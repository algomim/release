#!/usr/bin/env sh
set -eu

fail() { printf '[fail] %s\n' "$1" >&2; exit 1; }
assert_equal() { [ "$1" = "$2" ] || fail "$3"; }
assert_file() { [ -f "$1" ] || fail "$2"; }
json_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -n 1
}
profile_key() {
  path="$1"
  profile="$2"
  [ -f "$path" ] || return 0
  awk -v wanted="$profile" '
    { line=$0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line) }
    line ~ /^\[[^][]+\]$/ { section=substr(line,2,length(line)-2); next }
    section==wanted && line ~ /^api_key[[:space:]]*=/ { sub(/^api_key[[:space:]]*=[[:space:]]*/, "", line); print line; exit }
  ' "$path"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL="$REPO_ROOT/codex/install.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' HUP INT TERM EXIT

HOME="$TEST_ROOT/home"
CODEX_HOME="$TEST_ROOT/codex"
ALGOMIM_HOME="$TEST_ROOT/algomim"
FAKE_BIN="$TEST_ROOT/bin"
ALGOMIM_SHELL_PROFILE="$HOME/.profile"
mkdir -p "$HOME" "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod 700 "$FAKE_BIN/codex"
PATH="$FAKE_BIN:$PATH"
SHELL="/bin/sh"
export HOME CODEX_HOME ALGOMIM_HOME ALGOMIM_SHELL_PROFILE PATH SHELL
unset ALGOMIM_API_KEY ALGOMIM_PROFILE 2>/dev/null || true

DEFAULT_KEY="sk-cli-default-000000"
WORK_KEY="sk-cli-work-000000"
ROTATED_KEY="sk-cli-rotated-000000"
INSTALL_OUTPUT=$(sh "$INSTALL" --api-key "$DEFAULT_KEY" --credential-profile default 2>&1)
case "$INSTALL_OUTPUT" in *"$DEFAULT_KEY"*) fail "installer output must not expose the API key" ;; esac

CLI="$ALGOMIM_HOME/bin/algomim"
CLI_STATE="$ALGOMIM_HOME/cli/state.json"
CREDENTIALS="$ALGOMIM_HOME/credentials"
assert_file "$CLI" "installer must write the shell CLI"
assert_file "$CLI_STATE" "installer must write CLI state"
assert_equal "0.3.7" "$(json_field version "$CLI_STATE")" "CLI state must record the release version"
assert_equal "v0.3.7" "$(json_field releaseTag "$CLI_STATE")" "CLI state must record the immutable tag"
grep -F "$DEFAULT_KEY" "$CLI_STATE" >/dev/null 2>&1 && fail "CLI state must not contain credentials"

START_COUNT=$(grep -c '^# >>> algomim cli >>>$' "$ALGOMIM_SHELL_PROFILE")
END_COUNT=$(grep -c '^# <<< algomim cli <<<$' "$ALGOMIM_SHELL_PROFILE")
assert_equal "1" "$START_COUNT" "installer must add one PATH block"
assert_equal "1" "$END_COUNT" "installer must close one PATH block"
INSTALLED_AT=$(json_field installedAt "$CLI_STATE")
sh "$INSTALL" --credential-profile default >/dev/null 2>&1
assert_equal "1" "$(grep -c '^# >>> algomim cli >>>$' "$ALGOMIM_SHELL_PROFILE")" "reinstall must not duplicate PATH"
assert_equal "$INSTALLED_AT" "$(json_field installedAt "$CLI_STATE")" "reinstall must preserve install time"

sh "$CLI" version | grep -F 'Algomim CLI 0.3.7 (v0.3.7)' >/dev/null || fail "version must report CLI version"
sh "$CLI" help | grep -F 'algomim doctor [codex|claude] [--offline]' >/dev/null || fail "help must list lifecycle commands"
sh "$CLI" help | grep -F 'algomim run <codex|claude>' >/dev/null || fail "help must list the run command"
LOGIN_OUTPUT=$(printf '%s\n' "$WORK_KEY" | sh "$CLI" login --profile work --api-key-stdin 2>&1)
assert_equal "$WORK_KEY" "$(profile_key "$CREDENTIALS" work)" "login must create a named profile"
case "$LOGIN_OUTPUT" in *"$WORK_KEY"*) fail "login output must not expose the API key" ;; esac
ROTATION_OUTPUT=$(printf '%s\n' "$ROTATED_KEY" | sh "$CLI" login --profile work --api-key-stdin 2>&1)
assert_equal "$ROTATED_KEY" "$(profile_key "$CREDENTIALS" work)" "login must rotate the selected profile"
case "$ROTATION_OUTPUT" in *"$ROTATED_KEY"*) fail "rotation output must not expose the API key" ;; esac
sh "$CLI" logout --profile work --yes >/dev/null
[ -z "$(profile_key "$CREDENTIALS" work)" ] || fail "logout must remove the selected profile"
assert_equal "$DEFAULT_KEY" "$(profile_key "$CREDENTIALS" default)" "logout must preserve unrelated profiles"

sh "$CLI" doctor codex --offline >/dev/null
LEGACY_DOCTOR_OUTPUT=$(sh "$CLI" codex doctor --offline 2>&1) || fail "legacy noun-first grammar must still work"
case "$LEGACY_DOCTOR_OUTPUT" in *[Dd]eprecat*) fail "legacy grammar must not print a deprecation notice" ;; esac
INTEGRATION_HOME="$ALGOMIM_HOME/integrations/codex"
UPDATE_PATH="$INTEGRATION_HOME/update.sh"
UPDATE_BACKUP="$TEST_ROOT/update.sh"
UPDATE_MARKER="$TEST_ROOT/update-marker.txt"
cp "$UPDATE_PATH" "$UPDATE_BACKUP"
cat > "$UPDATE_PATH" <<'EOF'
#!/usr/bin/env sh
set -eu
printf '%s' "$*" > "$ALGOMIM_CLI_TEST_MARKER"
EOF
chmod 700 "$UPDATE_PATH"
ALGOMIM_CLI_TEST_MARKER="$UPDATE_MARKER"
export ALGOMIM_CLI_TEST_MARKER
sh "$CLI" update codex --check
assert_equal "--check" "$(cat "$UPDATE_MARKER")" "update --check must delegate to the lifecycle updater"
rm -f "$UPDATE_MARKER"
sh "$CLI" update --check
assert_equal "--check" "$(cat "$UPDATE_MARKER")" "bare update must target every installed integration"
cp "$UPDATE_BACKUP" "$UPDATE_PATH"
chmod 700 "$UPDATE_PATH"
unset ALGOMIM_CLI_TEST_MARKER

sh "$CLI" uninstall codex >/dev/null
[ ! -d "$INTEGRATION_HOME" ] || fail "uninstall codex must remove only the integration"
assert_file "$CLI" "uninstall codex must preserve the CLI"
assert_equal "$DEFAULT_KEY" "$(profile_key "$CREDENTIALS" default)" "uninstall codex must preserve credentials"
sh "$CLI" install codex --profile default >/dev/null
assert_file "$INTEGRATION_HOME/state.json" "install codex must repair a removed integration"
if find "$ALGOMIM_HOME" -type f ! -path "$CREDENTIALS" -exec grep -F "$DEFAULT_KEY" {} + >/dev/null 2>&1; then
  fail "non-credential files must not contain the API key"
fi

MIGRATION_ROOT="$TEST_ROOT/migration"
PREVIOUS_ARCHIVE="$MIGRATION_ROOT/v0.1.2.tar"
PREVIOUS_SOURCE="$MIGRATION_ROOT/source"
mkdir -p "$PREVIOUS_SOURCE"
git -C "$REPO_ROOT" archive --format=tar --output="$PREVIOUS_ARCHIVE" v0.1.2 codex
tar -xf "$PREVIOUS_ARCHIVE" -C "$PREVIOUS_SOURCE"
CODEX_HOME="$MIGRATION_ROOT/codex"
ALGOMIM_HOME="$MIGRATION_ROOT/algomim"
ALGOMIM_SHELL_PROFILE="$MIGRATION_ROOT/profile"
export CODEX_HOME ALGOMIM_HOME ALGOMIM_SHELL_PROFILE
sh "$PREVIOUS_SOURCE/codex/install.sh" --api-key "$DEFAULT_KEY" --release-version 0.1.2 --release-ref v0.1.2 >/dev/null 2>&1
MIGRATION_CREDENTIALS="$ALGOMIM_HOME/credentials"
cp "$MIGRATION_CREDENTIALS" "$MIGRATION_ROOT/credentials-before"
[ ! -f "$ALGOMIM_HOME/bin/algomim" ] || fail "v0.1.2 must start without the shell CLI"
MIGRATION_OUTPUT=$(sh "$INSTALL" --credential-profile default 2>&1)
cmp -s "$MIGRATION_ROOT/credentials-before" "$MIGRATION_CREDENTIALS" || fail "v0.1.2 migration must preserve credential bytes"
assert_file "$ALGOMIM_HOME/bin/algomim" "v0.2.0 migration must install the shell CLI"
case "$MIGRATION_OUTPUT" in *"$DEFAULT_KEY"*) fail "migration output must not expose the API key" ;; esac

printf '[ok] POSIX Algomim CLI tests passed.\n'
rm -rf "$TEST_ROOT"
trap - HUP INT TERM EXIT
