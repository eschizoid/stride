# 0018. Strength sets from layered sources

Status: Accepted
Date: 2026-09-18
Amended: 2026-09-25 — the adapters became a package, the tonnage spine gained
a minimum, and the fixture gate the consequences promised now exists.

## Context

The career view draws a threshold spine per sport family, and strength has no
threshold, so issue #478 asks for a tonnage spine instead. Tonnage needs sets,
reps and weight per session, and where that data lives turned out to be the
whole problem.

Strava's public API cannot receive per-exercise strength data. Its structured
strength endpoint fills only when a workout is logged in Strava's own strength
builder or arrives from a device that writes FIT set messages. Mariano's
sessions come from the Peloton strength app, which records every set but does
not use either path. He pastes Peloton's share summary into the Strava
activity description by hand after each session, so the data reaches Strava as
text in a regular grammar, one exercise name line followed by lines like
"3 × 8 • 30 lbs/side". A parser for that grammar would fill the tonnage
spine for him, and for nobody else. A parser tuned to one athlete's paste
habit must not be the feature's primary path.

## Decision

Strength sets come from layered sources, tried in a fixed order, and every
stored row names the source it came from.

First, the structured endpoint. When Strava returns exercise sets for an
activity, those rows are stored as they are. Athletes who log with Strava's
builder or a FIT device get correct data with no parsing, so the general path
is the primary path.

Second, description adapters. When the structured endpoint returns nothing,
the activity's description is tried against an ordered table of parsers in
`src/cli/Strength.roc`. The parsers themselves live in the `src/strength`
package, one module per app, so a new format is a new file rather than a
longer one. `Adapter.roc` states the contract every module keeps: pure
`Str -> List(SetRow)`, tolerant of junk, silent on formats it does not
recognize, and shipping a real sample of its app's share text as a top-level
`sample` that its own expects parse. `Peloton.roc` is the first adapter. Each
table row holds a name and a parse function, the same shape as
`Sports.families`, so registering a module is one row. The first adapter that
matches wins, so the table's order is part of the decision.

Third, honest absence. A strength session with no structured sets and no
parseable description stays a session. It counts for load and for the streak,
and it contributes nothing to tonnage, so the arc shows a gap. The career spine
already bridges months without a threshold with a dashed line, and the
tonnage spine treats a month where the paste habit slipped the same way. The
spine also refuses to draw at all until three months carry tonnage (#521):
two points are a line through anything, and a trend drawn from them would
claim a direction the data cannot support, so below three the view states the
count it has and the count it needs instead of a curve. A description that
parses badly returns no match rather than failing the sync.

Every `strength_sets` row carries a provenance column naming its source, the
structured endpoint or the adapter that parsed it. `load_coverage` already
states what CTL is built on so the coach can weigh it, and tonnage gets the
same treatment: a trend built from parsed pastes is labeled as such instead
of being flattened into equality with device-recorded rows.

## Consequences

A new app's paste format costs one module in `src/strength`, one table row,
and the sample its expects pin. `tools/adapter-fixtures.sh` holds the three to
each other in CI: the table's order is pinned, every row names a module and
every module has a row, and every module carries its sample and an expect that
parses it. An adapter that arrives without its sample does not land.

The parser is a fallback by construction. If Strava ever opens structured
strength data to API writes, or Peloton starts filling the structured
endpoint, the adapters stop being consulted, because the first layer wins
whenever it has rows.

The sync stores descriptions for strength-class activities; that schema change
landed with the #478 implementation.
