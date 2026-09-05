#!/bin/bash
set -euo pipefail
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$package_dir"
swift build --quiet
binary_dir="$(swift build --show-bin-path)"
app="$package_dir/dist/Native Lyrics Demo.app"
if [[ -d "$app" ]]; then
  # Only stop this exact development executable, never a same-named player.
  running_pid="$(pgrep -f "^${app}/Contents/MacOS/NativeLyricsDemo$" || true)"
  if [[ -n "$running_pid" ]]; then kill $running_pid; fi
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -X "$binary_dir/NativeLyricsDemo" "$app/Contents/MacOS/"
cp -X "$package_dir/script/Info.plist" "$app/Contents/Info.plist"
for resource in "$package_dir/Sources/NativeLyricsDemo/Resources"/*.ttml; do
  [[ ! -f "$resource" ]] || cp -X "$resource" "$app/Contents/Resources/"
done
for bundle in "$binary_dir"/*.bundle; do [[ ! -d "$bundle" ]] || cp -RX "$bundle" "$app/Contents/Resources/"; done
for fixture in song.ttml audio.m4a fixture.json; do
  if [[ -f "$package_dir/.local/$fixture" ]]; then cp -X "$package_dir/.local/$fixture" "$app/Contents/Resources/"; fi
done
# Finder/FileProvider metadata can be reattached to nested SwiftPM bundles.
# Clear the complete bundle recursively immediately before signing; clearing
# parents and children in a separate find pass can leave FinderInfo on a
# nested bundle between the two operations.
xattr -cr "$app" 2>/dev/null || true
codesign --force --sign - "$app"
if [[ "${1:-}" != "--build-only" ]]; then /usr/bin/open -n "$app"; fi
echo "$app"
