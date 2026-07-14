#!/usr/bin/env sh
set -eu

BASE_URL=""
API_KEY=""
RELEASE_REF="main"
SKIP_KEY="0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --api-key)
      API_KEY="${2:-}"
      shift 2
      ;;
    --release-ref)
      RELEASE_REF="${2:-main}"
      shift 2
      ;;
    --skip-key)
      SKIP_KEY="1"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

log() {
  printf '[algomim] %s\n' "$1"
}

trim_value() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

has_interactive_terminal() {
  [ -r /dev/tty ] && [ -w /dev/tty ] && stty -g >/dev/null 2>&1 < /dev/tty
}

read_prompt() {
  prompt="$1"
  answer=""

  if ! has_interactive_terminal; then
    return 1
  fi

  printf '%s' "$prompt" > /dev/tty
  if ! IFS= read -r answer < /dev/tty; then
    return 1
  fi
  printf '%s' "$answer"
}

read_required_secret() {
  prompt="$1"

  if ! has_interactive_terminal; then
    echo "Interactive API key input requires a terminal. Re-run interactively or pass --api-key." >&2
    exit 2
  fi

  while :; do
    printf '%s' "$prompt" > /dev/tty
    stty -echo < /dev/tty
    trap 'stty echo < /dev/tty; printf "\n" > /dev/tty' HUP INT TERM EXIT
    IFS= read -r secret < /dev/tty || true
    stty echo < /dev/tty
    trap - HUP INT TERM EXIT
    printf '\n' > /dev/tty

    secret=$(trim_value "$secret")
    if [ -n "$secret" ]; then
      printf '%s' "$secret"
      return
    fi

    printf '[warn] API key cannot be empty. Press Ctrl+C to cancel.\n' > /dev/tty
  done
}

has_usable_key_file() {
  [ -f "$1" ] && [ -n "$(tr -d '[:space:]' < "$1")" ]
}

normalize_base_url() {
  value=$(printf '%s' "$1" | sed 's:/*$::')
  case "$value" in
    http://*|https://*) ;;
    *)
      echo "Base URL must start with http:// or https://." >&2
      exit 2
      ;;
  esac

  case "$value" in
    */v1) printf '%s\n' "$value" ;;
    *) printf '%s/v1\n' "$value" ;;
  esac
}

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_single_quote() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

DEFAULT_BASE_URL="https://api.algomim.com/v1"
if [ -z "$BASE_URL" ]; then
  BASE_URL="$DEFAULT_BASE_URL"
fi

BASE_URL=$(normalize_base_url "$BASE_URL")
log "Using API base URL $BASE_URL"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_HOME"

PROFILE_PATH="$CODEX_HOME/algomim.config.toml"
CATALOG_PATH="$CODEX_HOME/algomim-models.json"
KEY_PATH="$CODEX_HOME/algomim.key"
AUTH_SCRIPT_PATH="$CODEX_HOME/algomim-auth.sh"

if [ "$SKIP_KEY" != "1" ]; then
  if [ -z "$API_KEY" ]; then
    if has_usable_key_file "$KEY_PATH"; then
      if reuse=$(read_prompt 'Existing Algomim key found. Reuse it? [Y/n]: '); then
        :
      else
        reuse=""
      fi
      case "$reuse" in
        n|N|no|NO|No)
          API_KEY=$(read_required_secret 'New Algomim API key: ')
          ;;
        *)
          log "Reusing existing API key."
          ;;
      esac
    else
      API_KEY=$(read_required_secret 'Algomim API key: ')
    fi
  fi

  if [ -n "$API_KEY" ]; then
    API_KEY=$(trim_value "$API_KEY")
    if [ -z "$API_KEY" ]; then
      echo "API key cannot be empty." >&2
      exit 2
    fi

    umask 077
    printf '%s' "$API_KEY" > "$KEY_PATH"
    chmod 600 "$KEY_PATH" 2>/dev/null || true
    log "Stored API key at $KEY_PATH"
  fi
fi

if ! has_usable_key_file "$KEY_PATH"; then
  echo "[warn] No Algomim API key file found. Run this installer again without --skip-key before starting Codex." >&2
fi

case "$0" in
  sh|-sh|bash|-bash)
    SCRIPT_DIR=""
    ;;
  *)
    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || printf '')
    ;;
esac
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/algomim-models.json" ]; then
  cp "$SCRIPT_DIR/algomim-models.json" "$CATALOG_PATH"
else
  CATALOG_URL="https://raw.githubusercontent.com/algomim/release/$RELEASE_REF/codex/algomim-models.json"
  curl -fsSL "$CATALOG_URL" -o "$CATALOG_PATH"
fi
log "Installed model catalog at $CATALOG_PATH"

cat > "$AUTH_SCRIPT_PATH" <<EOF
#!/usr/bin/env sh
set -eu
KEY_PATH='$(shell_single_quote "$KEY_PATH")'
if [ ! -f "\$KEY_PATH" ]; then
  echo "Algomim key file not found: \$KEY_PATH" >&2
  exit 1
fi
TOKEN=\$(cat "\$KEY_PATH" | tr -d '\\r\\n')
if [ -z "\$TOKEN" ]; then
  echo "Algomim key file is empty: \$KEY_PATH" >&2
  exit 1
fi
printf '%s\\n' "\$TOKEN"
EOF
chmod 700 "$AUTH_SCRIPT_PATH" 2>/dev/null || true
log "Installed auth helper at $AUTH_SCRIPT_PATH"

CATALOG_TOML=$(toml_escape "$CATALOG_PATH")
BASE_URL_TOML=$(toml_escape "$BASE_URL")
AUTH_SCRIPT_TOML=$(toml_escape "$AUTH_SCRIPT_PATH")

cat > "$PROFILE_PATH" <<EOF
model = "algomim"
model_provider = "algomim"
model_catalog_json = "$CATALOG_TOML"
web_search = "disabled"
service_tier = "default"
personality = "none"
model_reasoning_effort = "medium"

[model_providers.algomim]
name = "Algomim"
base_url = "$BASE_URL_TOML"
wire_api = "responses"

[model_providers.algomim.auth]
command = "/bin/sh"
args = ["$AUTH_SCRIPT_TOML"]
timeout_ms = 5000
refresh_interval_ms = 300000
EOF

log "Installed Codex profile at $PROFILE_PATH"

if command -v codex >/dev/null 2>&1; then
  log "Codex CLI found."
else
  echo "[warn] Codex CLI was not found on PATH. Install Codex before running codex --profile algomim." >&2
fi

printf '\nAlgomim Codex profile is ready.\n'
printf 'Start it with:\n'
printf '  codex --profile algomim\n\n'
printf "Normal 'codex' still uses your existing default provider.\n"
