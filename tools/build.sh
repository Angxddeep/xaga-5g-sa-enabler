#!/usr/bin/env bash
#
# Build script for MtkNrConfig (Java source -> DEX)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
BUILD_DIR="$SCRIPT_DIR/build"
CLASSES_DIR="$BUILD_DIR/classes"
DEX_DIR="$BUILD_DIR/dex"
OUTPUT_DEX="$SCRIPT_DIR/mtk_nr_config.dex"

echo "[*] Cleaning build directories..."
rm -rf "$BUILD_DIR"
mkdir -p "$CLASSES_DIR" "$DEX_DIR"

echo "[*] Compiling Java source..."
javac --release 8 -d "$CLASSES_DIR" "$SRC_DIR/com/xaga/sa/MtkNrConfig.java"

# Locate d8 in Android SDK
D8_BIN=""
if command -v d8 &>/dev/null; then
    D8_BIN="d8"
elif [ -d "$HOME/Library/Android/sdk/build-tools" ]; then
    LATEST_BT=$(ls -1d "$HOME/Library/Android/sdk/build-tools"/* | sort -V | tail -n 1)
    if [ -x "$LATEST_BT/d8" ]; then
        D8_BIN="$LATEST_BT/d8"
    fi
elif [ -d "$ANDROID_HOME/build-tools" ]; then
    LATEST_BT=$(ls -1d "$ANDROID_HOME/build-tools"/* | sort -V | tail -n 1)
    if [ -x "$LATEST_BT/d8" ]; then
        D8_BIN="$LATEST_BT/d8"
    fi
fi

if [ -z "$D8_BIN" ]; then
    echo "[-] Error: 'd8' could not be found. Please install Android build-tools or set ANDROID_HOME."
    exit 1
fi

echo "[*] Converting class files to DEX using $D8_BIN..."
"$D8_BIN" --output "$DEX_DIR" "$CLASSES_DIR/com/xaga/sa/MtkNrConfig.class"

cp "$DEX_DIR/classes.dex" "$OUTPUT_DEX"
DEX_SIZE=$(wc -c < "$OUTPUT_DEX" | tr -d ' ')
echo "[+] DEX generated successfully: $OUTPUT_DEX ($DEX_SIZE bytes)"

BASE64_FILE="$BUILD_DIR/mtk_nr_config.dex.b64"
base64 < "$OUTPUT_DEX" | tr -d '\n' > "$BASE64_FILE"
echo "[+] Base64 string written to: $BASE64_FILE"
