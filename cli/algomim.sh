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

  algomim install <codex|claude> [--profile <name>]
  algomim run <codex|claude> [-- <client arguments>]
  algomim doctor [codex|claude] [--offline]
  algomim update [codex|claude] [--check]
  algomim uninstall <codex|claude>
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

INTEGRATION_IDS="codex claude-code"

resolve_integration_name() {
  case "$1" in
    codex) printf 'codex' ;;
    claude|claude-code) printf 'claude-code' ;;
    *)
      fail_usage "Unknown integration: $1. Valid integrations: codex, claude."
      ;;
  esac
}

integration_token() {
  if [ "$1" = "claude-code" ]; then printf 'claude'; else printf '%s' "$1"; fi
}

integration_display_name() {
  if [ "$1" = "claude-code" ]; then printf 'Claude Code'; else printf 'Codex'; fi
}

integration_lifecycle() {
  integration="$1"
  name="$2"
  path="$ALGOMIM_HOME/integrations/$integration/$name"
  [ -f "$path" ] || {
    printf "%s integration is not installed. Run 'algomim install %s'.\n" "$(integration_display_name "$integration")" "$(integration_token "$integration")" >&2
    return 1
  }
  printf '%s' "$path"
}

installed_integrations() {
  for integration in $INTEGRATION_IDS; do
    if [ -f "$ALGOMIM_HOME/integrations/$integration/state.json" ]; then
      printf '%s\n' "$integration"
    fi
  done
}

run_install() {
  integration="$1"
  shift
  PROFILE=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile) [ "$#" -ge 2 ] || fail_usage "--profile requires a value."; PROFILE="$2"; shift 2 ;;
      *) fail_usage "Unknown install option: $1" ;;
    esac
  done
  PROFILE=$(selected_profile "$PROFILE")
  read_cli_state
  VERSION=$(json_field version "$CLI_STATE_PATH")
  TAG=$(json_field releaseTag "$CLI_STATE_PATH")
  INSTALLER="$ALGOMIM_HOME/cli/integrations/$integration/install.sh"
  [ -f "$INSTALLER" ] || {
    printf 'The bundled %s installer is missing. Re-run the versioned Algomim installer.\n' "$(integration_display_name "$integration")" >&2
    exit 1
  }
  sh "$INSTALLER" --credential-profile "$PROFILE" --release-ref "$TAG" --release-version "$VERSION" --skip-cli-install
  sh "$(integration_lifecycle "$integration" doctor.sh)" --credential-profile "$PROFILE" --skip-api-check
}

run_update() {
  integration="$1"
  check="$2"
  if [ "$check" = "1" ]; then sh "$(integration_lifecycle "$integration" update.sh)" --check
  else sh "$(integration_lifecycle "$integration" update.sh)"
  fi
}

run_doctor() {
  integration="$1"
  offline="$2"
  if [ "$offline" = "1" ]; then sh "$(integration_lifecycle "$integration" doctor.sh)" --skip-api-check
  else sh "$(integration_lifecycle "$integration" doctor.sh)"
  fi
}

run_uninstall() {
  integration="$1"
  shift
  [ "$#" -eq 0 ] || fail_usage "uninstall does not accept options."
  sh "$(integration_lifecycle "$integration" uninstall.sh)"
  printf '[algomim] Algomim CLI and shared credentials were preserved.\n'
}

run_credential() {
  profile="$1"
  if [ -n "${ALGOMIM_API_KEY:-}" ]; then
    if printf '%s' "$ALGOMIM_API_KEY" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1; then
      echo "ALGOMIM_API_KEY contains control characters." >&2
      return 1
    fi
    printf '%s' "$ALGOMIM_API_KEY"
    return 0
  fi
  if ! algomim_credential_get "$CREDENTIALS_PATH" "$profile" 2>/dev/null; then
    printf "No Algomim credential is available for profile '%s'. Run 'algomim login'.\n" "$profile" >&2
    return 1
  fi
}

run_client() {
  integration="$1"
  shift
  if [ "$integration" = "codex" ]; then
    integration_lifecycle codex state.json >/dev/null
    command -v codex >/dev/null 2>&1 || {
      echo "Codex CLI is not available on PATH. Install Codex first." >&2
      exit 1
    }
    exec codex --profile algomim "$@"
  fi

  STATE_PATH=$(integration_lifecycle claude-code state.json)
  SETTINGS_PATH=$(integration_lifecycle claude-code settings.json)
  CLAUDE_CONFIG_DIR_PATH="$ALGOMIM_HOME/integrations/claude-code/config"
  command -v claude >/dev/null 2>&1 || {
    echo "Claude Code CLI is not available on PATH. Install Claude Code first." >&2
    exit 1
  }
  if [ -L "$CLAUDE_CONFIG_DIR_PATH" ]; then
    echo "Claude Code integration config path must not be a symbolic link: $CLAUDE_CONFIG_DIR_PATH" >&2
    exit 1
  fi
  if [ -e "$CLAUDE_CONFIG_DIR_PATH" ] && [ ! -d "$CLAUDE_CONFIG_DIR_PATH" ]; then
    echo "Claude Code integration config path must be a directory: $CLAUDE_CONFIG_DIR_PATH" >&2
    exit 1
  fi
  mkdir -p "$CLAUDE_CONFIG_DIR_PATH"
  chmod 700 "$CLAUDE_CONFIG_DIR_PATH"
  PROFILE="${ALGOMIM_PROFILE:-$(json_field credentialProfile "$STATE_PATH")}"
  PROFILE="${PROFILE:-default}"
  algomim_credential_validate_profile "$PROFILE" || exit $?
  TOKEN=$(run_credential "$PROFILE") || exit 1
  unset \
    ANTHROPIC_CUSTOM_MODEL_OPTION \
    ANTHROPIC_CUSTOM_MODEL_OPTION_NAME \
    ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION \
    ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTED_CAPABILITIES \
    ANTHROPIC_DEFAULT_FABLE_MODEL \
    ANTHROPIC_DEFAULT_FABLE_MODEL_NAME \
    ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION \
    ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES \
    ANTHROPIC_DEFAULT_OPUS_MODEL \
    ANTHROPIC_DEFAULT_OPUS_MODEL_NAME \
    ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION \
    ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES \
    ANTHROPIC_DEFAULT_SONNET_MODEL \
    ANTHROPIC_DEFAULT_SONNET_MODEL_NAME \
    ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION \
    ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES \
    ANTHROPIC_DEFAULT_HAIKU_MODEL \
    ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME \
    ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION \
    ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES \
    ANTHROPIC_SMALL_FAST_MODEL
  ANTHROPIC_AUTH_TOKEN="$TOKEN" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_PATH" exec claude --settings "$SETTINGS_PATH" "$@"
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

# Legacy noun-first grammar (algomim codex install) rewrites silently to verb-first.
case "$COMMAND" in
  codex|claude)
    [ "$#" -ge 1 ] || fail_usage "An integration action is required: install, run, doctor, update, or uninstall."
    LEGACY_NOUN="$COMMAND"
    COMMAND="$1"
    shift
    set -- "$LEGACY_NOUN" "$@"
    ;;
esac

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
    for integration in $INTEGRATION_IDS; do
      INTEGRATION_STATE="$ALGOMIM_HOME/integrations/$integration/state.json"
      if [ -f "$INTEGRATION_STATE" ]; then
        printf '%s integration %s\n' "$(integration_display_name "$integration")" "$(json_field version "$INTEGRATION_STATE")"
      fi
    done
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
  install)
    [ "$#" -ge 1 ] || fail_usage "install requires an integration: codex or claude."
    INTEGRATION=$(resolve_integration_name "$1")
    shift
    run_install "$INTEGRATION" "$@"
    ;;
  run)
    [ "$#" -ge 1 ] || fail_usage "run requires an integration: codex or claude."
    case "$1" in
      -*) fail_usage "run requires an integration: codex or claude." ;;
    esac
    INTEGRATION=$(resolve_integration_name "$1")
    shift
    if [ "$#" -ge 1 ] && [ "$1" = "--" ]; then
      shift
    fi
    run_client "$INTEGRATION" "$@"
    ;;
  doctor)
    INTEGRATION=""
    OFFLINE="0"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --offline) OFFLINE="1"; shift ;;
        -*) fail_usage "Unknown doctor option: $1" ;;
        *)
          [ -z "$INTEGRATION" ] || fail_usage "doctor accepts a single integration."
          INTEGRATION=$(resolve_integration_name "$1")
          shift
          ;;
      esac
    done
    if [ -n "$INTEGRATION" ]; then
      run_doctor "$INTEGRATION" "$OFFLINE"
    else
      INSTALLED=$(installed_integrations)
      [ -n "$INSTALLED" ] || {
        echo "No Algomim integrations are installed. Run 'algomim install codex' or 'algomim install claude'." >&2
        exit 1
      }
      ANY_FAILED="0"
      for integration in $INSTALLED; do
        printf '[algomim] Doctor: %s\n' "$(integration_display_name "$integration")"
        if ! run_doctor "$integration" "$OFFLINE"; then
          ANY_FAILED="1"
        fi
      done
      [ "$ANY_FAILED" = "0" ] || exit 1
    fi
    ;;
  update)
    INTEGRATION=""
    CHECK="0"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --check) CHECK="1"; shift ;;
        -*) fail_usage "Unknown update option: $1" ;;
        *)
          [ -z "$INTEGRATION" ] || fail_usage "update accepts a single integration."
          INTEGRATION=$(resolve_integration_name "$1")
          shift
          ;;
      esac
    done
    if [ -n "$INTEGRATION" ]; then
      run_update "$INTEGRATION" "$CHECK"
    else
      INSTALLED=$(installed_integrations)
      [ -n "$INSTALLED" ] || {
        echo "No Algomim integrations are installed. Run 'algomim install codex' or 'algomim install claude'." >&2
        exit 1
      }
      for integration in $INSTALLED; do
        printf '[algomim] Update: %s\n' "$(integration_display_name "$integration")"
        run_update "$integration" "$CHECK"
      done
    fi
    ;;
  uninstall)
    [ "$#" -ge 1 ] || fail_usage "uninstall requires an integration: codex or claude."
    INTEGRATION=$(resolve_integration_name "$1")
    shift
    run_uninstall "$INTEGRATION" "$@"
    ;;
  *) fail_usage "Unknown command: $COMMAND" ;;
esac
