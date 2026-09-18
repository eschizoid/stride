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
# warning bullet and it is the pin notice, an all-passed summary, and not
# one failure marker. Each clause guards a distinct escape on this pinned
# nightly's output. The bullet count keeps a second real warning from
# riding through on the pin notice's back. The marker test catches an
# expect that fails to COMPILE, which prints an all-passed summary with a
# silently smaller count while its diagnostics carry the marker. And the
# summary's parentheses are LITERAL in the grep (a BRE, not a capture
# group) - the count sits inside them. When EXPECT_TESTS is set, the
# summary must carry exactly that count: without a pin, deleting every
# expect in the target leaves a smaller, plausible-looking summary from
# the modules it imports, and the gate would bless a suite that no longer
# tests what it was written for.
case "${1:-}" in test)
  # The pinned summary count, overridable for a one-off run. The target
  # imports core modules whose expects swell the total, so an unpinned
  # summary stays plausible after every viz expect is deleted - the same
  # reason e2e pins checks_ran_exactly!. Adding or removing an expect means
  # updating this pin ON PURPOSE.
  want="${EXPECT_TESTS:-47}"
  if [ "$(printf '%s\n' "$out" | grep -c '── ●')" = "1" ] &&
     printf '%s\n' "$out" | grep -q 'roc fmt to update the pin' &&
     printf '%s\n' "$out" | grep -q "All ($want) tests passed" &&
     ! printf '%s\n' "$out" | grep -q '✗'; then
    echo "roc-viz: tolerated roc-ray's pin-mismatch warning (all tests passed)"
    exit 0
  fi
  echo "roc-viz: test run is not the clean shape - failing" >&2
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
