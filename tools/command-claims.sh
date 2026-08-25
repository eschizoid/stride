#!/usr/bin/env sh
# Every `stride <command>` a doc NAMES is a claim that the binary HAS it, and nothing
# checked it. #219 made the command table machine-readable — `stride --json --help` yields
# `.data.commands[].name` — precisely so claims about the CLI could be checked rather than
# trusted, and `just schema-check` plus the e2e command-schema loop already hold the
# binary's own help payload to that table. Prose ABOUT the CLI, in files the binary never
# reads, was the half with no oracle (#252).
#
# Sibling of tools/issue-claims.sh and deliberately shaped like it: the same fail-closed
# extraction, the same "the probe must be able to speak" assertions, and its own `just`
# recipe rather than a step of `just test`. issue-claims is its own recipe because it needs
# `gh` auth; this one because it needs a BUILT BINARY to ask.
#
# ONE DIRECTION ONLY. A doc naming a command that does not exist is a correctness bug and
# fails here. A command no doc mentions is a COVERAGE question — it would make every new
# command land red until somebody wrote a sentence about it — and is deliberately not
# checked.
#
# POSIX sh, and run as `sh` rather than `bash` on purpose. `/bin/sh` on macOS is bash 3.2
# in POSIX mode, where `<(...)` is a SYNTAX ERROR; the substitution then yields an EMPTY
# operand, and two empty sides compare EQUAL, so the check passes having read nothing. The
# command-table pins in tests/e2e.roc were written that way and had never executed a single
# comparison until review mutated `pz` to `pzz` and watched the suite stay green. Temp files
# and a trap throughout, and running under `sh` is what keeps the constraint honest — a
# bashism would work on the author's machine and break where it matters. `set -o pipefail`
# is not POSIX either, which is the other reason every load-bearing extraction below writes
# to a file instead of a pipe: `cmd > file` reports cmd's status, `cmd | jq` reports jq's.
#
# No python: AGENTS.md rules it out project-wide. Shell + jq.
set -u
# Byte-wise, so substr() offsets are byte offsets. The extractor below walks a line by
# re-slicing it, and a slice that lands mid-character makes macOS awk FATAL with
# "towc: multibyte conversion failure" and ABANDON the rest of its input.
#
# What is verified, both ways: reintroduce the advance bug noted beside emit(), and the same
# code that exits 0 under LC_ALL=C dies under en_US.UTF-8 with
# `awk: towc: multibyte conversion failure`, exit 2, having read only part of its input. The
# docs are full of em dashes and box-drawing, so a wrong offset finds one immediately. With
# the advance fixed both locales yield the same 79 at exit 0.
#
# THE RECONSTRUCTION IS PART OF THE MEASUREMENT. Three people reconstructed this bug and got
# 61, 591 and 658, each reading like a refutation of the others, and three revisions of this
# comment were spent on that. They are the same measurement at different settings of two
# switches nobody had written down:
#
#   dedupe OFF, quoting-skip ON   ->  591 under C
#   dedupe OFF, quoting-skip OFF  ->  658 under C     (the 67 extra are all one line:
#                                                      the 1041-character marker line in
#                                                      AGENTS.md, which the skip removes)
#   dedupe ON                     ->   78/79, because the dedupe collapses the runaway
#                                      loop back onto the right total — the very thing
#                                      that hid this bug during development
#
# Clobbering the FIRST of the two RSTART/RLENGTH uses is a no-op, which is why it never
# showed up as a variable: awk evaluates `substr(rest, RSTART + RLENGTH - 1)` before calling
# tokens(), so "both clobbered" and "advance clobbered" are one program.
#
# The UTF-8 side aborts at exit 2 in every cell, and its count is NOT stable across machines
# — 61 on one, 180 here, because "abandon the rest of the input at the first glyph a wrong
# offset lands inside" depends on where that offset lands. The abort is the fact; the
# truncation point is not.
#
# Note which direction this fails in: LOUDLY. awk exits 2, the `||` below turns that into
# exit 5, and the truncated corpus would trip the floors anyway. It is the SILENT zero from
# the regex-literal bug that needed guarding, not this. So LC_ALL=C is defence in depth — it
# keeps the two locales agreeing without resting on every offset landing on ASCII.
LC_ALL=C
export LC_ALL

STRIDE="${STRIDE:-./stride}"

# Scope: everything in this repo that describes the CLI in prose. Globs are expanded by the
# shell below, so an EMPTY directory leaves the literal pattern in place and trips the
# per-file guard by name instead of silently contributing nothing.
FILES="README.md AGENTS.md docs/*.md docs/adr/*.md .claude/skills/stride/SKILL.md"

# The corpus is PINNED, not merely reported, and that gap was one of this check's two blind
# spots. The only quantitative assertion used to be "> 0", so any shrink short of total
# silence passed under a confident summary line. Rule B contributes 19 of the 79 — measured
# by disabling it — so a fence dialect, a parity flip, or a doc quietly leaving FILES could
# remove a quarter of the corpus while the run read clean. That is the same
# right-looking-total-over-a-wrong-scan the emit() dedupe hid once already, relocated from
# the loop to the corpus.
#
# THE FLOORS CANNOT SEE THE OTHER BLIND SPOT, and it matters that this is written down next
# to them rather than discovered again. They measure the extractor's OUTPUT, so they detect
# references that stop being counted and are structurally blind to references that were
# never counted at all. Review demonstrated three mutations that held the total at exactly
# its pinned value and exited 0: a real `stride sync` added inside the quoting-marked line,
# and `stride frobnicate` planted in a `~~~` fence or in a four-space indented block. The
# second is the one that stung — a doc naming a command the binary does not have, in a
# perfectly valid CommonMark fence, passing the one check whose header promises to catch it.
# No floor value can reach that; the fix had to be in the EXTRACTOR.
#
# So the tilde fence is a recognised dialect below, and UNPARSED counts what neither rule
# could read. Both directions are now measured rather than argued: converting every ``` in
# README to `~~~` is a NO-OP today (79 references, exit 0) where it used to take the corpus
# to 59, and the indented block trips the pin at exit 4 naming the cause.
#
# FLOORS, not equalities, because the directions are not symmetric here: growth is somebody
# writing docs and must not fail, shrink is the failure being guarded. issue-claims pins its
# marker count EXACTLY, for the opposite reason — a suppression is deliberate in both
# directions, so both directions should be loud.
#
# MIN_DOCS counts the docs that CONTRIBUTED a reference, not the docs stat'd. `nfiles` below
# is computed by a shell loop that never opens a file, so it reads 18 whether awk scanned
# eighteen documents or one; only 9 of the 18 carry a reference at all. Lower these when a
# doc genuinely loses references, and say which in the commit message.
MIN_REFS=79
MIN_DOCS=9

# Every `command-claims: quoting` marker in the corpus, pinned so a new one is deliberate —
# the same mechanism and the same pin as issue-claims, for the same reason.
#
# A doc that says a command does NOT exist otherwise fails here on a TRUE sentence. That is
# not hypothetical: this check was born from a README line naming `stride backfill`, and
# src/Command.roc still carries the retired-command arm that makes `backfill` worth
# explaining. Planted against the real table, all three of these go red —
# "there is no `stride backfill` command", "the old `stride migrate` was removed in 0.4",
# "an error looks like `stride frobnicate`: unknown command" — and the only way out without
# a marker is to strip the backticks, degrading the doc to satisfy the linter.
#
# LINE-scoped, unlike issue-claims' block scope, because a reference is a line-level fact
# here while an issue-state claim spans a paragraph. In prose written one-paragraph-per-line
# the marker rides at the end of the sentence inside an HTML comment, which renders as
# nothing.
#
# Counts LINES, where issue-claims counts OCCURRENCES, and the divergence is deliberate. Its
# unit is a paragraph, so a second token pasted into an already-marked block is invisible to
# block-counting; here the unit IS the line, so "how many lines are exempt" is exactly what
# the pin should hold. A line carrying the token twice — the AGENTS.md line does, once in
# backticked prose naming the marker and once as the marker — exempts one line either way.
#
# AGENTS.md carries the one exempted line, and it deliberately also names a fake command
# (`stride backfill`), so documenting the escape hatch is what exercises it: this is not a
# pin of zero guarding a mechanism nobody runs. Verified by deleting the `next` from the awk
# rule below, which reports `AGENTS.md:331 stride backfill` and exits 1.
#
# IT OVER-APPLIES, and that is the accepted cost rather than an oversight. The unit is the
# LINE, so a genuine claim added to an exempted line is exempted with it — measured: adding a
# real `stride sync` inside the AGENTS.md marker line leaves the total at 78 and the run
# green. There is no narrower unit available without a parser that can tell an asserted
# reference from a quoted one, which is the natural-language wall issue-claims hit and
# answered the same way. What holds the cost down is that a marker is loud to add (the pin
# above), every one is findable with `grep -rn 'command-claims: quoting'`, and there is
# currently exactly one line in the corpus it can hide anything on. Keep marked lines short.
#
# The pin is a COUNT, not an identity: with two or more markers, one could be moved from a
# quoted line to a genuine failure and the count would not notice. Latent today — moving the
# only marker re-exposes `stride backfill` and exits 1.
EXPECTED_QUOTING=1

# Lines that MENTION `stride <lowercase-word>` and yielded no reference. This is the counter
# for the direction the floors above structurally cannot see: they measure what was counted,
# so a reference that was never counted at all leaves the total unchanged and the run green.
# Review demonstrated `stride frobnicate` passing inside a `~~~` fence and inside a
# four-space indented block, which is the one outcome the header of this file promises to
# prevent.
#
# Most of this count is ordinary prose — "stride refuses", "stride already knows", "stride
# answers the question" — and none of it is a defect. The number is not a quality signal and
# a lower one is not better. What it buys is that the number MOVES when the extractor stops
# reading a shape, so a new fence dialect, a new code-block style, or a rule that quietly
# stopped matching becomes a red run instead of a silent gap. Read the diff when it changes:
# a new shape needs a rule, new prose needs this bumped.
#
# Pinned EXACTLY, not floored, and that is the opposite choice from MIN_REFS/MIN_DOCS on
# purpose. Those guard a quantity that legitimately grows; this one is a description of the
# corpus, and both directions are worth a look — it going DOWN can mean a rule started
# matching prose it should not.
#
# It inherits BOTH weaknesses recorded beside EXPECTED_QUOTING, and for the same reasons.
# It is a COUNT, not an identity: deleting one prose line while adding one unread claim
# holds the total and passes. And it is PER LINE and binary — a line that yields any
# reference is exempt from it entirely, so a second claim in an unread shape on the same
# line is invisible to both mechanisms.
#
# The `~~~` dialect added below widened the fence-parity surface: a prose line that begins
# with `~~~` now flips polarity, and a doc explaining fence dialects is exactly the sort of
# thing this repo writes. That risk is covered by this pin — measured, such a line takes the
# count to 43 and exits 4 — which is the property worth having: the fix's own new hazard
# lands on the fix's own new instrument.
#
# 43 on this tree, and the FIRST run of this counter was worth the whole exercise. It came
# back 44: 41 ordinary prose lines ("stride is", "stride refuses", "stride answers the
# question"), and three inside fences, which is where a missed claim would hide.
#
#   README.md:18   `── stride report (as of …)`  a banner, correctly not an invocation
#   README.md:131  `curl -o stride https://…`    a download, correctly not an invocation
#   README.md:171  `#   stride config set …`     a COMMENTED-OUT invocation — a real gap
#
# The third was a genuine command reference nothing was checking, and the fix went in the
# DOC rather than here. Teaching rule B to accept a `#` prefix was built and measured: it
# gains exactly one reference and costs a false accusation on
# `# stride refuses to guess your zones`, reported as "`stride refuses to` names no command"
# — because inside a fence an explanatory comment and a commented invocation are both `#`
# plus text, and nothing short of parsing the fence info string separates them. So the line
# was backticked instead, matching its own neighbour two lines below which already was.
# Rule A picks it up with no anchor change, the count went 78 -> 79 and 44 -> 43, and a
# bogus command planted there is now reported at exit 1 instead of living there forever.
EXPECTED_UNPARSED=43

# The trap goes up FIRST, before any of them exist. Installed after the block, a failure on
# the second or third mktemp leaks the ones already created — `exit 6` runs with no trap
# armed. `rm -f ""` is a silent no-op (exit 0), so the unset placeholders cost nothing.
NAMED=; REAL=; HELP=; ARGS=; QUOTED=; UNPARSED=
trap 'rm -f "$NAMED" "$REAL" "$HELP" "$ARGS" "$QUOTED" "$UNPARSED"' EXIT
NAMED=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
REAL=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
HELP=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
ARGS=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
QUOTED=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
UNPARSED=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }

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

# The SECOND half of the oracle, and the reason `stride week frobnicate` is refutable at all.
# Longest-prefix resolution alone makes any bogus token after a real command invisible: it
# resolves at `week`, the leftover is discarded, and the reference passes — in the exact
# direction this tool exists for. The table already carries what distinguishes them. `week`
# declares the literal lowercase arg `all`, `top` declares `<hr|tss|…>`, and `analyze`
# declares nothing at all, so `week all` is VERIFIABLE, `top hr` is a placeholder value, and
# `analyze frobnicate` is REFUTABLE. Flags (`--all`) never reach here — tokens() captures
# `[a-z]`, so a leading `-` is not a token.
#
# One line per command, name<TAB>arg names joined by spaces, and pinned to REAL's line count
# below so the two halves cannot silently disagree about which commands exist.
jq -r '.data.commands[] | .name + "\t" + ([.args[]?.name] | join(" "))' < "$HELP" > "$ARGS" \
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

# TWO extraction rules, and the difference between them is the whole reason this is awk and
# not one grep.
#
# Rule A — an inline code span, anywhere: `` `stride <cmd>` ``. The BACKTICK is what
# separates a command reference from the English word "stride". Measured on this tree, an
# unanchored `stride [a-z]+` sweep of these same files yields `stride is`, `stride already`,
# `stride cannot`, `stride declines`, `stride refuses` and thirty more verbs — every one of
# them a doc "naming a command that does not exist". The backtick takes that to zero.
#
# Rule B — a fenced INVOCATION line. The README's install and quickstart blocks are the
# highest-value prose about the CLI in the repo and almost none of it is backticked, so
# rule A alone reads past `stride init`, `stride config set …`, `stride sync && stride
# analyze && stride summary`. It is anchored at line start (allowing a `$ ` prompt, leading
# `VAR=value` assignments, and `./`) because the same fences contain lines that are NOT
# invocations: `── stride report (as of …)` is banner OUTPUT and
# `curl -o stride https://…` is a download, and an unanchored sweep inside fences turns
# those into claims about commands named `report` and `https`. Once a line is established
# as an invocation, every `stride <cmd>` ON it is extracted — that is what catches the
# three commands chained on the daily-loop line.
#
# fence state resets at FNR==1: a file that ends inside an unclosed fence must not leave the
# next file's whole text marked as fenced. issue-claims needs the same guard for the same
# reason and says so.
#
# TWO tokens per reference, matching the widest form the table declares (`config get`,
# `config set`, `week add`). That ceiling is not assumed — it is asserted against the table
# below, so a three-word form added later fails loudly instead of being silently truncated
# to a two-word prefix that happens to resolve.
#
# The two patterns are STRINGS, not `/…/` literals, and that is not a style choice. A regex
# literal passed as a function argument is not a regex in awk — it evaluates to `$0 ~ /…/`,
# so `pat` arrives as 0 or 1 and `match()` is handed the one-character pattern `0`.
# Measured: `awk 'BEGIN { pat = /`stride +[a-z]/; print pat }'` prints 0, and match() against
# it hits the first literal zero in the line.
#
# The failure that leaves is a SILENT ZERO, which is why the `nrefs`/floor guards below are
# the ones that catch it. Reintroducing only the literal into the current loop yields 0
# emissions, exit 0, instantly, over all 18 files — no output and no error, but also no hang.
# (It did hang while the advance below was also broken; both at once, a scan that never
# progresses. Only the combination hangs, and the comment used to attribute that to the
# literal alone.) The `RLENGTH < 1` bail covers the general form: a zero-width match would
# leave `rest` unchanged forever.
awk -v Q="$QUOTED" -v U="$UNPARSED" '
  function tokens(s) {
    if (match(s, /^[a-z][a-z-]*( [a-z][a-z-]*)?/)) return substr(s, RSTART, RLENGTH)
    return ""
  }
  # r and l are copies, and they have to be: tokens() calls match() itself, which CLOBBERS
  # the RSTART/RLENGTH this loop advances on. Reading them back after the call advanced by
  # the TOKEN match instead of the anchor match, so the scan crawled over the same span
  # again and again — 263 emissions from one line of SKILL.md. A dedupe downstream hid it
  # perfectly: the corpus count came out right while the loop was wrong.
  #
  # Dedupe is HERE, on the whole (file, line, command) triple, and not a `sort -u` after the
  # fact. Two shapes collide: a fenced line can satisfy both rules, and one line can name the
  # same command twice. Measured on this tree with the dedupe disabled, it is the second —
  # 79 raw emissions against 78, the single suppression being SKILL.md:183, which backticks
  # `stride analyze` twice in one sentence. Sorting to dedupe also reorders the report
  # lexically, which puts :10 above :7; emitting in file order and deduping in place keeps
  # the report in reading order. Deduping on a KEY (`sort -u -k1,2`) is the wrong fix twice
  # over: it would collapse the three distinct commands chained on README.md:201 into one.
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
      # as unparsed. That case cannot occur: `seen` keys on FILENAME, FNR and the token, so
      # the first hit of any token on a line is always new and always prints. Stated as
      # unreachable rather than as a property, because an earlier version of this comment
      # claimed the opposite behaviour AND claimed it was right — wrong twice, in the one
      # file whose thesis is that comments must be measurements.
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
# A grep that finds nothing and a grep that never ran look identical, and this repo's most
# repeated defect is a check that passed because it measured nothing. Both sides are
# asserted non-empty BEFORE the comparison, and the diagnostic names WHICH side is empty,
# because the two mean opposite things: an empty docs side is a broken extractor reporting
# a clean tree, an empty table side is a broken oracle.
#
# Numeric-validated first. On this /bin/sh an empty operand makes `[ "" -eq 0 ]` print
# "integer expression expected" and take the ELSE branch — the guard would fail OPEN, which
# is the exact shape of the bug it exists to catch.
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
# LONGEST PREFIX against the table's OWN names, which is why nothing here knows that
# `config` and `week` are the two-word verbs. `config set hr_z1_max` resolves at
# `config set`; `config frobnicate` resolves at NEITHER — `config` alone is not a command —
# and is reported, which is right. The loop peels one trailing token at a time rather than
# testing two known shapes, so it needs no change if the table ever grows a wider form
# (the ceiling above is what makes sure the extractor is widened to feed it).
#
# THEN the peeled token is judged, and skipping that step is what made the peel a hole. A
# bare longest-prefix pass resolves `week frobnicate` at `week`, discards the leftover and
# calls the reference clean — a doc naming a command the binary does not have, passing the
# one check that exists to catch exactly that. The table settles it: `week` declares the
# literal `all`, `top` declares `<hr|tss|…>`, and `analyze` declares nothing, so `week all`
# is verifiable, `top hr` is a placeholder value, and `analyze frobnicate` and
# `week frobnicate` are refutable. A command declaring ANY placeholder accepts any trailing
# token, because a placeholder's whole point is that its values are not enumerable here.
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
  case "$spec" in *"<"*) continue ;; esac
  case " $spec " in *" $x "*) continue ;; esac
  echo "UNKNOWN  $file:$line  \`stride $cand\` — \`$p\` is a command, but it takes no \`$x\`"
  fail=1
done < "$NAMED"

# "$ndocs of $nfiles" rather than "$nfiles docs": the second number is what the shell stat'd
# and the first is what actually yielded a reference, and reporting only the larger one
# implies a coverage the run never measured. Half the corpus names no command at all.
[ "$fail" = "0" ] && echo "command-claims: $nrefs command references across $ndocs of $nfiles docs, resolved against $nreal commands in the table — all name real commands"
exit $fail
