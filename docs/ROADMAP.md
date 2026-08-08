# Roadmap — what stride is missing to be The Sports Analytics Engine

Drafted 2026-08-08, after the v0.5.0 analytics-engine hardening. Directional, not a
promise; re-argue freely. Individual features graduate into GitHub issues when work
starts. Settled architecture stays in `docs/adr/` — nothing here overrides an ADR.

## The thesis

Stride's edge is already decided: **deterministic, local-first, honest about provenance,
judgment kept out of the engine**. TrainingPeaks hides its math, intervals.icu is
cloud-locked, Golden Cheetah is powerful but impenetrable. Nobody owns "the engine that
shows its work." Every feature below either widens what the engine can honestly measure
or widens who can feed it data. None of them adds judgment to the engine — reasoning
about the numbers stays with the coach (ADR 0000).

## Tier 1 — trust what you already compute

- **Interval detection.** The engine trusts session *names* and prescriptions; it never
  reads the stream to see what actually happened. Detecting work/rest structure from
  power/pace/HR unlocks the honest versions of three things done by eye today: did a
  VO2 session actually reach its target range; matching activities to prescriptions by
  *content* rather than date; classifying unnamed outdoor rides. Highest leverage on
  this list — it turns adherence from a claim into a measurement.
- **Aerobic decoupling (Pw:HR drift).** First-half vs second-half efficiency within a
  session — the classic aerobic-durability metric. Every input already exists (1 Hz
  power + HR streams). Feeds `activity` and `progress`.
- **Data-quality watchdog in `doctor`.** Streak detection: N consecutive sessions
  without HR, estimated-power rides, junk-filter percentages. The engine already knows;
  it doesn't tell. (Two strap-less rides in a row went unnoticed for two days — that's
  the motivating incident.)

## Tier 2 — ingestion breadth (the "of the world" part)

- **Native FIT import.** The ADR calls Strava "one ingestion layer," but it is the only
  real one. FIT is the lingua franca — Garmin, Wahoo, COROS, trainers. Removes the
  Strava-subscription dependency, gets full-resolution streams (Strava downsamples),
  and is the adoption gate for athletes who don't pay Strava. TCX/GPX ride along
  nearly free.
- **Wellness inputs (resting HR, HRV) as judgment-tier data.** A `stride wellness`
  command plus FIT extraction where devices provide it. The engine stores and trends;
  the *coach* decides what a suppressed HRV means. Slots into the existing
  judgment-tier rules — never wiped by sync.

## Tier 3 — the season, not just the week

- **Ramp-rate guardrails.** CTL ramp per week — the best-validated injury predictor
  computable from data stride holds. Pure arithmetic on `daily_load`, surfaced in
  `summary` as a number, not advice.
- **Event targeting.** `stride event add <date> <name>` → projected CTL/TSB on that
  date given the open plan. Prediction is deterministic arithmetic; whether to change
  the plan stays with the coach.
- **Season view.** `stride season` — blocks, monthly load, polarization per block, FTP
  trajectory over time. Period-accurate thresholds (ADR 0005) make this historically
  truthful, which no competitor can claim.

## Tier 4 — deeper power/pace science

W′ balance (match-burning within rides), time-to-exhaustion from the CP model already
fitted, critical speed as the pace-sport analog of CP, taper modeling. Valuable, but
sequenced last: these refine numbers for athletes who already trust the engine, rather
than widening who can use it.

## Explicitly not doing

- **Multi-athlete / coach views** — breaks the single-user local db that keeps
  everything else simple.
- **Graphs** — that experiment ran and failed; tables + legends + verdicts + the LLM
  coach are the visualization layer.
- **ML predictions** — the engine's identity is deterministic and explainable.
- **Social features** — Strava exists.

## Committed sequence

**FIT import first**, despite Tier 1's leverage: it is the adoption gate, and every
later feature benefits from full-resolution streams. Then interval detection →
decoupling + watchdog → wellness → ramp/event/season → the power-science tier.

Open arguments worth having before work starts: FIT-before-intervals ordering, and how
far wellness scope goes (resting HR + HRV only, or sleep/subjective too).
