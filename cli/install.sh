#!/usr/bin/env sh
set -eu

RELEASE_VERSION="0.3.2"
RELEASE_REF=""
ALGOMIM_HOME="${ALGOMIM_HOME:-$HOME/.algomim}"
PATH_TARGET="profile"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-version) RELEASE_VERSION="${2:-}"; shift 2 ;;
    --release-ref) RELEASE_REF="${2:-}"; shift 2 ;;
    --algomim-home) ALGOMIM_HOME="${2:-}"; shift 2 ;;
    --path-target) PATH_TARGET="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[algomim] %s\n' "$1"; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'; }
json_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -n 1
}
shell_quote() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

case "$RELEASE_VERSION" in *[!0-9.]*|.*|*.) echo "Release version must use MAJOR.MINOR.PATCH format." >&2; exit 2 ;; esac
printf '%s' "$RELEASE_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Release version must use MAJOR.MINOR.PATCH format." >&2; exit 2; }
[ -n "$RELEASE_REF" ] || RELEASE_REF="v$RELEASE_VERSION"
printf '%s' "$RELEASE_REF" | grep -Eq '^[A-Za-z0-9._/-]+$' || { echo "Release ref contains unsupported characters." >&2; exit 2; }
case "$PATH_TARGET" in profile|process) ;; *) echo "Path target must be profile or process." >&2; exit 2 ;; esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || printf '')
if [ -d "$ALGOMIM_HOME" ]; then
  ALGOMIM_HOME=$(CDPATH= cd -- "$ALGOMIM_HOME" && pwd)
else
  mkdir -p "$ALGOMIM_HOME"
  ALGOMIM_HOME=$(CDPATH= cd -- "$ALGOMIM_HOME" && pwd)
fi
BIN_DIRECTORY="$ALGOMIM_HOME/bin"
CLI_DIRECTORY="$ALGOMIM_HOME/cli"
CODEX_SUPPORT_DIRECTORY="$CLI_DIRECTORY/integrations/codex"
CLAUDE_CODE_SUPPORT_DIRECTORY="$CLI_DIRECTORY/integrations/claude-code"
STATE_PATH="$CLI_DIRECTORY/state.json"
mkdir -p "$BIN_DIRECTORY" "$CODEX_SUPPORT_DIRECTORY" "$CLAUDE_CODE_SUPPORT_DIRECTORY"
chmod 700 "$ALGOMIM_HOME" "$BIN_DIRECTORY" "$CLI_DIRECTORY" "$CLI_DIRECTORY/integrations" "$CODEX_SUPPORT_DIRECTORY" "$CLAUDE_CODE_SUPPORT_DIRECTORY"

atomic_copy() {
  source="$1"
  destination="$2"
  mode="$3"
  directory=$(dirname "$destination")
  mkdir -p "$directory"
  temporary_path=$(mktemp "$directory/.$(basename "$destination").XXXXXX")
  cp "$source" "$temporary_path"
  chmod "$mode" "$temporary_path"
  mv -f "$temporary_path" "$destination"
  chmod "$mode" "$destination"
}

install_repository_file() (
  repository_path="$1"
  destination="$2"
  mode="$3"
  repository_root=""
  if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/.." ]; then
    repository_root=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
  fi
  if [ -n "$repository_root" ] && [ -f "$repository_root/$repository_path" ]; then
    atomic_copy "$repository_root/$repository_path" "$destination" "$mode"
    exit 0
  fi
  download_path=$(mktemp)
  trap 'rm -f "$download_path"' HUP INT TERM EXIT
  curl -fsSL "https://raw.githubusercontent.com/algomim/release/$RELEASE_REF/$repository_path" -o "$download_path"
  atomic_copy "$download_path" "$destination" "$mode"
  rm -f "$download_path"
  trap - HUP INT TERM EXIT
)

install_repository_file cli/algomim.sh "$BIN_DIRECTORY/algomim" 700
install_repository_file shared/credential-store.sh "$CLI_DIRECTORY/credential-store.sh" 600
install_repository_file cli/release.json "$CLI_DIRECTORY/release.json" 600
for name in algomim-models.json algomim-models.lock.json install.sh update.sh doctor.sh uninstall.sh release.json; do
  mode=600
  case "$name" in *.sh) mode=700 ;; esac
  install_repository_file "codex/$name" "$CODEX_SUPPORT_DIRECTORY/$name" "$mode"
done
install_repository_file shared/credential-store.sh "$CODEX_SUPPORT_DIRECTORY/credential-store.sh" 600
for name in install.sh update.sh doctor.sh uninstall.sh release.json; do
  mode=600
  case "$name" in *.sh) mode=700 ;; esac
  install_repository_file "claude-code/$name" "$CLAUDE_CODE_SUPPORT_DIRECTORY/$name" "$mode"
done
install_repository_file shared/credential-store.sh "$CLAUDE_CODE_SUPPORT_DIRECTORY/credential-store.sh" 600

NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
INSTALLED_AT="$NOW"
if [ -f "$STATE_PATH" ]; then
  EXISTING_PRODUCT=$(json_field product "$STATE_PATH")
  EXISTING_INSTALLED_AT=$(json_field installedAt "$STATE_PATH")
  if [ "$EXISTING_PRODUCT" != "algomim-cli" ] || [ -z "$EXISTING_INSTALLED_AT" ]; then
    echo "Existing Algomim CLI state is invalid: $STATE_PATH" >&2
    exit 1
  fi
  INSTALLED_AT="$EXISTING_INSTALLED_AT"
fi
STATE_TEMPORARY=$(mktemp "$CLI_DIRECTORY/.state.XXXXXX")
cat > "$STATE_TEMPORARY" <<EOF
{
  "schemaVersion": 1,
  "product": "algomim-cli",
  "version": "$(json_escape "$RELEASE_VERSION")",
  "releaseTag": "$(json_escape "$RELEASE_REF")",
  "releaseRepository": "algomim/release",
  "installedAt": "$(json_escape "$INSTALLED_AT")",
  "updatedAt": "$(json_escape "$NOW")"
}
EOF
atomic_copy "$STATE_TEMPORARY" "$STATE_PATH" 600
rm -f "$STATE_TEMPORARY"

if [ "$PATH_TARGET" = "profile" ]; then
  if [ -n "${ALGOMIM_SHELL_PROFILE:-}" ]; then
    SHELL_PROFILE="$ALGOMIM_SHELL_PROFILE"
  else
    case "${SHELL:-}" in
      */zsh) SHELL_PROFILE="$HOME/.zshrc" ;;
      */bash) SHELL_PROFILE="$HOME/.bashrc" ;;
      *) SHELL_PROFILE="$HOME/.profile" ;;
    esac
  fi
  PROFILE_DIRECTORY=$(dirname "$SHELL_PROFILE")
  mkdir -p "$PROFILE_DIRECTORY"
  [ -f "$SHELL_PROFILE" ] || : > "$SHELL_PROFILE"
  START_MARKER="# >>> algomim cli >>>"
  END_MARKER="# <<< algomim cli <<<"
  CLEANED_PROFILE=$(mktemp "$PROFILE_DIRECTORY/.algomim-profile.XXXXXX")
  TRIMMED_PROFILE=$(mktemp "$PROFILE_DIRECTORY/.algomim-profile.XXXXXX")
  trap 'rm -f "$CLEANED_PROFILE" "$TRIMMED_PROFILE"' HUP INT TERM EXIT
  awk -v start="$START_MARKER" -v end="$END_MARKER" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$SHELL_PROFILE" > "$CLEANED_PROFILE"
  awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (i = 1; i <= last; i++) print lines[i] }' "$CLEANED_PROFILE" > "$TRIMMED_PROFILE"
  if [ -s "$TRIMMED_PROFILE" ]; then printf '\n' >> "$TRIMMED_PROFILE"; fi
  QUOTED_BIN=$(shell_quote "$BIN_DIRECTORY")
  printf '%s\nexport PATH='\''%s'\'':"$PATH"\n%s\n' "$START_MARKER" "$QUOTED_BIN" "$END_MARKER" >> "$TRIMMED_PROFILE"
  atomic_copy "$TRIMMED_PROFILE" "$SHELL_PROFILE" 600
  rm -f "$CLEANED_PROFILE" "$TRIMMED_PROFILE"
  trap - HUP INT TERM EXIT
  log "Added the Algomim CLI PATH block to $SHELL_PROFILE."
  log "Open a new shell to use the algomim command."
else
  log "Skipped persistent PATH changes."
fi

log "Installed Algomim CLI $RELEASE_VERSION."
