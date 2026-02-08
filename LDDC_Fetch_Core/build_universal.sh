#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Clean previous builds
rm -rf build dist_arm64 dist_x86_64 dist_universal .venv_arm64 .venv_x86_64

echo "=== Building Universal LDDC Server ==="

build_for_arch() {
    local ARCH=$1
    local OUTPUT_DIR=$2
    local VENV=".venv_$ARCH"
    
    echo ""
    echo ">>> Building for $ARCH..."
    
    if [ "$ARCH" == "x86_64" ]; then
        PREFIX="arch -x86_64"
    else
        PREFIX=""
    fi
    
    # 1. Create venv
    echo "Creating virtual environment ($ARCH)..."
    $PREFIX python3 -m venv "$VENV"
    
    # 2. Install dependencies
    echo "Installing dependencies ($ARCH)..."
    $PREFIX "$VENV/bin/pip" install -U pip -q
    $PREFIX "$VENV/bin/pip" install -e . -q
    $PREFIX "$VENV/bin/pip" install "httpx[http2,brotli]" pyaes pyinstaller -q
    
    # 3. Build with PyInstaller (ONEDIR for safety and merging)
    echo "Running PyInstaller ($ARCH)..."
    $PREFIX "$VENV/bin/pyinstaller" \
        --onedir \
        --name lddc-server \
        --specpath "build_$ARCH" \
        --distpath "$OUTPUT_DIR" \
        --workpath "build_$ARCH/work" \
        --paths src \
        --collect-all lddc_fetch_core \
        --hidden-import=lddc_fetch_core \
        --hidden-import=lddc_fetch_core.server \
        --hidden-import=lddc_fetch_core.fetch \
        --hidden-import=lddc_fetch_core.lrc_render \
        --hidden-import=lddc_fetch_core.match \
        --hidden-import=lddc_fetch_core.models \
        --hidden-import=lddc_fetch_core.providers \
        --hidden-import=lddc_fetch_core.providers.kg \
        --hidden-import=lddc_fetch_core.providers.lrclib \
        --hidden-import=lddc_fetch_core.providers.ne \
        --hidden-import=lddc_fetch_core.providers.qm \
        --hidden-import=lddc_fetch_core.decryptor \
        --hidden-import=lddc_fetch_core.parsers \
        --hidden-import=httpx \
        --hidden-import=httpx._transports \
        --hidden-import=httpx._transports.default \
        --hidden-import=h2 \
        --hidden-import=hpack \
        --hidden-import=brotli \
        --hidden-import=pyaes \
        --hidden-import=anyio \
        --hidden-import=anyio._backends \
        --hidden-import=anyio._backends._asyncio \
        --hidden-import=sniffio \
        --hidden-import=certifi \
        --hidden-import=idna \
        --hidden-import=socksio \
        --collect-all httpx \
        --collect-all h2 \
        --collect-all hpack \
        --clean \
        --noconfirm \
        --log-level WARN \
        lddc_server_entry.py

    # 4. Verify
    echo "Verifying $ARCH build..."
    lipo -info "$OUTPUT_DIR/lddc-server/lddc-server"
}

# --- Build ARM64 ---
build_for_arch "arm64" "dist_arm64"

# --- Build x86_64 ---
build_for_arch "x86_64" "dist_x86_64"

# --- Merge Universal ---
echo ""
echo ">>> Creation of Universal Binary Bundle..."
mkdir -p dist_universal/lddc-server

# 1. Copy the full _internal directory from arm64 (primary architecture)
echo "Copying _internal from arm64..."
cp -R dist_arm64/lddc-server/_internal dist_universal/lddc-server/

# 2. Lipo ONLY the main executable
echo "Merging Main Executable..."
lipo -create \
    dist_arm64/lddc-server/lddc-server \
    dist_x86_64/lddc-server/lddc-server \
    -output dist_universal/lddc-server/lddc-server

echo ""
echo ">>> verifying Universal Binary..."
lipo -info dist_universal/lddc-server/lddc-server
# Check if python runtime exists
if [ -f "dist_universal/lddc-server/_internal/Python.framework/Versions/3.9/Python" ]; then
    echo "Python runtime found."
else
    echo "Warning: Python runtime not found in expected location."
fi

echo ""
echo ">>> Signing..."
# Sign the main executable
codesign --force --sign - dist_universal/lddc-server/lddc-server

echo ""
echo ">>> Installing to Tools..."
TOOLS_DIR="../Tools/lddc-server"
# Ensure clean slate
rm -rf "$TOOLS_DIR"
mkdir -p "$(dirname "$TOOLS_DIR")"
# Copy the whole folder content
cp -R dist_universal/lddc-server "$TOOLS_DIR"

echo "Done."
