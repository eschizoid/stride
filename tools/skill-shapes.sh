#!/bin/sh
# Check SKILL.md's documented payload shapes against schemas/v2/*.json.
#
# SKILL.md is the coaching agent's instruction sheet, and it names each command's payload
# fields. Nothing connected those names to the schemas, so a field could be added to a
# schema, marked required, shipped, and never reach the agent. That happened TWICE in three
# days in consecutive commits of one PR (#292's `groups[].hidden`, then `hidden_lens` and
# `hidden_scope`), both caught by a human reading the diff. The failure is silent in the
# direction that matters: an agent given an undocumented field does not error, it simply
# never uses it.
#
# ── Why the membership question is answered by a PIN FILE and not by measuring the doc ──
#
# The first version of this gate decided which objects to enforce by measuring how much of
# each one SKILL.md already listed, and enforcing full coverage above a threshold. Review
# killed it: the denominator is the document being judged, so drift lowers the coverage and
# switches OFF the check that would have caught it. Dropping ONE field from a six-field
# object leaves 83% and is caught; dropping TWO leaves 66% and is silent — and "two at
# once" is not a hypothetical, it is verbatim how `hidden_lens`/`hidden_scope` landed. The
# gate would not have caught the second of the two drifts it was built for.
#
# So membership lives in `tools/skill-shapes.pins`, which is checked in. Two consequences
# worth stating because they are the point rather than side effects:
#
#   • a schema's required set cannot change without this gate failing, whatever the doc
#     says. Updating the pin is the moment someone decides whether the new field belongs in
#     SKILL.md, which is what #298 asked for.
#   • coverage is enforced for every schema in the table, not only the 16 with a row in the
#     command table. `sync` and `analyze` carry complete payload literals in PROSE, and the
#     measured version could not see them at all.
#
# ── The two directions ──
#
#   1. schema -> doc: for every object pinned `doc`, each of its required fields must be
#      named somewhere in that command's documentation.
#   2. doc -> schema: every key inside a `{...}` literal must exist as a schema property.
#      Catches documentation still promising a field that was renamed or removed.
set -eu
cd "$(dirname "$0")/.."
SK=.claude/skills/stride/SKILL.md
SCHEMAS=schemas/v2
PINS=tools/skill-shapes.pins
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

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
          + "\t" + ((.required | sort | join(",")))' "$f" 2>/dev/null >> "$tmp/sig" || true
done
sort -u "$tmp/sig" > "$tmp/sig.sorted"

# Every line of SKILL.md that documents a given command. Table rows AND prose, because the
# payload literals for `sync` and `analyze` live in a bullet rather than the table.
#
# A row is attributed to the LONGEST command it names, derived from the join rather than
# guessed: `stride week add ...` documents `week add`, not `week`. The first cut used an
# awk boundary of `([^a-z0-9-]|$)`, which contains a space, so `week` claimed `week add`'s
# row and could be satisfied by its neighbour's text.
doc_for() {
  cmd=$1
  grep -F "stride $cmd" "$SK" 2>/dev/null > "$tmp/cand" || true
  # A row naming a LONGER command belongs to that command, not this one.
  cut -f1 "$tmp/join" | grep "^$cmd " > "$tmp/longer" || true
  while IFS= read -r l; do
    [ -n "$l" ] && grep -vF "stride $l" "$tmp/cand" > "$tmp/cand2" && mv "$tmp/cand2" "$tmp/cand" || true
  done < "$tmp/longer"
  # The invocation cell is stripped before the text is searched. It holds argument
  # PLACEHOLDERS — `[date]`, `[sport]`, `<id>`, `[n]`, `[days]` — and leaving them in lets
  # a CLI argument silently satisfy a payload field of the same name. Measured: a required
  # `date` added to `progress.groups[]` passed on the strength of the `[date]` placeholder.
  sed 's/^| *`[^`]*` *|//' "$tmp/cand"
}

# The TABLE ROW that documents a command, if it has one. Narrower than `doc_for` on
# purpose, and the difference matters for direction 2 only.
#
# Direction 1 asks "is this field named anywhere in this command's documentation?", so the
# wide context is right — `sync` and `analyze` describe their payloads in prose, and a
# field named there is named. Direction 2 asks "which schema does this literal belong to?",
# which needs the command to be the SUBJECT of the line rather than merely mentioned. Many
# bullets say "run `stride analyze`" while documenting something else entirely, and reading
# their literals as `analyze`'s reported twelve of another command's fields as unknown.
row_for() {
  cmd=$1
  awk -F'|' -v n="$cmd" '/^\| *`stride/ {
      cell = $2; gsub(/[`\\]/, "", cell)
      if (cell ~ ("^ *stride " n " *($|[^a-z0-9-])")) { sub(/^\|[^|]*\|/, "", $0); print }
    }' "$SK"
}

: > "$tmp/problems"
pinned=0; checked_cmds=0

# `--refresh` rewrites the pin file from the current schemas and doc. It is the deliberate
# act the failure message asks for, and it is separate from the check so that refreshing is
# never something the gate does for you on the way past.
if [ "${1:-}" = "--refresh" ]; then
  : > "$tmp/new"
  while IFS="$(printf '\t')" read -r schema props req; do
    cmd=$(awk -F'\t' -v s="$schema" '$2 == s {print $1; exit}' "$tmp/join")
    flag="-"
    if [ -n "$cmd" ]; then
      doc_for "$cmd" > "$tmp/doc"
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
  mv "$tmp/new" "$PINS"
  echo "skill-shapes: refreshed $PINS ($(wc -l < "$PINS" | tr -d ' ') objects, $(awk -F'\t' '$4=="doc"' "$PINS" | wc -l | tr -d ' ') marked doc)"
  echo "skill-shapes: re-run without --refresh, and update EXPECT_PINNED/EXPECT_CMDS if they moved."
  exit 0
fi

# ── Pin agreement. Any schema whose required set moved fails here, documented or not. ──
cut -f1,2,3 "$tmp/sig.sorted" > "$tmp/sig.cmp"
cut -f1,2,3 "$PINS" | sort -u > "$tmp/pins.cmp"
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
  cmd=$(awk -F'\t' -v s="$schema" '$2 == s {print $1; exit}' "$tmp/join")
  [ -n "$cmd" ] || continue
  doc_for "$cmd" > "$tmp/doc"
  printf '%s\n' "$req" | tr ',' '\n' | while IFS= read -r rk; do
    [ -n "$rk" ] || continue
    grep -q "[^A-Za-z0-9_]$rk\([^A-Za-z0-9_]\|\$\)" "$tmp/doc" ||
      printf 'undocumented  %-12s %-18s %s is required and SKILL.md does not name it\n' \
        "$cmd" "$schema" "$rk" >> "$tmp/problems"
  done
done < "$PINS"

# ── Direction 2: a key the documentation promises that no schema property backs. ──
while IFS="$(printf '\t')" read -r cmd schema; do
  [ -f "$SCHEMAS/$schema" ] || continue
  row_for "$cmd" > "$tmp/doc"
  [ -s "$tmp/doc" ] || continue
  checked_cmds=$((checked_cmds + 1))
  : > "$tmp/keys"
  cp "$tmp/doc" "$tmp/w"
  while grep -q '{[^{}]*}' "$tmp/w"; do
    grep -o '{[^{}]*}' "$tmp/w" | while IFS= read -r lit; do
      printf '%s\n' "$lit" | grep -o '[a-z_][a-z_0-9]* *[,:}]' | sed 's/ *.$//' >> "$tmp/keys"
    done
    sed 's/{[^{}]*}/X/g' "$tmp/w" > "$tmp/w2"; mv "$tmp/w2" "$tmp/w"
  done
  jq -r '[.. | objects | select(has("properties")) | .properties | keys[]] | unique[]' \
    "$SCHEMAS/$schema" > "$tmp/props" 2>/dev/null || : > "$tmp/props"
  sort -u "$tmp/keys" | while IFS= read -r k; do
    [ -n "$k" ] || continue
    grep -qx "$k" "$tmp/props" ||
      printf 'unknown-field %-12s %-18s SKILL.md names %s, which the schema has no property for\n' \
        "$cmd" "$schema" "$k" >> "$tmp/problems"
  done
  printf '%s\n' "$checked_cmds" > "$tmp/cc"
done < "$tmp/join"
checked_cmds=$(cat "$tmp/cc" 2>/dev/null || echo 0)

# Both counts are asserted EXACTLY, not as floors. The first version used a floor of 12
# against an actual 16, so four rows could stop matching — a reworded row, a deleted schema
# — while the gate printed the same clean line a healthy tree prints. A count that may only
# be raised deliberately is the difference between a guard and a decoration.
EXPECT_PINNED=22
EXPECT_CMDS=16
if [ "$pinned" != "$EXPECT_PINNED" ] || [ "$checked_cmds" != "$EXPECT_CMDS" ]; then
  echo "skill-shapes: enforced $pinned doc-pinned objects across $checked_cmds documented commands;"
  echo "skill-shapes: expected $EXPECT_PINNED and $EXPECT_CMDS. If that change is intended, update these"
  echo "skill-shapes: numbers in the same commit; if it is not, the join or the doc lookup broke."
  exit 1
fi

n=$(wc -l < "$tmp/problems" | tr -d ' ')
if [ "$n" -gt 0 ]; then
  echo "skill-shapes: $n payload-shape mismatch(es)"
  echo
  sort "$tmp/problems"
  exit 1
fi
echo "skill-shapes: $pinned doc-pinned objects checked for required fields, $checked_cmds table rows checked for unknown fields — all clean"
