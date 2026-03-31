#!/bin/bash
# Build a professional DMG installer for SociMax
# Requires: brew install create-dmg

set -e

APP_NAME="SociMax"
DMG_NAME="${APP_NAME}-Installer"
BUILD_DIR=".build/Build/Products/Release"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Verify app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: ${APP_PATH} not found. Build the app first:"
    echo "  xcodebuild -scheme SociMax -configuration Release -derivedDataPath .build -quiet"
    exit 1
fi

# Check for create-dmg
if ! command -v create-dmg &> /dev/null; then
    echo "Installing create-dmg..."
    brew install create-dmg
fi

# Remove old DMG
rm -f "${DMG_NAME}.dmg"

# Generate DMG background if it doesn't exist
BG_PATH="scripts/dmg-background.png"
if [ ! -f "$BG_PATH" ]; then
    echo "Note: No custom background at ${BG_PATH}"
    echo "Creating DMG without custom background..."

    create-dmg \
        --volname "${APP_NAME}" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 80 \
        --icon "${APP_NAME}.app" 175 190 \
        --app-drop-link 425 190 \
        --hide-extension "${APP_NAME}.app" \
        "${DMG_NAME}.dmg" \
        "${APP_PATH}"
else
    create-dmg \
        --volname "${APP_NAME}" \
        --background "${BG_PATH}" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 80 \
        --icon "${APP_NAME}.app" 175 190 \
        --app-drop-link 425 190 \
        --hide-extension "${APP_NAME}.app" \
        "${DMG_NAME}.dmg" \
        "${APP_PATH}"
fi

echo ""
echo "DMG created: ${DMG_NAME}.dmg"
echo "Size: $(du -h "${DMG_NAME}.dmg" | cut -f1)"
