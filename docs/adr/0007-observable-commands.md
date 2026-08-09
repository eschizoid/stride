# ADR 0007 — observable long commands: progress on stderr, retries in the binary

Status: proposed · 2026-08-09 — design settled in the roadmap grill; written up for
review before implementation

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

**3. Bug C retries live inside the binary.** `sync` is idempotent (INSERT OR REPLACE
mirrors; metrics invalidation is deletion-based), so an internal retry is safe. Cap: 3
attempts. Each retry is narrated on stderr as it happens and **counted in the stdout
summary** — `synced 22 (2 retries)` in human mode, a `retries` field in the JSON
envelope — so the upstream bug's real-world frequency stays visible instead of being
silently absorbed. After the cap: fail loud, with the last narration line already
naming the failing step (`failed fetching streams for <id>, attempt 3/3`).

**4. Failures inherit context.** The narration is the context: whatever was last
printed to stderr is what was happening when the process died. No separate "verbose
mode" flag — observability is not opt-in.

## Consequences

- `json_schema_version` bumps if the envelope gains the `retries` field (additive —
  confirm whether the envelope's additive-field convention applies, per the
  `converged` precedent which did NOT bump).
- e2e gains coverage by capturing stderr (`2>` redirect in the harness helpers) and
  asserting narration exists for a multi-batch analyze, and that a mocked-failure sync
  reports its retry count. The bar itself (a `\r` stream) is asserted only as
  "contains no `\r` in machine mode" — exact bar frames are not golden-fixtured.
- The known trap is recorded here so tests don't lie: harness helpers that bypass
  `stride!` must pin `STRIDE_FORMAT`, or the narration mode follows the developer's
  shell and passes locally while failing in CI.

## Not doing

- No `--verbose`/`--quiet` flags. One behavior per output mode.
- No progress for fast commands (`summary`, `week`, …) — narration is for commands
  that can plausibly be mistaken for hung.
- No timestamps in narration (determinism of captured stderr in tests matters more
  than log aesthetics).
