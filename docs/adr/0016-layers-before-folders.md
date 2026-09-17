# 0016. Layers before folders

Status: Accepted
Date: 2026-09-07
Updated: 2026-09-17

## Context

The viz suite went through the split the rest of the codebase wanted in #386 and
#388, so one file of 710 lines became seven modules under `src/viz/`. The
engine's `src/` is already modular in the language sense, because every file is a
`Name :: [].{ … }` module. The modules sit flat in one directory, two of them are
very large at 234K for Metrics and 155K for Render, and nothing states or
enforces which module may depend on which.

Moving files into `src/core/` and `src/analytics/` folders was not possible when
we wrote this. On the nightlies pinned at the time, which were 2026-09-04 for the
engine and 2026-08-23 for the window, an import of a module in a local
subdirectory did not resolve. `import core.Metrics` parsed and bound
nothing, and the bare, qualified, and `as` forms all left the module out of
scope. We probed all three on 2026-09-07. `src/viz/` works because its app file
sits inside the folder and imports its siblings, so one app's modules have to be
its siblings.

## Decision

Define the layers now, and move the files when the compiler can follow them.

A module's layer is a statement about its imports rather than its location.

| layer | modules | may import |
|---|---|---|
| core package | `src/core/` (`Fmt`, `Sports`) | nothing outside itself |
| engine core | Metrics, Csv, Streams, Config, Drain, Schema, Render | engine core, and the core package |
| io | Db, Strava, Output | the layers above, and io |
| analytics | Analyze, Plan, Report, ReportHealth, ReportSeason, ReportSessions | the layers above, and analytics |
| app | main.roc, Command, Import | anything |
| viz | `src/viz/` (its own app) | its own modules, its platform, and the core package |

Two mechanical consequences follow. First, `tools/layer-check.sh` asserts the
table, because it reads each module's `import` lines and fails CI when an import
points at a higher layer. The table above is the configuration, the script holds
a copy of it, and the ADR explains why the boundaries are drawn where they are.
Second, when a nightly lands where the subdirectory probe passes, moving the
files is a mechanical change gated by the same script, so it needs a ticket
rather than a new ADR. The boundaries will not have changed, only the paths.

## What the decision deliberately leaves alone

The decision renames nothing, moves no files, and changes no behavior. It also
adds no module boundaries inside the large files, because splitting a file is a
ticket to raise whenever its size hurts, and the layer table already says where
the pieces would live.

## Consequences

The dependency direction used to live only in maintainers' heads, and it fails
CI when violated, starting from the first commit after the check landed.

An early draft recorded `Strava`, which is io, importing `Render`, which the
draft placed in analytics, and called it a carried exception. Measuring every
module's imports before writing the gate removed the exception, because `Render`
imports only `Metrics` and `Drain`. Its dependencies already put it in core, and
classifying it there leaves the gate strict with no exceptions at all. Core is
also the honest description of what `Render` does, since it shapes text over pure
math and every layer above it calls the result.

## Update, 2026-09-17

Two facts in the context above have changed, and the decision survives both.

A shared `src/core/` now exists, so the first paragraph of the context no longer
describes the tree. It is a Roc **package** rather than a subdirectory of either
app, which is the loophole the original probe missed. Both binaries import it,
and ADR 0017 records what may live there. Subdirectory imports within a single
app still do not resolve, so the reason the engine's own modules stay flat is
unchanged.

`Sports` moved into the core package, so it is no longer an engine module. Both
binaries need the sport vocabulary, and the module was already pure with no
imports of its own.
