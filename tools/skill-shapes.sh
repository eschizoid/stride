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
#     command table. Exactly what that reaches in each direction is stated below, beside the
#     fold that decides it — an earlier version also claimed it HERE, in words the fold then
#     made wrong, and the two sentences sat twenty lines apart contradicting each other.
#
# ── The two directions ──
#
#   1. schema -> doc: for every object pinned `doc`, each of its required fields must be
#      named somewhere in that command's documentation.
#   2. doc -> schema: every key inside a `{...}` literal must exist as a schema property.
#      Catches documentation still promising a field that was renamed or removed.
set -eu
# Byte collation, everywhere. Every comparison in this script runs through `sort`, and the
# pin file is a checked-in artifact compared line by line against a freshly sorted one — so
# a locale that orders differently makes the SAME content disagree with itself. Windows CI
# caught exactly that: every line reported as both pinned and actual, identical text, because
# Git Bash sorted it differently from the macOS run that generated the pin.
export LC_ALL=C
cd "$(dirname "$0")/.."
SK=.claude/skills/stride/SKILL.md
SCHEMAS=schemas/v2
PINS=tools/skill-shapes.pins
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# SKILL.md with hard-wrapped paragraph lines folded together. Markdown wraps prose, and the
# payload literals for `sync` and `analyze` are split across two source lines, so a
# line-scoped extractor finds ZERO complete `{...}` spans there.
#
# What this buys, precisely, because two earlier versions got it wrong in opposite ways:
#
# Direction 2 reaches all three prose literals — `sync`'s, `analyze`'s, and `config unset`'s,
# which has no table row at all. Renaming a field in any of them is reported.
#
# Direction 1 reaches `sync` but NOT `analyze`, and that asymmetry is an accident of the
# prose rather than a design. The fold merges the paragraph running from `stride sync`
# through the `{synced, …}` literal, so `sync` flags `doc`; `stride analyze` appears three
# times and never in the paragraph holding its own literal, so it stays `-`. Its required
# set is still pinned, so a schema change to it fails the gate — what is missing for
# `analyze` alone is the check that SKILL.md names each new field, and closing it needs a
# way to attribute prose that does not depend on where a paragraph break happens to fall.
#
# That accident has a cost worth naming rather than discovering later: a folded paragraph is
# a large haystack, and a required field with a common name can be satisfied by text about a
# different command. Review swept all 27 doc-pinned objects, deleting each required field
# from every literal while leaving prose alone, and found six such coincidences — `value`
# standing on "as `sync`'s `stopped` value it means…", `points` on "1 by construction at two
# points", `month` on "belongs to a month and to no block", and three more of the same shape.
#
# Recorded rather than closed, and the reason is measured rather than aesthetic: each is a
# SECOND line of defence failing. The field is still named in a literal today, and the pin
# fails unconditionally on any schema change whatever the prose says — so the drift #298 is
# actually about, a field added and never documented, is caught regardless. Closing this
# needs prose-to-command attribution, the same missing capability that leaves `analyze` at
# `-`, and inventing a heuristic for it is what produced twelve false reports last time.
#
# Two cases do NOT shelter under that, because they are placeholders rather than prose:
# `config.json` and `config_unset.json` each rest a required `key` on the inline
# `stride config get <key> --json` written in a sentence. The cell strip is anchored at `^|`
# so it never sees an inline invocation, and stripping arbitrary ones is a much broader
# change than a table cell. Named here so the limitation is not mistaken for the prose one.
LOGICAL="$tmp/logical.md"
awk '
  function isnew(l) {
    # A line STARTS a new logical line when it is blank, a heading, a table row, a fence,
    # or a list bullet. Everything else continues the paragraph above it — which is what
    # Markdown means by a hard wrap, and the condition an earlier version got wrong by
    # requiring leading whitespace. `sync`s literal wraps onto a column-0 line, so that
    # version never joined it and both directions stayed blind while looking covered.
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
  grep -F "stride $cmd" "$LOGICAL" 2>/dev/null > "$tmp/cand" || true
  # A line naming a LONGER command documents THAT command, not this one. `week add`'s row
  # is not `week`'s. Derived from the join rather than guessed at with a character class:
  # the first cut used an awk boundary of `([^a-z0-9-]|$)`, which contains a space, so
  # `week` claimed its neighbour's row and could be satisfied by its neighbour's text.
  cut -f1 "$tmp/join" | grep "^$cmd " > "$tmp/longer" || true
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    # NOT `grep -vF ... && mv ...`: when the filter matches every line grep exits 1, the
    # `mv` never runs, and `cand` silently keeps the UNFILTERED text. That is live for
    # `config`, whose four lines all name a longer form. Redirect first, move always.
    grep -vF "stride $l" "$tmp/cand" > "$tmp/cand2" || true
    mv "$tmp/cand2" "$tmp/cand"
  done < "$tmp/longer"
  # The invocation cell is stripped before the text is searched. It holds argument
  # PLACEHOLDERS — `[date]`, `[sport]`, `<id>`, `[n]`, `[days]` — and leaving them in lets
  # a CLI argument silently satisfy a payload field of the same name. Measured: moving `km`
  # into `stats`' invocation cell makes a required `km` pass with the schema untouched.
  # `[^|]*` after the closing backtick, not ` *`. Two table rows carry `(alias `pc`)` between
  # the invocation and the next pipe, so the anchored form matched nothing and the ENTIRE row
  # survived — placeholders included. That is round-1's placeholder finding alive again
  # inside the mechanism added to close it, and it only surfaced once the alias union
  # enrolled those two rows. Measured: deleting `sport` from `power-curve`'s literal passed,
  # while neutralising the `[sport]` placeholder as a control failed.
  #
  # Two limits, both recorded because this strip's whole job is to have known ones.
  #
  # An inline invocation in PROSE — `stride config get <key> --json` — is a different route
  # to the same place and is NOT fixed here: this is anchored at `^|`, so it never sees one.
  # `config.json` and `config_unset.json` both rest a required `key` on that `<key>`.
  #
  # And the anchor means the strip can stop applying to a row ENTIRELY. Reword the cell to
  # `| run \`stride power-curve …` and it matches nothing, the row survives whole, and the
  # placeholder hole reopens for that row — measured. Nothing guards row SHAPE any more:
  # that was `checked_cmds`, correctly retired when direction 2 stopped attributing. It
  # takes a reformat AND a field deleted from a literal while its placeholder remains, and
  # the pin still fails unconditionally on any schema change either way — so this is a
  # second line of defence that can go quiet, not a hole in the first.
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
  awk -F'\t' '$4=="doc" {print $1"  "$2}' "$PINS" | sort > "$tmp/was_doc"
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
done < "$PINS"

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
    "$f" 2>/dev/null >> "$tmp/objprops" || true
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
# Both counts are asserted EXACTLY, not as floors. The first version used a floor of 12
# against an actual 16, so four rows could stop matching — a reworded row, a deleted schema
# — while the gate printed the same clean line a healthy tree prints. A count that may only
# be raised deliberately is the difference between a guard and a decoration.
EXPECT_PINNED=27
EXPECT_LITERALS=25
if [ "$pinned" != "$EXPECT_PINNED" ] || [ "$literals" != "$EXPECT_LITERALS" ]; then
  echo "skill-shapes: enforced $pinned doc-pinned objects and matched $literals brace literals;"
  echo "skill-shapes: expected $EXPECT_PINNED and $EXPECT_LITERALS. If intended, update these"
  echo "skill-shapes: numbers in the same commit; if it is not, the join or the doc lookup broke."
  exit 1
fi

echo "skill-shapes: $pinned doc-pinned objects checked for required fields, $literals brace literals matched to schema objects — all clean"
