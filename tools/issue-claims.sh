#!/usr/bin/env bash
# Every `#NNN` in a source comment is a claim about an issue's state, and those rot
# silently: `#105 remains open` sat 560 lines above the same file saying it was fixed
# (#165, #205).
#
# Checks the one class with a free oracle: a comment BLOCK that names an issue and says
# it remains/is still open, is not yet fixed/released/landed/merged, is blocked by or on
# something, is awaiting something, is unreleased, or waits "until X lands/ships" — when
# the tracker says CLOSED. That list is the PATTERN below, verbatim; a block phrased with
# "pending" or "awaited" is NOT matched, so widen the pattern rather than assume coverage.
#
# BLOCK-scoped, not line-scoped, and that is the whole design. The first version matched
# a state phrase and a ref on the SAME line, which on this tree paired zero times -- it
# called `gh` not once and reported success. A ref and the claim about it are usually
# lines apart inside one comment paragraph.
#
# It over-reports WITHIN a block: if a block asserts a state, every ref in that block is
# flagged, including ones the claim was not about. That is the deliberate direction to be
# wrong in -- a false flag costs one read, a miss costs what #105 cost.
#
# Deliberately NOT checked: whether a comment's DESCRIPTION of an issue is accurate.
# That needs judgment. This is the mechanical half, which is the half that recurs.
#
# bash 3.2 (macOS): no mapfile, no associative arrays. No python either -- AGENTS.md
# rules it out project-wide -- so block grouping is awk.
set -uo pipefail
REPO="${GH_REPO:-eschizoid/stride}"
CACHE=$(mktemp); BLOCKS=$(mktemp); trap 'rm -f "$CACHE" "$BLOCKS"' EXIT
fail=0; checked=0; blocks=0

# one line per comment block: file<TAB>startline<TAB>joined text
awk '
  /^[[:space:]]*#/ { if (!n) { f=FILENAME; s=FNR; t="" } n++; l=$0; sub(/^[[:space:]]*#[[:space:]]?/,"",l); t=t" "l; next }
  { if (n) { print f"\t"s"\t"t; n=0 } }
  END { if (n) print f"\t"s"\t"t }
' src/*.roc tests/*.roc > "$BLOCKS"

while IFS=$'\t' read -r f s txt; do
  blocks=$((blocks + 1))
  # "open ABOVE", "keeps this open", "this open just created" are not issue states --
  # require the word to be about an ISSUE, so the phrase must sit near a ref.
  printf '%s' "$txt" | grep -qiE 'remains open|still open|not yet (fixed|released|landed|merged)|blocked (by|on)|awaiting|unreleased|until .*(lands|ships)' || continue
  refs=$(printf '%s' "$txt" | grep -oE '(^|[^a-zA-Z/-])#[0-9]{2,5}' | grep -oE '[0-9]{2,5}' | sort -u)
  [ -z "$refs" ] && continue
  for ref in $refs; do
    st=$(grep "^$ref " "$CACHE" 2>/dev/null | cut -d' ' -f2)
    if [ -z "$st" ]; then
      st=$(gh issue view "$ref" --repo "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)
      echo "$ref $st" >> "$CACHE"
    fi
    # UNKNOWN means the ORACLE failed (no auth, no network, wrong repo), NOT that the
    # claim is fine. Failing open would make an outage look like a clean tree.
    if [ "$st" = "UNKNOWN" ]; then
      echo "issue-claims: cannot resolve #$ref against $REPO — oracle unavailable, refusing to pass" >&2
      exit 3
    fi
    checked=$((checked + 1))
    if [ "$st" = "CLOSED" ]; then
      echo "STALE  $f:$s  claims #$ref is open/blocked, but it is CLOSED"
      printf '       %s\n' "$(printf '%s' "$txt" | cut -c1-100)"
      fail=1
    fi
  done
done < "$BLOCKS"

# Zero CHECKED pairs is legitimate -- it is what a clean tree looks like. Zero BLOCKS is
# not: that means the extraction broke. An earlier version conflated the two and called a
# healthy repo broken; the one before that reported success while checking nothing.
if [ "$blocks" = "0" ]; then
  echo "issue-claims: found 0 comment blocks — the EXTRACTION is broken, not the comments" >&2
  exit 2
fi
[ "$fail" = "0" ] && echo "issue-claims: $blocks comment blocks, $checked issue-state claims resolved against $REPO — none stale"
exit $fail
