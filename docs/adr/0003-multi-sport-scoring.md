# ADR 0003 — Multi-sport by design: score the full Strava sport space

Status: accepted (grilled + fleet-reviewed 2026-08-02)

Generalizes [ADR 0002](0002-power-based-intensity.md) (power-based, per-sport intensity)
and the mixed load model of [ADR 0000 §4](0000-architecture.md). 0002 made *intensity*
per-sport for **power** sports; this ADR extends the same "per-sport, best-available
model, no sport rejected" principle to the **whole** sport space — including the
pace-native and HR-native sports 0002's power lens does not serve.

**Reverses ADR 0000 §10**, which listed "a generic every-sport model" as *deliberately
out of scope, revisited only when dogfooding demands*. Dogfooding demands it (friends run
and swim), so §10 is updated in the same commit. The single-user/local-first boundary of
§1 is untouched (see Scope boundary).

## Context — the mission vs. the reality

The engine is meant to serve **all sports**, driven by a concrete need: the athlete's
friends train sports the current engine can't score honestly — they **run and swim**, and
"everything Strava captures" (soccer, basketball, tennis, hiking, climbing, …). Each
friend **owns their own data** — this is not a multi-athlete request (see Scope boundary).

What the code did when this was written (verified 2026-08-02 — **every bullet below is
now HISTORY; see the amendment after the list**):

- The load ladder is `power → HR → session-RPE → relative-effort` (`Metrics.tss_ladder`).
  There is **no pace rung**. Running and swimming without a power meter — the common case —
  fall straight to hrTSS, i.e. they're scored by the metric that misreads them: HR lags on
  intervals and is depressed in water.
- **GAP is dead code.** `Metrics.grade_adjusted_distance` / `minetti_ratio` (Minetti 2002)
  and `Streams.dist_alt_pairs` are built and expect-tested but have **zero call sites**.
- **HR zones are global.** One `ZoneBounds` (four `hr_z*_max` keys) for every sport — no
  per-sport LTHR, which is physiologically wrong across bike/run/swim for one athlete.
- **Cycling favoritism leaks through the "generic" layer**: `ftp_ride` is hardcoded in the
  zone-config bundle (`Analyze.load_zone_config!`), the Strava FTP sync (`app.roc`), and a
  command gate (`Report.roc`).

### The reframe that makes "all sports" tractable

"Everything Strava captures" is ~50 sport types, but they collapse into **four scoring
models** — and three of the four already exist:

| model | sports | status |
|---|---|---|
| **power** (NP/IF/TSS vs FTP) | cycling, power-metered rowing | ✅ have it (ADR 0002) |
| **pace** (rTSS/sTSS) | **running, swimming** | ❌ the one genuinely-new rung |
| **HR-zone** (hrTSS from time-in-zone) | **soccer, basketball, tennis**, hike, and the long tail | ✅ works — needs per-sport zones |
| **RPE / relative-effort** | strength, yoga, skill; final fallback | ✅ have it |

The team/racket/misc sports that dominate the tail are **HR-driven sports** — hrTSS is the
**best-available** model given HR-only consumer data (not a mere fallback), with known
biases we must not oversell: HR lag smears burst/rest intervals into the mid-zones, it
misses mechanical/neuromuscular load (accels, jumps, cuts — the real cost of team sports),
and the roughly-linear per-zone coefficients under-weight the Z4/Z5 spikes those sports
live in. Session-RPE is arguably a **peer**, not a lower fallback, for team/racket sports —
worth ranking RPE alongside HR there specifically. Still, the space reduces to: **add one
pace rung, make HR zones per-sport, and route every sport to a sensible rung without ever
rejecting an unknown one.**


**Amended 2026-08-17 — all four bullets above have been fixed, and the sequencing shipped.**

- The **pace rung exists**: `Metrics.tss_ladder` takes an `ngp` and a `threshold_speed` and
  interposes `pace_or_fallback`, with per-sport exponents (`Sports.pace_tss_exponent` — run
  2, swim 3). The ladder is now power → pace → HR → session-RPE → relative-effort.
- **GAP is live**, not dead: `minetti_ratio` and `grade_adjusted_speeds` feed
  `normalized_graded_pace`. (`grade_adjusted_distance` genuinely is still unused outside
  expects, exactly as this ADR predicted.)
- **HR zones are per-sport**: `hr_z<n>_max_<sport>` via `Metrics.hr_zone_key`, with a
  per-sport `zones_used` signature driving invalidation.
- **The cycling favoritism is gone**: `ftp_ride` appears nowhere outside a v10 migration
  and the config-refusal policy.

**One piece of Decision 5 did NOT ship.** 5(a) said the analyze gate becomes "has any
usable threshold/zone for the sports present"; `Analyze.load_zone_config!` still
hard-requires all four GLOBAL `hr_z1..z4_max` keys and returns `Err(MissingConfig)`
otherwise, so an athlete carrying only per-sport zones is still refused `analyze`. That is
the one live item left in this ADR.
## Decision

1. **Score the full sport space.** Every sport gets the best-available model via a complete
   ladder; no sport is rejected or crashes. An unknown/new Strava sport routes to a **safe
   default** (HR-first, then RPE/relative-effort) and is labeled honestly — never silently
   misrouted into a cycling frame.

2. **Add the pace rung.** A pace rung joins the ladder for pace-native endurance sports:
   `power → pace → HR-zone → session-RPE → relative-effort`. **Ordering stays
   sport-class-conditional** — power still wins whenever a power stream is present, and
   StrengthLike still ranks session-RPE above HR (ADR 0000 §4, `Metrics.tss_ladder`); the
   pace rung slots in for endurance sports without a power stream. Pace load is
   **rTSS/sTSS** (the TrainingPeaks model), built by reusing the `IF²·hours·100` machinery —
   but the naïve "swap watts for pace" hides two corrections that would otherwise produce a
   *wrong* number:
   - **NGP is a normalized speed *stream*, not a scalar.** Normalized Graded Pace applies
     NP's own 30 s-rolling + 4th-power weighting (`normalized_power`, already generic over
     `List(F64)`) to a **grade-adjusted instantaneous speed stream** (grade factor per
     sample × per-sample speed). The existing `grade_adjusted_distance` collapses the whole
     activity to one flat-equivalent **scalar** — the *wrong shape* for NGP; dividing it by
     time yields *average* graded pace and discards exactly the surge/hill variability
     normalization exists to capture. So the real work is **add a grade-adjusted-speed-
     stream producer** (reuse `minetti_ratio` per sample) and feed it through
     `normalized_power` — not "call the dead scalar GAP function."
   - **IF must not invert.** stride carries pace as **seconds/km** (`Render.pace_per_km`),
     where faster = *smaller*. So pace intensity is `IF = threshold_pace / NGP` (or convert
     both to speed first) — **NOT** `NGP / threshold_pace`, which is the power form and would
     score hard efforts *easy*. `threshold_pace_<sport>` mirrors `ftp_<sport>`, zero-config-
     derived from a **stored best-sustained-pace column** (the pace analog of `best_20min_w`;
     protocol is per-sport — run ≈ best ~30-60 min pace, swim CSS from a 400/200 pair).
   - Swim uses **NSS/CSS** (normalized swim speed vs critical swim speed); no grade term.
     Caveat: 25 m / 50 m / open-water paces are **not comparable**, so a CSS derived from
     mixed pool-contexts won't transfer — scope CSS per pool-context or flag the mix.

3. **Route via config, not a hardcoded taxonomy.** A per-sport `intensity_model` key
   (`model_<sport>` ∈ {power, pace, css, hr, rpe}) selects the rung, shipped with a small
   **built-in default map** and user-overridable. Defaults are a convenience, **not a gate**
   — an unmapped sport still works via the safe default. This keeps ADR 0002's "no sport is
   dropped, adding a sport needs no code" promise.

4. **HR zones become per-sport.** Per-sport zone keys (`hr_z*_max_<sport>`, or a per-sport
   LTHR that derives them) with the current global `hr_z*_max` as fallback. This is what
   makes the HR-native majority (soccer/basketball/tennis) *accurate*, and lets run/swim
   carry their own LTHR for the HR fallback path.

5. **Kill the cycling favoritism.** Remove the hardcoded `ftp_ride` special-cases
   (`Analyze.load_zone_config!`, the Strava FTP sync in `app.roc`, the `Report.roc` command
   gate) so the "generic" layer is actually generic. Two things to handle, not just delete:
   (a) `load_zone_config!` also returns `Err(MissingConfig)` when `ftp_ride` is unset — a
   **behavior change**, not just code cleanup: a runner with no bike FTP must still be able
   to `analyze`, so the gate becomes "has *any* usable threshold/zone for the sports
   present," not "has `ftp_ride`"; (b) summary's FTP calibration is a 4th consumer of
   `cfg.ftp` (`Report.roc` summary path) that must read the per-sport key.

## Scope boundary (load-bearing — do not drift)

**stride stays single-user, local-first.** "Support all my friends" means the **engine**
scores every friend's sports correctly — each friend **owns their own db** ("SQLite you
own"), runs their own instance, or has their export analyzed in a separate db. **Multi-
athlete / multi-tenant on one instance is explicitly OUT of scope** — it's a different
product (per-athlete isolation, config namespacing, per-athlete tokens) and would break
0000's local-first principle. Do not entangle sport-completeness with tenancy.

## Consequences

- **Gives the GAP theory a job** — `minetti_ratio` becomes the per-sample grade factor
  feeding the new NGP speed stream (the scalar `grade_adjusted_distance` is *not* the NGP
  input; see Decision 2), retiring the dead code as a real dependency.
- New config keys and new `activity_metrics` inputs need a schema change + a recompute —
  see **Migration story** below. It is deliberately **not** a data backfill.
- **`intensity_model` and `sport_class` are orthogonal — do NOT fold them.** `intensity_model`
  picks the *rung*; `sport_class` sets *fallback priority* (StrengthLike ranks RPE above HR,
  but power still wins if present). Collapsing sport_class into `model_<sport>` would regress
  "a rated strength session with real watts is still measured." Both stay.
- **Intensity, not just load, must go per-pace** — or ADR 0002 regresses. The easy/moderate/
  hard split + polarization read power-intensity and fall back to **HR zones** when power is
  absent, so a pace-scored run/swim would fall to HR and re-introduce the exact threshold-
  mislabeling 0002 killed. A pace-intensity (`pi_*` analog, from pace zones vs threshold
  pace) is required — not just the pace *load* columns; per-sport HR zones do not fix it.
- The honesty caveat from ADR 0002 carries over intact: pace/HR/CSS numbers are only as
  good as the thresholds feeding them — **trust the direction, not the decimals**, and
  caveat estimated thresholds.

## Migration story (three tiers, per ADR 0000 — only one is a real migration)

The three-data-tiers design means this large capability change touches disk in a
deliberately small way. Do **not** write a data-transform migration for the metrics.

1. **Schema migration — YES, and it's more than columns.** New `activity_metrics` columns:
   `ngp` + `threshold_pace_used` (pace analogs of NP + `ftp_used`), a **pace-intensity**
   `pi_*` set (analog of the power-intensity split — see Consequences), and a **best-
   sustained-pace** column (analog of `best_20min_w`, so `threshold_pace_<sport>` can
   zero-config-derive). Bump `schema_version`, append to `run_migrations!`. But two
   "additive" decisions are really the **same scalar→per-sport-CASE plumbing FTP already
   needed**, not just columns:
   - *Per-sport HR zones* (Decision 4): `compute_missing_metrics!` threads one global
     `ZoneBounds` and compares a scalar `zones_sig(zb)` in its invalidation WHERE — making
     zones per-sport needs a `zones_sig_case!` SQL CASE (like `sport_ftp_case!`) + per-row
     `zb` resolution, else rows never invalidate or recompute every run.
   - *Pace provenance* (Decision 2): new `load_model` strings (`ngp`/`rtss`/`css`) must join
     **every** `load_model IN(...)` list in `Report.roc` — the *measured* set, the `doctor`
     confidence tiers, and the catch-all → `non` bucket — declared **high (measured)** like
     power; miss it and GPS-measured pace silently reports as *unmeasured*. `doctor`'s
     config-completeness (exact `hr_z*_max` list + `ftp_` prefix) must also learn the new
     `hr_z*_max_<sport>` / `model_<sport>` keys.

2. **Computed data — RECOMPUTE, do not transform.** `activity_metrics` and `daily_load` are
   the disposable computed tier: **bump the `metrics_rev` constant** and the next `analyze`
   rebuilds every row under the new ladder/model. No backfill script, no data transform —
   the recompute-invalidation story (`ftp_used`/`zones_used`/`metrics_rev` + the new pace/
   threshold inputs, all compared in `compute_missing_metrics!`) does it for free. Any new
   metric input MUST be added to that WHERE-clause comparison or it won't invalidate.

3. **Mirror data — RE-PULL if a field is missing.** `activities`/`streams` are re-pullable.
   GAP needs distance + altitude streams, which are **already stored and backfilled**; only
   if some sport lacks a needed stream field does a `sync full` re-pull cover it.

4. **Config data — MINIMAL, non-destructive.** New keys (`threshold_pace_<sport>`,
   `model_<sport>`, per-sport HR zones) are born empty → defaults / zero-config derivation.
   The global `hr_z*_max` keys **stay** as the fallback — no destructive move. The only
   real key rename in this space is the existing `ftp`→`ftp_ride` (schema v10), which is the
   template if any key ever must move. Removing the `ftp_ride` code-hardcoding (Decision 5)
   changes **code, not config data**.

## Sequencing (tracer bullets — ship in this order)

> The build is unblocked (roc-lang/roc#10469, fixed upstream by roc-lang/roc#10531). This ADR is the
> durable sequencing; the live, disposable working checklist (in-flight PRs, watch-items)
> lives in the gitignored `.claude/PLAN.md` scratch, not here. Slice 1 (per-sport HR zones)
> resolves the zone half of Decision 4 + the `ftp_ride` removal of Decision 5.


1. **Per-sport HR zones + remove `ftp_ride` hardcoding.** Highest leverage: it makes the
   whole HR-native majority (the long tail of Strava sports) score correctly *immediately*,
   and is smaller than the pace rung.
2. **Run rTSS.** Wire GAP → NGP, add `threshold_pace_run` (+ zero-config derivation), route
   `model_run = pace`.
3. **Swim sTSS/CSS.** `threshold_pace_swim` as CSS; no grade term; deprioritize swim HR
   (wrist HR in water is unreliable).

Each slice is independently shippable and independently useful.
