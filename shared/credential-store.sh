algomim_trim_value() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

algomim_credential_validate_profile() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*|[._-]*)
      echo "Credential profile must start with a letter or number and contain at most 64 letters, numbers, dots, underscores, or hyphens." >&2
      return 2
      ;;
  esac
  if [ "${#1}" -gt 64 ]; then
    echo "Credential profile must not exceed 64 characters." >&2
    return 2
  fi
}

algomim_api_key_normalize() {
  normalized=$(algomim_trim_value "$1")
  if [ -z "$normalized" ]; then
    echo "API key cannot be empty." >&2
    return 1
  fi
  without_control=$(printf '%s' "$normalized" | LC_ALL=C tr -d '[:cntrl:]')
  if [ "$without_control" != "$normalized" ]; then
    echo "API key cannot contain control characters." >&2
    return 1
  fi
  printf '%s' "$normalized"
}

algomim_has_interactive_terminal() {
  [ -r /dev/tty ] && [ -w /dev/tty ] && stty -g >/dev/null 2>&1 < /dev/tty
}

algomim_read_required_secret() {
  prompt="$1"
  if ! algomim_has_interactive_terminal; then
    echo "Interactive API key input requires a terminal." >&2
    return 2
  fi
  while :; do
    printf '%s' "$prompt" > /dev/tty
    stty -echo < /dev/tty
    trap 'stty echo < /dev/tty; printf "\n" > /dev/tty' HUP INT TERM EXIT
    IFS= read -r secret < /dev/tty || true
    stty echo < /dev/tty
    trap - HUP INT TERM EXIT
    printf '\n' > /dev/tty
    if normalized=$(algomim_api_key_normalize "$secret"); then
      printf '%s' "$normalized"
      return
    fi
    printf '[warn] API key cannot be empty or contain control characters. Press Ctrl+C to cancel.\n' > /dev/tty
  done
}

algomim_credential_get() (
  path="$1"
  profile="$2"
  algomim_credential_validate_profile "$profile" || exit $?
  [ -f "$path" ] || exit 1
  [ ! -L "$path" ] || {
    echo "Credential file cannot be a symbolic link: $path" >&2
    exit 2
  }
  awk -v wanted="$profile" '
    BEGIN { section = ""; found = 0; fatal = 0 }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^[#;]/) next
      if (line ~ /^\[[^][]+\]$/) {
        section = substr(line, 2, length(line) - 2)
        next
      }
      if (section == wanted && line ~ /^api_key[[:space:]]*=/) {
        if (found) {
          printf "Credential profile %s contains more than one api_key entry.\n", wanted > "/dev/stderr"
          fatal = 3
          next
        }
        sub(/^api_key[[:space:]]*=[[:space:]]*/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line == "" || line ~ /[[:cntrl:]]/) {
          printf "Credential profile %s contains an invalid api_key.\n", wanted > "/dev/stderr"
          fatal = 4
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
  ' "$path"
)

algomim_credential_set() (
  path="$1"
  profile="$2"
  key=$(algomim_api_key_normalize "$3") || exit $?
  algomim_credential_validate_profile "$profile" || exit $?
  [ ! -L "$path" ] || {
    echo "Credential file cannot be a symbolic link: $path" >&2
    exit 1
  }

  directory=$(dirname "$path")
  umask 077
  mkdir -p "$directory"
  chmod 700 "$directory"
  temporary_path=$(mktemp "$directory/.credentials.XXXXXX")
  trap 'rm -f "$temporary_path"' HUP INT TERM EXIT
  in_target="0"
  target_found="0"
  key_written="0"
  if [ -f "$path" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      trimmed=$(algomim_trim_value "$line")
      case "$trimmed" in
        \[*\])
          if [ "$in_target" = "1" ] && [ "$key_written" = "0" ]; then
            printf 'api_key = %s\n' "$key" >> "$temporary_path"
            key_written="1"
          fi
          section=${trimmed#\[}
          section=${section%\]}
          if [ "$section" = "$profile" ]; then
            in_target="1"
            target_found="1"
          else
            in_target="0"
          fi
          printf '%s\n' "$line" >> "$temporary_path"
          continue
          ;;
      esac
      if [ "$in_target" = "1" ]; then
        case "$trimmed" in
          *=*)
            key_name=${trimmed%%=*}
            key_name=$(algomim_trim_value "$key_name")
            if [ "$key_name" = "api_key" ]; then
              if [ "$key_written" = "0" ]; then
                printf 'api_key = %s\n' "$key" >> "$temporary_path"
                key_written="1"
              fi
              continue
            fi
            ;;
        esac
      fi
      printf '%s\n' "$line" >> "$temporary_path"
    done < "$path"
  fi
  if [ "$in_target" = "1" ] && [ "$key_written" = "0" ]; then
    printf 'api_key = %s\n' "$key" >> "$temporary_path"
  fi
  if [ "$target_found" = "0" ]; then
    [ ! -s "$temporary_path" ] || printf '\n' >> "$temporary_path"
    printf '[%s]\napi_key = %s\n' "$profile" "$key" >> "$temporary_path"
  fi
  chmod 600 "$temporary_path"
  mv -f "$temporary_path" "$path"
  chmod 600 "$path"
  trap - HUP INT TERM EXIT
  stored=$(algomim_credential_get "$path" "$profile") || exit $?
  [ "$stored" = "$key" ] || {
    echo "Credential verification failed after writing profile '$profile'." >&2
    exit 1
  }
)

algomim_credential_remove() (
  path="$1"
  profile="$2"
  algomim_credential_validate_profile "$profile" || exit $?
  if [ ! -f "$path" ]; then
    printf 'missing\n'
    exit 0
  fi
  [ ! -L "$path" ] || {
    echo "Credential file cannot be a symbolic link: $path" >&2
    exit 1
  }

  directory=$(dirname "$path")
  umask 077
  temporary_path=$(mktemp "$directory/.credentials.XXXXXX")
  trap 'rm -f "$temporary_path"' HUP INT TERM EXIT
  in_target="0"
  target_found="0"
  meaningful="0"
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(algomim_trim_value "$line")
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
      case "$trimmed" in ""|\#*|\;*) ;; *) meaningful="1" ;; esac
    fi
  done < "$path"
  if [ "$target_found" = "0" ]; then
    rm -f "$temporary_path"
    printf 'missing\n'
    exit 0
  fi
  if [ "$meaningful" = "0" ]; then
    rm -f "$temporary_path" "$path"
    printf 'removed-empty\n'
    exit 0
  fi
  chmod 600 "$temporary_path"
  mv -f "$temporary_path" "$path"
  chmod 600 "$path"
  trap - HUP INT TERM EXIT
  printf 'removed\n'
)
