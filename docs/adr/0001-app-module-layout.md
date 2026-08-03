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
| `Output.roc` | `out!`/`emit_ok!`/`emit_err!`/`print_json!`/`json_mode!`/`err_out!` | Stdout |
| `Db.roc` | `open_db!`, `secure_perms!`, `run_migrations!`, config get/set, `sport_ftp!`, time-anchor | Sqlite, Cmd, Env |
| `Strava.roc` | `auth!`, token refresh, `sync!`, `backfill!`, stream fetch, ftp→Strava | Http, Sqlite |
| `Analyze.roc` | `analyze!`, `compute_one!`, `rebuild_daily_load!`, invalidation CASE | Sqlite |
| `Report.roc` | read commands: summary/week/activities/top/load/stats/doctor/activity/progress/compare/pz | Sqlite |
| `Plan.roc` | `plan_*`, `complete!`, `skip!`, `rate!` (the judgment tier) | Sqlite |
| `Import.roc` | `import_archive!` (CSV) | File, Cmd |
| `app.roc` | just `main!` + `dispatch!` + help text — thin | — |

`Report.roc` is the fattest; if unwieldy it splits again, one module per read-command. The
pure modules (Metrics/Render/Command/Config/Csv/Streams) already exist and don't change.

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
granularity and only subdivide `Report.roc` if it proves unwieldy. No premature structure.
