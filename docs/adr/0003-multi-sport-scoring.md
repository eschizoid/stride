# ADR 0003 — Multi-sport by design: score the full Strava sport space

Status: proposed (grilled 2026-08-02)

Generalizes [ADR 0002](0002-power-based-intensity.md) (power-based, per-sport intensity)
and the mixed load model of [ADR 0000 §4](0000-architecture.md). 0002 made *intensity*
per-sport for **power** sports; this ADR extends the same "per-sport, best-available
model, no sport rejected" principle to the **whole** sport space — including the
pace-native and HR-native sports 0002's power lens does not serve.

## Context — the mission vs. the reality

The engine is meant to serve **all sports**, driven by a concrete need: the athlete's
friends train sports the current engine can't score honestly — they **run and swim**, and
"everything Strava captures" (soccer, basketball, tennis, hiking, climbing, …). Each
friend **owns their own data** — this is not a multi-athlete request (see Scope boundary).

What the code actually does today (verified 2026-08-02):

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

The team/racket/misc sports that dominate the tail are **HR-intensity sports** — hrTSS is
the *correct* model for them, not a fallback. So the whole space reduces to: **add one
pace rung, make HR zones per-sport, and route every sport to the right rung without ever
rejecting an unknown one.**

## Decision

1. **Score the full sport space.** Every sport gets the best-available model via a complete
   ladder; no sport is rejected or crashes. An unknown/new Strava sport routes to a **safe
   default** (HR-first, then RPE/relative-effort) and is labeled honestly — never silently
   misrouted into a cycling frame.

2. **Add the pace rung.** The ladder becomes `power → pace → HR-zone → session-RPE →
   relative-effort`. Pace load is **rTSS/sTSS built by reusing the existing power
   machinery** — same `IF²·hours·100` shape, pace swapped for watts:
   - **NGP** (normalized graded pace) ↔ NP. This is what **wires the dead GAP code**:
     `grade_adjusted_distance` → normalize → NGP (run).
   - **threshold pace** ↔ FTP, stored per sport as `threshold_pace_<sport>` (mirrors
     `ftp_<sport>`), zero-config-derived from that sport's own best sustained effort.
   - Swim uses **NSS/CSS** (normalized swim speed vs critical swim speed); no grade term.

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
   (`Analyze.load_zone_config!`, the Strava FTP sync, the `Report.roc` gate) so the
   "generic" layer is actually generic.

## Scope boundary (load-bearing — do not drift)

**stride stays single-user, local-first.** "Support all my friends" means the **engine**
scores every friend's sports correctly — each friend **owns their own db** ("SQLite you
own"), runs their own instance, or has their export analyzed in a separate db. **Multi-
athlete / multi-tenant on one instance is explicitly OUT of scope** — it's a different
product (per-athlete isolation, config namespacing, per-athlete tokens) and would break
0000's local-first principle. Do not entangle sport-completeness with tenancy.

## Consequences

- **Gives the dead GAP code a job** (NGP), and removes it as a maintained liability.
- New config keys and new `activity_metrics` inputs need a schema change + a recompute —
  see **Migration story** below. It is deliberately **not** a data backfill.
- `Metrics.sport_class`'s boolean widens (or is subsumed) by the `intensity_model` routing;
  `sport_class`-dependent reporting (strength-unrated nudges) migrates onto it.
- The honesty caveat from ADR 0002 carries over intact: pace/HR/CSS numbers are only as
  good as the thresholds feeding them — **trust the direction, not the decimals**, and
  caveat estimated thresholds.

## Migration story (three tiers, per ADR 0000 — only one is a real migration)

The three-data-tiers design means this large capability change touches disk in a
deliberately small way. Do **not** write a data-transform migration for the metrics.

1. **Schema migration — YES (the only hand-written one).** New `activity_metrics` inputs —
   `ngp` / `threshold_pace_used` (pace analog of `ftp_used`) and the pace/zone entries in
   the `zones_used` / model signature — are new columns. Add them, bump `schema_version`,
   append the `ALTER`/rebuild to `run_migrations!` (ADR 0000 §schema). Pre-1.0 the schema
   is not a stable contract, so DROP+recreate the computed tables is fair game if simpler.

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

1. **Per-sport HR zones + remove `ftp_ride` hardcoding.** Highest leverage: it makes the
   whole HR-native majority (the long tail of Strava sports) score correctly *immediately*,
   and is smaller than the pace rung.
2. **Run rTSS.** Wire GAP → NGP, add `threshold_pace_run` (+ zero-config derivation), route
   `model_run = pace`.
3. **Swim sTSS/CSS.** `threshold_pace_swim` as CSS; no grade term; deprioritize swim HR
   (wrist HR in water is unreliable).

Each slice is independently shippable and independently useful.
