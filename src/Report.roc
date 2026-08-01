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
    zone_sum! : Str, Str => Try({ z1 : I64, z2 : I64, z3 : I64, z4 : I64, z5 : I64, tss : F64, measured : F64, easy : I64, moderate : I64, hard : I64 }, _)
    zone_sum! = |path, cutoff|
        Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(SUM(m.z1_s),0) AS z1, COALESCE(SUM(m.z2_s),0) AS z2, COALESCE(SUM(m.z3_s),0) AS z3,
                \\       COALESCE(SUM(m.z4_s),0) AS z4, COALESCE(SUM(m.z5_s),0) AS z5, CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss,
                \\       -- load that came from a measured power meter (high-confidence rungs),
                \\       -- vs estimated from HR/RPE/relative-effort — see the doctor confidence tiers
                \\       CAST(COALESCE(SUM(CASE WHEN m.load_model IN ('power_stream','weighted_watts','avg_watts') THEN m.tss ELSE 0 END),0) AS REAL) AS measured,
                \\       -- polarization intensity per activity: POWER split when the activity has
                \\       -- power-intensity time, else the HR zones. So a power ride's threshold
                \\       -- work counts as hard even when HR sat on a zone boundary.
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_easy_s ELSE m.z1_s + m.z2_s END),0) AS easy,
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_moderate_s ELSE m.z3_s END),0) AS moderate,
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_hard_s ELSE m.z4_s + m.z5_s END),0) AS hard
                \\FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
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
                Ok({ z1, z2, z3, z4, z5, tss, measured, easy, moderate, hard })
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
                    block = |w, ctl| {
                        tss: w.tss,
                        sessions: w.sessions,
                        hard_min: (w.z4 + w.z5) // 60,
                        easy_pct: pct_num(w.z1 + w.z2, w.z1 + w.z2 + w.z3 + w.z4 + w.z5),
                        ctl,
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
                \\       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr
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
                Ok({ id, date, sport, name, moving_time, distance_m, tss, np_w, intensity, ftp_used, z1_s, z2_s, z3_s, z4_s, z5_s, avg_hr })
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
                decoded = Streams.decode_streams(raw_opt)
                streams = decoded.streams

                hr_pairs = List.keep_if(
                    Streams.stream_pairs(streams.time, streams.heartrate),
                    |p| Metrics.valid_hr(p.v),
                )
                watts_pairs = List.keep_if(Streams.stream_pairs(streams.time, streams.watts), |p| Metrics.valid_watts(p.v))
                watts_1s = Metrics.resample_1s(watts_pairs)
                best = |w|
                    match Metrics.best_rolling_mean(watts_1s, w) {
                        Ok(v) => v
                        Err(_) => 0.0
                    }
                max_hr = List.fold(hr_pairs, 0.0.F64, |acc, p| (acc).max(p.v))
                hard_s = a.z4_s + a.z5_s
                # intensity from POWER (truer than HR for power sports — HR threshold can
                # sit on a zone boundary). Cycling uses the FTP the ride was scored with;
                # non-cycling power sports need their own threshold (not yet configured),
                # so they get 0 here and fall back to the HR "hard" signal.
                pi_ftp = Db.sport_ftp!(path, a.sport)?
                pintensity = Metrics.time_in_power_intensity(watts_pairs, pi_ftp)
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
                        power_bests: { w60: best(60), w180: best(180), w300: best(300), w1200: best(1200) },
                        max_hr,
                        avg_hr: a.avg_hr,
                        # true = stored streams exist but wouldn't decode, so the 0s
                        # above are "unreadable", NOT "no power meter / no strap"
                        streams_unreadable: decoded.failed,
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
                    if best(60) > 0
                        Stdout.line!("power  1min ${Render.fmt0(best(60))}W · 3min ${Render.fmt0(best(180))}W · 5min ${Render.fmt0(best(300))}W · 20min ${Render.fmt0(best(1200))}W")?
                    else
                        Ok({})?
                    (if max_hr > 0
                        Stdout.line!("hr     max ${Render.fmt0(max_hr)} · avg ${Render.fmt0(a.avg_hr)}")
                    else
                        Ok({}))?
                    if decoded.failed
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
                \\GROUP BY sport_type ORDER BY sessions DESC
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
            Ok({ ftp, zb }) => {
                payload = summary_payload!(path, ftp, zb)?
                Output.out!(payload, Render.summary_screen)
            }
        }
    }
    # weekly-planning bundle: everything the coach needs to plan a week, in one call
    week! : {} => Try({}, _)
    week! = |{}| {
        path = Db.open_db!({})?
        match Analyze.load_zone_config!(path) {
            Err(MissingConfig) => Output.missing_config!({})
            Err(other) => Err(other)
            Ok({ ftp, zb }) => {
                s = summary_payload!(path, ftp, zb)?
                anchor = (Metrics.date_str_to_days(s.as_of)).ok_or(0)
                cutoff14 = Metrics.days_to_date_str(anchor - 14)
                recent = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT a.id AS id, substr(a.start_local, 1, 10) AS date, a.sport_type AS sport, a.name AS name,
                        \\       a.moving_time AS moving_time, CAST(COALESCE(m.tss,0) AS REAL) AS tss,
                        \\       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                        \\       COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
                        \\       COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s,
                        \\       COALESCE(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_hard_s ELSE m.z4_s + m.z5_s END, 0) AS hard_s
                        \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                        \\WHERE a.start_local >= :cutoff
                        \\ORDER BY a.start_local DESC
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
                        Ok({ id, date, sport, name, moving_time, tss, intensity, z1_s, z2_s, z3_s, z4_s, z5_s, hard_s })
                    },
                })?
                open_p = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT id AS id, COALESCE(target_date,'') AS target_date, COALESCE(session_type,'') AS session_type,
                        \\       COALESCE(detail,'') AS detail, COALESCE(rationale,'') AS rationale
                        \\FROM planned_sessions WHERE COALESCE(status, 'open') = 'open'
                        \\ORDER BY target_date
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
                    Stdout.line!(Render.render_table(
                        ["date", "sport", "name", "time", "load", "hard"],
                        List.map(recent, |a| [a.date, a.sport, a.name, Render.mins(a.moving_time), Render.fmt0(a.tss), Render.mins(a.hard_s)]),
                    ))
                }
            }
        }
    }
    summary_payload! = |path, ftp, zb| {
        latest = Sqlite.query!({
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
        })?
        anchor = (Metrics.date_str_to_days(latest.day)).ok_or(0)
        cutoff28 = Metrics.days_to_date_str(anchor - 28)
        cutoff60 = Metrics.days_to_date_str(anchor - 60)

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
                \\SELECT a.sport_type AS sport, COUNT(*) AS sessions, CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss
                \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE a.start_local >= :cutoff
                \\GROUP BY a.sport_type ORDER BY tss DESC
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff28) }],
            rows: |cols| |stmt| {
                sport = Sqlite.str("sport")(cols)(stmt)?
                sessions = Sqlite.i64("sessions")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                Ok({ sport, sessions, tss })
            },
        })?

        cutoff7 = Metrics.days_to_date_str(anchor - 7)
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
        cal = Metrics.ftp_calibration({ best_20min: best20_row, ftp })

        Ok({
            as_of: latest.day,
            fitness_ctl: latest.ctl,
            fatigue_atl: latest.atl,
            form_tsb: latest.tsb,
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
            },
            ftp: {
                config_w: ftp,
                best_20min_w_60d: best20_row,
                estimated_ftp_w: cal.est,
                stale: cal.stale,
                detraining: cal.detraining,
            },
            hr_zones: { z1_max: zb.z1_max, z2_max: zb.z2_max, z3_max: zb.z3_max, z4_max: zb.z4_max },
            sports_28d: sports,
        })
    }
    activities! : U64, Str => Try({}, _)
    activities! = |limit, sport_filter| {
        path = Db.open_db!({})?
        where_clause =
            if Str.is_empty(sport_filter)
                ""
            else
                "WHERE a.sport_type = :sport COLLATE NOCASE"
        filter_bindings =
            if Str.is_empty(sport_filter)
                []
            else
                [{ name: ":sport", value: String(sport_filter) }]
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
                \\${where_clause}
                \\ORDER BY a.start_local DESC LIMIT ${(limit).to_str()}
            ,
            bindings: filter_bindings,
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
        else {
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
    top! : Str, U64, Str => Try({}, _)
    top! = |metric, limit, sport_filter| {
        path = Db.open_db!({})?
        match top_metric(metric) {
            Err(_) =>
                Output.err_out!("bad_metric", "unknown metric '${metric}' — use: hr, tss, power, intensity, distance, time, output")

            Ok({ col, header }) => {
                sport_where =
                    if Str.is_empty(sport_filter) "" else " AND a.sport_type = :sport COLLATE NOCASE"
                sport_binding =
                    if Str.is_empty(sport_filter) [] else [{ name: ":sport", value: String(sport_filter) }]
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
                        \\ORDER BY ${col} DESC LIMIT ${(limit).to_str()}
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
                else {
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
            query: "SELECT COALESCE(load_model, 'unknown (pre-provenance)') AS model, COUNT(*) AS n FROM activity_metrics GROUP BY load_model ORDER BY n DESC",
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
                \\SELECT COALESCE(SUM(CASE WHEN load_model IN ('power_stream','weighted_watts','avg_watts') THEN 1 ELSE 0 END),0) AS hi,
                \\       COALESCE(SUM(CASE WHEN load_model IN ('hr_zones','hr_avg','session_rpe') THEN 1 ELSE 0 END),0) AS med,
                \\       COALESCE(SUM(CASE WHEN load_model='relative_effort' THEN 1 ELSE 0 END),0) AS lo,
                \\       COALESCE(SUM(CASE WHEN load_model IS NULL OR load_model NOT IN ('power_stream','weighted_watts','avg_watts','hr_zones','hr_avg','session_rpe','relative_effort') THEN 1 ELSE 0 END),0) AS non
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
                \\SELECT COALESCE(SUM(CASE WHEN substr(key,1,4)='ftp_' THEN 1 ELSE 0 END),0) AS ftp_count,
                \\       COALESCE(SUM(CASE WHEN key IN ('hr_z1_max','hr_z2_max','hr_z3_max','hr_z4_max') THEN 1 ELSE 0 END),0) AS zones_set
                \\FROM config
            ,
            bindings: [],
            row: |cols| |stmt| {
                ftp_count = Sqlite.i64("ftp_count")(cols)(stmt)?
                zones_set = Sqlite.i64("zones_set")(cols)(stmt)?
                Ok({ ftp_count, zones_set })
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
        mode = Db.resolve_time_mode!(path)
        time_desc =
            match mode {
                Zone(name, off) => "timezone ${name} (${Db.fmt_offset(off)} now, DST-aware)"
                FixedOffset(off) => "fixed offset ${Db.fmt_offset(off)} (adjust seasonally for DST)"
                BadZone(name, off) => "timezone '${name}' UNKNOWN to system tz db — using ${Db.fmt_offset(off)}; fix the name or set utc_offset_minutes"
                Utc => "UTC (set `timezone` or `utc_offset_minutes` if you're not on UTC)"
            }
        time_ok =
            match mode {
                BadZone(_, _) => False
                _ => True
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
            ftp_configured: cfg.ftp_count,
            zones_set: cfg.zones_set >= 4,
            time: time_desc,
            time_ok: time_ok,
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
                        "  zero load (no usable data): ${(p.zero_load).to_str()}",
                        "  not yet analyzed: ${(p.unanalyzed).to_str()}",
                        "  pending stream backfill: ${(p.pending_streams).to_str()}",
                        "  config: ${(p.ftp_configured).to_str()} sport FTP(s) set explicitly (others auto-derived from data), hr zones ${if p.zones_set "set" else "incomplete"}",
                        "  time: ${p.time}",
                    ],
                    hint,
                ]),
                "\n",
            )
        })
    }
    # power-zone reference chart: the 7 Coggan/Peloton zones as watt ranges from your
    # configured FTP (the targets you'd set on a Power Zone ride).
    pz! : {} => Try({}, _)
    pz! = |{}| {
        path = Db.open_db!({})?
        match Analyze.config_f64!(path, "ftp_ride") {
            Err(MissingConfig) => Output.err_out!("missing_config", "set your FTP first: stride config set ftp_ride <watts>")
            Err(other) => Err(other)
            Ok(ftp) => {
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
    progress! : Str => Try({}, _)
    progress! = |date_arg| {
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
                        \\ORDER BY a.start_local DESC LIMIT 1
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
                \\       CAST(COALESCE(m.tss,0) AS REAL) AS tss
                \\FROM activities a
                \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\LEFT JOIN ratings rt ON rt.activity_id = a.id
                \\WHERE a.name IN (SELECT name FROM activities WHERE substr(start_local, 1, 10) = :date)
                \\ORDER BY a.name, a.start_local
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
                Ok({ name, date: row_date, sport, distance_m, moving_time, np_w, avg_hr, rpe, output_kj, tss })
            },
        })?
        labeled =
            List.keep_oks(Metrics.group_progress(prows), |g| Metrics.anchor_filter(g, date))
           .map(|g| { name: Render.progress_group_label(g.name, g.kind), rows: g.rows })
        # choose each group's lens, keep only rows it can score; drop unscorable groups
        keep_scored = |lens, g| {
            kept = List.keep_if(g.rows, |r| Metrics.lens_score(lens, r).is_ok())
            if List.is_empty(kept) Err(Skip) else Ok({ name: g.name, lens, rows: kept })
        }
        scored = List.keep_oks(labeled, |g|
            match Metrics.progress_lens(g.rows) {
                Ef => keep_scored(Ef, g)
                SpeedHr => keep_scored(SpeedHr, g)
                Rpe => keep_scored(Rpe, g)
                Unscorable => Err(Skip)
            })
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
                groups: List.map(scored, |g| {
                    name: g.name,
                    lens: lens_name(g.lens),
                    sessions: List.map(g.rows, |r| {
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
                    }),
                }),
            })
        } else {
            Stdout.line!(Str.join_with(List.map(scored, |g| Render.progress_section(g.name, g.rows, date, g.lens)), "\n\n"))
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
}
