#!/usr/bin/env sh
# Writes the two app icons the linux and windows packages carry, from the
# image the macOS app's icon is built from, so all three show the same
# artwork:
#
#   img/stride-icon-256.png  the linux menu icon
#   img/stride.ico           the windows shortcut icon: 16, 32, 48 and 256 px
#   img/stride-icons.sha256  the SHA-256 of the source and of both outputs
#
# The outputs are committed, so packaging needs no image tool, and
# tools/package-viz.sh checks every hash in the pin against the files, so
# an icon not regenerated after the artwork changes fails the build. Rerun
# this after changing img/stride-icon-macos.png; it needs macOS's sips.
# The source is the whole 1024 canvas, inset tile and rounded corners
# included, exactly as the macOS icon shows it.
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
sizes="16 32 48 256"
for s in $sizes; do
  sips -z "$s" "$s" stride-icon-macos.png --out "$work/$s.png" >/dev/null
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
shasum -a 256 stride-icon-macos.png stride.ico stride-icon-256.png > stride-icons.sha256
echo "make-icons: wrote img/stride.ico ($sizes), img/stride-icon-256.png and img/stride-icons.sha256"
