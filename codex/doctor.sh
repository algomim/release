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
CODEX_HOME="${CODEX_HOME:-}"

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
    sed 's/\\r//g; s/\\t/	/g; s/\\"/"/g; s/\\\\/\\/g'
}

json_number_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$path" | head -n 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  shasum -a 256 "$1" | awk '{print $1}'
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
INTEGRATION_HOME="$ALGOMIM_HOME/integrations/codex"
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
STATE_CODEX_HOME=""
STATE_CREDENTIAL_PROFILE=""
if [ -f "$STATE_PATH" ]; then
  STATE_SCHEMA=$(json_number_field schemaVersion "$STATE_PATH")
  STATE_INTEGRATION=$(json_field integration "$STATE_PATH")
  STATE_VERSION=$(json_field version "$STATE_PATH")
  STATE_CODEX_HOME=$(json_field codexHome "$STATE_PATH")
  STATE_CREDENTIAL_PROFILE=$(json_field credentialProfile "$STATE_PATH")
  if [ "$STATE_SCHEMA" = "1" ] && [ "$STATE_INTEGRATION" = "codex" ] &&
    printf '%s' "$STATE_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    ok "Installation state reports Codex integration version $STATE_VERSION."
  else
    fail "Codex installation state has an unsupported contract."
  fi
else
  fail "Codex installation state is missing: $STATE_PATH"
fi

if [ -z "$CODEX_HOME" ]; then
  CODEX_HOME="${STATE_CODEX_HOME:-$HOME/.codex}"
fi
if [ -d "$CODEX_HOME" ]; then
  CODEX_HOME=$(CDPATH= cd -- "$CODEX_HOME" && pwd)
fi
if [ -z "$CREDENTIAL_PROFILE" ]; then
  CREDENTIAL_PROFILE="${STATE_CREDENTIAL_PROFILE:-default}"
fi

PROFILE_PATH="$CODEX_HOME/algomim.config.toml"
CATALOG_PATH="$CODEX_HOME/algomim-models.json"
CATALOG_LOCK_PATH="$CODEX_HOME/algomim-models.lock.json"
LEGACY_KEY_PATH="$CODEX_HOME/algomim.key"
AUTH_SCRIPT_PATH="$CODEX_HOME/algomim-auth.sh"
CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"

if [ -n "$STATE_CODEX_HOME" ] && [ "$STATE_CODEX_HOME" != "$CODEX_HOME" ]; then
  fail "Installation state points to a different CODEX_HOME."
fi

RELEASE_CONTRACT="$INTEGRATION_HOME/release.json"
if [ -f "$RELEASE_CONTRACT" ] &&
  [ "$(json_field integration "$RELEASE_CONTRACT")" = "codex" ] &&
  [ "$(json_field version "$RELEASE_CONTRACT")" = "$STATE_VERSION" ]; then
  ok "Installed release contract matches the recorded version."
else
  fail "Installed release contract is missing or does not match the recorded version."
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

if command -v codex >/dev/null 2>&1; then
  ok "Codex CLI is available."
else
  fail "Codex CLI is not available on PATH."
fi

if [ -f "$PROFILE_PATH" ]; then
  ok "Profile exists: $PROFILE_PATH"
else
  fail "Profile is missing: $PROFILE_PATH"
fi

if [ -f "$CATALOG_PATH" ]; then
  if grep -q '"slug"[[:space:]]*:[[:space:]]*"algomim"' "$CATALOG_PATH"; then
    ok "Model catalog contains algomim."
  else
    fail "Model catalog does not contain algomim."
  fi
else
  fail "Model catalog is missing: $CATALOG_PATH"
fi

if [ -f "$CATALOG_PATH" ] && [ -f "$CATALOG_LOCK_PATH" ]; then
  EXPECTED_CATALOG_HASH=$(json_field catalogSha256 "$CATALOG_LOCK_PATH" | tr 'A-F' 'a-f')
  CATALOG_GENERATOR=$(json_field generator "$CATALOG_LOCK_PATH")
  ACTUAL_CATALOG_HASH=$(sha256_file "$CATALOG_PATH" | tr 'A-F' 'a-f')
  if printf '%s' "$EXPECTED_CATALOG_HASH" | grep -Eq '^[a-f0-9]{64}$' &&
    [ "$CATALOG_GENERATOR" = "@algomim/inference/codex-model-catalog" ] &&
    [ "$ACTUAL_CATALOG_HASH" = "$EXPECTED_CATALOG_HASH" ]; then
    ok "Model catalog checksum is valid."
  else
    fail "Model catalog checksum does not match its lock file."
  fi
else
  fail "Model catalog lock is missing: $CATALOG_LOCK_PATH"
fi

if [ -x "$AUTH_SCRIPT_PATH" ]; then
  ok "Auth helper exists and is executable."
else
  fail "Auth helper is missing or not executable: $AUTH_SCRIPT_PATH"
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

if [ -f "$LEGACY_KEY_PATH" ]; then
  warn "Legacy credential remains at $LEGACY_KEY_PATH. Run the installer to migrate it."
fi

if [ -x "$AUTH_SCRIPT_PATH" ] && [ -n "$TOKEN" ]; then
  if RESOLVED=$("$AUTH_SCRIPT_PATH" 2>/dev/null) && [ "$RESOLVED" = "$TOKEN" ]; then
    ok "Auth helper resolves the selected credential."
  else
    fail "Auth helper could not resolve the selected credential."
  fi
fi

BASE_URL=""
if [ -f "$PROFILE_PATH" ]; then
  if grep -q '^[[:space:]]*model[[:space:]]*=[[:space:]]*"algomim"[[:space:]]*$' "$PROFILE_PATH"; then
    ok "Profile selects the algomim model."
  else
    fail "Profile does not select the algomim model."
  fi

  if grep -q '^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"algomim"[[:space:]]*$' "$PROFILE_PATH"; then
    ok "Profile selects the Algomim provider."
  else
    fail "Profile does not select the Algomim provider."
  fi

  if grep -q '^[[:space:]]*wire_api[[:space:]]*=[[:space:]]*"responses"[[:space:]]*$' "$PROFILE_PATH"; then
    ok "Profile uses the Responses wire API."
  else
    fail "Profile does not use the Responses wire API."
  fi

  if awk '
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
  ' "$PROFILE_PATH"; then
    ok "Profile disables unsupported Codex personality injection."
  else
    fail "Profile does not disable unsupported Codex personality injection."
  fi

  BASE_URL=$(sed -n 's/^[[:space:]]*base_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$PROFILE_PATH" | head -n 1)
  if [ -n "$BASE_URL" ]; then
    ok "Profile base_url is set to $BASE_URL"
  else
    fail "Profile base_url is missing."
  fi
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
    if HTTP_STATUS=$(curl -sS --config "$CURL_CONFIG" -o "$RESPONSE_FILE" -w '%{http_code}' "$BASE_URL/models"); then
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
      fail "Could not reach the Model API. Check network and base_url."
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
