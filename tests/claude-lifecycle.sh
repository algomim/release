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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL="$REPO_ROOT/claude-code/install.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' HUP INT TERM EXIT

HOME="$TEST_ROOT/home"
ALGOMIM_HOME="$TEST_ROOT/algomim"
FAKE_BIN="$TEST_ROOT/bin"
CLAUDE_CONFIG_DIR="$TEST_ROOT/claude-user"
CAPTURE="$TEST_ROOT/claude-capture.txt"
ALGOMIM_SHELL_PROFILE="$HOME/.profile"
mkdir -p "$HOME" "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env sh
printf 'ARGS=%s\n' "$*" > "$CLAUDE_STUB_CAPTURE"
printf 'TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN:-}" >> "$CLAUDE_STUB_CAPTURE"
exit 0
EOF
chmod 700 "$FAKE_BIN/claude"
PATH="$FAKE_BIN:$PATH"
SHELL="/bin/sh"
export HOME ALGOMIM_HOME ALGOMIM_SHELL_PROFILE PATH SHELL CLAUDE_CONFIG_DIR
unset ALGOMIM_API_KEY ALGOMIM_PROFILE 2>/dev/null || true

KEY="sk-claude-lifecycle-000000"
INSTALL_OUTPUT=$(sh "$INSTALL" --api-key "$KEY" --credential-profile default --base-url "https://pilot.example.com" 2>&1)
case "$INSTALL_OUTPUT" in *"$KEY"*) fail "installer output must not expose the API key" ;; esac

INTEGRATION_HOME="$ALGOMIM_HOME/integrations/claude-code"
SETTINGS_PATH="$INTEGRATION_HOME/settings.json"
STATE_PATH="$INTEGRATION_HOME/state.json"
CREDENTIALS="$ALGOMIM_HOME/credentials"
CLI="$ALGOMIM_HOME/bin/algomim"
assert_file "$SETTINGS_PATH" "installer must write the session settings"
assert_file "$STATE_PATH" "installer must write the integration state"
assert_file "$CLI" "installer must install the Algomim CLI"

assert_equal "https://pilot.example.com/v1" "$(json_field ANTHROPIC_BASE_URL "$SETTINGS_PATH")" "settings must record the normalized base URL"
assert_equal "algomim" "$(json_field ANTHROPIC_DEFAULT_HAIKU_MODEL "$SETTINGS_PATH")" "settings must redirect background haiku traffic"
assert_equal "algomim" "$(json_field ANTHROPIC_CUSTOM_MODEL_OPTION "$SETTINGS_PATH")" "settings must add the /model custom option"
grep -F "$KEY" "$SETTINGS_PATH" >/dev/null 2>&1 && fail "settings must not contain the API key"
assert_equal "claude-code" "$(json_field integration "$STATE_PATH")" "state must record the integration id"
assert_equal "0.3.0" "$(json_field version "$STATE_PATH")" "state must record the release version"

[ ! -e "$CLAUDE_CONFIG_DIR" ] || fail "install must never create the Claude Code config directory"

sh "$CLI" doctor claude --offline >/dev/null || fail "doctor claude --offline must pass after install"

mkdir -p "$CLAUDE_CONFIG_DIR"
printf '{"env":{"ANTHROPIC_BASE_URL":"https://user.example.com"}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
CONFLICT_OUTPUT=$(sh "$CLI" doctor claude --offline 2>&1) || fail "conflicting user settings must warn without failing"
case "$CONFLICT_OUTPUT" in *"can conflict"*) ;; *) fail "doctor must warn about conflicting user settings" ;; esac
rm -rf "$CLAUDE_CONFIG_DIR"

CLAUDE_STUB_CAPTURE="$CAPTURE"
export CLAUDE_STUB_CAPTURE
sh "$CLI" run claude -- --version >/dev/null || fail "run claude must exit with the client exit code"
grep -F -- "--settings" "$CAPTURE" >/dev/null || fail "run claude must pass the settings file"
grep -F "$SETTINGS_PATH" "$CAPTURE" >/dev/null || fail "run claude must point at the installed settings"
grep -F -- "--version" "$CAPTURE" >/dev/null || fail "run claude must forward passthrough arguments"
grep -F "TOKEN=$KEY" "$CAPTURE" >/dev/null || fail "run claude must inject the token into the process environment"
grep '^ARGS=' "$CAPTURE" | grep -F "$KEY" >/dev/null 2>&1 && fail "run claude must never place the token on the command line"
[ ! -e "$CLAUDE_CONFIG_DIR" ] || fail "run must never create the Claude Code config directory"

sh "$CLI" uninstall claude >/dev/null
[ ! -d "$INTEGRATION_HOME" ] || fail "uninstall claude must remove only the integration"
assert_file "$CLI" "uninstall claude must preserve the CLI"
assert_file "$CREDENTIALS" "uninstall claude must preserve credentials"

sh "$CLI" install claude --profile default >/dev/null
assert_file "$STATE_PATH" "install claude must repair a removed integration"

if find "$ALGOMIM_HOME" -type f ! -path "$CREDENTIALS" -exec grep -F "$KEY" {} + >/dev/null 2>&1; then
  fail "non-credential files must not contain the API key"
fi

printf '[ok] POSIX Claude Code lifecycle tests passed.\n'
rm -rf "$TEST_ROOT"
trap - HUP INT TERM EXIT
