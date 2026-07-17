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
NORMAL_CLAUDE_SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
CAPTURE="$TEST_ROOT/claude-capture.txt"
ALGOMIM_SHELL_PROFILE="$HOME/.profile"
mkdir -p "$HOME" "$FAKE_BIN" "$CLAUDE_CONFIG_DIR"
printf '{"model":"opus","availableModels":["opus"],"env":{"ANTHROPIC_BASE_URL":"https://user.example.com"}}\n' > "$NORMAL_CLAUDE_SETTINGS"
cp "$NORMAL_CLAUDE_SETTINGS" "$TEST_ROOT/normal-claude-settings.before"
cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env sh
if [ "${1:-}" = "--version" ]; then
  printf '2.1.211\n'
  exit 0
fi
printf 'ARGS=%s\n' "$*" > "$CLAUDE_STUB_CAPTURE"
printf 'TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN:-}" >> "$CLAUDE_STUB_CAPTURE"
printf 'CONFIG=%s\n' "${CLAUDE_CONFIG_DIR:-}" >> "$CLAUDE_STUB_CAPTURE"
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
ISOLATED_CLAUDE_CONFIG="$INTEGRATION_HOME/config"
STATE_PATH="$INTEGRATION_HOME/state.json"
CREDENTIALS="$ALGOMIM_HOME/credentials"
CLI="$ALGOMIM_HOME/bin/algomim"
assert_file "$SETTINGS_PATH" "installer must write the session settings"
[ -d "$ISOLATED_CLAUDE_CONFIG" ] || fail "installer must create the isolated Claude Code config directory"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  Darwin*) assert_equal "700" "$(stat -f '%Lp' "$ISOLATED_CLAUDE_CONFIG")" "isolated Claude Code config must use mode 700" ;;
  *) assert_equal "700" "$(stat -c '%a' "$ISOLATED_CLAUDE_CONFIG")" "isolated Claude Code config must use mode 700" ;;
esac
assert_file "$STATE_PATH" "installer must write the integration state"
assert_file "$CLI" "installer must install the Algomim CLI"

grep -q '"model"[[:space:]]*:[[:space:]]*"algomim"' "$SETTINGS_PATH" || fail "settings must select the Algomim model"
grep -q '"availableModels"[[:space:]]*:[[:space:]]*\[[[:space:]]*"algomim"[[:space:]]*\]' "$SETTINGS_PATH" || fail "settings must allow only the Algomim model"
assert_equal "https://pilot.example.com" "$(json_field ANTHROPIC_BASE_URL "$SETTINGS_PATH")" "settings must record the service-root base URL"
assert_equal "algomim" "$(json_field ANTHROPIC_MODEL "$SETTINGS_PATH")" "settings must select the Algomim model for the main session"
assert_equal "algomim" "$(json_field ANTHROPIC_CUSTOM_MODEL_OPTION "$SETTINGS_PATH")" "settings must add the Algomim custom model option"
assert_equal "Algomim" "$(json_field ANTHROPIC_CUSTOM_MODEL_OPTION_NAME "$SETTINGS_PATH")" "settings must label the custom model option"
assert_equal "Algomim Model API" "$(json_field ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION "$SETTINGS_PATH")" "settings must describe the custom model option"
assert_equal "0" "$(json_field CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY "$SETTINGS_PATH")" "settings must disable gateway model discovery"
assert_equal "algomim" "$(json_field CLAUDE_CODE_SUBAGENT_MODEL "$SETTINGS_PATH")" "settings must redirect subagents"
assert_equal "1" "$(json_field CLAUDE_CODE_SUBPROCESS_ENV_SCRUB "$SETTINGS_PATH")" "settings must scrub the credential from child processes"
for family_pin in ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL; do
  ! grep -q "\"$family_pin\"" "$SETTINGS_PATH" || fail "settings must not define $family_pin"
done
grep -F "$KEY" "$SETTINGS_PATH" >/dev/null 2>&1 && fail "settings must not contain the API key"
assert_equal "claude-code" "$(json_field integration "$STATE_PATH")" "state must record the integration id"
assert_equal "0.3.5" "$(json_field version "$STATE_PATH")" "state must record the release version"
assert_equal "https://pilot.example.com" "$(json_field baseUrl "$STATE_PATH")" "state must record the service-root base URL"

cmp -s "$TEST_ROOT/normal-claude-settings.before" "$NORMAL_CLAUDE_SETTINGS" || fail "install must not modify normal Claude Code settings"

sh "$CLI" doctor claude --offline >/dev/null || fail "doctor claude --offline must pass after install"

CLAUDE_STUB_CAPTURE="$CAPTURE"
export CLAUDE_STUB_CAPTURE
sh "$CLI" run claude -- --version >/dev/null || fail "run claude must exit with the client exit code"
grep -F -- "--settings" "$CAPTURE" >/dev/null || fail "run claude must pass the settings file"
grep -F "$SETTINGS_PATH" "$CAPTURE" >/dev/null || fail "run claude must point at the installed settings"
grep -F -- "--version" "$CAPTURE" >/dev/null || fail "run claude must forward passthrough arguments"
grep -F "TOKEN=$KEY" "$CAPTURE" >/dev/null || fail "run claude must inject the token into the process environment"
grep -F "CONFIG=$ISOLATED_CLAUDE_CONFIG" "$CAPTURE" >/dev/null || fail "run claude must isolate Claude Code user state inside the integration"
grep '^ARGS=' "$CAPTURE" | grep -F "$KEY" >/dev/null 2>&1 && fail "run claude must never place the token on the command line"
cmp -s "$TEST_ROOT/normal-claude-settings.before" "$NORMAL_CLAUDE_SETTINGS" || fail "run must not modify normal Claude Code settings"

sh "$CLI" uninstall claude >/dev/null
[ ! -d "$INTEGRATION_HOME" ] || fail "uninstall claude must remove only the integration"
assert_file "$NORMAL_CLAUDE_SETTINGS" "uninstall must preserve normal Claude Code settings"
cmp -s "$TEST_ROOT/normal-claude-settings.before" "$NORMAL_CLAUDE_SETTINGS" || fail "uninstall must leave normal Claude Code settings unchanged"
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
