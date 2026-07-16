#!/usr/bin/env sh
set -eu

REMOVE_CREDENTIAL="0"
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
    sed 's/\\r//g; s/\\t/	/g; s/\\"/"/g; s/\\\\/\\/g'
}

ALGOMIM_HOME="${ALGOMIM_HOME:-$HOME/.algomim}"
if [ -d "$ALGOMIM_HOME" ]; then
  ALGOMIM_HOME=$(CDPATH= cd -- "$ALGOMIM_HOME" && pwd)
fi
INTEGRATION_HOME="$ALGOMIM_HOME/integrations/claude-code"
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
  STATE_CREDENTIAL_PROFILE=$(json_field credentialProfile "$STATE_PATH")
else
  STATE_CREDENTIAL_PROFILE=""
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

if [ "$REMOVE_CREDENTIAL" = "1" ]; then
  CREDENTIAL_RESULT=$(algomim_credential_remove "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE")
  case "$CREDENTIAL_RESULT" in
    missing) printf "[algomim] Credential profile '%s' was not present.\n" "$CREDENTIAL_PROFILE" ;;
    removed-empty) printf "[algomim] Removed credential profile '%s' and the empty credentials file.\n" "$CREDENTIAL_PROFILE" ;;
    *) printf "[algomim] Removed credential profile '%s'.\n" "$CREDENTIAL_PROFILE" ;;
  esac
else
  printf "[algomim] Kept shared Algomim credential profile '%s'.\n" "$CREDENTIAL_PROFILE"
fi

case "$INTEGRATION_HOME" in
  "$ALGOMIM_HOME"/integrations/claude-code) ;;
  *)
    echo "Claude Code integration path is outside ALGOMIM_HOME." >&2
    exit 1
    ;;
esac
if [ -d "$INTEGRATION_HOME" ]; then
  rm -rf "$INTEGRATION_HOME"
  printf '[algomim] Removed Claude Code integration settings, lifecycle, and state files.\n'
fi

printf '[algomim] Normal Claude Code configuration was not modified. Nothing was ever written to ~/.claude.\n'
