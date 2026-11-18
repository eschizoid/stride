# 0018. Strength sets from layered sources

Status: Accepted
Date: 2026-09-18
Amended: 2026-09-25 — the adapters became a package, the tonnage spine gained
a minimum, and the fixture gate the consequences promised now exists.
Amended: 2026-10-21 — the structured layer arrives through `stride strength
import` and the `strength_logs` table, read by a `strava` adapter at the top of
the table, because Strava's public API does not return a workout's sets.
Amended: 2026-11-18 — every adapter reports the pieces of its own format it
could not read (`unread`), and `stride doctor` counts them for recent sessions.

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

First, the structured log. Strava's app keeps a strength workout's exercises
as structured data, one entry per set with the exercise, its muscle groups,
and the weight and reps recorded. Strava's public API does not return it;
Strava's MCP connector does. The engine cannot call the connector, so a coach
fetches the JSON and hands it to `stride strength import`, which stores one
workout object per activity in the `strength_logs` mirror table. When an
activity has a stored log, the log is what the rebuild parses and its
description is not consulted, because both describe the same session and
reading both would count its sets twice. Athletes who log in Strava's own
builder get their recorded sets with no paste and no grammar to guess, so the
general path is the primary path.

The structured log carries a weight on bodyweight moves too, often the
athlete's own mass, which would make push-ups outweigh the session's lifts.
A bodyweight exercise, matched by name against a fixed list (an assisted or
negative form included), keeps its sets and reps and counts 0 kg toward
tonnage, from a pasted description as well as a log. Only the derived set
rows read 0 kg; the stored text keeps the recorded weight, so the list can
change without a re-import. The import names every logged set it zeroed. A
zeroed pasted line has no such report; `stride strength` shows the exercise
in reps.

Second, description adapters. When an activity has no stored log, its
description is tried against an ordered table of parsers in
`src/cli/Strength.roc`. The parsers themselves live in the `src/strength`
package, one module per source, so a new format is a new file rather than a
longer one. `Adapter.roc` states the contract every module keeps: a pure
`parse : Str -> List(SetRow)`, tolerant of junk, silent on formats it does not
recognize, an `unread` beside it (below), and a real sample of its source's
text as a top-level `sample` that its own expects parse. The stored log is
read by the same table: `StravaLog.roc` parses a workout object and sits
first, because JSON is the narrower grammar, and `Peloton.roc` parses
Peloton's share summary below it. Each table row holds a name, a parse
function and an unread function: a table of records, like `Sports.families`,
so registering a module is one row. The first adapter that recognizes the text
wins, so the table's order is part of the decision.

Beside `parse`, each adapter keeps an `unread` function: the pieces of text
in its own format that it saw and could not turn into a row. For the Peloton
summary that is a line that opens like a set line (`3 × 8 • ...`) but does not
parse, or one with no exercise name above it; for the Strava log it is a set
the decoder left out, with its reason. It is empty on text of any other
format, so the silence the table relies on holds, and an adapter recognizes a
text when it reads rows from it or reports unread pieces of it, so a paste
whose every set line is unreadable is still reported against its own source.
An unread piece never fails a sync or an analyze. `stride doctor` counts the
unread pieces in the strength sessions of the last 30 days and names those
sessions, so a set the grammar cannot read is a visible gap rather than a
silent one: the honest-absence rule below, applied to a single line. It is a
second function rather than a richer return type from `parse`, so `parse`
keeps the contract every caller and expect already relies on.

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
every module has a row, a row's `parse` and `unread` come from the same
module, and every module carries its sample and an expect that
parses it. An adapter that arrives without its sample does not land.

The description parser is a fallback by construction. An activity with a
stored log never reaches it, and if Strava ever returns structured strength
data through its public API, sync can store it in the same table and the
description adapters stop being consulted for those activities, because the
first layer wins whenever it has rows.

The sync stores descriptions for strength-class activities; that schema change
landed with the #478 implementation. `stride strength import` stores logs in
`strength_logs`, a mirror table of their own, keyed by activity.
