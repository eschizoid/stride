#!/usr/bin/env bash
# layer-check — ADR 0016's enforcement: the engine's layers are a rule about
# imports, checked here, because the compiler cannot yet follow subfolders.
#
# The table IS the config. A module may import its own layer and anything
# below it; core sits at the bottom. Renaming or adding a module without a
# row here fails the run — silence is never a pass.
set -euo pipefail
# Import scanning captures the pipeline status explicitly: grep exit 1 is the
# normal no-imports state, anything above it is a scan that FAILED — and a
# gate that could not read must not be green. The matcher reads LOCAL imports
# only — qualified package imports (pf.Sqlite, rr.App) are platform edges the
# layer table does not govern. Every importable local module is capitalized
# (app.roc is an entrypoint, imported by nothing), so [A-Z] covers them all.

# prints a file's local imports; dies if the scan itself breaks
scan() {
  local st=0 out
  out=$(grep -oE '^import [A-Z][A-Za-z]*' "$1" | sed 's/import //') || st=$?
  if [ "$st" -gt 1 ]; then
    echo "layer-check: scanning $1 failed (exit $st) — refusing to pass blind" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}
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

# ── the gate scans two homes: src/*.roc and src/viz/*.roc. A module anywhere
# else means the layout changed under the gate — fail loudly rather than let
# an unscanned file ride along (subdir imports do not even compile on the
# pinned nightlies, so such a file is at best dead and at worst the first
# sign the foldering ticket has come due and this script must be taught).
stray=$(find src -mindepth 2 -name '*.roc' -not -path 'src/viz/*')
if [ -n "$stray" ]; then
  echo "layer-check: .roc files outside the scanned homes:" >&2
  printf '%s
' "$stray" >&2
  fail=1
fi

# ── engine: src/*.roc, dependency direction only ever points down ──
for f in src/*.roc; do
  m=$(basename "$f" .roc)
  ml=$(layer_of "$m")
  if [ "$ml" = UNKNOWN ]; then
    echo "layer-check: $m has no layer — add it to the table in tools/layer-check.sh (and ADR 0016 if it starts a new layer)" >&2
    fail=1; continue
  fi
  for dep in $(scan "$f"); do
    dl=$(layer_of "$dep")
    if [ "$dl" = UNKNOWN ]; then
      echo "layer-check: $m imports $dep, which has no layer row" >&2; fail=1; continue
    fi
    if [ "$(rank_of "$dl")" -gt "$(rank_of "$ml")" ]; then
      echo "layer-check: $m ($ml) imports $dep ($dl) — dependencies must point down the layers" >&2
      fail=1
    fi
  done
done

# ── viz: its own app, its own world — modules import only their siblings ──
viz_members=$(ls src/viz/*.roc | xargs -n1 basename | sed 's/\.roc$//')
for f in src/viz/*.roc; do
  m=$(basename "$f" .roc)
  for dep in $(scan "$f"); do
    echo "$viz_members" | grep -qx "$dep" || {
      echo "layer-check: viz/$m imports $dep, which is not a viz module — the viz app reaches the engine through the database, never through imports (ADR 0015)" >&2
      fail=1
    }
  done
done

[ "$fail" = 0 ] && echo "layer-check: every import points down; viz stays behind the database"
exit "$fail"
