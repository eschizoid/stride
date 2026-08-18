# ADR 0001 — app.roc module layout (post new-compiler migration)

Status: accepted · executed 2026-08-02 (the split shipped — `app.roc` is now a thin
argv → dispatch shell; effectful code lives in the `Db.roc`, `Strava.roc`, `Analyze.roc`,
`Report.roc`, `Plan.roc`, and `Import.roc` modules,
all `roc check` green on the new compiler) · 2026-08-01

Supersedes the monolith constraint in [ADR 0000 §2](0000-architecture.md). ADR 0000
ended §2 with: *"Commands stay in app.roc … Re-test this after any compiler change."*
The new-compiler migration is that change, and the re-test passed — so this ADR records
the layout app.roc splits into once it's green.

## Context — why app.roc was one 2631-line file

On the alpha4 compiler, two constraints forced everything effectful into `app.roc`:
1. **Effects only in the app module** — no other module could use platform effects.
2. **Monomorphic module params** — a decoder wider than two columns failed to type-check
   once effects were injected into a sub-module, so query/decoder code couldn't move out.

Both are alpha4-specific. The migration to the new (Zig) compiler removes them.

## Decision

**Verified (2026-08-01):** on the new compiler, a *non-main* module can `import pf.Stdout`
(and Sqlite/Http/…) and define effectful (`=>`) functions — a two-file probe compiled with
zero errors except a too-loose annotation on my part. So the wall is gone, and app.roc is
split by **domain**, with one rule carried forward from ADR 0000: **each module keeps its
SQL queries next to their row decoders** (the adjacency guard the compiler still can't check).

| Module | Contents | Effects |
|---|---|---|
| `Output.roc` | `out!`/`emit_ok!`/`emit_err!`/`json_mode!`/`err_out!`/`usage!`/`narrate!` | Stdout |
| `Db.roc` | `open_db!`, `secure_perms!`, `run_migrations!`, config get/set, `sport_ftp!`, time-anchor | Sqlite, Cmd, Env |
| `Strava.roc` | `auth!`, token refresh, `sync!`, `backfill!`, stream fetch, ftp→Strava | Http, Sqlite |
| `Analyze.roc` | `analyze!`, `compute_one!`, `rebuild_daily_load!`, invalidation CASE | Sqlite |
| `Report.roc` | read commands: summary/activities/top/load/stats/doctor/activity/progress/compare/pz/power-curve/reps/season/tte/plan | Sqlite |
| `Plan.roc` | `plan_*`, `complete!`, `skip!`, `rate!` (the judgment tier) | Sqlite |
| `Import.roc` | `import_archive!` (CSV) | File, Cmd |
| `app.roc` | just `main!` + `dispatch!` + help text — thin | — |

`Report.roc` is the fattest and will keep growing. The pure modules
(Metrics/Render/Command/Config/Csv/Streams) already exist and don't change.

**When to split `Report.roc` (measurable, not a vibe).** "If it feels unwieldy" is
unfalsifiable, so the trigger is: split when **either** a single command function exceeds
**~250 lines**, **or** the file passes **~1500 lines**. When this ADR was written (2026-08-05) `Report.roc` was 1185 lines and its
largest definition was `doctor!` at 171, so the trigger had NOT fired then.

**Amended 2026-08-17 — the trigger has FIRED, on both halves (#196).** `Report.roc` is
**over 2700 lines** across 37 definitions, and four command functions are past the ~250
line: `summary_payload!`, `activity_body!`, `doctor!` and `plan_bundle!`, with `reps!` and
`season!` below it. Exact spans are deliberately not quoted here — an earlier version of
this sentence put `doctor!` "just under" the trigger, and a comment edit in THIS PR pushed
it over, which is the rot this ADR's own "measure it with something that fails" line warns
about. `#196` measures them when the split is actually done. For
scale, the file that motivated this ADR's original split was `app.roc` at 2631 lines.
The subdivision below is therefore in scope; what the boundaries should be is the open
question. Note the trigger went unnoticed for weeks because it was tracked in an untracked
scratch file — if it is restated, it should be measured by something that fails. Splitting *before* the trigger bought nothing measurable: specialization is
whole-program, so a split does not speed the build (proven during the migration), and each
new pure module must be wired into the `just test` recipe or its expects silently stop
running — which is why the threshold exists rather than a preference for small files.

The split, now in scope, goes by **read-command family**, not one module per command (11 tiny
modules is worse than one cohesive file) — the seams follow the help text:

| Module | Commands |
|---|---|
| `Report.roc` | where do I stand: `summary`, `load`, `compare` (`week` is dispatched to `Plan.plan_view!`) |
| `ReportSessions.roc` | what happened: `activities`, `activity`, `top`, `progress` |
| `ReportHealth.roc` | reference/diagnostics: `doctor`, `stats`, `zones`, `power-curve` |

## Consequences & sequencing

- **Never migrate-and-split in one step.** app.roc must first be green on the new compiler
  as a single file (all tests passing), committed. THEN extract one module at a time, with
  `roc-new test` green after each — every step independently verifiable.
- Effect boundaries become explicit per module (`=>` in the signatures), which is a
  documentation win the monolith couldn't give.
- ADR 0000 §2's "commands can't be split" paragraph gets rewritten to point here once this
  lands. The three-tier data model (§3) informs the boundaries: `Plan.roc` owns the judgment
  tier, `Analyze.roc` owns the computed tier, `Strava.roc`/`Db.roc` own the mirror tier's I/O.

## Not doing

Splitting further than domains (e.g. one file per command) up front — start at domain
granularity and only subdivide `Report.roc` when the measured trigger above fires. No
premature structure.
