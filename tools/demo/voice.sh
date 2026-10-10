#!/usr/bin/env bash
# The narration. Two engines, picked by VOICE_ENGINE:
#
# - say (the default): the voices installed on this Mac, through macOS `say`.
#   Nothing leaves the machine and no account is needed. The compact voices
#   ship with macOS; the Premium and Enhanced ones (System Settings,
#   Accessibility, Spoken Content, System Voice, Manage Voices) sound far more
#   natural and are used the same way once downloaded.
# - elevenlabs: an ElevenLabs voice. The API key is read from
#   ~/.config/stride-demo/elevenlabs.key (or $ELEVENLABS_API_KEY) and handed to
#   curl through a header file readable only by its owner, so it never appears
#   on a command line, in a log or on screen. The script text leaves the
#   machine; nothing else does.
#
#   voice.sh voices              list the voices the engine offers
#   voice.sh samples [N ...]     render the opening line in each named voice
#                                (default: a few English ones) to
#                                $DEMO_DIR/voice/sample-<name>.mp3
#   voice.sh render NAME         render every scene's narration, filled from
#                                facts.env, to $DEMO_DIR/voice/<scene>.mp3 and
#                                print each clip's length
#
# SAY_RATE sets the speaking rate for `say` in words per minute.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="${DEMO_DIR:-/tmp/stride-demo}"
engine="${VOICE_ENGINE:-say}"
out="$DEMO_DIR/voice"
mkdir -p "$out"

fill() { # narration with {KEY} placeholders filled from facts.env
  local s="$1" k v
  while IFS='=' read -r k v; do [ -n "$k" ] && s="${s//\{$k\}/$v}"; done < "$DEMO_DIR/facts.env"
  case "$s" in *'{'*'}'*) echo "voice: unfilled placeholder in: $s" >&2; exit 1 ;; esac
  printf '%s' "$s"
}
length() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
title_line() { awk -F'\t' '$1 == "title" {print $6}' "$here/scenes.tsv"; }

case "$engine" in
  say)
    # the novelty voices (Bells, Bubbles, Zarvox and the like) are left out
    voices() { say -v '?' | grep -E 'en_(US|GB|AU|IE|ZA|IN)' | grep -vE '^(Albert|Bad News|Bahh|Bells|Boing|Bubbles|Cellos|Wobble|Fred|Good News|Jester|Junior|Kathy|Organ|Superstar|Ralph|Trinoids|Whisper|Zarvox|Grandma|Grandpa) ' | sed -E 's/ +(en_[A-Z]+) +#.*/\t\1/'; }
    has_voice() { say -v '?' | grep -qF "$1 "; }
    speak() { # text voice file
      local aiff; aiff="$(mktemp -u).aiff"
      say -v "$2" -r "${SAY_RATE:-175}" -o "$aiff" "$1"
      ffmpeg -hide_banner -loglevel error -y -i "$aiff" -ar 44100 -ac 2 -c:a libmp3lame -b:a 192k "$3"
      /bin/rm -f "$aiff"
    }
    default_samples() { for n in "Samantha" "Daniel" "Reed (English (US))" "Shelley (English (US))" "Moira"; do has_voice "$n" && echo "$n"; done; }
    ;;
  elevenlabs)
    model="${ELEVENLABS_MODEL:-eleven_multilingual_v2}"; api="https://api.elevenlabs.io/v1"
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
    voices() { voices_json; jq -r '.voices[] | "\(.name)\t\(.labels | to_entries | map(.value) | join(", "))"' "$out/voices.json"; }
    has_voice() { [ -f "$out/voices.json" ] || voices_json; [ -n "$(voice_id "$1")" ]; }
    speak() { # text voice file
      local code body id
      id=$(voice_id "$2")
      body=$(jq -n --arg t "$1" --arg m "$model" '{text: $t, model_id: $m, voice_settings: {stability: 0.45, similarity_boost: 0.8, style: 0.15, use_speaker_boost: true}}')
      code=$(curl -sS -o "$3" -w '%{http_code}' -H @"$hdr" -H 'Content-Type: application/json' -H 'Accept: audio/mpeg' \
        -d "$body" "$api/text-to-speech/$id?output_format=mp3_44100_192")
      [ "$code" = 200 ] || { echo "voice: speaking returned HTTP $code: $(head -c 300 "$3")" >&2; /bin/rm -f "$3"; exit 1; }
    }
    default_samples() { voices_json; jq -r '.voices[:3][].name | split(" ")[0]' "$out/voices.json"; }
    ;;
  *) echo "voice: VOICE_ENGINE is say or elevenlabs, not $engine" >&2; exit 2 ;;
esac

case "${1:-}" in
  voices) voices ;;
  samples)
    shift
    names=("$@"); [ ${#names[@]} -gt 0 ] || { names=(); while IFS= read -r n; do names+=("$n"); done < <(default_samples); }
    line=$(title_line)
    for n in "${names[@]}"; do
      has_voice "$n" || { echo "voice: no voice named $n" >&2; exit 1; }
      f="$out/sample-${n// /_}.mp3"; speak "$line" "$n" "$f"; printf '%5.1fs  %s\n' "$(length "$f")" "$f"
    done
    ;;
  render)
    [ -n "${2:-}" ] || { echo "usage: voice.sh render NAME" >&2; exit 2; }
    [ -f "$DEMO_DIR/facts.env" ] || { echo "voice: run a take (or facts.sh) first" >&2; exit 1; }
    has_voice "$2" || { echo "voice: no voice named $2" >&2; exit 1; }
    echo "$engine $2" > "$out/voice-name"
    grep -v '^#' "$here/scenes.tsv" | while IFS=$'\t' read -r scene _ _ _ _ text; do
      speak "$(fill "$text")" "$2" "$out/$scene.mp3"
      printf '%-8s %5.1fs\n' "$scene" "$(length "$out/$scene.mp3")"
    done
    ;;
  *) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
