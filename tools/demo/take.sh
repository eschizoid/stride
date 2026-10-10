#!/usr/bin/env bash
# One take, start to finish: a fresh demo home, the facts read from it, the
# stride window and the demo terminal opened side by side, the screen capture
# started, then the terminal types and runs the script (drive.sh) while the
# window reacts to the directives it writes. One action belongs to the
# operator and the take waits for it: when $DEMO_DIR/cue appears, press "["
# in the stride window to step to an older session. Outputs land in
# $DEMO_DIR: screen.mov, marks, cap_start, facts.env.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
export DEMO_DIR="${DEMO_DIR:-/tmp/stride-demo}"
STRIDE_BIN_DIR="$(dirname "$(command -v "${STRIDE_BIN:-stride}")")"
export STRIDE_BIN_DIR
mkdir -p "$DEMO_DIR"
/bin/rm -f "$DEMO_DIR/marks" "$DEMO_DIR/cue" "$DEMO_DIR/go" "$DEMO_DIR/done"
pkill -f "$here/drive.sh" 2>/dev/null || true

"$here/setup.sh" > /dev/null
STRIDE_BIN="$STRIDE_BIN_DIR/stride" "$here/facts.sh" > /dev/null
"$here/window.sh"
"$here/terminal.sh" > /dev/null
echo "0 53 1600 900" > "$DEMO_DIR/region"
sleep 2
"$here/capture.sh" start
sleep 1
: > "$DEMO_DIR/go"
# another app coming to the front would cover the recorded rectangle: while the
# take runs, any other frontmost app sends both demo windows back on top
(while [ ! -f "$DEMO_DIR/done" ]; do
  front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null || true)
  case "$front" in stride-viz|Terminal|"") ;; *) osascript -e 'tell application "Terminal" to activate' -e 'tell application "System Events" to tell process "stride-viz" to set frontmost to true' >/dev/null 2>&1 || true ;; esac
  sleep 1
done) &
until [ -f "$DEMO_DIR/cue" ]; do sleep 0.2; done
echo "CUE: press [ in the stride window now"
until [ -f "$DEMO_DIR/done" ]; do sleep 0.5; done
sleep 1
"$here/capture.sh" stop > /dev/null
osascript -e 'tell application "Terminal" to close (every window whose name contains "stride") saving no' > /dev/null 2>&1 || true
pkill -f "stride-viz $DEMO_DIR/home/.stride" 2>/dev/null || true
echo "take: $DEMO_DIR/screen.mov"
