#!/usr/bin/env sh
# The compiler pin has ONE definition: the `setup-roc` action's default. Every
# workflow job takes it, and the justfile's local viz default names the same
# tag. roc-ray names no compiler, so the viz app header carries none; a `roc:`
# field there would be a second definition that nothing keeps in step.
# Sibling of command-claims.sh: fail-closed extraction, POSIX sh.
set -eu

default=$(grep -oE 'default: nightly-[0-9a-z-]+' .github/actions/setup-roc/action.yml | grep -oE 'nightly-[0-9a-z-]+' | head -1)
[ -n "$default" ] || { echo "pin-check: could not read the compiler default from .github/actions/setup-roc/action.yml"; exit 4; }

# A per-job override would be a second pin, so any nightly-tag line at all is drift.
strays=$(grep -rn 'nightly-tag:' .github/workflows/ || true)
if [ -n "$strays" ]; then
  echo "pin-check: a workflow overrides the compiler default - one compiler means one tag:"
  echo "$strays"
  exit 1
fi

headers=$(grep -c 'roc: "nightly-' src/viz/main.roc || true)
[ "$headers" = "0" ] || { echo "pin-check: src/viz/main.roc's app header names a compiler; roc-ray takes the repo pin, so delete the roc: field"; exit 1; }

local_pin=$(grep -oE '^viz_pin := .*nightly-[0-9a-z-]+' justfile | grep -oE 'nightly-[0-9a-z-]+' | head -1)
[ -n "$local_pin" ] || { echo "pin-check: could not read the viz_pin nightly from the justfile"; exit 4; }
if [ "$local_pin" != "$default" ]; then
  echo "pin-check: the justfile's viz_pin names $local_pin but the compiler default is $default - one compiler means one tag"
  exit 1
fi
echo "pin-check: the compiler default and the justfile's viz_pin agree ($default), and the viz header names none"
