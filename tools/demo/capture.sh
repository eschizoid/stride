#!/usr/bin/env bash
# Records one rectangle of the screen (x y width height in points, from
# $DEMO_DIR/region) at the display's pixel scale with ffmpeg's macOS screen
# device: the contents of the stride window and the demo terminal side by side,
# with their title bars, the menu bar and everything else left out.
# `start` logs the epoch the capture began to cap_start, which compose.sh
# aligns against the terminal's marks; `stop` ends it with SIGTERM (a
# background job ignores SIGINT), on which ffmpeg finalizes the file.
set -euo pipefail

DEMO_DIR="${DEMO_DIR:-/tmp/stride-demo}"
scale="${SCREEN_SCALE:-2}"
case "${1:-}" in
  start)
    read -r x y w h < "$DEMO_DIR/region"
    /bin/rm -f "$DEMO_DIR/screen.mov"
    perl -MTime::HiRes=time -e 'printf "%.3f\n", time' > "$DEMO_DIR/cap_start"
    ffmpeg -hide_banner -loglevel error -f avfoundation -framerate 30 -capture_cursor 0 -i "${SCREEN_DEVICE:-1}:none" \
      -vf "crop=$((w * scale)):$((h * scale)):$((x * scale)):$((y * scale))" -r 30 \
      -c:v h264_videotoolbox -b:v 40M "$DEMO_DIR/screen.mov" < /dev/null > "$DEMO_DIR/capture.log" 2>&1 &
    echo $! > "$DEMO_DIR/capture.pid"
    ;;
  stop)
    pid=$(cat "$DEMO_DIR/capture.pid")
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    /bin/rm -f "$DEMO_DIR/capture.pid"
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$DEMO_DIR/screen.mov"
    ;;
  *) echo "usage: capture.sh start|stop" >&2; exit 2 ;;
esac
