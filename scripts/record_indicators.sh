#!/bin/zsh
# Records the indicator styles off screen and builds Docs/images/indicators.webp.
# Needs Pillow and img2webp (brew install webp).
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/private/tmp/FlowType-${CONFIGURATION}}"
OUTPUT="${OUTPUT:-Docs/images/indicators.webp}"
# The card's tiles take this colour from recording.json.
BACKGROUND="0d1322"

WORK_DIR="$(mktemp -d "/private/tmp/flowtype-indicators.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

xcodebuild \
  -scheme FlowType \
  -destination platform=macOS \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build >/dev/null

APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Flow Type.app/Contents/MacOS/Flow Type"

record() {
  "$APP" --record-indicator "$1" --indicator-color "$2" --record-scale "$3" \
    --record-background "$BACKGROUND" --record-output "$WORK_DIR/frames/$1" | grep '^Wrote'
}

record Waves Blue 3
record Dots Violet 3
# Particles has no colours.
record Particles none 3
record Aurora Nebula 4

python3 -I scripts/readme_images.py indicators "$WORK_DIR/frames" "$WORK_DIR/cards"

# Frequent key frames: lossy partial frames leave visible edges in the glow.
img2webp -loop 0 -kmin 2 -kmax 4 -lossy -q 82 -m 6 -sharp_yuv -d 33 \
  -o "$OUTPUT" "$WORK_DIR"/cards/card-*.png

echo "$OUTPUT"
