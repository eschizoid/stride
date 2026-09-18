#!/usr/bin/env sh
# Runs the viz through roc, tolerating ONE warning and no others: roc-ray
# declares a supported compiler in its own header, and stride pins a newer one.
#
# The mismatch is advisory - the platform links and runs on the newer compiler,
# verified by building and driving the window - but `roc` exits non-zero on any
# warning, which would fail every viz job. Tolerating the exit code wholesale
# would also swallow real warnings, so this asserts the SHAPE of what it
# forgives: zero errors, exactly one warning, and that warning the pin notice.
# Anything else fails with roc's own exit code.
#
# Delete this the day roc-ray declares the compiler stride pins; the tolerance
# is for a version skew, not a policy.
set -eu

out=$("${ROC:-roc}" "$@" 2>&1) && { printf '%s\n' "$out"; exit 0; }
rc=$?
printf '%s\n' "$out"

# A test run trips the same pin warning but never prints the check shape's
# "0 errors and 1 warning" line, so it gets its own shape: exactly one
# warning bullet and it is the pin notice, an all-passed summary carrying
# exactly the pinned count, not one failure marker, and the pinned number
# of expects declared under src/viz. Each clause guards a distinct escape
# on this pinned nightly's output, and every clause runs on every
# invocation - the EXPECT_* variables override the pins for a one-off,
# never disable them.
#
# The bullet count keeps a second real warning from riding through on the
# pin notice's back. The summary pin (parentheses LITERAL in the grep - a
# BRE, not a capture group) is what makes a silently smaller run loud,
# the same reason e2e pins checks_ran_exactly!. The summary counts the
# whole import graph though, so alone it is satisfiable by arithmetic: a
# deleted viz expect paid for by a new core expect leaves 47 standing
# while the viz's own coverage shrinks - which is why the SOURCE count of
# src/viz expects is pinned separately. The marker clause is belt over
# those braces: on this pin, every failure it would catch also breaks the
# pinned summary, and unlike the other clauses it fails open if roc ever
# respells the glyph - it stays as a second net, not a load-bearing one.
# Adding or removing an expect means updating the matching pin ON PURPOSE.
case "${1:-}" in test)
  want="${EXPECT_TESTS:-47}"
  want_viz="${EXPECT_VIZ_EXPECTS:-14}"
  have_viz=$(grep -ch '^[[:space:]]*expect' src/viz/*.roc 2>/dev/null | awk '{s+=$1} END {print s+0}')
  if [ "$have_viz" != "$want_viz" ]; then
    echo "roc-viz: src/viz declares $have_viz expects, the pin says $want_viz - update the pin ON PURPOSE or restore the expect" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$out" | grep -c '── ●')" = "1" ] &&
     printf '%s\n' "$out" | grep -q 'roc fmt to update the pin' &&
     printf '%s\n' "$out" | grep -q "All ($want) tests passed" &&
     ! printf '%s\n' "$out" | grep -q '✗'; then
    echo "roc-viz: tolerated roc-ray's pin-mismatch warning (all tests passed)"
    exit 0
  fi
  got=$(printf '%s\n' "$out" | grep -o 'All ([0-9]*) tests passed' | head -1)
  echo "roc-viz: test run is not the clean shape - expected 'All ($want) tests passed' with one warning bullet and no failure marker; summary was '${got:-absent}'. A count off by a few with no viz change usually means a module the viz imports changed its expect count - update the pin ON PURPOSE." >&2
  exit 1
  ;;
esac

printf '%s\n' "$out" | grep -q '0 errors and 1 warning' || {
  echo "roc-viz: refusing to tolerate this - it is not the lone pin-mismatch warning" >&2
  exit "$rc"
}
printf '%s\n' "$out" | grep -q 'roc fmt to update the pin' || {
  echo "roc-viz: the single warning is not the platform pin notice" >&2
  exit "$rc"
}
echo "roc-viz: tolerated roc-ray's pin-mismatch warning (0 errors)"
