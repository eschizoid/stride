# ADR 0004 — Power-duration curve + Critical Power

Status: accepted — shipped (proposed 2026-08-03; `power-curve` + the mean-max columns
landed 2026-08-03 in `fadf38c`/`f0ab7e3`, and the CP model was spent by #186/#187 in PR #190)

Extends [ADR 0002](0002-power-based-intensity.md) (power-based intensity). 0002 turned the
watts stream into *intensity* (NP/IF/TSS vs FTP). This ADR turns the same stream into the
athlete's *power signature* — the mean-max power curve and the Critical Power model — the
single most valuable analytic for a power-metered cyclist, and the one the athlete's own
data is richest for (hundreds of power rides).

## Context — the reality

Today stride derives exactly **one** number from a rider's power: the best 20-minute power
→ FTP (`best_20min_w`, ADR 0003 / the derived-FTP work). That discards the *shape* of the
profile. A rider's sustainable power varies enormously with duration — a 5-second sprint,
a 1-minute attack, a 5-minute VO2 effort, a 20-minute threshold, a 3-hour endurance ride
are five different physiological systems. The **power-duration curve** (a.k.a. mean-max
power) captures all of them in one line; the **Critical Power (CP) model** distills it to
two numbers — CP (the sustainable aerobic ceiling) and W′ (the finite anaerobic battery
above it). Together they reveal anaerobic capacity, VO2 power, threshold, and aerobic
endurance at a glance, track fitness over time, and give a **better FTP than 20-min × 0.95**.

The engine already has the one hard primitive — `Metrics.best_rolling_mean` — and uses it
for `best_20min_w`. Extending it to a duration ladder is the whole job.

## Decision

1. **Store per-activity mean-max power at a fixed duration ladder.** At `analyze`, compute
   each activity's best rolling-mean power at `5s, 15s, 30s, 60s, 300s, 600s, 1200s, 3600s`
   from the 1 Hz watts stream (the same `best_rolling_mean` that already yields `best_20min_w`)
   and store them as additive `activity_metrics` columns. As shipped the names are
   `best_5s_w`/`best_15s_w`/`best_30s_w`/`best_60s_w`/`best_300s_w`/`best_600s_w`/`best_3600s_w`,
   with the 1200 s rung reusing the pre-existing `best_20min_w` rather than adding a duplicate.
   This is
   computed-tier (rebuilds from `analyze`); it needs a schema bump + a `metrics_rev` bump.

2. **The power-duration curve** for a sport is `MAX(best_<dur>_w)` per duration over a recent
   window (default 90 days) — the athlete's best power at each duration lately. A pure SQL
   aggregation over the stored columns; no re-reading streams.

3. **Critical Power + W′** fit the 2-parameter hyperbolic model `P(t) = W′/t + CP` by linear
   regression of `P` against `1/t` over the model's valid mid-range (the code fits
   `dur_s` 300–1200, i.e. 5–20 min — the 2-min end of the textbook range has no rung; the fit
   breaks down at sprint and multi-hour durations). `CP` is the intercept (watts), `W′` the
   slope (joules). A small pure function in `Metrics`, expect-tested against known inputs.
   With three points there is one degree of freedom, so `fit_r2` and the slope's
   t-statistic are in exact bijection and `SE(W′) = W′ / sqrt(r²/(1−r²))` falls out of the
   same numbers. That is worth knowing because r² here reports PRECISION, not plausibility:
   on this athlete a fit with r² 0.72 gives `W′` 6416 J, and adding a submaximal 5 s best
   raises r² to 0.99 while collapsing `W′` to 796 J.
   [ADR 0013](0013-publishing-a-model-that-does-not-fit.md) decides what to publish when
   the fit is precise about the wrong thing.

4. **A new query command `stride power-curve` (alias `pc`)** emits the curve + CP + W′ per
   power sport — JSON for the coach (versioned envelope), a table + one-line verdict for the
   terminal. A duration with no data is OMITTED from `points` entirely — measured, the
   payload carries 7 rungs and no zero-watt entry — so read absence as a missing key, not
   as a 0. (An earlier version of this line claimed the 0 convention; `ReportHealth.roc` filters
   `watts > 0.0` before emitting.)

5. **FTP-from-CP is deliberately OUT of scope here.** CP is a more principled FTP than
   20-min × 0.95 (CP ≈ 95–100% of FTP), but wiring it into the derived-FTP path couples this
   to ADR-0003's scoring and the pace-engine work in flight. Ship the curve/CP as a *lens*
   first; revisit the FTP tie-in as its own decision once the curve is trusted.

## Consequences

- Additive schema change + `metrics_rev` bump → the next `analyze` backfills the columns for
  every activity with a watts stream. No data transform (three-tiers, per ADR 0000 §3).
- The curve is only as honest as the data: a rider who never sprints has a soft short end; a
  CP fit from too few points is an estimate. Caveat estimated CP like FTP — **trust the
  direction, not the decimals** (the ADR-0002 honesty rule carries over).
- Reuses `best_rolling_mean` (already proven + expect-tested) at more windows; the CP
  regression is a small, pure, testable addition. No new external dependency.
- Only power sports have a power curve; HR/pace duration curves are explicitly not in scope.

## Scope boundary

- **IN:** per-activity mean-max columns, the curve aggregation, the CP/W′ fit, the
  `power-curve` command — for power-metered sports.
- **OUT:** deriving FTP from CP (separate future decision), pace/HR duration curves,
  per-activity curve display (the curve is a cross-activity signature, not a single ride).
