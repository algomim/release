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

fail() {
  printf '[fail] %s\n' "$1" >&2
  exit 1
}

assert_file() { [ -f "$1" ] || fail "$2"; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

json_claude_posix_field() {
  field="$1"
  path="$2"
  awk -v wanted_field="$field" '
    $0 ~ "^[[:space:]]*\"claudeCodeArtifacts\"[[:space:]]*:[[:space:]]*\\{" {
      inside_claude = 1
      next
    }
    inside_claude && !inside_posix && $0 ~ "^[[:space:]]*\"posix\"[[:space:]]*:[[:space:]]*\\{" {
      inside_posix = 1
      next
    }
    inside_posix && $0 ~ "^[[:space:]]*\\}" {
      exit
    }
    inside_posix && $0 ~ "^[[:space:]]*\"" wanted_field "\"[[:space:]]*:" {
      line = $0
      sub("^[[:space:]]*\"" wanted_field "\"[[:space:]]*:[[:space:]]*\"", "", line)
      sub("\"[,]?[[:space:]]*$", "", line)
      print line
      exit
    }
  ' "$path"
}

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/algomim-claude-published.XXXXXX")
ALGOMIM_HOME="$TEST_ROOT/algomim-home"
FAKE_BIN="$TEST_ROOT/bin"
INSTALLER="$TEST_ROOT/install.sh"
KEY="sk-published-claude-000000"
mkdir -p "$FAKE_BIN"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod 700 "$FAKE_BIN/claude"
PATH="$FAKE_BIN:$PATH"
export PATH ALGOMIM_HOME
unset ALGOMIM_API_KEY ALGOMIM_PROFILE 2>/dev/null || true

curl -fsSL "https://raw.githubusercontent.com/algomim/release/$TAG/claude-code/install.sh" -o "$INSTALLER"
INSTALL_OUTPUT=$(sh "$INSTALLER" \
  --api-key "$KEY" \
  --release-ref "$TAG" \
  --release-version "$VERSION" \
  --cli-path-target process 2>&1)

INTEGRATION_HOME="$ALGOMIM_HOME/integrations/claude-code"
SETTINGS_PATH="$INTEGRATION_HOME/settings.json"
CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"
CLI="$ALGOMIM_HOME/bin/algomim"
assert_file "$SETTINGS_PATH" "install must write the session settings"
assert_file "$CLI" "install must write the Algomim CLI"
case "$INSTALL_OUTPUT" in *"$KEY"*) fail "install output must not expose the credential" ;; esac

MANIFEST="$TEST_ROOT/manifest.json"
curl -fsSL "https://github.com/algomim/release/releases/download/$TAG/manifest.json" -o "$MANIFEST"
ARTIFACT_NAME=$(json_claude_posix_field file "$MANIFEST")
EXPECTED_HASH=$(json_claude_posix_field sha256 "$MANIFEST" | tr 'A-F' 'a-f')
[ -n "$ARTIFACT_NAME" ] || fail "manifest must advertise the POSIX Claude Code artifact"
ARCHIVE="$TEST_ROOT/$ARTIFACT_NAME"
curl -fsSL "https://github.com/algomim/release/releases/download/$TAG/$ARTIFACT_NAME" -o "$ARCHIVE"
ACTUAL_HASH=$(sha256_file "$ARCHIVE" | tr 'A-F' 'a-f')
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || fail "published Claude Code artifact must match its SHA-256"
ARCHIVE_ROOT="$TEST_ROOT/claude-archive"
mkdir -p "$ARCHIVE_ROOT"
tar -xzf "$ARCHIVE" -C "$ARCHIVE_ROOT"
assert_file "$ARCHIVE_ROOT/claude-code/install.sh" "published Claude Code artifact must contain the installer"

sh "$INTEGRATION_HOME/doctor.sh" --credential-profile default --skip-api-check

sh "$CLI" update claude --check

CREDENTIAL_HASH=$(sha256_file "$CREDENTIALS_PATH")
UPDATE_OUTPUT=$(sh "$INTEGRATION_HOME/update.sh" --version "$VERSION" --force 2>&1)
case "$UPDATE_OUTPUT" in
  *"Verified "*"SHA-256"*) ;;
  *) fail "update must verify the published artifact" ;;
esac
case "$UPDATE_OUTPUT" in *"$KEY"*) fail "update output must not expose the credential" ;; esac
[ "$(sha256_file "$CREDENTIALS_PATH")" = "$CREDENTIAL_HASH" ] || fail "update must preserve the credential"

sh "$CLI" doctor claude --offline

sh "$CLI" uninstall claude >/dev/null
[ ! -d "$INTEGRATION_HOME" ] || fail "normal uninstall must remove the integration"
assert_file "$CREDENTIALS_PATH" "normal uninstall must preserve credentials"
assert_file "$CLI" "normal uninstall must preserve the CLI"

REINSTALL_OUTPUT=$(sh "$CLI" install claude --profile default 2>&1)
assert_file "$SETTINGS_PATH" "reinstall must restore the session settings"
case "$REINSTALL_OUTPUT" in *"$KEY"*) fail "reinstall output must not expose the credential" ;; esac

sh "$CLI" uninstall claude >/dev/null
sh "$CLI" logout --profile default --yes >/dev/null
[ ! -f "$CREDENTIALS_PATH" ] || fail "explicit removal must delete the final credential profile"
assert_file "$CLI" "logout must preserve the CLI"

printf '[ok] Published %s POSIX Claude Code lifecycle passed.\n' "$TAG"
