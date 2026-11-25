#!/usr/bin/env sh
# Writes the two app icons the linux and windows packages carry, from the
# macOS icon's artwork:
#
#   img/stride-icon-256.png  the linux menu icon
#   img/stride.ico           the windows shortcut icon: 16, 32, 48 and 256 px
#
# Both outputs are committed, so packaging needs no image tool; rerun this
# after the artwork changes. It needs macOS's sips. stride-icon-macos.png
# insets its tile on a transparent 1024 canvas; the centered 848 square
# holds the tile with a thin margin, so a 16 px icon is not mostly padding.
#
# An ICO file may hold PNG images directly (Windows Vista and later read
# them): a 6-byte header (reserved 0, type 1, image count), one 16-byte
# entry per image (width and height, 0 meaning 256; colour count 0;
# reserved 0; planes 1; bits per pixel 32; byte length; byte offset), then
# the PNG files back to back. Every integer is little-endian.
set -eu
cd "$(dirname "$0")"
command -v sips >/dev/null || { echo "make-icons: needs sips (macOS)" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sips -c 848 848 stride-icon-macos.png --out "$work/tile.png" >/dev/null
sizes="16 32 48 256"
for s in $sizes; do
  sips -z "$s" "$s" "$work/tile.png" --out "$work/$s.png" >/dev/null
done
cp "$work/256.png" stride-icon-256.png

# one byte per call, as an octal escape, which every printf reads
byte() { printf "\\$(printf '%03o' "$(($1 & 255))")"; }
u16() { byte "$1"; byte "$(($1 >> 8))"; }
u32() { u16 "$(($1 & 65535))"; u16 "$(($1 >> 16))"; }

count=0
for s in $sizes; do count=$((count + 1)); done
{
  u16 0
  u16 1
  u16 "$count"
  offset=$((6 + 16 * count))
  for s in $sizes; do
    len=$(wc -c < "$work/$s.png" | tr -d ' ')
    byte "$((s % 256))"
    byte "$((s % 256))"
    byte 0
    byte 0
    u16 1
    u16 32
    u32 "$len"
    u32 "$offset"
    offset=$((offset + len))
  done
  for s in $sizes; do cat "$work/$s.png"; done
} > "$work/stride.ico"
mv "$work/stride.ico" stride.ico
echo "make-icons: wrote img/stride.ico ($sizes) and img/stride-icon-256.png"
