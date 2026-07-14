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

warn() {
  printf '[warn] %s\n' "$1" >&2
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
  BASE_URL=$(sed -n 's/^[[:space:]]*base_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$PROFILE_PATH" | head -n 1)
  if [ -n "$BASE_URL" ]; then
    ok "Profile base_url is set to $BASE_URL"
    if [ -s "$KEY_PATH" ] && command -v curl >/dev/null 2>&1; then
      if curl -fsSL -H "Authorization: Bearer $(cat "$KEY_PATH" | tr -d '\r\n')" "$BASE_URL/models" >/dev/null 2>&1; then
        ok "Model API responded to /models."
      else
        warn "Could not verify /models. Check network, base_url, and API key."
      fi
    fi
  else
    fail "Profile base_url is missing."
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

exit 0

