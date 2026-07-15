#!/usr/bin/env sh
set -eu

fail() {
  printf '[fail] %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  expected="$1"
  actual="$2"
  message="$3"
  [ "$expected" = "$actual" ] || fail "$message"
}

assert_file() {
  [ -f "$1" ] || fail "$2"
}

profile_key() {
  path="$1"
  profile="$2"
  awk -v wanted="$profile" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^\[[^][]+\]$/) {
        section = substr(line, 2, length(line) - 2)
        next
      }
      if (section == wanted && line ~ /^api_key[[:space:]]*=/) {
        sub(/^api_key[[:space:]]*=[[:space:]]*/, "", line)
        print line
        exit
      }
    }
  ' "$path"
}

file_mode() {
  if mode=$(stat -c '%a' "$1" 2>/dev/null); then
    printf '%s' "$mode"
    return
  fi
  stat -f '%Lp' "$1"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL="$REPO_ROOT/codex/install.sh"
UNINSTALL="$REPO_ROOT/codex/uninstall.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' HUP INT TERM EXIT

DEFAULT_KEY="test-key-default-000000"
WORK_KEY="test-key-work-000000"
OVERRIDE_KEY="test-key-override-000000"
LEGACY_KEY="test-key-legacy-000000"
CODEX_HOME="$TEST_ROOT/codex"
ALGOMIM_HOME="$TEST_ROOT/algomim"
export CODEX_HOME ALGOMIM_HOME
unset ALGOMIM_API_KEY ALGOMIM_PROFILE 2>/dev/null || true

INSTALL_OUTPUT=$(sh "$INSTALL" --api-key "$DEFAULT_KEY" --credential-profile default 2>&1)
CREDENTIALS="$ALGOMIM_HOME/credentials"
assert_file "$CREDENTIALS" "fresh install must create shared credentials"
assert_equal "$DEFAULT_KEY" "$(profile_key "$CREDENTIALS" default)" "default profile must be written"
[ ! -e "$CODEX_HOME/algomim.key" ] || fail "fresh install must not create a Codex-owned key"
case "$INSTALL_OUTPUT" in *"$DEFAULT_KEY"*) fail "install output must not contain the credential" ;; esac
if grep -R -F "$DEFAULT_KEY" "$CODEX_HOME" >/dev/null 2>&1; then
  fail "Codex artifacts must not embed the credential"
fi
STATE_PATH="$ALGOMIM_HOME/integrations/codex/state.json"
assert_file "$STATE_PATH" "installer must record integration state"
STATE_VERSION=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_PATH")
assert_equal "0.1.0" "$STATE_VERSION" "installer must record its release version"
grep -F "$DEFAULT_KEY" "$STATE_PATH" >/dev/null 2>&1 && fail "installation state must not contain credential"
for name in install.sh update.sh doctor.sh uninstall.sh release.json; do
  assert_file "$ALGOMIM_HOME/integrations/codex/$name" "installer must write lifecycle file $name"
done
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) assert_equal "600" "$(file_mode "$CREDENTIALS")" "credential file mode must be 600" ;;
esac
assert_equal "$DEFAULT_KEY" "$($CODEX_HOME/algomim-auth.sh)" "auth helper must resolve the stored profile"

ALGOMIM_API_KEY="$OVERRIDE_KEY"
export ALGOMIM_API_KEY
assert_equal "$OVERRIDE_KEY" "$($CODEX_HOME/algomim-auth.sh)" "environment key must override the credential file"
unset ALGOMIM_API_KEY

RERUN_OUTPUT=$(sh "$INSTALL" --credential-profile default 2>&1)
assert_equal "$DEFAULT_KEY" "$(profile_key "$CREDENTIALS" default)" "idempotent install must preserve the key"
case "$RERUN_OUTPUT" in *"$DEFAULT_KEY"*) fail "idempotent install must not print the credential" ;; esac

sh "$INSTALL" --api-key "$WORK_KEY" --credential-profile work >/dev/null 2>&1
assert_equal "$DEFAULT_KEY" "$(profile_key "$CREDENTIALS" default)" "adding a profile must preserve default"
assert_equal "$WORK_KEY" "$(profile_key "$CREDENTIALS" work)" "named profile must be written"
ALGOMIM_PROFILE="default"
export ALGOMIM_PROFILE
assert_equal "$DEFAULT_KEY" "$($CODEX_HOME/algomim-auth.sh)" "ALGOMIM_PROFILE must select another profile"
unset ALGOMIM_PROFILE

sh "$UNINSTALL" --credential-profile default >/dev/null
assert_file "$CREDENTIALS" "uninstall must preserve shared credentials"
[ ! -e "$CODEX_HOME/algomim.config.toml" ] || fail "uninstall must remove the Codex profile"
[ ! -e "$ALGOMIM_HOME/integrations/codex" ] || fail "uninstall must remove lifecycle state"

sh "$UNINSTALL" --credential-profile default --remove-credential >/dev/null
[ -z "$(profile_key "$CREDENTIALS" default)" ] || fail "explicit removal must delete the selected profile"
assert_equal "$WORK_KEY" "$(profile_key "$CREDENTIALS" work)" "explicit removal must preserve other profiles"

LEGACY_ROOT="$TEST_ROOT/legacy"
CODEX_HOME="$LEGACY_ROOT/codex"
ALGOMIM_HOME="$LEGACY_ROOT/algomim"
export CODEX_HOME ALGOMIM_HOME
mkdir -p "$CODEX_HOME"
umask 077
printf '%s' "$LEGACY_KEY" > "$CODEX_HOME/algomim.key"
MIGRATION_OUTPUT=$(sh "$INSTALL" --credential-profile default 2>&1)
LEGACY_CREDENTIALS="$ALGOMIM_HOME/credentials"
assert_equal "$LEGACY_KEY" "$(profile_key "$LEGACY_CREDENTIALS" default)" "legacy key must migrate"
[ ! -e "$CODEX_HOME/algomim.key" ] || fail "legacy key must be removed after verified migration"
case "$MIGRATION_OUTPUT" in *"$LEGACY_KEY"*) fail "migration output must not contain the credential" ;; esac

ENVIRONMENT_ROOT="$TEST_ROOT/environment-only"
CODEX_HOME="$ENVIRONMENT_ROOT/codex"
ALGOMIM_HOME="$ENVIRONMENT_ROOT/algomim"
ALGOMIM_API_KEY="$OVERRIDE_KEY"
export CODEX_HOME ALGOMIM_HOME ALGOMIM_API_KEY
ENVIRONMENT_OUTPUT=$(sh "$INSTALL" --credential-profile default 2>&1)
[ ! -e "$ALGOMIM_HOME/credentials" ] || fail "environment override must not be persisted"
assert_equal "$OVERRIDE_KEY" "$($CODEX_HOME/algomim-auth.sh)" "environment-only auth must resolve"
case "$ENVIRONMENT_OUTPUT" in *"$OVERRIDE_KEY"*) fail "environment credential must not be printed" ;; esac
grep -F "$OVERRIDE_KEY" "$ALGOMIM_HOME/integrations/codex/state.json" >/dev/null 2>&1 && fail "environment credential must not be written to state"
unset ALGOMIM_API_KEY

if find "$TEST_ROOT" -name '.credentials.*.tmp' -o -name '.credentials.*.bak' | grep . >/dev/null 2>&1; then
  fail "atomic credential updates must not leave temporary files"
fi

printf '[ok] POSIX credential contract tests passed.\n'
rm -rf "$TEST_ROOT"
trap - HUP INT TERM EXIT
