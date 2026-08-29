#!/usr/bin/env sh
# Every `stride <command>` a doc NAMES is a claim that the binary HAS it, and
# nothing checked it: #219 made the command table machine-readable precisely so
# claims about the CLI could be checked rather than trusted, and prose in files
# the binary never reads was the half with no oracle (#252).
#
# Sibling of tools/issue-claims.sh, deliberately shaped like it: fail-closed
# extraction, "the probe must be able to speak" assertions, its own `just`
# recipe (this one needs a BUILT BINARY to ask).
#
# ONE DIRECTION ONLY: a doc naming a nonexistent command is a correctness bug
# and fails here; a command no doc mentions is a COVERAGE question and is
# deliberately not checked.
#
# POSIX sh, run as `sh` on purpose: /bin/sh on macOS is bash 3.2 in POSIX mode,
# where `<(...)` is a syntax error yielding an EMPTY operand — and two empty
# sides compare EQUAL, so a check can pass having read nothing (the e2e
# command-table pins were written that way and had never executed a single
# comparison). Temp files and a trap throughout; `set -o pipefail` is not
# POSIX either, which is why every load-bearing extraction writes to a file
# whose emptiness is then asserted.
#
# No python: AGENTS.md rules it out project-wide. Shell + jq.
set -u
# Byte-wise, so substr() offsets are byte offsets: a slice landing
# mid-character makes macOS awk FATAL ("towc: multibyte conversion failure")
# and ABANDON the rest of its input — the docs are full of em dashes, so a
# wrong offset finds one immediately. Verified both ways: with the advance bug
# beside emit() reintroduced, the same code exits 0 under LC_ALL=C and dies at
# exit 2 under en_US.UTF-8 having read only part of its input; with it fixed,
# both locales agree at 79.
# Note the direction: this failure is LOUD (awk exits 2, the `||` makes exit 5,
# and a truncated corpus trips the floors). It is the SILENT zero from the
# regex-literal bug that needed guarding; LC_ALL=C is defence in depth.
LC_ALL=C
export LC_ALL

STRIDE="${STRIDE:-./stride}"

# Scope: everything in this repo that describes the CLI in prose. Globs are expanded by the
# shell below, so an EMPTY directory leaves the literal pattern in place and trips the
# per-file guard by name instead of silently contributing nothing.
FILES="README.md AGENTS.md docs/*.md docs/adr/*.md skills/stride/SKILL.md"

# The corpus is PINNED, not merely reported: the only quantitative assertion
# used to be "> 0", so any shrink short of total silence passed. Rule B
# contributes 19 of the 79 (measured by disabling it), so a fence dialect or a
# parity flip could remove a quarter of the corpus under a clean-reading run.
#
# THE FLOORS CANNOT SEE THE OTHER BLIND SPOT: they measure the extractor's
# OUTPUT, so they are structurally blind to references never counted at all —
# `stride frobnicate` in a `~~~` fence or a four-space indented block held the
# total at its pinned value and exited 0. No floor can reach that; the fix had
# to be in the EXTRACTOR (the tilde fence is a recognised dialect below, and
# UNPARSED counts what neither rule could read).
#
# FLOORS, not equalities: growth is somebody writing docs and must not fail;
# shrink is the failure being guarded. (issue-claims pins its marker count
# EXACTLY for the opposite reason — a suppression is deliberate both ways.)
# MIN_DOCS counts docs that CONTRIBUTED a reference, not docs stat'd — `nfiles`
# never opens a file, so it reads 18 regardless. Lower these only when a doc
# genuinely loses references, and say which in the commit message.
MIN_REFS=79
MIN_DOCS=9

# Every `command-claims: quoting` marker in the corpus, pinned so a new one is
# deliberate — same mechanism and pin as issue-claims. A doc that says a command
# does NOT exist otherwise fails on a TRUE sentence ("there is no `stride
# backfill` command"), and the only way out without a marker is stripping the
# backticks — degrading the doc to satisfy the linter.
#
# LINE-scoped, unlike issue-claims' block scope: a reference is a line-level
# fact. Counts LINES where issue-claims counts OCCURRENCES — the unit IS the
# line, so "how many lines are exempt" is what the pin should hold.
#
# AGENTS.md carries the one exempted line, which deliberately names a fake
# command — documenting the escape hatch is what exercises it (verified by
# deleting the `next` and watching it report). IT OVER-APPLIES by design: a
# genuine claim added to an exempted line is exempted with it, and no narrower
# unit exists without the natural-language wall issue-claims hit. The cost is
# held down by the pin, by `grep -rn 'command-claims: quoting'`, and by keeping
# marked lines short. The pin is a COUNT, not an identity — with two or more
# markers one could move; latent today with exactly one.
EXPECTED_QUOTING=1

# Lines that MENTION `stride <lowercase-word>` and yielded no reference — the
# counter for the direction the floors cannot see: they measure what was
# counted, so a reference never counted at all leaves the total unchanged
# (`stride frobnicate` passed inside a `~~~` fence and a four-space indented
# block — the one outcome this file's header promises to prevent).
#
# Most of the count is ordinary prose ("stride refuses", "stride answers") and
# none of it is a defect; the number is not a quality signal. What it buys is
# that it MOVES when the extractor stops reading a shape. Pinned EXACTLY, not
# floored — the opposite choice from MIN_REFS on purpose: this is a description
# of the corpus and both directions deserve a look (down can mean a rule
# started matching prose). It inherits both weaknesses recorded beside
# EXPECTED_QUOTING: a COUNT (compensating changes hold it) and PER-LINE binary.
#
# The `~~~` dialect widened the fence-parity surface — a prose line beginning
# `~~~` flips polarity — and that risk lands on this pin (measured: such a line
# exits 4). The first run of this counter found a COMMENTED-OUT invocation in a
# README fence that nothing was checking; the fix went in the DOC (backticked,
# matching its neighbour), because inside a fence an explanatory comment and a
# commented invocation are both `#` plus text.
EXPECTED_UNPARSED=47

# ------------------------------------------- the trailing-token rule, and its self-test
#
# UP HERE, above the binary check and every pin, because it needs neither and
# everything that used to precede it could mask it (an exit-3 guard upstream
# meant a broken rule went unreported in exactly the runs most likely to have
# broken it). As a function, so the self-test judges the SAME code the
# comparison loop runs. Returns 0 to accept the trailing token, 1 to refute.
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

# ...and PROVE it can refute, before trusting it on the real corpus: every other
# guard asserts its INPUTS are non-empty, and a rule that accepts everything
# looks exactly like a corpus with nothing wrong. The real corpus reaches this
# rule EXACTLY ONCE (`week all`, an accept), so the refute path has no corpus
# coverage at all. COUNTED, because a silent `sf` line and one that never
# existed look identical — reverting the rule AND deleting the case that pins
# it ran green, a complete revert undetected.
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
# ...and the soundness the position-1 rule got wrong. `week`'s `all` is optional, so a token
# may legally fill position 2 by skipping it. Judging position 1 alone refused
# `stride week ride` against `week [all] [<sport>]` — a false accusation, which this file
# treats as the worse failure: the only way out of one without a marker is to degrade the
# doc until the linter is satisfied.
sf "an optional literal is SKIPPABLE, so a later placeholder is reachable" \
                                                  ride       "all <sport>"               accept
# ...but a REQUIRED arg stops the walk: nothing past it is reachable, because reaching it
# would mean skipping something mandatory. This is the whole gain over the list-wide rule,
# and the motivating case (`all <n>`) does NOT demonstrate it — `all` is
# optional there, so accepting is correct.
sf "a required literal blocks a placeholder behind it" \
                                                  frobnicate "!bar <n>"                  refute
sf "...however many follow it"                    frobnicate "!bar <n> <m>"              refute
# THREE tokens, because two agree under a wrong implementation. Measured: `${2% *}` — all
# tokens but the last — passes every two-token case with a byte-identical verdict
# signature, passes the corpus, and IS #269's bug on a three-arg spec. The table already
# declares three- and four-arg commands (`top`, `skip`, `week add`).
sf "an optional literal FIRST, then two placeholders, is reachable at position 2" \
                                                  frobnicate "all <n> <m>"               accept
sf "a placeholder in position 1 accepts anything" frobnicate "!<metric> <limit>"         accept
# ...and a placeholder is recognised ANYWHERE in the arg name, not only at its start. Every
# name in today's table opens with `<`, so `case $_a in "<"*)` — starts-with — passes every
# other case here and the whole corpus. A bracketed-optional spelling is the shape that
# distinguishes them, and it is one naming convention away.
sf "a placeholder is recognised anywhere in the name" \
                                                  frobnicate "[<n>]"                     accept
sf "no declared args refutes anything"            frobnicate ""                          refute
# `sync` really declares `--all`, and it is required: false — so a token that is not `--all`
# must be refuted, and `--all` itself accepted.
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


# The trap goes up FIRST, before any of them exist. Installed after the block, a failure on
# the second or third mktemp leaks the ones already created — `exit 6` runs with no trap
# armed. `rm -f ""` is a silent no-op (exit 0), so the unset placeholders cost nothing.
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
# Two steps, not one pipeline. Under POSIX sh there is no pipefail, so
# `./stride --json --help | jq ... > "$REAL"` would report jq's status and swallow a binary
# that printed a stack trace. `--help` needs no database, which is why this is safe to run
# anywhere and why it can never be skipped.
"$STRIDE" --json --help > "$HELP" 2>/dev/null \
  || { echo "command-claims: \`$STRIDE --json --help\` failed — cannot read the command table" >&2; exit 3; }
jq -r '.data.commands[].name' < "$HELP" > "$REAL" \
  || { echo "command-claims: the help payload has no .data.commands[].name — the TABLE is broken, not the docs" >&2; exit 3; }

# The SECOND half of the oracle — why `stride week frobnicate` is refutable at
# all: longest-prefix alone resolves at `week` and discards the leftover. The
# table carries what distinguishes them (`week` declares literal `all`, `top`
# declares `<hr|…>`, `analyze` declares nothing). Flags never reach here —
# tokens() captures `[a-z]`, so a leading `-` is not a token.
# One line per command, pinned to REAL's line count so the two halves cannot
# disagree about which commands exist. `required` is carried as a leading `!`
# because `judge_trailing` is unsound without it: a token may legally fill
# position 2 when position 1 is OPTIONAL (`week [all] [<sport>]`), and dropping
# the flag falsely accused a legal invocation.
jq -r '.data.commands[] | .name + "\t" + ([.args[]? | (if .required then "!" else "" end) + .name] | join(" "))' < "$HELP" > "$ARGS" \
  || { echo "command-claims: the help payload has no .data.commands[].args — the TABLE is broken, not the docs" >&2; exit 3; }

# --------------------------------------------------------------- the corpus: the docs
#
# Checked BEFORE awk runs, because macOS awk ABORTS the rest of its argument list on a
# missing file rather than skipping it: one absent entry silently drops every file listed
# after it, and the run still prints a clean summary. issue-claims measured what that costs
# there — 2085 blocks down to 1631, 22% of the corpus, exit 0. This loop names the missing
# file; the `||` on the awk invocation is the backstop for the same class.
nfiles=0
for f in $FILES; do
  [ -f "$f" ] || { echo "command-claims: $f is not a readable file — refusing to scan a shrunken corpus" >&2; exit 5; }
  nfiles=$((nfiles + 1))
done

# TWO extraction rules — the difference is the whole reason this is awk.
#
# Rule A — an inline code span: `` `stride <cmd>` ``. The BACKTICK separates a
# command reference from the English word "stride" (an unanchored sweep yields
# `stride is`, `stride refuses` and thirty more verbs).
# Rule B — a fenced INVOCATION line, anchored at line start (allowing `$ `,
# leading VAR=value, `./`), because fences also hold banner OUTPUT and a curl
# download that are not invocations. Once a line is an invocation, every
# `stride <cmd>` ON it is extracted (the daily-loop line chains three).
# fence state resets at FNR==1, or a file ending inside an unclosed fence marks
# the next file's whole text fenced.
#
# TWO tokens per reference, matching the widest form the table declares —
# asserted against the table below, so a three-word form fails loudly.
#
# The two patterns are STRINGS, not `/…/` literals: a regex literal passed as a
# function argument evaluates to `$0 ~ /…/`, so `pat` arrives as 0 or 1 and
# match() is handed the one-character pattern "0". The failure is a SILENT
# ZERO, which the floor guards below catch; the `RLENGTH < 1` bail covers the
# general zero-width-match hang.
awk -v Q="$QUOTED" -v U="$UNPARSED" '
  function tokens(s) {
    if (match(s, /^[a-z][a-z-]*( [a-z][a-z-]*)?/)) return substr(s, RSTART, RLENGTH)
    return ""
  }
  # r and l are copies, and must be: tokens() calls match(), which CLOBBERS the
  # RSTART/RLENGTH this loop advances on — reading them back advanced by the
  # TOKEN match and re-scanned the same span (263 emissions from one line), which
  # a downstream dedupe hid perfectly. Dedupe is HERE, on the (file, line,
  # command) triple, not `sort -u`: sorting reorders the report (:10 above :7),
  # and key-dedupe would collapse three distinct commands chained on one README
  # line.
  function emit(line, pat,   rest, t, r, l, key) {
    rest = line
    while (match(rest, pat)) {
      if (RLENGTH < 1) break
      r = RSTART; l = RLENGTH
      t = tokens(substr(rest, r + l - 1))
      key = FILENAME "\t" FNR "\t" t
      # `emitted` is what the UNPARSED counter below reads to tell "this line yielded a
      # reference" from "this line mentioned stride and yielded nothing". It counts PRINTS,
      # inside the dedupe, so in principle a line whose every hit was suppressed would count
      # as unparsed. That case cannot occur: `seen` keys on FILENAME, FNR and the token,
      # so the first hit of any token on a line is always new and always prints.
      if (t != "" && !seen[key]++) { print key; emitted++ }
      rest = substr(rest, r + l)
    }
  }
  FNR==1 { fence = 0 }
  # BOTH CommonMark fence dialects. Backticks only was not a simplification, it was a hole:
  # `~~~` is as valid as ``` and the spec treats them identically, so `stride frobnicate`
  # inside a tilde fence was never extracted and the run reported a clean tree — the exact
  # outcome the header of this file promises it prevents (no apostrophes in here: the awk
  # program is one single-quoted shell string, and one of those ends it mid-comment). The
  # floors above cannot reach this case at all, because they
  # measure what was counted, and this was never counted.
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
    # SEEN BUT NOT PARSED. A line that mentions `stride <lowercase-word>` and yielded no
    # reference is either genuine prose ("stride refuses", "stride already knows") or a
    # claim in a shape neither rule reads — an unknown fence dialect, an indented code
    # block, a form nobody has thought of yet. The two are indistinguishable HERE, which is
    # why this is a pinned count rather than a failure: it turns "the extractor stopped
    # seeing a shape" from invisible into loud, in the one direction the floors cannot
    # cover. When it moves, read the diff — a new shape needs a rule, new prose needs the
    # pin bumped.
    if (emitted == n_before && $0 ~ /stride[[:space:]]+[a-z]/) unparsed++
  }
  END { print (quoting + 0) > Q; print (unparsed + 0) > U }
' $FILES > "$NAMED" \
  || { echo "command-claims: doc extraction failed — a listed file or glob is missing" >&2; exit 5; }

# ------------------------------------------------------- the probe must be able to speak
#
# A grep that finds nothing and a grep that never ran look identical, and this
# repo's most repeated defect is a check that passed measuring nothing. Both
# sides are asserted non-empty BEFORE the comparison, naming WHICH is empty:
# an empty docs side is a broken extractor, an empty table side a broken oracle.
# Numeric-validated first: on this /bin/sh an empty operand makes `[ "" -eq 0 ]`
# take the ELSE branch — failing OPEN, the exact shape it exists to catch.
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

# ndocs is the docs that CONTRIBUTED, counted from what awk emitted. nfiles above is counted
# by a shell loop that never opened a file, so it says 18 whether the scan read eighteen
# documents or one. Only this number falls to zero when awk aborts mid-list.
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

# The two halves of the oracle must describe the same command set. Nothing downstream can
# tell "this command declares no args" from "this command is missing from ARGS", and those
# have opposite meanings: the first REFUTES a trailing token, the second would refute every
# one of them. A jq shape change that empties one half and not the other lands here.
nargs=$(wc -l < "$ARGS" | tr -d ' ')
# ...and the REQUIRED MARKERS survived the extraction, COUNTED rather than
# sampled: `judge_trailing`'s self-test uses hand-written specs, so it cannot
# see the jq stop emitting `!` — and a walk without markers never stops and
# over-accepts. A one-position anchor was blind to two measured extraction
# mutants (every arg required: 33 markers; only first-of-each: 10).
#
# Pin the DERIVATION, not its sum: a bare total let a compensating flip (`all`
# to required +1, `<watts>` to optional -1) run green past a guard promising to
# catch exactly that. POSITIONS and not counts, because order is the walk's
# whole premise: reversing the arg order was a green one-line survivor under a
# total (`complete` goes 1 -> 2, `skip` 1,2 -> 2,3 under positions).
#
# When this moves: NO command today declares a literal at position 1 followed by
# anything (only `sync --all` and `week all` have literals, one each), so the
# walk's distinctive behaviour — a required literal blocking a placeholder —
# has zero table instances and lives only in the self-test. The day someone
# adds such a command is the day these rows move and the rule does real work.
EXPECTED_REQUIRED_SIG='activity=1
complete=1
config get=1
config set=1,2
config unset=1
import=1
rate=1,2
relabel=1,2,3
skip=1,2
top=1
tte=1
week add=1,2,3,4'
# The three SIGNATURE diffs accumulate into `sigfail` and exit once at the end:
# each early exit costs a full rebuild-and-run cycle to reach the next finding,
# and a new command with a required literal + placeholder cost THREE round trips
# under exit-on-first. One run now names every constant needing update. The two
# EMPTINESS branches still exit immediately, and should: with no arguments at
# all, the signature diffs downstream are noise.
sigfail=0
# NEWLINE-separated, one row per line. Not space-joined (a command NAME may
# contain a space: `config get`); not `|`-joined, which fragmented rows two
# measured ways — a `|` in a name garbled the LITERALS diff upstream of its own
# guard, and a `|` inside a literal split into a row that MATCHED expected and
# was silently consumed, leaving a diff blaming the wrong row. A newline in a
# name would already break every one-row-per-line file and `wc -l` here, an
# invariant load-bearing everywhere else; `|` is a character six arg names
# carry today.
reqsig=$(awk -F'\t' '{ n = split($2, a, " "); s = ""; for (i = 1; i <= n; i++) if (substr(a[i], 1, 1) == "!") s = (s == "" ? i : s "," i); if (s != "") printf "%s=%s\n", $1, s }' "$ARGS" | LC_ALL=C sort)
# Two different emptinesses, and the general message is false of both. An empty SIGNATURE
# means "no REQUIRED args", which is the likelier drift; an empty ARG COUNT means the
# `.args` half of the oracle is gone entirely. `nargs != nreal` sees neither, because all
# the rows still exist either way. Gate on the token count first so each gets its own
# sentence — review reproduced the misdiagnosis by declaring every arg optional, on a table
# where `top` plainly still declared three.

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
# ...and the PLACEHOLDER/LITERAL split survived, which the signature above
# cannot see: `judge_trailing` branches FIRST on placeholder-ness, and nothing
# pinned it. Two measured one-line survivors, both leaving the required
# signature byte-identical: mapping every arg to `<x>` accepts everything
# (`stride week frobnicate` passes — the bug this file exists to catch);
# stripping the angle brackets falsely accuses `stride top hr`.
#
# POSITIONS, not a count: a compensating flip (literal->placeholder +1,
# placeholder->literal -1) holds a count, and `all` -> `all<n>` is invisible to
# a starts-with count with no compensation at all. A position signature records
# which SLOTS hold placeholders and no name text, so renaming `<limit>` leaves
# it byte-identical while both survivors trip it. `/</` not `/^</` — CONTAINS,
# matching the rule's own `*"<"*` and self-test case 9.
EXPECTED_PLACEHOLDER_SIG='activities=1,2
activity=1
compare=1
complete=1,2
config get=1
config set=1,2
config unset=1
import=1
load=1
pc=1,2
power-curve=1,2
progress=1,2
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

# ...and the LITERALS still read as themselves. LAST of the four deliberately:
# it is the narrowest failure, so the emptiness branches and position signatures
# speak first (ordered the other way, an empty-args table reported "literals
# changed" — true, wrong cause). `judge_trailing` reads three properties of an
# arg: requiredness, placeholder-ness, and the literal's exact TEXT; the first
# two are pinned positionally above, this is the third. Measured survivor:
# renaming `sync`'s `--all` leaves both signatures byte-identical and the
# reference is then accepted; `week`'s `all` is covered only by the one corpus
# line that reaches the rule.
# TEXT here, unlike the placeholder names, and the asymmetry is the rule's own:
# it never reads a placeholder's name (`<limit>` -> `<count>` must stay free)
# and compares a literal's directly (`all` -> `every` should be reviewed).
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

# The two-token ceiling in the extractor is pinned to the table rather than believed. A
# three-word form (`config get set`, say) would otherwise be captured as its two-word
# prefix, and since that prefix would itself resolve, the reference would pass unchecked.
# That is the exact shape tests/e2e.roc hit with a two-literal capture depth: an arm like
# `[_, "week", "add", "bulk", p]` contributed `week add`, which was already accounted for,
# so a real three-token form was invisible and the pin stayed green.
maxtok=$(awk '{ if (NF > m) m = NF } END { print m + 0 }' "$REAL")
case "$maxtok" in ''|*[!0-9]*) echo "command-claims: could not measure the table's widest form (got '$maxtok')" >&2; exit 3 ;; esac
if [ "$maxtok" -gt 2 ]; then
  echo "command-claims: the table declares a $maxtok-word command form, but the extractor captures at most 2 tokens per reference and would silently truncate — widen tokens() before landing that form" >&2
  exit 4
fi

# ----------------------------------------------------------------------- the comparison
#
# LONGEST PREFIX against the table's OWN names — nothing here knows `config` and
# `week` are the two-word verbs. `config set hr_z1_max` resolves at `config
# set`; `config frobnicate` resolves at neither and is reported. The loop peels
# one trailing token at a time, so a wider future form needs no change here
# (the ceiling above widens the extractor to feed it).
#
# THEN the peeled token is judged — skipping that made the peel a hole: a bare
# longest-prefix pass resolves `week frobnicate` at `week`, discards the
# leftover, and passes a doc naming a command the binary does not have. The
# judgement is `judge_trailing`, at the top of this file; do not restate its
# rule here — a restated copy went stale and stated superseded semantics as
# current.

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
  # POSITIONAL, not list-wide (#269), and positional means "any position the token
  # can REACH" — not position 1. The old rule accepted any trailing token if the
  # command declared a placeholder ANYWHERE, blanket-accepting 17 of 30 commands.
  # Judging position 1 only is unsound the other way: `week`'s `all` is optional,
  # so a token may legally fill position 2 by skipping it, and position-1 judging
  # falsely accused `stride week ride` — the worse failure, since the only way out
  # of a false accusation without a marker is degrading the doc.
  #
  # So `judge_trailing` walks the spec and stops at the first REQUIRED arg the
  # token did not match — nothing past that is reachable. The gain: a required
  # literal now BLOCKS a placeholder behind it. Note: accepting `stride week
  # frobnicate` is CORRECT under the sound rule (`all` is optional, position 2 is
  # a placeholder), not a revert. An empty `$spec` means "declares no arguments",
  # so any trailing token refutes; the ARGS-vs-REAL row-count guard is what
  # separates that from "missing from the table".
  judge_trailing "$x" "$spec" && continue
  echo "UNKNOWN  $file:$line  \`stride $cand\` — \`$p\` is a command, but it takes no \`$x\`"
  fail=1
done < "$NAMED"

# "$ndocs of $nfiles" rather than "$nfiles docs": the second number is what the shell stat'd
# and the first is what actually yielded a reference, and reporting only the larger one
# implies a coverage the run never measured. Half the corpus names no command at all.
[ "$fail" = "0" ] && echo "command-claims: $nrefs command references across $ndocs of $nfiles docs, resolved against $nreal commands in the table — all name real commands"
exit $fail
