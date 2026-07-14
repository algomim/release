#!/usr/bin/env sh
set -eu

FAILED=0
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PROFILE_PATH="$CODEX_HOME/algomim.config.toml"
CATALOG_PATH="$CODEX_HOME/algomim-models.json"
KEY_PATH="$CODEX_HOME/algomim.key"
AUTH_SCRIPT_PATH="$CODEX_HOME/algomim-auth.sh"

ok() {
  printf '[ok] %s\n' "$1"
}

fail() {
  printf '[fail] %s\n' "$1" >&2
  FAILED=1
}

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

if [ -x "$AUTH_SCRIPT_PATH" ]; then
  ok "Auth helper exists."
else
  fail "Auth helper is missing or not executable: $AUTH_SCRIPT_PATH"
fi

if [ -s "$KEY_PATH" ]; then
  ok "API key file exists."
else
  fail "API key file is missing or empty: $KEY_PATH"
fi

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

  BASE_URL=$(sed -n 's/^[[:space:]]*base_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$PROFILE_PATH" | head -n 1)
  if [ -n "$BASE_URL" ]; then
    ok "Profile base_url is set to $BASE_URL"
    if [ -s "$KEY_PATH" ] && command -v curl >/dev/null 2>&1; then
      RESPONSE_FILE=$(mktemp)
      trap 'rm -f "$RESPONSE_FILE"' HUP INT TERM EXIT
      if HTTP_STATUS=$(curl -sS -o "$RESPONSE_FILE" -w '%{http_code}' -H "Authorization: Bearer $(tr -d '\r\n' < "$KEY_PATH")" "$BASE_URL/models"); then
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
      rm -f "$RESPONSE_FILE"
      trap - HUP INT TERM EXIT
    elif ! command -v curl >/dev/null 2>&1; then
      fail "curl is required to verify the Model API."
    fi
  else
    fail "Profile base_url is missing."
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

exit 0
