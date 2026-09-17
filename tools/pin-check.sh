#!/usr/bin/env sh
# The viz compiler pin has ONE definition: the `roc:` field in src/viz/main.roc's
# app header. Four workflow steps repeat it as a `nightly-tag:` input, and nothing
# compared them - bump the header, miss one input, and the release's app builds on
# a mismatched compiler, discovered on the artifact users download (#443).
# Sibling of command-claims.sh: fail-closed extraction, a pinned site count so a
# fifth copy appearing (or the scan going blind) is a loud diff, POSIX sh.
set -eu

# Uniqueness before trust: with two roc:"nightly-…" strings in the file, a
# stale one sitting above the header would win the extraction after a bump
# and green-light four stale sites against it.
pins=$(grep -c 'roc: "nightly-' src/viz/main.roc || true)
[ "$pins" = "1" ] || { echo "pin-check: expected exactly one roc pin string in src/viz/main.roc, found $pins"; exit 4; }
pin=$(grep -oE 'roc: "nightly-[0-9a-z-]+"' src/viz/main.roc | grep -oE 'nightly-[0-9a-z-]+' | head -1)
[ -n "$pin" ] || { echo "pin-check: could not read the roc pin from src/viz/main.roc's app header"; exit 4; }

# Both binaries share one compiler, so the pin has exactly two copies: the
# setup-roc action's default, which every job now takes, and the viz app
# header. A per-job override would be a third, so any nightly-tag line at all
# is drift.
strays=$(grep -rn 'nightly-tag:' .github/workflows/ || true)
if [ -n "$strays" ]; then
  echo "pin-check: a workflow overrides the compiler default - the pins converged, so an override is drift:"
  echo "$strays"
  exit 1
fi

default=$(grep -oE 'default: nightly-[0-9a-z-]+' .github/actions/setup-roc/action.yml | grep -oE 'nightly-[0-9a-z-]+' | head -1)
[ -n "$default" ] || { echo "pin-check: could not read the compiler default from .github/actions/setup-roc/action.yml"; exit 4; }
if [ "$default" != "$pin" ]; then
  echo "pin-check: the viz app header pins $pin but the compiler default is $default - one compiler means one tag"
  exit 1
fi
echo "pin-check: the app header and the compiler default agree ($pin)"
