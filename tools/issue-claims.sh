#!/usr/bin/env bash
# A `#NNN` in a comment asserting an issue is open/unfixed/pending is a claim with a
# free oracle: this flags any comment/paragraph BLOCK that both names a ref and makes
# such a claim (the grep pattern below is the authority on phrasings) when the tracker
# says CLOSED. Scope: Roc comments + the Markdown docs. Bare `pending`/`awaiting` are
# NOT matched (house vocabulary); the qualified `(is|still|remains)` prefix is, with no
# trailing boundary, so `is pending backfill` matches.
#
# BLOCK-scoped: ref and claim are usually lines apart in one paragraph — line-scoped
# pairing matched zero times on this tree. Over-reports within a block by design; a
# false flag costs one read, a miss cost #105. Description accuracy is judgment and out
# of scope; this is the mechanical half.
#
# bash 3.2 (macOS): no mapfile, no associative arrays, no python — block grouping is awk.
set -uo pipefail
REPO="${GH_REPO:-eschizoid/stride}"
CACHE=$(mktemp); BLOCKS=$(mktemp); trap 'rm -f "$CACHE" "$BLOCKS"' EXIT
fail=0; checked=0; blocks=0; quoting=0
# every `issue-claims: quoting` marker in the repo, pinned so a new one is deliberate.
# PLAN.md is listed via `ls` so absence is not an error while presence is scanned —
# AGENTS.md permits a root PLAN.md only on condition this tool reads it.
# The `|| exit` guards matter: macOS awk ABORTS its remaining argument list on a missing
# file (it does not skip), so one absent entry silently truncates the scan and every file
# listed after it goes unread while the run still exits 0.
EXPECTED_QUOTING=4

# one line per comment block: file<TAB>startline<TAB>joined text (guarded — see the
# awk-aborts note above)
awk '
  FNR==1 { if (n) { print f"\t"s"\t"t; n=0 } }
  /^[[:space:]]*#/ { if (!n) { f=FILENAME; s=FNR; t="" } n++; l=$0; sub(/^[[:space:]]*#[[:space:]]?/,"",l); t=t" "l; next }
  { if (n) { print f"\t"s"\t"t; n=0 } }
  END { if (n) print f"\t"s"\t"t }
' src/*.roc tests/*.roc > "$BLOCKS" \
  || { echo "issue-claims: Roc extraction failed — a listed file or glob is missing" >&2; exit 5; }

# Markdown gets its own extractor: `^#` would key on HEADINGS, so a block is a
# paragraph (consecutive non-blank lines), same output shape as the Roc pass.
# FNR==1 flushes at file boundaries — without it a file ending mid-paragraph merges
# into the next file's opener and a stale claim is reported at the wrong document.
# Fenced regions are dropped HERE, at line level: a fence is a line construct that
# cannot be recognised after joining, and one stray backtick inverts pairing while
# keeping the delimiter count even.
awk '
  FNR==1 { if (n) { print f"\t"s"\t"t; n=0 } fence=0 }
  /^[[:space:]]*```/ { fence = 1 - fence; next }
  fence { next }
  /^[[:space:]]*$/ { if (n) { print f"\t"s"\t"t; n=0 } next }
  { if (!n) { f=FILENAME; s=FNR; t="" } n++; t=t" "$0 }
  END { if (n) print f"\t"s"\t"t }
' README.md AGENTS.md $(ls PLAN.md 2>/dev/null) docs/*.md docs/adr/*.md skills/stride/SKILL.md >> "$BLOCKS" \
  || { echo "issue-claims: markdown extraction failed — a listed file is missing" >&2; exit 5; }

while IFS=$'\t' read -r f s txt; do
  blocks=$((blocks + 1))
  # A block quoting history (not asserting state) opts out with a literal marker —
  # deciding asserted-vs-quoted mechanically is a natural-language problem, and every
  # heuristic tried failed silently in the MISS direction. The marker can only be
  # over-applied, loudly; the pin below makes an accidental token deliberate. Counted
  # as OCCURRENCES, not blocks, so a copy-pasted duplicate inside one block is seen.
  case "$txt" in
    *"issue-claims: quoting"*)
      # grep -o | wc -l, NOT grep -c: the block is one joined line, and -c would read
      # two tokens as one — the exact case being guarded.
      quoting=$((quoting + $(printf '%s' "$txt" | grep -o 'issue-claims: quoting' | wc -l)))
      continue ;;
  esac
  said="$txt"
  printf '%s' "$said" | grep -qiE 'remains open|still open|not yet (fixed|released|landed|merged)|blocked (by|on)|awaiting (upstream|release|a fix|the fix|merge)|(is|still|remains) awaiting|(is|still) awaited|(is|still|remains) pending|pending (upstream|release|a fix|the fix)|unreleased|until .*(lands|ships)' || continue
  # Strip mermaid/CSS colours BEFORE ref extraction, or `stroke:#57606a` hands the ref
  # pattern an unresolvable number and the fail-closed arm turns CI red on a stylesheet.
  # Property-prefixed colours go first at any shorthand length (the prefix is what makes
  # stripping 3-4 digit runs safe — a bare `#196` never carries one), and the prefix must
  # be a whole word: without the leading boundary, `backfill:#196` matched on its last
  # four letters. Then bare six-digit hex.
  clean=$(printf '%s' "$txt" | sed -E 's/(^|[^a-z])(fill|stroke|color):#[0-9a-fA-F]{3,8}/\1/g; s/#[0-9a-fA-F]{6}//g')
  refs=$(printf '%s' "$clean" | grep -oE '(^|[^a-zA-Z/-])#[0-9]{2,5}' | grep -oE '[0-9]{2,5}' | sort -u)
  [ -z "$refs" ] && continue
  for ref in $refs; do
    st=$(grep "^$ref " "$CACHE" 2>/dev/null | cut -d' ' -f2)
    if [ -z "$st" ]; then
      st=$(gh issue view "$ref" --repo "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN)
      echo "$ref $st" >> "$CACHE"
    fi
    # UNKNOWN = the ORACLE failed (auth/network/repo), not that the claim is fine —
    # failing open would make an outage look like a clean tree.
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

# Zero CHECKED pairs = a clean tree; zero BLOCKS = broken extraction. Conflating them
# reports success while checking nothing.
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
