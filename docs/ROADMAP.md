# Roadmap — what stride is missing to be The Sports Analytics Engine

Drafted 2026-08-08, second pass same day. Directional, not a promise; re-argue freely.
Features graduate into GitHub issues when work starts. Settled architecture stays in
`docs/adr/` — nothing here overrides an ADR.

## The thesis

Stride's edge is already decided: **deterministic, local-first, honest about provenance,
judgment kept out of the engine**. TrainingPeaks hides its math. intervals.icu is
cloud-locked. Golden Cheetah deserves the fairest comparison — it is open source and
does show its work — but it is a dense desktop GUI built for a human to click through,
not an engine a coach (human or LLM) can script against. The position nobody owns is
"the engine that shows its work *to a machine*": every number traceable to its inputs,
recomputable from raw streams, and emitted as versioned JSON a tool can consume.

Every feature below does one of two things: widens what the engine can honestly measure,
or widens who can feed it data. None of them adds judgment to the engine — reasoning
about the numbers stays with the coach (ADR 0000).

Tiers are ordered: Tier 1 ships before Tier 2. Within a tier, order is open.

## Ground rules for every feature here

These are the existing invariants, restated so no roadmap item forgets them:

- Every new metric input **joins the invalidation story** (`ftp_used` / `zones_used` /
  `metrics_rev`, or row deletion on change) — a number that silently goes stale is worse
  than no number.
- Human-entered data is **judgment-tier**: never a column on a mirror table, never wiped
  by a re-sync.
- Numeric 0 = "not available". The engine never invents a value to fill a gap.

## Tier 1 — ingestion breadth (the "of the world" part)

- **Native FIT import.** The ADR calls Strava "one ingestion layer," but it is the only
  real one. FIT is the lingua franca — Garmin, Wahoo, COROS, every trainer. It removes
  the Strava-subscription dependency, delivers full-resolution streams where Strava
  downsamples, and is the adoption gate for athletes who don't pay Strava. TCX/GPX ride
  along nearly free. The hard part is not parsing: it is **dedupe** — the same ride
  arriving from both a FIT file and a Strava sync must become one activity, not two,
  and the richer stream must win without wiping judgment-tier data. That dedupe story
  needs an ADR before code.
- **Wellness inputs (resting HR, HRV) as judgment-tier data.** A `stride wellness`
  command plus FIT extraction where devices record it. The engine stores and trends —
  shown in `summary` and `week` — and the *coach* decides what a suppressed HRV means.
  Scope question still open: resting HR + HRV only, or sleep and subjective ratings too.

Sequenced first because it gates adoption, and every later feature benefits from
full-resolution streams.

## Tier 2 — trust what you already compute

- **Interval detection.** The engine trusts session *names* and prescriptions; it never
  reads the stream to see what actually happened. Detecting work/rest structure from
  power/pace/HR turns three things done by eye today into measurements: whether a VO2
  session actually reached its target range, matching activities to prescriptions by
  *content* rather than date, and classifying unnamed outdoor rides. Highest-leverage
  single feature on this list — it turns adherence from a claim into a measurement.
- **Aerobic decoupling (Pw:HR drift).** First-half vs second-half efficiency within a
  session — the standard aerobic-durability metric. Every input already exists (1 Hz
  power + HR streams). Feeds `activity` and `progress`.
- **Data-quality watchdog in `doctor`.** Streak detection: consecutive sessions without
  HR, estimated-power rides, junk-filter percentages. The engine already knows; it
  doesn't tell. (Two strap-less rides in a row went unnoticed for two days — that is
  the motivating incident.)

## Tier 3 — the season, not just the week

- **Ramp-rate guardrails.** CTL ramp per week — the best-validated overload signal
  computable from data stride holds. Pure arithmetic on `daily_load`, surfaced in
  `summary` as a number, not advice.
- **Event targeting.** `stride event add <date> <name>` → projected CTL/TSB on that
  date given the open plan. Projection is deterministic arithmetic; whether to change
  the plan stays with the coach.
- **Season view.** `stride season` — blocks, monthly load, polarization per block, FTP
  trajectory over time. Period-accurate thresholds (ADR 0005) mean each block is scored
  against the fitness of its own time. Others model threshold-over-time too; stride's
  claim is narrower and checkable: the whole history recomputes from raw streams, and
  the provenance of every number is visible.

## Tier 4 — deeper power/pace science

W′ balance (match-burning within rides), time-to-exhaustion from the CP model already
fitted, critical speed as the pace-sport analog of CP, and a taper projection built on
the same CTL/TSB arithmetic as event targeting. Valuable, but sequenced last: these
refine numbers for athletes who already trust the engine rather than widening who can
use it.

## Explicitly not doing

- **Multi-athlete / coach views** — breaks the single-user local db that keeps
  everything else simple. An athlete's coach reads their JSON instead.
- **Graphs** — that experiment ran and failed; tables + legends + verdicts + the LLM
  coach are the visualization layer.
- **ML predictions** — the engine's identity is deterministic and explainable. Nothing
  ships that cannot be recomputed by hand from the stored inputs.
- **Social features** — Strava exists.

## Open arguments

Recorded so they get fought on purpose, not settled by default:

1. **FIT-before-intervals ordering.** Tier 1 gates adoption; Tier 2 has more per-user
   leverage. The sequence above picks adoption. Reverse it if the near-term goal is
   depth for current users over reach.
2. **Wellness scope.** Resting HR + HRV are objective and device-measured. Sleep and
   subjective ratings drift toward journaling — worth it only if the coach actually
   consumes them.
3. **FIT dedupe semantics.** Same activity from two sources: which fields win, and
   what does a re-import invalidate? Needs its ADR before any parser work starts.
