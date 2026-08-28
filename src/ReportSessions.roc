# ── what happened: individual sessions and their comparisons ────────
#
# Split from Report.roc under ADR 0001. activity_body! (378) and reps! (246)
# had both passed the ~250-line command trigger.
#
# Report.sport_filter_sql and Report.cp_fit_as_of! stay in Report.roc and are called
# qualified: the first is shared with power-curve, the second with tte. Only
# helpers used by THIS family alone moved here — empty_hint!, known_sports!,
# top_metric, lens_name.
import Report
import Strava
import Db
import Output
import Metrics
import Render
import Sports
import Streams
import Csv
import pf.Sqlite
import pf.Stdout
import pf.Path

ReportSessions :: [].{
    activity! : Str => Try({}, _)
    activity! = |id_str| {
        path = Db.open_db!({})?
        match Metrics.arg_i64(id_str) {
            Err(_) => Output.err_out!("activity_not_found", "activity ${id_str} not found (run `stride activities` to list ids)")
            Ok(aid) => activity_body!(path, id_str, aid)

        }
    }
    activity_body! : Str, Str, I64 => Try({}, _)
    activity_body! = |path, id_str, aid| {
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.id AS id, COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS date, COALESCE(CAST(a.sport_type AS TEXT), '') AS sport,
                \\       COALESCE(CAST(a.sport_family AS TEXT), CAST(a.sport_type AS TEXT), '') AS family, COALESCE(CAST(a.name AS TEXT), '') AS name,
                \\       a.moving_time AS moving_time, CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
                \\       CAST(COALESCE(m.tss,0) AS REAL) AS tss, CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
                \\       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                \\       CAST(COALESCE(m.ftp_used,0) AS REAL) AS ftp_used,
                \\       COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
                \\       COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s,
                \\       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
                \\       CAST(COALESCE(m.avg_hr_stream, a.avg_hr, 0) AS REAL) AS avg_hr_scored,
                \\       CAST(COALESCE(m.decoupling_pct, 0) AS REAL) AS decoupling_pct,
                \\       CASE WHEN m.decoupling_pct IS NULL THEN 0 ELSE 1 END AS decoupling_known,
                \\       COALESCE(CAST(m.decoupling_signal AS TEXT), '') AS decoupling_signal,
                \\       CASE WHEN m.normalized_power IS NULL THEN 0 ELSE 1 END AS power_known,
                \\       CASE WHEN m.intensity_factor IS NULL THEN 0 ELSE 1 END AS intensity_known,
                \\       CASE WHEN a.avg_hr IS NULL THEN 0 ELSE 1 END AS hr_known,
                \\       CASE WHEN COALESCE(m.hr_samples_total, 0) > 0 THEN 1 ELSE 0 END AS zones_known,
                \\       COALESCE(CAST(m.load_model AS TEXT), '') AS load_model
                \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE a.id = :id LIMIT 1
            ,
            bindings: [{ name: ":id", value: Integer(aid) }],
            rows: |cols| |stmt| {
                id = Sqlite.i64("id")(cols)(stmt)?
                date = Sqlite.str("date")(cols)(stmt)?
                sport = Sqlite.str("sport")(cols)(stmt)?
                family = Sqlite.str("family")(cols)(stmt)?
                name = Sqlite.str("name")(cols)(stmt)?
                moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                distance_m = Sqlite.f64("distance_m")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                np_w = Sqlite.f64("np_w")(cols)(stmt)?
                intensity = Sqlite.f64("intensity")(cols)(stmt)?
                ftp_used = Sqlite.f64("ftp_used")(cols)(stmt)?
                z1_s = Sqlite.i64("z1_s")(cols)(stmt)?
                z2_s = Sqlite.i64("z2_s")(cols)(stmt)?
                z3_s = Sqlite.i64("z3_s")(cols)(stmt)?
                z4_s = Sqlite.i64("z4_s")(cols)(stmt)?
                z5_s = Sqlite.i64("z5_s")(cols)(stmt)?
                avg_hr = Sqlite.f64("avg_hr")(cols)(stmt)?
                avg_hr_scored = Sqlite.f64("avg_hr_scored")(cols)(stmt)?
                # split into value + flag in SQL rather than a nullable decoder: 0.0 is a
                # REAL result here (a perfectly steady session), so the flag is the only
                # thing that separates "flat" from "no power meter" (#94)
                decoupling_pct = Sqlite.f64("decoupling_pct")(cols)(stmt)?
                decoupling_known = Sqlite.i64("decoupling_known")(cols)(stmt)?
                decoupling_signal = Sqlite.str("decoupling_signal")(cols)(stmt)?
                power_known = Sqlite.i64("power_known")(cols)(stmt)?
                intensity_known = Sqlite.i64("intensity_known")(cols)(stmt)?
                hr_known = Sqlite.i64("hr_known")(cols)(stmt)?
                zones_known = Sqlite.i64("zones_known")(cols)(stmt)?
                load_model = Sqlite.str("load_model")(cols)(stmt)?
                Ok({ id, date, sport, family, name, moving_time, distance_m, tss, np_w, intensity, ftp_used, z1_s, z2_s, z3_s, z4_s, z5_s, avg_hr, avg_hr_scored, decoupling_pct, decoupling_known: decoupling_known != 0, decoupling_signal, power_known: power_known != 0, intensity_known: intensity_known != 0, hr_known: hr_known != 0, zones_known: zones_known != 0, load_model })
            },
        })?
        match List.first(rows) {
            Err(_) => Output.err_out!("activity_not_found", "activity ${id_str} not found (run `stride activities` to list ids)")
            Ok(a) => {
                # REFUSES rather than rendering an empty date, because this screen COMPUTES
                # from the date and the computation fails silently. `Report.cp_fit_as_of!`
                # takes a 90-day window anchored here, an unreadable date makes that window
                # empty, and the whole `vs self (90d, same family+band)` line DISAPPEARS —
                # indistinguishable from an athlete who genuinely has no comparables. The
                # header's blank date is at least visible; the missing line is not.
                #
                # The split in #249 is by what a command DOES with the date, not by which
                # table it read: `activities` and `top` LIST or RANK and can report a row
                # whose date is unusable, while `activity`, `reps` and `progress` compute
                # from it and must refuse. Reporting is only defensible where the wrong
                # value cannot become a wrong answer.
                _ = (Metrics.usable_date_days(a.date)).map_err(|_| BadActivityDate(a.date, a.id))?
                raw_rows = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query: "SELECT COALESCE(CAST(raw_json AS TEXT), '') AS raw FROM streams WHERE activity_id = :id",
                    bindings: [{ name: ":id", value: Integer(aid) }],
                    rows: Sqlite.str("raw"),
                })?
                raw_opt =
                    match List.first(raw_rows) {
                        Ok(text) => NotNull(text)
                        Err(_) => Null
                    }
                hard_s = a.z4_s + a.z5_s
                # intensity from POWER (truer than HR for power sports — HR threshold can
                # sit on a zone boundary). Cycling uses the FTP the ride was scored with;
                # non-cycling power sports need their own threshold (not yet configured),
                # so they get 0 here and fall back to the HR "hard" signal.
                pi_ftp = Db.sport_ftp!(path, a.sport)?
                # detected interval structure (ADR 0008) — computed tier, may be empty
                seg_rows = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT ordinal, COALESCE(CAST(kind AS TEXT), '') AS kind, start_s, dur_s, CAST(avg_signal AS REAL) AS avg_signal, COALESCE(CAST(signal AS TEXT), '') AS signal,
                        \\       CAST(COALESCE(peak_hr, 0) AS REAL) AS peak_hr, CAST(COALESCE(avg_hr, 0) AS REAL) AS avg_hr,
                        \\       CAST(COALESCE(rec_drop_60s, 0) AS REAL) AS rec_drop,
                        \\       CASE WHEN rec_drop_60s IS NULL THEN 0 ELSE 1 END AS rec_drop_known
                        \\FROM activity_segments WHERE activity_id = :id ORDER BY ordinal
                    ,
                    bindings: [{ name: ":id", value: Integer(aid) }],
                    rows: |cols| |stmt| {
                        ordinal = Sqlite.i64("ordinal")(cols)(stmt)?
                        kind = Sqlite.str("kind")(cols)(stmt)?
                        start_s = Sqlite.i64("start_s")(cols)(stmt)?
                        dur_s = Sqlite.i64("dur_s")(cols)(stmt)?
                        avg_signal = Sqlite.f64("avg_signal")(cols)(stmt)?
                        signal = Sqlite.str("signal")(cols)(stmt)?
                        peak_hr = Sqlite.f64("peak_hr")(cols)(stmt)?
                        avg_hr = Sqlite.f64("avg_hr")(cols)(stmt)?
                        rec_drop = Sqlite.f64("rec_drop")(cols)(stmt)?
                        rdk = Sqlite.i64("rec_drop_known")(cols)(stmt)?
                        Ok({ ordinal, kind, start_s, dur_s, avg_signal, signal, peak_hr, avg_hr, rec_drop, rec_drop_known: rdk == 1 })
                    },
                })?
                interval_summary = Render.interval_summary(seg_rows)
                seg_drift = Render.seg_hr_drift(seg_rows)
                detail =
                    match raw_opt {
                        NotNull(_) => {
                                decoded = Streams.decode_streams(raw_opt)
                                streams = decoded.streams
                                hr_pairs = List.keep_if(Streams.stream_pairs(streams.time, streams.heartrate), |p| Metrics.valid_hr(p.v))
                                watts_pairs = List.keep_if(Streams.stream_pairs(streams.time, streams.watts), |p| Metrics.valid_watts(p.v))
                                watts_1s_pairs = Metrics.resample_1s_pairs(watts_pairs, Hold)
                                best = |w|
                                    match Metrics.best_rolling_mean_1s(watts_1s_pairs, w) {
                                        Ok(v) => v
                                        Err(_) => 0.0
                                    }
                                pi = Metrics.time_in_power_intensity(watts_pairs, pi_ftp)
                                { max_hr: List.fold(hr_pairs, 0.0.F64, |acc, p| (acc).max(p.v)), best_60: best(60), best_180: best(180), best_300: best(300), best_1200: best(1200), easy_s: pi.easy_s, moderate_s: pi.moderate_s, hard_s: pi.hard_s, failed: decoded.failed, has_watts: !(List.is_empty(watts_pairs)), has_dist: !(List.is_empty(Streams.stream_pairs(streams.time, streams.distance))) }
                            }
                        Null => { max_hr: 0.0, best_60: 0.0, best_180: 0.0, best_300: 0.0, best_1200: 0.0, easy_s: 0, moderate_s: 0, hard_s: 0, failed: False, has_watts: False, has_dist: False }
                    }
                # W' balance (#186): what the ride did to the anaerobic tank,
                # against the fit as it stood on the ride's own date. Summary
                # rather than the series — a per-second array in every activity
                # payload would dwarf everything else, and min/end answer the
                # question ("how close to empty, and did it come back?").
                cpfit = Report.cp_fit_as_of!(path, a.family, a.date, 90)?
                # ANNOTATED: this payload is encode-only, and an unconstrained
                # tag serializes as the STRING "True" (the trap this repo keeps
                # rediscovering — pinned in e2e for the other flags)
                wbal_known : Bool
                wbal_known = cpfit.cp > 0.0 and (match raw_opt { NotNull(_) => True  Null => False })
                wbal =
                    match raw_opt {
                        NotNull(_) if cpfit.cp > 0.0 => {
                            decoded2 = Streams.decode_streams(raw_opt)
                            wp = List.keep_if(Streams.stream_pairs(decoded2.streams.time, decoded2.streams.watts), |p| Metrics.valid_watts(p.v))
                            series = Metrics.w_prime_balance(Metrics.resample_1s_pairs(wp, Hold), { cp: cpfit.cp, w_prime: cpfit.w_prime })
                            if List.is_empty(series) {
                                { min_j: 0.0, end_j: 0.0, computed: False }
                            } else {
                                lowest = List.fold(series, cpfit.w_prime, |acc, b| if b < acc b else acc)
                                { min_j: lowest, end_j: (List.last(series)).ok_or(0.0), computed: True }
                            }
                        }
                        _ => { min_j: 0.0, end_j: 0.0, computed: False }
                    }
                wbal_ok : Bool
                wbal_ok = wbal_known and wbal.computed
                pintensity = { easy_s: detail.easy_s, moderate_s: detail.moderate_s, hard_s: detail.hard_s }
                has_power_intensity = (pintensity.easy_s + pintensity.moderate_s + pintensity.hard_s) > 0

                # ── personal baselines (#160): THIS ride vs the athlete's own prior
                # comparables. Comparability is Metrics.duration_band + sport_family
                # + per-metric signal presence — the ONE rule (#149 must reuse it).
                # The window is 90 days anchored to THE ACTIVITY's own start (not
                # today) and strictly BEFORE it: recomputing an old ride months
                # later yields the same baseline, and future data cannot leak in.
                band = Metrics.duration_band(a.moving_time)
                comps = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT CAST(COALESCE(m.normalized_power, 0) AS REAL) AS np,
                        \\       CASE WHEN m.normalized_power IS NULL THEN 0 ELSE 1 END AS np_known,
                        \\       CAST(COALESCE(m.avg_hr_stream, a2.avg_hr, 0) AS REAL) AS hr,
                        \\       CAST(COALESCE(m.decoupling_pct, 0) AS REAL) AS dec_pct,
                        \\       CASE WHEN m.decoupling_pct IS NULL THEN 0 ELSE 1 END AS dec_known
                        \\FROM activities a2 JOIN activity_metrics m ON m.activity_id = a2.id
                        \\JOIN activities self ON self.id = :id
                        \\WHERE a2.sport_family = self.sport_family
                        \\  AND a2.moving_time >= :blo AND a2.moving_time < :bhi
                        \\  AND a2.start_local < self.start_local
                        \\  AND a2.start_local >= date(self.start_local, '-90 days')
                    ,
                    bindings: [
                        { name: ":id", value: Integer(a.id) },
                        { name: ":blo", value: Integer(band.lo) },
                        { name: ":bhi", value: Integer(band.hi) },
                    ],
                    rows: |cols| |stmt| {
                        np = Sqlite.f64("np")(cols)(stmt)?
                        np_known = Sqlite.i64("np_known")(cols)(stmt)?
                        hr = Sqlite.f64("hr")(cols)(stmt)?
                        dec_pct = Sqlite.f64("dec_pct")(cols)(stmt)?
                        dec_known = Sqlite.i64("dec_known")(cols)(stmt)?
                        Ok({ np, np_known: np_known != 0, hr, dec_pct, dec_known: dec_known != 0 })
                    },
                })?
                # `valid_hr`, not `> 0.0`, and this is the site that matters most of the
                # three: it is the COMPARABLES set, so an impossible reading here does not
                # merely misreport its own session, it sets the baseline every NEIGHBOUR is
                # scored against. Measured before this change — activity 13304290741's
                # 22-sample EF baseline contained 6.60 and 3.32, both from the two broken
                # rowing sessions, so a healthy session was ranked against a median two
                # impossible numbers helped set (#305).
                ef_samples = List.map(List.keep_if(comps, |c| c.np_known and Metrics.valid_hr(c.hr)), |c| c.np / c.hr)
                np_samples = List.map(List.keep_if(comps, |c| c.np_known), |c| c.np)
                dec_samples = List.map(List.keep_if(comps, |c| c.dec_known), |c| c.dec_pct)
                # flags first (ADR 0009), magnitude second (division guard). The bound is
                # `Metrics.valid_hr`, shared with the `progress` lenses and decoupling — one
                # definition of an impossible heart rate (#294 -> #305).
                # `a.hr_known` is gone from this gate rather than joined by a second flag: it
                # reads the STORED NULL (the documented `_known` contract), but the divisor is
                # now `avg_hr_scored` and a session can carry an HR stream while its summary is
                # NULL. The conjunct was redundant anyway — `COALESCE(...,0)` makes an absent
                # reading 0.0 and `valid_hr` refuses it — so dropping it cannot widen the old
                # path; it is what lets a stream-only session score (#311).
                cur_ef = if a.power_known and Metrics.valid_hr(a.avg_hr_scored) a.np_w / a.avg_hr_scored else 0.0
                # one metric block: current + own-history median + rank + change.
                # percentile is direction-free (documented at Metrics.percentile_of).
                # known = current-side presence AND a non-empty sample set; a
                # near-zero MEDIAN only zeroes delta_pct (a ratio against ~0 is not
                # a number) while known stays true — the percentile still ranks
                metric_block = |samples, current, cur_known| {
                    n = List.len(samples)
                    med = Metrics.median_f64(samples)
                    known : Bool
                    known = cur_known and n > 0
                    {
                        current,
                        baseline_median: med,
                        percentile: if known Metrics.percentile_of(samples, current) else 0,
                        delta_pct: if known and (med).abs() > 0.001 ((current - med) / (med).abs() * 100.0) else 0.0,
                        sample_count: (n).to_i64_wrap(),
                        known,
                    }
                }
                baselines = {
                    # the comparability rule, made visible so the coach can weigh it
                    window_days: 90.I64,
                    band_lo_s: band.lo,
                    band_hi_s: band.hi,
                    # ...and the KNOWN flag moves with it, so a refused session publishes
                    # `ef.known: false` rather than a number nothing marks. That is the
                    # marking half of #305: the reader gets an absent measurement instead of
                    # a 100th-percentile verdict computed from 18 bpm.
                    ef: metric_block(ef_samples, cur_ef, a.power_known and Metrics.valid_hr(a.avg_hr_scored)),
                    np: metric_block(np_samples, a.np_w, a.power_known),
                    decoupling: metric_block(dec_samples, a.decoupling_pct, a.decoupling_known),
                }

                if Output.json_mode!({})
                    Output.emit_ok!({
                        id: a.id,
                        date: a.date,
                        sport: a.sport,
                        name: a.name,
                        baselines,
                        moving_time: a.moving_time,
                        distance_m: a.distance_m,
                        tss: a.tss,
                        # tss 0 is AMBIGUOUS (a real recovery spin scores near-0; an
                        # unscored row COALESCEs to 0) — load_model is the discriminator:
                        # "" (no metrics row) or "none" = unscored, anything else = scored
                        load_model: a.load_model,
                        np_w: a.np_w,
                        # 0-vs-missing (#156): flags decode the STORED NULLs — deriving
                        # them from coalesced magnitudes re-loses exactly the information
                        # the flag exists to carry (np can be present while intensity is
                        # NULL when no FTP existed — observed on a real database state)
                        power_known: a.power_known,
                        intensity: a.intensity,
                        intensity_known: a.intensity_known,
                        ftp_used: a.ftp_used,
                        z1_s: a.z1_s,
                        z2_s: a.z2_s,
                        z3_s: a.z3_s,
                        z4_s: a.z4_s,
                        z5_s: a.z5_s,
                        hard_s,
                        # intensity from power (0s when no power/threshold — then read hard_s).
                        # hard_by_power_s is the honest "how hard" for a power ride.
                        power_intensity: { easy_s: pintensity.easy_s, moderate_s: pintensity.moderate_s, hard_s: pintensity.hard_s },
                        hard_by_power_s: if has_power_intensity pintensity.hard_s else 0,
                        power_bests: { w60: detail.best_60, w180: detail.best_180, w300: detail.best_300, w1200: detail.best_1200 },
                        max_hr: detail.max_hr,
                        avg_hr: a.avg_hr,
                        avg_hr_scored: a.avg_hr_scored,
                        hr_known: a.hr_known,
                        # summary avg_hr can exist while NO zone breakdown does (no HR
                        # stream): an all-zero z-vector is absence unless zones_known
                        zones_known: a.zones_known,
                        # true = stored streams exist but wouldn't decode, so the 0s
                        # above are "unreadable", NOT "no power meter / no strap"
                        streams_unreadable: detail.failed,
                        # aerobic decoupling (#94), ADDITIVE so the envelope version stays.
                        # The flag is load-bearing rather than decorative: 0.0 here is a
                        # real, good result (no drift), so the house "0 = not available"
                        # rule cannot carry the distinction on its own.
                        decoupling_pct: a.decoupling_pct,
                        decoupling_known: a.decoupling_known,
                        # which signal the drift came from — STORED provenance (like
                        # load_model), never re-derived from the stream at render time:
                        # a re-derivation mislabels estimated-watts sessions and re-pull
                        # windows where streams are momentarily absent (#142 retro)
                        decoupling_signal: a.decoupling_signal,
                        # detected structure (ADR 0008), ADDITIVE. Empty list + "" = none
                        # detected or no stream signal — reporting only, never a judgment.
                        segments: seg_rows,
                        # the tank: how low it went and where it ended, plus the
                        # fit it was measured against (a CP from a thin window is
                        # a different claim from one fitted on a rich one)
                        w_prime_balance: {
                            min_j: wbal.min_j,
                            end_j: wbal.end_j,
                            known: wbal_ok,
                            # A balance below zero is the MODEL failing, not the
                            # athlete succeeding: it means the fitted W' is too
                            # small to explain what was ridden. Reported as its
                            # own flag because a bare negative number reads as a
                            # measurement, and this one is a diagnosis of the fit.
                            model_exceeded: wbal_ok and wbal.min_j < 0.0,
                            cp_used: cpfit.cp,
                            w_prime_used: cpfit.w_prime,
                            fit_points: cpfit.points,
                            fit_r2: cpfit.r2,
                            fit_family: cpfit.family,
                        },
                        interval_summary,
                        # TRUE = the detector actually ran with a signal (power, or
                        # pace on a pace-routed sport). Distinguishes "verified: no
                        # interval structure" from "couldn't look" — an empty segments
                        # list alone conflates the two.
                        detection_attempted: detail.has_watts or (Sports.pace_routed(a.sport) and detail.has_dist),
                        hr_drift: (seg_drift).ok_or(0.0),
                        hr_drift_known: seg_drift.is_ok(),
                    })
                else {
                    dist_str = if a.distance_m >= 1000.0 " · ${Render.fmt1(a.distance_m / 1000.0)} km" else ""
                    Stdout.line!(a.name)?
                    Stdout.line!("${a.date} · ${a.sport} · ${Render.mins(a.moving_time)}${dist_str}")?
                    Stdout.line!("")?
                    load_str = if a.tss >= 1.0 "${Render.fmt0(a.tss)} TSS" else "no usable data"
                    np_str = if a.np_w > 0 " · np ${Render.fmt0(a.np_w)}W @ ftp ${Render.fmt0(a.ftp_used)} (if ${Render.fmt2(a.intensity)})" else ""
                    Stdout.line!("load   ${load_str}${np_str}")?
                    Stdout.line!("zones  Z1 ${(a.z1_s // 60).to_str()}m · Z2 ${(a.z2_s // 60).to_str()}m · Z3 ${(a.z3_s // 60).to_str()}m · Z4 ${(a.z4_s // 60).to_str()}m · Z5 ${(a.z5_s // 60).to_str()}m")?
                    (if has_power_intensity
                        Stdout.line!("hard   ${Render.mins(pintensity.hard_s)} at/above threshold (by power) · ${Render.mins(hard_s)} in HR Z4+Z5")
                    else
                        Stdout.line!("hard   ${Render.mins(hard_s)} in Z4+Z5"))?
                    if detail.best_60 > 0
                        Stdout.line!("power  1min ${Render.fmt0(detail.best_60)}W · 3min ${Render.fmt0(detail.best_180)}W · 5min ${Render.fmt0(detail.best_300)}W · 20min ${Render.fmt0(detail.best_1200)}W")?
                    else
                        Ok({})?
                    # the SCORED average, for the reason `progress`'s hr column shows it: this line
                    # shares a screen with an EF verdict, and the two disagreeing with nothing to say
                    # which is which is the gap #311 opened. When they differ, the recorded value is
                    # named beside it — that number is what the athlete compares against Strava.
                    # Compared as RENDERED, not as floats: 161.461 vs 161.2 differs by 0.26 and would
                    # print "avg 161 (recorded 161)" (measured on 336 of 490 firing rows). And only
                    # when a reading was RECORDED: a stream-only session stores no average, COALESCE
                    # makes it 0.0, and "(recorded 0)" states a measurement where `avg 0` merely read
                    # as absent (numeric-0 invariant, ADR 0009).
                    recorded_note =
                        if !(a.hr_known) or Render.fmt0(a.avg_hr_scored) == Render.fmt0(a.avg_hr) {
                            ""
                        } else {
                            " (recorded ${Render.fmt0(a.avg_hr)})"
                        }
                    (if detail.max_hr > 0
                        Stdout.line!("hr     max ${Render.fmt0(detail.max_hr)} · avg ${Render.fmt0(a.avg_hr_scored)}${recorded_note}")
                    else
                        Ok({}))?
                    # detected structure — absent line when nothing detected (honest absence)
                    (if Str.is_empty(interval_summary)
                        Ok({})
                    else {
                        drift_line = match seg_drift {
                            Ok(d) => "\nhr drift ${Render.signed(d)} bpm across reps — rising = fatigue accumulating"
                            Err(_) => ""
                        }
                        Stdout.line!("shape  ${interval_summary}\n${Render.segments_block(seg_rows)}${drift_line}")
                    })?
                    # aerobic decoupling (#94). Printed ONLY when it was computable —
                    # an absent line is honest, a "drift 0%" line on a session with no
                    # power meter would be a fabricated perfect score.
                    (if a.decoupling_known {
                        drift_tail =
                            if a.decoupling_signal == "power"
                                "Pw:HR — second-half heartbeats per watt vs first"
                            else if a.decoupling_signal == "pace"
                                "Pa:HR — second-half heartbeats per grade-adjusted m/s vs first"
                            else
                                "Spd:HR — per raw m/s (no altitude stream, terrain not normalized)"
                        Stdout.line!("drift   ${Render.signed(a.decoupling_pct)}% ${drift_tail}")
                    } else
                        Ok({}))?
                    # vs-self line (#160): rank within the athlete's OWN comparable
                    # history — percentile is direction-free rank; absent entirely
                    # when no metric has a baseline (no fake p0s)
                    (if baselines.ef.known or baselines.np.known or baselines.decoupling.known {
                        parts = List.keep_if(
                            [
                                if baselines.ef.known "ef p${I64.to_str(baselines.ef.percentile)}/${I64.to_str(baselines.ef.sample_count)}" else "",
                                if baselines.np.known "np p${I64.to_str(baselines.np.percentile)}/${I64.to_str(baselines.np.sample_count)}" else "",
                                if baselines.decoupling.known "drift p${I64.to_str(baselines.decoupling.percentile)}/${I64.to_str(baselines.decoupling.sample_count)}" else "",
                            ],
                            |p| !(Str.is_empty(p)),
                        )
                        Stdout.line!("vs self (90d, same family+band): ${Str.join_with(parts, " · ")}")
                    } else
                        Ok({}))?
                    if detail.failed
                        Stdout.line!("⚠ stored stream data for this activity is unreadable — zeros above are missing data, not real zeros")
                    else
                        Ok({})
                }
            }
        }
    }
    # career + year-to-date totals per sport
    activities! : U64, Str => Try({}, _)
    activities! = |limit, sport_filter| {
        path = Db.open_db!({})?
        sf = Report.sport_filter_sql(sport_filter)
        # optional sport filter via Report.sport_filter_sql: the FRAGMENT is interpolated
        # (its placeholders are numbered, values stay real bindings), and the empty
        # branch is a single space, never "" — interpolating a compile-time-constant
        # empty string used to crash this backend in str_concat (#32 class, roc#10595,
        # fixed upstream and carried by the current pin). Non-empty by construction is
        # the rule the :all-flag comment in Plan.roc states, and it stays.
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
            # `${Report.date_known_sql}` and `${Report.rankable_sql}` stay on the RAW column
            # while the projection beside them is wrapped — load-bearing, not an oversight to
            # tidy: `date(substr(blob,1,10))` returns TEXT and `substr(blob,1,10)` is a BLOB,
            # so the `IS NOT` is true on the type mismatch and the flag correctly goes false.
            # Wrapping them "for consistency" publishes `date_known: true` for a row no
            # bounded-range window (`week`, `compare`, a `season` month) can see — uncounted,
            # unhoisted, a silent wrong answer at exit 0, strictly worse than the crash this
            # removed.
            #
            # `a.sport_type` and `a.name` are NOT wrapped — a known gap, not an audit: a BLOB
            # in either crashes this SELECT as `start_local` did (#307), and the repair is at
            # the decode boundary, not another CAST per column.
                \\SELECT a.id AS id, COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS date, ${Report.date_known_sql} AS date_known, ${Report.rankable_sql} AS rankable, COALESCE(CAST(a.sport_type AS TEXT), '') AS sport, COALESCE(CAST(a.name AS TEXT), '') AS name,
                \\       a.moving_time AS moving_time, CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
                \\       CAST(COALESCE(m.tss,0) AS REAL) AS tss, CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
                \\       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                \\       COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
                \\       COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s,
                \\       -- hard time: the pi_* intensity split when the activity has one --
                \\       -- POWER-derived where there are watts, PACE-derived for a distance sport
                \\       -- without them -- else HR Z4+Z5. So a power ride's threshold work counts,
                \\       -- and so does a run's.
                \\       COALESCE(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_hard_s ELSE m.z4_s + m.z5_s END, 0) AS hard_s,
                \\       CAST(COALESCE(a.relative_effort,0) AS REAL) AS relative_effort,
                \\       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
                \\       CAST(COALESCE(m.avg_hr_stream, a.avg_hr, 0) AS REAL) AS avg_hr_scored,
                \\       CASE WHEN m.normalized_power IS NULL THEN 0 ELSE 1 END AS power_known,
                \\       CASE WHEN m.intensity_factor IS NULL THEN 0 ELSE 1 END AS intensity_known,
                \\       CASE WHEN a.avg_hr IS NULL THEN 0 ELSE 1 END AS hr_known,
                \\       CASE WHEN COALESCE(m.hr_samples_total, 0) > 0 THEN 1 ELSE 0 END AS zones_known,
                \\       COALESCE(CAST(m.load_model AS TEXT), '') AS load_model
                \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE (1=1${sf.frag})
                \\-- undateable rows FIRST, and that is the whole reason `activities` is
                \\-- allowed to report an unreadable date instead of refusing like the
                \\-- commands that compute from one. Reporting is only honest if the row can
                \\-- be SEEN: SQLite sorts NULL last under DESC, so the one row the listing
                \\-- exists to expose landed at position 736 of 736 on a real database and
                \\-- fell outside the default limit of 30 entirely. Measured — the id was
                \\-- absent from `stride activities` and needed `activities 5000` to appear.
                \\-- A listing whose job is to show what is stored must lead with the rows
                \\-- that need repair; a row with no date has no place in a recency order
                \\-- anyway, and first is the only position where no limit can hide it.
                \\--
                \\-- THREE SHAPES, not just NULL, and the first version of this tested
                \\-- `IS NULL` alone. That covered exactly one of them: review measured a
                \\-- stored empty string at position 737 of 737 and '0000-0z-01T10:00:00Z'
                \\-- at 745 — both outside the default limit, which is verbatim the failure
                \\-- the paragraph above claims to have fixed. The empty string is the
                \\-- pointed one, because the error message this change also added says
                \\-- "the column is NULL or empty", so the engine named a state and then
                \\-- hid it from the listing it tells you to go read. 'garbage-da' escaped
                \\-- only by luck of sorting high.
                \\--
                \\-- The predicate is the ROUND TRIP through SQLite's own date(), plus the
                \\-- year bound. Measured against the SHIPPED binary, it hoists every shape
                \\-- Metrics.usable_date_days rejects, impossible-but-well-formed days
                \\-- included: '2026-02-30', '2026-04-31' and '1000-02-30' all land in the
                \\-- first three rows, while a readable '1000-01-01' correctly stays at 740.
                \\--
                \\-- WHICH SQLite matters, and an earlier version of this comment was
                \\-- measured against the wrong one. The system CLI here is 3.43.2 and
                \\-- returns '2026-02-30' verbatim; the binary links 3.49.1 through
                \\-- basic-cli and does not. So the comment documented a residual the
                \\-- product does not have, and justified it with reasoning that was wrong
                \\-- anyway — such a row ranks 91 of 738 without the hoist, which is
                \\-- "among its neighbours" and still outside the default limit of 30.
                \\--
                \\-- The real property is a split: the REFUSAL rule lives in Roc and is
                \\-- version-independent, while this VISIBILITY rule delegates part of
                \\-- itself to the bundled SQLite. Two definitions of "readable date" in one
                \\-- feature is the drift shape Metrics.usable_date_days exists to prevent.
                \\-- The platform is hash-pinned, so it cannot move silently — but it does
                \\-- move on upgrades, and the e2e hoist fixtures are what hold the two
                \\-- together across one. '1000-02-30' is in that set for exactly this
                \\-- reason: it is the shape only the newer date() catches.
                \\ORDER BY ${Metrics.hoist_unrankable_sql("a.start_local")}, a.id DESC LIMIT ${(limit).to_str()}
            ,
            bindings: sf.binds,
            rows: |cols| |stmt| {
                id = Sqlite.i64("id")(cols)(stmt)?
                date = Sqlite.str("date")(cols)(stmt)?
                date_known = Sqlite.i64("date_known")(cols)(stmt)?
                rankable = Sqlite.i64("rankable")(cols)(stmt)?
                sport = Sqlite.str("sport")(cols)(stmt)?
                name = Sqlite.str("name")(cols)(stmt)?
                moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                distance_m = Sqlite.f64("distance_m")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                np_w = Sqlite.f64("np_w")(cols)(stmt)?
                intensity = Sqlite.f64("intensity")(cols)(stmt)?
                z1_s = Sqlite.i64("z1_s")(cols)(stmt)?
                z2_s = Sqlite.i64("z2_s")(cols)(stmt)?
                z3_s = Sqlite.i64("z3_s")(cols)(stmt)?
                z4_s = Sqlite.i64("z4_s")(cols)(stmt)?
                z5_s = Sqlite.i64("z5_s")(cols)(stmt)?
                hard_s = Sqlite.i64("hard_s")(cols)(stmt)?
                relative_effort = Sqlite.f64("relative_effort")(cols)(stmt)?
                avg_hr = Sqlite.f64("avg_hr")(cols)(stmt)?
                avg_hr_scored = Sqlite.f64("avg_hr_scored")(cols)(stmt)?
                power_known = Sqlite.i64("power_known")(cols)(stmt)?
                intensity_known = Sqlite.i64("intensity_known")(cols)(stmt)?
                hr_known = Sqlite.i64("hr_known")(cols)(stmt)?
                zones_known = Sqlite.i64("zones_known")(cols)(stmt)?
                load_model = Sqlite.str("load_model")(cols)(stmt)?
                Ok({ id, date, date_known: date_known != 0, rankable: rankable != 0, sport, name, moving_time, distance_m, tss, load_model, np_w, power_known: power_known != 0, intensity, intensity_known: intensity_known != 0, z1_s, z2_s, z3_s, z4_s, z5_s, zones_known: zones_known != 0, hard_s, relative_effort, avg_hr, avg_hr_scored, hr_known: hr_known != 0 })
            },
        })?
        if Output.json_mode!({})
            Output.emit_ok!(rows)
        else if List.is_empty(rows) and limit > 0 and !(Str.is_empty(sport_filter)) {
            Stdout.line!(empty_hint!(path, sport_filter, "any")?)
        } else {
            Stdout.line!(Render.render_table(
                ["date", "sport", "name", "time", "load", "intensity (if)", "hard"],
                List.map(rows, |a| [
                    # `-` for an unreadable date — this table's own house rule for every other
                    # column, and the date column was the one place with genuinely no usable data
                    # not using it. A blank cell is AMBIGUOUS here: a long name wraps onto a
                    # continuation row whose date cell is also blank, so the hoisted repair row
                    # renders identically to a line-wrap artifact.
                    (if Str.is_empty(a.date) "-" else a.date),
                    a.sport,
                    a.name,
                    Render.mins(a.moving_time),
                    (if a.tss >= 1.0 Render.fmt0(a.tss) else "-"),
                    (if a.intensity > 0 Render.fmt2(a.intensity) else "-"),
                    Render.mins(a.hard_s),
                ]),
            ))?
            Stdout.line!("")?
            Stdout.line!("load:           session stress — TSS for power/HR, session-RPE for rated sessions; '-' = no usable data (e.g. dead HR strap)")?
            Stdout.line!("intensity (if): vs your FTP — ~0.7 easy · 0.85-0.95 tempo · ~1.0 threshold · 1.05+ vo2max")?
            Stdout.line!("hard:           minutes at/above threshold — by power (vs the sport's FTP), else the pace split, else HR Z4+Z5")
        }
    }
    # metric keyword => its ORDER BY column + human table header. The column is HARDCODED
    # per keyword, so no user input ever reaches the SQL; an unknown metric errors before
    # any query. Single source of truth so column and header can't drift apart.
    top_metric : Str -> Try({ col : Str, header : Str, bound : Str }, [BadMetric])
    top_metric = |m|
        match m {
            # `bound` is the plausibility predicate for this metric's column, empty when the
            # column has none. `> 0` is presence, not plausibility — `top hr 700` returned
            # the same three readings `progress` and `activity` refuse, ordered so a 250 bpm
            # one led (#315). Per metric, because it is a per-column fact: `valid_hr`'s
            # 35-220 says nothing about kilometres. (`Metrics.valid_watts` exists but is a
            # per-SAMPLE stream bound; applying it to session NP is a separate judgement.)
            #
            # `CAST(... AS REAL)` because that is what every other consumer sees: a BLOB
            # storing the bytes of "100" scores through the `valid_hr`-gated rung and
            # publishes at 100 bpm, while bare SQL comparison orders BLOB above every number
            # and would exclude a row the rest of the engine accepts.
            "hr" => Ok({ col: "a.avg_hr", header: "heart rate (hr)", bound: "CAST(@ AS REAL) >= 35 AND CAST(@ AS REAL) <= 220" })
            "tss" => Ok({ col: "m.tss", header: "load", bound: "" })
            "power" => Ok({ col: "m.normalized_power", header: "power (np)", bound: "" })
            "intensity" => Ok({ col: "m.intensity_factor", header: "intensity (if)", bound: "" })
            "distance" => Ok({ col: "a.distance", header: "distance (km)", bound: "" })
            "time" => Ok({ col: "a.moving_time", header: "time (min)", bound: "" })
            "output" => Ok({ col: "(a.avg_watts * a.moving_time)", header: "output (kj)", bound: "" }) # total work (Peloton kJ)
            _ => Err(BadMetric)

        }
    # ranked "best sessions": top N activities by a chosen metric (vs `activities`,
    # which is chronological). e.g. `top hr`, `top tss 5 rowing`.
    # sport-word filter shared by top/activities/power-curve: the human word
    # widens to its Strava family (Sports.family), matched IN (...) with
    # NOCASE. Placeholders are numbered so the bindings stay real bindings.
    known_sports! : Str => Try(List(Str), _)
    known_sports! = |path|
        Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT DISTINCT COALESCE(CAST(sport_type AS TEXT), '') AS s FROM activities WHERE sport_type IS NOT NULL AND sport_type <> '' ORDER BY s",
            bindings: [],
            rows: Sqlite.str("s"),
        })

    # An empty filtered result has TWO honest explanations and the hint must pick
    # the right one: no such sport at all, or the sport exists but nothing in it
    # carries the asked-for data. Blaming the sport unconditionally once denied
    # the existence of runs while listing Run in the same sentence.
    empty_hint! : Str, Str, Str => Try(Str, _)
    empty_hint! = |path, word, what| {
        sf = Report.sport_filter_sql(word)
        n = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT COUNT(*) AS n FROM activities a WHERE 1=1${sf.frag}",
            bindings: sf.binds,
            row: Sqlite.i64("n"),
        })?
        if n == 0 {
            known = known_sports!(path)?
            Ok("no '${word}' activities — sports in your data: ${Str.join_with(known, ", ")}")
        } else {
            noun = if n == 1 "activity" else "activities"
            Ok("${I64.to_str(n)} '${word}' ${noun}, but none with ${what} data")
        }
    }
    top! : Str, U64, Str => Try({}, _)
    top! = |metric, limit, sport_filter| {
        path = Db.open_db!({})?
        match top_metric(metric) {
            Err(_) =>
                Output.err_out!("bad_metric", "unknown metric '${metric}' — use: hr, tss, power, intensity, distance, time, output")

            Ok({ col, header, bound }) => {
                # `bound` is a template over `@` so ONE predicate serves two queries: the
                # ranking applies it to the column, the count applies it to an alias inside a
                # subquery. Written twice they would drift, and the drift would be invisible
                # — the ranking would exclude rows while the count reported a different set.
                bound_sql = if Str.is_empty(bound) "" else " AND ${Str.replace_each(bound, "@", col)}"
                sf = Report.sport_filter_sql(sport_filter)
                sport_where = sf.frag
                sport_binding = sf.binds
                rows = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
            # `${Report.date_known_sql}` / `${Report.rankable_sql}` stay on the RAW column
            # while the projection is wrapped — load-bearing, not an oversight; see the
            # identical projection in the activities listing above for the full argument.
                        \\SELECT a.id AS id, COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS date, ${Report.date_known_sql} AS date_known, ${Report.rankable_sql} AS rankable, COALESCE(CAST(a.sport_type AS TEXT), '') AS sport, COALESCE(CAST(a.name AS TEXT), '') AS name,
                        \\       a.moving_time AS moving_time, CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
                        \\       CAST(COALESCE(m.tss,0) AS REAL) AS tss, CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
                        \\       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                        \\       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
                        \\       CAST(COALESCE(a.avg_watts * a.moving_time / 1000.0, 0) AS REAL) AS output_kj,
                        \\       CASE WHEN m.normalized_power IS NULL THEN 0 ELSE 1 END AS power_known,
                        \\       CASE WHEN m.intensity_factor IS NULL THEN 0 ELSE 1 END AS intensity_known,
                        \\       CASE WHEN a.avg_hr IS NULL THEN 0 ELSE 1 END AS hr_known
                        \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                        \\WHERE ${col} > 0${bound_sql}${sport_where}
                        # ORDER BY casts too, and that is not redundant with the bound: casting only
                        # inside the bound re-admits BLOB/non-numeric-TEXT rows (a BLOB of "100" IS a
                        # plausible reading) but leaves them sorted RAW, and SQLite orders BLOB above
                        # TEXT above every number — so the rows the bound rescued landed at rank 1.
                        # The count subquery repeats this ORDER BY deliberately: it counts what the BOUND
                        # excludes from the window the LIMIT admits, and the ORDER BY decides which rows
                        # are in that window. Change one and the other is wrong silently.
                        \\ORDER BY CAST(${col} AS REAL) DESC, a.id DESC LIMIT ${(limit).to_str()}
                    ,
                    bindings: sport_binding,
                    rows: |cols| |stmt| {
                        id = Sqlite.i64("id")(cols)(stmt)?
                        date = Sqlite.str("date")(cols)(stmt)?
                        date_known = Sqlite.i64("date_known")(cols)(stmt)?
                        rankable = Sqlite.i64("rankable")(cols)(stmt)?
                        sport = Sqlite.str("sport")(cols)(stmt)?
                        name = Sqlite.str("name")(cols)(stmt)?
                        moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                        distance_m = Sqlite.f64("distance_m")(cols)(stmt)?
                        tss = Sqlite.f64("tss")(cols)(stmt)?
                        np_w = Sqlite.f64("np_w")(cols)(stmt)?
                        intensity = Sqlite.f64("intensity")(cols)(stmt)?
                        avg_hr = Sqlite.f64("avg_hr")(cols)(stmt)?
                        output_kj = Sqlite.f64("output_kj")(cols)(stmt)?
                        power_known = Sqlite.i64("power_known")(cols)(stmt)?
                        intensity_known = Sqlite.i64("intensity_known")(cols)(stmt)?
                        hr_known = Sqlite.i64("hr_known")(cols)(stmt)?
                        Ok({ id, date, date_known: date_known != 0, rankable: rankable != 0, sport, name, moving_time, distance_m, tss, np_w, power_known: power_known != 0, intensity, intensity_known: intensity_known != 0, avg_hr, hr_known: hr_known != 0, output_kj })
                    },
                })?
                if Output.json_mode!({})
                    Output.emit_ok!(rows)
                else if List.is_empty(rows) and limit > 0 and !(Str.is_empty(sport_filter)) {
                    # The hint has to know about the bound, or it states a falsehood: two Swim rows at
                    # 250 and 20 bpm produced "2 'swim' activities, but none with heart rate (hr)
                    # data" while both rows HAVE heart-rate data.
                    # This count has NO LIMIT, unlike the one under the ranking table — different
                    # questions. Under a table, "N were implausible" is scoped to the rows you are
                    # looking at; here there is no table, so the question is whether the sport has
                    # any readings at all.
                    n_excluded =
                        if Str.is_empty(bound) {
                            0
                        } else {
                            Sqlite.query!({
                                path: Path.utf8(path),
                                query: "SELECT COUNT(*) AS n FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id WHERE ${col} > 0${sport_where} AND NOT (${Str.replace_each(bound, "@", col)})",
                                bindings: sport_binding,
                                row: Sqlite.i64("n"),
                            })?
                        }
                    if n_excluded > 0 {
                        Stdout.line!("${sport_filter} has ${I64.to_str(n_excluded)} session(s) with ${header} data, but every reading is implausible and none is ranked")
                    } else {
                        Stdout.line!(empty_hint!(path, sport_filter, header)?)
                    }
                } else {
                    val = |r|
                        match metric {
                            "hr" => "${Render.fmt0(r.avg_hr)} bpm"
                            "tss" => Render.fmt0(r.tss)
                            "power" => "${Render.fmt0(r.np_w)}W"
                            "intensity" => Render.fmt2(r.intensity)
                            "distance" => "${Render.fmt1(r.distance_m / 1000.0)} km"
                            "output" => "${Render.fmt0(r.output_kj)} kJ"
                            _ => Render.mins(r.moving_time)
                        }
                    Stdout.line!(Render.render_table(
                        ["date", "sport", header, "name"],
                        # `-` for an unreadable date, same house rule as `activities` above:
                        # `top` is the other REPORT command, so it shows the row rather than
                        # refusing, and a blank cell is indistinguishable from a wrapped-name
                        # continuation row.
                        List.map(rows, |r| [(if Str.is_empty(r.date) "-" else r.date), r.sport, val(r), r.name]),
                    ))?
                    # ...and SAY how many the bound removed — refuse the number, state the refusal
                    # (`progress` counts what it hides, `activities` marks what it cannot rank).
                    # Only when the bound removed something, and only for a metric that HAS one.
                    #
                    # Scoped to THIS TABLE, not the whole eligible set: counting every excluded row
                    # in the database printed "3 implausible" above a one-row leaderboard, and with
                    # DESC ordering every low-side exclusion sorts below the limit anyway. What it
                    # measures: of the rows this table WOULD have shown without the bound, how many
                    # the bound removed — same query, same limit, same filter, only the bound differs.
                    excluded =
                        if Str.is_empty(bound) {
                            0
                        } else {
                            Sqlite.query!({
                                path: Path.utf8(path),
                                query: "SELECT COUNT(*) AS n FROM (SELECT ${col} AS v FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id WHERE ${col} > 0${sport_where} ORDER BY CAST(${col} AS REAL) DESC, a.id DESC LIMIT ${(limit).to_str()}) WHERE NOT (${Str.replace_each(bound, "@", "v")})",
                                bindings: sport_binding,
                                row: Sqlite.i64("n"),
                            })?
                        }
                    if excluded > 0 {
                        # No hardcoded bound and no claim about other commands: the numbers live in the
                        # derivation, and a cross-command claim was false for a BLOB row `activity`
                        # accepts. It names what it did and where the rule lives.
                        Stdout.line!("\n${I64.to_str(excluded)} of this ranking's ${header} readings were implausible and are not shown")
                    } else {
                        Ok({})
                    }
                }
            }
        }
    }
    # one CSV row => the same Strava.ActivitySummary the API sync feeds to Strava.upsert_activity!.
    # Strava's export has DUPLICATE headers: the second Distance/Moving Time are the
    # precise ones (meters/seconds); the first Distance is km. English exports only.
    export_row_to_summary : List(Str), List(Str) -> Try(Strava.ActivitySummary, [BadRow])
    export_row_to_summary = |headers, row| {
        field = |name, occurrence|
            match Csv.column_index(headers, name, occurrence) {
                Ok(i) => (List.get(row, i)).ok_or("")
                Err(_) => ""
            }
        opt_field = |name|
            match F64.from_str(field(name, 0)) {
                Ok(v) => Ok(v)
                Err(_) => Err(Missing)
            }
        # narrowed like every other id (#201): a widened parse here makes "7e2" import
        # as id 700, and upsert_activity! would overwrite whatever real activity holds it
        id = Metrics.arg_i64(field("Activity ID", 0)).map_err(|_| BadRow)?
        start = Metrics.export_date_to_iso(field("Activity Date", 0)).map_err(|_| BadRow)?
        moving_raw = field("Moving Time", 1)
        moving_str = if Str.is_empty(moving_raw) field("Moving Time", 0) else moving_raw
        moving_f = F64.from_str(moving_str).map_err(|_| BadRow)?
        distance =
            match F64.from_str(field("Distance", 1)) {
                Ok(meters) => meters
                Err(_) =>
                    # single Distance column = km
                    match F64.from_str(field("Distance", 0)) {
                        Ok(km) => km * 1000.0
                        Err(_) => 0.0
                    }
            }
        mt : I64
        mt = (moving_f).round_to_i64_try().ok_or(0)
        Ok({
            id,
            name: field("Activity Name", 0),
            sport_type: field("Activity Type", 0),
            start_date_local: start,
            moving_time: mt,
            distance,
            total_elevation_gain: (F64.from_str(field("Elevation Gain", 0))).ok_or(0.0),
            suffer_score: opt_field("Relative Effort"),
            average_watts: opt_field("Average Watts"),
            average_heartrate: opt_field("Average Heart Rate"),
            weighted_average_watts: opt_field("Weighted Average Power"),
            # account exports do not say whether watts came from a meter — unknown, not true
            device_watts: Err(Missing),
        })
    }
    # dataset health report: how much of the history has usable data, which ladder
    # rung scored each activity, and what's honestly unscored. Trust, quantified.
    lens_name : [Ef, SpeedHr, Rpe] -> Str
    lens_name = |lens|
        match lens {
            Ef => "ef"
            SpeedHr => "speed_hr"
            Rpe => "rpe"

        }
    # "am I improving on THIS workout?" — anchored on a date, rendered through the
    # sport-aware lens (power->EF, distance->speed/HR, rated->RPE). Bare `progress`
    # uses the latest analyzed workout.
    # ── rep-level comparison (#149) ──────────────────────────────────────
    # `progress` compares whole SESSIONS; this compares the reps inside them. The
    # anchor is a session with detected work blocks (#95/#171); comparables are
    # earlier same-family sessions whose block structure has the SAME SHAPE — same
    # rep count, same duration band (`Metrics.rep_duration_band`, since session bands
    # are 20-120 min wide) — because "3x12min" and "5x3min" are different workouts.
    # Everything emitted is a measurement (#154): per-rep watts/HR, first-to-last
    # fade, rep count. Whether a fade is "too much" is the coach's call.
    reps! : Str => Try({}, _)
    reps! = |date_arg| {
        path = Db.open_db!({})?
        # the anchor: the named date's session with work blocks, else the most
        # recent one that has any. A date with no detected structure is an
        # honest in-band error rather than an empty comparison.
        anchor = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.id AS id, COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS date, COALESCE(CAST(a.name AS TEXT), '') AS name,
                # The trailing `''` is a behaviour change beyond blob handling: a row with BOTH
                # columns NULL used to decode as an error and now reads empty. An improvement, and
                # deliberate, but not something the CAST alone would have done.
                \\       COALESCE(CAST(a.sport_family AS TEXT), CAST(a.sport_type AS TEXT), '') AS fam,
                \\       COUNT(*) AS reps, CAST(AVG(s.dur_s) AS INTEGER) AS mean_dur,
                \\       MIN(s.dur_s) AS min_dur, MAX(s.dur_s) AS max_dur,
                \\       COALESCE(CAST(MIN(s.signal) AS TEXT), '') AS signal
                \\FROM activity_segments s JOIN activities a ON a.id = s.activity_id
                \\WHERE s.kind = 'work' AND (:d = '' OR substr(a.start_local, 1, 10) = :d)
                \\GROUP BY s.activity_id
                \\ORDER BY ${Metrics.rank_ts_sql("a.start_local", Desc)}, a.id DESC LIMIT 1
            ,
            bindings: [{ name: ":d", value: String(date_arg) }],
            rows: |cols| |stmt| {
                id = Sqlite.i64("id")(cols)(stmt)?
                date = Sqlite.str("date")(cols)(stmt)?
                name = Sqlite.str("name")(cols)(stmt)?
                fam = Sqlite.str("fam")(cols)(stmt)?
                reps = Sqlite.i64("reps")(cols)(stmt)?
                mean_dur = Sqlite.i64("mean_dur")(cols)(stmt)?
                min_dur = Sqlite.i64("min_dur")(cols)(stmt)?
                max_dur = Sqlite.i64("max_dur")(cols)(stmt)?
                signal = Sqlite.str("signal")(cols)(stmt)?
                Ok({ id, date, name, fam, reps, mean_dur, min_dur, max_dur, signal })
            },
        })?
        match List.first(anchor) {
            Err(_) =>
                if Str.is_empty(date_arg)
                    Output.err_out!("no_detected_intervals", "no session on record has detected interval structure yet — `stride activity <id>` shows what a ride's blocks look like")
                else
                    Output.err_out!("no_intervals_on_date", "no detected interval structure on ${date_arg} — the ride may have been continuous, or its streams are missing")
            Ok(a) => {
                # REFUSES, because the comparables invariant is "the ANCHOR always keeps its
                # row" — and it does not, if its date is unreadable: `a2.start_local <=
                # self.start_local` is NULL-false for every candidate including the anchor, so
                # the screen answers a confident "0 of 0 matched" over a database that holds one.
                # Narrow but reachable: the unreadable row wins only when it is the sole
                # work-segmented session — one analyzed ride on a fresh database.
                _ = (Metrics.usable_date_days(a.date)).map_err(|_| BadActivityDate(a.date, a.id))?
                # The anchor must itself BE a repeated shape before anything can
                # share it. The old rule printed "3x11:58" over sessions whose
                # reps ran 2187/67/250s: banding the MEAN says nothing about the
                # spread, and with rep count already fixed, a mean band is
                # arithmetically just a total-work-time band.
                band = Metrics.rep_duration_band(a.mean_dur)
                # The ANCHOR must be a repeated shape or there is nothing to compare against: a
                # session whose blocks run 2187/67/250s has the same mean as a real 3x12 and is
                # not a repeated set. Candidates are NOT filtered on this — each reports its own
                # spread and the coach judges (#154). 1.6x, up from 1.4x, which refused a session
                # this very ranking placed second-most-comparable — "comparable enough to show
                # you" and "not repeated enough to be a workout" in the same breath.
                anchor_uniform = Metrics.is_uniform_reps(a.min_dur, a.max_dur)
                if !(anchor_uniform) {
                    Output.err_out!("irregular_anchor", "the blocks detected in this session vary too much to be one repeated shape (${(a.min_dur).to_str()}s to ${(a.max_dur).to_str()}s, and an anchor's blocks must sit within ${Render.fmt1(Metrics.anchor_uniformity_max)}x of each other) — nothing to compare it against as a repeated workout")
                } else {
                # same family, same rep count, same rep-duration band, and never
                # later than the anchor — the same no-future-leak rule as #160,
                # so re-running this on an old session reproduces its answer.
                sessions = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT a2.id AS id, COALESCE(substr(CAST(a2.start_local AS TEXT), 1, 10), '') AS date, COALESCE(CAST(a2.name AS TEXT), '') AS name,
                        \\       COUNT(*) AS reps,
                        \\       CAST(AVG(s.avg_signal) AS REAL) AS mean_w,
                        \\       CAST(AVG(s.dur_s) AS INTEGER) AS mean_dur,
                        \\       MIN(s.dur_s) AS min_dur, MAX(s.dur_s) AS max_dur
                        \\FROM activity_segments s JOIN activities a2 ON a2.id = s.activity_id
                        \\JOIN activities self ON self.id = :id
                        \\WHERE s.kind = 'work'
                        \\  AND COALESCE(a2.sport_family, a2.sport_type) = COALESCE(self.sport_family, self.sport_type)
                        \\  AND a2.start_local <= self.start_local
                        \\  AND COALESCE(s.signal, '') = :sig
                        \\GROUP BY s.activity_id
                        \\HAVING COUNT(*) = :reps
                        \\   AND CAST(AVG(s.dur_s) AS INTEGER) >= :blo
                        \\   AND CAST(AVG(s.dur_s) AS INTEGER) < :bhi
                        \\-- keep the MOST COMPARABLE twelve, not the most recent.
                        \\-- Declining to filter on uniformity and then letting a
                        \\-- recency cap discard the two most uniform sessions in
                        \\-- the history (review measured exactly that) defers the
                        \\-- judgment and withholds the data for it. Ties break by
                        \\-- recency; the rows are re-sorted by date for display.
                        \\-- the ANCHOR always keeps its row: ranking decides which
                        \\-- twelve are shown, and a table that answers "am I
                        \\-- riding this harder?" without the session being asked
                        \\-- about answers nothing. Round 2 got this for free from
                        \\-- recency (the anchor is newest by construction);
                        \\-- ranking by uniformity removed that guarantee.
                        \\ORDER BY (a2.id = :id) DESC,
                        \\         (CAST(MAX(s.dur_s) AS REAL) / MAX(MIN(s.dur_s), 1)) ASC,
                        \\         a2.start_local DESC, a2.id DESC
                        \\LIMIT 12
                    ,
                    bindings: [
                        { name: ":id", value: Integer(a.id) },
                        { name: ":reps", value: Integer(a.reps) },
                        { name: ":blo", value: Integer(band.lo) },
                        { name: ":bhi", value: Integer(band.hi) },
                        { name: ":sig", value: String(a.signal) },
                    ],
                    rows: |cols| |stmt| {
                        id = Sqlite.i64("id")(cols)(stmt)?
                        date = Sqlite.str("date")(cols)(stmt)?
                        name = Sqlite.str("name")(cols)(stmt)?
                        reps = Sqlite.i64("reps")(cols)(stmt)?
                        mean_w = Sqlite.f64("mean_w")(cols)(stmt)?
                        mean_dur = Sqlite.i64("mean_dur")(cols)(stmt)?
                        min_dur = Sqlite.i64("min_dur")(cols)(stmt)?
                        max_dur = Sqlite.i64("max_dur")(cols)(stmt)?
                        Ok({ id, date, name, reps, mean_w, mean_dur, min_dur, max_dur })
                    },
                })?
                # how many sessions the rule matched, before the window. The
                # repo does not ship silent caps (form_band_days_capped is the
                # precedent), and review found the cap evicting the only two
                # genuinely comparable sessions in the history while keeping
                # eleven unrelated ones.
                matched = Sqlite.query!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT COUNT(*) AS n FROM (
                        \\  SELECT s.activity_id
                        \\  FROM activity_segments s JOIN activities a2 ON a2.id = s.activity_id
                        \\  JOIN activities self ON self.id = :id
                        \\  WHERE s.kind = 'work'
                        \\    AND COALESCE(a2.sport_family, a2.sport_type) = COALESCE(self.sport_family, self.sport_type)
                        \\    AND a2.start_local <= self.start_local
                        \\    AND COALESCE(s.signal, '') = :sig
                        \\  GROUP BY s.activity_id
                        \\  HAVING COUNT(*) = :reps
                        \\     AND CAST(AVG(s.dur_s) AS INTEGER) >= :blo
                        \\     AND CAST(AVG(s.dur_s) AS INTEGER) < :bhi
                        \\)
                    ,
                    bindings: [
                        { name: ":id", value: Integer(a.id) },
                        { name: ":reps", value: Integer(a.reps) },
                        { name: ":blo", value: Integer(band.lo) },
                        { name: ":bhi", value: Integer(band.hi) },
                        { name: ":sig", value: String(a.signal) },
                    ],
                    row: Sqlite.i64("n"),
                })?
                rows_for! = |aid| Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT ordinal AS ordinal, dur_s AS dur_s, CAST(avg_signal AS REAL) AS avg_signal,
                        \\       -- the writer never leaves this NULL (Analyze binds
                        \\       -- 'power' or 'pace'); COALESCE keeps the decoder
                        \\       -- total, and '' is declared in the schema rather
                        \\       -- than manufactured outside it
                        \\       COALESCE(CAST(signal AS TEXT), '') AS signal,
                        \\       CAST(COALESCE(avg_hr, 0) AS REAL) AS avg_hr,
                        \\       CASE WHEN avg_hr IS NULL THEN 0 ELSE 1 END AS hr_known,
                        \\       CAST(COALESCE(rec_drop_60s, 0) AS REAL) AS rec_drop,
                        \\       CASE WHEN rec_drop_60s IS NULL THEN 0 ELSE 1 END AS rec_drop_known
                        \\FROM activity_segments WHERE activity_id = :aid AND kind = 'work'
                        \\ORDER BY ordinal
                    ,
                    bindings: [{ name: ":aid", value: Integer(aid) }],
                    rows: |cols| |stmt| {
                        ordinal = Sqlite.i64("ordinal")(cols)(stmt)?
                        dur_s = Sqlite.i64("dur_s")(cols)(stmt)?
                        avg_signal = Sqlite.f64("avg_signal")(cols)(stmt)?
                        signal = Sqlite.str("signal")(cols)(stmt)?
                        avg_hr = Sqlite.f64("avg_hr")(cols)(stmt)?
                        hr_known = Sqlite.i64("hr_known")(cols)(stmt)?
                        rec_drop = Sqlite.f64("rec_drop")(cols)(stmt)?
                        rec_drop_known = Sqlite.i64("rec_drop_known")(cols)(stmt)?
                        Ok({ ordinal, dur_s, avg_signal, signal, avg_hr, hr_known: hr_known != 0, rec_drop, rec_drop_known: rec_drop_known != 0 })
                    },
                })
                # selection ranked by uniformity, DISPLAY by date — the coach reads a trend down
                # the page. Str has no ordering in this Roc, so sort on parsed day numbers.
                # GUARDED, and the guard produces the key rather than sitting beside it (#270):
                # `.ok_or(0)` collapsed an unreadable comparable to the epoch and headed the
                # by-date table with it. One expression, so the guard's domain IS the sort key's
                # domain.
                keyed = List.map_try(sessions, |sn|
                    (Metrics.usable_date_days(sn.date))
                        .map_err(|_| BadActivityDate(sn.date, sn.id))
                        .map_ok(|d| { d, sn }))?
                by_date = List.map(List.sort_with(keyed, |x, y| if x.d > y.d LT else if x.d < y.d GT else EQ), |k| k.sn)
                built = List.map_try!(by_date, |sn| {
                    rs = rows_for!(sn.id)?
                    first_w = (List.first(rs)).map_ok(|r| r.avg_signal).ok_or(0.0)
                    last_w = (List.last(rs)).map_ok(|r| r.avg_signal).ok_or(0.0)
                    # first-to-last means the FIRST and LAST reps, not the first
                    # and last reps that happen to carry HR — review found a
                    # session with HR on reps 1 and 2 reporting a "first-to-last"
                    # rise that spanned reps 1 to 2 while the legend claimed
                    # otherwise. If either end is missing, the span is unknown.
                    first_r = List.first(rs)
                    last_r = List.last(rs)
                    ends_have_hr : Bool
                    ends_have_hr = (first_r.map_ok(|r| r.hr_known) ?? False) and (last_r.map_ok(|r| r.hr_known) ?? False)
                    first_hr = (first_r).map_ok(|r| r.avg_hr).ok_or(0.0)
                    last_hr = (last_r).map_ok(|r| r.avg_hr).ok_or(0.0)
                    hr_span_known : Bool
                    hr_span_known = ends_have_hr and List.len(rs) >= 2
                    Ok({
                        id: sn.id,
                        date: sn.date,
                        name: sn.name,
                        rep_count: sn.reps,
                        mean_signal: sn.mean_w,
                        mean_dur_s: sn.mean_dur,
                        # the spread of THIS session's reps. The filter finds candidates by count and
                        # scale; whether a 588-1232s spread is "the same workout" as an even 3x12 is
                        # judgment, so stride reports the dispersion and the coach decides (#154). The
                        # anchor is gated on it — no consistent shape means nothing to be compared AS —
                        # but a candidate is only described.
                        min_dur_s: sn.min_dur,
                        max_dur_s: sn.max_dur,
                        uniformity: if sn.min_dur > 0 (sn.max_dur).to_f64() / (sn.min_dur).to_f64() else 0.0,
                        # fade WITHIN the session: last rep minus first. Signed,
                        # because holding or building is as real as fading.
                        fade_signal: last_w - first_w,
                        # what the same work cost in heartbeats by the last rep
                        hr_rise_bpm: if hr_span_known last_hr - first_hr else 0.0,
                        hr_rise_known: hr_span_known,
                        reps: rs,
                    })
                })?
                if Output.json_mode!({})
                    Output.emit_ok!({
                        anchor_date: a.date,
                        anchor_activity_id: a.id,
                        # the shape every session here shares — the comparability
                        # rule, stated rather than implied
                        shape: { rep_count: a.reps, mean_dur_s: a.mean_dur, band_lo_s: band.lo, band_hi_s: band.hi, signal: a.signal },
                        sport_family: a.fam,
                        # matched BEFORE the window; sessions is capped at 12,
                        # newest first, so a caller can see what it is not seeing
                        matched_total: matched,
                        sessions: built,
                    })
                else
                    Stdout.line!(Render.reps_screen({ anchor_date: a.date, shape_reps: a.reps, shape_dur: a.mean_dur, matched_total: matched, signal: a.signal, sessions: built }))
                }
            }
        }
    }
    progress! : Str, [Asc, Desc] => Try({}, _)
    progress! = |date_arg, sort| {
        path = Db.open_db!({})?
        date =
            if !(Str.is_empty(date_arg))
                date_arg
            else {
                latest = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS d, COALESCE(CAST(a.name AS TEXT), '') AS name, a.id AS id
                        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id
                        \\ORDER BY ${Metrics.rank_ts_sql("a.start_local", Desc)}, a.id DESC LIMIT 1
                    ,
                    bindings: [],
                    rows: |cols| |stmt| {
                        d = Sqlite.str("d")(cols)(stmt)?
                        name = Sqlite.str("name")(cols)(stmt)?
                        id = Sqlite.i64("id")(cols)(stmt)?
                        Ok({ d, name, id })
                    },
                })?
                # The sixth site in this file (the issue counted five). `ORDER BY ... DESC` puts
                # NULLs LAST, so this only surfaces when the unreadable row is the only scored
                # activity — which is why it hides. COALESCE stops the decode crashing; the guard
                # stops the empty string becoming an anchor (`:date` bound to `''` matches no
                # row, so `progress` would answer `no_scorable_workouts` over scored workouts).
                _ = List.map_try(latest, |r| (Metrics.usable_date_days(r.d)).map_err(|_| BadActivityDate(r.d, r.id)))?
                match List.first(latest) {
                    Ok(r) => r.d
                    Err(_) => ""
                }
            }
        prows : List(Metrics.ProgressRow)
        prows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(CAST(a.name AS TEXT), '') AS name, a.id AS id, COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS date, COALESCE(CAST(a.sport_type AS TEXT), '') AS sport,
                \\       CAST(COALESCE(a.distance,0) AS REAL) AS distance_m, a.moving_time AS moving_time,
                \\       CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w, CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
                \\       CAST(COALESCE(m.avg_hr_stream, a.avg_hr, 0) AS REAL) AS avg_hr_scored,
                \\       CAST(COALESCE(rt.rpe,0) AS REAL) AS rpe,
                \\       CAST(COALESCE(a.avg_watts * a.moving_time / 1000.0, 0) AS REAL) AS output_kj,
                \\       CAST(COALESCE(m.tss,0) AS REAL) AS tss,
                \\       COALESCE(CAST(m.load_model AS TEXT), '') AS load_model,
                \\       CAST(COALESCE(m.decoupling_pct, 0) AS REAL) AS decoupling_pct,
                \\       CASE WHEN m.decoupling_pct IS NULL THEN 0 ELSE 1 END AS decoupling_known
                \\FROM activities a
                \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\LEFT JOIN ratings rt ON rt.activity_id = a.id
                \\WHERE a.name IN (SELECT name FROM activities WHERE substr(start_local, 1, 10) = :date)
                \\ORDER BY a.name, a.start_local, a.id
            ,
            bindings: [{ name: ":date", value: String(date) }],
            rows: |cols| |stmt| {
                name = Sqlite.str("name")(cols)(stmt)?
                row_id = Sqlite.i64("id")(cols)(stmt)?
                row_date = Sqlite.str("date")(cols)(stmt)?
                sport = Sqlite.str("sport")(cols)(stmt)?
                distance_m = Sqlite.f64("distance_m")(cols)(stmt)?
                moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                np_w = Sqlite.f64("np_w")(cols)(stmt)?
                avg_hr = Sqlite.f64("avg_hr")(cols)(stmt)?
                avg_hr_scored = Sqlite.f64("avg_hr_scored")(cols)(stmt)?
                rpe = Sqlite.f64("rpe")(cols)(stmt)?
                output_kj = Sqlite.f64("output_kj")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                load_model = Sqlite.str("load_model")(cols)(stmt)?
                dpct = Sqlite.f64("decoupling_pct")(cols)(stmt)?
                dknown = Sqlite.i64("decoupling_known")(cols)(stmt)?
                Ok({ name, date: row_date, sport, distance_m, moving_time, np_w, avg_hr, avg_hr_scored, rpe, output_kj, tss, load_model, decoupling_pct: dpct, decoupling_known: dknown == 1, id: row_id })
            },
        })?
        # REFUSES, because `progress` computes a TREND across dates — an unreadable date
        # does not go missing, it becomes a POSITION. `ORDER BY a.name, a.start_local`
        # sorts the empty string FIRST, relocating the newest session to the earliest
        # slot: measured, the verdict moved from "improving (28%)" to "improving (19%)"
        # with `best: 1.49 ()` — every number real, conclusion wrong, exit 0. `""` is
        # also taken: SKILL.md documents `'' = none on record` for
        # `last_hard_session_date`, so an empty date already means "no such thing".
        _ = List.map_try(prows, |r| (Metrics.usable_date_days(r.date)).map_err(|_| BadActivityDate(r.date, r.id)))?
        labeled =
            List.keep_oks(Metrics.group_progress(prows), |g| Metrics.anchor_filter(g, date))
           .map(|g| { name: Render.progress_group_label(g.name, g.kind), rows: g.rows, total: g.total, scope_why: g.scope_why })
        # choose each group's lens, keep only rows it can score; drop unscorable groups
        keep_scored = |lens, g| {
            kept = List.keep_if(g.rows, |r| Metrics.lens_score(lens, r).is_ok())
            # Asked per GROUP, against the anchor ROW itself — not "is some row on that date
            # still here". anchor_filter picks the FIRST row on the date, so two same-name
            # sessions on one day mean a dropped anchor can hide behind its surviving twin.
            anchor_ok =
                match List.find_first(g.rows, |r| r.date == date) {
                    Ok(a) => Metrics.lens_score(lens, a).is_ok()
                    Err(_) => False
                }
            # `all_days` is every session in the group BEFORE the lens filter, so the gap
            # marker can be folded over the real chronology rather than over what survived.
            all_days = List.keep_oks(g.rows, |r| Metrics.date_str_to_days(r.date))
            # `hidden` counts everything the reader cannot see, from BOTH gates. Counting
            # `g.rows - kept` measured only the lens filter, and `g.rows` is already
            # scope-truncated — so a group scoped from 29 rows to 1 reported `hidden: 0` and
            # printed "first session of this workout". `g.total` is what makes "zero means
            # the whole history" true rather than hopeful.
            scope_dropped = g.total - List.len(g.rows)
            lens_dropped = List.len(g.rows) - List.len(kept)
            # No reason string is derived here any more — `hidden_reason` (one string, both
            # causes) retired with #286. Once an unscorable row RENDERS, the two causes are
            # two different outcomes: a scope drop is hidden, a lens drop is shown without a
            # score, so one sentence counting them together is wrong about the half the
            # reader can see. The lens wording lives in `Metrics.lens_needs`, called with the
            # count it describes. The PAYLOAD is untouched: `sessions[]` still holds only
            # scored rows, so `hidden`/`hidden_lens`/`hidden_scope` mean what they meant.
            hidden = scope_dropped + lens_dropped
            # `display_rows` is the group AFTER the scope gate but BEFORE the lens gate — the
            # human table shows a ride the lens cannot score instead of deleting it. Three of
            # `Ef`'s six columns (np, kJ, load) were computed for those rows and thrown away.
            # The PAYLOAD keeps `rows: kept`: `sessions[]` is what the agent trends over, an
            # unscored row has no score to trend, and `hidden_lens` already says how many and
            # why — the two surfaces agree on the COUNT and differ in what they do with it.
            if List.is_empty(kept) Err(Skip) else Ok({ name: g.name, lens, rows: kept, display_rows: g.rows, scope_why: g.scope_why, anchor_ok, all_days, hidden, scope_dropped, lens_dropped })
        }
        scored = List.keep_oks(labeled, |g|
            match Metrics.progress_lens(g.rows) {
                Ef => keep_scored(Ef, g)
                SpeedHr => keep_scored(SpeedHr, g)
                Rpe => keep_scored(Rpe, g)
                Unscorable => Err(Skip)
            })
        # Did the session we anchored on survive its own lens? keep_scored drops rows the
        # lens can't score, and the anchor is not exempt — the group is then non-empty, so
        # the unscorable branch never fires and the table renders a trend computed
        # entirely from sessions the athlete did not ask about.
        # Counted PER GROUP: a date holding two workouts makes two groups, and "some group
        # kept the date" lets a surviving group mask a sibling that lost its anchor or was
        # dropped whole. Equality against the labeled count catches both.
        anchor_kept = List.len(scored) == List.len(labeled) and List.all(scored, |g| g.anchor_ok)
        # The two ways the anchor can fail to be SCORED are two different outcomes now: a
        # lens refusal leaves the row visible in `display_rows` with blank lens cells; a
        # skipped group leaves nothing at all. `anchor_scored` in the payload keeps
        # meaning "does a score exist", which is why this split lives here, not in the
        # flag (#286).
        anchor_group_dropped = List.len(scored) != List.len(labeled)
        if List.is_empty(scored) {
            if Str.is_empty(date) {
                Output.err_out!("no_scorable_workouts", "nothing to compare yet — analyze activities first (and `stride rate` your strength sessions)")
            } else {
                on_date = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query: "SELECT COALESCE(CAST(name AS TEXT), '') AS name, id AS id FROM activities WHERE substr(start_local, 1, 10) = :date LIMIT 1",
                    bindings: [{ name: ":date", value: String(date) }],
                    rows: |cols| |stmt| {
                        name = Sqlite.str("name")(cols)(stmt)?
                        id = Sqlite.i64("id")(cols)(stmt)?
                        Ok({ name, id })
                    },
                })?
                match List.first(on_date) {
                    Ok(a) => Output.err_out!("unscorable", "found \"${a.name}\" on ${date}, but it can't be compared — needs power+HR, distance+HR, or a rating (`stride rate <id> <1-10>`)")
                    Err(_) => Output.err_out!("no_workout_on_date", "no workout found on ${date}")
                }
            }
        } else if Output.json_mode!({}) {
            Output.emit_ok!({
                anchor_date: date,
                # False = at least one workout anchored on this date lost its own row after
                # scoring (a date can hold several workouts, hence several groups), so that
                # session is absent from `groups` and the trends exclude it. Bool-TYPED, not
                # a bare tag.
                anchor_scored: anchor_kept,
                groups: List.map(scored, |g| {
                    name: g.name,
                    lens: lens_name(g.lens),
                    # ...and how many sessions of this workout the lens could NOT score, so
                    # `sessions` is never read as the whole history. The human render says it
                    # and the payload did not — and the payload is the half the coaching
                    # agent reads. A group holding one session with `hidden: 10` is not a
                    # workout done once (#292).
                    hidden: g.hidden,
                    # ...and its two causes, because they license OPPOSITE actions: a lens drop is
                    # fixable at the source (wear the strap, rate the session); a scope drop is not,
                    # and is not even about the same slice of training. On real data 35 groups hide
                    # both kinds at once, indistinguishable through one integer. Split in the PAYLOAD
                    # only — the human line keeps one number because two read worse, and the payload
                    # is where anyone branches.
                    hidden_lens: g.lens_dropped,
                    hidden_scope: g.scope_dropped,
                    # scores/trends upstream are computed on chronological rows; the sort only changes
                    # the ORDER sessions are listed in. progress sessions carry NO power_known/hr_known:
                    # rows exist only because the group's LENS scored them, so the signal is present by
                    # construction; np_w/avg_hr are auxiliary display fields, 0 = absent.
                    sessions: List.map((match sort { Asc => g.rows Desc => Render.reverse_list(g.rows) }), |r| {
                        date: r.date,
                        sport: r.sport,
                        score: Metrics.lens_score(g.lens, r).ok_or(0.0),
                        np_w: r.np_w,
                        avg_hr: r.avg_hr,
                        avg_hr_scored: r.avg_hr_scored,
                        distance_m: r.distance_m,
                        moving_time: r.moving_time,
                        rpe: r.rpe,
                        output_kj: r.output_kj,
                        tss: r.tss,
                        # per-session aerobic decoupling (#135), same honesty pair as
                        # everywhere else — 0.0 is a real perfect result, the flag decides
                        decoupling_pct: r.decoupling_pct,
                        decoupling_known: r.decoupling_known,
                    }),
                }),
            })
        } else {
            # Say it BEFORE the table. Read after, it looks like a footnote to numbers the
            # athlete has already taken as including their session.
            note =
                if anchor_kept {
                    ""
                } else if anchor_group_dropped {
                    "⚠ a session on ${date} isn't shown in any table below — every session in its group was withheld, so there is nothing to compare it against\n\n"
                } else {
                    # It IS in the table now, so the banner says where to look rather than
                    # that it is missing. The old wording — "isn't shown in its own table" —
                    # became false the moment unscorable rows started rendering, and it sat
                    # directly above a table containing the row it denied.
                    "⚠ the session on ${date} is shown below WITHOUT a score — the lens chosen for its group can't score it (needs power+HR, distance+HR, or a rating), so the trend(s) exclude it even though the row is there\n\n"
                }
            Stdout.line!("${note}${Str.join_with(List.map(scored, |g| Render.progress_section(g.name, g.display_rows, date, g.lens, sort, g.all_days, g.scope_dropped, g.scope_why)), "\n\n")}")
        }
    }
}
