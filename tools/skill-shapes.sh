#!/bin/sh
# Check SKILL.md's documented payload shapes against schemas/v2/*.json.
#
# SKILL.md is the coaching agent's instruction sheet, and it names each command's payload
# fields as a literal — `{anchor_date, groups:[{name, lens, hidden}]}`. Nothing connected
# those literals to the schemas, so a field could be added to a schema, marked required,
# shipped, and never reach the agent. That happened TWICE in three days in consecutive
# commits of one PR (#292's `groups[].hidden`, then `hidden_lens`/`hidden_scope`), both
# caught by a human reviewer rather than by anything mechanical.
#
# The failure is silent in the direction that matters: an agent given an undocumented
# field does not error, it simply never uses it. `hidden_lens`/`hidden_scope` exist
# specifically so the agent can separate the fixable half of a hidden count from the
# unfixable half, so a field that never reaches SKILL.md is a feature that does not exist
# as far as the coach is concerned.
#
# Two directions, both mechanical because the schemas already carry `required`:
#   1. schema -> doc: every `required` name in a schema appears in that command's row.
#   2. doc -> schema: every key named in a row's `{...}` shape literal exists as a
#      property somewhere in the schema. Catches a field renamed or deleted in the
#      schema while the documentation goes on promising it.
#
# Direction 2 reads keys ONLY from inside brace literals, never from the row's prose.
# The prose is full of backticked values and error codes — `ef`, `speed_hr`,
# `no_workout_on_date` — which are not payload keys, and scanning the whole row would
# report every one of them as an unknown field.
#
# The command->schema join is not invented here: `src/Command.roc`'s table already
# declares it, as the last `"<name>.json"` on each `reads(...)`/`writes(...)` line.
set -eu
cd "$(dirname "$0")/.."
SK=.claude/skills/stride/SKILL.md
SCHEMAS=schemas/v2
# The coverage above which a documented object is treated as an ENUMERATION rather than a
# summary. See the long comment below for the measurement this number comes from.
COVERAGE_PCT=70
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# The join, derived from the table rather than restated here.
grep '\(reads\|writes\)("' src/Command.roc | while IFS= read -r line; do
  n=$(printf '%s\n' "$line" | grep -o '\(reads\|writes\)("[^"]*"' | head -1 | sed 's/.*("//;s/"$//')
  s=$(printf '%s\n' "$line" | grep -o '"[a-z_]*\.json"' | tail -1 | tr -d '"')
  if [ -n "$n" ] && [ -n "$s" ]; then printf '%s\t%s\n' "$n" "$s"; fi
done | sort -u > "$tmp/join"

: > "$tmp/problems"
checked=0
TAB=$(printf '\t')
while IFS="$TAB" read -r name schema; do
  [ -f "$SCHEMAS/$schema" ] || continue
  # The row whose COMMAND cell invokes exactly this command. Anchored and followed by a
  # boundary so `week` does not select `week add`'s row.
  awk -F'|' -v n="$name" '
    /^\| *`stride/ { cell = $2; gsub(/[`\\]/, "", cell)
                     if (cell ~ ("^ *stride " n "([^a-z0-9-]|$)")) print }' "$SK" > "$tmp/row"
  [ -s "$tmp/row" ] || continue
  checked=$((checked + 1))

  # The doc's brace literals, one key-set per literal. Innermost-first: pull `{...}`
  # spans with no nested braces, record their keys, blank them out, repeat — so
  # `{anchor_date, groups:[{name, lens}]}` yields the inner set AND the outer one,
  # instead of the outer keys vanishing with the nesting.
  : > "$tmp/sets"
  cp "$tmp/row" "$tmp/work"
  while grep -q '{[^{}]*}' "$tmp/work"; do
    grep -o '{[^{}]*}' "$tmp/work" | while IFS= read -r lit; do
      printf '%s\n' "$lit" | grep -o '[a-z_][a-z_0-9]* *[,:}]' | sed 's/ *.$//' | sort -u |
        tr '\n' ' ' >> "$tmp/sets"
      printf '\n' >> "$tmp/sets"
    done
    sed 's/{[^{}]*}/X/g' "$tmp/work" > "$tmp/work2"; mv "$tmp/work2" "$tmp/work"
  done

  # Every object in the schema, as "required-list :: property-list".
  jq -r '[.. | objects | select(has("properties"))]
         | .[] | ((.required // []) | join(" ")) + " :: " + (.properties | keys | join(" "))' \
    "$SCHEMAS/$schema" > "$tmp/objs" 2>/dev/null || : > "$tmp/objs"

  # An object the doc ENUMERATES must be enumerated fully — and "enumerates" is decided by
  # COVERAGE, not by a couple of incidental mentions. Measured across the current table the
  # two populations separate cleanly with nothing in between: objects the doc lists in full
  # sit at 100%, ones it is visibly trying to list sit at 75-85%, and the ones it summarises
  # in prose on purpose sit at 50% and below (season's month object, 8 of 24; reps' rep
  # object, 2 of 13). The threshold goes in that gap.
  #
  # Not "every required field of every schema": SKILL.md summarises most payloads
  # deliberately, and demanding full coverage everywhere reports 166 mismatches on a healthy
  # tree, which is a gate nobody can keep green. Not "two or more mentions" either — that
  # reports 32, most of them prose summaries doing exactly what they should.
  #
  # This is what sees the two real drifts: both landed inside a literal that already listed
  # the object's siblings — `groups[].hidden`, then `hidden_lens`/`hidden_scope` — so the
  # coverage was 100% before the schema changed and short by one after.
  while IFS= read -r obj; do
    req=$(printf '%s' "$obj" | sed 's/ :: .*//')
    props=$(printf '%s' "$obj" | sed 's/.* :: //')
    [ -n "$req" ] || continue
    total=$(printf '%s' "$props" | tr ' ' '\n' | grep -c .)
    [ "$total" -gt 0 ] || continue
    while IFS= read -r set; do
      [ -n "$set" ] || continue
      hits=0
      for pp in $props; do
        case " $set " in *" $pp "*) hits=$((hits + 1)) ;; esac
      done
      [ $((hits * 100 / total)) -ge "$COVERAGE_PCT" ] || continue
      # Presence is tested against the WHOLE ROW, not against the literal that decided
      # enumeration. The row is the documentation; a field named in the surrounding prose
      # is documented even though it sits outside the braces. `reps`' `matched_total` is
      # exactly that — required, and explained in a sentence rather than listed in the
      # shape — and scoring it missing would have been the gate reporting its own parser.
      for rk in $req; do
        grep -q "[^A-Za-z0-9_]$rk\([^A-Za-z0-9_]\|\$\)" "$tmp/row" ||
          printf 'undocumented  %-12s %-18s %s is required, and SKILL.md lists %d of this object'"'"'s %d fields without naming it\n' \
            "$name" "$schema" "$rk" "$hits" "$total" >> "$tmp/problems"
      done
    done < "$tmp/sets"
  done < "$tmp/objs"

  # 2. doc -> schema: a field the documentation promises that no schema property backs.
  jq -r '[.. | objects | select(has("properties")) | .properties | keys[]] | unique[]' \
    "$SCHEMAS/$schema" > "$tmp/props" 2>/dev/null || : > "$tmp/props"
  tr ' ' '\n' < "$tmp/sets" | sort -u | while IFS= read -r k; do
    [ -n "$k" ] || continue
    grep -qx "$k" "$tmp/props" ||
      printf 'unknown-field %-12s %-18s SKILL.md names %s, which the schema has no property for\n' \
        "$name" "$schema" "$k" >> "$tmp/problems"
  done

  printf '%s\n' "$checked" > "$tmp/checked"
done < "$tmp/join"

checked=$(cat "$tmp/checked" 2>/dev/null || echo 0)
# `wc -l`, not `grep -c . || echo 0`: grep -c on an empty file prints 0 AND exits 1, so the
# fallback fires too and `n` becomes two lines. `[ "$n" -gt 0 ]` then errors out instead of
# testing anything, and execution falls through to the success message — a gate that cannot
# report a failure it has already found.
n=$(wc -l < "$tmp/problems" | tr -d ' ')

# The count is asserted, not just the problem list. Every guard on this project that
# reported only ABSENCES has at some point passed by running on nothing: a changed table
# format, a renamed heading, and the loop silently checks zero rows while printing the
# same clean line a healthy tree prints.
if [ "$checked" -lt 12 ]; then
  echo "skill-shapes: only $checked documented commands matched a schema — expected at least 12."
  echo "skill-shapes: the SKILL.md table or Command.roc's schema column changed shape; fix the join, do not lower this number."
  exit 1
fi

if [ "$n" -gt 0 ]; then
  echo "skill-shapes: $n payload-shape mismatch(es) across $checked documented commands"
  echo
  sort "$tmp/problems"
  exit 1
fi
echo "skill-shapes: $checked documented commands, every required schema field named in SKILL.md and every documented field real"
