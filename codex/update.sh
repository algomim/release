#!/usr/bin/env sh
set -eu

ALGOMIM_HOME="${ALGOMIM_HOME:-$HOME/.algomim}"
VERSION=""
MANIFEST_URL=""
ARTIFACT_BASE_URL=""
FORCE="0"
CHECK_ONLY="0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --algomim-home)
      ALGOMIM_HOME="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --manifest-url)
      MANIFEST_URL="${2:-}"
      shift 2
      ;;
    --artifact-base-url)
      ARTIFACT_BASE_URL="${2:-}"
      shift 2
      ;;
    --force)
      FORCE="1"
      shift
      ;;
    --check)
      CHECK_ONLY="1"
      shift
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

json_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -n 1 |
    sed 's/\\r//g; s/\\t/	/g; s/\\"/"/g; s/\\\\/\\/g'
}

json_number_field() {
  field="$1"
  path="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$path" | head -n 1
}

json_object_field() {
  object="$1"
  field="$2"
  path="$3"
  awk -v wanted_object="$object" -v wanted_field="$field" '
    $0 ~ "^[[:space:]]*\"" wanted_object "\"[[:space:]]*:[[:space:]]*\\{" {
      inside = 1
      next
    }
    inside && $0 ~ "^[[:space:]]*\\}" {
      exit
    }
    inside && $0 ~ "^[[:space:]]*\"" wanted_field "\"[[:space:]]*:" {
      line = $0
      sub("^[[:space:]]*\"" wanted_field "\"[[:space:]]*:[[:space:]]*\"", "", line)
      sub("\"[,]?[[:space:]]*$", "", line)
      print line
      exit
    }
  ' "$path" | sed 's/\\r//g; s/\\t/	/g; s/\\"/"/g; s/\\\\/\\/g'
}

validate_semver() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

semver_compare() {
  awk -v left="$1" -v right="$2" 'BEGIN {
    split(left, a, ".")
    split(right, b, ".")
    for (i = 1; i <= 3; i++) {
      if ((a[i] + 0) < (b[i] + 0)) { print -1; exit }
      if ((a[i] + 0) > (b[i] + 0)) { print 1; exit }
    }
    print 0
  }'
}

copy_source() {
  source="$1"
  destination="$2"
  if [ -f "$source" ]; then
    cp "$source" "$destination"
    return
  fi
  case "$source" in
    https://*) curl -fsSL "$source" -o "$destination" ;;
    *)
      echo "Release source must be a local file or an HTTPS URL: $source" >&2
      return 1
      ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  shasum -a 256 "$1" | awk '{print $1}'
}

restore_installation() {
  codex_home="$1"
  integration_home="$2"
  backup_root="$3"

  for name in algomim.config.toml algomim-models.json algomim-auth.sh; do
    rm -f "$codex_home/$name"
    if [ -f "$backup_root/codex/$name" ]; then
      cp "$backup_root/codex/$name" "$codex_home/$name"
    fi
  done

  find "$integration_home" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  if [ -d "$backup_root/integration" ]; then
    cp -R "$backup_root/integration/." "$integration_home/"
  fi
}

mkdir -p "$ALGOMIM_HOME"
ALGOMIM_HOME=$(CDPATH= cd -- "$ALGOMIM_HOME" && pwd)
INTEGRATION_HOME="$ALGOMIM_HOME/integrations/codex"
case "$INTEGRATION_HOME" in
  "$ALGOMIM_HOME"/integrations/codex) ;;
  *)
    echo "Codex integration path is outside ALGOMIM_HOME." >&2
    exit 1
    ;;
esac

STATE_PATH="$INTEGRATION_HOME/state.json"
if [ ! -f "$STATE_PATH" ]; then
  echo "Codex installation state is missing. Run the versioned installer first: $STATE_PATH" >&2
  exit 1
fi

SCHEMA_VERSION=$(json_number_field schemaVersion "$STATE_PATH")
INTEGRATION=$(json_field integration "$STATE_PATH")
INSTALLED_VERSION=$(json_field version "$STATE_PATH")
REPOSITORY=$(json_field releaseRepository "$STATE_PATH")
BASE_URL=$(json_field baseUrl "$STATE_PATH")
CREDENTIAL_PROFILE=$(json_field credentialProfile "$STATE_PATH")
CODEX_HOME=$(json_field codexHome "$STATE_PATH")
if [ "$SCHEMA_VERSION" != "1" ] || [ "$INTEGRATION" != "codex" ]; then
  echo "Unsupported Codex installation state." >&2
  exit 1
fi
if ! validate_semver "$INSTALLED_VERSION"; then
  echo "Installed version is invalid." >&2
  exit 1
fi
if ! printf '%s' "$REPOSITORY" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  echo "Installation state contains an invalid release repository." >&2
  exit 1
fi

VERSION=${VERSION#v}
if [ -n "$VERSION" ] && ! validate_semver "$VERSION"; then
  echo "Version must use MAJOR.MINOR.PATCH format." >&2
  exit 2
fi

TEMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TEMP_ROOT"' HUP INT TERM EXIT
MANIFEST_PATH="$TEMP_ROOT/manifest.json"
if [ -z "$MANIFEST_URL" ]; then
  if [ -n "$VERSION" ]; then
    MANIFEST_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION/manifest.json"
  else
    MANIFEST_URL="https://github.com/$REPOSITORY/releases/latest/download/manifest.json"
  fi
fi
copy_source "$MANIFEST_URL" "$MANIFEST_PATH"

MANIFEST_SCHEMA=$(json_number_field schemaVersion "$MANIFEST_PATH")
MANIFEST_INTEGRATION=$(json_field integration "$MANIFEST_PATH")
TARGET_VERSION=$(json_field version "$MANIFEST_PATH")
RELEASE_TAG=$(json_field releaseTag "$MANIFEST_PATH")
if [ "$MANIFEST_SCHEMA" != "1" ] || [ "$MANIFEST_INTEGRATION" != "codex" ]; then
  echo "Release manifest has an unsupported contract." >&2
  exit 1
fi
if ! validate_semver "$TARGET_VERSION" || [ "$RELEASE_TAG" != "v$TARGET_VERSION" ]; then
  echo "Release manifest version and tag are invalid." >&2
  exit 1
fi
if [ -n "$VERSION" ] && [ "$TARGET_VERSION" != "$VERSION" ]; then
  echo "Release manifest version does not match the requested version." >&2
  exit 1
fi

COMPARISON=$(semver_compare "$TARGET_VERSION" "$INSTALLED_VERSION")
if [ "$FORCE" != "1" ] && [ "$COMPARISON" -lt 0 ]; then
  echo "Refusing to downgrade from $INSTALLED_VERSION to $TARGET_VERSION without --force." >&2
  exit 1
fi
if [ "$FORCE" != "1" ] && [ "$COMPARISON" -eq 0 ]; then
  log "Codex integration is already up to date at $INSTALLED_VERSION."
  exit 0
fi
if [ "$CHECK_ONLY" = "1" ]; then
  log "Codex integration update available: $INSTALLED_VERSION -> $TARGET_VERSION"
  exit 0
fi

ARTIFACT_NAME=$(json_object_field posix file "$MANIFEST_PATH")
ARTIFACT_FORMAT=$(json_object_field posix format "$MANIFEST_PATH")
EXPECTED_HASH=$(json_object_field posix sha256 "$MANIFEST_PATH" | tr 'A-F' 'a-f')
case "$ARTIFACT_NAME" in
  ""|*/*|*\\*)
    echo "POSIX artifact name is invalid." >&2
    exit 1
    ;;
  *.tar.gz) ;;
  *)
    echo "POSIX artifact name is invalid." >&2
    exit 1
    ;;
esac
if [ -z "$ARTIFACT_NAME" ] || [ "$ARTIFACT_FORMAT" != "tar.gz" ]; then
  echo "Release manifest must contain one tar.gz POSIX artifact." >&2
  exit 1
fi
if ! printf '%s' "$EXPECTED_HASH" | grep -Eq '^[a-f0-9]{64}$'; then
  echo "POSIX artifact checksum is invalid." >&2
  exit 1
fi

ARTIFACT_PATH="$TEMP_ROOT/$ARTIFACT_NAME"
if [ -z "$ARTIFACT_BASE_URL" ]; then
  ARTIFACT_SOURCE="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/$ARTIFACT_NAME"
elif [ -d "$ARTIFACT_BASE_URL" ]; then
  ARTIFACT_SOURCE="$ARTIFACT_BASE_URL/$ARTIFACT_NAME"
else
  ARTIFACT_SOURCE="${ARTIFACT_BASE_URL%/}/$ARTIFACT_NAME"
fi
copy_source "$ARTIFACT_SOURCE" "$ARTIFACT_PATH"
ACTUAL_HASH=$(sha256_file "$ARTIFACT_PATH" | tr 'A-F' 'a-f')
if [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
  echo "Release artifact checksum verification failed." >&2
  exit 1
fi
log "Verified $ARTIFACT_NAME (SHA-256)."

if tar -tzf "$ARTIFACT_PATH" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  echo "Release artifact contains an unsafe path." >&2
  exit 1
fi
STAGE_ROOT="$TEMP_ROOT/stage"
mkdir -p "$STAGE_ROOT"
tar -xzf "$ARTIFACT_PATH" -C "$STAGE_ROOT"
STAGED_CODEX="$STAGE_ROOT/codex"
for required in install.sh doctor.sh update.sh release.json; do
  [ -f "$STAGED_CODEX/$required" ] || {
    echo "Release artifact is missing $required." >&2
    exit 1
  }
done

CONTRACT_VERSION=$(json_field version "$STAGED_CODEX/release.json")
CONTRACT_TAG=$(json_field releaseTag "$STAGED_CODEX/release.json")
CONTRACT_INTEGRATION=$(json_field integration "$STAGED_CODEX/release.json")
if [ "$CONTRACT_INTEGRATION" != "codex" ] || [ "$CONTRACT_VERSION" != "$TARGET_VERSION" ] || [ "$CONTRACT_TAG" != "$RELEASE_TAG" ]; then
  echo "Release artifact contract does not match the manifest." >&2
  exit 1
fi

mkdir -p "$CODEX_HOME"
BACKUP_ROOT="$TEMP_ROOT/backup"
mkdir -p "$BACKUP_ROOT/codex" "$BACKUP_ROOT/integration"
for name in algomim.config.toml algomim-models.json algomim-auth.sh; do
  if [ -f "$CODEX_HOME/$name" ]; then
    cp "$CODEX_HOME/$name" "$BACKUP_ROOT/codex/$name"
  fi
done
cp -R "$INTEGRATION_HOME/." "$BACKUP_ROOT/integration/"

UPDATE_FAILED="0"
if ! CODEX_HOME="$CODEX_HOME" ALGOMIM_HOME="$ALGOMIM_HOME" sh "$STAGED_CODEX/install.sh" \
  --base-url "$BASE_URL" \
  --credential-profile "$CREDENTIAL_PROFILE" \
  --release-ref "$RELEASE_TAG" \
  --release-version "$TARGET_VERSION" \
  --skip-key; then
  UPDATE_FAILED="1"
fi

if [ "$UPDATE_FAILED" = "0" ] && ! CODEX_HOME="$CODEX_HOME" ALGOMIM_HOME="$ALGOMIM_HOME" sh "$STAGED_CODEX/doctor.sh" \
  --credential-profile "$CREDENTIAL_PROFILE" \
  --skip-api-check; then
  UPDATE_FAILED="1"
fi

if [ "$UPDATE_FAILED" = "0" ]; then
  UPDATED_VERSION=$(json_field version "$STATE_PATH")
  if [ "$UPDATED_VERSION" != "$TARGET_VERSION" ]; then
    UPDATE_FAILED="1"
  fi
fi

if [ "$UPDATE_FAILED" = "1" ]; then
  printf '[warn] Update failed; restoring Codex integration %s.\n' "$INSTALLED_VERSION" >&2
  restore_installation "$CODEX_HOME" "$INTEGRATION_HOME" "$BACKUP_ROOT"
  echo "Codex update rolled back." >&2
  exit 1
fi

log "Updated Codex integration from $INSTALLED_VERSION to $TARGET_VERSION."
rm -rf "$TEMP_ROOT"
trap - HUP INT TERM EXIT
