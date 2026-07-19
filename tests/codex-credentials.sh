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
. "$REPO_ROOT/shared/credential-store.sh"
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

INVALID_MULTILINE_KEY='sk-safe
[injected]
api_key = sk-injected'
if algomim_api_key_normalize "$INVALID_MULTILINE_KEY" >/dev/null 2>&1; then
  fail "credential normalization must reject embedded newlines"
fi

INSTALL_OUTPUT=$(sh "$INSTALL" --api-key "$DEFAULT_KEY" --credential-profile default --cli-path-target process 2>&1)
CREDENTIALS="$ALGOMIM_HOME/credentials"
assert_file "$CREDENTIALS" "fresh install must create shared credentials"
assert_equal "$DEFAULT_KEY" "$(profile_key "$CREDENTIALS" default)" "default profile must be written"
[ ! -e "$CODEX_HOME/algomim.key" ] || fail "fresh install must not create a Codex-owned key"
case "$INSTALL_OUTPUT" in *"$DEFAULT_KEY"*) fail "install output must not contain the credential" ;; esac
grep -Eq '^[[:space:]]*web_search[[:space:]]*=[[:space:]]*"live"[[:space:]]*$' \
  "$CODEX_HOME/algomim.config.toml" || fail "installed profile must enable native web search"
awk '
  /^[[:space:]]*\[[^][]+\][[:space:]]*$/ {
    section = $0
    sub(/^[[:space:]]*\[/, "", section)
    sub(/\][[:space:]]*$/, "", section)
    next
  }
  section == "features" &&
    /^[[:space:]]*personality[[:space:]]*=[[:space:]]*false[[:space:]]*$/ {
    found = 1
  }
  END { exit found ? 0 : 1 }
' "$CODEX_HOME/algomim.config.toml" || fail "installed profile must disable unsupported personality injection"
if grep -R -F "$DEFAULT_KEY" "$CODEX_HOME" >/dev/null 2>&1; then
  fail "Codex artifacts must not embed the credential"
fi
STATE_PATH="$ALGOMIM_HOME/integrations/codex/state.json"
assert_file "$STATE_PATH" "installer must record integration state"
STATE_VERSION=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_PATH")
assert_equal "0.3.9" "$STATE_VERSION" "installer must record its release version"
grep -F "$DEFAULT_KEY" "$STATE_PATH" >/dev/null 2>&1 && fail "installation state must not contain credential"
for name in install.sh update.sh doctor.sh uninstall.sh release.json credential-store.sh; do
  assert_file "$ALGOMIM_HOME/integrations/codex/$name" "installer must write lifecycle file $name"
done
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) assert_equal "600" "$(file_mode "$CREDENTIALS")" "credential file mode must be 600" ;;
esac
assert_equal "$DEFAULT_KEY" "$($CODEX_HOME/algomim-auth.sh)" "auth helper must resolve the stored profile"
DOCTOR_BIN="$TEST_ROOT/doctor-bin"
mkdir -p "$DOCTOR_BIN"
cat > "$DOCTOR_BIN/codex" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod 700 "$DOCTOR_BIN/codex"
if ! PATH="$DOCTOR_BIN:$PATH" \
  CODEX_HOME="$TEST_ROOT//codex/" \
  sh "$ALGOMIM_HOME/integrations/codex/doctor.sh" \
  --credential-profile default \
  --skip-api-check >/dev/null 2>&1; then
  fail "doctor must normalize redundant separators in CODEX_HOME"
fi

ALGOMIM_API_KEY="$OVERRIDE_KEY"
export ALGOMIM_API_KEY
assert_equal "$OVERRIDE_KEY" "$($CODEX_HOME/algomim-auth.sh)" "environment key must override the credential file"
unset ALGOMIM_API_KEY

RERUN_OUTPUT=$(sh "$INSTALL" --credential-profile default --cli-path-target process 2>&1)
assert_equal "$DEFAULT_KEY" "$(profile_key "$CREDENTIALS" default)" "idempotent install must preserve the key"
case "$RERUN_OUTPUT" in *"$DEFAULT_KEY"*) fail "idempotent install must not print the credential" ;; esac

sh "$INSTALL" --api-key "$WORK_KEY" --credential-profile work --cli-path-target process >/dev/null 2>&1
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
MIGRATION_OUTPUT=$(sh "$INSTALL" --credential-profile default --cli-path-target process 2>&1)
LEGACY_CREDENTIALS="$ALGOMIM_HOME/credentials"
assert_equal "$LEGACY_KEY" "$(profile_key "$LEGACY_CREDENTIALS" default)" "legacy key must migrate"
[ ! -e "$CODEX_HOME/algomim.key" ] || fail "legacy key must be removed after verified migration"
case "$MIGRATION_OUTPUT" in *"$LEGACY_KEY"*) fail "migration output must not contain the credential" ;; esac

ENVIRONMENT_ROOT="$TEST_ROOT/environment-only"
CODEX_HOME="$ENVIRONMENT_ROOT/codex"
ALGOMIM_HOME="$ENVIRONMENT_ROOT/algomim"
ALGOMIM_API_KEY="$OVERRIDE_KEY"
export CODEX_HOME ALGOMIM_HOME ALGOMIM_API_KEY
ENVIRONMENT_OUTPUT=$(sh "$INSTALL" --credential-profile default --cli-path-target process 2>&1)
[ ! -e "$ALGOMIM_HOME/credentials" ] || fail "environment override must not be persisted"
assert_equal "$OVERRIDE_KEY" "$($CODEX_HOME/algomim-auth.sh)" "environment-only auth must resolve"
case "$ENVIRONMENT_OUTPUT" in *"$OVERRIDE_KEY"*) fail "environment credential must not be printed" ;; esac
grep -F "$OVERRIDE_KEY" "$ALGOMIM_HOME/integrations/codex/state.json" >/dev/null 2>&1 && fail "environment credential must not be written to state"
unset ALGOMIM_API_KEY

FAILURE_ROOT="$TEST_ROOT/download-failure"
mkdir -p "$FAILURE_ROOT/bin" "$FAILURE_ROOT/tmp"
cp "$INSTALL" "$FAILURE_ROOT/install.sh"
cat > "$FAILURE_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env sh
exit 22
EOF
chmod 700 "$FAILURE_ROOT/bin/curl"
if TMPDIR="$FAILURE_ROOT/tmp" \
  CODEX_HOME="$FAILURE_ROOT/codex" \
  ALGOMIM_HOME="$FAILURE_ROOT/algomim" \
  PATH="$FAILURE_ROOT/bin:$PATH" \
  sh "$FAILURE_ROOT/install.sh" --skip-key >/dev/null 2>&1; then
  fail "installer must fail when a release file cannot be downloaded"
fi
if find "$FAILURE_ROOT/tmp" -mindepth 1 -print -quit | grep . >/dev/null 2>&1; then
  fail "failed release downloads must not leave temporary files"
fi

if find "$TEST_ROOT" -name '.credentials.*.tmp' -o -name '.credentials.*.bak' | grep . >/dev/null 2>&1; then
  fail "atomic credential updates must not leave temporary files"
fi

printf '[ok] POSIX credential contract tests passed.\n'
rm -rf "$TEST_ROOT"
trap - HUP INT TERM EXIT
