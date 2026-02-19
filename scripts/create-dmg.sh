#!/bin/bash

# Create a DMG from a built .app
# Usage:
#   ./scripts/create-dmg.sh /path/to/Gemelo.app [output_dir]

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/AppName.app [output_dir]"
  exit 1
fi

APP_PATH="$1"
OUTPUT_DIR="${2:-$(pwd)/dist}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: app not found: $APP_PATH"
  exit 1
fi

APP_NAME="$(basename "$APP_PATH" .app)"
mkdir -p "$OUTPUT_DIR"

STAGING_DIR="$OUTPUT_DIR/dmg-staging"
DMG_PATH="$OUTPUT_DIR/${APP_NAME}.dmg"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING_DIR"

echo "DMG created: $DMG_PATH"
