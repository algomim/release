#!/usr/bin/env sh
set -eu

TAG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if ! printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Tag must use vMAJOR.MINOR.PATCH format." >&2
  exit 2
fi

VERSION=${TAG#v}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/algomim-published.XXXXXX")
CODEX_HOME="$TEST_ROOT/codex-home"
ALGOMIM_HOME="$TEST_ROOT/algomim-home"
FAKE_BIN="$TEST_ROOT/bin"
INSTALLER="$TEST_ROOT/install.sh"
KEY="sk-published-lifecycle-000000"
mkdir -p "$FAKE_BIN"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod 700 "$FAKE_BIN/codex"
PATH="$FAKE_BIN:$PATH"
export PATH CODEX_HOME ALGOMIM_HOME
unset ALGOMIM_API_KEY ALGOMIM_PROFILE 2>/dev/null || true

curl -fsSL "https://raw.githubusercontent.com/algomim/release/$TAG/codex/install.sh" -o "$INSTALLER"
INSTALL_OUTPUT=$(sh "$INSTALLER" \
  --api-key "$KEY" \
  --release-ref "$TAG" \
  --release-version "$VERSION" \
  --cli-path-target process 2>&1)

INTEGRATION_HOME="$ALGOMIM_HOME/integrations/codex"
CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"
PROFILE_PATH="$CODEX_HOME/algomim.config.toml"
CATALOG_PATH="$CODEX_HOME/algomim-models.json"
[ -f "$PROFILE_PATH" ] || { echo "Profile was not installed." >&2; exit 1; }
[ -f "$CATALOG_PATH" ] || { echo "Catalog was not installed." >&2; exit 1; }
case "$INSTALL_OUTPUT" in *"$KEY"*) echo "Install output exposed the credential." >&2; exit 1 ;; esac
CLI="$ALGOMIM_HOME/bin/algomim"
CLI_STATE="$ALGOMIM_HOME/cli/state.json"
[ -f "$CLI" ] || { echo "Algomim CLI was not installed." >&2; exit 1; }
[ -f "$CLI_STATE" ] || { echo "Algomim CLI state was not installed." >&2; exit 1; }
sh "$CLI" version | grep -F "Algomim CLI $VERSION ($TAG)" >/dev/null || { echo "CLI version is incorrect." >&2; exit 1; }

MANIFEST_PATH="$TEST_ROOT/manifest.json"
curl -fsSL "https://github.com/algomim/release/releases/download/$TAG/manifest.json" -o "$MANIFEST_PATH"
CLI_POSIX_BLOCK=$(awk '
  /"cliArtifacts"/ { in_cli = 1 }
  in_cli && /"posix"/ { in_posix = 1; next }
  in_posix && /^[[:space:]]*}/ { exit }
  in_posix { print }
' "$MANIFEST_PATH")
CLI_ARTIFACT=$(printf '%s\n' "$CLI_POSIX_BLOCK" | sed -n 's/^[[:space:]]*"file"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
CLI_HASH=$(printf '%s\n' "$CLI_POSIX_BLOCK" | sed -n 's/^[[:space:]]*"sha256"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{64\}\)".*/\1/p' | head -n 1)
[ -n "$CLI_ARTIFACT" ] && [ -n "$CLI_HASH" ] || { echo "Manifest does not advertise the POSIX CLI artifact." >&2; exit 1; }
CLI_ARCHIVE="$TEST_ROOT/$CLI_ARTIFACT"
curl -fsSL "https://github.com/algomim/release/releases/download/$TAG/$CLI_ARTIFACT" -o "$CLI_ARCHIVE"
[ "$(sha256_file "$CLI_ARCHIVE")" = "$CLI_HASH" ] || { echo "Published CLI artifact checksum is invalid." >&2; exit 1; }
tar -tzf "$CLI_ARCHIVE" | grep -F 'cli/algomim.sh' >/dev/null || { echo "Published CLI artifact is missing the POSIX dispatcher." >&2; exit 1; }

sh "$INTEGRATION_HOME/doctor.sh" --credential-profile default --skip-api-check
sh "$CLI" codex update --check

CREDENTIAL_HASH=$(sha256_file "$CREDENTIALS_PATH")
UPDATE_OUTPUT=$(sh "$INTEGRATION_HOME/update.sh" --version "$VERSION" --force 2>&1)
case "$UPDATE_OUTPUT" in *"Verified "*"SHA-256"*) ;; *) echo "Update did not verify the artifact." >&2; exit 1 ;; esac
case "$UPDATE_OUTPUT" in *"$KEY"*) echo "Update output exposed the credential." >&2; exit 1 ;; esac
[ "$(sha256_file "$CREDENTIALS_PATH")" = "$CREDENTIAL_HASH" ] || { echo "Update changed the credential." >&2; exit 1; }

sh "$CLI" codex doctor --offline
sh "$CLI" codex uninstall >/dev/null
[ ! -f "$PROFILE_PATH" ] || { echo "Normal uninstall kept the profile." >&2; exit 1; }
[ -f "$CREDENTIALS_PATH" ] || { echo "Normal uninstall removed shared credentials." >&2; exit 1; }
[ -f "$CLI" ] || { echo "Normal uninstall removed the CLI." >&2; exit 1; }

REINSTALL_OUTPUT=$(sh "$CLI" codex install --profile default 2>&1)
[ -f "$PROFILE_PATH" ] || { echo "Reinstall did not restore the profile." >&2; exit 1; }
case "$REINSTALL_OUTPUT" in *"$KEY"*) echo "Reinstall output exposed the credential." >&2; exit 1 ;; esac

sh "$CLI" codex uninstall >/dev/null
sh "$CLI" logout --profile default --yes >/dev/null
[ ! -f "$CREDENTIALS_PATH" ] || { echo "Explicit removal kept the final credential profile." >&2; exit 1; }
[ -f "$CLI" ] || { echo "Logout removed the CLI." >&2; exit 1; }

printf '[ok] Published %s POSIX lifecycle passed.\n' "$TAG"
