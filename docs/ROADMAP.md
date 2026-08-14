# Roadmap — what stride is missing to be The Sports Analytics Engine

Drafted 2026-08-08; amended 2026-08-09 after review, then grilled; status refreshed
2026-08-13 against what actually shipped — settled decisions are marked inline. Directional, not a promise;
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

**Applied backwards, 2026-08-13 (#123 — SHIPPED in #127):** the rule caught something
already in main. The `form` verdict line ended in advice ("favor easy work"), a
prescription derived from a single scalar. It repeated for 17 straight days, and worse, it
was WRONG — it told an athlete to go easy through a fortnight that was 81% easy with no
hard session in nine days, because TSB alone cannot see intensity distribution. The labels
now name the state and say how long it has held ("balanced, 16 days in this band" — with a
`+` when the count is truncated by the window rather than ended by a band change). Worth
re-reading this thesis against anything that emits words rather than numbers.

## Settled 2026-08-09: both, interleaved — world-class in the foreground

"World-class vs world-scale" got grilled and the answer is both tracks at once:

- **Foreground:** quick wins, then interval detection — depth for the athletes already
  here, shipping value weekly.
- **Background:** wellness-via-Apple-Health, pending its homework. (The FIT track was
  retired later the same day — see the ingestion tier: Strava is the parser.)

Review bandwidth is the real constraint — one maintainer approves every PR — so the
background track stays cheap.

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
- **The ingestion boundary is the filesystem.** Where a device uploads its data —
  Garmin Connect, Wahoo, Peloton's servers — is between the athlete and their vendor,
  not stride's business. Stride reads files the athlete puts on disk (bulk export, USB —
  Garmin devices mount as a disk with `Activities/*.fit` — email, anything). Strava
  stays as the one grandfathered API because it exists and is an aggregator; no other
  vendor-cloud integration ships, ever. This is one sentence that deletes an entire
  category of scope.

## Quick wins — ship when convenient, regardless of tier

Days-sized each, high value, all on data the engine already holds. These do not wait
behind any tier.

**Status 2026-08-13:** the watchdog, the ramp guardrail, observable commands and aerobic
decoupling have all landed. What is left of this tier is the pace variant of decoupling
and the in-binary sync retry, both noted inline below.

- **~~Data-quality watchdog in `doctor`~~ — SHIPPED (#92).** Streak detection: consecutive sessions without
  HR, estimated-power rides, junk-filter percentages. The engine already knows; it
  doesn't tell. (Two strap-less rides in a row went unnoticed for two days — the
  motivating incident.)
- **~~Ramp-rate guardrail~~ — SHIPPED (#93).** CTL ramp per week — the best-validated overload signal
  computable from data stride holds. Pure arithmetic on `daily_load`, surfaced in
  `summary` as a number, not advice.
- **~~Observable sync + analyze~~ — SHIPPED (#91), EXCEPT the in-binary retry.** Both commands were silent until they
  finish — a 72 s full rescore reads as a hang (a healthy analyze got killed for
  exactly that), and a mid-run sync death says nothing about how far it got. Progress
  narration goes to **stderr** (`rescoring 128/723…`, `fetching streams 14/60…`) so the
  stdout JSON envelope stays a single deterministic payload and golden fixtures are
  untouched. Failures inherit context from the narration (`failed fetching streams for
  <id>, attempt 2/3`). Human mode gets a live progress bar —
  `rescoring [██████████░░░░]  358/723` — reusing the table bar's `█` glyph and redrawn
  with `\r`; machine/CI mode gets plain appended lines, because carriage returns are
  garbage in logs and basic-cli exposes no tty check. The existing output-mode switch
  is the selector — same information, dressed for the reader.
  **The in-binary retry is now moot in its original form:** it existed to absorb bug C,
  and bug C is fixed (#105 closed — see Risks). Transient network failures are the only
  remaining retry case; whether that earns an in-binary retry at all should be re-argued
  from a clean sheet rather than inherited from the bug-C era. The `just e2e-sync` 5×
  shell retry is already gone — measured 10/10 clean unretried on 0.22.0, so the crutch
  was deleted the same day the bug was; a future flake there fails loudly on purpose.
- **~~Aerobic decoupling (Pw:HR drift)~~ — SHIPPED for POWER (#94/#125).** First-half vs
  second-half efficiency within a session. Stored as a NULLABLE `decoupling_pct` with a
  paired `decoupling_known` flag, because 0.0 is a legitimate perfect result here and the
  house "0 = not available" rule cannot carry that distinction on its own.
  **Still open: the pace variant.** It needs the grade-adjusted stream `rTSS` consumes,
  which is derived further down the same function; wiring it in place would duplicate that
  derivation or reorder the function. Deferred deliberately — a wrong drift number on every
  run is worse than none. `progress` integration also still pending; it feeds `activity`
  only today.
  **Reading caveat worth carrying:** decoupling only means "aerobic durability" on a
  STEADY effort. On a structured interval session a high number reflects the workout's
  shape, not the athlete's ceiling.

## Tier: trust what you already compute

- **Interval detection — IMPLEMENTED (#95 / ADR 0008, PR #132 in review; release gated
  on validating against the maintainer's own threshold session).** The engine now reads
  the stream: `stride activity` renders `shape 9×[2:07 @ 238W / 1:20 easy]` with per-rep
  HR (peak/avg, 60s recovery drop) and a drift verdict; JSON carries
  `segments`/`interval_summary`/`hr_drift` additively. `activity_segments` is
  computed-tier, invalidated exactly like `activity_metrics`, parameters versioned by
  `metrics_rev`. Real-session behavior so far: steady rides and HR-only sessions
  honestly detect nothing; a song-driven ride detects its 9 surges with
  physiologically-correct HR. The settled design it implements:
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

- **~~Native FIT import~~ — settled 2026-08-09: Strava is the parser.** Every vendor
  already syncs to Strava; Strava normalizes a hundred device formats into the two
  outputs stride already reads — API JSON and the bulk export. Stride never parses a
  raw device format (FIT/TCX/GPX); the dedupe ADR and decoder spike die with this,
  taking the roadmap's largest build and its biggest compiler risk with them. The
  facts behind the call: paid and free Strava serve the SAME data with full retention —
  the June-2026 change only gated *holding API credentials* behind a subscription, and
  the bulk export stays free for everyone. Two prices, paid knowingly:
  - **The free path stays summary-level.** The export's stream data lives in original
    device files stride declines to parse, so import users get CSV summaries — no
    zones, NP, or detection on that history. Full-resolution stride = the API path.
  - **Single-artery dependence.** Re-argue this decision only if Strava squeezes terms
    again, or a real user arrives who cannot use Strava at all.
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
- **Vendor-cloud integrations** (Garmin Connect, Wahoo, Peloton APIs, ...) — see the
  filesystem ground rule.
- **Raw device-format parsing** (FIT/TCX/GPX) — Strava is the parser; stride ingests
  its two outputs. Re-argue clause lives in the ingestion tier.

## Known risks the roadmap inherits

- **The compiler.** Pinned to `nightly-2026-August-04-1cb06bc`; every later nightly
  miscompiles (roc-lang/roc#10693). Roc is pre-1.0 and moving. Small, well-tested
  increments are the mitigation.
  **Re-tested 2026-08-13 against `nightly-2026-08-11-56acb9b`: still broken**, so the pin
  stands. One thing did change — the `match`-wrapped case no longer takes the compiler
  down with SIGSEGV, it now compiles and fails at runtime instead. The miscompile itself
  is untouched: a program still builds with `0 errors and 0 warnings` and crashes when
  run, which is the worst shape of the bug. Also observed: `roc build` can die with
  SIGILL/SIGSEGV and no diagnostics on code `roc check` rejects cleanly, so **`roc check`
  before `roc build` on any new file**.
- **~~Bug C~~ — FIXED end to end (#105, closed 2026-08-14).** The heap corruption that
  accused HTTP for months was a DOUBLE-FREE in basic-cli 0.21's SQLite host: the platform
  dropped every element of a bindings list after use and the generated caller dropped
  them again, so a heap-allocated `Str` in bindings corrupted whatever recycled the
  memory — surfacing at a LATER host call under rotating masks. Root-caused with a
  45-line reproducer made deterministic by guard-malloc, reported upstream
  (basic-cli#471), fixed upstream in ~2 hours (#472), released same day as 0.22.0, and
  consumed here (#131). The one-day workaround (#130, splice text as quoted literals)
  was fully reverted — bindings are the right channel again. Lessons the repo keeps
  (AGENTS.md): a crash at a host boundary names where damage LANDED, not where it came
  from; guard-malloc early; and the e2e mock's short fixture strings made it
  structurally blind to this bug class, so **sync decode/bind changes are verified
  against real Strava data before being called working** — that rule outlives the bug.
- **Stream storage.** Raw stream JSON already runs ~70 MB at full backfill; FIT's
  full-resolution streams grow it further. Accepted for now; revisit if it hurts.

## Open arguments

Recorded so they get fought on purpose, not settled by default:

1. ~~World-class vs world-scale~~ — settled: both, interleaved, world-class foreground.
2. **Wellness homework** — does anyone in the circle wear a watch overnight? Gates
   wellness entirely.
3. ~~FIT dedupe semantics~~ — moot; the FIT track was retired (Strava is the parser).
4. **Structured prescription targets** — parked, not planned. Would make detection-to-
   prescription matching honest arithmetic, at the cost of rigid prescribing. Re-argue
   only if free-text reconciliation actually starts failing in practice.
