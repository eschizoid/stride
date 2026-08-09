# Roadmap — what stride is missing to be The Sports Analytics Engine

Drafted 2026-08-08; amended 2026-08-09 after review. Directional, not a promise;
re-argue freely. Features graduate into GitHub issues when work starts. Settled
architecture stays in `docs/adr/` — nothing here overrides an ADR.

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

## The unsettled question that orders everything

"The Sports Analytics Engine of the world" has two readings, and they produce different
roadmaps:

- **World-class** — the deepest, most honest engine for the athletes already here.
  Then trust features (interval detection, decoupling) come first, ingestion later.
- **World-scale** — an engine anyone can feed regardless of platform. Then FIT import
  comes first, because it gates every athlete who doesn't pay Strava.

The tiers below are grouped by theme and deliberately NOT force-ranked against each
other until this is settled. It is the first thing to grill.

## Ground rules for every feature here

The existing invariants, restated so no roadmap item forgets them:

- Every new metric input **joins the invalidation story** (`ftp_used` / `zones_used` /
  `metrics_rev`, or row deletion on change) — a number that silently goes stale is worse
  than no number.
- Human-entered data is **judgment-tier**: never a column on a mirror table, never wiped
  by a re-sync.
- Numeric 0 = "not available". The engine never invents a value to fill a gap.
- **Reliability is a feature.** An engine that flakes on ingest is not the best engine
  in the world, whatever its math says.

## Quick wins — ship when convenient, regardless of tier

Days-sized each, high value, all on data the engine already holds. These do not wait
behind any tier:

- **Data-quality watchdog in `doctor`.** Streak detection: consecutive sessions without
  HR, estimated-power rides, junk-filter percentages. The engine already knows; it
  doesn't tell. (Two strap-less rides in a row went unnoticed for two days — the
  motivating incident.)
- **Ramp-rate guardrail.** CTL ramp per week — the best-validated overload signal
  computable from data stride holds. Pure arithmetic on `daily_load`, surfaced in
  `summary` as a number, not advice.
- **Sync auto-retry.** Bug C (upstream compiler heap corruption) makes `stride sync`
  fail ~25–50% of the time; the workaround is "run it again". The retry belongs INSIDE
  the binary — sync is idempotent, so retrying internally is safe, honest, and turns
  the engine's worst first impression into a non-event. Upstream bug stays filed;
  users stop meeting it.
- **Aerobic decoupling (Pw:HR drift).** First-half vs second-half efficiency within a
  session — the standard aerobic-durability metric. Every input already exists (1 Hz
  power + HR streams). Feeds `activity` and `progress`.

## Tier: trust what you already compute

- **Interval detection.** The engine trusts session *names* and prescriptions; it never
  reads the stream to see what actually happened. Detecting work/rest structure from
  power/pace/HR turns three things done by eye today into measurements: whether a VO2
  session actually reached its target range, matching activities to prescriptions by
  *content* rather than date, and classifying unnamed outdoor rides. Highest-leverage
  single feature on this list — it turns adherence from a claim into a measurement.

## Tier: ingestion breadth

- **Native FIT import.** The ADR calls Strava "one ingestion layer," but it is the only
  real one. FIT is the lingua franca — Garmin, Wahoo, COROS, every trainer. It removes
  the Strava-subscription dependency, delivers full-resolution streams where Strava
  downsamples, and gates every athlete who doesn't pay Strava. TCX/GPX ride along
  nearly free. Two honest costs, stated up front:
  - **Dedupe is the feature, parsing is the chore.** The same ride arriving from a FIT
    file and a Strava sync must become one activity; the richer stream must win without
    wiping judgment-tier data. Needs an ADR before parser code.
  - **This is the largest single build on the roadmap**, hand-rolling a binary parser
    in a language with no FIT library and an unstable compiler (see the toolchain pin
    in `roc-new-compiler-notes.md`). Scope a minimal decoder (record/lap/session
    messages) first; the format has hundreds of message types we never need.
- **Wellness inputs (resting HR, HRV) as judgment-tier data.** A `stride wellness`
  command plus FIT extraction where devices record it. The engine stores and trends —
  shown in `summary` and `week` — and the *coach* decides what a suppressed HRV means.
  **Contingent: verify a data source exists before building.** Peloton records neither;
  this ships only if the athlete's devices actually produce the data. Scope question
  also open: resting HR + HRV only, or sleep and subjective ratings too.

## Tier: the season, not just the week

- **Event targeting.** `stride event add <date> <name>` → projected CTL/TSB on that
  date given the open plan. Projection is deterministic arithmetic; whether to change
  the plan stays with the coach.
- **Season view.** `stride season` — blocks, monthly load, polarization per block, FTP
  trajectory over time. Period-accurate thresholds (ADR 0005) mean each block is scored
  against the fitness of its own time. Others model threshold-over-time too; stride's
  claim is narrower and checkable: the whole history recomputes from raw streams, and
  the provenance of every number is visible.

## Tier: deeper power/pace science

W′ balance (match-burning within rides), time-to-exhaustion from the CP model already
fitted, critical speed as the pace-sport analog of CP, and a taper projection built on
the same CTL/TSB arithmetic as event targeting. Sequenced last regardless of the
world-class/world-scale answer: these refine numbers for athletes who already trust
the engine.

## Explicitly not doing

- **Multi-athlete / coach views** — breaks the single-user local db that keeps
  everything else simple. An athlete's coach reads their JSON instead.
- **Graphs** — that experiment ran and failed; tables + legends + verdicts + the LLM
  coach are the visualization layer.
- **ML predictions** — the engine's identity is deterministic and explainable. Nothing
  ships that cannot be recomputed by hand from the stored inputs.
- **Social features** — Strava exists.

## Known risks the roadmap inherits

- **The compiler.** Pinned to `nightly-2026-August-04-1cb06bc`; every later nightly
  miscompiles (roc-lang/roc#10693). Roc is pre-1.0 and moving. Every large build here
  (FIT above all) carries this risk; small, well-tested increments are the mitigation.
- **Stream storage.** Raw stream JSON already runs ~70 MB at full backfill; FIT's
  full-resolution streams grow it further. Accepted for now; revisit if it hurts.

## Open arguments

Recorded so they get fought on purpose, not settled by default:

1. **World-class vs world-scale** — settles the tier order. See above.
2. **Wellness scope and source** — resting HR + HRV only, or sleep/subjective too;
   and does a real data source exist for the current athletes?
3. **FIT dedupe semantics** — which fields win, and what does a re-import invalidate?
   Needs its ADR before any parser work starts.
