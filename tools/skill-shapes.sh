#!/usr/bin/env sh
# Check SKILL.md's documented payload shapes against schemas/v3/*.json.
#
# SKILL.md is the coaching agent's instruction sheet; an agent given an undocumented
# field does not error, it silently never uses it (#292, twice in three days). Membership
# lives in `tools/skill-shapes.pins`, checked in — NOT measured from the doc, because
# with the doc as denominator, drift lowers coverage and switches the check off. The
# pin is a DEDUPLICATED set of (schema, property-set, required-set) rows — 79 objects
# reduce to 73 — so it records which SHAPES a schema holds (its shape rows), not how
# many or where. A change moving that set fails the gate; updating it is the moment
# someone decides whether the field belongs in SKILL.md (#298). Known hole: it compares
# SETS, so any SCHEMA change leaving the set intact is invisible — an object can leave
# while an identically-shaped sibling still emits its row, and one can arrive whose row
# a sibling already emits. Activity, compare, stats and summary each carry one (#346).
#
# Two directions: (1) schema -> doc — every required field of a `doc`-pinned object
# must be named in that command's documentation; an object pinned `-` is held to the
# pin alone, so a change to its shape rows still fails there — subject to the hole
# above — while this check's doc side never runs (`--refresh` does run it, which is
# how a `-` becomes `doc`). A field's TYPE is not pinned: scalar-to-scalar retypes,
# enum changes and array-vs-object cardinality all pass, since jq's `..` recurses
# through arrays and an array wrapper exposes the identical object. The two
# directions read DIFFERENT sets: the pin takes objects carrying both `properties`
# and `required`, direction 2 takes every object carrying `properties`. A retype
# moves the pin only when it adds a row the set lacked or removes the last object
# carrying one; adding a properties-only object fails nothing and silently widens
# what direction 2 accepts. (2) doc -> schema — every `{...}` literal's key set must
# be a SUBSET of some SINGLE schema object's properties, catching documentation that
# still promises a renamed or removed field. Per-key existence is NOT the rule: keys
# drawn from different objects each exist and still fail, because no single payload
# object has them as siblings; nested payloads are written as nested literals,
# peeled innermost-first.
set -eu
# Byte collation everywhere: the pin is a checked-in artifact compared line-by-line
# against a freshly sorted one, so a locale that orders differently makes the SAME
# content disagree with itself (Windows CI: every line both pinned and actual).
export LC_ALL=C
# ...and every generated stream is CR-stripped where written: Windows jq emits CRLF in
# text mode, and normalising at the source beats normalising at each comparison.
cd "$(dirname "$0")/.."
SK=skills/stride/SKILL.md

SCHEMAS=schemas/v3
PINS=tools/skill-shapes.pins
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# SKILL.md with hard-wrapped paragraphs folded to logical lines — the sync/analyze
# payload literals span source lines, so a line-scoped extractor finds zero `{...}`
# spans there. Known limits: direction 1 reaches sync but not analyze (paragraph-break
# accident; analyze stays pinned so changes to its shape rows still fail), and
# a folded paragraph is a big haystack where a common field name can be satisfied by
# unrelated text — a second line of defence weakening, while the pin still fails on any
# change that moves the pinned set.
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

# The command->schema join, derived from the table rather than restated.
grep '\(reads\|writes\)("' src/Command.roc | while IFS= read -r line; do
  n=$(printf '%s\n' "$line" | grep -o '\(reads\|writes\)("[^"]*"' | head -1 | sed 's/.*("//;s/"$//')
  s=$(printf '%s\n' "$line" | grep -o '"[a-z_]*\.json"' | tail -1 | tr -d '"')
  if [ -n "$n" ] && [ -n "$s" ]; then printf '%s\t%s\n' "$n" "$s"; fi
done | sort -u > "$tmp/join"

# Every required-carrying object's signature, keyed by schema + sorted property names,
# then DEDUPLICATED: renaming a wrapper leaves the wrapped object's own signature
# untouched, but the parent object's property list moves, so the gate still fails.
# Adding or removing a field always moves a row — the new shape APPEARS even when a
# sibling still emits the old one. What a twin hides is a change that does not move the
# SET: an object leaving without removing its row — dropping `required`, dropping
# `properties` (membership needs both), or deleting an object no parent's property list
# mentions, such as an `items` node — or an object arriving whose row a twin already
# emits (#346).
: > "$tmp/sig"
for f in "$SCHEMAS"/*.json; do
  b=$(basename "$f")
  jq -r --arg b "$b" '
    [.. | objects | select(has("required")) | select(has("properties"))]
    | .[] | $b + "\t" + ((.properties | keys | sort | join(",")))
          + "\t" + ((.required | sort | join(",")))' "$f" 2>/dev/null | tr -d '\r' >> "$tmp/sig" || true
done
sort -u "$tmp/sig" > "$tmp/sig.sorted"

# Every SKILL.md line documenting a command — rows AND prose (sync/analyze literals
# live in bullets). A line is attributed to the LONGEST command it names, derived from
# the join: `stride week add ...` documents `week add`, not `week`. Do NOT reach for a
# word boundary instead: `([^a-z0-9-]|$)` contains a SPACE, so under it `week` claims
# `week add`'s row and is satisfied by its neighbour's text.
doc_for() {
  cmd=$1
  grep -F "stride $cmd" "$LOGICAL" 2>/dev/null > "$tmp/cand" || true
  # A line naming a LONGER command documents THAT command, not this one. `week add`'s row
  # is not `week`'s. Derived from the join rather than guessed with a character class —
  # see the boundary note above.
  cut -f1 "$tmp/join" | grep "^$cmd " > "$tmp/longer" || true
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    # Redirect first, move always: `grep -v && mv` skips the mv when the filter
    # matches everything (grep exits 1), silently keeping the unfiltered text.
    grep -vF "stride $l" "$tmp/cand" > "$tmp/cand2" || true
    mv "$tmp/cand2" "$tmp/cand"
  done < "$tmp/longer"
  # Strip the invocation cell before searching: its argument PLACEHOLDERS would let a
  # CLI arg satisfy a same-named payload field. `[^|]*` after the closing backtick, not
  # ` *` — alias parentheticals sit before the pipe and the anchored form matched
  # nothing. Known limits: prose invocations bypass the `^|` anchor (config's required
  # `key` rests on one), and a reworded cell can stop matching — second-line defence
  # weakening only; the pin still fails on any change that moves the pinned set.
  sed 's/^| *`[^`]*`[^|]*|//' "$tmp/cand"
}

# Every command reaching schema $1, unioned — picking one name alphabetically picks
# the ALIAS (`pz`), which SKILL.md never writes, blanking fully-documented schemas.
doc_for_schema() {
  awk -F'\t' -v s="$1" '$2 == s {print $1}' "$tmp/join" | while IFS= read -r c; do
    [ -n "$c" ] && doc_for "$c"
  done
}


: > "$tmp/problems"
pinned=0

# `--refresh` rewrites the pin from current schemas+doc — deliberately separate from
# the check, so refreshing is never something the gate does for you on the way past.
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
  # A doc -> - transition = an object STOPPED being enforced, and refresh is the one
  # place that can happen silently — named loudly here, and the count moves too.
  # Temp files, not `<(...)`: /bin/sh parses process substitution as a syntax error.
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

# ── Pin agreement. Any schema whose set of shape rows moved fails here. ──
cut -f1,2,3 "$tmp/sig.sorted" > "$tmp/sig.cmp"
# Read an LF-normalised copy, never the file on disk — gitattributes asks the checkout
# to behave; this does not have to ask.
tr -d '\r' < "$PINS" > "$tmp/pins.lf"
PINS_LF="$tmp/pins.lf"
cut -f1,2,3 "$PINS_LF" | sort -u > "$tmp/pins.cmp"
if ! diff -q "$tmp/sig.cmp" "$tmp/pins.cmp" >/dev/null 2>&1; then
  echo "skill-shapes: a schema's shape rows changed and $PINS does not agree."
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
  # Label with the command that DOCUMENTS the schema, not the alphabetically first
  # name — head -1 labels alias-reached schemas `pc`/`pz`, names SKILL.md never writes.
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
# No command is identified anywhere, deliberately: attributing a literal by which
# command the line MENTIONS mis-filed prose ("run `stride analyze`" is not a statement
# about analyze's payload), and reading table rows only went blind to prose literals.
# Subset-of-some-object needs no attribution and cannot be fooled by a mention; a
# literal matching nothing is a renamed field or a typo — the drift being caught.
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
  # `@` sentinel, not `X`: with the key class accepting capitals, an X parses as a key
  # and reports phantom unmatched literals on a clean tree.
  sed 's/{[^{}]*}/@/g' "$tmp/w" > "$tmp/w2"; mv "$tmp/w2" "$tmp/w"
done

literals=0
sort -u "$tmp/lits" | while IFS= read -r lit; do
  # `[A-Za-z_]`: a lowercase-only class starts matching AFTER a capital, truncating
  # `Xremoved` to the real property `removed` and passing a field that does not exist.
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
# Both counts asserted EXACTLY, not as floors: under a floor, rows can stop matching
# while the gate prints the same clean line a healthy tree prints.
EXPECT_PINNED=33
EXPECT_LITERALS=30
if [ "$pinned" != "$EXPECT_PINNED" ] || [ "$literals" != "$EXPECT_LITERALS" ]; then
  echo "skill-shapes: enforced $pinned doc-pinned objects and matched $literals brace literals;"
  echo "skill-shapes: expected $EXPECT_PINNED and $EXPECT_LITERALS. If intended, update these"
  echo "skill-shapes: numbers in the same commit; if it is not, the join or the doc lookup broke."
  exit 1
fi

echo "skill-shapes: $pinned doc-pinned objects checked for required fields, $literals brace literals matched to schema objects — all clean"
