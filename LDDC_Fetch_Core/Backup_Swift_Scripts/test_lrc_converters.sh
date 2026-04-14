#!/bin/bash
# Test script for LRC to TTML converters
# Compares Python and Swift outputs

set -e

echo "======================================"
echo "LRC to TTML Converter Test Suite"
echo "======================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test directories
TEST_DIR="/Users/kmg/Documents/vscode/player/myPlayer2/LDDC-main/LDDC_Fetch_Core/examples/out_separate"
SWIFT_DIR="/Users/kmg/Documents/vscode/player/myPlayer2"
PYTHON_DIR="/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Resources"
OUTPUT_DIR="/tmp/lrc_test_output"

# Create output directories
mkdir -p "$OUTPUT_DIR/python"
mkdir -p "$OUTPUT_DIR/swift"
mkdir -p "$OUTPUT_DIR/swift_translation"
mkdir -p "$OUTPUT_DIR/python_translation"

# Test files
TEST_FILE1="$TEST_DIR/司南 - 守望者 [Original].lrc"
TEST_FILE2="$TEST_DIR/珂拉琪 Collage - MALIYANG [Original].lrc"
TRANS_FILE="$TEST_DIR/珂拉琪 Collage - MALIYANG [Translation].lrc"

pass_count=0
fail_count=0

# Function to compare two files
compare_files() {
    local file1=$1
    local file2=$2
    local test_name=$3
    
    if [ ! -f "$file1" ]; then
        echo -e "${RED}❌ FAIL${NC}: $test_name - Python output not found: $file1"
        ((fail_count++))
        return 1
    fi
    
    if [ ! -f "$file2" ]; then
        echo -e "${RED}❌ FAIL${NC}: $test_name - Swift output not found: $file2"
        ((fail_count++))
        return 1
    fi
    
    if diff -q "$file1" "$file2" > /dev/null 2>&1; then
        echo -e "${GREEN}✅ PASS${NC}: $test_name - Files are identical"
        ((pass_count++))
        return 0
    else
        echo -e "${YELLOW}⚠️  DIFF${NC}: $test_name - Files differ (showing first 20 lines of diff)"
        diff "$file1" "$file2" | head -20 || true
        echo ""
        ((fail_count++))
        return 1
    fi
}

echo "=== Test 1: Single File Conversion (司南 - 守望者) ==="
echo ""

# Python conversion
echo "Running Python converter..."
python3 "$PYTHON_DIR/lrc_to_ttml.py" -i "$TEST_FILE1" -o "$OUTPUT_DIR/python/守望者.ttml" --strip-metadata || {
    echo -e "${RED}❌ Python conversion failed${NC}"
    exit 1
}

# Swift conversion  
echo "Running Swift converter..."
cd "$SWIFT_DIR"
swift "$SWIFT_DIR/LRCToTTMLConverter.swift" -i "$TEST_FILE1" -o "$OUTPUT_DIR/swift/守望者.ttml" || {
    echo -e "${RED}❌ Swift conversion failed${NC}"
    exit 1
}

compare_files "$OUTPUT_DIR/python/守望者.ttml" "$OUTPUT_DIR/swift/守望者.ttml" "守望者 Single File"
echo ""

echo "=== Test 2: Single File Conversion (MALIYANG) ==="
echo ""

# Python conversion
echo "Running Python converter..."
python3 "$PYTHON_DIR/lrc_to_ttml.py" -i "$TEST_FILE2" -o "$OUTPUT_DIR/python/MALIYANG.ttml" --strip-metadata || {
    echo -e "${RED}❌ Python conversion failed${NC}"
    exit 1
}

# Swift conversion
echo "Running Swift converter..."
swift "$SWIFT_DIR/LRCToTTMLConverter.swift" -i "$TEST_FILE2" -o "$OUTPUT_DIR/swift/MALIYANG.ttml" || {
    echo -e "${RED}❌ Swift conversion failed${NC}"
    exit 1
}

compare_files "$OUTPUT_DIR/python/MALIYANG.ttml" "$OUTPUT_DIR/swift/MALIYANG.ttml" "MALIYANG Single File"
echo ""

echo "=== Test 3: With Translation (MALIYANG) ==="
echo ""

# Python conversion with translation
echo "Running Python converter with translation..."
python3 "$PYTHON_DIR/lrc_to_ttml_with_translation.py" -i "$TEST_FILE2" -t "$TRANS_FILE" -o "$OUTPUT_DIR/python_translation/MALIYANG.ttml" --strip-metadata || {
    echo -e "${RED}❌ Python translation conversion failed${NC}"
    exit 1
}

# Swift conversion with translation
echo "Running Swift converter with translation..."
swift "$SWIFT_DIR/LRCToTTMLWithTranslationConverter.swift" -i "$TEST_FILE2" -t "$TRANS_FILE" -o "$OUTPUT_DIR/swift_translation/MALIYANG.ttml" || {
    echo -e "${RED}❌ Swift translation conversion failed${NC}"
    exit 1
}

compare_files "$OUTPUT_DIR/python_translation/MALIYANG.ttml" "$OUTPUT_DIR/swift_translation/MALIYANG.ttml" "MALIYANG With Translation"
echo ""

echo "=== Test 4: Without Metadata Stripping (守望者) ==="
echo ""

# Python without strip
echo "Running Python converter (no strip)..."
python3 "$PYTHON_DIR/lrc_to_ttml.py" -i "$TEST_FILE1" -o "$OUTPUT_DIR/python/守望者_no_strip.ttml" --no-strip-metadata || {
    echo -e "${RED}❌ Python conversion failed${NC}"
    exit 1
}

# Swift doesn't have --no-strip-metadata flag by default, but we can test structure
echo "Skipping Swift no-strip test (requires flag implementation)"
echo ""

echo "=== Sample Output Preview ==="
echo ""
echo "Python output (first 500 chars):"
head -c 500 "$OUTPUT_DIR/python/守望者.ttml" | cat
echo ""
echo "..."
echo ""
echo "Swift output (first 500 chars):"
head -c 500 "$OUTPUT_DIR/swift/守望者.ttml" | cat
echo ""
echo "..."
echo ""

echo "======================================"
echo "Test Results Summary"
echo "======================================"
echo -e "${GREEN}Passed: $pass_count${NC}"
echo -e "${RED}Failed: $fail_count${NC}"
echo ""

if [ $fail_count -eq 0 ]; then
    echo -e "${GREEN}🎉 All tests passed!${NC}"
    echo ""
    echo "Output files available in: $OUTPUT_DIR"
    exit 0
else
    echo -e "${RED}⚠️  Some tests failed. Check differences above.${NC}"
    echo ""
    echo "Output files available in: $OUTPUT_DIR"
    exit 1
fi
