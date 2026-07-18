#!/usr/bin/env sh
set -eu

BASE_URL=""
API_KEY=""
API_KEY_WAS_EXPLICIT="0"
RELEASE_REF=""
RELEASE_VERSION="0.3.8"
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

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g; s//\\r/g'
}

json_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -n 1 |
    sed 's/\\r//g; s/\\t/	/g; s/\\"/"/g; s/\\\\/\\/g'
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  shasum -a 256 "$1" | awk '{print $1}'
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
  curl -fsSL "https://raw.githubusercontent.com/algomim/release/$RELEASE_REF/codex/$name" -o "$download_path"
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

install_model_catalog() (
  catalog_destination="$1"
  lock_destination="$2"
  temporary_root=$(mktemp -d)
  trap 'rm -rf "$temporary_root"' HUP INT TERM EXIT
  catalog_source="$temporary_root/algomim-models.json"
  lock_source="$temporary_root/algomim-models.lock.json"

  install_release_file "algomim-models.json" "$catalog_source" 600
  install_release_file "algomim-models.lock.json" "$lock_source" 600
  expected_hash=$(json_field catalogSha256 "$lock_source" | tr 'A-F' 'a-f')
  actual_hash=$(sha256_file "$catalog_source" | tr 'A-F' 'a-f')
  generator=$(json_field generator "$lock_source")
  if ! printf '%s' "$expected_hash" | grep -Eq '^[a-f0-9]{64}$' ||
    [ "$generator" != "@algomim/inference/codex-model-catalog" ] ||
    [ "$actual_hash" != "$expected_hash" ]; then
    echo "Model catalog SHA-256 verification failed." >&2
    exit 1
  fi

  atomic_copy "$lock_source" "$lock_destination" 600
  atomic_copy "$catalog_source" "$catalog_destination" 600
  rm -rf "$temporary_root"
  trap - HUP INT TERM EXIT
)

legacy_key_get() {
  path="$1"
  [ -f "$path" ] || return 1
  algomim_api_key_normalize "$(cat "$path")"
}

DEFAULT_BASE_URL="https://api.algomim.com/v1"
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

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
ALGOMIM_HOME="${ALGOMIM_HOME:-$HOME/.algomim}"
mkdir -p "$CODEX_HOME"
mkdir -p "$ALGOMIM_HOME"
chmod 700 "$ALGOMIM_HOME"
CODEX_HOME=$(CDPATH= cd -- "$CODEX_HOME" && pwd)
ALGOMIM_HOME=$(CDPATH= cd -- "$ALGOMIM_HOME" && pwd)

PROFILE_PATH="$CODEX_HOME/algomim.config.toml"
CATALOG_PATH="$CODEX_HOME/algomim-models.json"
CATALOG_LOCK_PATH="$CODEX_HOME/algomim-models.lock.json"
LEGACY_KEY_PATH="$CODEX_HOME/algomim.key"
AUTH_SCRIPT_PATH="$CODEX_HOME/algomim-auth.sh"
CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"
INTEGRATION_HOME="$ALGOMIM_HOME/integrations/codex"
STATE_PATH="$INTEGRATION_HOME/state.json"

log "Using API base URL $BASE_URL"
log "Using credential profile '$CREDENTIAL_PROFILE' in $CREDENTIALS_PATH"

STORED_API_KEY=""
LEGACY_API_KEY=""
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
if [ -f "$LEGACY_KEY_PATH" ]; then
  if LEGACY_API_KEY=$(legacy_key_get "$LEGACY_KEY_PATH"); then
    :
  else
    echo "Legacy Codex key is invalid: $LEGACY_KEY_PATH" >&2
    exit 1
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
  elif [ -n "$LEGACY_API_KEY" ]; then
    algomim_credential_set "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE" "$LEGACY_API_KEY"
    STORED_API_KEY=$(algomim_credential_get "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE")
    rm -f "$LEGACY_KEY_PATH"
    LEGACY_API_KEY=""
    log "Migrated the legacy Codex key to shared Algomim credentials."
  elif [ -n "${ALGOMIM_API_KEY:-}" ]; then
    algomim_api_key_normalize "$ALGOMIM_API_KEY" >/dev/null
    log "Using ALGOMIM_API_KEY from the environment without persisting it."
  else
    API_KEY=$(algomim_read_required_secret 'Algomim API key: ')
    algomim_credential_set "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE" "$API_KEY"
    STORED_API_KEY=$(algomim_credential_get "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE")
    log "Stored credential profile '$CREDENTIAL_PROFILE' at $CREDENTIALS_PATH"
  fi

  if [ -n "$LEGACY_API_KEY" ] && [ -n "$STORED_API_KEY" ]; then
    if [ "$API_KEY_WAS_EXPLICIT" = "1" ] || [ "$LEGACY_API_KEY" = "$STORED_API_KEY" ]; then
      rm -f "$LEGACY_KEY_PATH"
      log "Removed the obsolete legacy Codex key file."
    else
      printf '[warn] A different legacy key remains at %s. The shared credential profile takes precedence.\n' "$LEGACY_KEY_PATH" >&2
    fi
  fi
fi

if [ -z "${ALGOMIM_API_KEY:-}" ]; then
  if ! algomim_credential_get "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE" >/dev/null 2>&1; then
    printf '[warn] No Algomim credential is available. Set ALGOMIM_API_KEY or run this installer again without --skip-key.\n' >&2
  fi
fi

install_model_catalog "$CATALOG_PATH" "$CATALOG_LOCK_PATH"
log "Installed and verified model catalog at $CATALOG_PATH"

ALGOMIM_HOME_SHELL=$(shell_single_quote "$ALGOMIM_HOME")
CREDENTIAL_PROFILE_SHELL=$(shell_single_quote "$CREDENTIAL_PROFILE")
GENERATED_AUTH=$(mktemp)
cat > "$GENERATED_AUTH" <<EOF
#!/usr/bin/env sh
set -eu

credential_get() {
  path="\$1"
  profile="\$2"
  [ -f "\$path" ] || {
    echo "Algomim credentials file not found: \$path" >&2
    return 1
  }
  [ ! -L "\$path" ] || {
    echo "Algomim credentials file cannot be a symbolic link: \$path" >&2
    return 1
  }

  awk -v wanted="\$profile" '
    BEGIN { section = ""; found = 0; fatal = 0 }
    {
      line = \$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+\$/, "", line)
      if (line == "" || line ~ /^[#;]/) next
      if (line ~ /^\\[[^][]+\\]\$/) {
        section = substr(line, 2, length(line) - 2)
        next
      }
      if (section == wanted && line ~ /^api_key[[:space:]]*=/) {
        if (found) {
          printf "Credential profile %s contains more than one api_key entry.\\n", wanted > "/dev/stderr"
          fatal = 3
          next
        }
        sub(/^api_key[[:space:]]*=[[:space:]]*/, "", line)
        sub(/[[:space:]]+\$/, "", line)
        if (line == "") {
          printf "Credential profile %s has an empty api_key.\\n", wanted > "/dev/stderr"
          fatal = 4
          next
        }
        if (line ~ /[[:cntrl:]]/) {
          printf "Credential profile %s contains an invalid api_key.\\n", wanted > "/dev/stderr"
          fatal = 5
          next
        }
        value = line
        found = 1
      }
    }
    END {
      if (fatal) exit fatal
      if (!found) exit 1
      print value
    }
  ' "\$path"
}

if [ -n "\${ALGOMIM_API_KEY:-}" ]; then
  if printf '%s' "\$ALGOMIM_API_KEY" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1; then
    echo "ALGOMIM_API_KEY contains control characters." >&2
    exit 1
  fi
  printf '%s\\n' "\$ALGOMIM_API_KEY"
  exit 0
fi

PROFILE="\${ALGOMIM_PROFILE:-$CREDENTIAL_PROFILE_SHELL}"
case "\$PROFILE" in
  ""|*[!A-Za-z0-9._-]*|[._-]*)
    echo "ALGOMIM_PROFILE is invalid." >&2
    exit 1
    ;;
esac
ALGOMIM_HOME="\${ALGOMIM_HOME:-$ALGOMIM_HOME_SHELL}"
credential_get "\$ALGOMIM_HOME/credentials" "\$PROFILE"
EOF
atomic_copy "$GENERATED_AUTH" "$AUTH_SCRIPT_PATH" 700
rm -f "$GENERATED_AUTH"
log "Installed auth helper at $AUTH_SCRIPT_PATH"

CATALOG_TOML=$(toml_escape "$CATALOG_PATH")
BASE_URL_TOML=$(toml_escape "$BASE_URL")
AUTH_SCRIPT_TOML=$(toml_escape "$AUTH_SCRIPT_PATH")
GENERATED_PROFILE=$(mktemp)
cat > "$GENERATED_PROFILE" <<EOF
model = "algomim"
model_provider = "algomim"
model_catalog_json = "$CATALOG_TOML"
web_search = "live"
service_tier = "default"
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

[features]
personality = false
EOF
atomic_copy "$GENERATED_PROFILE" "$PROFILE_PATH" 600
rm -f "$GENERATED_PROFILE"
log "Installed Codex profile at $PROFILE_PATH"

mkdir -p "$INTEGRATION_HOME"
chmod 700 "$INTEGRATION_HOME"
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
  if [ "$existing_integration" != "codex" ] || [ -z "$existing_installed_at" ]; then
    echo "Existing Codex installation state is invalid: $STATE_PATH" >&2
    exit 1
  fi
  INSTALLED_AT="$existing_installed_at"
fi

GENERATED_STATE=$(mktemp)
cat > "$GENERATED_STATE" <<EOF
{
  "schemaVersion": 1,
  "integration": "codex",
  "version": "$(json_escape "$RELEASE_VERSION")",
  "channel": "pilot",
  "releaseRepository": "algomim/release",
  "releaseTag": "$(json_escape "$RELEASE_REF")",
  "baseUrl": "$(json_escape "$BASE_URL")",
  "credentialProfile": "$(json_escape "$CREDENTIAL_PROFILE")",
  "codexHome": "$(json_escape "$CODEX_HOME")",
  "installedAt": "$(json_escape "$INSTALLED_AT")",
  "updatedAt": "$(json_escape "$NOW")"
}
EOF
atomic_copy "$GENERATED_STATE" "$STATE_PATH" 600
rm -f "$GENERATED_STATE"
log "Recorded Codex integration version $RELEASE_VERSION at $STATE_PATH"

if [ "$SKIP_KEY" != "1" ] && [ "$SKIP_CLI_INSTALL" != "1" ]; then
  install_algomim_cli
fi

if command -v codex >/dev/null 2>&1; then
  log "Codex CLI found."
else
  printf '[warn] Codex CLI was not found on PATH. Install Codex before running codex --profile algomim.\n' >&2
fi

printf '\nAlgomim Codex profile is ready.\n'
printf 'Start it with:\n'
printf '  codex --profile algomim\n\n'
printf "Normal 'codex' still uses your existing default provider.\n"
