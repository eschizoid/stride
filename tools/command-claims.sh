#!/usr/bin/env sh
# Every `stride <command>` a doc NAMES is a claim that the binary HAS it; the oracle is
# the machine-readable command table (#219, #252). Sibling of issue-claims.sh:
# fail-closed extraction, probe-must-speak assertions, own `just` recipe (needs a BUILT
# binary). ONE DIRECTION: a doc naming a nonexistent command fails; a command no doc
# mentions is a coverage question, deliberately unchecked.
#
# POSIX sh on purpose: /bin/sh here is bash 3.2 in POSIX mode, where `<(...)` is a
# syntax error yielding an EMPTY operand — two empty sides compare EQUAL, so a check can
# pass having read nothing. Temp files + trap throughout; no pipefail in POSIX, so every
# load-bearing extraction writes a file whose emptiness is asserted. No python (AGENTS.md).
set -u
# Byte-wise, so substr() offsets are byte offsets: a mid-character slice makes macOS
# awk FATAL and abandon its input, and the docs are full of em dashes. That failure is
# LOUD (the floors trip); LC_ALL=C is defence in depth.
LC_ALL=C
export LC_ALL

STRIDE="${STRIDE:-./stride}"

# Scope: everything in this repo that describes the CLI in prose. Globs are expanded by the
# shell below, so an EMPTY directory leaves the literal pattern in place and trips the
# per-file guard by name instead of silently contributing nothing.
FILES="README.md AGENTS.md docs/*.md docs/adr/*.md skills/stride/SKILL.md"

# The corpus is PINNED: under a bare "> 0", any shrink short of total silence passed
# (rule B alone is a quarter of the refs). FLOORS, not equalities — growth is somebody
# writing docs; shrink is the failure. The floors measure extractor OUTPUT and are
# structurally blind to references never counted at all — that direction is the
# extractor rules plus the UNPARSED pin below. MIN_DOCS counts docs that CONTRIBUTED;
# lower these only when a doc genuinely loses references, and say which in the commit.
MIN_REFS=79
MIN_DOCS=9

# Every `command-claims: quoting` marker, pinned so a new one is deliberate — same
# mechanism as issue-claims, but LINE-scoped (a reference is a line-level fact). A doc
# truthfully saying a command does NOT exist needs the marker or it fails on a true
# sentence. Over-applies by design (a genuine claim on an exempted line rides along);
# the pin is a COUNT, not an identity — with two or more markers one could move.
EXPECTED_QUOTING=1

# Lines that MENTION `stride <lowercase-word>` and yielded no reference — the counter
# for what the floors cannot see: a reference never counted leaves every total
# unchanged. Mostly ordinary prose, not a quality signal; what it buys is MOVING when
# the extractor stops reading a shape. Pinned EXACTLY, opposite of MIN_REFS: both
# directions deserve a look (down can mean a rule started matching prose). Inherits
# EXPECTED_QUOTING's weaknesses: a count, per-line binary.
EXPECTED_UNPARSED=51

# ------------------------------------------- the trailing-token rule, and its self-test
#
# UP HERE, above the binary check and every pin: it needs neither, and an upstream
# guard masking it left a broken rule unreported in exactly the runs most likely to
# have broken it. A function, so the self-test judges the SAME code the comparison
# loop runs. Returns 0 accept, 1 refute.
#   $1 the trailing token, $2 the command's declared arg spec (space-joined)
judge_trailing() {
  _tok="$1"
  _verdict=1
  # `set -f` because `for _a in $2` is an unquoted expansion — word splitting AND
  # PATHNAME EXPANSION. The spec is data, not a glob: `[<n>]` is a valid bracket
  # pattern over {<, n, >}, so an untracked file named `n` in the repo root turned
  # the verdict into a function of working-directory contents, in both directions.
  # The verdict moves to a variable because an early `return` would leave `-f`
  # set for the rest of the run, and `FILES` depends on globbing.
  set -f
  for _a in $2; do
    case "$_a" in "!"*) _req=1; _a="${_a#!}" ;; *) _req=0 ;; esac
    # a placeholder in a position the token can reach accepts it — its values are not
    # enumerable from the table, which is the one thing the old rule had right
    case "$_a" in *"<"*) _verdict=0; break ;; esac
    [ "$_a" = "$_tok" ] && { _verdict=0; break; }
    # ...and a REQUIRED arg the token did not match is where the walk stops: nothing after
    # it is reachable, because reaching it would mean skipping something mandatory.
    [ "$_req" = "1" ] && { _verdict=1; break; }
  done
  set +f
  return "$_verdict"
}

# ...and PROVE it can refute before trusting it: a rule that accepts everything looks
# exactly like a corpus with nothing wrong, and the real corpus reaches this rule once
# (an accept), so the refute path has no corpus coverage. Cases are COUNTED — a deleted
# case and one that never existed look identical.
selftest_fail=0
selftest_ran=0
sf() {  # description, token, spec, expected verdict (accept|refute)
  selftest_ran=$((selftest_ran + 1))
  if judge_trailing "$2" "$3"; then _got=accept; else _got=refute; fi
  [ "$_got" = "$4" ] || { echo "command-claims: SELF-TEST FAILED — $1: judged '$2' against [$3] as $_got, expected $4" >&2; selftest_fail=1; }
}
# `!` marks a REQUIRED arg, the same encoding the ARGS file carries.
sf "a required literal refutes anything else"     frobnicate "!all"                      refute
sf "a required literal accepts itself"            all        "!all"                      accept
sf "an OPTIONAL literal alone still refutes"      frobnicate "all"                       refute
# ...and the soundness a position-1 rule gets wrong: an optional literal is skippable,
# so a token may legally fill position 2 — judging position 1 alone falsely accused
# `stride week ride`, the worse failure class.
sf "an optional literal is SKIPPABLE, so a later placeholder is reachable" \
                                                  ride       "all <sport>"               accept
# ...but a REQUIRED arg stops the walk: nothing past it is reachable, because reaching it
# would mean skipping something mandatory. This is the whole gain over the list-wide rule,
# and the motivating case (`all <n>`) does NOT demonstrate it — `all` is
# optional there, so accepting is correct.
sf "a required literal blocks a placeholder behind it" \
                                                  frobnicate "!bar <n>"                  refute
sf "...however many follow it"                    frobnicate "!bar <n> <m>"              refute
# THREE tokens, because two agree under a wrong implementation (#269's bug only shows
# on a three-arg spec, and the table declares three- and four-arg commands).
sf "an optional literal FIRST, then two placeholders, is reachable at position 2" \
                                                  frobnicate "all <n> <m>"               accept
sf "a placeholder in position 1 accepts anything" frobnicate "!<metric> <limit>"         accept
# ...and a placeholder is recognised ANYWHERE in the name — starts-with passes today's
# whole table, and a bracketed-optional spelling is one naming convention away.
sf "a placeholder is recognised anywhere in the name" \
                                                  frobnicate "[<n>]"                     accept
sf "no declared args refutes anything"            frobnicate ""                          refute
# `sync` really declares `--all` (optional): non-`--all` refuted, `--all` accepted.
sf "a flag is a literal like any other"           --all      "--all"                     accept
sf "...and refutes a non-flag"                    frobnicate "--all"                     refute
if [ "$selftest_ran" != "12" ]; then
  echo "command-claims: the trailing-token self-test ran $selftest_ran cases, expected 12 — a case was deleted, and a silent one is indistinguishable from one that never existed" >&2
  exit 7
fi
if [ "$selftest_fail" != "0" ]; then
  echo "command-claims: the trailing-token rule does not judge as declared — refusing to run it against the docs" >&2
  exit 7
fi


# Trap FIRST: installed after the block, a mid-block mktemp failure leaks the ones
# already created. `rm -f ""` is a free no-op for the unset placeholders.
NAMED=; REAL=; HELP=; ARGS=; QUOTED=; UNPARSED=; SIGA=; SIGB=
trap 'rm -f "$NAMED" "$REAL" "$HELP" "$ARGS" "$QUOTED" "$UNPARSED" "$SIGA" "$SIGB"' EXIT
NAMED=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
REAL=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
HELP=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
ARGS=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
QUOTED=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
UNPARSED=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
SIGA=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
SIGB=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }

command -v jq >/dev/null 2>&1 || { echo "command-claims: jq not found — the table cannot be read, refusing to pass" >&2; exit 6; }
[ -x "$STRIDE" ] || { echo "command-claims: $STRIDE is not an executable — run \`just build\` first (the recipe depends on it); refusing to report a clean tree because the oracle was missing" >&2; exit 6; }

# ---------------------------------------------------------------- the oracle: the table
#
# Two steps, not one pipeline: no pipefail in POSIX, so a pipe reports jq's status and
# swallows a crashing binary. `--help` needs no database, so this runs anywhere.
"$STRIDE" --json --help > "$HELP" 2>/dev/null \
  || { echo "command-claims: \`$STRIDE --json --help\` failed — cannot read the command table" >&2; exit 3; }
jq -r '.data.commands[].name' < "$HELP" > "$REAL" \
  || { echo "command-claims: the help payload has no .data.commands[].name — the TABLE is broken, not the docs" >&2; exit 3; }

# The oracle's second half — what makes `week frobnicate` refutable: longest-prefix
# alone discards the leftover; the args are what judge it. One row per command, pinned
# to REAL's count below. `required` rides as a leading `!` — judge_trailing is unsound
# without it (an optional position 1 makes position 2 legally reachable).
jq -r '.data.commands[] | .name + "\t" + ([.args[]? | (if .required then "!" else "" end) + .name] | join(" "))' < "$HELP" > "$ARGS" \
  || { echo "command-claims: the help payload has no .data.commands[].args — the TABLE is broken, not the docs" >&2; exit 3; }

# --------------------------------------------------------------- the corpus: the docs
#
# Checked BEFORE awk runs: macOS awk ABORTS its remaining argument list on a missing
# file (does not skip), silently dropping every file after it at exit 0. This loop names
# the missing file; the `||` on the awk call is the backstop.
nfiles=0
for f in $FILES; do
  [ -f "$f" ] || { echo "command-claims: $f is not a readable file — refusing to scan a shrunken corpus" >&2; exit 5; }
  nfiles=$((nfiles + 1))
done

# TWO extraction rules. Rule A: an inline code span — the backtick separates a
# reference from the English word "stride". Rule B: a fenced INVOCATION line, anchored
# at line start (allowing `$ `, VAR=value, `./`) because fences also hold output; every
# `stride <cmd>` on an invocation line is extracted. Fence state resets at FNR==1.
# TWO tokens per reference — the table's widest form, asserted below. The patterns are
# STRINGS, not /…/ literals: a regex literal as a function argument evaluates to
# `$0 ~ /…/` and match() gets the pattern "0" — a SILENT zero; the floors catch it, and
# `RLENGTH < 1` covers zero-width hangs.
awk -v Q="$QUOTED" -v U="$UNPARSED" '
  function tokens(s) {
    if (match(s, /^[a-z][a-z-]*( [a-z][a-z-]*)?/)) return substr(s, RSTART, RLENGTH)
    return ""
  }
  # r/l are copies because tokens() calls match(), clobbering RSTART/RLENGTH. Dedupe
  # is HERE on the (file, line, command) triple — sort -u reorders the report, and a
  # narrower key collapses distinct commands chained on one line.
  function emit(line, pat,   rest, t, r, l, key) {
    rest = line
    while (match(rest, pat)) {
      if (RLENGTH < 1) break
      r = RSTART; l = RLENGTH
      t = tokens(substr(rest, r + l - 1))
      key = FILENAME "\t" FNR "\t" t
      # `emitted` feeds the UNPARSED counter. It counts PRINTS inside the dedupe, but a
      # fully-suppressed line cannot occur: `seen` keys on (file, line, token), so the
      # first hit on a line always prints.
      if (t != "" && !seen[key]++) { print key; emitted++ }
      rest = substr(rest, r + l)
    }
  }
  FNR==1 { fence = 0 }
  # BOTH CommonMark fence dialects — tilde fences are as valid as backtick ones, and a
  # reference inside an unrecognised fence is never counted, which no floor can see.
  # (No apostrophes in this awk program: it is one single-quoted shell string.)
  /^[[:space:]]*(```|~~~)/ { fence = 1 - fence; next }
  # The opt-out, counted in the SAME pass that applies it so the pin and the skip cannot
  # disagree about how many lines were exempted. Deliberately before the extraction rules
  # and after the fence toggle: a marked line must still move fence state, or opting one
  # line out would invert polarity for the rest of the file.
  index($0, "command-claims: quoting") { quoting++; next }
  {
    n_before = emitted
    emit($0, "`(\\./)?stride +[a-z]")
    if (fence && match($0, /^[[:space:]]*(\$[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(\.\/)?stride[[:space:]]+[a-z]/))
      emit($0, "(\\./)?stride +[a-z]")
    # SEEN BUT NOT PARSED: genuine prose and a claim in an unread shape are
    # indistinguishable here, so this is a pinned count, not a failure — it turns "the
    # extractor stopped seeing a shape" loud. New shape -> new rule; new prose -> bump.
    if (emitted == n_before && $0 ~ /stride[[:space:]]+[a-z]/) unparsed++
  }
  END { print (quoting + 0) > Q; print (unparsed + 0) > U }
' $FILES > "$NAMED" \
  || { echo "command-claims: doc extraction failed — a listed file or glob is missing" >&2; exit 5; }

# ------------------------------------------------------- the probe must be able to speak
#
# A grep that finds nothing and one that never ran look identical. Both sides are
# asserted non-empty BEFORE comparing, naming which is empty. Numeric-validated first:
# an empty operand makes `[ "" -eq 0 ]` take the ELSE branch — failing open.
nrefs=$(wc -l < "$NAMED" | tr -d ' ')
nreal=$(wc -l < "$REAL" | tr -d ' ')
case "$nrefs" in ''|*[!0-9]*) echo "command-claims: could not count the extracted references (got '$nrefs')" >&2; exit 2 ;; esac
case "$nreal" in ''|*[!0-9]*) echo "command-claims: could not count the table's commands (got '$nreal')" >&2; exit 3 ;; esac
if [ "$nrefs" -eq 0 ]; then
  echo "command-claims: extracted 0 command references from $nfiles docs — the EXTRACTOR is broken, not the docs" >&2
  exit 2
fi
if [ "$nreal" -eq 0 ]; then
  echo "command-claims: the command table is empty — the ORACLE is broken, not the docs; refusing to pass" >&2
  exit 3
fi

# ndocs = docs that CONTRIBUTED (from awk's output); nfiles never opened a file and
# cannot fall when awk aborts mid-list. Only ndocs can.
ndocs=$(cut -f1 "$NAMED" | sort -u | wc -l | tr -d ' ')
nquot=$(cat "$QUOTED" 2>/dev/null | tr -d ' ')
nunp=$(cat "$UNPARSED" 2>/dev/null | tr -d ' ')
case "$nunp" in ''|*[!0-9]*) echo "command-claims: the extractor did not report an unparsed-line count (got '$nunp') — it did not reach END, so the scan is truncated" >&2; exit 2 ;; esac
case "$ndocs" in ''|*[!0-9]*) echo "command-claims: could not count the contributing docs (got '$ndocs')" >&2; exit 2 ;; esac
case "$nquot" in ''|*[!0-9]*) echo "command-claims: the extractor did not report a quoting-marker count (got '$nquot') — it did not reach END, so the scan is truncated" >&2; exit 2 ;; esac

if [ "$nrefs" -lt "$MIN_REFS" ]; then
  echo "command-claims: $nrefs command references, floor is $MIN_REFS — the corpus SHRANK; a doc left FILES, a fence dialect changed, or the extractor stopped seeing a shape. Confirm the loss is deliberate and lower MIN_REFS." >&2
  exit 2
fi
if [ "$ndocs" -lt "$MIN_DOCS" ]; then
  echo "command-claims: references came from $ndocs docs, floor is $MIN_DOCS — the scan is reading fewer documents than it did; awk may have aborted mid-list. Confirm and lower MIN_DOCS." >&2
  exit 2
fi
if [ "$nquot" != "$EXPECTED_QUOTING" ]; then
  echo "command-claims: $nquot quoting markers, expected $EXPECTED_QUOTING — an opt-out was added or removed; confirm it is deliberate and update EXPECTED_QUOTING" >&2
  exit 4
fi
if [ "$nunp" != "$EXPECTED_UNPARSED" ]; then
  echo "command-claims: $nunp lines mention a stride command but yielded no reference, expected $EXPECTED_UNPARSED — either a doc uses a shape neither rule reads (a fence dialect, an indented block: teach the extractor) or it is new prose (bump EXPECTED_UNPARSED). \`grep -n 'stride [a-z]' \$FILES\` against the report above shows which." >&2
  exit 4
fi

# Both oracle halves must describe the same command set: "declares no args" and
# "missing from ARGS" are indistinguishable downstream and mean opposite things.
nargs=$(wc -l < "$ARGS" | tr -d ' ')
# ...and the REQUIRED MARKERS survived extraction — the self-test uses hand-written
# specs and cannot see jq stop emitting `!`, and a walk without markers never stops.
# Pinned as POSITIONS, not counts: a compensating flip holds a total, and reversing arg
# order is invisible to one. Note: no command today declares a required literal before a
# placeholder, so the walk's distinctive behaviour lives only in the self-test until one
# does.
EXPECTED_REQUIRED_SIG='activity=1
complete=1
config get=1
config set=1,2
config unset=1
event add=1,2
event remove=1
import=1
project=1
rate=1,2
relabel=1,2,3
skip=1,2
top=1
tte=1
week add=1,2,3,4'
# The three signature diffs accumulate into `sigfail` and exit once — exit-on-first
# costs a rebuild cycle per finding. The emptiness branches still exit immediately:
# with no args at all, the diffs downstream are noise.
sigfail=0
# NEWLINE-separated rows: names may contain spaces (`config get`), and `|` — which six
# arg names carry — fragmented `|`-joined rows in ways that blamed the wrong row.
reqsig=$(awk -F'\t' '{ n = split($2, a, " "); s = ""; for (i = 1; i <= n; i++) if (substr(a[i], 1, 1) == "!") s = (s == "" ? i : s "," i); if (s != "") printf "%s=%s\n", $1, s }' "$ARGS" | LC_ALL=C sort)
# Two different emptinesses: an empty SIGNATURE means "nothing required" (the likelier
# drift); an empty ARG COUNT means the .args half of the oracle is gone. Each gets its
# own sentence — the row-count guard sees neither.

nargtok=$(awk -F'\t' '{ n = split($2, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") c++ } END { print c + 0 }' "$ARGS")
case "$nargtok" in ''|*[!0-9]*) echo "command-claims: could not count the table's declared arguments (got '$nargtok')" >&2; exit 3 ;; esac
if [ "$nargtok" -eq 0 ]; then
  echo "command-claims: the derived table declares no arguments at all — the \`.args\` half of the oracle is empty, so the trailing-token rule has nothing to walk" >&2
  exit 3
fi
if [ -z "$reqsig" ]; then
  echo "command-claims: the derived table declares $nargtok arguments but marks none of them required — the walk then never stops, and every trailing token is accepted. Either the extraction dropped \`required\`, or the table genuinely made everything optional." >&2
  exit 3
fi
if [ "$reqsig" != "$EXPECTED_REQUIRED_SIG" ]; then
  echo "command-claims: required-arg signature changed." >&2
  printf '%s\n' "$EXPECTED_REQUIRED_SIG" | LC_ALL=C sort > "$SIGA"
  printf '%s\n' "$reqsig" | LC_ALL=C sort > "$SIGB"
  comm -23 "$SIGA" "$SIGB" | sed 's/^/  only in expected:  /' >&2
  comm -13 "$SIGA" "$SIGB" | sed 's/^/  only in derived:   /' >&2
  echo "command-claims: either the extraction dropped/forged \`required\` or reordered the args (the trailing-token rule silently over-accepts without the markers, and walks the wrong way without the order), or an argument genuinely changed between required and optional. Confirm each row above, then update EXPECTED_REQUIRED_SIG." >&2
  sigfail=1
fi
# ...and the PLACEHOLDER/LITERAL split survived — judge_trailing branches FIRST on
# placeholder-ness and the required signature cannot see it: all-placeholder accepts
# everything, all-literal falsely accuses. POSITIONS again (a compensating flip holds a
# count); renaming `<limit>` stays byte-identical. `/</` CONTAINS, matching the rule's
# own `*"<"*` test.
EXPECTED_PLACEHOLDER_SIG='activities=1,2
activity=1
compare=1
complete=1,2
config get=1
config set=1,2
config unset=1
event add=1,2
event remove=1
import=1
load=1
pc=1,2
power-curve=1,2
progress=1,2
project=1,2
rate=1,2
relabel=1,2,3,4
reps=1
skip=1,2,3
top=1,2,3
tte=1
week add=1,2,3,4,5'
phsig=$(awk -F'\t' '{ n = split($2, a, " "); s = ""; for (i = 1; i <= n; i++) { t = a[i]; sub(/^!/, "", t); if (t ~ /</) s = (s == "" ? i : s "," i) } if (s != "") printf "%s=%s\n", $1, s }' "$ARGS" | LC_ALL=C sort)
if [ "$phsig" != "$EXPECTED_PLACEHOLDER_SIG" ]; then
  echo "command-claims: placeholder signature changed." >&2
  printf '%s\n' "$EXPECTED_PLACEHOLDER_SIG" | LC_ALL=C sort > "$SIGA"
  printf '%s\n' "$phsig" | LC_ALL=C sort > "$SIGB"
  comm -23 "$SIGA" "$SIGB" | sed 's/^/  only in expected:  /' >&2
  comm -13 "$SIGA" "$SIGB" | sed 's/^/  only in derived:   /' >&2
  echo "command-claims: the extraction is mangling arg names, or an arg changed between placeholder and literal. That flips the rule's FIRST branch: all-placeholder accepts every trailing token, all-literal refuses every legal one. Confirm each row above against \`stride --json --help\`, then update EXPECTED_PLACEHOLDER_SIG." >&2
  sigfail=1
fi

# ...and the LITERALS still read as themselves — the rule's third property (after
# requiredness and placeholder-ness, pinned above): renaming a literal leaves both
# signatures byte-identical while changing what the rule accepts. TEXT for literals,
# never for placeholder names — the asymmetry is the rule's own. Last of the four so
# the wider failures speak first.
EXPECTED_LITERALS='sync=--all
week=all'
littext=$(awk -F'\t' '{ n = split($2, a, " "); for (i = 1; i <= n; i++) { t = a[i]; sub(/^!/, "", t); if (t !~ /</) printf "%s=%s\n", $1, t } }' "$ARGS" | LC_ALL=C sort)
if [ "$littext" != "$EXPECTED_LITERALS" ]; then
  echo "command-claims: declared literals changed." >&2
  printf '%s\n' "$EXPECTED_LITERALS" | LC_ALL=C sort > "$SIGA"
  printf '%s\n' "$littext" | LC_ALL=C sort > "$SIGB"
  comm -23 "$SIGA" "$SIGB" | sed 's/^/  only in expected:  /' >&2
  comm -13 "$SIGA" "$SIGB" | sed 's/^/  only in derived:   /' >&2
  echo "command-claims: the rule compares a trailing token against a literal's exact text, so a rename here changes which references it accepts. Confirm each row above against \`stride --json --help\`, then update EXPECTED_LITERALS." >&2
  sigfail=1
fi

if [ "$sigfail" != "0" ]; then
  echo "command-claims: refusing to judge trailing tokens against a table whose declared shape does not match the pins above." >&2
  exit 3
fi

if [ "$nargs" != "$nreal" ]; then
  echo "command-claims: the table yielded $nreal names but $nargs arg rows — the two halves of the oracle disagree; refusing to judge trailing tokens against a partial table" >&2
  exit 3
fi

# The extractor's two-token ceiling is pinned to the table rather than believed: a
# three-word form would be captured as its resolving two-word prefix and pass unchecked.
maxtok=$(awk '{ if (NF > m) m = NF } END { print m + 0 }' "$REAL")
case "$maxtok" in ''|*[!0-9]*) echo "command-claims: could not measure the table's widest form (got '$maxtok')" >&2; exit 3 ;; esac
if [ "$maxtok" -gt 2 ]; then
  echo "command-claims: the table declares a $maxtok-word command form, but the extractor captures at most 2 tokens per reference and would silently truncate — widen tokens() before landing that form" >&2
  exit 4
fi

# ----------------------------------------------------------------------- the comparison
#
# LONGEST PREFIX against the table's own names, peeling one trailing token at a time —
# then the peeled token is JUDGED, because a bare prefix pass discards the leftover and
# passes `week frobnicate`. The judgement is judge_trailing at the top of this file; do
# not restate its rule here — a restated copy went stale.

fail=0
while IFS="$(printf '\t')" read -r file line cand; do
  p="$cand"
  while [ -n "$p" ]; do
    grep -qxF -e "$p" "$REAL" && break
    case "$p" in
      *" "*) p="${p% *}" ;;
      *)     p="" ;;
    esac
  done
  if [ -z "$p" ]; then
    echo "UNKNOWN  $file:$line  \`stride $cand\` names no command the binary has"
    fail=1
    continue
  fi
  [ "$p" = "$cand" ] && continue
  x="${cand#"$p" }"
  spec=$(awk -F"$(printf '\t')" -v n="$p" '$1 == n { print $2; exit }' "$ARGS")
  # POSITIONAL (#269), meaning any position the token can REACH: list-wide
  # blanket-accepted 17 of 30 commands, position-1-only falsely accused legal
  # invocations past an optional literal. judge_trailing walks the spec and stops at
  # the first unmatched REQUIRED arg. Empty $spec = declares no args, so any trailing
  # token refutes; the row-count guard separates that from "missing from the table".
  judge_trailing "$x" "$spec" && continue
  echo "UNKNOWN  $file:$line  \`stride $cand\` — \`$p\` is a command, but it takes no \`$x\`"
  fail=1
done < "$NAMED"

# "$ndocs of $nfiles": stat'd vs contributed — reporting only the larger implies a
# coverage the run never measured.
[ "$fail" = "0" ] && echo "command-claims: $nrefs command references across $ndocs of $nfiles docs, resolved against $nreal commands in the table — all name real commands"
exit $fail
