#!/usr/bin/env sh
# Runs the viz through roc, and holds a test run to the two assertion counts
# the window's coverage is pinned at. Every other subcommand carries roc's own
# exit code, except for the one forgiven class of warning below.
#
# A warning located inside the roc-ray package named by `ray_pkg`, which
# stride cannot edit, is forgiven. roc exits 2 when a run has warnings and no
# errors, and the run counts as clean only when all of these hold: roc exited
# 2, src/viz/main.roc names that package, no error header (`── ✗`) appears, at
# least one warning header (`── ●`) appears and every one of them ends in a
# location under roc's package cache for that hash (`roc/packages/<hash>/`),
# and the `N errors and M warnings` summary reads `0 errors and M warnings`
# with M equal to the header count. `check` and `build` print that summary;
# `test` prints none, so a test run may lack it, and the pinned all-passed
# summary below is still required of it. A warning in stride's own source
# fails the run and is listed after roc's output. Another roc-ray release
# unpacks under another hash: while src/viz/main.roc names a package other
# than `ray_pkg`, nothing is forgiven, and a run with warnings says so. Delete
# the exception once the pinned roc-ray checks clean on the pinned nightly.
set -eu

ray_pkg=A8Dt5CorYsEtHFh8h7SfMtpzSy73UWbaB5Twy9JoYS1U
in_pkg="[/\\\\]roc[/\\\\]packages[/\\\\]$ray_pkg[/\\\\][^ ]*\$"

rc=0
out=$("${ROC:-roc}" "$@" 2>&1) || rc=$?
printf '%s\n' "$out"

if [ "$rc" = "2" ] && ! grep -q "/$ray_pkg\.tar\.zst" src/viz/main.roc; then
  echo "roc-viz: nothing forgiven - src/viz/main.roc does not name the roc-ray package $ray_pkg; point ray_pkg at the new release only if the warnings above are all inside it" >&2
elif [ "$rc" = "2" ]; then
  warned=$(printf '%s\n' "$out" | grep -c '^── ● ' || true)
  outside=$(printf '%s\n' "$out" | grep '^── ● ' | grep -vc "$in_pkg" || true)
  failed=$(printf '%s\n' "$out" | grep -c '^── ✗ ' || true)
  summary=$(printf '%s\n' "$out" | grep -o '[0-9]* errors and [0-9]* warnings' | head -1)
  if [ "$warned" -gt 0 ] && [ "$outside" = "0" ] && [ "$failed" = "0" ] &&
     { [ "$summary" = "0 errors and $warned warnings" ] ||
       { [ -z "$summary" ] && [ "${1:-}" = "test" ]; }; }; then
    echo "roc-viz: forgave $warned warnings inside the roc-ray package $ray_pkg"
    rc=0
  else
    echo "roc-viz: not forgiven: $outside of $warned warning headers lie outside the roc-ray package, $failed error headers, summary '${summary:-absent}'" >&2
    printf '%s\n' "$out" | grep '^── ● ' | grep -v "$in_pkg" >&2 || true
  fi
fi

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
  want="${EXPECT_TESTS:-809}"
  want_viz="${EXPECT_VIZ_ASSERTS:-1111}"
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
  if [ "$rc" = "0" ]; then
    echo "roc-viz: test run is not the clean shape - expected 'All ($want) tests passed' with no failure marker; the summary was '${got:-absent}'. A count off by a few with no viz change usually means a module the viz imports changed its expect count - update the pin ON PURPOSE." >&2
  else
    echo "roc-viz: test run failed - roc exited $rc and the summary was '${got:-absent}'; the cause is in the output above." >&2
  fi
  exit 1
  ;;
esac

exit "$rc"
