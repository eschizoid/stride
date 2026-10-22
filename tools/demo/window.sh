#!/usr/bin/env bash
# Opens the stride window against the demo home and parks it in the left part
# of the capture region, below the menu bar: 980 points wide, its minimum, and
# 928 tall, so its content under the 28-point title bar is 900. With the
# terminal beside it the two contents fill a 1600 by 900 rectangle, which is
# 16:9, leaves the title bars out of the capture and clears a Dock on the
# right of a 1680-point screen. The window draws at the scale its size calls
# for.
set -euo pipefail

DEMO_DIR="${DEMO_DIR:-/tmp/stride-demo}"
app="${STRIDE_VIZ:-$HOME/Applications/Stride.app/Contents/MacOS/stride-viz}"
home="$DEMO_DIR/home"

pkill -f "stride-viz $home/.stride" 2>/dev/null || true
(cd "$DEMO_DIR" && HOME="$home" "$app" "$home/.stride" "$DEMO_DIR" > "$DEMO_DIR/window.log" 2>&1 &)
for _ in $(seq 1 40); do
  osascript -e 'tell application "System Events" to tell process "stride-viz" to get position of window 1' >/dev/null 2>&1 && break
  sleep 0.5
done
osascript -e 'tell application "System Events" to tell process "stride-viz"' \
          -e 'set frontmost to true' \
          -e 'set position of window 1 to {0, 25}' \
          -e 'set size of window 1 to {980, 928}' \
          -e 'end tell' >/dev/null
# the splash hands over to the loaded board within a few seconds
sleep 6
