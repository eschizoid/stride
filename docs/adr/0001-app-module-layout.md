# ADR 0001 — app.roc module layout (post new-compiler migration)

Status: accepted · executed 2026-08-02 (the split shipped — `app.roc` is now a thin
argv → dispatch shell; effectful code lives in the `Db.roc`, `Strava.roc`, `Analyze.roc`,
the report family (`Report.roc` + `ReportSessions`/`ReportHealth`/`ReportSeason`), `Plan.roc`, and `Import.roc` modules,
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
| `Strava.roc` | `auth!`, token refresh, `sync!`, stream drain, ftp→Strava | Http, Sqlite |
| `Analyze.roc` | `analyze!`, `compute_one!`, `rebuild_daily_load!`, invalidation CASE | Sqlite |
| `Report.roc` | where do I stand: summary/load/compare, plus the helpers shared across the report family | Sqlite |
| `ReportSessions.roc` | what happened: activity/activities/top/progress/reps | Sqlite |
| `ReportHealth.roc` | check the engine: doctor/stats/zones/power-curve/tte | Sqlite |
| `ReportSeason.roc` | the long view: season (ADR 0011) | Sqlite |
| `Plan.roc` | `plan_*` incl. `plan_bundle!`, `complete!`, `skip!`, `rate!` (the judgment tier) | Sqlite |
| `Import.roc` | `import_archive!` (CSV) | File, Cmd |
| `app.roc` | just `main!` + `dispatch!` + help text — thin | — |

The pure modules (Metrics/Render/Command/Config/Csv/Streams/Sports) already exist and
don't change.

**When to split `Report.roc` (measurable, not a vibe).** "If it feels unwieldy" is
unfalsifiable, so the trigger is: split when **either** a single command function exceeds
**~250 lines**, **or** the file passes **~1500 lines**. When this ADR was written (2026-08-05) `Report.roc` was 1185 lines and its
largest definition was `doctor!` at 171, so the trigger had NOT fired then.

**Amended 2026-08-18 — the split is DONE (#196), and it went by read-command family.**

Line counts are a snapshot at the split commit, not a live measurement — they are here to
show the shape of the move, and later edits to these files do not make the table wrong.

| file | before | after |
|---|---|---|
| `Report.roc` | 2780 | 702 |
| `ReportSessions.roc` | — | 1107 |
| `ReportHealth.roc` | — | 499 |
| `ReportSeason.roc` | — | 293 |
| `Plan.roc` | 768 | 1025 |

`plan_bundle!` moved to `Plan.roc` rather than into a report module: it serves the `plan`
command, `week` already dispatched to `Plan.plan_view!`, and `Plan.roc` owns the judgment
tier (ADR 0000 §3). That was a misfiling, not a size problem.

Three helpers stayed in `Report.roc` and are called qualified from the new modules, because
each is shared across families: the high/medium/low model lists (doctor + summary's
coverage), `sport_filter_sql` (power-curve + activities/top) and `cp_fit_as_of!` (tte +
activity). The families depend inward on the core; the core imports none of them, so there
is no cycle to reason about.

**The file half of the trigger is now satisfied everywhere. The function half is not, and
this ADR should probably stop treating them as the same measurement.** After the split,
`summary_payload!` is 356, `activity_body!` 377, `plan_view!` 297, `doctor!` 259,
`plan_bundle!` 254 — all past ~250.

Lifting the one genuinely self-contained block out of `summary_payload!` (its hard-day
stats: three inputs, one record out) took it from 394 to 356. Each further extraction of
that quality buys roughly forty lines and needs three or four more to reach the trigger,
and the remaining candidates each thread five or six intermediates, so the call site grows
as the body shrinks.

That is worth naming rather than grinding through. These functions are LINEAR sequences of
forty-odd named bindings with no nesting — a different problem from a 350-line function
with deep control flow, and a line count cannot tell them apart. Splitting further would
satisfy the number while turning local bindings into record fields threaded across a
boundary, which is not obviously more readable.

So: the file trigger stands as written and worked. The function trigger needs a better
predicate before it is worth acting on again — nesting depth, or the number of distinct
things a reader must hold at once, rather than lines. Until someone proposes one, the five
functions above are recorded as knowingly over the line rather than silently so.

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
