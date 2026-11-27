#!/usr/bin/env bash
# Opens the demo's Terminal window beside the stride window (980..1600 by
# 25..953 points, its content below the title bar matching the window's) with
# a dark palette and a 10-point Menlo, which fits the 99-column tables stride
# prints in the 620 points it has. The title bar is outside the capture. The tab runs
# drive.sh, which waits for $DEMO_DIR/go before it types anything. The colours
# and font are set on this tab only, not on a Terminal profile.
set -euo pipefail

DEMO_DIR="${DEMO_DIR:-/tmp/stride-demo}"
here="$(cd "$(dirname "$0")" && pwd)"
cmd="clear; DEMO_DIR='$DEMO_DIR' STRIDE_BIN_DIR='${STRIDE_BIN_DIR:?}' exec bash --noprofile --norc '$here/drive.sh'"
osascript <<OSA
tell application "Terminal"
  activate
  set t to do script "$cmd"
  set w to front window
  set font name of t to "Menlo"
  set font size of t to 10
  set custom title of t to "stride"
  set title displays custom title of t to true
  set background color of t to {4112, 4112, 5654}
  set normal text color of t to {55512, 55512, 58082}
  set bold text color of t to {65535, 65535, 65535}
  set cursor color of t to {24415, 55255, 44975}
  set bounds of w to {980, 25, 1600, 953}
end tell
OSA
