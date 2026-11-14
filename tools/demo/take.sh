#!/usr/bin/env bash
# One take, start to finish: a fresh demo home, the facts read from it, the
# stride window and the demo terminal opened side by side, the screen capture
# started, then the terminal types and runs the script (drive.sh) while the
# window reacts to the directives it writes. Two key presses in the stride
# window are the athlete's, and the take cues each with a chime (sound is not
# recorded) and a line on its own output: at CUE press "[" (step to an older
# session), at CUE2 press "R" (reload, so the plan view shows the edit). The
# capture records a rectangle of the screen, so nothing else may come in front
# of the two windows while it runs: keep your hands off the Mac otherwise, and
# quit chat apps whose notifications or windows could appear. A guard sends
# both windows back on top if another app takes the front. Outputs land in
# $DEMO_DIR: screen.mov, marks, cap_start, facts.env.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
export DEMO_DIR="${DEMO_DIR:-/tmp/stride-demo}"
STRIDE_BIN_DIR="$(dirname "$(command -v "${STRIDE_BIN:-stride}")")"
export STRIDE_BIN_DIR
mkdir -p "$DEMO_DIR"
/bin/rm -f "$DEMO_DIR/marks" "$DEMO_DIR/cue" "$DEMO_DIR/go" "$DEMO_DIR/done" "$DEMO_DIR/cue2"
pkill -f "$here/drive.sh" 2>/dev/null || true

"$here/setup.sh" > /dev/null
STRIDE_BIN="$STRIDE_BIN_DIR/stride" "$here/facts.sh" > /dev/null
"$here/window.sh"
"$here/terminal.sh" > /dev/null
echo "0 53 1600 900" > "$DEMO_DIR/region"
sleep 2
"$here/capture.sh" start
sleep 2
kill -0 "$(cat "$DEMO_DIR/capture.pid")" 2>/dev/null || { echo "take: the screen capture stopped at once; see $DEMO_DIR/capture.log" >&2; exit 1; }
: > "$DEMO_DIR/go"
# another app coming to the front would cover the recorded rectangle: while the
# take runs, any other frontmost app sends both demo windows back on top, and a
# hidden Terminal is shown again
(while [ ! -f "$DEMO_DIR/done" ]; do
  front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null || true)
  hidden=$(osascript -e 'tell application "System Events" to get visible of process "Terminal"' 2>/dev/null || true)
  if [ "$hidden" = false ]; then osascript -e 'tell application "System Events" to set visible of process "Terminal" to true' >/dev/null 2>&1 || true; fi
  case "$front" in stride-viz|Terminal|"") ;; *) osascript -e 'tell application "Terminal" to activate' -e 'tell application "System Events" to tell process "stride-viz" to set frontmost to true' >/dev/null 2>&1 || true ;; esac
  sleep 1
done) &
until [ -f "$DEMO_DIR/cue" ]; do sleep 0.2; done
afplay /System/Library/Sounds/Glass.aiff &
echo "CUE: press [ in the stride window now"
until [ -f "$DEMO_DIR/cue2" ]; do sleep 0.2; done
afplay /System/Library/Sounds/Glass.aiff &
echo "CUE2: press R in the stride window now"
until [ -f "$DEMO_DIR/done" ]; do sleep 0.5; done
sleep 1
"$here/capture.sh" stop > /dev/null
osascript -e 'tell application "Terminal" to close (every window whose name contains "stride") saving no' > /dev/null 2>&1 || true
pkill -f "stride-viz $DEMO_DIR/home/.stride" 2>/dev/null || true
echo "take: $DEMO_DIR/screen.mov"
