#!/usr/bin/env bash
# Edits a take into the finished video: the screen capture cut to start at the
# first prompt (mark 1), scaled to 1440p, with the title card over the first
# scene, the end card over the last, a caption band per scene and, when
# voice.sh has rendered it, each scene's narration starting just after its
# scene does. Scene times come from scenes.tsv and the take's marks; the
# capture is aligned to them by the epoch the capture started at. The cards
# and captions are drawn by headless Chrome from HTML in stride's own faces
# (Quicksand, JetBrains Mono), since this ffmpeg has no text filter.
#
# Outputs in $DEMO_DIR/out: stride-demo-1440p.mp4, stride-demo-1080p.mp4,
# poster.png (a frame from the steering scene), poster.gif (six seconds of it,
# for the README) and contact-sheet.png (twelve frames across the cut, to check
# before publishing that nothing but the two demo windows was recorded).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="${DEMO_DIR:-/tmp/stride-demo}"
out="$DEMO_DIR/out"; work="$DEMO_DIR/work"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
fonts="$HOME/.stride/fonts"; icon="$HOME/.stride/img/stride-icon.png"
/bin/rm -rf "$work"; mkdir -p "$out" "$work"
for f in "$fonts/Quicksand-Medium.ttf" "$fonts/JetBrainsMono-Regular.ttf" "$chrome" "$DEMO_DIR/screen.mov" "$DEMO_DIR/marks" "$DEMO_DIR/cap_start"; do
  [ -e "$f" ] || { echo "compose: missing $f" >&2; exit 1; }
done

mark() { sed -n "$(($1 + 1))p" "$DEMO_DIR/marks"; }
t0=$(mark 1)
ss=$(echo "$t0 - $(cat "$DEMO_DIR/cap_start")" | bc -l)

# scene table with resolved times: scene start end layout caption
grep -v '^#' "$here/scenes.tsv" | while IFS=$'\t' read -r scene m off layout caption _; do
  printf '%s\t%.3f\t%s\t%s\n' "$scene" "$(echo "$(mark "$m") - $t0 + $off" | bc -l)" "$layout" "$caption"
done > "$work/starts"
end_start=$(awk -F'\t' '$1 == "end" {print $2}' "$work/starts")
dur=$(echo "$end_start + 8.5" | bc -l)
awk -F'\t' -v d="$dur" '{s[NR] = $0; t[NR] = $2} END {for (i = 1; i <= NR; i++) {split(s[i], f, "\t"); printf "%s\t%s\t%s\t%s\t%s\n", f[1], f[2], (i < NR ? t[i + 1] : d), f[3], f[4]}}' "$work/starts" > "$work/scenes"

# HTML to a 2560x1440 PNG, transparent wherever the page draws nothing
render() { # html-file png-file
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=2560,1440 --screenshot="$2" "file://$1" > /dev/null 2>&1
  [ -s "$2" ] || { echo "compose: Chrome drew nothing for $1" >&2; exit 1; }
}
css="@font-face{font-family:Q;src:url('file://$fonts/Quicksand-Medium.ttf')}@font-face{font-family:M;src:url('file://$fonts/JetBrainsMono-Regular.ttf')}html,body{margin:0;width:2560px;height:1440px;background:transparent}"
esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
card() { # png headline line small
  local img=""; [ -f "$icon" ] && img="<img src='file://$icon' style='width:220px;margin-bottom:40px'>"
  cat > "$work/card.html" <<HTML
<html><head><style>$css .c{width:2560px;height:1440px;background:#0f0f14;display:flex;flex-direction:column;align-items:center;justify-content:center}
.a{font:150px Q;color:#f2f2f7}.b{font:56px Q;color:#9a9aae;margin-top:34px}.s{font:34px M;color:#5fd7af;margin-top:70px}</style></head>
<body><div class="c">$img<div class="a">$(printf '%s' "$2" | esc)</div><div class="b">$(printf '%s' "$3" | esc)</div><div class="s">$(printf '%s' "$4" | esc)</div></div></body></html>
HTML
  render "$work/card.html" "$1"
}
card "$work/title.png" "stride" "$(awk -F'\t' '$1 == "title" {print $5}' "$work/scenes")" "Claude drives the CLI and the window; every number comes from stride"
card "$work/end.png" "stride" "$(awk -F'\t' '$1 == "end" {print $5}' "$work/scenes")" "github.com/eschizoid/stride"

# a caption band per screen scene, each its own transparent layer
vin=(); vchain=""; k=3; last="v0"
while IFS=$'\t' read -r scene start end layout caption; do
  case "$layout" in title|end) continue ;; esac
  cat > "$work/cap.html" <<HTML
<html><head><style>$css .b{position:absolute;left:330px;top:1290px;width:1900px;height:104px;background:rgba(11,11,16,.82);border-radius:14px;display:flex;align-items:center;justify-content:center;font:50px Q;color:#f2f2f7}</style></head>
<body><div class="b">$(printf '%s' "$caption" | esc)</div></body></html>
HTML
  render "$work/cap.html" "$work/cap-$scene.png"
  vin+=(-loop 1 -t "$dur" -i "$work/cap-$scene.png")
  vchain="$vchain[$last][$k:v]overlay=enable='between(t,$start,$end)'[c$k];"; last="c$k"; k=$((k + 1))
done < "$work/scenes"

# narration: each clip delayed to its scene's start, half a second in
ain=(); afilter=""; a0=$k
if [ -f "$DEMO_DIR/voice/title.mp3" ]; then
  while IFS=$'\t' read -r scene start _ _ _; do
    [ -f "$DEMO_DIR/voice/$scene.mp3" ] || { echo "compose: no narration for $scene" >&2; exit 1; }
    ain+=(-i "$DEMO_DIR/voice/$scene.mp3")
    ms=$(printf '%.0f' "$(echo "($start + 0.5) * 1000" | bc -l)")
    afilter="$afilter[$k:a]adelay=$ms|$ms[a$k];"; k=$((k + 1))
  done < "$work/scenes"
  labels=$(seq "$a0" $((k - 1)) | sed 's/.*/[a&]/' | tr -d '\n')
  afilter="$afilter${labels}amix=inputs=$((k - a0)):duration=longest:normalize=0,apad,atrim=0:$dur,loudnorm=I=-16:TP=-1.5:LRA=11[a]"
else
  echo "compose: no narration yet (voice.sh render NAME); writing a silent cut" >&2
  ain=(-f lavfi -t "$dur" -i anullsrc=r=48000:cl=stereo); afilter="[$k:a]anull[a]"
fi

title_end=$(awk -F'\t' '$1 == "title" {print $3}' "$work/scenes")
fade_out=$(echo "$title_end - 0.8" | bc -l)
ffmpeg -hide_banner -loglevel error -y \
  -ss "$ss" -t "$dur" -i "$DEMO_DIR/screen.mov" \
  -loop 1 -t "$dur" -i "$work/title.png" -loop 1 -t "$dur" -i "$work/end.png" "${vin[@]}" "${ain[@]}" \
  -filter_complex "[0:v]fps=30,scale=2560:1440:flags=lanczos,format=yuv420p[v0];${vchain}[1:v]format=rgba,fade=t=out:st=$fade_out:d=0.8:alpha=1[ti];[$last][ti]overlay=enable='lte(t,$title_end)'[t1];[2:v]format=rgba,fade=t=in:st=$end_start:d=0.7:alpha=1[en];[t1][en]overlay=enable='gte(t,$end_start)',format=yuv420p[v];$afilter" \
  -map "[v]" -map "[a]" -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart \
  "$out/stride-demo-1440p.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$out/stride-demo-1440p.mp4" -vf scale=1920:1080:flags=lanczos \
  -c:v libx264 -preset slow -crf 19 -c:a copy -movflags +faststart "$out/stride-demo-1080p.mp4"

verify=$(awk -F'\t' '$1 == "verify" {print $2}' "$work/scenes")
ffmpeg -hide_banner -loglevel error -y -ss "$(echo "$verify - 1.5" | bc -l)" -i "$out/stride-demo-1440p.mp4" -frames:v 1 "$out/poster.png"
ffmpeg -hide_banner -loglevel error -y -ss "$(echo "$verify - 6" | bc -l)" -t 6 -i "$out/stride-demo-1440p.mp4" \
  -vf "fps=12,scale=1000:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160[p];[b][p]paletteuse=dither=sierra2_4a" -loop 0 "$out/poster.gif"
# twelve frames across the cut in one image, to check before anything is
# published that only the two demo windows ever reached the capture
for i in $(seq 0 11); do
  ffmpeg -hide_banner -loglevel error -y -ss "$(echo "$dur * ($i + 0.5) / 12" | bc -l)" -i "$out/stride-demo-1080p.mp4" -frames:v 1 -vf scale=640:-1 "$work/sheet-$i.png"
done
ffmpeg -hide_banner -loglevel error -y $(for i in $(seq 0 11); do printf -- "-i %s " "$work/sheet-$i.png"; done) \
  -filter_complex "[0][1][2][3]hstack=4[a];[4][5][6][7]hstack=4[b];[8][9][10][11]hstack=4[c];[a][b][c]vstack=3" "$out/contact-sheet.png"
for f in "$out"/*; do printf '%s  %s\n' "$(du -h "$f" | cut -f1)" "$f"; done
printf 'length %.1fs\n' "$dur"
