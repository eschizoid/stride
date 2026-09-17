# ADR 0007. Observable long commands: progress narration on stderr

Status: Accepted
Date: 2026-08-09
Note: Mariano approved the decision, and #91 implemented it.

## Context

`sync` and `analyze` are silent until they finish, and both caused a problem in the same
week. First, a full rescore ran 72 s with no output. Both the athlete and the coach
concluded it had hung, and a healthy analyze was killed mid-transaction. Second, `sync`
dies mid-run on bug C, which is upstream heap corruption affecting roughly 25 to 50% of
runs, having printed nothing at all. There is no indication of how far it got or what it
was doing. The workaround, which is to run it again, is manual and confusing to a new user.

The output contract in ADR 0000 says that stdout carries either the versioned JSON envelope
or the human table. Both are deterministic and tested against golden fixtures. Any
observability design must leave stdout byte-identical.

## Decision

### Decision 1. Progress narrates on stderr and stdout is untouched

Stderr is the process's narration channel and carries no contract. Examples of the
narration are `rescoring 128/723…`, `fetching streams 14/60…` and `rebuilding daily load…`.
Machine consumers parsing stdout never see the narration, and golden fixtures never change.
basic-cli 0.22 exposes `Stderr.line!` and `Stderr.write!`, which writes no newline, so no
platform work is needed.

### Decision 2. Human mode gets a live bar and machine mode gets plain lines

A bar redrawn with `\r`, such as `rescoring [██████████░░░░]  358/723`, reuses the table
bar's `█` glyph. Carriage returns are unreadable in logs and CI, and basic-cli exposes no
tty check. The existing output-mode switch therefore selects the form, with a bar for
humans and appended lines for machines. The switch reads `--json` and `--human`, and
otherwise STRIDE_FORMAT, which has been the only environment input since #181. The
information is the same in both forms.

### Decision 3. Bug C retries, deferred because the premise was not verified

The original decision was that `sync` retries internally, with a cap of 3, narrated, and
counted in the summary as `synced 22 (2 retries)`. The reasoning was that `sync` is
idempotent, so an in-process retry is safe.

Measuring before building it found that the premise does not hold as stated. Nine runs of
the sync driver against the mock on the pinned nightly gave 1 pass and 8 failures. In every
failure `sync` itself succeeded, because `2 mock activities synced` passed. What failed was
the TSS value computed afterwards, and the non-zero exit came from the harness's own
`check!` rather than from a signal. The observable symptom in that path is a silently wrong
number rather than a process death, and a binary cannot retry on "the value I just computed
is wrong" because it has no way to know.

One caveat is recorded rather than hidden. The measurement covers the mock path only. The
"dies mid-run" claim in the context above was recorded from real Strava syncs and was not
re-observed on the day of the measurement, so the two may be different manifestations of
the same upstream bug.

Retrying is therefore deferred until bug C's failure mode is characterised. The interim
workaround is the existing one, because `just e2e-sync` re-runs the whole process and works
precisely because the retry happens outside the corrupted process. The retry is tracked
separately, and this ADR's narration decisions 1, 2 and 4 stand on their own and shipped
without it.

### Amendment of 2026-08-17, decision 3 is withdrawn rather than deferred

Bug C was root-caused and fixed upstream. basic-cli 0.21's host double-freed every heap
`Str` in a bindings list, reported as basic-cli#471, fixed in #472 and shipped in 0.22.0,
tracked in stride as #105 and closed 2026-08-14. The 5x retry that had absorbed the flake
was deleted from `justfile` deliberately when the bug was fixed, so a new flake here gets
an investigation rather than absorption. The context item above, which says `sync` dies
mid-run on bug C in roughly 25 to 50% of runs, describes a failure mode that can no longer
occur. It is kept for the history rather than as a live constraint.

### Decision 4. Failures inherit context

The narration is the context, because whatever was last printed to stderr is what was
happening when the process died. There is no separate verbose-mode flag, and observability
is not opt-in.

## Consequences

`json_schema_version` would not bump for an additive field such as `retries`. The question
was settled by checking what was actually done. `converged` was added to the analyze
payload in 9c67470, which touched `Analyze.roc` only and left the version alone. The
envelope's version tracks the wrapper shape, meaning `{schema_version, data}` against
`{schema_version, error}`, rather than the fields inside a command's payload. A consumer
reading known keys is unaffected by a new key appearing. Bump the version when the wrapper
changes or when a field is removed or retyped.

The e2e suite gains coverage by capturing stderr with a `2>` redirect in the harness helpers
and asserting that narration exists for a multi-batch analyze. The bar itself is a `\r`
stream and is asserted only as containing no `\r` in machine mode, because exact bar frames
are not held in golden fixtures. The retry-count assertion is deferred along with decision
3.

One known trap is recorded here so that tests do not lie. Harness helpers that bypass
`stride!` must pin `STRIDE_FORMAT`. Otherwise the narration mode follows the developer's
shell, and the test passes locally while failing in CI.

## Not doing

There are no `--verbose` or `--quiet` flags, because there is one behavior per output mode.

There is no progress for fast commands such as `summary` and `week`, because narration is
for commands that can plausibly be mistaken for hung.

There are no timestamps in narration, because determinism of captured stderr in tests is
more important than the appearance of the log.
