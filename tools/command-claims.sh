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
# "towc: multibyte conversion failure" and ABANDON the rest of its input — measured at 61
# references instead of 78, exit 2, while the advance bug noted beside emit() was still
# producing arbitrary offsets. With the advance fixed both locales now yield the same 78
# and exit 0; this keeps that from resting on the offsets happening to stay on ASCII.
LC_ALL=C
export LC_ALL

STRIDE="${STRIDE:-./stride}"

# Scope: everything in this repo that describes the CLI in prose. Globs are expanded by the
# shell below, so an EMPTY directory leaves the literal pattern in place and trips the
# per-file guard by name instead of silently contributing nothing.
FILES="README.md AGENTS.md docs/*.md docs/adr/*.md .claude/skills/stride/SKILL.md"

NAMED=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
REAL=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
HELP=$(mktemp) || { echo "command-claims: mktemp failed" >&2; exit 6; }
trap 'rm -f "$NAMED" "$REAL" "$HELP"' EXIT

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
# so `pat` arrives as 0 or 1, `match()` is handed a one-character pattern, and the scan loop
# below stops advancing. It hung on the first file, with no output and no error. The
# `RLENGTH < 1` bail covers the general form of that: a zero-width match would leave `rest`
# unchanged forever.
awk '
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
  # fact. A fenced line can satisfy both rules and would otherwise be reported twice — as it
  # was, when the mutation test planted `stride frobnicate` in ADR 0007. Sorting to dedupe
  # also reorders the report lexically, which puts :10 above :7; emitting in file order and
  # deduping in place keeps the report in reading order. Deduping on a KEY (`sort -u -k1,2`)
  # is the wrong fix twice over: it would collapse the three distinct commands chained on
  # README.md:201 into one.
  function emit(line, pat,   rest, t, r, l, key) {
    rest = line
    while (match(rest, pat)) {
      if (RLENGTH < 1) break
      r = RSTART; l = RLENGTH
      t = tokens(substr(rest, r + l - 1))
      key = FILENAME "\t" FNR "\t" t
      if (t != "" && !seen[key]++) print key
      rest = substr(rest, r + l)
    }
  }
  FNR==1 { fence = 0 }
  /^[[:space:]]*```/ { fence = 1 - fence; next }
  {
    emit($0, "`(\\./)?stride +[a-z]")
    if (fence && match($0, /^[[:space:]]*(\$[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(\.\/)?stride[[:space:]]+[a-z]/))
      emit($0, "(\\./)?stride +[a-z]")
  }
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
# `config` and `week` are the two-word verbs. `week all` resolves at `week`, because `week`
# is a command and `all` is its literal argument; `config set hr_z1_max` resolves at
# `config set`; `config frobnicate` resolves at NEITHER — `config` alone is not a command —
# and is reported, which is right. The loop peels one trailing token at a time rather than
# testing two known shapes, so it needs no change if the table ever grows a wider form
# (the ceiling above is what makes sure the extractor is widened to feed it).
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
  [ -n "$p" ] && continue
  echo "UNKNOWN  $file:$line  \`stride $cand\` names no command the binary has"
  fail=1
done < "$NAMED"

[ "$fail" = "0" ] && echo "command-claims: $nrefs command references across $nfiles docs, resolved against $nreal commands in the table — all name real commands"
exit $fail
