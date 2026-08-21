#!/usr/bin/env bash
# Every `#NNN` in a source comment is a claim about an issue's state, and those rot
# silently: `#105 remains open` sat 560 lines above the same file saying it was fixed
# (#165, #205).
#
# Checks the one class with a free oracle: a BLOCK that names an issue and says it
# remains/is still open, is not yet fixed/released/landed/merged, is blocked by or on
# something, is awaiting upstream/release/a fix/the fix/merge, is/still/remains awaiting,
# is/still awaited, is/still/remains pending, is pending
# upstream/release/a fix/the fix, is unreleased, or waits until X lands/ships — when the tracker
# says CLOSED. That list is the PATTERN below, verbatim. Read the pattern, not this
# sentence, before believing a phrasing is covered: this comment claimed "pending" and
# "awaited" for a while when the regex matched neither.
#
# Scope is Roc comments AND the Markdown docs. Docs went unscanned at first, and the gap
# was not hypothetical — ADR 0000 asserted the #196 split "remains open" for a day after
# it shipped, while this same class was enforced two directories away.
#
# Bare `pending` and bare `awaiting` are deliberately NOT matched. Both are this
# codebase's own vocabulary — "pending backfill", "pending sessions", "strength sessions
# awaiting a rating" — and a block carrying one plus any ref would flag forever, on a
# phrase that says nothing about an issue. Note what the qualification does and does not
# buy: `(is|still|remains) pending` has no trailing boundary, so `is pending backfill`
# DOES match. The prefix is what is required, not a particular following noun.
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
fail=0; checked=0; blocks=0; quoting=0
# every `issue-claims: quoting` marker in the repo, pinned so a new one is deliberate
EXPECTED_QUOTING=4

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
#
# FENCED REGIONS ARE DROPPED HERE, AT LINE LEVEL, AND THAT IS WHY THE PASSES BELOW WORK.
# A fence is three backticks -- an ODD RUN -- and it is a LINE construct that cannot be
# recognised once lines are joined into a paragraph. Five successive versions of the
# quotation logic tried to survive it by counting delimiters, and counting sees the total
# while the damage is done by the pairing: one compensating stray tick restores an even
# total and leaves polarity inverted for the rest of the block. Measured on this tree:
# backtick runs are 3400 of length 1 and 28 of length 3, and all 28 are fence markers.
# Dropping fences takes the odd runs to zero, which is the only thing that makes an even
# total actually imply correct pairing.
awk '
  FNR==1 { if (n) { print f"\t"s"\t"t; n=0 } fence=0 }
  /^[[:space:]]*```/ { fence = 1 - fence; next }
  fence { next }
  /^[[:space:]]*$/ { if (n) { print f"\t"s"\t"t; n=0 } next }
  { if (!n) { f=FILENAME; s=FNR; t="" } n++; t=t" "$0 }
  END { if (n) print f"\t"s"\t"t }
' README.md AGENTS.md PLAN.md docs/*.md docs/adr/*.md .claude/skills/stride/SKILL.md >> "$BLOCKS"

while IFS=$'\t' read -r f s txt; do
  blocks=$((blocks + 1))
  # "open ABOVE", "keeps this open", "this open just created" are not issue states --
  # require the word to be about an ISSUE, so the phrase must sit near a ref.
  # `pending` and `awaited` are qualified, not bare. Bare `pending` matches this
  # codebase's own vocabulary -- "pending backfill", "pending stream", "pending
  # sessions" -- none of which say anything about an ISSUE, and a block carrying one of
  # those plus any ref would flag forever. The qualified forms are the ones that assert
  # a tracker state.
  #
  # NO PARSING. A block opts out with a literal marker, and that is the whole
  # mechanism. Six successive versions tried to decide MECHANICALLY whether a state
  # phrase was asserted or merely quoted -- pairing quotes, bounding the pair, scanning
  # parity, removing code spans, dropping fences, refusing unpairable runs -- and every
  # one of them could be defeated by a single compensating character, silently, in the
  # MISS direction. The last one was beaten by an inches mark.
  #
  # Telling `asserts X` from `quotes someone asserting X` is a natural-language problem,
  # and all that machinery was protecting four blocks of quoted history.
  #
  # State the property precisely, because claiming more than the code delivers is what
  # burned five of the six previous versions. The marker CANNOT be defeated by a
  # compensating character -- there is nothing to mis-pair -- and it can only be
  # OVER-applied: the unit is the whole block, so a genuine claim added to a marked
  # paragraph is exempted with it, and a paragraph that merely documents this token opts
  # itself out. Both require somebody to have typed the token, and
  # `grep -rn 'issue-claims: quoting'` lists every one. That is the trade: silent misses
  # from one stray character, for loud misses that are all visible in one command.
  #
  # It fails in the LOUD direction too. Forget the marker on new quoted history and CI
  # goes red naming the file and line, which is one read and a fix. The heuristic failed
  # by reporting a clean tree with a stale claim sitting in it.
  #
  # EXPECTED is pinned below so an accidental token -- a doc explaining the mechanism,
  # a copy-paste -- fails loudly instead of quietly widening the exemption.
  # Counts OCCURRENCES, not blocks, so the pin agrees with the grep recommended above.
  # A duplicate token inside an already-marked paragraph is exactly the copy-paste the
  # pin exists to catch, and block-counting cannot see it.
  case "$txt" in
    *"issue-claims: quoting"*)
      # grep -o | wc -l, NOT grep -c: the block is one joined line, so -c counts that
      # single line and reads two tokens as one -- which is the case being guarded.
      quoting=$((quoting + $(printf '%s' "$txt" | grep -o 'issue-claims: quoting' | wc -l)))
      continue ;;
  esac
  said="$txt"
  printf '%s' "$said" | grep -qiE 'remains open|still open|not yet (fixed|released|landed|merged)|blocked (by|on)|awaiting (upstream|release|a fix|the fix|merge)|(is|still|remains) awaiting|(is|still) awaited|(is|still|remains) pending|pending (upstream|release|a fix|the fix)|unreleased|until .*(lands|ships)' || continue
  # Scanning Markdown brought mermaid `classDef` lines into range, and `stroke:#57606a`
  # offers the ref pattern a five-digit prefix to match -- unresolvable, so it trips the
  # fail-closed arm and the gate goes permanently red on a stylesheet.
  #
  # Colours in a CSS/mermaid PROPERTY go first, at any shorthand length: `fill:#00f`
  # otherwise yields ref 00 and `fill:#5760` yields 5760, both unresolvable, both
  # tripping the fail-closed arm and turning CI permanently red on a stylesheet. The
  # property prefix is what makes stripping 3- and 4-digit runs safe here, since a bare
  # `#196` can never carry one. The prefix must also be a WHOLE word -- without the
  # leading boundary, `backfill:#196` matched on its last four letters and lost both the
  # ref and the words around it, and "pending backfill" is vocabulary this file's own
  # header cites twice. Then six-digit hex anywhere, for colours written without
  # a property.
  clean=$(printf '%s' "$txt" | sed -E 's/(^|[^a-z])(fill|stroke|color):#[0-9a-fA-F]{3,8}/\1/g; s/#[0-9a-fA-F]{6}//g')
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
if [ "$quoting" != "$EXPECTED_QUOTING" ]; then
  echo "issue-claims: $quoting quoting markers, expected $EXPECTED_QUOTING — a suppression was added or removed; confirm it is deliberate and update EXPECTED_QUOTING" >&2
  exit 4
fi
[ "$fail" = "0" ] && echo "issue-claims: $blocks comment blocks, $checked issue-state claims resolved against $REPO — none stale"
exit $fail
