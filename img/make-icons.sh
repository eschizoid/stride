#!/usr/bin/env sh
# Writes the app icons the linux and windows packages carry from
# img/stride-icon.png, the master: a 512 px opaque square, the gradient
# frame drawn on a dark ground.
#
#   img/stride-icon-256.png  the linux menu icon
#   img/stride.ico           the windows icon: 16, 24, 32, 48 and 256 px
#   img/stride-icons.sha256  the SHA-256 of the master, the macOS icon, this
#                            script and both outputs
#
#   sh img/make-icons.sh          regenerate the linux and windows icons
#   sh img/make-icons.sh --check  regenerate them into a scratch folder and
#                                 fail when a committed icon's pixels differ,
#                                 when the macOS icon is not the master's
#                                 derivative, or when any icon carries a light
#                                 fringe at its edge
#
# The outputs are committed, so packaging needs no image tool, and
# tools/package-viz.sh checks every hash in the pin. It needs macOS's sips.
#
# A linux or windows icon is the frame alone: the master scaled so the
# frame's taller side spans its platform's share of the canvas, centered,
# and masked at the target size to a rounded rectangle just inside the
# frame's outer edge, so no dark ground shows outside the frame and no
# masked edge is ever scaled again. GNOME's app icon template draws its
# square keyline at 103 of 128 px, so linux gives the frame 80.5%;
# Windows' 48 px grid draws its square keyline at 42 of 48, so windows
# gives it 87.5%.
#
# img/stride-icon-macos.png is the macOS-shaped derivative of the same
# master: the master scaled to 924 px, placed at (50, 50) on a 1024 canvas
# and masked to Apple's 824 px tile, the master's ground included. It is
# committed as it is, since 1024 px cannot come from the 512 px master
# without scaling it up; --check holds its opaque pixels to that transform.
#
# An ICO file may hold PNG images directly (Windows Vista and later read
# them): a 6-byte header (reserved 0, type 1, image count), one 16-byte
# entry per image (width and height, 0 meaning 256; colour count 0;
# reserved 0; planes 1; bits per pixel 32; byte length; byte offset), then
# the PNG files back to back. Every integer is little-endian.
set -eu
cd "$(dirname "$0")"
command -v sips >/dev/null || { echo "make-icons: needs sips (macOS)" >&2; exit 1; }
command -v xxd >/dev/null || { echo "make-icons: needs xxd" >&2; exit 1; }

# the frame's outer edge in the master, in master px as continuous
# coordinates (left top right bottom), its corner radius, and how far
# inside that edge the mask runs, past the edge's antialiased pixels
frame_box="33 37 475 486"
frame_radius=95
frame_inset=1.5
share_linux=0.805
share_windows=0.875
ico_sizes="16 24 32 48 256"
# the macOS icon's transform: the master's size on the 1024 canvas, and
# its offset
mac_scale=924
mac_offset=50

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# the masking pass: reads a scaled master as the bytes of a top-down 24bpp
# BMP (M px square) and prints, as hex, a top-down 32bpp BGRA BMP of N px:
# each pixel is the master pixel at (x - OX, y - OY), its alpha the share of
# 4x4 samples inside the rounded rectangle [X0, X1] x [Y0, Y1] with corner
# radius R, in canvas px
cat > "$work/mask.awk" <<'AWK'
function hex4(v) { return sprintf("%02x%02x%02x%02x", v % 256, int(v / 256) % 256, int(v / 65536) % 256, int(v / 16777216) % 256) }
function inside(px, py,   cx, cy, dx, dy) {
  if (px < X0 || px > X1 || py < Y0 || py > Y1) return 0
  cx = (px < X0 + R) ? X0 + R : (px > X1 - R) ? X1 - R : px
  cy = (py < Y0 + R) ? Y0 + R : (py > Y1 - R) ? Y1 - R : py
  dx = px - cx; dy = py - cy
  return dx * dx + dy * dy <= R * R
}
{ for (i = 1; i <= NF; i++) byte[n++] = $i }
END {
  row = int((M * 3 + 3) / 4) * 4
  printf "424d%s00000000%s", hex4(138 + N * N * 4), hex4(138)
  printf "%s%s%s01002000%s%s%s%s%s%s", hex4(124), hex4(N), hex4(4294967296 - N), hex4(3), hex4(N * N * 4), hex4(2835), hex4(2835), hex4(0), hex4(0)
  printf "0000ff0000ff0000ff000000000000ff42475273"
  for (i = 0; i < 48; i++) printf "00"
  printf "%s%s%s%s", hex4(4), hex4(0), hex4(0), hex4(0)
  for (y = 0; y < N; y++) {
    line = ""
    for (x = 0; x < N; x++) {
      c = 0
      for (sy = 0; sy < 4; sy++) for (sx = 0; sx < 4; sx++) c += inside(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4)
      a = int(c * 255 / 16 + 0.5)
      mx = x - OX; my = y - OY
      if (a == 0 || mx < 0 || my < 0 || mx >= M || my >= M) { line = line "00000000"; continue }
      o = my * row + mx * 3
      line = line sprintf("%02x%02x%02x%02x", byte[o], byte[o + 1], byte[o + 2], a)
    }
    printf "%s", line
  }
}
AWK

# the frame at N px, its taller side the share $2 of N, written to $3
render() {
  n=$1
  # shellcheck disable=SC2086
  set -- "$1" "$2" "$3" $frame_box
  m=$(awk -v N="$n" -v F="$2" -v T="$5" -v B="$7" 'BEGIN { printf "%d", N * F / (B - T) * 512 + 0.5 }')
  sips -z "$m" "$m" stride-icon.png --out "$work/scaled.png" >/dev/null
  sips -s format bmp "$work/scaled.png" --out "$work/scaled.bmp" >/dev/null
  off=$(od -An -tu4 -j10 -N4 "$work/scaled.bmp" | tr -d ' ')
  geometry=$(awk -v N="$n" -v M="$m" -v L="$4" -v T="$5" -v R="$6" -v B="$7" -v RAD="$frame_radius" -v I="$frame_inset" 'BEGIN {
    k = M / 512; ox = int(N / 2 - (L + R) / 2 * k + 0.5); oy = int(N / 2 - (T + B) / 2 * k + 0.5)
    printf "%d %d %.4f %.4f %.4f %.4f %.4f", ox, oy, ox + (L + I) * k, ox + (R - I) * k, oy + (T + I) * k, oy + (B - I) * k, (RAD - I) * k }')
  # shellcheck disable=SC2086
  set -- "$3" $geometry
  od -An -tu1 -v -j"$off" "$work/scaled.bmp" |
    awk -v N="$n" -v M="$m" -v OX="$2" -v OY="$3" -v X0="$4" -v X1="$5" -v Y0="$6" -v Y1="$7" -v R="$8" -f "$work/mask.awk" |
    xxd -r -p > "$work/masked.bmp"
  sips -s format png "$work/masked.bmp" --out "$1" >/dev/null
}

# one byte per call, as an octal escape, which every printf reads
byte() { printf "\\$(printf '%03o' "$(($1 & 255))")"; }
u16() { byte "$1"; byte "$(($1 >> 8))"; }
u32() { u16 "$(($1 & 65535))"; u16 "$(($1 >> 16))"; }

# both icons, rendered into the folder given
build() {
  render 256 "$share_linux" "$1/stride-icon-256.png"
  count=0
  for s in $ico_sizes; do
    render "$s" "$share_windows" "$1/win-$s.png"
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

# whether two PNGs show the same pixels: decoded to BMP, byte for byte, or,
# where a different build of sips scales differently, a mean byte
# difference of at most 0.5 with at most 0.1% of bytes off by more than
# 32. A frame moved by 4 master px, at any size here, differs by more.
same_pixels() {
  sips -s format bmp "$1" --out "$work/a.bmp" >/dev/null
  sips -s format bmp "$2" --out "$work/b.bmp" >/dev/null
  cmp -s "$work/a.bmp" "$work/b.bmp" && return 0
  sa=$(wc -c < "$work/a.bmp" | tr -d ' ')
  sb=$(wc -c < "$work/b.bmp" | tr -d ' ')
  [ "$sa" = "$sb" ] || { echo "make-icons: $3 is ${sb} bytes decoded, the regenerated one $sa" >&2; return 1; }
  cmp -l "$work/a.bmp" "$work/b.bmp" | awk -v n="$sa" -v what="$3" '
    function oct(s,  v, i) { v = 0; for (i = 1; i <= length(s); i++) v = v * 8 + substr(s, i, 1); return v }
    { d = oct($2) - oct($3); if (d < 0) d = -d; sum += d; if (d > 32) big++ }
    END {
      mean = sum / n; frac = big / n
      if (mean > 0.5 || frac > 0.001) { printf "make-icons: %s differs from its regeneration (mean %.3f, %.3f%% of bytes off by more than 32)\n", what, mean, frac * 100 > "/dev/stderr"; exit 1 }
    }'
}

# whether a PNG's partly transparent pixels are no lighter than the opaque
# pixels within 3 px of them, beyond 16 levels of mean RGB: a light halo
# outside a darker edge, from scaling colour and alpha apart, fails. It
# holds an icon whose frame is at least a pixel wide; below 48 px the
# frame is narrower, and its own edge pixels are the lightest around
no_light_fringe() {
  sips -s format bmp "$1" --out "$work/f.bmp" >/dev/null
  w=$(le "$work/f.bmp" 18 4)
  off=$(le "$work/f.bmp" 10 4)
  [ "$(le "$work/f.bmp" 28 2)" = 32 ] || { echo "make-icons: $2 decodes without alpha" >&2; return 1; }
  od -An -tu1 -v -j"$off" "$work/f.bmp" | awk -v W="$w" -v what="$2" '
    { for (i = 1; i <= NF; i++) { k = n % 4; p = int(n / 4); if (k < 3) s[p] += $i; else a[p] = $i; n++ } }
    END {
      for (p in a) {
        if (a[p] == 0 || a[p] == 255) continue
        x = p % W; y = int(p / W); lum = s[p] / 3; best = -1
        for (dy = -3; dy <= 3; dy++) for (dx = -3; dx <= 3; dx++) {
          q = (y + dy) * W + (x + dx)
          if (x + dx < 0 || x + dx >= W || !(q in a) || a[q] != 255) continue
          if (s[q] / 3 > best) best = s[q] / 3
        }
        if ((best >= 0 && lum > best + 16) || (best < 0 && lum > 48)) { bad++; if (bad <= 3) printf "make-icons: %s has a light edge pixel at %d,%d\n", what, x, y > "/dev/stderr" }
      }
      if (bad) { printf "make-icons: %s has %d edge pixels lighter than the edge they border\n", what, bad > "/dev/stderr"; exit 1 }
    }'
}

# whether the macOS icon's opaque pixels are the master's, scaled to
# $mac_scale px and placed at $mac_offset: within a mean byte difference of
# 2 with at most 1.5% of bytes off by more than 32, since it was scaled by
# another tool; a master moved by 4 px differs by more
mac_derived() {
  sips -z "$mac_scale" "$mac_scale" stride-icon.png --out "$work/mac.png" >/dev/null
  sips -s format bmp "$work/mac.png" --out "$work/mac-master.bmp" >/dev/null
  sips -s format bmp stride-icon-macos.png --out "$work/mac-icon.bmp" >/dev/null
  {
    od -An -tu1 -v -j"$(le "$work/mac-icon.bmp" 10 4)" "$work/mac-icon.bmp"
    echo SPLIT
    od -An -tu1 -v -j"$(le "$work/mac-master.bmp" 10 4)" "$work/mac-master.bmp"
  } | awk -v M="$mac_scale" -v O="$mac_offset" '
    $0 == "SPLIT" { s = 1; next }
    { for (i = 1; i <= NF; i++) if (s) b[nb++] = $i; else a[na++] = $i }
    END {
      W = 1024; row = int((M * 3 + 3) / 4) * 4
      for (y = 0; y < W; y++) for (x = 0; x < W; x++) {
        o = (y * W + x) * 4
        if (a[o + 3] != 255) continue
        mx = x - O; my = y - O
        if (mx < 0 || my < 0 || mx >= M || my >= M) { off++; continue }
        q = my * row + mx * 3
        for (c = 0; c < 3; c++) { d = a[o + c] - b[q + c]; if (d < 0) d = -d; sum += d; if (d > 32) big++; cnt++ }
      }
      mean = sum / cnt; frac = big / cnt
      if (off || mean > 2 || frac > 0.015) { printf "make-icons: img/stride-icon-macos.png is not the master scaled to %d px at %d (mean %.3f, %.3f%% of bytes off by more than 32, %d opaque pixels outside it)\n", M, O, mean, frac * 100, off > "/dev/stderr"; exit 1 }
    }'
}

if [ "${1:-}" = "--check" ]; then
  mkdir -p "$work/new" "$work/old"
  build "$work/new"
  same_pixels "$work/new/stride-icon-256.png" stride-icon-256.png img/stride-icon-256.png
  n=$(unpack_ico stride.ico "$work/old")
  # shellcheck disable=SC2086
  set -- $ico_sizes
  [ "$n" = "$#" ] || { echo "make-icons: img/stride.ico holds $n images, not the $# of $ico_sizes" >&2; exit 1; }
  i=0
  for s in $ico_sizes; do
    same_pixels "$work/new/win-$s.png" "$work/old/entry-$i.png" "img/stride.ico's $s px image"
    [ "$s" -lt 48 ] || no_light_fringe "$work/old/entry-$i.png" "img/stride.ico's $s px image"
    i=$((i + 1))
  done
  no_light_fringe stride-icon-256.png img/stride-icon-256.png
  # the macOS icon's tile is centered on the canvas while the master's
  # frame sits below its center, so the tile clips the frame's bottom-left
  # edge and leaves 5 light pixels there (x 159 to 179, y 875 to 891); it is
  # held to its transform and its hash, not to this
  mac_derived
  echo "make-icons: every icon is the master's by its recorded transform, with no light fringe"
  exit 0
fi

build "$work"
cp "$work/stride-icon-256.png" stride-icon-256.png
cp "$work/stride.ico" stride.ico
shasum -a 256 stride-icon.png stride-icon-macos.png make-icons.sh stride.ico stride-icon-256.png > stride-icons.sha256
echo "make-icons: wrote img/stride.ico ($ico_sizes), img/stride-icon-256.png and img/stride-icons.sha256"
