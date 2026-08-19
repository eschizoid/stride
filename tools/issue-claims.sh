#!/usr/bin/env bash
# Every `#NNN` in a source comment is a claim about an issue's state, and those rot
# silently: `#105 remains open` sat 560 lines above the same file saying it was fixed
# (#165, #205).
#
# Checks the one class with a free oracle: a BLOCK that names an issue and says it
# remains/is still open, is not yet fixed/released/landed/merged, is blocked by or on
# something, is awaiting or awaited, is/still/remains pending, is pending
# upstream/release/a fix/the fix, is unreleased, or waits until X lands/ships — when the tracker
# says CLOSED. That list is the PATTERN below, verbatim. Read the pattern, not this
# sentence, before believing a phrasing is covered: this comment claimed "pending" and
# "awaited" for a while when the regex matched neither.
#
# Scope is Roc comments AND the Markdown docs. Docs went unscanned at first, and the gap
# was not hypothetical — ADR 0000 asserted the #196 split "remains open" for a day after
# it shipped, while this same class was enforced two directories away.
#
# Bare `pending` is deliberately NOT matched, because this codebase says "pending
# backfill" and "pending sessions" constantly and a block carrying one plus any ref would
# flag forever. Note what that does and does not buy: the qualified forms have no
# trailing boundary, so `is pending backfill` DOES match. The prefix is what is required,
# not a particular following noun.
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
  FNR==1 { if (n) { print f"\t"s"\t"t; n=0 } }
  /^[[:space:]]*#/ { if (!n) { f=FILENAME; s=FNR; t="" } n++; l=$0; sub(/^[[:space:]]*#[[:space:]]?/,"",l); t=t" "l; next }
  { if (n) { print f"\t"s"\t"t; n=0 } }
  END { if (n) print f"\t"s"\t"t }
' src/*.roc tests/*.roc > "$BLOCKS"

# Markdown needs its OWN extractor: it has no comment syntax, so the `^#` rule above
# would key on HEADINGS and slice every document into nonsense. Here a block is a
# paragraph — consecutive non-blank lines — which is the same unit the Roc pass uses
# (a run of comment lines) and produces the same file<TAB>line<TAB>text shape.
#
# Docs were unscanned until now, and that gap was not theoretical: ADR 0000 asserted the
# #196 split "remains open" for a day after it shipped, while the identical class was
# enforced two directories away.
#
# FNR==1 flushes at every file boundary. Without it a file ending mid-paragraph merges
# into the next file's opening paragraph, and the merged block is reported at the FIRST
# file's name and line — so a stale claim gets pinned to a document that does not
# contain it. Caught by planting a claim at the end of ADR 0001 and watching the report
# quote ADR 0002's title back. The Roc pass above needs the same guard for the same
# reason, a file that ends on a comment line.
awk '
  FNR==1 { if (n) { print f"\t"s"\t"t; n=0 } }
  /^[[:space:]]*$/ { if (n) { print f"\t"s"\t"t; n=0 } next }
  { if (!n) { f=FILENAME; s=FNR; t="" } n++; t=t" "$0 }
  END { if (n) print f"\t"s"\t"t }
' README.md AGENTS.md docs/*.md docs/adr/*.md .claude/skills/stride/SKILL.md >> "$BLOCKS"

while IFS=$'\t' read -r f s txt; do
  blocks=$((blocks + 1))
  # "open ABOVE", "keeps this open", "this open just created" are not issue states --
  # require the word to be about an ISSUE, so the phrase must sit near a ref.
  # `pending` and `awaited` are qualified, not bare. Bare `pending` matches this
  # codebase's own vocabulary -- "pending backfill", "pending stream", "pending
  # sessions" -- none of which say anything about an ISSUE, and a block carrying one of
  # those plus any ref would flag forever. The qualified forms are the ones that assert
  # a tracker state.
  # A state phrase inside quotation marks is being QUOTED, not asserted, so quoted spans
  # come out before the match. Docs make this load-bearing: prose narrates superseded
  # states constantly, and both paragraphs this flagged on its first run over docs/ were
  # of exactly that shape -- `used to sit here as "blocked by the compiler"` and `why the
  # original "blocked on roc-json" conclusion was wrong`. Rewording accurate history to
  # satisfy a regex would be the wrong direction to fix that.
  # BOUNDED at 80 characters, and the bound is the whole safety. Unbounded, `"[^"]*"`
  # pairs quotes left-to-right across the entire joined block, and a Markdown block is a
  # whole paragraph -- AGENTS.md's conventions list is one 5651-char block with nine
  # quote characters, where the fourth "pair" spans ~200 characters of live prose because
  # a quote inside a grep pattern mispairs with a quote inside a code span. A stale claim
  # sitting in that gap was reported as clean: the gate said none stale with a literal
  # `blocked by #196` in the file. Eighty covers every quoted phrase this repo actually
  # writes and cannot span two unrelated code samples.
  said=$(printf '%s' "$txt" | sed -E 's/"[^"]{0,80}"//g')
  printf '%s' "$said" | grep -qiE 'remains open|still open|not yet (fixed|released|landed|merged)|blocked (by|on)|awaiting|awaited|(is|still|remains) pending|pending (upstream|release|a fix|the fix)|unreleased|until .*(lands|ships)' || continue
  # Strip six-digit hex colours first. Scanning Markdown brought mermaid `classDef`
  # lines into range, and `stroke:#57606a` offers the ref pattern a five-digit prefix to
  # match -- which resolves to nothing and trips the fail-closed arm, so the gate would
  # have gone permanently red on a stylesheet. SIX only: three hex chars is also a legal
  # colour, but `#196` is three hex chars too, and stripping those would silently blind
  # the checker to most of this repo's own issue numbers.
  # Colours in a CSS/mermaid PROPERTY go first, at any shorthand length: `fill:#00f`
  # otherwise yields ref 00 and `fill:#5760` yields 5760, both unresolvable, both
  # tripping the fail-closed arm and turning CI permanently red on a stylesheet. The
  # property prefix is what makes stripping 3- and 4-digit runs safe here, since a bare
  # `#196` can never carry one. Then six-digit hex anywhere, for colours written without
  # a property.
  clean=$(printf '%s' "$txt" | sed -E 's/(fill|stroke|color):#[0-9a-fA-F]{3,8}//g; s/#[0-9a-fA-F]{6}//g')
  refs=$(printf '%s' "$clean" | grep -oE '(^|[^a-zA-Z/-])#[0-9]{2,5}' | grep -oE '[0-9]{2,5}' | sort -u)
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
