# 0016. Layers before folders — the engine's module boundaries

Status: Proposed
Date: 2026-09-07

## Context

The viz suite just went through the split the rest of the codebase wants (#386/#388):
one 710-line file became seven modules under `src/viz/`. The engine's `src/` is
already modular in the language sense — every file is a `Name :: [].{ … }` module —
but the modules live flat, some are very large (Metrics 234K, Render 155K), and
nothing states or enforces which may depend on which.

The obvious next move, `src/core/` and `src/analytics/` folders, is **not available**:
on the pinned nightlies (engine 2026-09-04, viz 2026-08-23) a local subdirectory
import does not resolve. `import core.Metrics` parses and binds nothing — bare,
qualified, and `as` forms all leave the module out of scope (probed 2026-09-07).
`src/viz/` works only because its app file sits inside the folder importing
siblings. One app's modules must be its siblings.

## Decision

**Define the layers now; move the files when the compiler can follow them.**

The layer of a module is a statement about its imports, not its location:

| layer | modules | may import |
|---|---|---|
| core | Sports, Metrics, Csv, Streams, Config, Drain, Schema | core only |
| io | Db, Strava, Output | core + io |
| analytics | Analyze, Plan, Render, Report, ReportHealth, ReportSeason, ReportSessions | core + io + analytics |
| app | app.roc, Command, Import | anything |
| viz | `src/viz/` (its own app, its own pin) | its own modules + its platform |

Two mechanical consequences:

1. `tools/layer-check.sh` asserts the table: it reads each module's `import` lines
   and fails CI when an import points down the table at a higher layer. The table
   above is the config, in the script, and this ADR describes it — the script is
   the enforcement, the ADR the why.
2. When a nightly lands where the subdirectory probe passes, the foldering is a
   mechanical move gated by the same script — a ticket, not a new ADR (the
   boundaries will not have changed, only the paths).

## What this deliberately does not do

- No renames, no file moves, no behavior change now.
- No new module boundaries inside the big files (Metrics, Render). Splitting a
  file is a ticket whenever its size hurts; the layer table already says where
  the pieces would live.

## Consequences

- The dependency direction that today only lives in maintainers' heads fails CI
  when violated, starting from the first commit after the check lands.
- One known tension is recorded rather than hidden: `Strava` (io) imports
  `Render` (analytics) today. The check will carry an explicit, counted
  exception for it until the formatting it uses moves into core, which is the
  first real cleanup this table points at.
