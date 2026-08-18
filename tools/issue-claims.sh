#!/usr/bin/env bash
# Every `#NNN` in a source comment is a claim about an issue's state, and those rot
# silently: `#105 remains open` sat 560 lines above the same file saying it was fixed,
# and `our pinned nightly predates the fix` outlived the pin that made it false. Both
# were found by a human reading, months late (#165, #205).
#
# This checks the one class with a free oracle: a comment asserting an issue is still
# OPEN, blocked, pending or awaited, when the tracker says it is closed.
#
# Deliberately NOT checked: whether a comment's DESCRIPTION of an issue is accurate.
# That needs judgment. This catches the mechanical half, which is the half that recurs.
#
# bash 3.2 (macOS ships it): no mapfile, no associative arrays. An earlier version used
# both, and every one of those lines failed while the script still printed its success
# message -- a checker that passes for the wrong reason, which is the defect it exists
# to find. Hence the explicit guard below rather than trusting the exit path.
set -uo pipefail
REPO="${GH_REPO:-eschizoid/stride}"
CACHE=$(mktemp); trap 'rm -f "$CACHE"' EXIT
fail=0
scanned=0
refs_seen=0
asserting=0

# stride refs only: a leading repo qualifier (roc#10595, basic-cli#472) belongs to
# someone else's tracker, and resolving that number against ours is worse than not
# checking. {2,5} because {2,4} silently truncated every 5-digit upstream ref.
while IFS= read -r line; do
  f=$(printf '%s' "$line" | cut -d: -f1)
  n=$(printf '%s' "$line" | cut -d: -f2)
  txt=$(printf '%s' "$line" | cut -d: -f3-)
  scanned=$((scanned + 1))
  printf '%s' "$txt" | grep -qE '(^|[^a-zA-Z/-])#[0-9]{2,5}' && refs_seen=$((refs_seen + 1))
  printf '%s' "$txt" | grep -qiE 'remains open|still open|is open|not yet (fixed|released|landed)|blocked by|awaiting|unreleased|until .*lands' || continue
  asserting=$((asserting + 1))
  for ref in $(printf '%s' "$txt" | grep -oE '(^|[^a-zA-Z/-])#[0-9]{2,5}' | grep -oE '[0-9]{2,5}'); do
    st=$(grep "^$ref " "$CACHE" 2>/dev/null | cut -d' ' -f2)
    if [ -z "$st" ]; then
      st=$(gh issue view "$ref" --repo "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)
      echo "$ref $st" >> "$CACHE"
    fi
    if [ "$st" = "CLOSED" ]; then
      echo "STALE  $f:$n  claims #$ref is open/blocked, but it is CLOSED"
      printf '       %s\n' "$(printf '%s' "$txt" | cut -c1-100)"
      fail=1
    fi
  done
done < <(grep -nH '^[[:space:]]*#' src/*.roc tests/*.roc 2>/dev/null)

# ZERO state-asserting comments is a legitimate result -- it is what a clean tree looks
# like. What is NOT legitimate is scanning zero comment lines or finding zero refs: that
# means the extraction broke, and an earlier version of this guard conflated the two and
# reported "broken" on a clean tree. Distinguish them explicitly.
if [ "$scanned" = "0" ] || [ "$refs_seen" = "0" ]; then
  echo "issue-claims: scanned=$scanned refs_seen=$refs_seen — the EXTRACTION is broken, not the comments" >&2
  exit 2
fi
[ "$fail" = "0" ] && echo "issue-claims: $scanned comment lines, $refs_seen carrying refs, $asserting asserting a state — none stale"
exit $fail
