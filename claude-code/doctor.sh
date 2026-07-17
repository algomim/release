#!/usr/bin/env sh
set -eu

FAILED=0
CREDENTIAL_PROFILE="${ALGOMIM_PROFILE:-}"
SKIP_API_CHECK="0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --credential-profile)
      CREDENTIAL_PROFILE="${2:-}"
      shift 2
      ;;
    --skip-api-check)
      SKIP_API_CHECK="1"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

ALGOMIM_HOME="${ALGOMIM_HOME:-$HOME/.algomim}"

ok() {
  printf '[ok] %s\n' "$1"
}

warn() {
  printf '[warn] %s\n' "$1" >&2
}

fail() {
  printf '[fail] %s\n' "$1" >&2
  FAILED=1
}

json_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -n 1 |
    sed 's/\\r//g; s/\\t/	/g; s/\\"/"/g; s/\\\\/\\/g'
}

json_number_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$path" | head -n 1
}

credential_mode() {
  path="$1"
  if mode=$(stat -c '%a' "$path" 2>/dev/null); then
    printf '%s' "$mode"
    return
  fi
  stat -f '%Lp' "$path" 2>/dev/null
}

mkdir -p "$ALGOMIM_HOME"
ALGOMIM_HOME=$(CDPATH= cd -- "$ALGOMIM_HOME" && pwd)
INTEGRATION_HOME="$ALGOMIM_HOME/integrations/claude-code"
CREDENTIAL_HELPER="$INTEGRATION_HOME/credential-store.sh"
if [ ! -f "$CREDENTIAL_HELPER" ]; then
  CREDENTIAL_HELPER="$ALGOMIM_HOME/cli/credential-store.sh"
fi
if [ ! -f "$CREDENTIAL_HELPER" ]; then
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || printf '')
  CREDENTIAL_HELPER="$SCRIPT_DIR/../shared/credential-store.sh"
fi
[ -f "$CREDENTIAL_HELPER" ] || {
  echo "Algomim credential helper is missing. Run the installer again." >&2
  exit 1
}
. "$CREDENTIAL_HELPER"
STATE_PATH="$INTEGRATION_HOME/state.json"
STATE_VERSION=""
STATE_CREDENTIAL_PROFILE=""
STATE_BASE_URL=""
if [ -f "$STATE_PATH" ]; then
  STATE_SCHEMA=$(json_number_field schemaVersion "$STATE_PATH")
  STATE_INTEGRATION=$(json_field integration "$STATE_PATH")
  STATE_VERSION=$(json_field version "$STATE_PATH")
  STATE_CREDENTIAL_PROFILE=$(json_field credentialProfile "$STATE_PATH")
  STATE_BASE_URL=$(json_field baseUrl "$STATE_PATH")
  if [ "$STATE_SCHEMA" = "1" ] && [ "$STATE_INTEGRATION" = "claude-code" ] &&
    printf '%s' "$STATE_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    ok "Installation state reports Claude Code integration version $STATE_VERSION."
  else
    fail "Claude Code installation state has an unsupported contract."
  fi
else
  fail "Claude Code installation state is missing: $STATE_PATH"
fi

if [ -z "$CREDENTIAL_PROFILE" ]; then
  CREDENTIAL_PROFILE="${STATE_CREDENTIAL_PROFILE:-default}"
fi

SETTINGS_PATH="$INTEGRATION_HOME/settings.json"
CLAUDE_CONFIG_DIR_PATH="$INTEGRATION_HOME/config"
CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"

RELEASE_CONTRACT="$INTEGRATION_HOME/release.json"
MINIMUM_ALGOMIM_CLI_VERSION=""
if [ -f "$RELEASE_CONTRACT" ] &&
  [ "$(json_field integration "$RELEASE_CONTRACT")" = "claude-code" ] &&
  [ "$(json_field version "$RELEASE_CONTRACT")" = "$STATE_VERSION" ]; then
  ok "Installed release contract matches the recorded version."
  MINIMUM_ALGOMIM_CLI_VERSION=$(json_field minimumAlgomimCliVersion "$RELEASE_CONTRACT")
  if ! printf '%s' "$MINIMUM_ALGOMIM_CLI_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "Installed release contract does not declare a valid minimum Algomim CLI version."
    MINIMUM_ALGOMIM_CLI_VERSION=""
  fi
else
  fail "Installed release contract is missing or does not match the recorded version."
fi

if [ -n "$MINIMUM_ALGOMIM_CLI_VERSION" ]; then
  CLI_STATE_PATH="$ALGOMIM_HOME/cli/state.json"
  INSTALLED_CLI_VERSION=""
  if [ -f "$CLI_STATE_PATH" ] && [ "$(json_field product "$CLI_STATE_PATH")" = "algomim-cli" ]; then
    INSTALLED_CLI_VERSION=$(json_field version "$CLI_STATE_PATH")
  fi
  if [ -n "$INSTALLED_CLI_VERSION" ] &&
    printf '%s' "$INSTALLED_CLI_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' &&
    awk -v current="$INSTALLED_CLI_VERSION" -v minimum="$MINIMUM_ALGOMIM_CLI_VERSION" 'BEGIN {
      split(current, c, "."); split(minimum, m, ".")
      for (i = 1; i <= 3; i++) {
        if ((c[i] + 0) > (m[i] + 0)) exit 0
        if ((c[i] + 0) < (m[i] + 0)) exit 1
      }
      exit 0
    }'; then
    ok "Algomim CLI $INSTALLED_CLI_VERSION supports isolated Claude Code sessions."
  else
    fail "Algomim CLI $MINIMUM_ALGOMIM_CLI_VERSION or newer is required. Run the current tag-pinned Claude Code installer once."
  fi
fi

for lifecycle_file in install.sh update.sh doctor.sh uninstall.sh; do
  if [ ! -f "$INTEGRATION_HOME/$lifecycle_file" ]; then
    fail "Installed lifecycle file is missing: $lifecycle_file"
  fi
done

if algomim_credential_validate_profile "$CREDENTIAL_PROFILE" >/dev/null 2>&1; then
  ok "Credential profile name is valid."
else
  fail "Credential profile name is invalid."
fi

if command -v claude >/dev/null 2>&1; then
  CLAUDE_VERSION_OUTPUT=$(claude --version 2>/dev/null || printf '')
  CLAUDE_VERSION=$(printf '%s\n' "$CLAUDE_VERSION_OUTPUT" | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)
  if [ -n "$CLAUDE_VERSION" ] && awk -v current="$CLAUDE_VERSION" -v minimum="2.1.200" 'BEGIN {
      split(current, c, "."); split(minimum, m, ".")
      for (i = 1; i <= 3; i++) {
        if ((c[i] + 0) > (m[i] + 0)) exit 0
        if ((c[i] + 0) < (m[i] + 0)) exit 1
      }
      exit 0
    }'; then
    ok "Claude Code CLI $CLAUDE_VERSION is supported."
  else
    fail "Claude Code CLI 2.1.200 or newer is required."
  fi
else
  fail "Claude Code CLI is not available on PATH."
fi

BASE_URL=""
if [ -f "$SETTINGS_PATH" ]; then
  ok "Settings exist: $SETTINGS_PATH"

  if grep -q '"model"[[:space:]]*:[[:space:]]*"algomim"' "$SETTINGS_PATH"; then
    ok "Settings select the Algomim model."
  else
    fail "Settings do not select algomim."
  fi

  if grep -q '"availableModels"[[:space:]]*:[[:space:]]*\[[[:space:]]*"algomim"[[:space:]]*\]' "$SETTINGS_PATH"; then
    ok "Settings expose only the Algomim model."
  else
    fail "Settings must allow only algomim."
  fi

  for required_env in \
    ANTHROPIC_MODEL \
    ANTHROPIC_CUSTOM_MODEL_OPTION \
    CLAUDE_CODE_SUBAGENT_MODEL; do
    if grep -q "\"$required_env\"[[:space:]]*:[[:space:]]*\"algomim\"" "$SETTINGS_PATH"; then
      ok "Settings set $required_env."
    else
      fail "Settings do not set $required_env to algomim."
    fi
  done
  for expected_setting in \
    'ANTHROPIC_CUSTOM_MODEL_OPTION_NAME|Algomim' \
    'ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION|Algomim Model API' \
    'CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY|0' \
    'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB|1'; do
    setting_name=${expected_setting%%|*}
    setting_value=${expected_setting#*|}
    if grep -q "\"$setting_name\"[[:space:]]*:[[:space:]]*\"$setting_value\"" "$SETTINGS_PATH"; then
      ok "Settings set $setting_name."
    else
      fail "Settings do not set $setting_name to $setting_value."
    fi
  done

  FAMILY_OVERRIDE_FOUND=0
  for family_override in \
    ANTHROPIC_DEFAULT_HAIKU_MODEL \
    ANTHROPIC_DEFAULT_SONNET_MODEL \
    ANTHROPIC_DEFAULT_OPUS_MODEL \
    ANTHROPIC_DEFAULT_FABLE_MODEL; do
    if grep -q "\"$family_override\"[[:space:]]*:" "$SETTINGS_PATH"; then
      fail "Settings must not set $family_override; use the Algomim custom model option instead."
      FAMILY_OVERRIDE_FOUND=1
    fi
  done
  if [ "$FAMILY_OVERRIDE_FOUND" = "0" ]; then
    ok "Settings do not override Claude model families."
  fi

  BASE_URL=$(json_field ANTHROPIC_BASE_URL "$SETTINGS_PATH")
  if [ -n "$BASE_URL" ]; then
    ok "Settings base URL is set to $BASE_URL"
    case "${BASE_URL%/}" in
      */v1) fail "Settings base URL must be the service root and must not end in /v1." ;;
    esac
    if [ -n "$STATE_BASE_URL" ] && [ "$STATE_BASE_URL" != "$BASE_URL" ]; then
      fail "Settings base URL does not match the recorded installation state."
    fi
  else
    fail "Settings do not set ANTHROPIC_BASE_URL."
  fi

  if grep -q '"ANTHROPIC_AUTH_TOKEN"' "$SETTINGS_PATH"; then
    fail "Settings must not embed ANTHROPIC_AUTH_TOKEN. Remove it and rely on algomim run claude."
  fi
else
  fail "Settings are missing: $SETTINGS_PATH"
fi

if [ -L "$CLAUDE_CONFIG_DIR_PATH" ]; then
  fail "Isolated Claude Code config directory must not be a symbolic link: $CLAUDE_CONFIG_DIR_PATH"
elif [ -d "$CLAUDE_CONFIG_DIR_PATH" ]; then
  CONFIG_MODE=$(credential_mode "$CLAUDE_CONFIG_DIR_PATH" || printf '')
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ok "Claude Code user state is isolated at $CLAUDE_CONFIG_DIR_PATH" ;;
    *)
      if [ "$CONFIG_MODE" = "700" ]; then
        ok "Claude Code user state is isolated at $CLAUDE_CONFIG_DIR_PATH"
      else
        fail "Isolated Claude Code config directory permissions are too broad (mode ${CONFIG_MODE:-unknown}); expected 700."
      fi
      ;;
  esac
else
  fail "Isolated Claude Code config directory is missing: $CLAUDE_CONFIG_DIR_PATH"
fi

TOKEN=""
if [ -n "${ALGOMIM_API_KEY:-}" ]; then
  if printf '%s' "$ALGOMIM_API_KEY" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1; then
    fail "ALGOMIM_API_KEY contains control characters."
  else
    TOKEN="$ALGOMIM_API_KEY"
    ok "Credential resolves from ALGOMIM_API_KEY."
  fi
elif [ -L "$CREDENTIALS_PATH" ]; then
  fail "Credential file must not be a symbolic link: $CREDENTIALS_PATH"
elif TOKEN=$(algomim_credential_get "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE" 2>/dev/null); then
  ok "Credential profile '$CREDENTIAL_PROFILE' exists in shared Algomim credentials."
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      ok "Credential permissions are managed by Windows ACLs."
      ;;
    *)
      MODE=$(credential_mode "$CREDENTIALS_PATH" || printf '')
      case "$MODE" in
        600|400)
          ok "Credential file permissions are restricted ($MODE)."
          ;;
        *)
          fail "Credential file permissions are too broad (mode ${MODE:-unknown}); expected 600."
          ;;
      esac
      ;;
  esac
else
  fail "No credential is available through ALGOMIM_API_KEY or $CREDENTIALS_PATH"
fi

NORMAL_CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
NORMAL_CLAUDE_SETTINGS="$NORMAL_CLAUDE_CONFIG_DIR/settings.json"
if [ -f "$NORMAL_CLAUDE_SETTINGS" ] &&
  grep -q '"model"[[:space:]]*:[[:space:]]*"algomim"' "$NORMAL_CLAUDE_SETTINGS"; then
  warn "Normal Claude settings still select algomim from an earlier session: $NORMAL_CLAUDE_SETTINGS. Remove the top-level model field to restore Claude's own default."
fi

if [ "$SKIP_API_CHECK" = "1" ]; then
  ok "Skipped live Model API check."
elif [ -n "$BASE_URL" ] && [ -n "$TOKEN" ]; then
  if command -v curl >/dev/null 2>&1; then
    umask 077
    RESPONSE_FILE=$(mktemp)
    CURL_CONFIG=$(mktemp)
    trap 'rm -f "$RESPONSE_FILE" "$CURL_CONFIG"' HUP INT TERM EXIT
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$CURL_CONFIG"
    if HTTP_STATUS=$(curl -sS --config "$CURL_CONFIG" -o "$RESPONSE_FILE" -w '%{http_code}' "$BASE_URL/v1/models"); then
      if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
        if grep -q '"id"[[:space:]]*:[[:space:]]*"algomim"' "$RESPONSE_FILE"; then
          ok "Model API responded and exposes algomim."
        else
          fail "Model API responded but does not expose algomim."
        fi
      elif [ "$HTTP_STATUS" = "401" ]; then
        fail "Model API rejected the API key (HTTP 401)."
      else
        fail "Model API check failed (HTTP $HTTP_STATUS)."
      fi
    else
      fail "Could not reach the Model API. Check network and the recorded base URL."
    fi
    rm -f "$RESPONSE_FILE" "$CURL_CONFIG"
    trap - HUP INT TERM EXIT
  else
    fail "curl is required to verify the Model API."
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

exit 0
