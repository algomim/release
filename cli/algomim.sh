#!/usr/bin/env sh
set -eu

usage() {
  cat <<'EOF'
Algomim CLI

Usage:
  algomim login [--profile <name>] [--api-key-stdin]
  algomim logout [--profile <name>] [--yes]
  algomim version
  algomim help

  algomim codex install [--profile <name>]
  algomim codex update [--check]
  algomim codex doctor [--offline]
  algomim codex uninstall
EOF
}

fail_usage() {
  printf '%s\nRun '\''algomim help'\'' for usage.\n' "$1" >&2
  exit 2
}

json_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -n 1
}

selected_profile() {
  profile="${1:-${ALGOMIM_PROFILE:-default}}"
  algomim_credential_validate_profile "$profile" || exit $?
  printf '%s' "$profile"
}

read_cli_state() {
  [ -f "$CLI_STATE_PATH" ] || {
    echo "Algomim CLI state is missing. Re-run the versioned installer." >&2
    return 1
  }
  [ "$(json_field product "$CLI_STATE_PATH")" = "algomim-cli" ] || {
    echo "Algomim CLI state has an unsupported contract." >&2
    return 1
  }
}

codex_lifecycle() {
  path="$ALGOMIM_HOME/integrations/codex/$1"
  [ -f "$path" ] || {
    echo "Codex integration is not installed. Run 'algomim codex install'." >&2
    return 1
  }
  printf '%s' "$path"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ALGOMIM_HOME="${ALGOMIM_HOME:-$HOME/.algomim}"
CLI_STATE_PATH="$ALGOMIM_HOME/cli/state.json"
CREDENTIALS_PATH="$ALGOMIM_HOME/credentials"
CREDENTIAL_HELPER="$ALGOMIM_HOME/cli/credential-store.sh"
if [ ! -f "$CREDENTIAL_HELPER" ]; then
  CREDENTIAL_HELPER="$SCRIPT_DIR/../shared/credential-store.sh"
fi
[ -f "$CREDENTIAL_HELPER" ] || {
  echo "Algomim credential helper is missing. Re-run the versioned installer." >&2
  exit 1
}
. "$CREDENTIAL_HELPER"

COMMAND="${1:-help}"
[ "$#" -eq 0 ] || shift
case "$COMMAND" in
  help)
    [ "$#" -eq 0 ] || fail_usage "help does not accept options."
    usage
    ;;
  version)
    [ "$#" -eq 0 ] || fail_usage "version does not accept options."
    read_cli_state
    VERSION=$(json_field version "$CLI_STATE_PATH")
    TAG=$(json_field releaseTag "$CLI_STATE_PATH")
    printf 'Algomim CLI %s (%s)\n' "$VERSION" "$TAG"
    CODEX_STATE="$ALGOMIM_HOME/integrations/codex/state.json"
    if [ -f "$CODEX_STATE" ]; then
      printf 'Codex integration %s\n' "$(json_field version "$CODEX_STATE")"
    fi
    ;;
  login)
    PROFILE=""
    STDIN_KEY="0"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --profile) [ "$#" -ge 2 ] || fail_usage "--profile requires a value."; PROFILE="$2"; shift 2 ;;
        --api-key-stdin) STDIN_KEY="1"; shift ;;
        *) fail_usage "Unknown login option: $1" ;;
      esac
    done
    PROFILE=$(selected_profile "$PROFILE")
    if [ "$STDIN_KEY" = "1" ]; then
      API_KEY=$(algomim_api_key_normalize "$(cat)")
    else
      API_KEY=$(algomim_read_required_secret 'Algomim API key: ')
    fi
    algomim_credential_set "$CREDENTIALS_PATH" "$PROFILE" "$API_KEY"
    API_KEY=""
    printf "[algomim] Credential profile '%s' is ready.\n" "$PROFILE"
    ;;
  logout)
    PROFILE=""
    CONFIRMED="0"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --profile) [ "$#" -ge 2 ] || fail_usage "--profile requires a value."; PROFILE="$2"; shift 2 ;;
        --yes) CONFIRMED="1"; shift ;;
        *) fail_usage "Unknown logout option: $1" ;;
      esac
    done
    PROFILE=$(selected_profile "$PROFILE")
    if [ "$CONFIRMED" != "1" ]; then
      algomim_has_interactive_terminal || {
        echo "Interactive confirmation requires a terminal; pass --yes." >&2
        exit 2
      }
      printf "Remove Algomim credential profile '%s'? [y/N] " "$PROFILE" > /dev/tty
      IFS= read -r ANSWER < /dev/tty || true
      case "$ANSWER" in y|Y|yes|YES|Yes) CONFIRMED="1" ;; esac
    fi
    if [ "$CONFIRMED" != "1" ]; then
      printf '[algomim] Logout cancelled.\n'
      exit 0
    fi
    RESULT=$(algomim_credential_remove "$CREDENTIALS_PATH" "$PROFILE")
    case "$RESULT" in
      missing) printf "[algomim] Credential profile '%s' was not present.\n" "$PROFILE" ;;
      removed-empty) printf "[algomim] Removed credential profile '%s' and the empty credentials file.\n" "$PROFILE" ;;
      *) printf "[algomim] Removed credential profile '%s'.\n" "$PROFILE" ;;
    esac
    ;;
  codex)
    SUBCOMMAND="${1:-}"
    [ -n "$SUBCOMMAND" ] || fail_usage "A Codex command is required."
    shift
    case "$SUBCOMMAND" in
      install)
        PROFILE=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --profile) [ "$#" -ge 2 ] || fail_usage "--profile requires a value."; PROFILE="$2"; shift 2 ;;
            *) fail_usage "Unknown codex install option: $1" ;;
          esac
        done
        PROFILE=$(selected_profile "$PROFILE")
        read_cli_state
        VERSION=$(json_field version "$CLI_STATE_PATH")
        TAG=$(json_field releaseTag "$CLI_STATE_PATH")
        INSTALLER="$ALGOMIM_HOME/cli/integrations/codex/install.sh"
        [ -f "$INSTALLER" ] || { echo "The bundled Codex installer is missing. Re-run the versioned Algomim installer." >&2; exit 1; }
        sh "$INSTALLER" --credential-profile "$PROFILE" --release-ref "$TAG" --release-version "$VERSION" --skip-cli-install
        sh "$(codex_lifecycle doctor.sh)" --credential-profile "$PROFILE" --skip-api-check
        ;;
      update)
        CHECK="0"
        while [ "$#" -gt 0 ]; do
          [ "$1" = "--check" ] || fail_usage "Unknown codex update option: $1"
          CHECK="1"
          shift
        done
        if [ "$CHECK" = "1" ]; then sh "$(codex_lifecycle update.sh)" --check
        else sh "$(codex_lifecycle update.sh)"
        fi
        ;;
      doctor)
        OFFLINE="0"
        while [ "$#" -gt 0 ]; do
          [ "$1" = "--offline" ] || fail_usage "Unknown codex doctor option: $1"
          OFFLINE="1"
          shift
        done
        if [ "$OFFLINE" = "1" ]; then sh "$(codex_lifecycle doctor.sh)" --skip-api-check
        else sh "$(codex_lifecycle doctor.sh)"
        fi
        ;;
      uninstall)
        [ "$#" -eq 0 ] || fail_usage "codex uninstall does not accept options."
        sh "$(codex_lifecycle uninstall.sh)"
        printf '[algomim] Algomim CLI and shared credentials were preserved.\n'
        ;;
      *) fail_usage "Unknown Codex command: $SUBCOMMAND" ;;
    esac
    ;;
  *) fail_usage "Unknown command: $COMMAND" ;;
esac
