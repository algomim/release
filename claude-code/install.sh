#!/usr/bin/env sh
set -eu

BASE_URL=""
API_KEY=""
API_KEY_WAS_EXPLICIT="0"
RELEASE_REF=""
RELEASE_VERSION="0.3.4"
CREDENTIAL_PROFILE="${ALGOMIM_PROFILE:-default}"
SKIP_KEY="0"
SKIP_CLI_INSTALL="0"
CLI_PATH_TARGET="profile"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --api-key)
      API_KEY="${2:-}"
      API_KEY_WAS_EXPLICIT="1"
      shift 2
      ;;
    --release-ref)
      RELEASE_REF="${2:-}"
      shift 2
      ;;
    --release-version)
      RELEASE_VERSION="${2:-}"
      shift 2
      ;;
    --credential-profile)
      CREDENTIAL_PROFILE="${2:-}"
      shift 2
      ;;
    --skip-key)
      SKIP_KEY="1"
      shift
      ;;
    --skip-cli-install)
      SKIP_CLI_INSTALL="1"
      shift
      ;;
    --cli-path-target)
      CLI_PATH_TARGET="${2:-}"
      shift 2
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
    */v1)
      printf 'Base URL must be the service root and must not end in /v1.\n' >&2
      return 1
      ;;
  esac
  printf '%s\n' "$value"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g; s//\\r/g'
}

json_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -n 1 |
    sed 's/\\r//g; s/\\t/	/g; s/\\"/"/g; s/\\\\/\\/g'
}

atomic_copy() {
  source="$1"
  destination="$2"
  mode="$3"
  directory=$(dirname "$destination")
  mkdir -p "$directory"
  temporary_path=$(mktemp "$directory/.$(basename "$destination").tmp.XXXXXX")
  cp "$source" "$temporary_path"
  chmod "$mode" "$temporary_path"
  mv -f "$temporary_path" "$destination"
  chmod "$mode" "$destination"
}

install_release_file() (
  name="$1"
  destination="$2"
  mode="$3"

  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$name" ]; then
    atomic_copy "$SCRIPT_DIR/$name" "$destination" "$mode"
    return
  fi

  download_path=$(mktemp)
  trap 'rm -f "$download_path"' HUP INT TERM EXIT
  curl -fsSL "https://raw.githubusercontent.com/algomim/release/$RELEASE_REF/claude-code/$name" -o "$download_path"
  atomic_copy "$download_path" "$destination" "$mode"
  rm -f "$download_path"
  trap - HUP INT TERM EXIT
)

install_shared_release_file() (
  name="$1"
  destination="$2"
  mode="$3"
  if [ -n "$SCRIPT_DIR" ]; then
    if [ -f "$SCRIPT_DIR/$name" ]; then
      atomic_copy "$SCRIPT_DIR/$name" "$destination" "$mode"
      exit 0
    fi
    if [ -f "$SCRIPT_DIR/../shared/$name" ]; then
      atomic_copy "$SCRIPT_DIR/../shared/$name" "$destination" "$mode"
      exit 0
    fi
  fi
  download_path=$(mktemp)
  trap 'rm -f "$download_path"' HUP INT TERM EXIT
  curl -fsSL "https://raw.githubusercontent.com/algomim/release/$RELEASE_REF/shared/$name" -o "$download_path"
  atomic_copy "$download_path" "$destination" "$mode"
  rm -f "$download_path"
  trap - HUP INT TERM EXIT
)

install_algomim_cli() (
  installer=""
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../cli/install.sh" ]; then
    installer="$SCRIPT_DIR/../cli/install.sh"
  fi
  download_path=""
  if [ -z "$installer" ]; then
    download_path=$(mktemp)
    trap 'rm -f "$download_path"' HUP INT TERM EXIT
    curl -fsSL "https://raw.githubusercontent.com/algomim/release/$RELEASE_REF/cli/install.sh" -o "$download_path"
    installer="$download_path"
  fi
  sh "$installer" \
    --algomim-home "$ALGOMIM_HOME" \
    --release-ref "$RELEASE_REF" \
    --release-version "$RELEASE_VERSION" \
    --path-target "$CLI_PATH_TARGET"
  if [ -n "$download_path" ]; then
    rm -f "$download_path"
    trap - HUP INT TERM EXIT
  fi
)

DEFAULT_BASE_URL="https://api.algomim.com"
if [ -z "$BASE_URL" ]; then
  BASE_URL="$DEFAULT_BASE_URL"
fi
BASE_URL=$(normalize_base_url "$BASE_URL")

if ! printf '%s' "$RELEASE_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Release version must use MAJOR.MINOR.PATCH format." >&2
  exit 2
fi
if [ -z "$RELEASE_REF" ]; then
  RELEASE_REF="v$RELEASE_VERSION"
fi
if ! printf '%s' "$RELEASE_REF" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
  echo "Release ref contains unsupported characters." >&2
  exit 2
fi

case "$0" in
  sh|-sh|bash|-bash) SCRIPT_DIR="" ;;
  *) SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || printf '') ;;
esac
CREDENTIAL_STORE_SOURCE=""
CREDENTIAL_STORE_IS_TEMPORARY="0"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/credential-store.sh" ]; then
  CREDENTIAL_STORE_SOURCE="$SCRIPT_DIR/credential-store.sh"
elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../shared/credential-store.sh" ]; then
  CREDENTIAL_STORE_SOURCE="$SCRIPT_DIR/../shared/credential-store.sh"
else
  CREDENTIAL_STORE_SOURCE=$(mktemp)
  CREDENTIAL_STORE_IS_TEMPORARY="1"
  trap 'rm -f "$CREDENTIAL_STORE_SOURCE"' HUP INT TERM EXIT
  if ! curl -fsSL "https://raw.githubusercontent.com/algomim/release/$RELEASE_REF/shared/credential-store.sh" -o "$CREDENTIAL_STORE_SOURCE"; then
    rm -f "$CREDENTIAL_STORE_SOURCE"
    trap - HUP INT TERM EXIT
    exit 1
  fi
fi
. "$CREDENTIAL_STORE_SOURCE"
if [ "$CREDENTIAL_STORE_IS_TEMPORARY" = "1" ]; then
  rm -f "$CREDENTIAL_STORE_SOURCE"
  trap - HUP INT TERM EXIT
fi

algomim_credential_validate_profile "$CREDENTIAL_PROFILE"

ALGOMIM_HOME="${ALGOMIM_HOME:-$HOME/.algomim}"
mkdir -p "$ALGOMIM_HOME"
chmod 700 "$ALGOMIM_HOME"
ALGOMIM_HOME=$(CDPATH= cd -- "$ALGOMIM_HOME" && pwd)

CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"
INTEGRATION_HOME="$ALGOMIM_HOME/integrations/claude-code"
SETTINGS_PATH="$INTEGRATION_HOME/settings.json"
STATE_PATH="$INTEGRATION_HOME/state.json"

log "Using API base URL $BASE_URL"
log "Using credential profile '$CREDENTIAL_PROFILE' in $CREDENTIALS_PATH"

STORED_API_KEY=""
if STORED_API_KEY=$(algomim_credential_get "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE"); then
  :
else
  credential_status=$?
  if [ "$credential_status" -eq 1 ]; then
    STORED_API_KEY=""
  else
    exit "$credential_status"
  fi
fi

if [ "$SKIP_KEY" != "1" ]; then
  if [ "$API_KEY_WAS_EXPLICIT" = "1" ]; then
    API_KEY=$(algomim_api_key_normalize "$API_KEY")
    algomim_credential_set "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE" "$API_KEY"
    STORED_API_KEY=$(algomim_credential_get "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE")
    log "Stored credential profile '$CREDENTIAL_PROFILE' at $CREDENTIALS_PATH"
  elif [ -n "$STORED_API_KEY" ]; then
    chmod 700 "$ALGOMIM_HOME"
    chmod 600 "$CREDENTIALS_PATH"
    log "Reusing credential profile '$CREDENTIAL_PROFILE'."
  elif [ -n "${ALGOMIM_API_KEY:-}" ]; then
    algomim_api_key_normalize "$ALGOMIM_API_KEY" >/dev/null
    log "Using ALGOMIM_API_KEY from the environment without persisting it."
  else
    API_KEY=$(algomim_read_required_secret 'Algomim API key: ')
    algomim_credential_set "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE" "$API_KEY"
    STORED_API_KEY=$(algomim_credential_get "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE")
    log "Stored credential profile '$CREDENTIAL_PROFILE' at $CREDENTIALS_PATH"
  fi
fi

if [ -z "${ALGOMIM_API_KEY:-}" ]; then
  if ! algomim_credential_get "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE" >/dev/null 2>&1; then
    printf '[warn] No Algomim credential is available. Set ALGOMIM_API_KEY or run this installer again without --skip-key.\n' >&2
  fi
fi

mkdir -p "$INTEGRATION_HOME"
chmod 700 "$INTEGRATION_HOME"

BASE_URL_JSON=$(json_escape "$BASE_URL")
GENERATED_SETTINGS=$(mktemp)
cat > "$GENERATED_SETTINGS" <<EOF
{
  "model": "algomim",
  "availableModels": ["algomim"],
  "env": {
    "ANTHROPIC_BASE_URL": "$BASE_URL_JSON",
    "ANTHROPIC_MODEL": "algomim",
    "ANTHROPIC_CUSTOM_MODEL_OPTION": "algomim",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Algomim",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "Algomim Model API",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "0",
    "CLAUDE_CODE_SUBAGENT_MODEL": "algomim",
    "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1"
  }
}
EOF
atomic_copy "$GENERATED_SETTINGS" "$SETTINGS_PATH" 600
rm -f "$GENERATED_SETTINGS"
log "Installed Claude Code settings at $SETTINGS_PATH"

for release_file in install.sh update.sh doctor.sh uninstall.sh release.json; do
  case "$release_file" in
    *.sh) release_mode=700 ;;
    *) release_mode=600 ;;
  esac
  install_release_file "$release_file" "$INTEGRATION_HOME/$release_file" "$release_mode"
done
install_shared_release_file "credential-store.sh" "$INTEGRATION_HOME/credential-store.sh" 600

NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
INSTALLED_AT="$NOW"
if [ -f "$STATE_PATH" ]; then
  existing_integration=$(json_field integration "$STATE_PATH")
  existing_installed_at=$(json_field installedAt "$STATE_PATH")
  if [ "$existing_integration" != "claude-code" ] || [ -z "$existing_installed_at" ]; then
    echo "Existing Claude Code installation state is invalid: $STATE_PATH" >&2
    exit 1
  fi
  INSTALLED_AT="$existing_installed_at"
fi

GENERATED_STATE=$(mktemp)
cat > "$GENERATED_STATE" <<EOF
{
  "schemaVersion": 1,
  "integration": "claude-code",
  "version": "$(json_escape "$RELEASE_VERSION")",
  "channel": "pilot",
  "releaseRepository": "algomim/release",
  "releaseTag": "$(json_escape "$RELEASE_REF")",
  "baseUrl": "$(json_escape "$BASE_URL")",
  "credentialProfile": "$(json_escape "$CREDENTIAL_PROFILE")",
  "installedAt": "$(json_escape "$INSTALLED_AT")",
  "updatedAt": "$(json_escape "$NOW")"
}
EOF
atomic_copy "$GENERATED_STATE" "$STATE_PATH" 600
rm -f "$GENERATED_STATE"
log "Recorded Claude Code integration version $RELEASE_VERSION at $STATE_PATH"

if [ "$SKIP_KEY" != "1" ] && [ "$SKIP_CLI_INSTALL" != "1" ]; then
  install_algomim_cli
fi

if command -v claude >/dev/null 2>&1; then
  log "Claude Code CLI found."
else
  printf '[warn] Claude Code CLI was not found on PATH. Install Claude Code before running algomim run claude.\n' >&2
fi

printf '\nAlgomim Claude Code integration is ready.\n'
printf 'Start it with:\n'
printf '  algomim run claude\n\n'
printf "Normal 'claude' still uses your existing Anthropic account. Nothing was written to ~/.claude.\n"
