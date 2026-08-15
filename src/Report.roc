import Db
import Output
import Strava
import Streams
import Analyze
import Csv
import pf.Sqlite
import pf.Stdout
import pf.Path
import Metrics
import Render

Report :: [].{
    # ── shared queries ──────────────────────────────────────────────────

    # zone + TSS totals for activities on/after a cutoff date
    zone_sum! : Str, Str => Try({ z1 : I64, z2 : I64, z3 : I64, z4 : I64, z5 : I64, tss : F64, measured : F64, easy : I64, moderate : I64, hard : I64, sessions : I64, moving_time : I64, distance_m : F64, hr_streams : I64, intensity_streams : I64 }, _)
    zone_sum! = |path, cutoff|
        Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(SUM(m.z1_s),0) AS z1, COALESCE(SUM(m.z2_s),0) AS z2, COALESCE(SUM(m.z3_s),0) AS z3,
                \\       COALESCE(SUM(m.z4_s),0) AS z4, COALESCE(SUM(m.z5_s),0) AS z5, CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss,
                \\       -- load from a MEASURED source — a power meter or GPS-measured pace
                \\       -- (high-confidence rungs) — vs estimated from HR/RPE/relative-effort
                \\       CAST(COALESCE(SUM(CASE WHEN m.load_model IN ('power_stream','weighted_watts','avg_watts','rtss') THEN m.tss ELSE 0 END),0) AS REAL) AS measured,
                \\       -- polarization intensity per activity: POWER split when the activity has
                \\       -- power-intensity time, else the HR zones. So a power ride's threshold
                \\       -- work counts as hard even when HR sat on a zone boundary.
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_easy_s ELSE m.z1_s + m.z2_s END),0) AS easy,
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_moderate_s ELSE m.z3_s END),0) AS moderate,
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_hard_s ELSE m.z4_s + m.z5_s END),0) AS hard,
                \\       COUNT(*) AS sessions, COALESCE(SUM(a.moving_time),0) AS moving_time,
                \\       CAST(COALESCE(SUM(a.distance),0) AS REAL) AS distance_m,
                \\       COALESCE(SUM(CASE WHEN s.raw_json LIKE '%"heartrate"%' THEN 1 ELSE 0 END),0) AS hr_streams,
                \\       COALESCE(SUM(CASE WHEN s.raw_json LIKE '%"heartrate"%' OR s.raw_json LIKE '%"watts"%' OR s.raw_json LIKE '%"distance"%' THEN 1 ELSE 0 END),0) AS intensity_streams
                \\FROM activities a
                \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\LEFT JOIN streams s ON s.activity_id = a.id
                \\WHERE a.start_local >= :cutoff
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff) }],
            row: |cols| |stmt| {
                z1 = Sqlite.i64("z1")(cols)(stmt)?
                z2 = Sqlite.i64("z2")(cols)(stmt)?
                z3 = Sqlite.i64("z3")(cols)(stmt)?
                z4 = Sqlite.i64("z4")(cols)(stmt)?
                z5 = Sqlite.i64("z5")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                measured = Sqlite.f64("measured")(cols)(stmt)?
                easy = Sqlite.i64("easy")(cols)(stmt)?
                moderate = Sqlite.i64("moderate")(cols)(stmt)?
                hard = Sqlite.i64("hard")(cols)(stmt)?
                sessions = Sqlite.i64("sessions")(cols)(stmt)?
                moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                distance_m = Sqlite.f64("distance_m")(cols)(stmt)?
                hr_streams = Sqlite.i64("hr_streams")(cols)(stmt)?
                intensity_streams = Sqlite.i64("intensity_streams")(cols)(stmt)?
                Ok({ z1, z2, z3, z4, z5, tss, measured, easy, moderate, hard, sessions, moving_time, distance_m, hr_streams, intensity_streams })
            },
        })

    # activity stats within a half-open [from, to) date window (both are date strings
    # compared against start_local; ISO makes the lexical compare correct)
    window_stats! : Str, Str, Str => Try({ z1 : I64, z2 : I64, z3 : I64, z4 : I64, z5 : I64, tss : F64, sessions : I64 }, _)
    window_stats! = |path, from_str, to_str|
        Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(SUM(m.z1_s),0) AS z1, COALESCE(SUM(m.z2_s),0) AS z2, COALESCE(SUM(m.z3_s),0) AS z3,
                \\       COALESCE(SUM(m.z4_s),0) AS z4, COALESCE(SUM(m.z5_s),0) AS z5,
                \\       CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss, COUNT(*) AS sessions
                \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE a.start_local >= :from AND a.start_local < :to
            ,
            bindings: [{ name: ":from", value: String(from_str) }, { name: ":to", value: String(to_str) }],
            row: |cols| |stmt| {
                z1 = Sqlite.i64("z1")(cols)(stmt)?
                z2 = Sqlite.i64("z2")(cols)(stmt)?
                z3 = Sqlite.i64("z3")(cols)(stmt)?
                z4 = Sqlite.i64("z4")(cols)(stmt)?
                z5 = Sqlite.i64("z5")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                sessions = Sqlite.i64("sessions")(cols)(stmt)?
                Ok({ z1, z2, z3, z4, z5, tss, sessions })
            },
        })

    # CTL as of a given day (most recent daily_load row on or before it); 0 if none
    ctl_at! : Str, Str => Try(F64, _)
    ctl_at! = |path, day_str|
        match Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT ctl AS ctl FROM daily_load WHERE day <= :d ORDER BY day DESC LIMIT 1",
            bindings: [{ name: ":d", value: String(day_str) }],
            row: Sqlite.f64("ctl"),
        }) {
            Ok(v) => Ok(v)
            Err(NoRowsReturned) => Ok(0.0)
            Err(e) => Err(e)
        }

    # period-over-period: this rolling window vs the one immediately before it
    compare! : Str => Try({}, _)
    compare! = |period| {
        path = Db.open_db!({})?
        if period != "week" and period != "month" {
            Output.err_out!("bad_period", "compare week | compare month (got '${period}')")
        } else {
            days = if period == "month" 28 else 7
            label = if period == "month" "28d" else "7d"
            match Sqlite.query!({ path: Path.utf8(path), query: "SELECT day AS day FROM daily_load ORDER BY day DESC LIMIT 1", bindings: [], row: Sqlite.str("day") }) {
                Err(NoRowsReturned) => Output.err_out!("no_data", "nothing analyzed yet — run `stride sync` (or `stride import`) then `stride analyze`")
                Err(e) => Err(e)
                Ok(latest_day) => {
                    anchor = Metrics.date_str_to_days(latest_day).ok_or(0)
                    cur_from = Metrics.days_to_date_str(anchor - (days - 1))
                    cur_to = Metrics.days_to_date_str(anchor + 1)
                    pri_from = Metrics.days_to_date_str(anchor - (2 * days - 1))
                    cur = window_stats!(path, cur_from, cur_to)?
                    pri = window_stats!(path, pri_from, cur_from)?
                    cur_ctl = ctl_at!(path, Metrics.days_to_date_str(anchor))?
                    pri_ctl = ctl_at!(path, Metrics.days_to_date_str(anchor - days))?
                    # has_data distinguishes a genuinely-empty window (no activities AND no
                    # accrued fitness) from a real all-easy/zero week. Without it the prior
                    # block reads as "0 TSS, 0% easy, 0 ctl" — indistinguishable from a rest
                    # week — and the current-vs-prior delta looks like a phantom spike.
                    block = |w, ctl| {
                        tss: w.tss,
                        sessions: w.sessions,
                        hard_min: (w.z4 + w.z5) // 60,
                        easy_pct: pct_num(w.z1 + w.z2, w.z1 + w.z2 + w.z3 + w.z4 + w.z5),
                        ctl,
                        has_data: w.sessions > 0 or ctl > 0.0,
                    }
                    Output.out!({ period, window_label: label, current: block(cur, cur_ctl), prior: block(pri, pri_ctl) }, Render.compare_screen)
                }
            }
        }
    }

    # does a row with this id exist? (table is an internal literal, never user input)
    row_exists! : Str, Str, I64 => Try(Bool, _)
    row_exists! = |path, table, id| {
        n = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT COUNT(*) AS n FROM ${table} WHERE id = :id",
            bindings: [{ name: ":id", value: Integer(id) }],
            row: Sqlite.i64("n"),
        })?
        Ok(n > 0)
    }
    pct_num : I64, I64 -> I64
    pct_num = |part, total|
        if total == 0
            0
        else
            ((part).to_f64() * 100.0 / (total).to_f64()).round_to_i64_try().ok_or(0)

    # one session in depth: metrics + zones + power bests computed from local streams
    activity! : Str => Try({}, _)
    activity! = |id_str| {
        path = Db.open_db!({})?
        match I64.from_str(id_str) {
            Err(_) => Output.err_out!("activity_not_found", "activity ${id_str} not found (run `stride activities` to list ids)")
            Ok(aid) => activity_body!(path, id_str, aid)

        }
    }
    activity_body! : Str, Str, I64 => Try({}, _)
    activity_body! = |path, id_str, aid| {
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.id AS id, substr(a.start_local, 1, 10) AS date, a.sport_type AS sport, a.name AS name,
                \\       a.moving_time AS moving_time, CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
                \\       CAST(COALESCE(m.tss,0) AS REAL) AS tss, CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
                \\       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                \\       CAST(COALESCE(m.ftp_used,0) AS REAL) AS ftp_used,
                \\       COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
                \\       COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s,
                \\       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
                \\       CAST(COALESCE(m.decoupling_pct, 0) AS REAL) AS decoupling_pct,
                \\       CASE WHEN m.decoupling_pct IS NULL THEN 0 ELSE 1 END AS decoupling_known,
                \\       COALESCE(m.decoupling_signal, '') AS decoupling_signal
                \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE a.id = :id LIMIT 1
            ,
            bindings: [{ name: ":id", value: Integer(aid) }],
            rows: |cols| |stmt| {
                id = Sqlite.i64("id")(cols)(stmt)?
                date = Sqlite.str("date")(cols)(stmt)?
                sport = Sqlite.str("sport")(cols)(stmt)?
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
                # split into value + flag in SQL rather than a nullable decoder: 0.0 is a
                # REAL result here (a perfectly steady session), so the flag is the only
                # thing that separates "flat" from "no power meter" (#94)
                decoupling_pct = Sqlite.f64("decoupling_pct")(cols)(stmt)?
                decoupling_known = Sqlite.i64("decoupling_known")(cols)(stmt)?
                decoupling_signal = Sqlite.str("decoupling_signal")(cols)(stmt)?
                Ok({ id, date, sport, name, moving_time, distance_m, tss, np_w, intensity, ftp_used, z1_s, z2_s, z3_s, z4_s, z5_s, avg_hr, decoupling_pct, decoupling_known: decoupling_known != 0, decoupling_signal })
            },
        })?
        match List.first(rows) {
            Err(_) => Output.err_out!("activity_not_found", "activity ${id_str} not found (run `stride activities` to list ids)")
            Ok(a) => {
                raw_rows = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query: "SELECT raw_json AS raw FROM streams WHERE activity_id = :id",
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
                        \\SELECT ordinal, kind, start_s, dur_s, CAST(avg_signal AS REAL) AS avg_signal, signal,
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
                pintensity = { easy_s: detail.easy_s, moderate_s: detail.moderate_s, hard_s: detail.hard_s }
                has_power_intensity = (pintensity.easy_s + pintensity.moderate_s + pintensity.hard_s) > 0

                if Output.json_mode!({})
                    Output.emit_ok!({
                        id: a.id,
                        date: a.date,
                        sport: a.sport,
                        name: a.name,
                        moving_time: a.moving_time,
                        distance_m: a.distance_m,
                        tss: a.tss,
                        np_w: a.np_w,
                        intensity: a.intensity,
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
                        interval_summary,
                        # TRUE = the detector actually ran with a signal (power, or
                        # pace on a pace-routed sport). Distinguishes "verified: no
                        # interval structure" from "couldn't look" — an empty segments
                        # list alone conflates the two.
                        detection_attempted: detail.has_watts or (Metrics.pace_detect_sport(a.sport) and detail.has_dist),
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
                    (if detail.max_hr > 0
                        Stdout.line!("hr     max ${Render.fmt0(detail.max_hr)} · avg ${Render.fmt0(a.avg_hr)}")
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
                    if detail.failed
                        Stdout.line!("⚠ stored stream data for this activity is unreadable — zeros above are missing data, not real zeros")
                    else
                        Ok({})
                }
            }
        }
    }
    # career + year-to-date totals per sport
    stats! : {} => Try({}, _)
    stats! = |{}| {
        path = Db.open_db!({})?
        today_days = Db.local_today_days!(path)
        year = (Metrics.civil_from_days(today_days)).y
        all_time = stats_rows!(path, "0000-01-01")?
        ytd = stats_rows!(path, "${(year).to_str()}-01-01")?
        if Output.json_mode!({})
            Output.emit_ok!({ all_time, ytd, ytd_year: year })
        else {
            to_table = |rows|
                Render.render_table(
                    ["sport", "sessions", "time", "distance"],
                    List.map(rows, |r| [
                        r.sport,
                        (r.sessions).to_str(),
                        "${Render.fmt0(r.hours)}h",
                        (if r.km >= 1.0 "${Render.fmt0(r.km)} km" else "-"),
                    ]),
                )
            Stdout.line!("ALL TIME")?
            Stdout.line!(to_table(all_time))?
            Stdout.line!("")?
            Stdout.line!("${(year).to_str()} YEAR TO DATE")?
            Stdout.line!(to_table(ytd))
        }
    }
    stats_rows! : Str, Str => Try(List({ sport : Str, sessions : I64, hours : F64, km : F64 }), _)
    stats_rows! = |path, cutoff|
        Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT sport_type AS sport, COUNT(*) AS sessions,
                \\       CAST(SUM(moving_time) / 3600.0 AS REAL) AS hours,
                \\       CAST(COALESCE(SUM(distance), 0) / 1000.0 AS REAL) AS km
                \\FROM activities WHERE start_local >= :cutoff
                \\GROUP BY sport_type ORDER BY sessions DESC, sport_type
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff) }],
            rows: |cols| |stmt| {
                sport = Sqlite.str("sport")(cols)(stmt)?
                sessions = Sqlite.i64("sessions")(cols)(stmt)?
                hours = Sqlite.f64("hours")(cols)(stmt)?
                km = Sqlite.f64("km")(cols)(stmt)?
                Ok({ sport, sessions, hours, km })
            },
        })

    # the one-call coach-input payload
    summary! : {} => Try({}, _)
    summary! = |{}| {
        path = Db.open_db!({})?
        match Analyze.load_zone_config!(path) {
            Err(MissingConfig) => Output.missing_config!({})
            Err(other) => Err(other)
            Ok(zb) =>
                match summary_payload!(path, zb) {
                    Err(NoDataYet) => Output.err_out!("no_data", "nothing analyzed yet — run `stride sync` (or `stride import`) then `stride analyze`")
                    Err(e) => Err(e)
                    Ok(payload) => Output.out!(payload, Render.summary_screen)
                }
        }
    }
    # weekly-planning bundle: everything the coach needs to plan a week, in one call
    plan_bundle! : {} => Try({}, _)
    plan_bundle! = |{}| {
        path = Db.open_db!({})?
        match Analyze.load_zone_config!(path) {
            Err(MissingConfig) => Output.missing_config!({})
            Err(other) => Err(other)
            Ok(zb) =>
                match summary_payload!(path, zb) {
                    Err(NoDataYet) => Output.err_out!("no_data", "nothing analyzed yet — run `stride sync` (or `stride import`) then `stride analyze`")
                    Err(e) => Err(e)
                    Ok(s) => {
                anchor = (Metrics.date_str_to_days(s.as_of)).ok_or(0)
                # anchor-13, not anchor-14: the range is INCLUSIVE of both ends, so
                # `>= anchor - 14` spans fifteen days while the section header and the
                # `recent_activities_14d` field both promise fourteen. Nobody could count
                # the difference while only days with activities were rendered; showing
                # every day made the extra one visible. Narrowing the window keeps the
                # name honest — the alternative, relabelling to 15, would have meant
                # renaming the JSON field and breaking its consumers over a fencepost.
                cutoff14 = Metrics.days_to_date_str(anchor - 13)
                recent = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT a.id AS id, substr(a.start_local, 1, 10) AS date, a.sport_type AS sport, a.name AS name,
                        \\       a.moving_time AS moving_time, CAST(COALESCE(m.tss,0) AS REAL) AS tss,
                        \\       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                        \\       COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
                        \\       COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s,
                        \\       COALESCE(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_hard_s ELSE m.z4_s + m.z5_s END, 0) AS hard_s,
                        \\       CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
                        \\       CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
                        \\       CAST(COALESCE(a.relative_effort,0) AS REAL) AS relative_effort,
                        \\       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr
                        \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                        \\WHERE a.start_local >= :cutoff
                        \\ORDER BY a.start_local DESC, a.id DESC
                    ,
                    bindings: [{ name: ":cutoff", value: String(cutoff14) }],
                    rows: |cols| |stmt| {
                        id = Sqlite.i64("id")(cols)(stmt)?
                        date = Sqlite.str("date")(cols)(stmt)?
                        sport = Sqlite.str("sport")(cols)(stmt)?
                        name = Sqlite.str("name")(cols)(stmt)?
                        moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                        tss = Sqlite.f64("tss")(cols)(stmt)?
                        intensity = Sqlite.f64("intensity")(cols)(stmt)?
                        z1_s = Sqlite.i64("z1_s")(cols)(stmt)?
                        z2_s = Sqlite.i64("z2_s")(cols)(stmt)?
                        z3_s = Sqlite.i64("z3_s")(cols)(stmt)?
                        z4_s = Sqlite.i64("z4_s")(cols)(stmt)?
                        z5_s = Sqlite.i64("z5_s")(cols)(stmt)?
                        hard_s = Sqlite.i64("hard_s")(cols)(stmt)?
                        distance_m = Sqlite.f64("distance_m")(cols)(stmt)?

                        np_w = Sqlite.f64("np_w")(cols)(stmt)?

                        relative_effort = Sqlite.f64("relative_effort")(cols)(stmt)?

                        avg_hr = Sqlite.f64("avg_hr")(cols)(stmt)?
                        Ok({ id, date, sport, name, moving_time, tss, intensity, z1_s, z2_s, z3_s, z4_s, z5_s, hard_s, distance_m, np_w, relative_effort, avg_hr })
                    },
                })?
                open_p = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT id AS id, COALESCE(target_date,'') AS target_date, COALESCE(session_type,'') AS session_type,
                        \\       COALESCE(detail,'') AS detail, COALESCE(rationale,'') AS rationale
                        \\FROM planned_sessions WHERE COALESCE(status, 'open') = 'open'
                        \\ORDER BY target_date, id
                    ,
                    bindings: [],
                    rows: |cols| |stmt| {
                        id = Sqlite.i64("id")(cols)(stmt)?
                        target_date = Sqlite.str("target_date")(cols)(stmt)?
                        session_type = Sqlite.str("session_type")(cols)(stmt)?
                        detail = Sqlite.str("detail")(cols)(stmt)?
                        rationale = Sqlite.str("rationale")(cols)(stmt)?
                        Ok({ id, target_date, session_type, detail, rationale })
                    },
                })?
                if Output.json_mode!({}) {
                    Output.emit_ok!({
                        summary: s,
                        recent_activities_14d: recent,
                        open_sessions: open_p,
                    })
                } else {
                    Stdout.line!(Render.summary_screen(s))?
                    Stdout.line!("")?
                    Stdout.line!("OPEN PLAN")?
                    Stdout.line!(Render.render_table(
                        ["id", "date", "type", "detail"],
                        List.map(open_p, |p| [(p.id).to_str(), p.target_date, p.session_type, p.detail]),
                    ))?
                    Stdout.line!("")?
                    Stdout.line!("RECENT 14 DAYS")?
                    # This table is a DATE RANGE, so a day with nothing on it is information:
                    # it was a rest day, planned or not. Rendering only the days that HAVE
                    # activities made the reader diff dates to notice a gap — an explicit row
                    # says it outright. Human table only: the JSON payload stays a list of
                    # real activities and never gains pseudo-rows with no id.
                    # 14 DAYS, matching the `>= anchor - 13` cutoff above — not 14 rows: a
                    # day with two activities contributes two. The walk and the query have
                    # to span the same days, or the table shows one the query never
                    # returned (always blank) or hides one it did.
                    # Week boundaries get a full-width rule. The table runs newest-first, so
                    # the boundary falls just ABOVE each Sunday — never above the first row,
                    # which needs no divider.
                    recent_headers = ["date", "sport", "name", "time", "load", "hard"]
                    # A full-width horizontal rule, drawn by render_table in the table's own
                    # border glyphs so it lines up with the header rule. It must not be a
                    # glyph in every cell: `progress` uses `···` to mean a GAP in time, so
                    # reusing it here made a boundary between two CONSECUTIVE days read as
                    # missing days.
                    week_div = Render.rule
                    recent_display = List.join(List.map(Render.indices(14), |i| {
                        d = anchor - (i).to_i64_wrap()
                        ds = Metrics.days_to_date_str(d)
                        on_day = List.keep_if(recent, |a| a.date == ds)
                        day_rows =
                            if List.is_empty(on_day) {
                                # header-driven like the divider: the label sits in whichever
                                # column is NAMED "name" and every other cell is a dash, so a
                                # new column widens this row instead of leaving it short. The
                                # activity rows below stay positional by necessity — each cell
                                # is a different field, which no header list can express.
                                [List.map(recent_headers, |h|
                                    if h == "date" {
                                        ds
                                    } else if h == "name" {
                                        "(no activity)"
                                    } else {
                                        "-"
                                    })]
                            } else {
                                List.map(on_day, |a| [a.date, a.sport, a.name, Render.mins(a.moving_time), Render.fmt0(a.tss), Render.mins(a.hard_s)])
                            }
                        if i > 0 and Metrics.day_of_week(d) == "Sun" {
                            List.prepend(day_rows, week_div)
                        } else {
                            day_rows
                        }
                    }))
                    Stdout.line!(Render.render_table(recent_headers, recent_display))
                }
                    }
                }
        }
    }
    summary_payload! = |path, zb| {
        # empty daily_load (nothing analyzed yet) is a clean "no data" state, not an
        # error to blow up on — map NoRowsReturned to a tag the callers turn into a
        # friendly message instead of leaking a raw SQLite error to the user.
        latest =
            match Sqlite.query!({
                path: Path.utf8(path),
                query: "SELECT day AS day, ctl AS ctl, atl AS atl, tsb AS tsb FROM daily_load ORDER BY day DESC LIMIT 1",
                bindings: [],
                row: |cols| |stmt| {
                    day = Sqlite.str("day")(cols)(stmt)?
                    ctl = Sqlite.f64("ctl")(cols)(stmt)?
                    atl = Sqlite.f64("atl")(cols)(stmt)?
                    tsb = Sqlite.f64("tsb")(cols)(stmt)?
                    Ok({ day, ctl, atl, tsb })
                },
            }) {
                Ok(v) => Ok(v)
                Err(NoRowsReturned) => Err(NoDataYet)
                Err(e) => Err(e)
            }?
        # PROPAGATE a bad anchor day, exactly as the ramp rows below do — the same guard,
        # applied to the value those rows are compared AGAINST. Defaulting to epoch day 0
        # here is worse than for a row: this one binding drives every cutoff, the ramp
        # window, form_delta_7d and days_in_band. A junk `day` sorts to the top of
        # `ORDER BY day DESC` (string sort), becomes `latest`, and then either lands the
        # cutoffs in the far future (every window returns nothing, and summary prints a
        # confident all-zero report) or in 1969 (every "last 28 days" window silently
        # becomes all-time). Both exit 0 with nothing flagged.
        anchor = (Metrics.date_str_to_days(latest.day)).map_err(|_| BadDailyLoadDay(latest.day))?
        # Inclusive >= cutoffs: today plus 27/59 prior days are true 28/60-day windows.
        cutoff28 = Metrics.days_to_date_str(anchor - 27)
        cutoff60 = Metrics.days_to_date_str(anchor - 59)

        zsum = zone_sum!(path, cutoff28)?

        best20_row = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT CAST(COALESCE(MAX(m.best_20min_w),0) AS REAL) AS b FROM activity_metrics m
                \\JOIN activities a ON a.id = m.activity_id
                \\WHERE a.start_local >= :cutoff
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff60) }],
            row: Sqlite.f64("b"),
        })?

        sports = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.sport_type AS sport, COUNT(*) AS sessions, CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss,
                \\       COALESCE(SUM(a.moving_time),0) AS moving_time, CAST(COALESCE(SUM(a.distance),0) AS REAL) AS distance_m
                \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE a.start_local >= :cutoff
                \\GROUP BY a.sport_type ORDER BY tss DESC, a.sport_type
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff28) }],
            rows: |cols| |stmt| {
                sport = Sqlite.str("sport")(cols)(stmt)?
                sessions = Sqlite.i64("sessions")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                distance_m = Sqlite.f64("distance_m")(cols)(stmt)?
                Ok({ sport, sessions, tss, moving_time, distance_m })
            },
        })?

        cutoff7 = Metrics.days_to_date_str(anchor - 6)
        zsum7 = zone_sum!(path, cutoff7)?

        pending = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT COUNT(*) AS n FROM planned_sessions WHERE COALESCE(status, 'open') = 'open'",
            bindings: [],
            row: Sqlite.i64("n"),
        })?

        # most recent day with a real hard stimulus (5+ min in Z4/Z5); '' = never
        last_hard = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(MAX(substr(a.start_local, 1, 10)), '') AS d
                \\FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
                \\WHERE m.z4_s + m.z5_s >= 300
            ,
            bindings: [],
            row: Sqlite.str("d"),
        })?

        # polarization is power-aware: easy/moderate/hard come from POWER zones for
        # activities that have power-intensity, HR zones otherwise (zone_sum! per-activity)
        total = zsum.easy + zsum.moderate + zsum.hard
        easy = zsum.easy
        hard = zsum.hard
        # what fraction of the 28d load is measured (power) vs estimated (HR/RPE/RE) —
        # so the fitness number carries its own confidence, not just doctor's
        measured_pct = if zsum.tss > 0.0 ((zsum.measured / zsum.tss) * 100.0).round_to_i64_try().ok_or(0) else 0
        total7 = zsum7.easy + zsum7.moderate + zsum7.hard
        easy7 = zsum7.easy
        hard7 = zsum7.hard

        # CTL/ATL seed at zero on the first day with any activity, so a short history reads
        # LOW rather than unknown. One 42-day time constant only gets CTL to ~63% of its true
        # value, so 42 days is where it is still MOST wrong, not where it becomes right; the
        # threshold is two constants (~90 d, ~88% converged), past which the form bands —
        # absolute numbers — start meaning something. COUNT(*) always returns a row, so this
        # query cannot hit the absent-key crash.
        load_days = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT COUNT(*) AS n FROM daily_load",
            bindings: [],
            row: Sqlite.i64("n"),
        })?

        # #93 ramp: reuses the `anchor` this function already computed, rather than
        # deriving the same day again — two bindings for one day can drift, and then the
        # ramp window and summary's 7d/28d windows would disagree about which day "now"
        # is. 30 days of series covers the 28-day ramp lookback with room for gaps — and now
        # also bounds days_in_band, which has NO natural upper limit. That is why the streak
        # returns AtLeast when it fills this window rather than a bare number: widening the
        # window moves the truncation point, it does not remove it.
        ramp_rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT day AS day, CAST(ctl AS REAL) AS ctl, CAST(tsb AS REAL) AS tsb FROM daily_load WHERE day >= :cutoff ORDER BY day DESC",
            bindings: [{ name: ":cutoff", value: String(Metrics.days_to_date_str(anchor - 30)) }],
            rows: |cols| |stmt| {
                d = Sqlite.str("day")(cols)(stmt)?
                c = Sqlite.f64("ctl")(cols)(stmt)?
                # tsb rides along on the ramp query rather than getting its own: the two
                # lookbacks want the same rows over the same window, and a second query
                # could disagree with this one about which days exist (#111).
                t = Sqlite.f64("tsb")(cols)(stmt)?
                Ok({ d, ctl: c, tsb: t })
            },
        })?
        # Convert OUTSIDE the decoder, whose error union has no room for BadDate, and
        # PROPAGATE rather than defaulting a bad day to epoch-day 0. That default is not
        # harmless: a day-0 row is a valid candidate for any lookback, so where the series
        # genuinely does not reach back far enough, ctl_as_of would return that row's ctl
        # as Found instead of Missing — a fabricated ramp exactly where the honest answer
        # is 0. daily_load days are engine-written and canonical, so this is a guard
        # against corruption, and corruption should stop the command rather than quietly
        # change the number it prints.
        # Prepend, not append: ctl_as_of takes the max qualifying day and so does not care
        # about order, and appending inside a fold is the quadratic trap.
        dated_load = List.fold(ramp_rows, Ok([]), |acc, r|
            match acc {
                Err(e) => Err(e)
                Ok(xs) =>
                    match Metrics.date_str_to_days(r.d) {
                        Ok(day) => Ok(List.prepend(xs, { day, ctl: r.ctl, tsb: r.tsb }))
                        Err(_) => Err(BadDailyLoadDay(r.d))
                    }
            })?
        # one validated series, two views — each helper takes a closed record, so the
        # projections keep the date validation above from being done twice
        ramps = Metrics.ramp_rates(List.map(dated_load, |e| { day: e.day, ctl: e.ctl }), anchor)
        form_delta = Metrics.form_delta_7d(List.map(dated_load, |e| { day: e.day, tsb: e.tsb }), anchor)
        # how long the band has held (#123) — the thing the label itself cannot say
        band_days = Metrics.days_in_band(List.map(dated_load, |e| { day: e.day, tsb: e.tsb }), anchor)
        # ANNOTATED Bool, not a bare `True`/`False` tag. The builtin JSON serializes an
        # unconstrained tag as the STRING "True". This payload happens to escape that
        # already — but for a reason worth stating correctly, because the wrong reason
        # teaches the wrong rule: it is RENDERED as well as encoded, and
        # `Render.summary_screen` consumes the field as an `if` condition, which flows the
        # Bool constraint back through the un-annotated renderer. analyze's payload is
        # encode-only, so nothing constrained it and it shipped "True". Neighbouring Bool
        # fields have nothing to do with it — record fields do not constrain one another.
        # The rule: an encode-only payload has no constraint on its tags, so annotate.
        band_capped : Bool
        band_capped = match band_days { AtLeast(_) => True  _ => False }
        delta_known : Bool
        delta_known = match form_delta { Known(_) => True  Unknown => False }

        Ok({
            as_of: latest.day,
            fitness_ctl: latest.ctl,
            ramp_7d: ramps.ramp_7d,
            ramp_28d_avg: ramps.ramp_28d_avg,
            fatigue_atl: latest.atl,
            form_tsb: latest.tsb,
            # ADDITIVE field, so the envelope version stays (same precedent as `converged`
            # and the ramp fields). Unknown flattens to 0.0 here, which is the house
            # meaning of a numeric 0 — "not available", not "form did not move". The human
            # renderer keeps the distinction and simply omits the clause.
            form_delta_7d: match form_delta { Known(d) => d  Unknown => 0.0 },
            # 0.0 is ambiguous HERE in a way the house "0 = not available" rule does not
            # cover: form genuinely level for a week is a real, useful answer that is also
            # exactly 0. So the flag carries what the number cannot, for machine consumers
            # as much as for the renderer.
            form_delta_known: delta_known,
            # 0 = not available, per the house rule; a real streak is always >= 1.
            # The value alone cannot say whether it is exact or truncated by the window,
            # so it travels with a flag — see form_band_days_capped.
            form_band_days: match band_days { Known(n) => n  AtLeast(n) => n  Unknown => 0 },
            # TRUE means the streak filled the whole series and is a FLOOR, not a count.
            # `dated_load` is a 31-day window sized for the #93 ramp, so a 45-day streak
            # arrives here as 31; without this flag the coach reads 31 as fact. Annotated
            # Bool for the same reason delta_known is.
            form_band_days_capped: band_capped,
            load_days: load_days,
            ctl_warming_up: load_days < 90,
            last_hard_session_date: last_hard,
            pending_sessions: pending,
            last_7d: {
                tss: zsum7.tss,
                z1_s: zsum7.z1,
                z2_s: zsum7.z2,
                z3_s: zsum7.z3,
                z4_s: zsum7.z4,
                z5_s: zsum7.z5,
                easy_pct: pct_num(easy7, total7),
                moderate_pct: pct_num(zsum7.moderate, total7),
                hard_pct: pct_num(hard7, total7),
                sessions: zsum7.sessions,
                moving_time: zsum7.moving_time,
                distance_m: zsum7.distance_m,
                hr_streams: zsum7.hr_streams,
                intensity_streams: zsum7.intensity_streams,
            },
            last_28d: {
                tss: zsum.tss,
                z1_s: zsum.z1,
                z2_s: zsum.z2,
                z3_s: zsum.z3,
                z4_s: zsum.z4,
                z5_s: zsum.z5,
                easy_pct: pct_num(easy, total),
                moderate_pct: pct_num(zsum.moderate, total),
                hard_pct: pct_num(hard, total),
                measured_pct: measured_pct,
                sessions: zsum.sessions,
                moving_time: zsum.moving_time,
                distance_m: zsum.distance_m,
                hr_streams: zsum.hr_streams,
                intensity_streams: zsum.intensity_streams,
            },
            ftp: {
                best_20min_w_60d: best20_row,
                estimated_ftp_w: Metrics.ftp_from_best_20min(best20_row),
            },
            hr_zones: { z1_max: zb.z1_max, z2_max: zb.z2_max, z3_max: zb.z3_max, z4_max: zb.z4_max },
            sports_28d: sports,
        })
    }
    activities! : U64, Str => Try({}, _)
    activities! = |limit, sport_filter| {
        path = Db.open_db!({})?
        sf = sport_filter_sql(sport_filter)
        # optional sport filter via sport_filter_sql: the FRAGMENT is interpolated
        # (its placeholders are numbered, values stay real bindings), and the empty
        # branch is a single space, never "" — interpolating a compile-time-constant
        # empty string crashes this backend in str_concat (#32 class; fixed upstream
        # in roc#10595 but our pinned nightly predates it). Non-empty by construction
        # is the rule the :all-flag comment in Plan.roc states.
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.id AS id, substr(a.start_local, 1, 10) AS date, a.sport_type AS sport, a.name AS name,
                \\       a.moving_time AS moving_time, CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
                \\       CAST(COALESCE(m.tss,0) AS REAL) AS tss, CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
                \\       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                \\       COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
                \\       COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s,
                \\       -- hard time: power (at/above threshold) when the activity has power-
                \\       -- intensity, else HR Z4+Z5. So a power ride's threshold work counts.
                \\       COALESCE(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_hard_s ELSE m.z4_s + m.z5_s END, 0) AS hard_s,
                \\       CAST(COALESCE(a.relative_effort,0) AS REAL) AS relative_effort,
                \\       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr
                \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE (1=1${sf.frag})
                \\ORDER BY a.start_local DESC, a.id DESC LIMIT ${(limit).to_str()}
            ,
            bindings: sf.binds,
            rows: |cols| |stmt| {
                id = Sqlite.i64("id")(cols)(stmt)?
                date = Sqlite.str("date")(cols)(stmt)?
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
                Ok({ id, date, sport, name, moving_time, distance_m, tss, np_w, intensity, z1_s, z2_s, z3_s, z4_s, z5_s, hard_s, relative_effort, avg_hr })
            },
        })?
        if Output.json_mode!({})
            Output.emit_ok!(rows)
        else if List.is_empty(rows) and !(Str.is_empty(sport_filter)) {
            Stdout.line!(empty_hint!(path, sport_filter, "any")?)
        } else {
            Stdout.line!(Render.render_table(
                ["date", "sport", "name", "time", "load", "intensity (if)", "hard"],
                List.map(rows, |a| [
                    a.date,
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
            Stdout.line!("hard:           minutes at/above threshold — by power (vs the sport's FTP) where there's power, else HR Z4+Z5")
        }
    }
    # metric keyword => its ORDER BY column + human table header. The column is HARDCODED
    # per keyword, so no user input ever reaches the SQL; an unknown metric errors before
    # any query. Single source of truth so column and header can't drift apart.
    top_metric : Str -> Try({ col : Str, header : Str }, [BadMetric])
    top_metric = |m|
        match m {
            "hr" => Ok({ col: "a.avg_hr", header: "heart rate (hr)" })
            "tss" => Ok({ col: "m.tss", header: "load" })
            "power" => Ok({ col: "m.normalized_power", header: "power (np)" })
            "intensity" => Ok({ col: "m.intensity_factor", header: "intensity (if)" })
            "distance" => Ok({ col: "a.distance", header: "distance (km)" })
            "time" => Ok({ col: "a.moving_time", header: "time (min)" })
            "output" => Ok({ col: "(a.avg_watts * a.moving_time)", header: "output (kj)" }) # total work (Peloton kJ)
            _ => Err(BadMetric)

        }
    # ranked "best sessions": top N activities by a chosen metric (vs `activities`,
    # which is chronological). e.g. `top hr`, `top tss 5 rowing`.
    # sport-word filter shared by top/activities/power-curve: the human word
    # widens to its Strava family (Metrics.sport_family), matched IN (...) with
    # NOCASE. Placeholders are numbered so the bindings stay real bindings.
    sport_filter_sql : Str -> { frag : Str, binds : List({ name : Str, value : [Null, Real(F64), Integer(I64), String(Str), Bytes(List(U8))] }) }
    sport_filter_sql = |word|
        if Str.is_empty(word) {
            # a lone SPACE, never "": interpolating a compile-time-constant empty
            # string is the #32-class str_concat trap, live on the pinned nightly
            { frag: " ", binds: [] }
        } else {
            fam = Metrics.sport_family(word)
            names = List.map_with_index(fam, |_, i| ":sp${(i).to_str()}")
            { frag: " AND a.sport_type COLLATE NOCASE IN (${Str.join_with(names, ", ")})", binds: List.map_with_index(fam, |s, i| { name: ":sp${(i).to_str()}", value: String(s) }) }
        }

    # the no-silent-empty hint: what sports DOES the data hold
    known_sports! : Str => Try(List(Str), _)
    known_sports! = |path|
        Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT DISTINCT sport_type AS s FROM activities WHERE sport_type IS NOT NULL AND sport_type <> '' ORDER BY s",
            bindings: [],
            rows: Sqlite.str("s"),
        })

    # An empty filtered result has TWO honest explanations and the hint must pick
    # the right one: no such sport at all, or the sport exists but nothing in it
    # carries the asked-for data. Blaming the sport unconditionally once denied
    # the existence of runs while listing Run in the same sentence.
    empty_hint! : Str, Str, Str => Try(Str, _)
    empty_hint! = |path, word, what| {
        sf = sport_filter_sql(word)
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
            Ok("${I64.to_str(n)} '${word}' activities, but none with ${what} data")
        }
    }

    top! : Str, U64, Str => Try({}, _)
    top! = |metric, limit, sport_filter| {
        path = Db.open_db!({})?
        match top_metric(metric) {
            Err(_) =>
                Output.err_out!("bad_metric", "unknown metric '${metric}' — use: hr, tss, power, intensity, distance, time, output")

            Ok({ col, header }) => {
                sf = sport_filter_sql(sport_filter)
                sport_where = sf.frag
                sport_binding = sf.binds
                rows = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT a.id AS id, substr(a.start_local, 1, 10) AS date, a.sport_type AS sport, a.name AS name,
                        \\       a.moving_time AS moving_time, CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
                        \\       CAST(COALESCE(m.tss,0) AS REAL) AS tss, CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
                        \\       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                        \\       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
                        \\       CAST(COALESCE(a.avg_watts * a.moving_time / 1000.0, 0) AS REAL) AS output_kj
                        \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                        \\WHERE ${col} > 0${sport_where}
                        \\ORDER BY ${col} DESC, a.id DESC LIMIT ${(limit).to_str()}
                    ,
                    bindings: sport_binding,
                    rows: |cols| |stmt| {
                        id = Sqlite.i64("id")(cols)(stmt)?
                        date = Sqlite.str("date")(cols)(stmt)?
                        sport = Sqlite.str("sport")(cols)(stmt)?
                        name = Sqlite.str("name")(cols)(stmt)?
                        moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                        distance_m = Sqlite.f64("distance_m")(cols)(stmt)?
                        tss = Sqlite.f64("tss")(cols)(stmt)?
                        np_w = Sqlite.f64("np_w")(cols)(stmt)?
                        intensity = Sqlite.f64("intensity")(cols)(stmt)?
                        avg_hr = Sqlite.f64("avg_hr")(cols)(stmt)?
                        output_kj = Sqlite.f64("output_kj")(cols)(stmt)?
                        Ok({ id, date, sport, name, moving_time, distance_m, tss, np_w, intensity, avg_hr, output_kj })
                    },
                })?
                if Output.json_mode!({})
                    Output.emit_ok!(rows)
                else if List.is_empty(rows) and !(Str.is_empty(sport_filter)) {
                    Stdout.line!(empty_hint!(path, sport_filter, header)?)
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
                        List.map(rows, |r| [r.date, r.sport, val(r), r.name]),
                    ))
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
        id = I64.from_str(field("Activity ID", 0)).map_err(|_| BadRow)?
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
    doctor! : {} => Try({}, _)
    doctor! = |{}| {
        path = Db.open_db!({})?
        cov = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COUNT(*) AS total,
                \\       COALESCE(SUM(CASE WHEN a.avg_hr > 0 THEN 1 ELSE 0 END), 0) AS with_hr,
                \\       COALESCE(SUM(CASE WHEN COALESCE(a.avg_watts, a.weighted_avg_watts, 0) > 0 THEN 1 ELSE 0 END), 0) AS with_power,
                \\       COALESCE(SUM(CASE WHEN s.activity_id IS NOT NULL AND s.raw_json <> '{}' THEN 1 ELSE 0 END), 0) AS with_streams,
                \\       COALESCE(SUM(CASE WHEN m.activity_id IS NULL THEN 1 ELSE 0 END), 0) AS unanalyzed,
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.tss, 0) = 0 AND m.activity_id IS NOT NULL THEN 1 ELSE 0 END), 0) AS zero_load
                \\FROM activities a
                \\LEFT JOIN streams s ON s.activity_id = a.id
                \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
            ,
            bindings: [],
            row: |cols| |stmt| {
                total = Sqlite.i64("total")(cols)(stmt)?
                with_hr = Sqlite.i64("with_hr")(cols)(stmt)?
                with_power = Sqlite.i64("with_power")(cols)(stmt)?
                with_streams = Sqlite.i64("with_streams")(cols)(stmt)?
                unanalyzed = Sqlite.i64("unanalyzed")(cols)(stmt)?
                zero_load = Sqlite.i64("zero_load")(cols)(stmt)?
                Ok({ total, with_hr, with_power, with_streams, unanalyzed, zero_load })
            },
        })?
        models = Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT COALESCE(load_model, 'unknown (pre-provenance)') AS model, COUNT(*) AS n FROM activity_metrics GROUP BY load_model ORDER BY n DESC, load_model",
            bindings: [],
            rows: |cols| |stmt| {
                model = Sqlite.str("model")(cols)(stmt)?
                n = Sqlite.i64("n")(cols)(stmt)?
                Ok({ model, n })
            },
        })?
        conf = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\-- confidence tiers derived from load_model at read time (not stored): high =
                \\-- measured power, medium = HR/RPE, low = relative_effort, none = unscored. The
                \\-- e2e cross-checks the 'high' count against the power-rung provenance counts so
                \\-- this mapping can't silently drift.
                \\SELECT COALESCE(SUM(CASE WHEN load_model IN ('power_stream','weighted_watts','avg_watts','rtss') THEN 1 ELSE 0 END),0) AS hi,
                \\       COALESCE(SUM(CASE WHEN load_model IN ('hr_zones','hr_avg','session_rpe') THEN 1 ELSE 0 END),0) AS med,
                \\       COALESCE(SUM(CASE WHEN load_model='relative_effort' THEN 1 ELSE 0 END),0) AS lo,
                \\       COALESCE(SUM(CASE WHEN load_model IS NULL OR load_model NOT IN ('power_stream','weighted_watts','avg_watts','rtss','hr_zones','hr_avg','session_rpe','relative_effort') THEN 1 ELSE 0 END),0) AS non
                \\FROM activity_metrics
            ,
            bindings: [],
            row: |cols| |stmt| {
                hi = Sqlite.i64("hi")(cols)(stmt)?
                med = Sqlite.i64("med")(cols)(stmt)?
                lo = Sqlite.i64("lo")(cols)(stmt)?
                non = Sqlite.i64("non")(cols)(stmt)?
                Ok({ hi, med, lo, non })
            },
        })?
        pending = Strava.pending_streams!(path)?
        cfg = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT (SELECT COUNT(DISTINCT a.sport_type) FROM activity_metrics m
                \\        JOIN activities a ON a.id = m.activity_id WHERE m.ftp_used > 0 AND a.sport_type IS NOT NULL AND a.sport_type <> '') AS derived_ftp_sports,
                \\       COALESCE(SUM(CASE WHEN key IN ('hr_z1_max','hr_z2_max','hr_z3_max','hr_z4_max') THEN 1 ELSE 0 END),0) AS zones_set,
                \\       COALESCE(SUM(CASE WHEN key GLOB 'hr_z[1-4]_max_?*' THEN 1 ELSE 0 END),0) AS sport_zone_overrides
                \\FROM config
            ,
            bindings: [],
            row: |cols| |stmt| {
                derived_ftp_sports = Sqlite.i64("derived_ftp_sports")(cols)(stmt)?
                zones_set = Sqlite.i64("zones_set")(cols)(stmt)?
                sport_zone_overrides = Sqlite.i64("sport_zone_overrides")(cols)(stmt)?
                Ok({ derived_ftp_sports, zones_set, sport_zone_overrides })
            },
        })?
        # strength-class sessions without a rating: aggregate in Roc so the sport
        # list can't drift from Metrics.sport_class
        sports = Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT COALESCE(a.sport_type, '') AS sport, CASE WHEN r.activity_id IS NULL THEN 0 ELSE 1 END AS rated FROM activities a LEFT JOIN ratings r ON r.activity_id = a.id",
            bindings: [],
            rows: |cols| |stmt| {
                sport = Sqlite.str("sport")(cols)(stmt)?
                rated = Sqlite.i64("rated")(cols)(stmt)?
                Ok({ sport, rated })
            },
        })?
        strength_unrated = List.len(List.keep_if(sports, |r| Metrics.sport_class(r.sport) == StrengthLike and r.rated == 0))
        rated_total = List.len(List.keep_if(sports, |r| r.rated == 1))
        # ── data-quality watchdog (#92): streaks and counts the engine already knows ──
        # Anchored to the LOCAL day like every other window, not SQLite's `now`, so a user
        # west of UTC does not get a window that ends tomorrow.
        cutoff30 = Metrics.days_to_date_str(Db.local_today_days!(path) - 30)
        # newest-first, and bounded: a streak only needs enough rows to find the session
        # that DID record HR. 200 is far past any plausible strapless run.
        recent_hr = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(sport_type, '') AS sport,
                \\       CASE WHEN COALESCE(avg_hr, 0) > 0 THEN 1 ELSE 0 END AS has_hr
                \\FROM activities ORDER BY start_local DESC, id DESC LIMIT 200
            ,
            bindings: [],
            rows: |cols| |stmt| {
                sport = Sqlite.str("sport")(cols)(stmt)?
                has_hr = Sqlite.i64("has_hr")(cols)(stmt)?
                Ok({ sport, has_hr: has_hr == 1 })
            },
        })?
        hr_missing_streak = Metrics.hr_missing_streak(recent_hr)
        # device_watts = 0 is Strava saying the watts were ESTIMATED, not measured. NULL
        # (pre-flag syncs, CSV imports) coalesces to 1: unknown is not evidence of
        # estimation, matching how the scoring ladder reads the same column.
        est_power_30d = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COUNT(*) AS n FROM activities
                \\WHERE start_local >= :cutoff
                \\  AND COALESCE(device_watts, 1) = 0
                \\  AND COALESCE(avg_watts, weighted_avg_watts, 0) > 0
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff30) }],
            row: Sqlite.i64("n"),
        })?
        # Pooled share over the window AND the worst single session, because they answer
        # different questions: pooled is the trend ("is my strap degrading"), worst is the
        # incident ("did something break on Tuesday"). A pooled number alone hides one
        # dead-strap session inside a big volume week; a per-session average alone spikes
        # every week with a lot of short sessions. Both, or neither is trustworthy.
        # NULLIF guards the divide: an activity with no samples contributes nothing rather
        # than a division by zero.
        junk = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(
                \\         100.0 * SUM(COALESCE(m.hr_samples_dropped,0) + COALESCE(m.watts_samples_dropped,0))
                \\         / NULLIF(SUM(COALESCE(m.hr_samples_total,0) + COALESCE(m.watts_samples_total,0)), 0), 0.0) AS pooled,
                \\       COALESCE(MAX(
                \\         100.0 * (COALESCE(m.hr_samples_dropped,0) + COALESCE(m.watts_samples_dropped,0))
                \\         / NULLIF(COALESCE(m.hr_samples_total,0) + COALESCE(m.watts_samples_total,0), 0)), 0.0) AS worst
                \\FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
                \\WHERE a.start_local >= :cutoff
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff30) }],
            row: |cols| |stmt| {
                pooled = Sqlite.f64("pooled")(cols)(stmt)?
                worst = Sqlite.f64("worst")(cols)(stmt)?
                Ok({ pooled, worst })
            },
        })?
        jmode = Db.journal_mode!(path)?
        mode = Db.resolve_time_mode!(path)
        time_desc =
            match mode {
                Zone(name, off) => "timezone ${name} (${Db.fmt_offset(off)} now, DST-aware)"
                FixedOffset(off) => "fixed offset ${Db.fmt_offset(off)} (adjust seasonally for DST)"
                BadZone(name, off) => "timezone '${name}' UNKNOWN to system tz db — using ${Db.fmt_offset(off)}; fix the name or set utc_offset_minutes"
                Utc => "UTC (set `timezone` or `utc_offset_minutes` if you're not on UTC)"
            }
        # Bool-TYPED, not bare True/False tags: the builtin JSON serializes a bare tag as the
        # string "True"/"False", which breaks the boolean contract (a consumer sees "True",
        # not true). Same fix as the config `redacted` field. `1 == 1` / `1 == 0` are Bool.
        time_ok =
            match mode {
                BadZone(_, _) => 1 == 0
                _ => 1 == 1
            }
        payload = {
            activities: cov.total,
            with_hr: cov.with_hr,
            with_power: cov.with_power,
            with_streams: cov.with_streams,
            unanalyzed: cov.unanalyzed,
            zero_load: cov.zero_load,
            rated: rated_total,
            strength_unrated: strength_unrated.to_i64_wrap(),
            scored_by: models,
            conf_high: conf.hi,
            conf_medium: conf.med,
            conf_low: conf.lo,
            conf_none: conf.non,
            pending_streams: pending,
            ftp_derived_sports: cfg.derived_ftp_sports,
            zones_set: cfg.zones_set >= 4,
            sport_zone_overrides: cfg.sport_zone_overrides,
            time: time_desc,
            time_ok: time_ok,
            # WAL is what lets a query command run alongside a long analyze without either
            # aborting. It can silently fail to engage on filesystems lacking the shared
            # memory it needs, so report what is actually in force instead of assuming.
            journal_mode: jmode,
            concurrent_reads_ok: jmode == "wal",
            # numbers only, no advice — the coach reads them and decides (house rule)
            hr_missing_streak: hr_missing_streak.to_i64_wrap(),
            estimated_power_count_30d: est_power_30d,
            junk_filtered_pct_30d: junk.pooled,
            junk_worst_session_pct_30d: junk.worst,
        }
        Output.out!(payload, |p| {
            model_lines = List.map(p.scored_by, |mrow| "    ${mrow.model}: ${(mrow.n).to_str()}")
            hint =
                if p.strength_unrated > 0
                    ["", "  → ${(p.strength_unrated).to_str()} strength-class sessions have no rating — `stride rate <id> <1-10>` scores them honestly"]
                else
                    []
            Str.join_with(
                List.join([
                    [
                        "",
                        "── stride doctor ─────────────────────────────",
                        "",
                        "  activities: ${(p.activities).to_str()}",
                        "    with heart rate: ${(p.with_hr).to_str()}",
                        "    with power: ${(p.with_power).to_str()}",
                        "    with streams: ${(p.with_streams).to_str()}",
                        "    rated (session-RPE): ${(p.rated).to_str()}",
                        "",
                        "  scored by (load provenance):",
                    ],
                    model_lines,
                    [
                        "",
                        "  confidence (how measured each load is):",
                        "    high (power): ${(p.conf_high).to_str()}",
                        "    medium (HR / RPE): ${(p.conf_medium).to_str()}",
                        "    low (relative effort): ${(p.conf_low).to_str()}",
                        "    none (unscored): ${(p.conf_none).to_str()}",
                        "",
                        "  hr-less endurance sessions in a row: ${(p.hr_missing_streak).to_str()}",
                        "  rides on estimated power (30d): ${(p.estimated_power_count_30d).to_str()}",
                        "  junk samples dropped (30d): ${Render.fmt1(p.junk_filtered_pct_30d)}% overall · worst session ${Render.fmt1(p.junk_worst_session_pct_30d)}%",
                        "  zero load (no usable data): ${(p.zero_load).to_str()}",
                        "  not yet analyzed: ${(p.unanalyzed).to_str()}",
                        "  pending stream backfill: ${(p.pending_streams).to_str()}",
                        "  config: hr zones ${if p.zones_set "set" else "incomplete"}, ${(p.sport_zone_overrides).to_str()} per-sport zone key(s) set · ${(p.ftp_derived_sports).to_str()} sport(s) have a derived FTP (FTP is never configured — see summary)",
                        "  time: ${p.time}",
                    ],
                    hint,
                ]),
                "\n",
            )
        })
    }
    # power-zone reference chart: the 7 Coggan/Peloton zones as watt ranges from your
    # cycling FTP — derived from recent ride power, not configured (targets for a PZ ride).
    pz! : {} => Try({}, _)
    pz! = |{}| {
        path = Db.open_db!({})?
        # power zones derive from the cycling FTP (recent best 20-min ride power); no config
        ftp = Db.sport_ftp!(path, "Ride")?
        if ftp <= 0.0
            Output.err_out!("no_power_data", "no cycling FTP yet — power zones derive from your best 20-min ride power in the last 60 days. Either those rides have no power, or they haven't been analyzed: run `stride analyze` (and sync rides with a power meter).")
        else {
            zones = Metrics.power_zones(ftp)
            if Output.json_mode!({})
                Output.emit_ok!({ ftp, zones })
            else {
                range = |z|
                    if z.lo_w <= 0.0
                        "< ${Render.fmt0(z.hi_w)}"
                    else if z.hi_w <= 0.0
                        "${Render.fmt0(z.lo_w)}+"
                    else
                        "${Render.fmt0(z.lo_w)}-${Render.fmt0(z.hi_w)}"
                Stdout.line!(Render.render_table(
                    ["zone", "name", "watts (ftp ${Render.fmt0(ftp)})"],
                    List.map(zones, |z| [z.z, z.name, range(z)]),
                ))
            }
        }
    }
    # "am I improving on THIS workout?" — anchored on a date: resolves that day's workout(s)
    # and shows every comparable instance chronologically, with Efficiency Factor (NP/HR) as
    # the fitness tell. Named classes match by exact name; Strava auto-names ("Morning Ride")
    # cover different routes, so those only compare rides within ±10% of the anchor's distance.
    # JSON tag for a chosen lens
    lens_name : [Ef, SpeedHr, Rpe] -> Str
    lens_name = |lens|
        match lens {
            Ef => "ef"
            SpeedHr => "speed_hr"
            Rpe => "rpe"

        }
    # "am I improving on THIS workout?" — anchored on a date, rendered through the
    # sport-aware lens each repeated workout supports (power->EF, distance->speed/HR,
    # rated strength->RPE). Bare `progress` uses your latest analyzed workout.
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
                        \\SELECT substr(a.start_local, 1, 10) AS d, a.name AS name
                        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id
                        \\ORDER BY a.start_local DESC, a.id DESC LIMIT 1
                    ,
                    bindings: [],
                    rows: |cols| |stmt| {
                        d = Sqlite.str("d")(cols)(stmt)?
                        name = Sqlite.str("name")(cols)(stmt)?
                        Ok({ d, name })
                    },
                })?
                match List.first(latest) {
                    Ok(r) => r.d
                    Err(_) => ""
                }
            }
        prows : List(Metrics.ProgressRow)
        prows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.name AS name, substr(a.start_local, 1, 10) AS date, COALESCE(a.sport_type, '') AS sport,
                \\       CAST(COALESCE(a.distance,0) AS REAL) AS distance_m, a.moving_time AS moving_time,
                \\       CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w, CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
                \\       CAST(COALESCE(rt.rpe,0) AS REAL) AS rpe,
                \\       CAST(COALESCE(a.avg_watts * a.moving_time / 1000.0, 0) AS REAL) AS output_kj,
                \\       CAST(COALESCE(m.tss,0) AS REAL) AS tss,
                \\       COALESCE(m.load_model, '') AS load_model,
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
                row_date = Sqlite.str("date")(cols)(stmt)?
                sport = Sqlite.str("sport")(cols)(stmt)?
                distance_m = Sqlite.f64("distance_m")(cols)(stmt)?
                moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                np_w = Sqlite.f64("np_w")(cols)(stmt)?
                avg_hr = Sqlite.f64("avg_hr")(cols)(stmt)?
                rpe = Sqlite.f64("rpe")(cols)(stmt)?
                output_kj = Sqlite.f64("output_kj")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                load_model = Sqlite.str("load_model")(cols)(stmt)?
                dpct = Sqlite.f64("decoupling_pct")(cols)(stmt)?
                dknown = Sqlite.i64("decoupling_known")(cols)(stmt)?
                Ok({ name, date: row_date, sport, distance_m, moving_time, np_w, avg_hr, rpe, output_kj, tss, load_model, decoupling_pct: dpct, decoupling_known: dknown == 1 })
            },
        })?
        labeled =
            List.keep_oks(Metrics.group_progress(prows), |g| Metrics.anchor_filter(g, date))
           .map(|g| { name: Render.progress_group_label(g.name, g.kind), rows: g.rows })
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
            if List.is_empty(kept) Err(Skip) else Ok({ name: g.name, lens, rows: kept, anchor_ok })
        }
        scored = List.keep_oks(labeled, |g|
            match Metrics.progress_lens(g.rows) {
                Ef => keep_scored(Ef, g)
                SpeedHr => keep_scored(SpeedHr, g)
                Rpe => keep_scored(Rpe, g)
                Unscorable => Err(Skip)
            })
        # Did the session we anchored on survive its own lens? keep_scored drops rows the
        # lens can't score, and the anchor is not exempt — a ride with no HR vanishes from a
        # speed/HR group while its older siblings remain. The group is then non-empty, so the
        # unscorable branch below never fires and the table renders as if nothing were wrong,
        # with a trend computed entirely from sessions the athlete did not ask about.
        #
        # Counted PER GROUP, not "any group still has the date": anchor_filter drops every
        # group that lacks the anchor, so each labeled group starts with one. A date holding
        # two workouts therefore makes two groups, and asking only whether SOME group kept
        # the date lets a surviving group mask a sibling that lost its anchor — or was
        # dropped whole. Equality against the labeled count catches both.
        # Both failure modes: a whole group dropped (count mismatch), or a group that
        # survived while the row we anchored on did not.
        anchor_kept = List.len(scored) == List.len(labeled) and List.all(scored, |g| g.anchor_ok)
        if List.is_empty(scored) {
            if Str.is_empty(date) {
                Output.err_out!("no_scorable_workouts", "nothing to compare yet — analyze activities first (and `stride rate` your strength sessions)")
            } else {
                on_date = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query: "SELECT name AS name, id AS id FROM activities WHERE substr(start_local, 1, 10) = :date LIMIT 1",
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
                    # scores/trends upstream are computed on chronological rows; the sort
                    # only changes the ORDER sessions are listed in
                    sessions: List.map((match sort { Asc => g.rows Desc => Render.reverse_list(g.rows) }), |r| {
                        date: r.date,
                        sport: r.sport,
                        score: Metrics.lens_score(g.lens, r).ok_or(0.0),
                        np_w: r.np_w,
                        avg_hr: r.avg_hr,
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
                } else {
                    "⚠ a session on ${date} isn't shown in its own table — the lens chosen for its group can't score it (needs power+HR, distance+HR, or a rating), so the trend(s) below exclude it\n\n"
                }
            Stdout.line!("${note}${Str.join_with(List.map(scored, |g| Render.progress_section(g.name, g.rows, date, g.lens, sort)), "\n\n")}")
        }
    }
    load_series! : U64 => Try({}, _)
    load_series! = |days| {
        path = Db.open_db!({})?
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT day AS day, tss AS tss, ctl AS ctl, atl AS atl, tsb AS tsb FROM daily_load ORDER BY day DESC LIMIT ${(days).to_str()}",
            bindings: [],
            rows: |cols| |stmt| {
                day = Sqlite.str("day")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                ctl = Sqlite.f64("ctl")(cols)(stmt)?
                atl = Sqlite.f64("atl")(cols)(stmt)?
                tsb = Sqlite.f64("tsb")(cols)(stmt)?
                Ok({ day, tss, ctl, atl, tsb })
            },
        })?
        ordered = List.fold(rows, [], |acc, x| List.concat([x], acc))
        Output.out!(ordered, Render.load_screen)
    }

    # power-duration curve: the best mean-max power sustained for each ladder duration,
    # taken as the MAX across a window (per sport), plus a Critical Power / W' fit over the
    # aerobic points. Reads the stored best_<dur>_w columns — no stream re-read. 0-power
    # durations (no ride long enough) are dropped, so the curve only shows real data.
    power_curve! : U64, Str => Try({}, _)
    power_curve! = |days, sport| {
        path = Db.open_db!({})?
        sf = sport_filter_sql(sport)
        cutoff = Metrics.days_to_date_str(Db.local_today_days!(path) - (days).to_i64_wrap())
        r = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT
                \\  CAST(COALESCE(MAX(m.best_5s_w), 0) AS REAL) AS d5,
                \\  CAST(COALESCE(MAX(m.best_15s_w), 0) AS REAL) AS d15,
                \\  CAST(COALESCE(MAX(m.best_30s_w), 0) AS REAL) AS d30,
                \\  CAST(COALESCE(MAX(m.best_60s_w), 0) AS REAL) AS d60,
                \\  CAST(COALESCE(MAX(m.best_300s_w), 0) AS REAL) AS d300,
                \\  CAST(COALESCE(MAX(m.best_600s_w), 0) AS REAL) AS d600,
                \\  CAST(COALESCE(MAX(m.best_20min_w), 0) AS REAL) AS d1200,
                \\  CAST(COALESCE(MAX(m.best_3600s_w), 0) AS REAL) AS d3600
                \\FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
                \\WHERE a.start_local >= :cutoff${sf.frag}
            ,
            bindings: List.concat([{ name: ":cutoff", value: String(cutoff) }], sf.binds),
            row: |cols| |stmt| {
                d5 = Sqlite.f64("d5")(cols)(stmt)?
                d15 = Sqlite.f64("d15")(cols)(stmt)?
                d30 = Sqlite.f64("d30")(cols)(stmt)?
                d60 = Sqlite.f64("d60")(cols)(stmt)?
                d300 = Sqlite.f64("d300")(cols)(stmt)?
                d600 = Sqlite.f64("d600")(cols)(stmt)?
                d1200 = Sqlite.f64("d1200")(cols)(stmt)?
                d3600 = Sqlite.f64("d3600")(cols)(stmt)?
                Ok({ d5, d15, d30, d60, d300, d600, d1200, d3600 })
            },
        })?
        raw : List({ dur_s : U64, watts : F64 })
        raw = [
            { dur_s: 5, watts: r.d5 },
            { dur_s: 15, watts: r.d15 },
            { dur_s: 30, watts: r.d30 },
            { dur_s: 60, watts: r.d60 },
            { dur_s: 300, watts: r.d300 },
            { dur_s: 600, watts: r.d600 },
            { dur_s: 1200, watts: r.d1200 },
            { dur_s: 3600, watts: r.d3600 },
        ]
        points = List.keep_if(raw, |p| p.watts > 0.0)
        # fit CP/W' over the AEROBIC points (>= 5 min); short sprints are anaerobic and
        # would skew the linear P = W'/t + CP fit
        fit_points = List.map(
            # the 2-parameter hyperbolic model holds ~2-20 min; the 60-min point drags CP
            # down and W-prime up, so it is excluded from the fit (it still shows on the curve)
            List.keep_if(points, |p| p.dur_s >= 300 and p.dur_s <= 1200),
            |p| { dur_s: (p.dur_s).to_f64(), watts: p.watts },
        )
        cpfit =
            match Metrics.critical_power(fit_points) {
                # a fit is only meaningful when BOTH are positive; inconsistent bests (no true
                # 5-10 min efforts) can yield a non-positive CP or W' — treat that as no fit
                Ok(c) => (if c.cp > 0.0 and c.w_prime > 0.0 { cp: c.cp, w_prime: c.w_prime } else { cp: 0.0, w_prime: 0.0 })
                Err(_) => { cp: 0.0, w_prime: 0.0 }
            }
        Output.out!(
            { window_days: days, sport, points, cp: cpfit.cp, w_prime: cpfit.w_prime },
            Render.power_curve_screen,
        )
    }
}
