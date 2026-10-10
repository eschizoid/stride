#!/usr/bin/env bash
# The narration, spoken by an ElevenLabs voice. The API key is read from
# ~/.config/stride-demo/elevenlabs.key (or $ELEVENLABS_API_KEY) and handed to
# curl through a header file readable only by its owner, so it never appears
# on a command line, in a log or on screen. The script text leaves the
# machine; nothing else does.
#
#   voice.sh voices              list the account's voices (name, id, labels)
#   voice.sh samples [N ...]     render the opening line in each named voice
#                                (default: the first three listed) to
#                                $DEMO_DIR/voice/sample-<name>.mp3
#   voice.sh render NAME         render every scene's narration, filled from
#                                facts.env, to $DEMO_DIR/voice/<scene>.mp3 and
#                                report each clip's length against the time
#                                its scene has in the take
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="${DEMO_DIR:-/tmp/stride-demo}"
out="$DEMO_DIR/voice"
model="${ELEVENLABS_MODEL:-eleven_multilingual_v2}"
api="https://api.elevenlabs.io/v1"
mkdir -p "$out"

hdr=$(mktemp); chmod 600 "$hdr"; trap '/bin/rm -f "$hdr"' EXIT
key="${ELEVENLABS_API_KEY:-}"
[ -n "$key" ] || key=$(tr -d "[:space:]" 2>/dev/null < "$HOME/.config/stride-demo/elevenlabs.key" || true)
[ -n "$key" ] || { echo "voice: no key in ~/.config/stride-demo/elevenlabs.key" >&2; exit 1; }
printf 'xi-api-key: %s\n' "$key" > "$hdr"; unset key

voices_json() {
  local code
  code=$(curl -sS -o "$out/voices.json" -w '%{http_code}' -H @"$hdr" "$api/voices")
  [ "$code" = 200 ] || { echo "voice: listing voices returned HTTP $code: $(head -c 300 "$out/voices.json")" >&2; exit 1; }
}
voice_id() { jq -r --arg n "$1" '[.voices[] | select((.name | ascii_downcase | split(" ")[0]) == ($n | ascii_downcase) or (.name | ascii_downcase) == ($n | ascii_downcase))][0].voice_id // empty' "$out/voices.json"; }
speak() { # text voice_id file
  local code body
  body=$(jq -n --arg t "$1" --arg m "$model" '{text: $t, model_id: $m, voice_settings: {stability: 0.45, similarity_boost: 0.8, style: 0.15, use_speaker_boost: true}}')
  code=$(curl -sS -o "$3" -w '%{http_code}' -H @"$hdr" -H 'Content-Type: application/json' -H 'Accept: audio/mpeg' \
    -d "$body" "$api/text-to-speech/$2?output_format=mp3_44100_192")
  [ "$code" = 200 ] || { echo "voice: speaking returned HTTP $code: $(head -c 300 "$3")" >&2; /bin/rm -f "$3"; exit 1; }
}
fill() { # narration with {KEY} placeholders filled from facts.env
  local s="$1" k v
  while IFS='=' read -r k v; do [ -n "$k" ] && s="${s//\{$k\}/$v}"; done < "$DEMO_DIR/facts.env"
  case "$s" in *'{'*'}'*) echo "voice: unfilled placeholder in: $s" >&2; exit 1 ;; esac
  printf '%s' "$s"
}
length() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

case "${1:-}" in
  voices)
    voices_json
    jq -r '.voices[] | "\(.name)\t\(.voice_id)\t\(.labels | to_entries | map(.value) | join(", "))"' "$out/voices.json"
    ;;
  samples)
    voices_json; shift
    names=("$@"); [ ${#names[@]} -gt 0 ] || { names=(); while IFS= read -r n; do names+=("$n"); done < <(jq -r ".voices[:3][].name | split(\" \")[0]" "$out/voices.json"); }
    line=$(awk -F'\t' '$1 == "title" {print $6}' "$here/scenes.tsv")
    for n in "${names[@]}"; do
      id=$(voice_id "$n"); [ -n "$id" ] || { echo "voice: no voice named $n" >&2; exit 1; }
      speak "$line" "$id" "$out/sample-$n.mp3"; echo "$out/sample-$n.mp3  $(length "$out/sample-$n.mp3")s"
    done
    ;;
  render)
    [ -n "${2:-}" ] || { echo "usage: voice.sh render NAME" >&2; exit 2; }
    [ -f "$DEMO_DIR/facts.env" ] || { echo "voice: run a take (or facts.sh) first" >&2; exit 1; }
    voices_json; id=$(voice_id "$2"); [ -n "$id" ] || { echo "voice: no voice named $2" >&2; exit 1; }
    echo "$2" > "$out/voice-name"
    grep -v '^#' "$here/scenes.tsv" | while IFS=$'\t' read -r scene _ _ _ _ text; do
      speak "$(fill "$text")" "$id" "$out/$scene.mp3"
      printf '%-8s %5.1fs\n' "$scene" "$(length "$out/$scene.mp3")"
    done
    ;;
  *) sed -n '9,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
