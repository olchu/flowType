#!/bin/zsh
set -euo pipefail

SCHEME="${SCHEME:-FlowType}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/private/tmp/${SCHEME}-${CONFIGURATION}}"
DIST_DIR="${DIST_DIR:-dist}"

BUILD_SETTINGS="$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings)"
PRODUCT_NAME="$(printf "%s\n" "$BUILD_SETTINGS" | awk -F'= ' '/ PRODUCT_NAME = / { print $2; exit }')"
VERSION="$(printf "%s\n" "$BUILD_SETTINGS" | awk -F'= ' '/ MARKETING_VERSION = / { print $2; exit }')"

if [[ -z "$PRODUCT_NAME" || -z "$VERSION" ]]; then
  echo "Could not resolve PRODUCT_NAME or MARKETING_VERSION from Xcode build settings." >&2
  exit 1
fi

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$PRODUCT_NAME.app"
DMG_NAME="$PRODUCT_NAME-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
STAGING_DIR="$(mktemp -d "/private/tmp/${PRODUCT_NAME}-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

xcodebuild \
  -scheme "$SCHEME" \
  -destination platform=macOS \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

mkdir -p "$DIST_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$PRODUCT_NAME.app"
ln -shf /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$PRODUCT_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "$DMG_PATH"
