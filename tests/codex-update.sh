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
  "minimumCodexVersion": "0.144.1",
  "artifacts": {
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

copy_posix_bundle() {
  destination="$1"
  mkdir -p "$destination/codex"
  for name in algomim-models.json install.sh update.sh doctor.sh uninstall.sh release.json; do
    cp "$REPO_ROOT/codex/$name" "$destination/codex/$name"
  done
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' HUP INT TERM EXIT

ARTIFACTS="$TEST_ROOT/artifacts"
STAGE="$TEST_ROOT/stage"
CODEX_HOME="$TEST_ROOT/codex-home"
ALGOMIM_HOME="$TEST_ROOT/algomim-home"
FAKE_BIN="$TEST_ROOT/bin"
KEY="test-update-key-000000"
mkdir -p "$ARTIFACTS" "$STAGE" "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod 700 "$FAKE_BIN/codex"
PATH="$FAKE_BIN:$PATH"
export PATH CODEX_HOME ALGOMIM_HOME
unset ALGOMIM_API_KEY ALGOMIM_PROFILE 2>/dev/null || true

copy_posix_bundle "$STAGE/good"
GOOD_ARTIFACT="algomim-codex-posix-v0.1.0.tar.gz"
tar -czf "$ARTIFACTS/$GOOD_ARTIFACT" -C "$STAGE/good" codex
GOOD_HASH=$(sha256_file "$ARTIFACTS/$GOOD_ARTIFACT")
write_manifest "0.1.0" "$GOOD_ARTIFACT" "$GOOD_HASH" "$ARTIFACTS/manifest.json"

sh "$REPO_ROOT/codex/install.sh" \
  --api-key "$KEY" \
  --release-version 0.0.9 \
  --release-ref v0.0.9 >/dev/null 2>&1

STATE_PATH="$ALGOMIM_HOME/integrations/codex/state.json"
CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"
INITIAL_INSTALLED_AT=$(json_field installedAt "$STATE_PATH")
UPDATE_OUTPUT=$(sh "$REPO_ROOT/codex/update.sh" \
  --manifest-url "$ARTIFACTS/manifest.json" \
  --artifact-base-url "$ARTIFACTS" 2>&1)

assert_equal "0.1.0" "$(json_field version "$STATE_PATH")" "verified release must update state"
assert_equal "$INITIAL_INSTALLED_AT" "$(json_field installedAt "$STATE_PATH")" "update must preserve installation timestamp"
grep -F "$KEY" "$CREDENTIALS_PATH" >/dev/null || fail "update must preserve shared credential"
case "$UPDATE_OUTPUT" in *"$KEY"*) fail "update output must not contain credential" ;; esac

PROFILE_PATH="$CODEX_HOME/algomim.config.toml"
PROFILE_HASH=$(sha256_file "$PROFILE_PATH")
cp "$STATE_PATH" "$TEST_ROOT/state-before-rollback.json"
cp "$CREDENTIALS_PATH" "$TEST_ROOT/credential-before-rollback"

copy_posix_bundle "$STAGE/bad"
sed 's/"version": "0.1.0"/"version": "0.2.0"/; s/"releaseTag": "v0.1.0"/"releaseTag": "v0.2.0"/' \
  "$STAGE/bad/codex/release.json" > "$STAGE/bad/codex/release.json.tmp"
mv "$STAGE/bad/codex/release.json.tmp" "$STAGE/bad/codex/release.json"
printf '{\n  "models": []\n}\n' > "$STAGE/bad/codex/algomim-models.json"
BAD_ARTIFACT="algomim-codex-posix-v0.2.0.tar.gz"
tar -czf "$ARTIFACTS/$BAD_ARTIFACT" -C "$STAGE/bad" codex
BAD_HASH=$(sha256_file "$ARTIFACTS/$BAD_ARTIFACT")
write_manifest "0.2.0" "$BAD_ARTIFACT" "$BAD_HASH" "$ARTIFACTS/bad-manifest.json"

if sh "$ALGOMIM_HOME/integrations/codex/update.sh" \
  --manifest-url "$ARTIFACTS/bad-manifest.json" \
  --artifact-base-url "$ARTIFACTS" >/dev/null 2>&1; then
  fail "failed post-install doctor must roll back"
fi
cmp -s "$TEST_ROOT/state-before-rollback.json" "$STATE_PATH" || fail "rollback must restore exact state"
assert_equal "$PROFILE_HASH" "$(sha256_file "$PROFILE_PATH")" "rollback must restore Codex profile"
cmp -s "$TEST_ROOT/credential-before-rollback" "$CREDENTIALS_PATH" || fail "rollback must not change credential"
[ -f "$ALGOMIM_HOME/integrations/codex/update.sh" ] || fail "rollback must restore lifecycle files"

write_manifest "0.2.0" "$BAD_ARTIFACT" "0000000000000000000000000000000000000000000000000000000000000000" "$ARTIFACTS/checksum-manifest.json"
if sh "$ALGOMIM_HOME/integrations/codex/update.sh" \
  --manifest-url "$ARTIFACTS/checksum-manifest.json" \
  --artifact-base-url "$ARTIFACTS" >/dev/null 2>&1; then
  fail "checksum mismatch must be rejected"
fi
cmp -s "$TEST_ROOT/state-before-rollback.json" "$STATE_PATH" || fail "checksum rejection must leave state unchanged"

printf '[ok] POSIX update and rollback tests passed.\n'
rm -rf "$TEST_ROOT"
trap - HUP INT TERM EXIT
