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

sites=$(grep -rn 'nightly-tag:' .github/workflows/ | wc -l | tr -d ' ')
EXPECT_SITES=6
if [ "$sites" != "$EXPECT_SITES" ]; then
  echo "pin-check: found $sites nightly-tag sites in .github/workflows, expected $EXPECT_SITES."
  echo "pin-check: if a viz build job was added or removed, update the number here in the same commit;"
  echo "pin-check: if it was not, the scan stopped matching and this gate is blind."
  exit 1
fi

bad=$(grep -rn 'nightly-tag:' .github/workflows/ | grep -v "nightly-tag: $pin" || true)
if [ -n "$bad" ]; then
  echo "pin-check: the app header pins $pin but these workflow sites disagree:"
  echo "$bad"
  exit 1
fi
echo "pin-check: $sites workflow sites agree with the app header pin ($pin)"
