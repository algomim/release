#!/usr/bin/env sh
set -eu

REMOVE_CREDENTIAL="0"
KEEP_KEY="0"
CREDENTIAL_PROFILE="${ALGOMIM_PROFILE:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remove-credential)
      REMOVE_CREDENTIAL="1"
      shift
      ;;
    --credential-profile)
      CREDENTIAL_PROFILE="${2:-}"
      shift 2
      ;;
    --keep-key)
      KEEP_KEY="1"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

json_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -n 1 |
    sed 's/\\r//g; s/\\t/	/g; s/\\"/"/g; s/\\\\/\\/g'
}

CODEX_HOME="${CODEX_HOME:-}"
ALGOMIM_HOME="${ALGOMIM_HOME:-$HOME/.algomim}"
if [ -d "$ALGOMIM_HOME" ]; then
  ALGOMIM_HOME=$(CDPATH= cd -- "$ALGOMIM_HOME" && pwd)
fi
INTEGRATION_HOME="$ALGOMIM_HOME/integrations/codex"
CREDENTIAL_HELPER="$INTEGRATION_HOME/credential-store.sh"
if [ ! -f "$CREDENTIAL_HELPER" ]; then
  CREDENTIAL_HELPER="$ALGOMIM_HOME/cli/credential-store.sh"
fi
[ -f "$CREDENTIAL_HELPER" ] || {
  echo "Algomim credential helper is missing: $CREDENTIAL_HELPER" >&2
  exit 1
}
. "$CREDENTIAL_HELPER"
STATE_PATH="$INTEGRATION_HOME/state.json"
if [ -f "$STATE_PATH" ]; then
  STATE_CODEX_HOME=$(json_field codexHome "$STATE_PATH")
  STATE_CREDENTIAL_PROFILE=$(json_field credentialProfile "$STATE_PATH")
else
  STATE_CODEX_HOME=""
  STATE_CREDENTIAL_PROFILE=""
fi

if [ -z "$CODEX_HOME" ]; then
  CODEX_HOME="${STATE_CODEX_HOME:-$HOME/.codex}"
fi
if [ -z "$CREDENTIAL_PROFILE" ]; then
  CREDENTIAL_PROFILE="${STATE_CREDENTIAL_PROFILE:-default}"
fi

case "$CREDENTIAL_PROFILE" in
  ""|*[!A-Za-z0-9._-]*|[._-]*)
    echo "Credential profile name is invalid." >&2
    exit 2
    ;;
esac
if [ "${#CREDENTIAL_PROFILE}" -gt 64 ]; then
  echo "Credential profile name is invalid." >&2
  exit 2
fi

CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"
LEGACY_KEY_PATH="$CODEX_HOME/algomim.key"

remove_if_exists() {
  if [ -e "$1" ]; then
    rm -f "$1"
    printf '[algomim] Removed %s\n' "$1"
  fi
}

remove_if_exists "$CODEX_HOME/algomim.config.toml"
remove_if_exists "$CODEX_HOME/algomim-models.json"
remove_if_exists "$CODEX_HOME/algomim-models.lock.json"
remove_if_exists "$CODEX_HOME/algomim-auth.sh"

if [ "$KEEP_KEY" = "1" ]; then
  printf '[warn] --keep-key is no longer required; credentials are preserved by default.\n' >&2
fi

if [ "$REMOVE_CREDENTIAL" = "1" ]; then
  CREDENTIAL_RESULT=$(algomim_credential_remove "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE")
  case "$CREDENTIAL_RESULT" in
    missing) printf "[algomim] Credential profile '%s' was not present.\n" "$CREDENTIAL_PROFILE" ;;
    removed-empty) printf "[algomim] Removed credential profile '%s' and the empty credentials file.\n" "$CREDENTIAL_PROFILE" ;;
    *) printf "[algomim] Removed credential profile '%s'.\n" "$CREDENTIAL_PROFILE" ;;
  esac
  remove_if_exists "$LEGACY_KEY_PATH"
else
  printf "[algomim] Kept shared Algomim credential profile '%s'.\n" "$CREDENTIAL_PROFILE"
  if [ -f "$LEGACY_KEY_PATH" ]; then
    printf '[warn] A legacy Codex key remains. Re-run the installer to migrate it.\n' >&2
  fi
fi

case "$INTEGRATION_HOME" in
  "$ALGOMIM_HOME"/integrations/codex) ;;
  *)
    echo "Codex integration path is outside ALGOMIM_HOME." >&2
    exit 1
    ;;
esac
if [ -d "$INTEGRATION_HOME" ]; then
  rm -rf "$INTEGRATION_HOME"
  printf '[algomim] Removed Codex integration lifecycle and state files.\n'
fi

printf '[algomim] Normal Codex configuration was not modified.\n'
