#!/usr/bin/env bash
# Every `#NNN` in a source comment is a claim about an issue's state, and those
# rot silently: `#105 remains open` sat 560 lines above the same file saying it
# was fixed. Checks the one class with a free oracle: a BLOCK naming an issue
# and asserting it is open/unfixed/pending/awaiting (the PATTERN below is the
# authority — read it, not this sentence, before believing a phrasing covered)
# when the tracker says CLOSED.
#
# Scope is Roc comments AND the Markdown docs (ADR 0000 asserted a split
# "remains open" for a day after it shipped). Bare `pending`/`awaiting` are
# deliberately NOT matched — both are this codebase's own vocabulary; the
# qualified prefix `(is|still|remains)` is what is required, with no trailing
# boundary, so `is pending backfill` DOES match.
#
# BLOCK-scoped, not line-scoped: a ref and the claim about it are usually lines
# apart in one paragraph (line-scoped paired ZERO times on this tree — it never
# called `gh` once and reported success). Over-reports WITHIN a block by design:
# a false flag costs one read, a miss costs what #105 cost. Does NOT check
# whether a comment's DESCRIPTION of an issue is accurate — that needs judgment;
# this is the mechanical half, which is the half that recurs.
#
# bash 3.2 (macOS): no mapfile, no associative arrays, and no python (AGENTS.md
# rules it out project-wide), so block grouping is awk.
set -uo pipefail
REPO="${GH_REPO:-eschizoid/stride}"
CACHE=$(mktemp); BLOCKS=$(mktemp); trap 'rm -f "$CACHE" "$BLOCKS"' EXIT
fail=0; checked=0; blocks=0; quoting=0
# every `issue-claims: quoting` marker in the repo, pinned so a new one is deliberate
# PLAN.md is listed through `ls` so its ABSENCE is not an error while its PRESENCE is
# still scanned. AGENTS.md and ADR 0000 both permit a root PLAN.md only on the condition
# that this tool reads it — that scan is the load-bearing half of the permission, and the
# self-deletion trigger only ever worked because of it. A literal entry would fail whenever
# no sequence is in flight; naming nothing at all would leave the permission standing with
# its enforcement quietly gone.
#
# The `||` matters more than it looks. macOS awk ABORTS the rest of its argument list on a
# missing file rather than skipping it, and this invocation's exit status was discarded, so
# one absent entry silently truncated the scan — losing every file listed after it. That is
# how deleting PLAN.md reported "1 quoting markers" instead of 4 and nearly had the expected
# count "corrected" to a number a broken run produced. It only surfaced at all because the
# marker-bearing files happened to sit downstream; remove one from the end and the
# truncation is invisible.
EXPECTED_QUOTING=4

# one line per comment block: file<TAB>startline<TAB>joined text
# GUARDED like the markdown extractor below: macOS awk ABORTS the rest of its
# argument list on a missing file rather than skipping it — a missing file after
# `src/*.roc` silently drops tests/*.roc (22% of the corpus) while the script
# still prints "none stale" and exits 0.
awk '
  FNR==1 { if (n) { print f"\t"s"\t"t; n=0 } }
  /^[[:space:]]*#/ { if (!n) { f=FILENAME; s=FNR; t="" } n++; l=$0; sub(/^[[:space:]]*#[[:space:]]?/,"",l); t=t" "l; next }
  { if (n) { print f"\t"s"\t"t; n=0 } }
  END { if (n) print f"\t"s"\t"t }
' src/*.roc tests/*.roc > "$BLOCKS" \
  || { echo "issue-claims: Roc extraction failed — a listed file or glob is missing" >&2; exit 5; }

# Markdown needs its OWN extractor: no comment syntax, so the `^#` rule would
# key on HEADINGS. A block is a paragraph (consecutive non-blank lines), same
# file<TAB>line<TAB>text shape as the Roc pass.
#
# FNR==1 flushes at every file boundary: without it a file ending mid-paragraph
# merges into the next file's opener and the stale claim is reported at the
# wrong document. The Roc pass needs the same guard for a file ending on a
# comment line.
#
# FENCED REGIONS ARE DROPPED HERE, AT LINE LEVEL. A fence is an ODD backtick
# run and a LINE construct that cannot be recognised after joining; counting
# delimiters sees the total while the damage is the pairing (one stray tick
# restores an even total with inverted polarity). On this tree all 28 length-3
# runs are fences; dropping them takes odd runs to zero, the only state where
# an even total implies correct pairing.
awk '
  FNR==1 { if (n) { print f"\t"s"\t"t; n=0 } fence=0 }
  /^[[:space:]]*```/ { fence = 1 - fence; next }
  fence { next }
  /^[[:space:]]*$/ { if (n) { print f"\t"s"\t"t; n=0 } next }
  { if (!n) { f=FILENAME; s=FNR; t="" } n++; t=t" "$0 }
  END { if (n) print f"\t"s"\t"t }
' README.md AGENTS.md $(ls PLAN.md 2>/dev/null) docs/*.md docs/adr/*.md .claude/skills/stride/SKILL.md >> "$BLOCKS" \
  || { echo "issue-claims: markdown extraction failed — a listed file is missing" >&2; exit 5; }

while IFS=$'\t' read -r f s txt; do
  blocks=$((blocks + 1))
  # "open ABOVE", "keeps this open" are not issue states — the phrase must sit
  # near a ref. `pending`/`awaited` are qualified, never bare: bare `pending` is
  # this codebase's own vocabulary ("pending backfill") and would flag forever.
  #
  # NO PARSING. A block opts out with a literal marker, and that is the whole
  # mechanism: deciding mechanically whether a phrase is asserted or merely QUOTED
  # is a natural-language problem, and every heuristic tried (quote pairing,
  # parity, fence counting) was defeated by a single compensating character,
  # silently, in the MISS direction. The marker cannot be defeated — there is
  # nothing to mis-pair — and can only be OVER-applied, loudly:
  # `grep -rn 'issue-claims: quoting'` lists every use. Forgetting it on new
  # quoted history goes red naming the file and line; the heuristics failed by
  # reporting a clean tree with a stale claim in it.
  #
  # EXPECTED is pinned below so an accidental token fails loudly instead of
  # widening the exemption. Counts OCCURRENCES, not blocks, so the pin agrees
  # with the grep above and sees a copy-pasted duplicate inside a marked block.
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

# Zero CHECKED pairs is legitimate -- it is what a clean tree looks like. Zero BLOCKS
# is not: that means the extraction broke. Conflating the two calls a healthy repo
# broken, or reports success while checking nothing.
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
