# 0017. Shared semantics live in the database, as SQL views

Status: Accepted
Date: 2026-09-08

## Context

The viz window and the CLI must agree on what the data MEANS — which planned
row counts for a date, where a week starts — but they cannot share code: they
compile against different platforms (basic-cli vs roc-ray) on different
compiler pins, and ADR 0016's layer gate deliberately forbids viz importing
engine modules. ADR 0015 already made the database their only channel for
state. Before this decision, the viz re-created the CLI's queries, up to and
including a dedupe clause quoted verbatim with a comment promising it would
not drift — the kind of promise that always breaks (#403's review caught the
first divergence within hours).

## Decision

**The rule the two sides must share is written once, as a SQL view in
`Schema.roc`, and both sides SELECT from it.** Not just data through the bus
— meaning through the bus.

The first two:

- `plan_current` — exactly one row per planned date: the newest non-skipped
  row wins; a skipped tombstone speaks only when nothing replaced it.
- `week_bounds` — the Monday of the series' current week
  (`date(COALESCE(MAX(day), date('now','localtime')), '-6 days', 'weekday 1')`,
  verified for all seven weekdays; an empty daily_load anchors on the wall
  clock), matching `Metrics.weekly_rollup`'s alignment.

## The sharp edges, learned in #403's eleven review rounds

- **Views migrate LAST.** `run_migrations!` applies them after every ALTER,
  because a view naming a column that an ALTER adds fails on any database
  older than the column. DROP + CREATE each run, so an edited definition
  always wins.
- **A raw-history scope bypasses the view on purpose.** `week all` shows
  tombstones — that is its contract, e2e-pinned. Windowed reads dedupe via
  `id IN (SELECT id FROM plan_current)` so the rule still has one home.
- **A reader on a never-migrated database finds no view** and must render its
  empty state, not guess. The viz does; the engine migrates on every run.

## Consequences

- Every future view in the fleet (#409) defines its semantics here first;
  the CLI can adopt the same view whenever it grows the matching feature.
- The schema version bumps when a view definition changes, like any
  migration.

## Amendment (2026-09-10): the full set, and why not a shared package

Five views now carry every cross-surface definition: `plan_current`,
`week_bounds`, `activity_intensity` (the intensity split — both report
surfaces and the viz read it; no inline copy remains), `activity_power_ladder`
(the power-ladder unpivot: which columns, which family words, and that 0
means unrecorded — windowed bests, all-time PRs and health reports aggregate
it differently but unpivot identically), and `weekly_ramp` (Monday-week TSS,
end-of-week CTL, week-over-week ramp). `Metrics.roc`'s `ramp_7d`/`ramp_28d_avg`
are rolling daily rates — a different quantity that keeps its own name.

The views are a workaround elevated to a decision, and the constraint behind
them is worth recording: Roc apps bind to exactly one platform, the engine
(basic-cli) and the window (roc-ray) pin different compiler nightlies, and so
no Roc module can be imported by both binaries today. A platform-independent
`stride-core` package is the eventual fix; until the two pins converge on a
compiler where that works, the database is the only module system the two
binaries share, and this ADR is deferred-until-the-toolchain-allows, not
chosen forever.
