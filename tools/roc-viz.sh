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

printf '%s\n' "$out" | grep -q '0 errors and 1 warning' || {
  echo "roc-viz: refusing to tolerate this - it is not the lone pin-mismatch warning" >&2
  exit "$rc"
}
printf '%s\n' "$out" | grep -q 'roc fmt to update the pin' || {
  echo "roc-viz: the single warning is not the platform pin notice" >&2
  exit "$rc"
}
echo "roc-viz: tolerated roc-ray's pin-mismatch warning (0 errors)"
