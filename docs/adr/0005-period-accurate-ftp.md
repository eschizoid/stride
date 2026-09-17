# ADR 0005. The scoring threshold is period-accurate, not retroactive

Status: Accepted
Date: 2026-08-05
Note: The athlete explicitly accepted the recompute cost.

## Amendment of 2026-08-08, extended to the derived pace threshold

As accepted, this ADR moved the window anchor for FTP and said nothing about the pace
threshold, which pace sports are scored against exactly as power sports are scored against
FTP. The pace threshold was left anchored to today, so it was the sport's best 20-minute
grade-adjusted speed over the last 60 days, one global number applied to every activity in
history. A 2021 run was therefore scored against 2026 fitness, which is what this ADR
rejected for power. The omission was not a decision, because the pace rung was not in view
when this was written.

Two consequences made the omission visible. First, identical work in different seasons
received different load, which is the defect that motivated this ADR. Second, because the
window ends at today, deleting any recent metrics row moved the global threshold and
invalidated every activity of that sport back to the beginning. An ordinary 22-activity
sync queued all 723 rows for recompute (issue #79). The second consequence is a symptom of
the retroactive anchor rather than a separate problem, and it disappears once the window is
anchored per activity.

The decision below now reads on both derived thresholds. Everywhere it says FTP and
`ftp_used`, it says the same of the derived pace threshold and `threshold_pace_used`. The
derived pace threshold is the sport's best 20-minute grade-adjusted speed × 0.95 over the
60 days ending on that activity's date, with the same cold-start forward-fill and the same
per-row comparison in the recompute `WHERE`. The derivation, the anchor and the reasoning
are the same as for FTP. A `metrics_rev` bump delivered the change with no schema change,
because the column already existed and already carried per-row provenance.

The decision here refines [ADR 0002](0002-power-based-intensity.md) without superseding it.
ADR 0002 settled that intensity is power-based and per-sport, and it noted in passing that
an unset threshold is "auto-derived from that sport's own best-20-min power × 0.95". ADR
0002 never addressed which derived value scores a given activity, because the question of
the window's anchor did not come up. ADR 0005 answers only that question, and it leaves the
derivation formula and the per-sport model untouched.

One inconsistency is recorded here rather than hidden. ADR 0002 describes `ftp_<sport>` as
something you "set (or auto-derive)", but `Db.sport_ftp!` ignores configuration entirely
and always derives. Whether a configured value should win is a separate open question,
tracked as P3.2, and it is deliberately not settled here.

## Amendment of 2026-08-17

Two things in this ADR have since been settled elsewhere.

- The override question is closed. ADR 0002's 2026-08-06 amendment settled it the day after
  this ADR was written. FTP is always derived, and `stride config set ftp_ride` is refused
  outright by `Config.is_derived`, which is expect-tested for `ftp_ride`, `ftp_rowing` and
  `ftp_kitesurfing`. "P3.2" tracked the question in an untracked scratch file that no longer
  exists, so there is no open item behind the paragraph above.
- The window's population is the sport family rather than the sport. As written below, the
  anchor is "the sport's best 20-minute power over the 60 days ending on that activity's
  date". Since #151 and PR #169 the query filters `a2.sport_family = a.sport_family`. Pace
  thresholds deliberately still key on the exact `sport_type`. A trail run and a track run
  are not interchangeable at a given pace, while a gravel ride and a road ride are
  interchangeable at a given wattage. Reading this ADR alone gives the wrong population, and
  ADR 0002's 2026-08-16 amendment is the authority.

## Context

`Db.sport_ftp!` derived a sport's FTP as its best 20-minute power over the last 60 days
× 0.95, and that single number then scored every activity of that sport however old it was.
One `ftp_used` covered the whole history of a sport, spanning years.

Two consequences followed, and both were live in the production database when this was
written. Neither is live now, because the decision below shipped. The same database carries
53 distinct `ftp_used` values for Ride alone, ranging from 139 to 271, one per activity's
own era, which is the fix working. An earlier version of this section printed the two
pre-fix rows as if they were current, so it read as a live defect rather than as the
motivation for a decision already taken.

The first consequence is that historical load is understated. A December 2021 ride at NP
170 W scores IF 0.70 and TSS 36.5 against FTP 243. Scored against the FTP actually in force
then, which was nearer the 190 that was configured before the July recalibration, it was
IF ≈ 0.89 and TSS ≈ 59. Old seasons read roughly 40% easier than they were.

The understatement is a definitional problem rather than a rounding problem. CTL, ATL and
TSB model training stress relative to the fitness the athlete had at the time. Dividing a
2021 effort by 2026 fitness produces a number that does not mean what the model says it
means.

The second consequence is that history is not stable. Because the window slides, a new
20-minute best changes the derived FTP. The changed FTP changes `ftp_used`, which
invalidates and rescores every activity. Last March's CTL moves because of what happened in
August. A training log whose past changes when the present does is not a log.

### The tradeoff we assumed does not exist

A single threshold was assumed to buy cross-time comparability, meaning the same standard
for a 2021 ride and a 2026 ride. Inspection of `Metrics.lens_score` shows that the
comparison commands do not use FTP at all.

| Lens | Score | Uses FTP? |
|---|---|---|
| `Ef` | `np_w / avg_hr` | no |
| `SpeedHr` | `(distance / time) / avg_hr` | no |
| `Rpe` | `rpe` | no |

`progress` does not use FTP, and `power-curve` reports raw watts. The only reader that
would change character is `top intensity`, which becomes "hardest relative to the fitness
you had", arguably the more useful ranking. The cost of moving the anchor is therefore
close to nothing.

## Decision

`activity_metrics.ftp_used` stores the FTP in force when the activity happened.

The resolution is the sport's best 20-minute power over the 60 days ending on that
activity's date, × 0.95. The derivation is the same as before, and only the window anchor
is different.

Activities older than the first 60 days of history have no prior window, which is the cold
start case. Scoring them at FTP 0 would silently drop them to the HR rung, so the earliest
derivable FTP is carried backwards instead. Unknown early fitness is approximated by the
earliest fitness actually measured, which is the least wrong answer available and is honest
about being an approximation.

Recomputation compares `ftp_used` against the value for that row's date rather than against
one global current FTP.

The column name already implied the stored meaning, and the column now carries it.

## Consequences

CTL, ATL and TSB become physiologically meaningful across the whole history rather than
only across the recent window. Past numbers also stop moving, because a new PR changes
future scoring only, which is the main gain from the decision.

A change in current FTP no longer rescores old rows. Only rows whose own 60-day window is
affected are rescored. The change simplifies the invalidation story from ADR 0000 §5, and
it is also a change to a documented invariant, which is why this ADR exists.

The invalidation `WHERE` becomes a correlated per-row subquery rather than a flat `CASE`.
On a database of this size, meaning hundreds to low thousands of rows, the subquery is not
a practical concern and stays O(n).

Numbers will move on the first run after the decision lands. Older seasons rise, sometimes
substantially, while current form barely shifts, because recent activities were already
being scored against a recent window. A `metrics_rev` bump delivers the change, so the
backfill is the ordinary recompute path with no migration. There is no schema change,
because `ftp_used` already exists and already carries per-row provenance.

## Alternatives considered

The first alternative was to keep retroactive scoring and document it. The approach is
cheap and honest, because `doctor` states that historical load is scored at current FTP. It
was rejected as the primary answer, because it leaves the headline number in `summary` and
`week` resting on a value that moves, and both the athlete and the coach read that number
first. It should still be done if this ADR is not implemented.

The second alternative was to store two values, a snapshot for load and the current value
for display. It was rejected. Two FTPs per activity means every reader has to know which
one it is holding, and the audit already found one column, `normalized_power`, carrying two
different quantities. The project is not repeating that.

The third alternative was to freeze `ftp_used` at first computation. It was rejected,
because it makes the score depend on when the user happened to run `analyze`, which is
worse than either other option. The result is non-deterministic across users with identical
data, and it breaks the "recompute from raw streams" reproducibility promise in ADR
0000 §1.

## Not doing

A configured FTP override is not decided here. Letting `config set ftp_ride` win over
derivation is a separate question, and it would restore the lab-tested FTP path and make
the existing help text true. The question is independent of this decision and is tracked
separately.

The derivation itself does not change. The 0.95 factor and the 60-day window stay as they
are, and this ADR moves only the anchor of the window.

Backfilling a "true" historical FTP from outside sources, such as old Strava profile values
or test results, is not done. The engine derives from data it holds, and imported claims
are not data.
