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

remove_credential_profile() {
  path="$1"
  profile="$2"
  if [ ! -f "$path" ]; then
    printf '[algomim] Shared credentials file does not exist.\n'
    return
  fi
  if [ -L "$path" ]; then
    echo "Credential file cannot be a symbolic link: $path" >&2
    exit 1
  fi

  directory=$(dirname "$path")
  umask 077
  temporary_path=$(mktemp "$directory/.credentials.XXXXXX")
  in_target="0"
  target_found="0"
  meaningful="0"

  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$trimmed" in
      \[*\])
        section=${trimmed#\[}
        section=${section%\]}
        if [ "$section" = "$profile" ]; then
          in_target="1"
          target_found="1"
          continue
        fi
        in_target="0"
        ;;
    esac

    if [ "$in_target" = "0" ]; then
      printf '%s\n' "$line" >> "$temporary_path"
      case "$trimmed" in
        ""|\#*|\;*) ;;
        *) meaningful="1" ;;
      esac
    fi
  done < "$path"

  if [ "$target_found" = "0" ]; then
    rm -f "$temporary_path"
    printf "[algomim] Credential profile '%s' was not present.\n" "$profile"
    return
  fi

  if [ "$meaningful" = "0" ]; then
    rm -f "$temporary_path" "$path"
    printf "[algomim] Removed credential profile '%s' and the empty credentials file.\n" "$profile"
    return
  fi

  chmod 600 "$temporary_path"
  mv -f "$temporary_path" "$path"
  chmod 600 "$path"
  printf "[algomim] Removed credential profile '%s'.\n" "$profile"
}

remove_if_exists "$CODEX_HOME/algomim.config.toml"
remove_if_exists "$CODEX_HOME/algomim-models.json"
remove_if_exists "$CODEX_HOME/algomim-auth.sh"

if [ "$KEEP_KEY" = "1" ]; then
  printf '[warn] --keep-key is no longer required; credentials are preserved by default.\n' >&2
fi

if [ "$REMOVE_CREDENTIAL" = "1" ]; then
  remove_credential_profile "$CREDENTIALS_PATH" "$CREDENTIAL_PROFILE"
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
