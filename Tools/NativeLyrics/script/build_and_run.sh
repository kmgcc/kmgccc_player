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
cp "$binary_dir/NativeLyricsDemo" "$app/Contents/MacOS/"
cp "$package_dir/script/Info.plist" "$app/Contents/Info.plist"
cp "$package_dir/Sources/NativeLyricsDemo/Resources/complex.ttml" "$app/Contents/Resources/"
for bundle in "$binary_dir"/*.bundle; do [[ ! -d "$bundle" ]] || cp -R "$bundle" "$app/Contents/Resources/"; done
for fixture in song.ttml audio.m4a fixture.json; do
  if [[ -f "$package_dir/.local/$fixture" ]]; then cp "$package_dir/.local/$fixture" "$app/Contents/Resources/"; fi
done
xattr -cr "$app"
codesign --force --sign - "$app"
if [[ "${1:-}" != "--build-only" ]]; then /usr/bin/open -n "$app"; fi
echo "$app"
