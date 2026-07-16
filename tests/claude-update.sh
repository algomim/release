#!/usr/bin/env sh
set -eu

fail() {
  printf '[fail] %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "$3"
}

json_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -n 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_manifest() {
  version="$1"
  artifact="$2"
  hash="$3"
  destination="$4"
  cat > "$destination" <<EOF
{
  "schemaVersion": 1,
  "integration": "codex",
  "version": "$version",
  "releaseTag": "v$version",
  "channel": "pilot",
  "minimumClaudeCodeVersion": "2.0.0",
  "claudeCodeArtifacts": {
    "windows": {
      "file": "unused.zip",
      "format": "zip",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    },
    "posix": {
      "file": "$artifact",
      "format": "tar.gz",
      "sha256": "$hash"
    }
  }
}
EOF
}

copy_claude_bundle() {
  destination="$1"
  mkdir -p "$destination/claude-code" "$destination/shared"
  for name in install.sh update.sh doctor.sh uninstall.sh release.json; do
    cp "$REPO_ROOT/claude-code/$name" "$destination/claude-code/$name"
  done
  cp "$REPO_ROOT/shared/credential-store.sh" "$destination/shared/credential-store.sh"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CURRENT_VERSION=$(json_field version "$REPO_ROOT/claude-code/release.json")
CURRENT_TAG=$(json_field releaseTag "$REPO_ROOT/claude-code/release.json")
if [ "$CURRENT_VERSION" = "9999.9999.9999" ]; then
  INVALID_VERSION="9999.9999.9998"
else
  INVALID_VERSION="9999.9999.9999"
fi
INVALID_TAG="v$INVALID_VERSION"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' HUP INT TERM EXIT

ARTIFACTS="$TEST_ROOT/artifacts"
STAGE="$TEST_ROOT/stage"
ALGOMIM_HOME="$TEST_ROOT/algomim-home"
KEY="test-claude-update-key-000000"
mkdir -p "$ARTIFACTS" "$STAGE"
export ALGOMIM_HOME
unset ALGOMIM_API_KEY ALGOMIM_PROFILE 2>/dev/null || true

copy_claude_bundle "$STAGE/good"
GOOD_ARTIFACT="algomim-claude-code-posix-$CURRENT_TAG.tar.gz"
tar -czf "$ARTIFACTS/$GOOD_ARTIFACT" -C "$STAGE/good" claude-code shared
GOOD_HASH=$(sha256_file "$ARTIFACTS/$GOOD_ARTIFACT")
write_manifest "$CURRENT_VERSION" "$GOOD_ARTIFACT" "$GOOD_HASH" "$ARTIFACTS/manifest.json"

sh "$REPO_ROOT/claude-code/install.sh" \
  --api-key "$KEY" \
  --release-version "$CURRENT_VERSION" \
  --release-ref "$CURRENT_TAG" \
  --skip-cli-install >/dev/null 2>&1

INTEGRATION_HOME="$ALGOMIM_HOME/integrations/claude-code"
STATE_PATH="$INTEGRATION_HOME/state.json"
SETTINGS_PATH="$INTEGRATION_HOME/settings.json"
CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"

UP_TO_DATE_OUTPUT=$(sh "$INTEGRATION_HOME/update.sh" \
  --manifest-url "$ARTIFACTS/manifest.json" \
  --artifact-base-url "$ARTIFACTS" 2>&1)
case "$UP_TO_DATE_OUTPUT" in
  *"already up to date"*) ;;
  *) fail "same-version update must report up to date" ;;
esac
assert_equal "$CURRENT_VERSION" "$(json_field version "$STATE_PATH")" "same-version update must leave state unchanged"

SETTINGS_HASH=$(sha256_file "$SETTINGS_PATH")
cp "$STATE_PATH" "$TEST_ROOT/state-before-rollback.json"
cp "$CREDENTIALS_PATH" "$TEST_ROOT/credential-before-rollback"

copy_claude_bundle "$STAGE/bad"
sed "s/\"version\": \"$CURRENT_VERSION\"/\"version\": \"$INVALID_VERSION\"/; s/\"releaseTag\": \"$CURRENT_TAG\"/\"releaseTag\": \"$INVALID_TAG\"/" \
  "$STAGE/bad/claude-code/release.json" > "$STAGE/bad/claude-code/release.json.tmp"
mv "$STAGE/bad/claude-code/release.json.tmp" "$STAGE/bad/claude-code/release.json"
cat > "$STAGE/bad/claude-code/doctor.sh" <<'EOF'
#!/usr/bin/env sh
echo "staged doctor failure" >&2
exit 1
EOF
chmod 700 "$STAGE/bad/claude-code/doctor.sh"
BAD_ARTIFACT="algomim-claude-code-posix-$INVALID_TAG.tar.gz"
tar -czf "$ARTIFACTS/$BAD_ARTIFACT" -C "$STAGE/bad" claude-code shared
BAD_HASH=$(sha256_file "$ARTIFACTS/$BAD_ARTIFACT")
write_manifest "$INVALID_VERSION" "$BAD_ARTIFACT" "$BAD_HASH" "$ARTIFACTS/bad-manifest.json"

if sh "$INTEGRATION_HOME/update.sh" \
  --manifest-url "$ARTIFACTS/bad-manifest.json" \
  --artifact-base-url "$ARTIFACTS" >/dev/null 2>&1; then
  fail "failed staged doctor must roll back"
fi
cmp -s "$TEST_ROOT/state-before-rollback.json" "$STATE_PATH" || fail "rollback must restore exact state"
assert_equal "$SETTINGS_HASH" "$(sha256_file "$SETTINGS_PATH")" "rollback must restore the session settings"
cmp -s "$TEST_ROOT/credential-before-rollback" "$CREDENTIALS_PATH" || fail "rollback must not change credential"
[ -f "$INTEGRATION_HOME/update.sh" ] || fail "rollback must restore lifecycle files"

write_manifest "$INVALID_VERSION" "$BAD_ARTIFACT" "0000000000000000000000000000000000000000000000000000000000000000" "$ARTIFACTS/checksum-manifest.json"
if sh "$INTEGRATION_HOME/update.sh" \
  --manifest-url "$ARTIFACTS/checksum-manifest.json" \
  --artifact-base-url "$ARTIFACTS" >/dev/null 2>&1; then
  fail "checksum mismatch must be rejected"
fi
cmp -s "$TEST_ROOT/state-before-rollback.json" "$STATE_PATH" || fail "checksum rejection must leave state unchanged"

printf '[ok] POSIX Claude Code update and rollback tests passed.\n'
rm -rf "$TEST_ROOT"
trap - HUP INT TERM EXIT
