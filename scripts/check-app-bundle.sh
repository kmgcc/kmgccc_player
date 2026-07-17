#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: ./scripts/check-app-bundle.sh /path/to/kmgccc_player.app"
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "$2 missing: ${1#$APP/}"
}

require_executable() {
  [[ -x "$1" ]] || fail "$2 missing or not executable: ${1#$APP/}"
}

require_directory() {
  [[ -d "$1" ]] || fail "$2 missing: ${1#$APP/}"
}

if [[ $# -ne 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  [[ $# -eq 1 ]] && exit 0
  exit 2
fi

if [[ "$1" == /* ]]; then
  APP="$1"
else
  APP="$PWD/$1"
fi
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"

require_directory "$APP" "App bundle"
require_executable "$CONTENTS/MacOS/kmgccc_player" "App executable"
require_file "$CONTENTS/Info.plist" "App Info.plist"
require_file "$RESOURCES/Assets.car" "Asset catalog"

require_file "$RESOURCES/AMLL/index.html" "AMLL entry page"
require_file "$RESOURCES/AMLL/amll-core.js" "AMLL core"
require_file "$RESOURCES/AMLL/amll-lyric.js" "AMLL lyric parser"
require_file "$RESOURCES/AMLL/amll-background.js" "AMLL background runtime"
require_file "$RESOURCES/AMLL/bridge.js" "AMLL bridge"
require_file "$RESOURCES/AMLL/style.css" "AMLL stylesheet"

require_executable "$RESOURCES/Tools/lddc-server/lddc-server" "LDDC server"
require_directory "$RESOURCES/Tools/lddc-server/_internal" "LDDC runtime directory"
require_executable "$RESOURCES/Tools/qqmusic-helper/qqmusic-helper" "QQMusic helper"
require_directory "$RESOURCES/Tools/qqmusic-helper/_internal.bundle" "QQMusic helper runtime directory"
require_executable "$RESOURCES/Tools/sacad/sacad" "SACAD helper"

require_file "$RESOURCES/mediaremote-adapter/bin/mediaremote-adapter.pl" "MediaRemoteAdapter launcher"
require_directory "$RESOURCES/mediaremote-adapter/build/MediaRemoteAdapter.framework" "MediaRemoteAdapter framework"
require_file "$RESOURCES/mediaremote-adapter/build/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" "MediaRemoteAdapter binary"
require_executable "$RESOURCES/mediaremote-adapter/build/MediaRemoteAdapterTestClient" "MediaRemoteAdapter client"

require_file "$RESOURCES/zh-Hans.lproj/Localizable.strings" "Simplified Chinese localization"
require_file "$RESOURCES/Docs/policy.md" "User agreement document"
require_file "$RESOURCES/Docs/privacy.md" "Privacy policy document"
for license in \
  AGPL-3.0.txt \
  GPL-3.0.txt \
  LDDC.txt \
  QQMusicApi.txt \
  SACAD-MPL-2.0.txt \
  apple-audio-visualization.txt \
  applemusic-like-lyrics.txt; do
  require_file "$RESOURCES/$license" "Runtime license"
done
require_file \
  "$RESOURCES/Licenses/MediaRemoteAdapter-BSD-3-Clause.txt" \
  "MediaRemoteAdapter license"

for forbidden_name in .DS_Store .git DerivedData __pycache__ .pytest_cache; do
  if /usr/bin/find "$CONTENTS" -name "$forbidden_name" -print -quit | /usr/bin/grep -q .; then
    fail "Forbidden bundle entry found: $forbidden_name"
  fi
done

if /usr/bin/find "$CONTENTS" -type f \( \
    -name '*.swift' -o \
    -name '*.pyc' -o \
    -name '*.tmp' -o \
    -iname 'README' -o \
    -iname 'README.*' -o \
    -name '*Tests.swift' \
  \) -print -quit | /usr/bin/grep -q .; then
  fail "Source, test, README, or temporary files entered the App bundle."
fi

for forbidden_directory in Tests ColorGoldenMaster; do
  if /usr/bin/find "$CONTENTS" -type d -name "$forbidden_directory" -print -quit | /usr/bin/grep -q .; then
    fail "Development directory entered the App bundle: $forbidden_directory"
  fi
done

for text_file in \
  "$CONTENTS/Info.plist" \
  "$RESOURCES/AMLL/index.html" \
  "$RESOURCES/AMLL/background.html" \
  "$RESOURCES/AMLL/bridge.js" \
  "$RESOURCES/AMLL/style.css" \
  "$RESOURCES/mediaremote-adapter/bin/mediaremote-adapter.pl" \
  "$RESOURCES/zh-Hans.lproj/Localizable.strings"; do
  if LC_ALL=C /usr/bin/grep -a -q '/Users/' "$text_file"; then
    fail "User-home absolute path found in bundled text: ${text_file#$APP/}"
  fi
done

echo "[OK] Required App bundle components are present."
echo "[OK] Basic forbidden-entry checks passed."
echo "This presence check is not a functional smoke test or a release audit."
