# ADR 0004. Power-duration curve + Critical Power

Status: accepted and shipped. Proposed 2026-08-03. The `power-curve` command and the
mean-max columns landed 2026-08-03 in `fadf38c`/`f0ab7e3`, and the CP model was spent by
#186/#187 in PR #190.

The decision here extends [ADR 0002](0002-power-based-intensity.md), which made intensity
power-based. ADR 0002 turned the watts stream into intensity, meaning NP, IF and TSS
judged against FTP. The same stream also describes the athlete's power signature, which is
the mean-max power curve together with the Critical Power model. For a cyclist with a
power meter that is the most useful analytic the engine can offer, and it is the one the
athlete's own data supports best, because the database holds hundreds of power rides.

## Context

Today stride derives exactly one number from a rider's power, the best 20-minute power
that becomes FTP (`best_20min_w`, ADR 0003 and the derived-FTP work), and the shape of the
profile is discarded. A rider's sustainable power varies a great deal with duration,
because a 5-second sprint, a 1-minute attack, a 5-minute VO2 effort, a 20-minute threshold
and a 3-hour endurance ride draw on five different physiological systems. The
power-duration curve, also called mean-max power, records all of them in one line. The
Critical Power (CP) model reduces the curve to two numbers, where CP is the sustainable
aerobic ceiling and W′ is the finite anaerobic capacity above it. Together the two numbers
report anaerobic capacity, VO2 power, threshold and aerobic endurance in one place, they
track fitness over time, and they give a better FTP than 20-min × 0.95.

The engine already has the one hard primitive, `Metrics.best_rolling_mean`, and uses it
for `best_20min_w`. Extending that primitive to a ladder of durations is the whole job.

## Decision

1. Store per-activity mean-max power at a fixed ladder of durations. At `analyze`, compute
   each activity's best rolling-mean power at `5s, 15s, 30s, 60s, 300s, 600s, 1200s, 3600s`
   from the 1 Hz watts stream, using the same `best_rolling_mean` that already yields
   `best_20min_w`, and store the results as additive `activity_metrics` columns. As shipped
   the names are `best_5s_w`, `best_15s_w`, `best_30s_w`, `best_60s_w`, `best_300s_w`,
   `best_600s_w` and `best_3600s_w`, and the 1200 s rung reuses the pre-existing
   `best_20min_w` rather than adding a duplicate. The columns are computed tier, so they
   rebuild from `analyze`, and adding them needs a schema bump and a `metrics_rev` bump.

2. The power-duration curve for a sport is `MAX(best_<dur>_w)` per duration over a recent
   window, 90 days by default, which is the athlete's best power at each duration lately.
   The curve is a pure SQL aggregation over the stored columns and re-reads no streams.

3. Critical Power and W′ come from fitting the 2-parameter hyperbolic model
   `P(t) = W′/t + CP` by linear regression of `P` against `1/t` over the model's valid
   mid-range. The code fits `dur_s` 300 to 1200, that is 5 to 20 min, because the 2-min end
   of the textbook range has no rung and the fit breaks down at sprint and multi-hour
   durations. `CP` is the intercept in watts and `W′` is the slope in joules. The fit is a
   small pure function in `Metrics`, expect-tested against known inputs. With three points
   there is one degree of freedom, so `fit_r2` and the slope's t-statistic are in exact
   bijection and `SE(W′) = W′ / sqrt(r²/(1−r²))` falls out of the same numbers. Read r²
   here as a report of precision rather than of plausibility. On this athlete a fit with r²
   0.72 gives `W′` 6416 J, and adding a submaximal 5 s best raises r² to 0.99 while
   collapsing `W′` to 796 J. [ADR 0013](0013-publishing-a-model-that-does-not-fit.md)
   decides what to publish when the fit is precise about the wrong thing.

4. A new query command `stride power-curve`, aliased `pc`, emits the curve plus CP and W′
   per power sport. It emits JSON for the coach in the versioned envelope, and a table with
   a one-line verdict for the terminal. A duration with no data is omitted from `points`
   entirely, and measured on real data the payload carries 7 rungs and no zero-watt entry,
   so read an absent duration as a missing key rather than as a 0. An earlier version of
   this line described a 0 convention instead, and `ReportHealth.roc` filters
   `watts > 0.0` before emitting.

5. Deriving FTP from CP is deliberately out of scope here. CP is a more principled FTP than
   20-min × 0.95, since CP is roughly 95 to 100% of FTP, but wiring it into the derived-FTP
   path would couple this decision to ADR 0003's scoring and to the pace-engine work in
   flight. Ship the curve and CP as a reporting surface first, and revisit the FTP tie-in as
   its own decision once the curve is trusted.

## Consequences

- The additive schema change and the `metrics_rev` bump make the next `analyze` backfill
  the columns for every activity with a watts stream. There is no data transform, per the
  three tiers in ADR 0000 §3.
- The curve is only as good as the data behind it. A rider who never sprints has a weak
  short end, and a CP fit from too few points is an estimate. Caveat an estimated CP the
  way FTP is caveated, which is to trust the direction rather than the decimals, because
  the ADR 0002 honesty rule carries over.
- The work reuses `best_rolling_mean`, which is already proven and expect-tested, at more
  windows, and the CP regression is a small, pure, testable addition. No new external
  dependency is needed.
- Only power sports have a power curve. HR and pace duration curves are explicitly not in
  scope.

## Scope boundary

In scope are the per-activity mean-max columns, the curve aggregation, the CP and W′ fit,
and the `power-curve` command, all for power-metered sports.

Out of scope are deriving FTP from CP, which is a separate future decision, pace and HR
duration curves, and per-activity curve display, because the curve is a cross-activity
signature rather than a property of a single ride.
