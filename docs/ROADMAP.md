# Roadmap — what stride is missing to be The Sports Analytics Engine

Drafted 2026-08-08; amended 2026-08-09 after review, then grilled — settled
decisions are marked inline. Directional, not a promise;
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

## Settled 2026-08-09: both, interleaved — world-class in the foreground

"World-class vs world-scale" got grilled and the answer is both tracks at once:

- **Foreground:** quick wins, then interval detection — depth for the athletes already
  here, shipping value weekly.
- **Background:** the FIT dedupe ADR (pure thinking, no compiler risk), then a minimal
  decoder SPIKE (record/lap/session messages only, one real file) that retires the
  Roc-parses-binary risk BEFORE any product commitment. If the spike fights the
  compiler, a week is lost, not a quarter.

Review bandwidth is the real constraint — one maintainer approves every PR — so the
background track stays cheap until the spike says otherwise.

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
- **Observable sync + analyze (with auto-retry).** Both commands are silent until they
  finish — a 72 s full rescore reads as a hang (a healthy analyze got killed for
  exactly that), and a mid-run sync death says nothing about how far it got. Progress
  narration goes to **stderr** (`rescoring 128/723…`, `fetching streams 14/60…`) so the
  stdout JSON envelope stays a single deterministic payload and golden fixtures are
  untouched. Failures inherit context from the narration (`failed fetching streams for
  <id>, attempt 2/3`). Bug C retries happen INSIDE the binary — sync is idempotent —
  capped at 3, loud failure after, and counted in the summary (`synced 22 (2 retries)`)
  so the upstream bug's frequency stays visible.
- **Aerobic decoupling (Pw:HR drift).** First-half vs second-half efficiency within a
  session — the standard aerobic-durability metric. Every input already exists (1 Hz
  power + HR streams). Feeds `activity` and `progress`.

## Tier: trust what you already compute

- **Interval detection** — grilled 2026-08-09; the design is settled:
  - **The detector reports; it never acts.** Output is structure on `activity`
    (`5×[3:01 @ 258W / 3:04 easy]`) — matching it to a prescription stays a coach/human
    act. Auto-completing (or even emitting match candidates) was rejected: prescriptions
    are free text, so structure-matching would mean parsing prose, which is judgment.
    If structured prescription targets ever earn their way in, re-argue then.
  - **Power and pace place edges; both ship in v1.** One signal-agnostic detector
    (smooth → sustained-level-shift segmentation → min-duration filter, deterministic).
    Power covers rides AND rows; the existing 1 Hz grade-adjusted speed stream covers
    runs and swims with conservative thresholds. No scored sport with a measured signal
    is left out.
  - **HR never places edges — it enriches them.** HR lags effort by 30+ s, so HR-derived
    edges would be fiction. Inside detected segments HR is gold: per-rep peak/avg,
    drift across reps (fatigue signature), post-rep recovery rate (a validated fitness
    marker), and corroboration that target watts produced the expected physiological
    cost. HR-only sessions detect nothing; `hard_s`/zones already tell their story.

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
- **Wellness inputs (resting HR, HRV) as judgment-tier data.** The likely source is an
  **Apple Health export** (Settings → Health → Export All Health Data — a local zip,
  no API, no OAuth; stream-parse the XML, never load it whole), which fits stride's
  local-first shape better than FIT extraction. But Apple Health only holds these
  metrics if a wearable records them — an iPhone alone does not. **Contingent on a
  real source: pending homework, does anyone in the circle sleep with a watch on?**
  Manual export makes this a trend tool, not a daily readiness signal. Engine stores
  and trends, shown in `summary`/`week`; the coach interprets. Scope still open:
  resting HR + HRV only, or sleep too.

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

1. ~~World-class vs world-scale~~ — settled: both, interleaved, world-class foreground.
2. **Wellness source (homework)** — does anyone in the circle wear a watch overnight?
   Determines whether wellness ships at all. Scope (sleep? subjective?) waits on that.
3. **FIT dedupe semantics** — which fields win, and what does a re-import invalidate?
   Needs its ADR before any parser work starts.
4. **Structured prescription targets** — parked, not planned. Would make detection-to-
   prescription matching honest arithmetic, at the cost of rigid prescribing. Re-argue
   only if free-text reconciliation actually starts failing in practice.
