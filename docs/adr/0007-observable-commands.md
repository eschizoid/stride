# ADR 0007 — observable long commands: progress narrates on stderr

Status: accepted · 2026-08-09 — blessed by Mariano; implemented by #91

## Context

`sync` and `analyze` are silent until they finish. Both bit us in the same week:

- A full rescore ran 72 s with no output; both the athlete and the coach concluded it
  had hung, and a healthy analyze got killed mid-transaction.
- `sync` dies mid-run on bug C (upstream heap corruption, ~25–50% of runs) having
  printed nothing — no indication of how far it got or what it was doing. The
  workaround, "run it again," is manual and mystifying to a new user.

The output contract (ADR 0000): stdout carries either the versioned JSON envelope or
the human table — deterministic, golden-fixture-tested. Any observability design must
leave stdout byte-identical.

## Decision

**1. Progress narrates on stderr; stdout is untouched.** Stderr is the process's
narration channel and carries no contract: `rescoring 128/723…`,
`fetching streams 14/60…`, `daily_load rebuild…`. Machine consumers parsing stdout
never see it; golden fixtures never change. basic-cli 0.21 exposes `Stderr.line!` and
`Stderr.write!` (no newline), so no platform work is needed.

**2. Human mode gets a live bar; machine mode gets plain lines.** A `\r`-redrawn bar —
`rescoring [██████████░░░░]  358/723` — reuses the table bar's `█` glyph. Carriage
returns are garbage in logs and CI, and basic-cli exposes no tty check, so the existing
output-mode switch (CLAUDECODE / STRIDE_FORMAT) selects the dress: bar for humans,
appended lines for machines. Same information, dressed for the reader.

**3. Bug C retries — DEFERRED, premise not verified.** The original decision was that
`sync` retries internally (cap 3, narrated, counted in the summary as `synced 22 (2
retries)`), on the reasoning that `sync` is idempotent so an in-process retry is safe.

Measuring before building it found the premise does not hold as stated. Nine runs of the
sync driver against the mock on the pinned nightly: **1 passed, 8 failed** — and in every
failure `sync` itself SUCCEEDED (`2 mock activities synced` passed). What failed was the
TSS value computed afterwards, and the non-zero exit came from the harness's own `check!`,
not from a signal. So the observable symptom in that path is a **silently wrong number**,
not a process death — and a binary cannot retry on "the value I just computed is wrong",
because it has no way to know.

Caveat, stated rather than hidden: this measures the MOCK path. The "dies mid-run" claim
in Context above was recorded from real-Strava syncs and has NOT been re-observed today,
so the two may be different manifestations of the same upstream bug.

Retrying is therefore deferred until bug C's failure mode is actually characterised. The
honest interim workaround is the existing one: `just e2e-sync` re-runs the whole process,
which works precisely because the retry happens OUTSIDE the corrupted process. Tracked
separately; this ADR's narration decisions (1, 2, 4) stand on their own and shipped
without it.

**4. Failures inherit context.** The narration is the context: whatever was last
printed to stderr is what was happening when the process died. No separate "verbose
mode" flag — observability is not opt-in.

## Consequences

- **`json_schema_version` would NOT bump for an additive field like `retries`.** Settled by
  checking what was actually done: `converged` was added to the analyze payload in
  9c67470, which touched `Analyze.roc` only and left the version alone. The envelope's
  version tracks the WRAPPER shape (`{schema_version, data}` vs `{schema_version, error}`),
  not the fields inside a command's payload — a consumer reading known keys is unaffected
  by a new one appearing. Bump it when the wrapper changes or a field is removed/retyped.
- e2e gains coverage by capturing stderr (`2>` redirect in the harness helpers) and
  asserting narration exists for a multi-batch analyze. The bar itself (a `\r` stream) is
  asserted only as "contains no `\r` in machine mode" — exact bar frames are not
  golden-fixtured. (The retry-count assertion is deferred with Decision 3.)
- The known trap is recorded here so tests don't lie: harness helpers that bypass
  `stride!` must pin `STRIDE_FORMAT`, or the narration mode follows the developer's
  shell and passes locally while failing in CI.

## Not doing

- No `--verbose`/`--quiet` flags. One behavior per output mode.
- No progress for fast commands (`summary`, `week`, …) — narration is for commands
  that can plausibly be mistaken for hung.
- No timestamps in narration (determinism of captured stderr in tests matters more
  than log aesthetics).
