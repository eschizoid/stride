# ADR 0001. app.roc module layout (post new-compiler migration)

Status: accepted, executed 2026-08-02. The split shipped, so `app.roc` is now a thin
argv → dispatch shell. Effectful code lives in the `Db.roc`, `Strava.roc`, `Analyze.roc`,
`Plan.roc` and `Import.roc` modules and in the report family (`Report.roc` plus
`ReportSessions`/`ReportHealth`/`ReportSeason`), and all of them are `roc check` green on
the new compiler.
Date: 2026-08-01

The decision supersedes the monolith constraint in [ADR 0000 §2](0000-architecture.md).
ADR 0000 ended §2 with "Commands stay in app.roc … Re-test this after any compiler change."
The new-compiler migration is that change and the re-test passed, so this ADR records the
layout app.roc splits into once it is green.

## Context

On the alpha4 compiler, two constraints forced everything effectful into `app.roc`, which
is how that one file reached 2631 lines. First, effects were available only in the app
module, so no other module could use platform effects. Second, module params were
monomorphic, so a decoder wider than two columns failed to type-check once effects were
injected into a sub-module, which meant query and decoder code could not move out. Both
constraints are specific to alpha4, and the migration to the new Zig compiler removes them.

## Decision

Verified on 2026-08-01, a non-main module on the new compiler can `import pf.Stdout`, along
with Sqlite, Http and the rest, and can define effectful (`=>`) functions. A two-file probe
compiled with zero errors except a too-loose annotation on my part. The old restriction is
therefore gone, and app.roc is split by domain, carrying forward one rule from ADR 0000.
Each module keeps its SQL queries next to their row decoders, which is the adjacency guard
the compiler still cannot check.

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
| `app.roc` | just `main!` + `dispatch!` + help text, kept thin | none |

The pure modules (Metrics/Render/Command/Config/Csv/Streams/Sports) already exist and
don't change.

### When to split Report.roc

The trigger has to be measurable. "If it feels unwieldy" is unfalsifiable, so the rule is
to split when either a single command function exceeds about 250 lines or the file passes
about 1500 lines. When this ADR was written on 2026-08-05, `Report.roc` was 1185 lines and
its largest definition was `doctor!` at 171 lines, so the trigger had not fired then.

### Amended 2026-08-18. The split is done (#196), and it went by read-command family

Line counts are a snapshot at the split commit rather than a live measurement. They show
the shape of the move, and later edits to these files do not make the table wrong.

| file | before | after |
|---|---|---|
| `Report.roc` | 2780 | 702 |
| `ReportSessions.roc` | none | 1107 |
| `ReportHealth.roc` | none | 499 |
| `ReportSeason.roc` | none | 293 |
| `Plan.roc` | 768 | 1025 |

`plan_bundle!` moved to `Plan.roc` rather than into a report module. It serves the `plan`
command, and `week` already dispatched to `Plan.plan_view!`. `Plan.roc` also owns the
judgment tier (ADR 0000 §3). The move corrected a misfiling rather than a size problem.

Three helpers stayed in `Report.roc` and are called qualified from the new modules, because
each is shared across families. They are the high/medium/low model lists, read by doctor
and by summary's coverage, `sport_filter_sql`, read by power-curve and by activities/top,
and `cp_fit_as_of!`, read by tte and activity. The families depend inward on the core, and
the core imports none of them, so there is no cycle to reason about.

The file half of the trigger is now satisfied everywhere, and the function half is not, so
this ADR should probably stop treating the two as the same measurement. After the split,
`summary_payload!` is 356 lines, `activity_body!` 377, `plan_view!` 297, `doctor!` 259 and
`plan_bundle!` 254, so all five are past the roughly 250-line mark.

Lifting the one genuinely self-contained block out of `summary_payload!`, its hard-day
stats with three inputs and one record out, took the function from 394 lines to 356. Each
further extraction of that quality removes roughly forty lines, and three or four more of
them would be needed to reach the trigger. The remaining candidates each thread five or six
intermediates, so the call site grows as the body shrinks.

The shape of these functions is the reason to name the situation rather than keep
extracting. Each one is a linear sequence of about forty named bindings with no nesting,
which is a different problem from a 350-line function with deep control flow, and a line
count cannot tell the two apart. Splitting further would satisfy the number while turning
local bindings into record fields threaded across a boundary, which is not obviously more
readable.

The file trigger therefore stands as written, and it worked. The function trigger needs a
better predicate before anyone acts on it again, such as nesting depth or the number of
distinct things a reader must hold at once, rather than lines. Until someone proposes one,
the five functions above are recorded as knowingly over the limit rather than silently
over it.

## Consequences and sequencing

- Never migrate and split in one step. First, app.roc must be green on the new compiler as
  a single file with all tests passing, and that state must be committed. Second, extract
  one module at a time and keep `roc-new test` green after each extraction, so every step
  is independently verifiable.
- You can read each module's effect boundary off its signatures, because the `=>` arrow is
  written there, which the monolith could not document.
- ADR 0000 §2's "commands can't be split" paragraph gets rewritten to point here once this
  lands. The three-tier data model in §3 informs the boundaries, because `Plan.roc` owns
  the judgment tier, `Analyze.roc` owns the computed tier, and `Strava.roc` and `Db.roc`
  own the mirror tier's I/O.

## Not doing

Splitting further than domains, for example one file per command, is not done up front. The
layout starts at domain granularity, and `Report.roc` is subdivided only when the measured
trigger above fires. No structure is added before it is needed.

## Update, 2026-09-17

Two file-layout facts above no longer describe the tree, and the decision survives both.

The engine's entry point is `src/main.roc` rather than `app.roc`, renamed in #394 on
2026-09-07, so every mention of `app.roc` above refers to that file. The split by domain
and the adjacency rule are unchanged.

`Sports` is no longer an engine module, because it moved into a shared Roc package at
`src/core/` that also holds `Fmt`, and both binaries import that package. The list of pure
modules above therefore names one module that now lives outside the engine. ADR 0016
records the layer table that governs these imports, and ADR 0017 records what may live in
the package.
