# Post-#10469 runbook — build UNBLOCKED 2026-08-03; features still ahead

**Status (2026-08-03):** roc#10469 is FIXED (roc#10531, in `nightly-2026-August-03-94cbed3`).
`roc build src/app.roc` now completes (~6m44s). The build-gated plumbing is done; what
remains is the ADR-0003 multi-sport *feature* work (sections 3–6) plus two infra items now
gated on a NEW bug — **the intermittent SIGABRT, issue #32** (heap corruption in the
optimized stream-decode path; `analyze` reliably aborts on a real-sized db). Until #32 is
resolved we can't run e2e in CI or ship binaries. Boxes are the checklist.

## 0. Confirm the build actually completes  ✅ DONE
- [x] `roc build src/app.roc --output=stride` finishes — 6m44s, 0 errors (note `--output=`,
      the new compiler's syntax). The Specialization stall is gone. Two runtime breaks the
      build surfaced were fixed (#30): `UnixBytes` argv decoding, and bare `True` JSON fields
      serializing as the string `"True"`.

## 1. Restore the pipeline  — build works; CI-e2e + release BLOCKED on #32
- [ ] `just test` green locally — **blocked by #32**: `analyze` on a real db aborts, so the
      full e2e can't run clean. (`roc check` + pure `roc test` are green.)
- [ ] Wire `tests/e2e.roc` into CI — **held on #32** (the crash lands at random spots across
      the ~140-check suite → flaky). build.yml is re-pinned to the Aug-03 nightly (#33) and
      the e2e job is staged, commented, ready to un-comment.
- [ ] Re-enable the `release-please.yml` build/upload jobs — **held on #32** (don't ship a
      binary that can abort). Windows unblocks with the working build.

## 2. Merge the parked PRs  ✅ DONE
- [x] **#14** — altitude/distance streams (GAP's input). Merged.
- [x] **#15** — the pace engine (rTSS/sTSS math). Merged earlier.
- [x] Build a fresh binary. (`--opt=dev` is the fallback while #32 blocks the optimized build.)

## 3. ADR 0003 slice 1 — per-sport HR zones + kill `ftp_ride` hardcoding  — FTP half ✅
Highest leverage: makes the HR-native tail (soccer / basketball / tennis) score correctly.
- [ ] `zones_sig` scalar → a per-sport SQL CASE in the invalidation WHERE (mirror the
      existing `sport_ftp_case!`), plus per-row zone resolution in `compute_missing_metrics!`.
- [ ] per-sport `hr_z*_max_<sport>` config keys, with the global `hr_z*_max` as fallback.
- [x] **the `ftp_ride` hardcodes are gone (#26)** — we went further than "change the gate":
      FTP is now *fully derived* per sport (recent best 20-min × 0.95), no config at all.
      `load_zone_config!` requires only HR zones, the `app.roc` Strava-FTP sync is removed,
      and the `zones` gate derives from ride power. A runner never sets a bike FTP.
- [ ] teach `doctor` config-completeness the new key shapes (per-sport HR zones part).
- [ ] schema migration + `metrics_rev` bump (for the per-sport HR zones; the FTP change
      invalidates via `ftp_used` and needed no bump).

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
