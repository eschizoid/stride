# ── reference and diagnostics: doctor, stats, zones, power-curve, tte ─
#
# Split from Report.roc under ADR 0001 (doctor! had passed the ~250-line
# trigger). These are the commands you run to check the ENGINE rather than the
# training: coverage, provenance, the configured zones, the power-duration
# curve and what it implies.
#
# Three helpers stay in Report.roc rather than move here, because each is shared
# with another family: the high/medium/low model lists (doctor + summary's
# coverage), Report.sport_filter_sql (power-curve + activities/top) and Report.cp_fit_as_of!
# (tte + activity). Moving a shared helper into one family is how a split turns
# into a tangle.
import Strava
import Report
import Analyze
import Db
import Output
import Metrics
import Render
import Sports
import pf.Sqlite
import pf.Stdout
import pf.Path

ReportHealth :: [].{
    stats! : {} => Try({}, _)
    stats! = |{}| {
        path = Db.open_db!({})?
        today_days = Db.local_today_days!(path)
        year = (Metrics.civil_from_days(today_days)).y
        # The cutoff below is the literal "0000-01-01", whose only job is to mean
        # EVERYTHING — and `WHERE start_local >= :cutoff` is NULL-false, so an unreadable
        # date silently removes the activity from a total printed under the heading
        # ALL TIME. Measured: 475 sessions became 474, 11950 km became 11924, exit 0, on a
        # command whose declared error_codes were empty.
        #
        # Refuses rather than reports, and that is the same call `summary` makes about the
        # same shape one file over: a number that claims completeness and is quietly short
        # is worse than no number. `stats` LISTS totals, which reads like the report side of
        # #249's split, but the split is by what the date DOES — and here it decides
        # membership in an aggregate, so a wrong date is a wrong total.
        _ = Report.guard_activity_dates!(path)?
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
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.tss, 0) = 0 AND m.activity_id IS NOT NULL THEN 1 ELSE 0 END), 0) AS zero_load,
                \\       -- rows whose start_local cannot be read (#265). doctor is the
                \\       -- command a stuck user reaches for, and it reported a clean engine
                \\       -- on databases where analyze, summary, season, plan, stats and week
                \\       -- all refused — every one of those messages naming a remedy the
                \\       -- user has to apply BY ID, which doctor had and did not say.
                \\       --
                \\       -- Same predicate as the ORDER BY hoist in ReportSessions, and it has
                \\       -- to be: this counts what those commands refuse over. It is a COUNT
                \\       -- and not a verdict — ADR 0012 puts "is this a problem?" on the
                \\       -- coach's side — and `stride activities` now leads with these rows,
                \\       -- so the pointer to the ids is a command rather than a list here.
                \\       COALESCE(SUM(1 - ${Report.date_known_sql}), 0) AS undateable
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
                undateable = Sqlite.i64("undateable")(cols)(stmt)?
                Ok({ total, with_hr, with_power, with_streams, unanalyzed, zero_load, undateable })
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
                \\-- measured power or distance-measured pace (rtss), medium = HR/RPE, low =
                \\-- relative_effort, none = unscored. The e2e cross-checks the 'high' count
                \\-- against this rung list, and all FOUR rungs are guarded: dropping any of
                \\-- them fails the suite. That took one fixture row per rung reaching doctor
                \\-- alive -- avg_watts was hidden by body ORDER, rtss by b_period_pace!
                \\-- deleting its own pace-scored swims before doctor runs. Two earlier
                \\-- versions of this comment guessed at causes instead (a missing fixture,
                \\-- then an underivable threshold, then the wrong SQL arm); a threshold speed
                \\-- derives from a single activity via period_threshold_sql's TRAILING-60-day
                \\-- arm, whose `b2.start_local <= a.start_local` includes the activity's own
                \\-- row -- not the cold-start forward-fill, which can be deleted outright with
                \\-- the suite still green. Adding a rung here
                \\-- needs a fixture row that SURVIVES to b_doctor!, or the guard silently
                \\-- stops covering it.
                \\SELECT COALESCE(SUM(CASE WHEN load_model IN (${Report.high_models_sql}) THEN 1 ELSE 0 END),0) AS hi,
                \\       COALESCE(SUM(CASE WHEN load_model IN (${Report.medium_models_sql}) THEN 1 ELSE 0 END),0) AS med,
                \\       COALESCE(SUM(CASE WHEN load_model IN (${Report.low_models_sql}) THEN 1 ELSE 0 END),0) AS lo,
                \\       COALESCE(SUM(CASE WHEN load_model IS NULL OR load_model NOT IN (${Report.high_models_sql},${Report.medium_models_sql},${Report.low_models_sql}) THEN 1 ELSE 0 END),0) AS non
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
                \\SELECT (SELECT COUNT(DISTINCT a.sport_family) FROM activity_metrics m
                \\        JOIN activities a ON a.id = m.activity_id WHERE m.ftp_used > 0 AND a.sport_family IS NOT NULL AND a.sport_family <> '') AS derived_ftp_sports,
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
        # list can't drift from Sports.class
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
        strength_unrated = List.len(List.keep_if(sports, |r| Sports.class(r.sport) == StrengthLike and r.rated == 0))
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
                BadOffset(raw) => "utc_offset_minutes '${raw}' is not a whole number — using UTC; fix it with `stride config set utc_offset_minutes <minutes east of UTC>"
                Utc => "UTC (set `timezone` or `utc_offset_minutes` if you're not on UTC)"
            }
        # Bool-TYPED, not bare True/False tags: the builtin JSON serializes a bare tag as the
        # string "True"/"False", which breaks the boolean contract (a consumer sees "True",
        # not true). Same fix as the config `redacted` field. `1 == 1` / `1 == 0` are Bool.
        time_ok =
            match mode {
                BadZone(_, _) => 1 == 0
                BadOffset(_) => 1 == 0
                _ => 1 == 1
            }
        # Not `?`. doctor's job is to diagnose a broken installation, so it is the one
        # command that must not die on the thing it is meant to report. Three conditions
        # block the count — the global zones absent, a global key unparseable, or a
        # per-sport override unparseable — and `plan` only survives the last of them,
        # because it propagates everything from load_zone_config! and degrades only inside
        # pending_metrics_count!. That is why doctor needs three arms where plan needs one.
        #
        # Annotated so the Bool guarantee is LOCAL. Worth being precise about what the
        # annotation does and does not do: removing it alone changes nothing, because
        # `if p.awaiting_metrics_known` in the human screen already forces Bool. It is that
        # `if` which is load-bearing today. Rewrite it as a `match` with the annotation
        # gone and `known` infers a bare [False, True] tag union, the encoder emits the
        # string "False", and only the schema catches it. The annotation is here so that
        # refactor cannot reach across two functions to break the payload.
        #
        # The Err arms carry the inspected error rather than discarding it: a transient
        # SQLITE_BUSY under a concurrent analyze would otherwise be reported as "could not
        # be computed", which is the worst diagnosis the diagnostic command could give.
        awaiting : { count : U64, known : Bool, problem : Str }
        awaiting =
            match Analyze.load_zone_config!(path) {
                Err(MissingConfig) => { count: 0, known: False, problem: "hr zone bounds are not set — run `stride config set hr_z1_max <bpm>` through hr_z4_max" }
                Err(UnreadableConfig(key, raw)) => { count: 0, known: False, problem: Output.unreadable_config_msg(key, raw) }
                Err(SqliteErr(code, msg)) => { count: 0, known: False, problem: "the database refused the zone-config read (${Str.inspect(code)}): ${msg}" }
                Err(_) => { count: 0, known: False, problem: "the zone config could not be read" }
                Ok(zb) =>
                    match Analyze.pending_metrics_count!(path, zb) {
                        Ok(n) => { count: n, known: True, problem: "" }
                        Err(UnreadableConfig(key, raw)) => { count: 0, known: False, problem: Output.unreadable_config_msg(key, raw) }
                        Err(SqliteErr(code, msg)) => { count: 0, known: False, problem: "the database refused the pending-metrics count (${Str.inspect(code)}): ${msg}" }
                        Err(_) => { count: 0, known: False, problem: "the pending-metrics count could not be computed" }
                    }
            }
        payload = {
            activities: cov.total,
            with_hr: cov.with_hr,
            with_power: cov.with_power,
            with_streams: cov.with_streams,
            unanalyzed: cov.unanalyzed,
            zero_load: cov.zero_load,
            undateable_activities: cov.undateable,
            rated: rated_total,
            strength_unrated: strength_unrated.to_i64_wrap(),
            scored_by: models,
            conf_high: conf.hi,
            conf_medium: conf.med,
            conf_low: conf.lo,
            conf_none: conf.non,
            pending_streams: pending,
            # What `analyze` would recompute right now, beside what it has never scored
            # at all (#238). `unanalyzed` above is `m.activity_id IS NULL` and nothing
            # else, which is the right answer for a COVERAGE field — its neighbours all
            # report presence — but it meant doctor read 0 on a database where every row
            # was due. Measured on a real database with metrics_rev bumped, the shape a
            # metrics-definition release produces: unanalyzed 0, this field 735.
            #
            # Shares Analyze.pending_metrics_count! with `plan`'s
            # activities_awaiting_metrics, so the two commands cannot disagree about the
            # same question, and it is the same predicate `analyze` selects rows with.
            awaiting_metrics: awaiting.count,
            awaiting_metrics_known: awaiting.known,
            # Measured at ~89ms on a 735-activity, 35MB-of-streams database, roughly
            # doubling doctor. It is `LENGTH(s.raw_json)` in the shared predicate forcing
            # a decode of every stored blob, so it scales with stream BYTES rather than
            # activity count. Paid deliberately: the only way to make it cheaper is a
            # narrower predicate than `analyze` uses, which would forfeit the property
            # that this and `plan` cannot disagree — and doctor is run by hand.
            #
            # WHY the count is unknown, which is the whole point of surfacing it in the
            # DIAGNOSTIC command: `plan` degrades silently and correctly, but a bare
            # `known: false` with no reason would just move the question here. "" when
            # the count was computed.
            config_error: awaiting.problem,
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
            # A LIST that is empty or one element, exactly like `hint` above, rather than a
            # string that is empty or a sentence. The conditional undateable line disappears
            # when it has nothing to say, and `""` keeps meaning what it means everywhere
            # else in this screen: a deliberate section spacer.
            #
            # The first version returned `else ""` and filtered the whole joined list for
            # empties — which removed all SIX spacers, five here and one in `hint`, turning
            # the screen into an undifferentiated wall and detaching the footer arrow. The
            # two e2e checks that read this screen are `Str.contains` on single lines, so
            # 785 checks stayed green through a regression that changed every section
            # boundary on it.
            undateable =
                if p.undateable_activities > 0
                    ["  activities with an unreadable date: ${(p.undateable_activities).to_str()} — `stride activities` lists them first; delete each by id and re-sync"]
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
                        "    high (power/pace): ${(p.conf_high).to_str()}",
                        "    medium (HR / RPE): ${(p.conf_medium).to_str()}",
                        "    low (relative effort): ${(p.conf_low).to_str()}",
                        "    none (unscored): ${(p.conf_none).to_str()}",
                        "",
                        "  hr-less endurance sessions in a row: ${(p.hr_missing_streak).to_str()}",
                        "  rides on estimated power (30d): ${(p.estimated_power_count_30d).to_str()}",
                        "  junk samples dropped (30d): ${Render.fmt1(p.junk_filtered_pct_30d)}% overall · worst session ${Render.fmt1(p.junk_worst_session_pct_30d)}%",
                        "  zero load (no usable data): ${(p.zero_load).to_str()}",
                        "  not yet analyzed: ${(p.unanalyzed).to_str()}",
                        # Beside "not yet analyzed", not replacing it: one is what has
                        # never been scored, the other is what `analyze` would rescore.
                        # They are equal in the ordinary case and diverge exactly when it
                        # matters — a changed FTP or a bumped metrics_rev leaves the first
                        # at 0 while the second is the whole history.
                        if p.awaiting_metrics_known {
                            "  would be recomputed by analyze: ${(p.awaiting_metrics).to_str()}"
                        } else {
                            "  would be recomputed by analyze: unknown — ${p.config_error}"
                        },
                        "  streams still pending: ${(p.pending_streams).to_str()} — run `stride sync` to keep draining them",
                    ],
                    # ONLY when there are any (#265). Every other line here reports a number
                    # that is meaningful at zero — "0 not yet analyzed" is a clean bill —
                    # but this one is a fault count, and printing "0 undateable" on every
                    # healthy run trains the eye to skip the row on the day it is not zero.
                    # That is the same argument `plan`'s freshness note makes for staying
                    # silent. Names the command rather than the ids, because `activities`
                    # now leads with these rows.
                    undateable,
                    [
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
    # cover different routes, so those only compare sessions within ±10% of the anchor's distance.
    # JSON tag for a chosen lens
    tte! : Str => Try({}, _)
    tte! = |watts_arg|
        match Metrics.arg_f64(Str.trim(watts_arg)) {
            Err(_) => Output.err_out!("bad_watts", "tte needs a power in watts — got '${watts_arg}'")
            Ok(w) =>
                # `w <= 0.0` is FALSE for NaN, so a NaN sailed straight through
                # to the payload and broke the envelope (#183 class). Negate a
                # POSITIVE test instead: !(w > 0.0) catches NaN, zero, and
                # negatives together. The ceiling catches +inf and typos.
                if !(w > 0.0) or w > 3000.0 {
                    Output.err_out!("bad_watts", "power must be a positive number of watts under 3000 — got '${watts_arg}'")
                } else {
                    path = Db.open_db!({})?
                    today = Metrics.days_to_date_str(Db.local_today_days!(path))
                    # tte fits the RIDE family: the CP model needs a power meter
                    # and this athlete's other families have none. Named in the
                    # payload so a caller never has to guess whose model it is.
                    fit = Report.cp_fit_as_of!(path, Sports.canonical("Ride"), today, 90)?
                    if fit.cp <= 0.0 {
                        # Two different causes, one branch: too few bests, or
                        # bests that are inconsistent (a longer one above a
                        # shorter one). Saying only "not enough" sends a coach
                        # to prescribe a test the athlete has already done.
                        Output.err_out!("no_cp_fit", "could not fit a CP model from the 5/10/20-minute bests on record in the last 90 days — there may be too few, or they may be inconsistent (a longer best above a shorter one); `stride power-curve` shows what is on record")
                    } else {
                        res = Metrics.time_to_exhaustion({ cp: fit.cp, w_prime: fit.w_prime }, w)
                        seconds = match res { Seconds(t) => t  OutsideModel(t) => t  BelowCp => 0.0 }
                        status = match res { Seconds(_) => "in_model"  OutsideModel(_) => "outside_model"  BelowCp => "below_cp" }
                        known : Bool
                        known = match res { BelowCp => False  _ => True }
                        # The longest effort at or above this power that the
                        # athlete has ON RECORD in the same window the fit was
                        # built from. These are the fit's own inputs, so a
                        # prediction shorter than one of them is refuted by the
                        # data it came from — the single cheapest fit-quality
                        # signal available, and it is a measurement, not a
                        # verdict (ADR 0010).
                        held = List.keep_if(fit.pts, |p| p.watts >= w)
                        best = List.fold(held, { dur_s: 0.0, watts: 0.0 }, |acc, p| if p.dur_s > acc.dur_s p else acc)
                        dem_known : Bool
                        dem_known = best.dur_s > 0.0
                        contradicts : Bool
                        contradicts = dem_known and known and best.dur_s > seconds
                        Output.out!(
                            {
                                watts: w,
                                seconds,
                                known,
                                status,
                                cp: fit.cp,
                                w_prime: fit.w_prime,
                                fit_points: fit.points,
                                fit_r2: fit.r2,
                                window_days: 90,
                                sport_family: fit.family,
                                demonstrated_s: best.dur_s,
                                demonstrated_w: best.watts,
                                demonstrated_known: dem_known,
                                contradicts_model: contradicts,
                            },
                            Render.tte_screen,
                        )
                    }
                }
        }
    power_curve! : U64, Str => Try({}, _)
    power_curve! = |days, sport| {
        path = Db.open_db!({})?
        sf = Report.sport_filter_sql(sport)
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
                # fit_points counts the bests AVAILABLE to the fit, the same
                # meaning tte and activity publish. Zeroing it on a refused fit
                # made the same key mean two different things across commands;
                # `cp` of 0 is the refusal signal.
                Ok(c) => (if c.cp > 0.0 and c.w_prime > 0.0 { cp: c.cp, w_prime: c.w_prime, r2: c.r2, points: (List.len(fit_points)).to_i64_wrap() } else { cp: 0.0, w_prime: 0.0, r2: 0.0, points: (List.len(fit_points)).to_i64_wrap() })
                Err(_) => { cp: 0.0, w_prime: 0.0, r2: 0.0, points: (List.len(fit_points)).to_i64_wrap() }
            }
        Output.out!(
            { window_days: days, sport, points, cp: cpfit.cp, w_prime: cpfit.w_prime, fit_r2: cpfit.r2, fit_points: cpfit.points },
            Render.power_curve_screen,
        )
    }
}
