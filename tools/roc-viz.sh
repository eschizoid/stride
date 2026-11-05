#!/usr/bin/env sh
# Runs the viz through roc, and holds a test run to the two assertion counts
# the window's coverage is pinned at. Every other subcommand is a pass-through
# carrying roc's own exit code.
#
# Nothing here forgives a warning. roc-ray names no compiler, so a viz build
# has no version-skew notice to tolerate, and roc exits non-zero on any
# warning that does appear.
set -eu

rc=0
out=$("${ROC:-roc}" "$@" 2>&1) || rc=$?
printf '%s\n' "$out"

# A test run gets two gates, and both run on the clean path, so the pins
# execute whether roc succeeded or not.
#
# The first never reads roc's output: the SOURCE count of assertion lines
# under src/viz, lines beginning with `expect` or `and `, must equal its pin.
# The summary pin below counts the whole import graph, so on its own a deleted
# viz expect paid for by a new core expect would leave it standing; and a
# count of expect blocks alone is blind to one assertion deleted from inside a
# multi-line block, which counting continuation lines catches.
#
# The second is the OUTPUT shape: a clean exit, an all-passed summary carrying
# exactly the pinned count (the parentheses are literal in the grep, a BRE and
# not a capture group), and no failure marker. Every failure the marker clause
# catches also breaks the pinned summary; the clause is a second check that
# fails open if roc ever changes the glyph.
#
# Every clause runs on every invocation: the EXPECT_* variables override the
# pins for a one-off and never disable them. Adding or removing an assertion
# means updating the matching pin on purpose.
case "${1:-}" in test)
  want="${EXPECT_TESTS:-351}"
  want_viz="${EXPECT_VIZ_ASSERTS:-404}"
  have_viz=$(grep -ch '^[[:space:]]*\(expect\|and \)' src/viz/*.roc 2>/dev/null | awk '{s+=$1} END {print s+0}')
  if [ "$have_viz" != "$want_viz" ]; then
    echo "roc-viz: src/viz declares $have_viz assertion lines (expect + and), the pin says $want_viz - update the pin ON PURPOSE or restore the assertion" >&2
    exit 1
  fi
  if [ "$rc" = "0" ] &&
     printf '%s\n' "$out" | grep -q "All ($want) tests passed" &&
     ! printf '%s\n' "$out" | grep -q '✗'; then
    echo "roc-viz: all $want tests passed"
    exit 0
  fi
  got=$(printf '%s\n' "$out" | grep -o 'All ([0-9]*) tests passed' | head -1)
  echo "roc-viz: test run is not the clean shape - expected 'All ($want) tests passed' at exit 0 with no failure marker; roc exited $rc and the summary was '${got:-absent}'. A count off by a few with no viz change usually means a module the viz imports changed its expect count - update the pin ON PURPOSE." >&2
  exit 1
  ;;
esac

exit "$rc"
