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
  #
  # A state phrase inside quotation marks is being QUOTED, not asserted. Docs make that
  # load-bearing: prose narrates superseded states constantly, and the first run over
  # docs/ flagged `used to sit here as "blocked by the compiler"` and `why the original
  # "blocked on roc-json" conclusion was wrong`. Rewording accurate history to satisfy a
  # checker would be the wrong direction.
  #
  # Blank the INSIDE of quotations by scanning parity, one character at a time. Any
  # regex that PAIRS quotes is wrong here, and two versions proved it: `"[^"]*"` paired
  # greedily across a 5651-character block and deleted ~200 characters of live prose,
  # and bounding it to 80 only shrank the blast radius -- a quotation longer than the
  # bound cannot be matched, so the matcher steps past its opening quote and every
  # later pairing is off by one for the rest of the block. Fifty-seven blocks in this
  # tree contain an over-80-character quotation, three already lost prose, and a
  # planted `blocked by #196` in ADR 0010 read as clean. The same desync breaks
  # suppressions the other way, turning CI red on quoted history after an unrelated
  # edit elsewhere in the paragraph.
  #
  # CODE SPANS COME OUT FIRST, and that is what makes the quote pass safe. Parity does
  # not desync the way a pairing regex does, but quote polarity is GLOBAL across a
  # joined paragraph: any run of quotes with odd cardinality inverts inside/outside for
  # everything after it. Code samples are exactly such runs -- one block here carries
  # `grep -nE '\["(complete|skip)", "[0-9]'`, three quote characters, the third never
  # closing -- and inverting there swallows the 177 characters of prose that follow.
  # Every stray quote in this tree sits inside backticks, so removing code spans first
  # takes the odd-cardinality blocks from one to zero and the polarity problem with it.
  #
  # Each pass re-checks parity on the string IT receives, and any skip skips the rest.
  # Both halves of that are load-bearing and each was learned by getting it wrong.
  # Guarding the passes independently lets an odd backtick count leave the code spans IN,
  # and the quote pass then runs over the very samples that make quote polarity unsafe.
  # Guarding them only on the ORIGINAL text is just as bad in the other direction: pass 2
  # never sees $0, it sees the code spans already removed, so counting quotes up front
  # measures a string that no longer exists — one stray quote in prose alongside nine
  # inside code spans passes the outer check and then opens a quotation that runs to the
  # end of the block.
  #
  # Note what removing code spans also does, beyond protecting quote parity: a state
  # phrase written in code font -- `blocked on` -- is now suppressed like a quoted one.
  # That is the same argument (a span shows a phrase rather than asserting it), but it is
  # a real behaviour change and nothing else in this file says so.
  #
  # Collapsing space runs afterwards is what makes a phrase INTERRUPTED by a span still
  # match -- `not yet "fully" merged` becomes `not yet merged`. It can also weld a phrase
  # across a blanked span that ended a sentence ("not yet \"done.\" Merged in June" reads
  # as `not yet Merged`), which over-reports. That is the direction this file chooses.
  said=$(printf '%s' "$txt" | awk '
    function blank(s, d,    out, ins, i, c, n) {
      # A RUN longer than one is not a delimiter this can pair. Markdown closes a span
      # with a run of the same length, so ``` opens something a per-character parity scan
      # will mis-pair, and one compensating tick restores an even TOTAL while leaving the
      # pairing inverted. Dropping fences at line level removes every such run in this
      # tree, but an inline ``` is still writable, so refuse rather than trust the count.
      if (index(s, d d) > 0) return "\001"
      n = gsub(d, "&", s)
      if (n % 2 == 1) return "\001"
      out = ""; ins = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == d) { ins = 1 - ins; out = out " "; continue }
        out = out (ins ? " " : c)
      }
      return out
    }
    {
      s = blank($0, "`")
      if (s == "\001") { print; next }
      s = blank(s, "\"")
      if (s == "\001") { print; next }
      gsub(/  +/, " ", s); print s
    }')
  printf '%s' "$said" | grep -qiE 'remains open|still open|not yet (fixed|released|landed|merged)|blocked (by|on)|awaiting|awaited|(is|still|remains) pending|pending (upstream|release|a fix|the fix)|unreleased|until .*(lands|ships)' || continue
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
[ "$fail" = "0" ] && echo "issue-claims: $blocks comment blocks, $checked issue-state claims resolved against $REPO — none stale"
exit $fail
