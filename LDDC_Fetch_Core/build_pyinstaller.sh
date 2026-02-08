#!/bin/bash
# LDDC Server PyInstaller Build Script
# Builds a standalone executable for the LDDC lyrics fetch server

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

OUTPUT_DIR="../Tools"

echo "=== LDDC Server Build Script ==="
echo "Working directory: $SCRIPT_DIR"

# Step 1: Create/update virtual environment
echo ""
echo "[1/4] Setting up Python virtual environment..."
PYTHON_BIN="/usr/local/bin/python3.11"
if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="python3"
fi
if [ ! -d ".venv" ]; then
    "$PYTHON_BIN" -m venv .venv
fi
source .venv/bin/activate

# Step 2: Install dependencies
echo ""
echo "[2/4] Installing dependencies..."
pip install -U pip -q
pip install -e . -q
pip install "httpx[http2,brotli]" pyaes pyinstaller -q

# Step 3: Build with PyInstaller
echo ""
echo "[3/4] Building with PyInstaller..."
pyinstaller \
    --onedir \
    --name lddc-server \
    --specpath build \
    --distpath dist \
    --workpath build/work \
    --paths src \
    --collect-submodules lddc_fetch_core \
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
    lddc_server_entry.py

# Step 4: Copy to Resources
echo ""
echo "[4/4] Copying to $OUTPUT_DIR..."
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/lddc-server"
cp -R dist/lddc-server "$OUTPUT_DIR/"
chmod +x "$OUTPUT_DIR/lddc-server/lddc-server"

echo ""
echo "=== Build Complete ==="
echo "Output: $OUTPUT_DIR/lddc-server/lddc-server"
echo ""
echo "Verify with: $OUTPUT_DIR/lddc-server --help"

# Quick test
echo ""
echo "Testing binary..."
"$OUTPUT_DIR/lddc-server/lddc-server" --help || echo "Warning: Binary test failed"
