#!/usr/bin/env sh
# Writes the two app icons the linux and windows packages carry, from the
# image the macOS app's icon is built from, so all three show the same
# artwork:
#
#   img/stride-icon-256.png  the linux menu icon
#   img/stride.ico           the windows icon: 16, 24, 32, 48 and 256 px
#   img/stride-icons.sha256  the SHA-256 of the source, this script and both
#                            outputs
#
#   sh img/make-icons.sh          regenerate all three
#   sh img/make-icons.sh --check  regenerate into a scratch folder and fail
#                                 when a committed icon's pixels differ
#
# The outputs are committed, so packaging needs no image tool, and
# tools/package-viz.sh checks every hash in the pin, so an icon edited by
# hand, or this script changed without rerunning it, fails the build. It
# needs macOS's sips.
#
# Each platform's icon is the source cropped to a square, then scaled. The
# source's tile spans pixels 100 to 923 of its 1024 canvas, 80.5% of it,
# on Apple's macOS icon grid. GNOME's app icon template draws its square
# keyline at 103 of 128 px, the same 80.5%, so linux takes the whole
# canvas. Windows' 48 px icon grid draws its square keyline at 42 of 48,
# 87.5%, so windows takes the centered 942 px square, in which the 824 px
# tile fills 87.5%. A crop is "offsetY offsetX size" on the source.
#
# An ICO file may hold PNG images directly (Windows Vista and later read
# them): a 6-byte header (reserved 0, type 1, image count), one 16-byte
# entry per image (width and height, 0 meaning 256; colour count 0;
# reserved 0; planes 1; bits per pixel 32; byte length; byte offset), then
# the PNG files back to back. Every integer is little-endian.
set -eu
cd "$(dirname "$0")"
command -v sips >/dev/null || { echo "make-icons: needs sips (macOS)" >&2; exit 1; }

crop_linux="0 0 1024"
crop_windows="41 41 942"
ico_sizes="16 24 32 48 256"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# the source cropped to $2 ("offsetY offsetX size") and scaled to $1 px,
# written to $3
render() {
  # shellcheck disable=SC2086
  set -- "$1" $2 "$3"
  sips -c "$4" "$4" --cropOffset "$2" "$3" stride-icon-macos.png --out "$work/crop.png" >/dev/null
  sips -z "$1" "$1" "$work/crop.png" --out "$5" >/dev/null
}

# one byte per call, as an octal escape, which every printf reads
byte() { printf "\\$(printf '%03o' "$(($1 & 255))")"; }
u16() { byte "$1"; byte "$(($1 >> 8))"; }
u32() { u16 "$(($1 & 65535))"; u16 "$(($1 >> 16))"; }

# both icons, rendered into the folder given
build() {
  render 256 "$crop_linux" "$1/stride-icon-256.png"
  count=0
  for s in $ico_sizes; do
    render "$s" "$crop_windows" "$1/win-$s.png"
    count=$((count + 1))
  done
  {
    u16 0
    u16 1
    u16 "$count"
    offset=$((6 + 16 * count))
    for s in $ico_sizes; do
      len=$(wc -c < "$1/win-$s.png" | tr -d ' ')
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
    for s in $ico_sizes; do cat "$1/win-$s.png"; done
  } > "$1/stride.ico"
}

# the unsigned little-endian integer of $3 bytes at offset $2 in file $1
le() {
  od -An -tu1 -j "$2" -N "$3" "$1" | awk '{ for (i = NF; i >= 1; i--) v = v * 256 + $i } END { print v + 0 }'
}

# the ICO's images, by position, into $2/entry-N.png
unpack_ico() {
  n=$(le "$1" 4 2)
  i=0
  while [ "$i" -lt "$n" ]; do
    e=$((6 + 16 * i))
    tail -c +$(($(le "$1" $((e + 12)) 4) + 1)) "$1" | head -c "$(le "$1" $((e + 8)) 4)" > "$2/entry-$i.png"
    i=$((i + 1))
  done
  echo "$n"
}

# whether two PNGs show the same pixels, within what two builds of sips'
# scaler can differ by: decoded to BMP, the mean byte difference is at most
# 1 and at most 0.2% of bytes differ by more than 48. An image edited by
# hand, or rendered from another crop, differs by far more.
same_pixels() {
  sips -s format bmp "$1" --out "$work/a.bmp" >/dev/null
  sips -s format bmp "$2" --out "$work/b.bmp" >/dev/null
  sa=$(wc -c < "$work/a.bmp" | tr -d ' ')
  sb=$(wc -c < "$work/b.bmp" | tr -d ' ')
  [ "$sa" = "$sb" ] || { echo "make-icons: $3 is ${sb} bytes decoded, the regenerated one $sa" >&2; return 1; }
  cmp -l "$work/a.bmp" "$work/b.bmp" | awk -v n="$sa" -v what="$3" '
    function oct(s,  v, i) { v = 0; for (i = 1; i <= length(s); i++) v = v * 8 + substr(s, i, 1); return v }
    { d = oct($2) - oct($3); if (d < 0) d = -d; sum += d; if (d > 48) big++ }
    END {
      mean = sum / n; frac = big / n
      if (mean > 1 || frac > 0.002) { printf "make-icons: %s differs from its regeneration (mean %.3f, %.4f%% of bytes off by more than 48)\n", what, mean, frac * 100 > "/dev/stderr"; exit 1 }
    }'
}

if [ "${1:-}" = "--check" ]; then
  mkdir -p "$work/new" "$work/old"
  build "$work/new"
  same_pixels "$work/new/stride-icon-256.png" stride-icon-256.png img/stride-icon-256.png
  n=$(unpack_ico stride.ico "$work/old")
  set -- $ico_sizes
  [ "$n" = "$#" ] || { echo "make-icons: img/stride.ico holds $n images, not the $# of $ico_sizes" >&2; exit 1; }
  i=0
  for s in $ico_sizes; do
    same_pixels "$work/new/win-$s.png" "$work/old/entry-$i.png" "img/stride.ico's $s px image"
    i=$((i + 1))
  done
  echo "make-icons: every committed icon is its regeneration from img/stride-icon-macos.png"
  exit 0
fi

build "$work"
cp "$work/stride-icon-256.png" stride-icon-256.png
cp "$work/stride.ico" stride.ico
shasum -a 256 stride-icon-macos.png make-icons.sh stride.ico stride-icon-256.png > stride-icons.sha256
echo "make-icons: wrote img/stride.ico ($ico_sizes), img/stride-icon-256.png and img/stride-icons.sha256"
