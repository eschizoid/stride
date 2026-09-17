# 0017. Shared semantics live in the database, as SQL views

Status: Accepted
Date: 2026-09-08

## Context

The viz window and the CLI must agree on what the data means, which covers
questions such as which planned row counts for a date and where a week
starts. They cannot share code, because they compile against different
platforms, basic-cli for one and roc-ray for the other, on different compiler
pins, and because ADR 0016's layer gate deliberately forbids viz importing
engine modules. ADR 0015 already made the database their only channel for
state. Before this decision the viz re-created the CLI's queries, up to and
including a dedupe clause quoted verbatim with a comment promising it would
not drift, and #403's review caught the first divergence within hours.

## Decision

The rule the two sides must share is written once, as a SQL view in
`Schema.roc`, and both sides SELECT from it. The bus carries the meaning of
the data as well as the data itself.

The first two views are these.

- `plan_current` returns exactly one row per planned date. The newest
  non-skipped row wins, and a skipped tombstone counts only when nothing
  replaced it.
- `week_bounds` returns the Monday of the series' current week as
  `date(COALESCE(MAX(day), date('now','localtime')), '-6 days', 'weekday 1')`,
  which is verified for all seven weekdays and matches the alignment of
  `Metrics.weekly_rollup`. An empty daily_load anchors the result on the wall
  clock.

## What the eleven review rounds in #403 established

- Views migrate last. `run_migrations!` applies them after every ALTER,
  because a view naming a column that an ALTER adds fails on any database
  older than the column. Each run drops and creates them, so an edited
  definition always wins.
- A raw history scope bypasses the view on purpose. `week all` shows
  tombstones, which is its contract and is pinned in the e2e suite. Windowed
  reads dedupe with `id IN (SELECT id FROM plan_current)`, so the rule still
  has one home.
- A reader on a never-migrated database finds no view, and it must render its
  empty state rather than guess. The viz does that, and the engine migrates on
  every run.

## Consequences

- Every future view in the fleet (#409) defines its semantics here first, and
  the CLI can adopt the same view whenever it grows the matching feature.
- The schema version bumps when a view definition changes, like any
  migration.

## Amendment, 2026-09-09. The full set of views, and why not a shared package

Five views now carry every cross-surface definition, and they are
`plan_current`, `week_bounds`, `activity_intensity`, `activity_power_ladder`
and `weekly_ramp`. `activity_intensity` holds the intensity split, both report
surfaces and the viz read it, and no inline copy remains.
`activity_power_ladder` holds the power ladder unpivot, which states which
columns are used, which family words apply, and that 0 means unrecorded.
Windowed bests, all-time PRs and health reports aggregate that view
differently and unpivot it identically. `weekly_ramp` holds Monday-week TSS,
end-of-week CTL and week-over-week ramp. The `ramp_7d` and `ramp_28d_avg`
values in `Metrics.roc` are rolling daily rates, which is a different quantity
that keeps its own name.

The views are a workaround raised to a decision, and the constraint behind
them is recorded here. A Roc app binds to exactly one platform, the engine
binds basic-cli and the window binds roc-ray, and the two pin different
compiler nightlies, so no Roc module can be imported by both binaries today. A
platform-independent `stride-core` package is the eventual fix. Until the two
pins converge on a compiler where that works, the database is the only module
system the two binaries share, and the decision is deferred until the
toolchain allows the package rather than chosen forever.

## Amendment, 2026-09-16. `stride-core` exists, and it never needed the pins to converge

The earlier amendment said a shared package was "deferred until the toolchain
allows it." The claim rested on an assumption nobody had tested, which was
that two apps on different compiler nightlies could not import one package.
Measured, the assumption is false. A package declares no compiler of its own,
and both binaries import `src/core` on the pins they already had, as the table
below records.

| | imports `src/core` |
| --- | --- |
| engine on `nightly-2026-09-09` | yes |
| window on `nightly-2026-09-07` | yes |

So `src/core` is in, on today's pins, with no convergence involved. The cost
of the untested assumption was months of a workaround presented as a
constraint, and the lesson is that "the toolchain will not let us" is a claim
like any other and deserves the ten minutes it takes to test.

Convergence is still useful for its own sake, because it gives one tag, one
gate and one thing to bump, and both binaries do build on
`nightly-2026-09-16`. It is blocked for now on something unrelated to this
decision. roc-ray 0.10.0-rc5 declares `nightly-2026-09-07` in its own header,
so a 09-16 build warns, and CI treats that warning as an error. The
convergence waits for a roc-ray release naming a newer compiler.

The views are not retired, and the test for which mechanism to reach for is
where the definition has to be true.

- A SQL view holds a definition about rows, meaning which rows count, how they
  group, and what joins them. The views are `plan_current`, `week_bounds`,
  `activity_intensity`, `activity_power_ladder`, `weekly_ramp`,
  `career_totals`, `monthly_load` and `monthly_threshold`. Moving those into
  Roc would mean each binary running its own SQL and agreeing by luck.
- A core module holds a definition about a value already in hand. `Fmt.mmss`
  and `Fmt.hundredths` are the first two, because both surfaces had written
  each rule out separately, so a padding change could reach one and miss the
  other.

The layer rule extends accordingly, since `src/core` sits beneath both homes
and may import neither. The direction needs no gate, because a package
importing an app's modules is not expressible in Roc, and
`tools/layer-check.sh` scans core for strays and gives it no layer row.

## What cannot move into `stride-core`, and what can (tested 2026-09-17)

"Why not put `Db.roc` in core?" is the obvious next question, and the answer
was measured rather than reasoned, because the last assumption in this ADR was
wrong.

The driver cannot move. A package module may write `import pf.Sqlite`, but
calling into it fails at the first use.

```
Nothing is named query! in this scope.
```

`pf` is a name an app binds to its platform, and a package has none. The
engine binds basic-cli's `Sqlite`, which is path-based, and the window binds
roc-ray's, which is handle-based, so the effectful layer stays in each binary.
The driver half of the old constraint is real.

SQL text and driver-parameterised shapes can move, because both of these
compile in a package today.

```roc
count_sql : Str
counted! : (Str => Try(I64, [Failed])), Str => I64
```

There is nothing to move, though. Of the engine's 24 queries and the window's
38, not one pair shares even a 45-character prefix, and the two files touch
mostly different tables, with migration, schema versioning and config on one
side and view loaders and the agent bus on the other. They share a filename
rather than a job.

So the boundary is drawn as follows.

- Core takes values, meaning arithmetic, formatting and vocabulary (`Fmt`,
  `Sports`).
- The database takes rows, meaning every cross-surface definition, as a view.
- Each binary keeps its own thin driver, because the platform makes that
  unavoidable.

Should a genuinely shared query ever appear, core can hold the string and each
side can run it. Until one does, centralising `Db.roc` would build an
abstraction over two drivers that share no queries, which is cost with no
duplication retired.

## Update, 2026-09-17. The two pins have converged

The 2026-09-16 amendment says convergence is blocked, because roc-ray 0.10.0-rc5
declares `nightly-2026-09-07` and CI treats the resulting warning as an error.
#471 landed the convergence anyway. Both binaries now build on
`nightly-2026-09-16-a49a16f`, which is the `setup-roc` action's default and is
mirrored in the app header of `src/viz/main.roc`, and `tools/pin-check.sh`
holds those two copies together while refusing any per-job override. roc-ray
still declares the older compiler, so a viz build emits one mismatch warning,
and `tools/roc-viz.sh` tolerates exactly that one warning and fails on
anything else. The script is deleted the day roc-ray names the compiler this
repo pins.

The convergence changes nothing else in this ADR. The package never needed it,
the views still hold every definition about rows, and each binary still keeps
its own driver.
