#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PYTHON_BIN="${LDDC_ARM_PYTHON:-/opt/homebrew/bin/python3.12}"
BUILD_ROOT="${LDDC_BUILD_DIR:-$REPO_ROOT/.build/work/lddc}"
OUTPUT_DIR="${LDDC_OUTPUT_DIR:-$REPO_ROOT/.build/products/lddc}"
VENV_DIR="$BUILD_ROOT/venv"
DIST_DIR="$BUILD_ROOT/dist"
WORK_DIR="$BUILD_ROOT/work"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "error: ARM64 Python is unavailable: $PYTHON_BIN" >&2
  echo "error: Set LDDC_ARM_PYTHON to an ARM64 Python 3.9 or newer." >&2
  exit 1
fi

if [[ "$(arch -arm64 "$PYTHON_BIN" -c 'import platform; print(platform.machine())')" != "arm64" ]]; then
  echo "error: LDDC_ARM_PYTHON must run as arm64: $PYTHON_BIN" >&2
  exit 1
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
arch -arm64 "$PYTHON_BIN" -m venv "$VENV_DIR"
arch -arm64 "$VENV_DIR/bin/python" -m pip install \
  -e "$SCRIPT_DIR" \
  "pyinstaller==6.21.0"

arch -arm64 "$VENV_DIR/bin/python" -m PyInstaller \
  --noconfirm \
  --clean \
  --onedir \
  --contents-directory _internal \
  --name lddc-server \
  --distpath "$DIST_DIR" \
  --workpath "$WORK_DIR" \
  --specpath "$BUILD_ROOT" \
  --paths "$SCRIPT_DIR/src" \
  --collect-submodules lddc_fetch_core \
  --collect-all lddc_fetch_core \
  --collect-all httpx \
  --collect-all h2 \
  --collect-all hpack \
  --hidden-import anyio._backends._asyncio \
  --hidden-import brotli \
  --hidden-import certifi \
  --hidden-import pyaes \
  --hidden-import sniffio \
  "$SCRIPT_DIR/lddc_server_entry.py"

BUILT_DIR="$DIST_DIR/lddc-server"
BUILT_EXE="$BUILT_DIR/lddc-server"
if [[ ! -x "$BUILT_EXE" ]] || ! /usr/bin/lipo -archs "$BUILT_EXE" | /usr/bin/grep -qw arm64; then
  echo "error: ARM64 LDDC build output is incomplete." >&2
  exit 1
fi

STAGING_DIR="${OUTPUT_DIR}.bootstrap.$$"
rm -rf "$STAGING_DIR"
COPYFILE_DISABLE=1 /usr/bin/ditto "$BUILT_DIR" "$STAGING_DIR"
chmod 755 "$STAGING_DIR/lddc-server"
/usr/bin/xattr -cr "$STAGING_DIR" 2>/dev/null || true

while IFS= read -r -d '' item; do
  if /usr/bin/file "$item" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign --force --sign - "$item" >/dev/null 2>&1 || true
  fi
done < <(/usr/bin/find "$STAGING_DIR" -type f -print0)

rm -rf "$OUTPUT_DIR"
mv "$STAGING_DIR" "$OUTPUT_DIR"
echo "LDDC runtime built at $OUTPUT_DIR"
