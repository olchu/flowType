#!/bin/zsh
# Screenshots the Models and Indicator panes and builds Docs/images/settings.png.
# Opens a second copy of the installed app for a few seconds per pane: started
# by launchd rather than this shell, it has its own permissions and shows
# "Ready to use". Needs Pillow and Screen Recording access for the terminal.
set -euo pipefail

APP_BUNDLE="${APP_BUNDLE:-/Applications/Flow Type.app}"
OUTPUT="${OUTPUT:-Docs/images/settings.png}"
BINARY="$APP_BUNDLE/Contents/MacOS/Flow Type"

WORK_DIR="$(mktemp -d "/private/tmp/flowtype-settings.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/window.swift" <<'EOF'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows
where window[kCGWindowOwnerPID as String] as? Int32 == pid
    && window[kCGWindowName as String] as? String == "Flow Type Settings" {
    print(window[kCGWindowNumber as String]!)
    break
}
EOF

capture() {
  local before
  before="$(pgrep -n -f "$BINARY" || true)"
  open -n -a "$APP_BUNDLE" --args --open-settings --settings-pane "$1" --appearance dark
  # Long enough for the model to load and the status to turn ready.
  sleep 10
  local pid
  pid="$(pgrep -n -f "$BINARY")"
  if [[ "$pid" == "$before" ]]; then
    echo "No new copy of Flow Type started." >&2
    exit 1
  fi
  # Either step can fail, screencapture while the screen is locked; the
  # copy is closed either way.
  local window result=0
  window="$(swift "$WORK_DIR/window.swift" "$pid")" || result=$?
  [[ $result == 0 ]] && { screencapture -x -o -l"$window" "$WORK_DIR/$1.png" || result=$?; }
  kill "$pid"
  return $result
}

capture models
capture indicator

python3 -I scripts/readme_images.py settings "$WORK_DIR/models.png" "$WORK_DIR/indicator.png" "$OUTPUT"
echo "$OUTPUT"
