# Post-#10469 runbook — what to do when the native build unblocks

The multi-sport engine ([ADR 0003](adr/0003-multi-sport-scoring.md)) and native binaries
are all gated on ONE upstream compiler bug: **roc-lang/roc#10469** — `roc build
src/app.roc` stalls the Specialization phase for minutes. `roc check` / `roc test` still
work (they stop before that phase), so pure code + tests ship now; everything that needs a
built binary waits here. When #10469 is fixed — or the loop-rewrite lead unblocks it — run
this in order. Boxes are the checklist.

## 0. Confirm the build actually completes
- [ ] `roc build src/app.roc --output stride` finishes (no minutes-long stall).
  - If it STILL stalls, the upstream fix didn't hit our case. Try the lead: rewrite the
    recursive `fetch_pages!` / `upsert_all!` in `src/Strava.roc` as `List.walk` / `for_each`
    loops and re-measure — recursion-wrapping-generics was the worst specializer amplifier.
    Full characterization: the upstream issue `roc-lang/roc#10469` and `MIGRATION.md`.

## 1. Restore the pipeline
- [ ] `just build` + `just test` green locally (the e2e suite now runs against a fresh build,
      not the frozen binary).
- [ ] Wire `tests/e2e.roc` into CI (`.github/workflows/build.yml`) — run the full suite
      (offline + `E2E_MODE=sync`/`mock`) against a freshly-built binary. Closes the standing
      "e2e not in CI" gap.
- [ ] Re-enable the `release-please.yml` build/upload jobs (currently `if: false`) → binaries
      reattach (linux x86_64/arm64, macOS arm64/intel) **+ Windows** (new compiler unlocks it).

## 2. Merge the parked PRs
- [ ] **#14** — request `altitude,distance` streams (GAP's input). New syncs carry altitude.
- [ ] **#15** — the pace engine (`normalized_graded_pace`, `pace_tss`, `grade_adjusted_speeds`;
      pure, tested rTSS/sTSS math).
- [ ] Build + install a fresh binary.

## 3. ADR 0003 slice 1 — per-sport HR zones + kill `ftp_ride` hardcoding
Highest leverage: makes the HR-native tail (soccer / basketball / tennis) score correctly.
- [ ] `zones_sig` scalar → a per-sport SQL CASE in the invalidation WHERE (mirror the
      existing `sport_ftp_case!`), plus per-row zone resolution in `compute_missing_metrics!`.
- [ ] per-sport `hr_z*_max_<sport>` config keys, with the global `hr_z*_max` as fallback.
- [ ] remove the `ftp_ride` hardcodes (`Analyze.load_zone_config!`, the `app.roc` Strava FTP
      sync, the `Report.roc` command gate). The "must set FTP before analyze" gate becomes
      "has any usable threshold/zone for the sports present" (a runner needs no bike FTP).
- [ ] teach `doctor` config-completeness the new key shapes.
- [ ] schema migration + `metrics_rev` bump.

## 4. ADR 0003 slice 2 — wire the pace engine into scoring (runs)
- [ ] Add the pace rung to `Metrics.tss_ladder` / `Analyze.compute_one!`, using #15's
      `normalized_graded_pace` + `pace_tss`. **Resample time/dist/alt to 1 Hz first** with
      the existing `Metrics.resample_1s` (the 30-sample NP window is only 30 s at 1 Hz), and
      **filter the three streams as ONE aligned unit** (the nested `map2` truncates to the
      shortest — build a `dist_alt_time` triple helper in `Streams.roc`).
- [ ] **STORE the result — don't recompute on read.** NGP/rTSS are computed-tier: add
      columns to `activity_metrics` (`ngp`, `threshold_pace_used` — the pace analog of
      `ftp_used`, the `pi_*` pace-intensity split, and a stored best-sustained-pace column
      that is the analog of `best_20min_w` for zero-config threshold derivation). The
      expensive stream→GAP→NGP pass runs once at `analyze` and persists, exactly like the
      power path stores `np`/`tss`; reads never recompute. Join every new input to the
      `ftp_used` / `zones_used` / `metrics_rev` invalidation story.
- [ ] `threshold_pace_<sport>` config + zero-config derivation from the stored best-pace column.
- [ ] `pi_*` pace-intensity split (from pace zones) — REQUIRED, or a pace-scored run falls
      back to HR intensity and re-breaks ADR 0002's threshold-mislabeling fix.
- [ ] new `load_model` strings (`ngp` / `rtss`) added to EVERY `load_model IN(...)` list in
      `Report.roc` — the measured set, the doctor confidence tiers, and the catch-all — as
      **high (measured)** confidence. Miss one and GPS-measured pace reports as *unmeasured*.
- [ ] config-driven `intensity_model` routing (`model_<sport>`), kept **orthogonal** to
      `sport_class` — don't fold them (a rated strength session with real watts must stay
      measured).
- [ ] backfill altitude for existing runs: add the `stride backfill --refetch <sport>` flag
      (pinned on #14), or the manual `DELETE FROM streams WHERE activity_id IN (…run/hike…)`
      then `stride backfill`.

## 5. ADR 0003 slice 3 — swim sTSS/CSS
- [ ] `threshold_pace_swim` = CSS (scope per pool-context — 25 m / 50 m / open-water don't
      transfer); no grade term; deprioritize swim HR (unreliable in water).
- [ ] Verify the IF exponent vs TrainingPeaks sSS — speed-based IF² under-scores hard swims
      (drag ≈ v³); see the caveat on `Metrics.pace_tss`.

## 6. Ship
- [ ] `just test` (full) + the schema-migration test + a real altitude backfill against Strava.
- [ ] Cut a release (binaries + Windows). Record the unblock in `MIGRATION.md`.

---
Each slice (3, 4, 5) is independently shippable, so friends get value incrementally:
HR-native sports first, then running, then swimming.
