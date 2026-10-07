#!/usr/bin/env sh
# Runs the viz through roc, and holds a test run to the two assertion counts
# the window's coverage is pinned at. Every other subcommand is a pass-through
# carrying roc's own exit code.
#
# Nothing here forgives a warning. roc-ray declares the compiler the app header
# pins, so a viz build has no version-skew notice to tolerate, and roc exits
# non-zero on any warning that does appear.
set -eu

rc=0
out=$("${ROC:-roc}" "$@" 2>&1) || rc=$?
printf '%s\n' "$out"

# A test run gets two gates, and both run on the clean path - a wrapper that
# returns early when roc succeeds is a wrapper whose pins never execute.
#
# The first never reads roc's output at all: the SOURCE count of assertion
# lines under src/viz - lines beginning with `expect` or `and ` (today every
# one of the latter is an expect continuation) - must equal its pin. The
# summary pin below counts the whole import graph, so alone it is satisfiable
# by arithmetic (a deleted viz expect paid for by a new core expect leaves the
# pinned count standing while the viz's own coverage shrinks), and a block
# count alone is blind to a single assertion deleted from inside a multi-line
# block; counting continuation lines is what makes one deleted `and` loud.
#
# The second is the OUTPUT shape: a clean exit, an all-passed summary carrying
# exactly the pinned count (parentheses LITERAL in the grep - a BRE, not a
# capture group; the pin is the same reason e2e pins checks_ran_exactly!), and
# not one failure marker. The marker clause is belt over the pins' braces:
# every failure it would catch also breaks the pinned summary, and unlike the
# other clauses it fails open if roc ever respells the glyph - a second net,
# not a load-bearing one.
#
# Every clause runs on every invocation - the EXPECT_* variables override the
# pins for a one-off, never disable them. Adding or removing an assertion means
# updating the matching pin ON PURPOSE.
case "${1:-}" in test)
  want="${EXPECT_TESTS:-227}"
  want_viz="${EXPECT_VIZ_ASSERTS:-279}"
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
