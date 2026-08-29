#!/bin/sh
# Check SKILL.md's documented payload shapes against schemas/v2/*.json.
#
# SKILL.md is the coaching agent's instruction sheet. Nothing connected its
# field names to the schemas, so a field could be added, marked required,
# shipped, and never reach the agent — which happened twice in three days
# (#292's `hidden`, then `hidden_lens`/`hidden_scope`), both caught by a human.
# The failure is silent in the direction that matters: an agent given an
# undocumented field does not error, it simply never uses it.
#
# Membership lives in `tools/skill-shapes.pins`, checked in — NOT measured from
# the doc: with the doc as denominator, drift lowers coverage and switches OFF
# the check (dropping ONE field of six is caught at 83%; dropping TWO is silent
# at 66%, and two-at-once is verbatim how the motivating drift landed). The pin
# means a schema's required set cannot change without this gate failing, and
# updating it is the moment someone decides whether the field belongs in
# SKILL.md (#298).
#
# Two directions: (1) schema -> doc — every required field of a `doc`-pinned
# object must be named in that command's documentation; (2) doc -> schema —
# every key inside a `{...}` literal must exist as a schema property, catching
# documentation that still promises a renamed or removed field.
set -eu
# Byte collation, everywhere. Every comparison in this script runs through `sort`, and the
# pin file is a checked-in artifact compared line by line against a freshly sorted one — so
# a locale that orders differently makes the SAME content disagree with itself. Windows CI
# caught exactly that: every line reported as both pinned and actual, identical text, because
# Git Bash sorted it differently from the macOS run that generated the pin.
export LC_ALL=C
# ...and every generated stream is stripped of carriage returns at the point it is written.
# `jq` on Windows opens stdout in text mode and emits CRLF, so the side this script GENERATES
# carried CR while the side it read from disk did not — every line differing with identical
# text, for the third time on this branch and by the third distinct mechanism. Normalising at
# the source rather than at each comparison is what stops a fourth.
cd "$(dirname "$0")/.."
SK=skills/stride/SKILL.md

SCHEMAS=schemas/v2
PINS=tools/skill-shapes.pins
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# SKILL.md with hard-wrapped paragraph lines folded together: the payload
# literals for `sync` and `analyze` split across source lines, so a line-scoped
# extractor finds ZERO complete `{...}` spans there.
#
# Direction 2 reaches all three prose literals, including `config unset`'s,
# which has no table row. Direction 1 reaches `sync` but NOT `analyze` — an
# accident of where the paragraph breaks fall, not a design; `analyze`'s
# required set is still pinned, so a schema change fails the gate, and what is
# missing is only the check that SKILL.md names each new field. Closing that
# needs prose-to-command attribution, and the last heuristic for it produced
# twelve false reports.
#
# A folded paragraph is a large haystack: a required field with a common name
# can be satisfied by text about a different command (a sweep found six such
# coincidences — `value`, `points`, `month`…). Each is a SECOND line of defence
# failing; the pin fails unconditionally on any schema change regardless.
LOGICAL="$tmp/logical.md"
awk '
  function isnew(l) {
    # A line STARTS a new logical line when it is blank, a heading, a table row, a fence,
    # or a list bullet. Everything else continues the paragraph above it — which is what
    # Markdown means by a hard wrap. Do not require leading whitespace on continuations:
    # the `sync` literal wraps onto a column-0 line, and a whitespace condition never
    # joins it, leaving both directions blind while looking covered.
    return (l ~ /^[ \t]*$/) || (l ~ /^#/) || (l ~ /^\|/) || (l ~ /^```/) || (l ~ /^[ \t]*([-*+]|[0-9]+\.)[ \t]/)
  }
  NR == 1 { printf "%s", $0; next }
  isnew($0) { printf "\n%s", $0; next }
  { sub(/^[ \t]+/, ""); printf " %s", $0 }
  END { printf "\n" }
' "$SK" > "$LOGICAL"

# The command->schema join, derived from `src/Command.roc`'s table rather than restated.
grep '\(reads\|writes\)("' src/Command.roc | while IFS= read -r line; do
  n=$(printf '%s\n' "$line" | grep -o '\(reads\|writes\)("[^"]*"' | head -1 | sed 's/.*("//;s/"$//')
  s=$(printf '%s\n' "$line" | grep -o '"[a-z_]*\.json"' | tail -1 | tr -d '"')
  if [ -n "$n" ] && [ -n "$s" ]; then printf '%s\t%s\n' "$n" "$s"; fi
done | sort -u > "$tmp/join"

# The CURRENT signature of every object carrying a required list, keyed by schema and by the
# sorted property names of the object itself. Keying on the property set rather than on a
# path means reordering or renaming a wrapper does not churn the pin, while adding or
# removing a field — the thing being guarded — always does.
: > "$tmp/sig"
for f in "$SCHEMAS"/*.json; do
  b=$(basename "$f")
  jq -r --arg b "$b" '
    [.. | objects | select(has("required")) | select(has("properties"))]
    | .[] | $b + "\t" + ((.properties | keys | sort | join(",")))
          + "\t" + ((.required | sort | join(",")))' "$f" 2>/dev/null | tr -d '\r' >> "$tmp/sig" || true
done
sort -u "$tmp/sig" > "$tmp/sig.sorted"

# Every line of SKILL.md that documents a given command. Table rows AND prose, because the
# payload literals for `sync` and `analyze` live in a bullet rather than the table.
#
# A row is attributed to the LONGEST command it names, derived from the join rather than
# guessed: `stride week add ...` documents `week add`, not `week`. An awk boundary of
# `([^a-z0-9-]|$)` contains a space, so under it `week` claims `week add`'s row and is
# satisfied by its neighbour's text.
doc_for() {
  cmd=$1
  grep -F "stride $cmd" "$LOGICAL" 2>/dev/null > "$tmp/cand" || true
  # A line naming a LONGER command documents THAT command, not this one. `week add`'s row
  # is not `week`'s. Derived from the join rather than guessed with a character class —
  # see the boundary note above.
  cut -f1 "$tmp/join" | grep "^$cmd " > "$tmp/longer" || true
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    # NOT `grep -vF ... && mv ...`: when the filter matches every line grep exits 1, the
    # `mv` never runs, and `cand` silently keeps the UNFILTERED text. That is live for
    # `config`, whose four lines all name a longer form. Redirect first, move always.
    grep -vF "stride $l" "$tmp/cand" > "$tmp/cand2" || true
    mv "$tmp/cand2" "$tmp/cand"
  done < "$tmp/longer"
  # The invocation cell is stripped before the text is searched: it holds argument
  # PLACEHOLDERS (`[date]`, `<id>`, `[n]`), and leaving them in lets a CLI
  # argument satisfy a payload field of the same name (measured with `km`).
  # `[^|]*` after the closing backtick, not ` *`: two rows carry `(alias `pc`)`
  # before the next pipe, so the anchored form matched nothing and the whole row
  # survived, placeholders included.
  #
  # Two limits, recorded because this strip's job is to have known ones. An inline
  # invocation in PROSE (`stride config get <key> --json`) is a different route to
  # the same place — the anchor is `^|`, so it never sees one, and `config.json` /
  # `config_unset.json` both rest a required `key` on it. And a reworded cell can
  # stop matching entirely, reopening the placeholder hole for that row; the pin
  # still fails unconditionally on any schema change, so this is a second line of
  # defence that can go quiet, not a hole in the first.
  sed 's/^| *`[^`]*`[^|]*|//' "$tmp/cand"
}

# Every command whose schema is $1, unioned. A schema can be reached by several names —
# `zones.json` by both `zones` and `pz` — and picking one alphabetically picks the ALIAS,
# which SKILL.md never writes. That silently blanked `zones`, `power-curve`, `commands` and
# `version`: `doc_for` returned nothing, so the refresh wrote them un-enforced while the doc
# in fact documents them in full.
doc_for_schema() {
  awk -F'\t' -v s="$1" '$2 == s {print $1}' "$tmp/join" | while IFS= read -r c; do
    [ -n "$c" ] && doc_for "$c"
  done
}


: > "$tmp/problems"
pinned=0

# `--refresh` rewrites the pin file from the current schemas and doc. It is the deliberate
# act the failure message asks for, and it is separate from the check so that refreshing is
# never something the gate does for you on the way past.
if [ "${1:-}" = "--refresh" ]; then
  : > "$tmp/new"
  while IFS="$(printf '\t')" read -r schema props req; do
    cmd=$(awk -F'\t' -v s="$schema" '$2 == s {print $1; exit}' "$tmp/join")
    flag="-"
    if [ -n "$cmd" ]; then
      doc_for_schema "$schema" > "$tmp/doc"
      if [ -s "$tmp/doc" ]; then
        miss=0
        for rk in $(printf '%s' "$req" | tr ',' ' '); do
          grep -q "[^A-Za-z0-9_]$rk\([^A-Za-z0-9_]\|\$\)" "$tmp/doc" || miss=1
        done
        [ "$miss" = 0 ] && flag="doc"
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$schema" "$props" "$req" "$flag" >> "$tmp/new"
  done < "$tmp/sig.sorted"
  # A doc -> - transition means an object STOPPED being enforced, and refresh is the one
  # place that can happen. Left silent it is the whole escape hatch: hit the pin failure,
  # refresh as the message tells you, and the object quietly leaves the enforced set with
  # nothing in the diff but a flag character. Named loudly, and the count below moves too.
  #
  # Temp files rather than `<(...)`: this is /bin/sh, and process substitution is a bashism
  # that parses as a syntax error here rather than failing at run time.
  tr -d '\r' < "$PINS" > "$tmp/pins.lf.refresh"
  awk -F'\t' '$4=="doc" {print $1"  "$2}' "$tmp/pins.lf.refresh" | sort > "$tmp/was_doc"
  awk -F'\t' '$4!="doc" {print $1"  "$2}' "$tmp/new" | sort > "$tmp/now_not"
  comm -12 "$tmp/was_doc" "$tmp/now_not" > "$tmp/downgraded"
  if [ -s "$tmp/downgraded" ]; then
    echo "skill-shapes: WARNING — these objects are being DOWNGRADED from enforced to unenforced:"
    sed 's/^/  DOWNGRADED: /' "$tmp/downgraded"
    echo "skill-shapes: that is SKILL.md no longer naming every required field of those objects."
    echo "skill-shapes: document them instead, unless dropping the coverage is what you meant."
  fi
  mv "$tmp/new" "$PINS"
  echo "skill-shapes: refreshed $PINS ($(wc -l < "$PINS" | tr -d ' ') objects, $(awk -F'\t' '$4=="doc"' "$PINS" | wc -l | tr -d ' ') marked doc)"
  echo "skill-shapes: re-run without --refresh, and update EXPECT_PINNED/EXPECT_LITERALS if they moved."
  exit 0
fi

# ── Pin agreement. Any schema whose required set moved fails here, documented or not. ──
cut -f1,2,3 "$tmp/sig.sorted" > "$tmp/sig.cmp"
# Read through an LF-normalised copy, never the file on disk. A `.gitattributes` `eol=lf`
# asks the checkout to behave; this does not have to ask. Windows CI reported every pin line
# as changed while the text was identical — the same shape as the collation bug one commit
# earlier, reached through carriage returns, and a gate that certifies a checked-in artifact
# should not depend on how the artifact was checked out.
tr -d '\r' < "$PINS" > "$tmp/pins.lf"
PINS_LF="$tmp/pins.lf"
cut -f1,2,3 "$PINS_LF" | sort -u > "$tmp/pins.cmp"
if ! diff -q "$tmp/sig.cmp" "$tmp/pins.cmp" >/dev/null 2>&1; then
  echo "skill-shapes: a schema's required set changed and $PINS does not agree."
  echo
  diff "$tmp/pins.cmp" "$tmp/sig.cmp" | sed 's/^</  pinned:  /;s/^>/  actual:  /' | grep -v '^[0-9-]' || true
  echo
  echo "Decide whether the changed field belongs in SKILL.md, update it if so, then refresh"
  echo "the pin with:  sh tools/skill-shapes.sh --refresh"
  exit 1
fi

# ── Direction 1: every required field of a `doc`-pinned object appears in the doc text. ──
while IFS="$(printf '\t')" read -r schema props req flag; do
  [ "$flag" = "doc" ] || continue
  pinned=$((pinned + 1))
  # The label is the command that actually DOCUMENTS this schema, not the alphabetically
  # first name mapping to it. Taking `head -1` on a sorted join labels alias-reached schemas
  # by the alias — reporting `pc` and `pz`, names SKILL.md never writes, so the message names
  # something the reader cannot find in the file it is being told to fix.
  cmd=""
  for c in $(awk -F'\t' -v s="$schema" '$2 == s {print $1}' "$tmp/join"); do
    if [ -z "$cmd" ]; then cmd="$c"; fi
    if [ -n "$(doc_for "$c")" ]; then cmd="$c"; break; fi
  done
  [ -n "$cmd" ] || continue
  doc_for_schema "$schema" > "$tmp/doc"
  printf '%s\n' "$req" | tr ',' '\n' | while IFS= read -r rk; do
    [ -n "$rk" ] || continue
    grep -q "[^A-Za-z0-9_]$rk\([^A-Za-z0-9_]\|\$\)" "$tmp/doc" ||
      printf 'undocumented  %-12s %-18s %s is required and SKILL.md does not name it\n' \
        "$cmd" "$schema" "$rk" >> "$tmp/problems"
  done
done < "$PINS_LF"

# ── Direction 2: every brace literal in SKILL.md must match SOME schema object. ──
#
# No command is identified at any point, and that is the fix rather than a shortcut. The
# first version asked "whose payload is this literal?", answered it by which command the
# line mentions, and reported twelve of another command's fields as unknown because a
# bullet saying "run `stride analyze`" is not a statement about `analyze`'s payload. The
# repair was to read table rows only — which bought accuracy by going blind to every
# literal in prose, including `config unset`'s `{key, removed}`, a command with no table
# row at all.
#
# Asking instead whether the key set is a SUBSET of some single object's properties needs
# no attribution and cannot be fooled by a mention. A literal that matches nothing is
# either a renamed field or a typo, and both are the drift this direction exists to catch.
: > "$tmp/objprops"
for f in "$SCHEMAS"/*.json; do
  jq -r '[.. | objects | select(has("properties")) | .properties | keys | sort | join(",")] | .[]' \
    "$f" 2>/dev/null | tr -d '\r' >> "$tmp/objprops" || true
done
sort -u "$tmp/objprops" > "$tmp/objprops.u"

: > "$tmp/lits"
cp "$LOGICAL" "$tmp/w"
while grep -q '{[^{}]*}' "$tmp/w"; do
  grep -o '{[^{}]*}' "$tmp/w" >> "$tmp/lits"
  # `@`, not `X`: the sentinel replaces a literal already consumed, and with the key class
  # widened to accept capitals an `X` sentinel parses as a key itself and reports three
  # phantom unmatched literals on a clean tree. Both halves of this fix are needed together.
  sed 's/{[^{}]*}/@/g' "$tmp/w" > "$tmp/w2"; mv "$tmp/w2" "$tmp/w"
done

literals=0
sort -u "$tmp/lits" | while IFS= read -r lit; do
  # `[A-Za-z_]`, because a lowercase-only class begins matching AFTER a capital and
  # silently truncates the key to its tail. `{key, Xremoved}` extracted as `removed`, a
  # real property, so the gate PASSED on a documented field that does not exist. Live for
  # any doc writing a key with a capital, not merely a hazard when authoring a mutation.
  keys=$(printf '%s\n' "$lit" | grep -o '[A-Za-z_][A-Za-z_0-9]* *[,:}]' | sed 's/ *.$//' | sort -u)
  [ -n "$keys" ] || continue
  literals=$((literals + 1)); printf '%s\n' "$literals" > "$tmp/lc"
  hit=0
  while IFS= read -r props; do
    all=1
    for k in $keys; do
      case ",$props," in *",$k,"*) ;; *) all=0 ;; esac
    done
    if [ "$all" = 1 ]; then hit=1; break; fi
  done < "$tmp/objprops.u"
  [ "$hit" = 1 ] ||
    printf 'unmatched     %-31s %s\n' "$(printf '%s' "$keys" | tr '\n' ' ')" \
      "names no single schema object holding all of these" >> "$tmp/problems"
done
literals=$(cat "$tmp/lc" 2>/dev/null || echo 0)

n=$(wc -l < "$tmp/problems" | tr -d ' ')
if [ "$n" -gt 0 ]; then
  echo "skill-shapes: $n payload-shape mismatch(es)"
  echo
  sort "$tmp/problems"
  exit 1
fi
# Both counts are asserted EXACTLY, not as floors: under a floor of 12 against an actual
# 16, four rows can stop matching — a reworded row, a deleted schema — while the gate
# prints the same clean line a healthy tree prints. A count that may only
# be raised deliberately is the difference between a guard and a decoration.
EXPECT_PINNED=29
EXPECT_LITERALS=27
if [ "$pinned" != "$EXPECT_PINNED" ] || [ "$literals" != "$EXPECT_LITERALS" ]; then
  echo "skill-shapes: enforced $pinned doc-pinned objects and matched $literals brace literals;"
  echo "skill-shapes: expected $EXPECT_PINNED and $EXPECT_LITERALS. If intended, update these"
  echo "skill-shapes: numbers in the same commit; if it is not, the join or the doc lookup broke."
  exit 1
fi

echo "skill-shapes: $pinned doc-pinned objects checked for required fields, $literals brace literals matched to schema objects — all clean"
