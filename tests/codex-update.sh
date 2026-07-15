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
  mkdir -p "$destination/codex" "$destination/cli" "$destination/shared"
  for name in algomim-models.json algomim-models.lock.json install.sh update.sh doctor.sh uninstall.sh release.json; do
    cp "$REPO_ROOT/codex/$name" "$destination/codex/$name"
  done
  for name in algomim.sh install.sh release.json; do
    cp "$REPO_ROOT/cli/$name" "$destination/cli/$name"
  done
  cp "$REPO_ROOT/shared/credential-store.sh" "$destination/shared/credential-store.sh"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CURRENT_VERSION=$(json_field version "$REPO_ROOT/codex/release.json")
CURRENT_TAG=$(json_field releaseTag "$REPO_ROOT/codex/release.json")
if [ "$CURRENT_VERSION" = "9999.9999.9999" ]; then
  INVALID_VERSION="9999.9999.9998"
else
  INVALID_VERSION="9999.9999.9999"
fi
INVALID_TAG="v$INVALID_VERSION"
PREVIOUS_TAG=$(git -C "$REPO_ROOT" tag --list 'v*.*.*' --sort=-version:refname |
  awk -v current="$CURRENT_TAG" '$0 != current { print; exit }')
[ -n "$PREVIOUS_TAG" ] || fail "a previous release tag is required for the update compatibility test"
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
GOOD_ARTIFACT="algomim-codex-posix-$CURRENT_TAG.tar.gz"
tar -czf "$ARTIFACTS/$GOOD_ARTIFACT" -C "$STAGE/good" codex cli shared
GOOD_HASH=$(sha256_file "$ARTIFACTS/$GOOD_ARTIFACT")
write_manifest "$CURRENT_VERSION" "$GOOD_ARTIFACT" "$GOOD_HASH" "$ARTIFACTS/manifest.json"

PREVIOUS_ARCHIVE="$TEST_ROOT/previous-release.tar"
git -C "$REPO_ROOT" archive --format=tar --output="$PREVIOUS_ARCHIVE" "$PREVIOUS_TAG" codex
mkdir -p "$STAGE/previous"
tar -xf "$PREVIOUS_ARCHIVE" -C "$STAGE/previous"
PREVIOUS_VERSION=$(json_field version "$STAGE/previous/codex/release.json")
assert_equal "$PREVIOUS_TAG" "$(json_field releaseTag "$STAGE/previous/codex/release.json")" "previous release contract must match its tag"

sh "$STAGE/previous/codex/install.sh" \
  --api-key "$KEY" \
  --release-version "$PREVIOUS_VERSION" \
  --release-ref "$PREVIOUS_TAG" >/dev/null 2>&1

STATE_PATH="$ALGOMIM_HOME/integrations/codex/state.json"
CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"
INITIAL_INSTALLED_AT=$(json_field installedAt "$STATE_PATH")
assert_equal "$PREVIOUS_VERSION" "$(json_field version "$STATE_PATH")" "test must start from the previous published release"
UPDATE_OUTPUT=$(sh "$ALGOMIM_HOME/integrations/codex/update.sh" \
  --manifest-url "$ARTIFACTS/manifest.json" \
  --artifact-base-url "$ARTIFACTS" 2>&1)

assert_equal "$CURRENT_VERSION" "$(json_field version "$STATE_PATH")" "previous updater must install the verified current release"
assert_equal "$INITIAL_INSTALLED_AT" "$(json_field installedAt "$STATE_PATH")" "update must preserve installation timestamp"
grep -F "$KEY" "$CREDENTIALS_PATH" >/dev/null || fail "update must preserve shared credential"
case "$UPDATE_OUTPUT" in *"$KEY"*) fail "update output must not contain credential" ;; esac

PROFILE_PATH="$CODEX_HOME/algomim.config.toml"
PROFILE_HASH=$(sha256_file "$PROFILE_PATH")
cp "$STATE_PATH" "$TEST_ROOT/state-before-rollback.json"
cp "$CREDENTIALS_PATH" "$TEST_ROOT/credential-before-rollback"

copy_posix_bundle "$STAGE/bad"
sed "s/\"version\": \"$CURRENT_VERSION\"/\"version\": \"$INVALID_VERSION\"/; s/\"releaseTag\": \"$CURRENT_TAG\"/\"releaseTag\": \"$INVALID_TAG\"/" \
  "$STAGE/bad/codex/release.json" > "$STAGE/bad/codex/release.json.tmp"
mv "$STAGE/bad/codex/release.json.tmp" "$STAGE/bad/codex/release.json"
printf '{\n  "models": []\n}\n' > "$STAGE/bad/codex/algomim-models.json"
BAD_ARTIFACT="algomim-codex-posix-$INVALID_TAG.tar.gz"
tar -czf "$ARTIFACTS/$BAD_ARTIFACT" -C "$STAGE/bad" codex cli shared
BAD_HASH=$(sha256_file "$ARTIFACTS/$BAD_ARTIFACT")
write_manifest "$INVALID_VERSION" "$BAD_ARTIFACT" "$BAD_HASH" "$ARTIFACTS/bad-manifest.json"

if sh "$ALGOMIM_HOME/integrations/codex/update.sh" \
  --manifest-url "$ARTIFACTS/bad-manifest.json" \
  --artifact-base-url "$ARTIFACTS" >/dev/null 2>&1; then
  fail "failed post-install doctor must roll back"
fi
cmp -s "$TEST_ROOT/state-before-rollback.json" "$STATE_PATH" || fail "rollback must restore exact state"
assert_equal "$PROFILE_HASH" "$(sha256_file "$PROFILE_PATH")" "rollback must restore Codex profile"
cmp -s "$TEST_ROOT/credential-before-rollback" "$CREDENTIALS_PATH" || fail "rollback must not change credential"
[ -f "$ALGOMIM_HOME/integrations/codex/update.sh" ] || fail "rollback must restore lifecycle files"

write_manifest "$INVALID_VERSION" "$BAD_ARTIFACT" "0000000000000000000000000000000000000000000000000000000000000000" "$ARTIFACTS/checksum-manifest.json"
if sh "$ALGOMIM_HOME/integrations/codex/update.sh" \
  --manifest-url "$ARTIFACTS/checksum-manifest.json" \
  --artifact-base-url "$ARTIFACTS" >/dev/null 2>&1; then
  fail "checksum mismatch must be rejected"
fi
cmp -s "$TEST_ROOT/state-before-rollback.json" "$STATE_PATH" || fail "checksum rejection must leave state unchanged"

printf '[ok] POSIX update and rollback tests passed.\n'
rm -rf "$TEST_ROOT"
trap - HUP INT TERM EXIT
