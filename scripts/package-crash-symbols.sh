#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --app <App.app> --dsym <App.app.dSYM> [--manifest <manifest.json>] [--archive-dir <private-dir> --backup-dir <backup-dir>] [--check]" >&2
}

APP=""
DSYM=""
MANIFEST_OUTPUT=""
ARCHIVE_DIR=""
BACKUP_DIR=""
CHECK_ONLY=0
while (($#)); do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --dsym) DSYM="${2:-}"; shift 2 ;;
    --manifest) MANIFEST_OUTPUT="${2:-}"; shift 2 ;;
    --archive-dir) ARCHIVE_DIR="${2:-}"; shift 2 ;;
    --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

[[ -d "$APP" && -d "$DSYM" ]] || { usage; exit 2; }
INFO_PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
APP_BINARY="$APP/Contents/MacOS/$EXECUTABLE"
DWARF_RELATIVE="$(basename "$DSYM")/Contents/Resources/DWARF/$EXECUTABLE"
DWARF_FILE="$DSYM/Contents/Resources/DWARF/$EXECUTABLE"

[[ -f "$APP_BINARY" && -f "$DWARF_FILE" ]] || {
  echo "error: app executable or dSYM DWARF file is missing" >&2
  exit 1
}
[[ "$APP_VERSION" =~ ^[A-Za-z0-9._+-]+$ && "$BUILD_NUMBER" =~ ^[A-Za-z0-9._+-]+$ ]] || {
  echo "error: version/build contains unsupported manifest characters" >&2
  exit 1
}

APP_UUIDS="$(/usr/bin/dwarfdump --uuid "$APP_BINARY" | /usr/bin/awk '{ print toupper($2) " " $3 }' | /usr/bin/sort)"
DSYM_UUIDS="$(/usr/bin/dwarfdump --uuid "$DWARF_FILE" | /usr/bin/awk '{ print toupper($2) " " $3 }' | /usr/bin/sort)"
[[ -n "$APP_UUIDS" && "$APP_UUIDS" == "$DSYM_UUIDS" ]] || {
  echo "error: dSYM UUIDs do not match the built app" >&2
  echo "app:  $APP_UUIDS" >&2
  echo "dSYM: $DSYM_UUIDS" >&2
  exit 1
}

STAGING="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/kmgccc-symbols.XXXXXX")"
trap '/bin/rm -rf "$STAGING"' EXIT
/bin/cp -R "$DSYM" "$STAGING/$(basename "$DSYM")"
DWARF_SHA256="$(/usr/bin/shasum -a 256 "$DWARF_FILE" | /usr/bin/awk '{print $1}')"

{
  printf '{"schemaVersion":1,"appVersion":"%s","buildNumber":"%s","symbols":[' "$APP_VERSION" "$BUILD_NUMBER"
  FIRST=1
  while read -r UUID ARCH_PAREN; do
    ARCH="${ARCH_PAREN#(}"
    ARCH="${ARCH%)}"
    ((FIRST)) || printf ','
    FIRST=0
    printf '{"uuid":"%s","architecture":"%s","dwarfPath":"%s","sha256":"%s"}' \
      "$UUID" "$ARCH" "$DWARF_RELATIVE" "$DWARF_SHA256"
  done <<< "$DSYM_UUIDS"
  printf ']}'
} > "$STAGING/manifest.json"

if [[ -n "$MANIFEST_OUTPUT" ]]; then
  MANIFEST_DIR="$(dirname "$MANIFEST_OUTPUT")"
  /bin/mkdir -p "$MANIFEST_DIR"
  MANIFEST_OUTPUT="$(cd "$MANIFEST_DIR" && pwd)/$(basename "$MANIFEST_OUTPUT")"
  /bin/cp "$STAGING/manifest.json" "$MANIFEST_OUTPUT.tmp.$$"
  /bin/mv "$MANIFEST_OUTPUT.tmp.$$" "$MANIFEST_OUTPUT"
fi

if [[ -z "$ARCHIVE_DIR" && -z "$BACKUP_DIR" ]]; then
  echo "validated dSYM UUIDs and generated manifest for $APP_VERSION ($BUILD_NUMBER)"
  exit 0
fi
[[ -n "$ARCHIVE_DIR" && -n "$BACKUP_DIR" ]] || {
  echo "error: --archive-dir and --backup-dir must be provided together" >&2
  exit 2
}

/bin/mkdir -p "$ARCHIVE_DIR" "$BACKUP_DIR"
ARCHIVE_DIR="$(cd "$ARCHIVE_DIR" && pwd)"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"
[[ "$ARCHIVE_DIR" != "$BACKUP_DIR" ]] || {
  echo "error: primary archive and backup must be different directories" >&2
  exit 2
}
FIRST_UUID="$(printf '%s\n' "$DSYM_UUIDS" | /usr/bin/awk 'NR == 1 { gsub(/-/, "", $1); print substr($1, 1, 12) }')"
ARCHIVE_NAME="kmgccc_player_${APP_VERSION}_${BUILD_NUMBER}_${FIRST_UUID}.symbols.zip"
TEMP_ARCHIVE="$STAGING/$ARCHIVE_NAME"
(cd "$STAGING" && COPYFILE_DISABLE=1 /usr/bin/zip -qry "$TEMP_ARCHIVE" manifest.json "$(basename "$DSYM")")

copy_archive() {
  local destination="$1/$ARCHIVE_NAME"
  if [[ -f "$destination" ]]; then
    /usr/bin/unzip -p "$destination" manifest.json | /usr/bin/cmp -s - "$STAGING/manifest.json" || {
      echo "error: archive already exists with a different manifest: $destination" >&2
      exit 1
    }
  else
    /bin/cp "$TEMP_ARCHIVE" "$destination.tmp.$$"
    /bin/mv "$destination.tmp.$$" "$destination"
  fi
  printf '%s\n' "$destination"
}

PRIMARY_PATH="$(copy_archive "$ARCHIVE_DIR")"
BACKUP_PATH="$(copy_archive "$BACKUP_DIR")"
PRIMARY_SHA="$(/usr/bin/shasum -a 256 "$PRIMARY_PATH" | /usr/bin/awk '{print $1}')"
BACKUP_SHA="$(/usr/bin/shasum -a 256 "$BACKUP_PATH" | /usr/bin/awk '{print $1}')"
[[ "$PRIMARY_SHA" == "$BACKUP_SHA" ]] || {
  echo "error: primary archive and backup SHA-256 differ" >&2
  exit 1
}

echo "primary: $PRIMARY_PATH"
echo "backup:  $BACKUP_PATH"
echo "sha256:  $PRIMARY_SHA"
