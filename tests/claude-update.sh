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
  "minimumClaudeCodeVersion": "2.1.214",
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

write_release_contract() {
  version="$1"
  destination="$2"
  cat > "$destination" <<EOF
{
  "schemaVersion": 1,
  "integration": "claude-code",
  "version": "$version",
  "releaseTag": "v$version",
  "minimumAlgomimCliVersion": "0.3.5",
  "channel": "pilot",
  "repository": "algomim/release"
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
BASELINE_VERSION="0.3.9"
BASELINE_TAG="v$BASELINE_VERSION"
BASELINE_REVISION="c5b8285408312e295f684ab0c3ef510dd89f3c10"
CANDIDATE_VERSION=$(json_field version "$REPO_ROOT/claude-code/release.json")
CANDIDATE_TAG=$(json_field releaseTag "$REPO_ROOT/claude-code/release.json")
assert_equal "v$CANDIDATE_VERSION" "$CANDIDATE_TAG" "candidate contract must match its version"
if [ "$CANDIDATE_VERSION" = "9999.9999.9999" ]; then
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
FAKE_BIN="$TEST_ROOT/bin"
KEY="test-claude-update-key-000000"
mkdir -p "$ARTIFACTS" "$STAGE" "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env sh
if [ "${1:-}" = "--version" ]; then
  printf '2.1.214\n'
fi
exit 0
EOF
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env sh
printf '[fail] update compatibility test attempted network access\n' >&2
exit 97
EOF
chmod 700 "$FAKE_BIN/claude" "$FAKE_BIN/curl"
PATH="$FAKE_BIN:$PATH"
export ALGOMIM_HOME PATH
unset ALGOMIM_API_KEY ALGOMIM_PROFILE 2>/dev/null || true

BASELINE_ARCHIVE="$TEST_ROOT/claude-$BASELINE_TAG.tar"
git -C "$REPO_ROOT" archive --format=tar --output="$BASELINE_ARCHIVE" "$BASELINE_REVISION" claude-code cli codex shared
mkdir -p "$STAGE/baseline"
tar -xf "$BASELINE_ARCHIVE" -C "$STAGE/baseline"
assert_equal "$BASELINE_VERSION" "$(json_field version "$STAGE/baseline/claude-code/release.json")" "baseline contract must record $BASELINE_TAG"
assert_equal "$BASELINE_TAG" "$(json_field releaseTag "$STAGE/baseline/claude-code/release.json")" "baseline contract must match the immutable tag"

sh "$STAGE/baseline/cli/install.sh" \
  --algomim-home "$ALGOMIM_HOME" \
  --release-ref "$BASELINE_TAG" \
  --release-version "$BASELINE_VERSION" \
  --path-target process >/dev/null
assert_equal "$BASELINE_VERSION" "$(json_field version "$ALGOMIM_HOME/cli/state.json")" "test must install the immutable $BASELINE_TAG CLI"
grep -q 'CLAUDE_CONFIG_DIR_PATH=' "$ALGOMIM_HOME/bin/algomim" || fail "baseline CLI launcher must contain Claude config isolation"
sh "$STAGE/baseline/claude-code/install.sh" \
  --api-key "$KEY" \
  --release-version "$BASELINE_VERSION" \
  --release-ref "$BASELINE_TAG" \
  --skip-cli-install >/dev/null 2>&1

INTEGRATION_HOME="$ALGOMIM_HOME/integrations/claude-code"
STATE_PATH="$INTEGRATION_HOME/state.json"
SETTINGS_PATH="$INTEGRATION_HOME/settings.json"
CLAUDE_CONFIG_PATH="$INTEGRATION_HOME/config"
RUNTIME_SENTINEL="$CLAUDE_CONFIG_PATH/runtime-sentinel.txt"
CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"
mkdir -p "$CLAUDE_CONFIG_PATH"
printf 'preserve Algomim Claude runtime state\n' > "$RUNTIME_SENTINEL"
cp "$RUNTIME_SENTINEL" "$TEST_ROOT/runtime-sentinel.before"

BASELINE_INSTALLED_AT=$(json_field installedAt "$STATE_PATH")
cp "$CREDENTIALS_PATH" "$TEST_ROOT/credential-before-update"
assert_equal "$BASELINE_VERSION" "$(json_field version "$STATE_PATH")" "test must start from immutable $BASELINE_TAG"
assert_equal "$BASELINE_TAG" "$(json_field releaseTag "$STATE_PATH")" "baseline state must record the immutable tag"
assert_equal "https://api.algomim.com" "$(json_field baseUrl "$STATE_PATH")" "baseline must record the service-root base URL"

copy_claude_bundle "$STAGE/candidate"
write_release_contract "$CANDIDATE_VERSION" "$STAGE/candidate/claude-code/release.json"
CANDIDATE_ARTIFACT="algomim-claude-code-posix-$CANDIDATE_TAG.tar.gz"
tar -czf "$ARTIFACTS/$CANDIDATE_ARTIFACT" -C "$STAGE/candidate" claude-code shared
CANDIDATE_HASH=$(sha256_file "$ARTIFACTS/$CANDIDATE_ARTIFACT")
write_manifest "$CANDIDATE_VERSION" "$CANDIDATE_ARTIFACT" "$CANDIDATE_HASH" "$ARTIFACTS/manifest.json"

UPDATE_OUTPUT=$(sh "$INTEGRATION_HOME/update.sh" \
  --manifest-url "$ARTIFACTS/manifest.json" \
  --artifact-base-url "$ARTIFACTS" 2>&1)

assert_equal "$CANDIDATE_VERSION" "$(json_field version "$STATE_PATH")" "$BASELINE_TAG CLI and updater must install candidate $CANDIDATE_TAG"
assert_equal "$CANDIDATE_TAG" "$(json_field releaseTag "$STATE_PATH")" "updated state must record the candidate tag"
assert_equal "$BASELINE_INSTALLED_AT" "$(json_field installedAt "$STATE_PATH")" "update must preserve installation timestamp"
cmp -s "$TEST_ROOT/credential-before-update" "$CREDENTIALS_PATH" || fail "update must preserve the exact credential store"
cmp -s "$TEST_ROOT/runtime-sentinel.before" "$RUNTIME_SENTINEL" || fail "update must preserve isolated Claude Code runtime state"
case "$UPDATE_OUTPUT" in *"$KEY"*) fail "update output must not contain credential" ;; esac
grep -q '"model"[[:space:]]*:[[:space:]]*"algomim"' "$SETTINGS_PATH" || fail "updated settings must select the Algomim model"
assert_equal "medium" "$(json_field effortLevel "$SETTINGS_PATH")" "updated settings must select medium effort by default"
grep -q '"availableModels"[[:space:]]*:[[:space:]]*\[[[:space:]]*"algomim"[[:space:]]*\]' "$SETTINGS_PATH" || fail "updated settings must allow only the Algomim model"
assert_equal "https://api.algomim.com" "$(json_field ANTHROPIC_BASE_URL "$SETTINGS_PATH")" "updated settings must preserve the service-root base URL"
assert_equal "algomim" "$(json_field ANTHROPIC_MODEL "$SETTINGS_PATH")" "updated settings must select the Algomim model for the main session"
assert_equal "algomim" "$(json_field ANTHROPIC_DEFAULT_OPUS_MODEL "$SETTINGS_PATH")" "updated settings must map gateway Default to Algomim"
assert_equal "Algomim" "$(json_field ANTHROPIC_DEFAULT_OPUS_MODEL_NAME "$SETTINGS_PATH")" "updated settings must label the single named model"
assert_equal "Algomim Model API" "$(json_field ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION "$SETTINGS_PATH")" "updated settings must describe the single named model"
assert_equal "effort" "$(json_field ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES "$SETTINGS_PATH")" "updated settings must enable only the supported Claude effort levels"
assert_equal "algomim" "$(json_field ANTHROPIC_SMALL_FAST_MODEL "$SETTINGS_PATH")" "updated settings must redirect background functionality"
assert_equal "0" "$(json_field CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY "$SETTINGS_PATH")" "updated settings must disable gateway model discovery"
assert_equal "1" "$(json_field CLAUDE_CODE_DISABLE_1M_CONTEXT "$SETTINGS_PATH")" "updated settings must disable unsupported 1M aliases"
assert_equal "algomim" "$(json_field CLAUDE_CODE_SUBAGENT_MODEL "$SETTINGS_PATH")" "updated settings must redirect subagents"
assert_equal "1" "$(json_field CLAUDE_CODE_SUBPROCESS_ENV_SCRUB "$SETTINGS_PATH")" "updated settings must scrub the credential from child processes"
for suffix in '' _NAME _DESCRIPTION _SUPPORTED_CAPABILITIES; do
  mapping_name="ANTHROPIC_CUSTOM_MODEL_OPTION${suffix}"
  ! grep -q "\"$mapping_name\"[[:space:]]*:" "$SETTINGS_PATH" || fail "updated settings must omit $mapping_name so it does not duplicate the mapped Opus row"
done
for family in FABLE SONNET HAIKU; do
  for suffix in MODEL MODEL_NAME MODEL_DESCRIPTION MODEL_SUPPORTED_CAPABILITIES; do
    mapping_name="ANTHROPIC_DEFAULT_${family}_${suffix}"
    ! grep -q "\"$mapping_name\"[[:space:]]*:" "$SETTINGS_PATH" || fail "updated settings must omit the $family $suffix mapping so the picker has no duplicate family entry"
  done
done

UP_TO_DATE_OUTPUT=$(sh "$INTEGRATION_HOME/update.sh" \
  --manifest-url "$ARTIFACTS/manifest.json" \
  --artifact-base-url "$ARTIFACTS" 2>&1)
case "$UP_TO_DATE_OUTPUT" in
  *"already up to date"*) ;;
  *) fail "same-version candidate update must report up to date" ;;
esac
assert_equal "$CANDIDATE_VERSION" "$(json_field version "$STATE_PATH")" "same-version candidate update must leave state unchanged"

SETTINGS_HASH=$(sha256_file "$SETTINGS_PATH")
cp "$STATE_PATH" "$TEST_ROOT/state-before-rollback.json"
cp "$CREDENTIALS_PATH" "$TEST_ROOT/credential-before-rollback"

mkdir -p "$STAGE/bad"
cp -R "$STAGE/candidate/." "$STAGE/bad/"
write_release_contract "$INVALID_VERSION" "$STAGE/bad/claude-code/release.json"
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
cmp -s "$TEST_ROOT/runtime-sentinel.before" "$RUNTIME_SENTINEL" || fail "rollback must restore isolated Claude Code runtime state"
[ -f "$INTEGRATION_HOME/update.sh" ] || fail "rollback must restore lifecycle files"

write_manifest "$INVALID_VERSION" "$BAD_ARTIFACT" "0000000000000000000000000000000000000000000000000000000000000000" "$ARTIFACTS/checksum-manifest.json"
if sh "$INTEGRATION_HOME/update.sh" \
  --manifest-url "$ARTIFACTS/checksum-manifest.json" \
  --artifact-base-url "$ARTIFACTS" >/dev/null 2>&1; then
  fail "checksum mismatch must be rejected"
fi
cmp -s "$TEST_ROOT/state-before-rollback.json" "$STATE_PATH" || fail "checksum rejection must leave state unchanged"

printf '[ok] POSIX Claude Code %s to candidate %s update and rollback tests passed.\n' "$BASELINE_TAG" "$CANDIDATE_TAG"
rm -rf "$TEST_ROOT"
trap - HUP INT TERM EXIT
