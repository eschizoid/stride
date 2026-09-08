#!/usr/bin/env bash
# layer-check — ADR 0016's enforcement: the engine's layers are a rule about
# imports, checked here, because the compiler cannot yet follow subfolders.
#
# The table IS the config. A module may import its own layer and anything
# below it; core sits at the bottom. Renaming or adding a module without a
# row here fails the run — silence is never a pass.
set -euo pipefail
# NOTE on set -e vs the import greps below: they feed while-loops through
# process substitution, whose exit status set -e never sees — a module with
# zero matching imports iterates zero times and the script continues. Verified
# against bash directly and against this repo's zero-import modules. Every
# IMPORTABLE module here is capitalized (app.roc is an entrypoint, imported
# by nothing), so the [A-Z] matcher covers the complete import vocabulary.
cd "$(dirname "$0")/.."

layer_of() {
  case "$1" in
    Sports|Metrics|Csv|Streams|Config|Drain|Schema|Render) echo core ;;
    Db|Strava|Output)                                      echo io ;;
    Analyze|Plan|Report|ReportHealth|ReportSeason|ReportSessions) echo analytics ;;
    app|Command|Import)                                    echo app ;;
    *) echo UNKNOWN ;;
  esac
}
# A layer name unknown to rank_of means the two tables drifted apart — say so
# instead of letting -gt choke on an empty string under set -e.
rank_of() { case "$1" in core) echo 0 ;; io) echo 1 ;; analytics) echo 2 ;; app) echo 3 ;; *) echo "layer-check: rank_of has no row for layer '$1' — layer_of and rank_of drifted apart" >&2; exit 1 ;; esac; }

# ── self-test: the table resolves its own vocabulary and flags a stranger ──
[ "$(layer_of Metrics)" = core ] && [ "$(layer_of Strava)" = io ] \
  && [ "$(layer_of Plan)" = analytics ] && [ "$(layer_of app)" = app ] \
  && [ "$(layer_of Nonesuch)" = UNKNOWN ] \
  || { echo "layer-check: SELF-TEST FAILED — the table no longer resolves its own rows" >&2; exit 1; }

fail=0

# ── engine: src/*.roc, dependency direction only ever points down ──
for f in src/*.roc; do
  m=$(basename "$f" .roc)
  ml=$(layer_of "$m")
  if [ "$ml" = UNKNOWN ]; then
    echo "layer-check: $m has no layer — add it to the table in tools/layer-check.sh (and ADR 0016 if it starts a new layer)" >&2
    fail=1; continue
  fi
  while IFS= read -r dep; do
    dl=$(layer_of "$dep")
    if [ "$dl" = UNKNOWN ]; then
      echo "layer-check: $m imports $dep, which has no layer row" >&2; fail=1; continue
    fi
    if [ "$(rank_of "$dl")" -gt "$(rank_of "$ml")" ]; then
      echo "layer-check: $m ($ml) imports $dep ($dl) — dependencies must point down the layers" >&2
      fail=1
    fi
  done < <(grep -oE '^import [A-Z][A-Za-z]*' "$f" | sed 's/import //')
done

# ── viz: its own app, its own world — modules import only their siblings ──
viz_members=$(ls src/viz/*.roc | xargs -n1 basename | sed 's/.roc$//')
for f in src/viz/*.roc; do
  m=$(basename "$f" .roc)
  while IFS= read -r dep; do
    echo "$viz_members" | grep -qx "$dep" || {
      echo "layer-check: viz/$m imports $dep, which is not a viz module — the viz app reaches the engine through the database, never through imports (ADR 0015)" >&2
      fail=1
    }
  done < <(grep -oE '^import [A-Z][A-Za-z]*' "$f" | sed 's/import //')
done

[ "$fail" = 0 ] && echo "layer-check: every import points down; viz stays behind the database"
exit "$fail"
