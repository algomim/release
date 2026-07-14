#!/usr/bin/env sh
set -eu

KEEP_KEY="0"

while [ "$#" -gt 0 ]; do
  case "$1" in
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

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

remove_if_exists() {
  if [ -e "$1" ]; then
    rm -f "$1"
    printf '[algomim] Removed %s\n' "$1"
  fi
}

remove_if_exists "$CODEX_HOME/algomim.config.toml"
remove_if_exists "$CODEX_HOME/algomim-models.json"
remove_if_exists "$CODEX_HOME/algomim-auth.sh"

if [ "$KEEP_KEY" = "1" ]; then
  printf '[algomim] Kept API key file.\n'
else
  remove_if_exists "$CODEX_HOME/algomim.key"
  printf '[algomim] Removed API key file.\n'
fi

printf '[algomim] Normal Codex configuration was not modified.\n'

