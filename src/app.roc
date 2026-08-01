app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
    http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

# stride — a local-first multi-sport training engine.
#
# This module owns every effect: CLI dispatch, Strava OAuth + sync, metric
# computation orchestration, SQLite access, and output rendering. In Roc only
# the app module can use platform capabilities, so effects concentrate here by
# design; the logic worth testing lives in pure modules — Metrics (training
# math), Render (tables/formatting), Schema (DDL).
#
# Two consumers, one contract: humans get tables (with legends and a verdict),
# LLM coaches get JSON (STRIDE_FORMAT=json or an agent env var). The engine
# computes deterministically; the coach reasons and writes the plan back
# through the coaching-log commands. Neither does the other's job.

import pf.Stdout
import pf.Stdin
import pf.Env
import pf.OsStr
import pf.Http
import http.Request
import http.Response
import http.Method
import pf.Utc
import pf.Sleep
import pf.Sqlite
import pf.Cmd
import pf.Path
import Csv
import Streams
import Metrics
import Command
import Config
import Schema
import Render
import Backfill
import Db
import Output
import Strava
import Analyze
import Report

version = "stride 0.1.0" # x-release-please-version

help_text =
        \\stride — a local-first, deterministic training analytics engine (built in Roc)
        \\Designed to be driven by an LLM coach (e.g. Claude Code) or by hand.
        \\
        \\USAGE
        \\    stride <command>
        \\
        \\Query commands print human tables in a terminal, JSON when STRIDE_FORMAT=json
        \\or CLAUDECODE is set (for LLM/tool callers).
        \\
        \\SETUP (once)
        \\    init        create ~/.stride and migrate the SQLite db
        \\    auth        authorize with Strava (one-time paste flow; stores creds)
        \\    config      get/set config (e.g. ftp_ride, ftp_rowing, hr zone bounds)
        \\
        \\GET DATA
        \\    sync        pull new activities + streams (rolling 30d self-heal)
        \\    backfill    re-pull the full activity list + ALL missing streams
        \\    import <zip|dir>  load a Strava account export — no API creds needed
        \\    analyze     compute training metrics (TSS, zones, CTL/ATL/TSB)
        \\
        \\WHERE DO I STAND?
        \\    summary     form, 7d/28d zones + polarization, FTP calibration, per-sport
        \\    stats       career + year-to-date totals per sport
        \\    doctor      dataset health: coverage + how each activity was scored
        \\
        \\AM I IMPROVING?
        \\    progress [date]         trend on a repeated workout, sport-aware lens
        \\                            (power→EF, distance→speed/HR, rated→RPE); latest by default
        \\    compare [week|month]    this period vs the one before it (default week)
        \\    top <metric> [n] [sport]   best sessions by hr|tss|power|intensity|distance|time|output
        \\
        \\WHAT HAPPENED?
        \\    activities [limit] [sport]   recent sessions with metrics (default 30)
        \\    activity <id>                one session in depth: zones, power bests, hard min
        \\    load [days]                  fitness/fatigue/form series (default 90)
        \\
        \\WHAT SHOULD I DO?
        \\    week                    planning bundle: summary + open plan + last 14 days
        \\    plan                    this week's plan (Mon-Sun); `plan all` for the full log
        \\    plan add <date> <type> <detail> <rationale>    add a planned session
        \\    complete <session_id> [activity_id]            mark done (bare = rest day)
        \\    skip <session_id> <reason>                     mark skipped, with reason
        \\    rate <activity_id|latest> <1-10>               session-RPE — scores strength honestly
        \\
        \\REFERENCE
        \\    zones       power-zone watt ranges (7) from your FTP (alias: pz)
        \\
        \\FLAGS
        \\    --help      show this help
        \\    --version   show version
        \\
        \\SETUP (first time only)
        \\    Create a Strava API app (strava.com/settings/api), then:
        \\    STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth
        \\    After that, creds live in the db — no env vars needed again.

# main! stays thin: parse argv into a typed Command (pure, in Command.roc), then
# dispatch. All arity/count validation lives in the parser and is unit-tested there.
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |raw_args| {
    args = List.map(raw_args, |a| match a { Utf8(s) => s, _ => "" })
    match Command.parse(args) {
        Err(ShowHelp) => Stdout.line!(help_text)
        Err(Usage(u)) => Output.usage!(u)
        Err(BadCount(s)) => Output.err_out!("bad_count", "expected a number, got '${s}'")
        Ok(cmd) => dispatch!(cmd)

    }
}
dispatch! : Command.Command => Try({}, _)
dispatch! = |cmd|
    match cmd {
        Command.Init => init!({})
        Command.Auth => Strava.auth!({})
        Command.Sync => Strava.sync!({})
        Command.Backfill => Strava.backfill!({})
        Command.Analyze => Analyze.analyze!({})
        Command.Summary => Report.summary!({})
        Command.Stats => Report.stats!({})
        Command.Week => Report.week!({})
        Command.Doctor => Report.doctor!({})
        Command.Zones => Report.pz!({})
        Command.Version => Stdout.line!(version)
        Command.Compare(period) => Report.compare!(period)
        Command.Activities(c, sport) => Report.activities!(c, sport)
        Command.Top(metric, c, sport) => Report.top!(metric, c, sport)
        Command.Import(src) => import_archive!(src)
        Command.Rate(target, rpe_str) => rate!(target, rpe_str)
        Command.Progress(name) => Report.progress!(name)
        Command.Activity(id_str) => Report.activity!(id_str)
        Command.Load(days) => Report.load_series!(days)
        Command.PlanView => plan_view!(ThisWeek)
        Command.PlanViewAll => plan_view!(AllTime)
        Command.PlanAdd(date, session_type, detail, rationale) => plan_add!(date, session_type, detail, rationale)
        Command.Complete(session_id, activity_id) => complete!(session_id, activity_id)
        Command.CompleteRest(session_id) => complete_rest!(session_id)
        Command.Skip(session_id, reason) => skip!(session_id, reason)
        Command.ConfigGet(key) => config_show!(key)
        Command.ConfigSet(key, val) => config_store!(key, val)

    }

config_show! : Str => Try({}, _)
config_show! = |key| {
    path = Db.open_db!({})?
    if Config.is_secret(key)
        # confirm set-ness without leaking the value
        match Db.config_opt!(path, key)? {
            Found(_) => Output.out!({ key, value: "<redacted>", redacted: True }, |_| "${key} = <redacted> (secret — stored in the db, not shown)")
            NotFound => Output.err_out!("not_set", "(not set)")
        }
    else
        match Db.config_opt!(path, key)? {
            Found(v) => Output.out!({ key, value: v }, |p| p.value)
            NotFound => Output.err_out!("not_set", "(not set)")

        }
}
config_store! : Str, Str => Try({}, _)
config_store! = |key, val| {
    path = Db.open_db!({})?
    Db.config_set!(path, key, val)?
    Stdout.line!("${key} = ${val}")?
    # FTP is the one config that also lives on Strava — keep them in sync so
    # Strava's own power features use the same number
    if key == "ftp_ride" Strava.sync_ftp_to_strava!(path, val) else Ok({})
}
init! : {} => Try({}, _)
init! = |{}| {
    home = Env.var_str!(OsStr.from_str("HOME"))?
    dir = "${home}/.stride"
    # ignore AlreadyExists — idempotent init
    _ = Path.create_dir!(Path.utf8(dir))
    path = "${dir}/db.sqlite"
    Db.ensure_schema!(path)?
    Db.secure_perms!(dir)?
    Stdout.line!("initialized ${path}")
}
# ── import from a Strava account export (no API credentials needed) ──
# Phase 1 of the export path (#6): summary-level rows from activities.csv, fed
# through the SAME upsert as sync — idempotent, metrics-invalidation intact.
# Streams aren't in the CSV, so zone/NP metrics stay honestly absent; the TSS
# ladder falls back to watts/HR/relative-effort exactly as with sparse API data.
import_archive! : Str => Try({}, _)
import_archive! = |src| {
    db = Db.open_db!({})?
    dir_result =
        if Str.ends_with(src, ".zip") {
            tmp = Cmd.new(OsStr.from_str("mktemp")).arg(OsStr.from_str("-d")).exec_output!().map_err(|_| ImportTempDirFailed)?
            tmp_dir = Str.trim(tmp.stdout_utf8)
            match Cmd.new(OsStr.from_str("unzip")).args(List.map(["-o", "-q", src, "-d", tmp_dir], OsStr.from_str)).exec_output!() {
                Ok(_) => Ok(tmp_dir)
                Err(_) => Err(UnzipFailed)
            }
        }
        else
            Ok(src)
    match dir_result {
        Err(UnzipFailed) => Output.err_out!("unzip_failed", "couldn't unzip ${src} — is `unzip` installed? (or extract it yourself and `stride import <dir>`)")
        Err(other) => Err(other)
        Ok(dir) => {
            csv_path = "${dir}/activities.csv"
            match Path.read_utf8!(Path.utf8(csv_path)) {
                Err(_) => Output.err_out!("no_activities_csv", "no activities.csv in ${dir} — point me at a Strava account export (Settings → My Account → Download or Delete Your Account)")
                Ok(text) =>
                    match Csv.parse(text) {
                        [headers, .. as rows] => {
                            counts = import_rows!(db, headers, rows, { imported: 0.U64, skipped: 0.U64 })?
                            if Output.json_mode!({})
                                Output.emit_ok!(counts)
                            else
                                Stdout.line!("imported ${(counts.imported).to_str()} activities (${(counts.skipped).to_str()} rows skipped) — run `stride analyze` to compute metrics")
                        }
                        _ => Output.err_out!("empty_csv", "activities.csv is empty")

                    }
            }
        }
    }
}
import_rows! : Str, List(Str), List(List(Str)), { imported : U64, skipped : U64 } => Try({ imported : U64, skipped : U64 }, _)
import_rows! = |db, headers, rows, acc|
    match rows {
        [] => Ok(acc)
        [row, .. as rest] =>
            match Report.export_row_to_summary(headers, row) {
                Ok(summary) => {
                    Strava.upsert_activity!(db, summary)?
                    import_rows!(db, headers, rest, { ..acc, imported: acc.imported + 1 })
                }
                Err(_) =>
                    import_rows!(db, headers, rest, { ..acc, skipped: acc.skipped + 1 })

            }
    }
# session-RPE rating: the athlete is the sensor for sports without power meters.
# Ratings live in their OWN table (the judgment tier) — never on the activities
# mirror, which sync/import replace wholesale. Rating an activity invalidates its
# metrics so the next analyze rescores it through the sport-aware ladder.
rate! : Str, Str => Try({}, _)
rate! = |target, rpe_str| {
    path = Db.open_db!({})?
    rpe_result =
        match F64.from_str(rpe_str) {
            Ok(r) if r >= 1.0 and r <= 10.0 => Ok(r)
            _ => Err(BadRpe)
        }
    match rpe_result {
        Err(_) => Output.err_out!("bad_rpe", "rate needs an effort from 1 (easy) to 10 (max) — got '${rpe_str}'")
        Ok(rpe) => {
            id_result =
                if target == "latest" {
                    match Sqlite.query!({
                        path: Path.utf8(path),
                        query: "SELECT COALESCE(MAX(id), 0) AS id FROM activities WHERE start_local = (SELECT MAX(start_local) FROM activities)",
                        bindings: [],
                        row: Sqlite.i64("id"),
                    }) {
                        Ok(0) => Err(NoActivities)
                        Ok(id) => Ok(id)
                        Err(e) => Err(e)
                    }
                } else {
                    I64.from_str(target).map_err(|_| BadId)
                }
            match id_result {
                Err(BadId) => Output.err_out!("bad_id", "rate needs an activity id or 'latest': rate <activity_id|latest> <1-10>")
                Err(NoActivities) => Output.err_out!("no_activities", "nothing to rate yet — `stride sync` or `stride import` first")
                Err(other) => Err(other)
                Ok(activity_id) =>
                    if !(Report.row_exists!(path, "activities", activity_id)?) {
                        Output.err_out!("activity_not_found", "no activity ${I64.to_str(activity_id)} in the db — `stride sync` first?")
                    } else {
                        Sqlite.execute!({
                            path: Path.utf8(path),
                            query: "INSERT OR REPLACE INTO ratings (activity_id, rpe, rated_at) VALUES (:id, :rpe, :at)",
                            bindings: [
                                { name: ":id", value: Integer(activity_id) },
                                { name: ":rpe", value: Real(rpe) },
                                { name: ":at", value: String(Metrics.epoch_to_iso(Db.now_secs!({}))) },
                            ],
                        })?
                        # a rating is a metric input — invalidate so analyze rescores
                        Strava.invalidate_metrics!(path, activity_id)?
                        Output.out!({ rated: activity_id, rpe }, |p| "activity ${I64.to_str(p.rated)} rated ${Render.fmt0(p.rpe)}/10 — run `stride analyze` to rescore")
                    }
            }
        }
    }
}
plan_view! : [ThisWeek, AllTime] => Try({}, _)
plan_view! = |scope| {
    path = Db.open_db!({})?
    # default view is the CURRENT training week (Mon-Sun containing today) so `plan`
    # is "this week at a glance", not the whole history spilling into next week. The
    # Monday offset is rem(days+3,7) — the same convention as Metrics.day_of_week.
    today = Db.local_today_days!(path)
    mon = today - (today + 3) % (7)
    week_filter =
        match scope {
            AllTime => ""
            ThisWeek => "WHERE COALESCE(target_date,'') >= '${Metrics.days_to_date_str(mon)}' AND COALESCE(target_date,'') <= '${Metrics.days_to_date_str(mon + 6)}'"
        }
    rows = Sqlite.query_many!({
        path: Path.utf8(path),
        query:
            \\SELECT id AS id, COALESCE(created_at,'') AS created_at, COALESCE(target_date,'') AS target_date,
            \\       COALESCE(session_type,'') AS session_type, COALESCE(detail,'') AS detail,
            \\       COALESCE(rationale,'') AS rationale, COALESCE(completed_activity_id,0) AS completed_activity_id,
            \\       COALESCE(status,'open') AS status, COALESCE(skipped_reason,'') AS skipped_reason
            \\FROM planned_sessions ${week_filter} ORDER BY target_date DESC, id DESC LIMIT 100
        ,
        bindings: [],
        rows: |cols| |stmt| {
            id = Sqlite.i64("id")(cols)(stmt)?
            created_at = Sqlite.str("created_at")(cols)(stmt)?
            target_date = Sqlite.str("target_date")(cols)(stmt)?
            session_type = Sqlite.str("session_type")(cols)(stmt)?
            detail = Sqlite.str("detail")(cols)(stmt)?
            rationale = Sqlite.str("rationale")(cols)(stmt)?
            completed_activity_id = Sqlite.i64("completed_activity_id")(cols)(stmt)?
            status = Sqlite.str("status")(cols)(stmt)?
            skipped_reason = Sqlite.str("skipped_reason")(cols)(stmt)?
            Ok({ id, created_at, target_date, session_type, detail, rationale, completed_activity_id, status, skipped_reason })
        },
    })?
    # most recent 100 by date, displayed in calendar order
    ordered = List.fold(rows, [], |acc, x| List.concat([x], acc))
    dow = |date_str|
        match Metrics.date_str_to_days(date_str) {
            Ok(d) => Metrics.day_of_week(d)
            Err(_) => ""
        }
    # enrich ONCE with the day-of-week; both output modes consume the same rows
    # (constructed explicitly — Roc's `&` can only update fields, not add one)
    enriched = List.map(ordered, |p| {
        id: p.id,
        created_at: p.created_at,
        target_date: p.target_date,
        day: dow(p.target_date),
        session_type: p.session_type,
        detail: p.detail,
        rationale: p.rationale,
        completed_activity_id: p.completed_activity_id,
        status: p.status,
        skipped_reason: p.skipped_reason,
    })
    Output.out!(enriched, |rows_enriched|
        Render.render_table(
            ["day", "date", "type", "status", "detail", "id"],
            List.map(rows_enriched, |p| [p.day, p.target_date, p.session_type, p.status, p.detail, (p.id).to_str()]),
        ))
}
plan_add! : Str, Str, Str, Str => Try({}, _)
plan_add! = |target_date, session_type, detail, rationale| {
    path = Db.open_db!({})?
    # guard: one open planned session per date — skip or complete the old one first
    existing = Sqlite.query!({
        path: Path.utf8(path),
        query: "SELECT COALESCE(MAX(id), 0) AS id FROM planned_sessions WHERE target_date = :date AND COALESCE(status, 'open') = 'open'",
        bindings: [{ name: ":date", value: String(target_date) }],
        row: Sqlite.i64("id"),
    })?
    if existing > 0
        Output.err_out!("date_already_planned", "${target_date} already has open planned session #${(existing).to_str()} — `stride skip ${(existing).to_str()} \"reason\"` first")
    else
        insert_planned_session!(path, target_date, session_type, detail, rationale)
}
insert_planned_session! : Str, Str, Str, Str, Str => Try({}, _)
insert_planned_session! = |path, target_date, session_type, detail, rationale| {
    Sqlite.execute!({
        path: Path.utf8(path),
        query:
            \\INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status)
            \\VALUES (:at, :date, :type, :detail, :rationale, 'open')
        ,
        bindings: [
            { name: ":at", value: String(Metrics.epoch_to_iso(Db.now_secs!({}))) },
            { name: ":date", value: String(target_date) },
            { name: ":type", value: String(session_type) },
            { name: ":detail", value: String(detail) },
            { name: ":rationale", value: String(rationale) },
        ],
    })?
    new_id = Sqlite.query!({
        path: Path.utf8(path),
        query: "SELECT MAX(id) AS id FROM planned_sessions",
        bindings: [],
        row: Sqlite.i64("id"),
    })?
    Output.out!({ id: new_id, target_date, session_type }, |p| "planned #${(p.id).to_str()}: ${p.session_type} on ${p.target_date}")
}
# ONE not-found message for complete/complete-rest/skip — can't drift apart
session_not_found! : I64 => Try({}, _)
session_not_found! = |session_id|
    Output.err_out!("session_not_found", "no planned session #${(session_id).to_str()} — run `stride plan` to see ids")

complete! : Str, Str => Try({}, _)
complete! = |session_id_str, activity_id_str| {
    path = Db.open_db!({})?
    match (I64.from_str(session_id_str), I64.from_str(activity_id_str)) {
        (Ok(session_id), Ok(activity_id)) =>
            # SQLite UPDATE matching 0 rows is not an error — check existence
            # ourselves so a typo'd id can't report false success and silently
            # leave the planned session open / the coaching log out of sync
            if !(Report.row_exists!(path, "planned_sessions", session_id)?) {
                session_not_found!(session_id)
            } else if !(Report.row_exists!(path, "activities", activity_id)?) {
                Output.err_out!("activity_not_found", "no activity ${I64.to_str(activity_id)} in the db — `stride sync` first?")
            } else {
                Sqlite.execute!({
                    path: Path.utf8(path),
                    query: "UPDATE planned_sessions SET completed_activity_id = :aid, status = 'done' WHERE id = :pid",
                    bindings: [
                        { name: ":aid", value: Integer(activity_id) },
                        { name: ":pid", value: Integer(session_id) },
                    ],
                })?
                Output.out!({ completed_session: session_id, activity: activity_id }, |p| "planned session #${I64.to_str(p.completed_session)} completed by activity ${I64.to_str(p.activity)}")
            }
        _ =>
            Output.err_out!("bad_id", "complete needs numeric ids: complete <session_id> <activity_id>")

    }
}
# rest days have no activity to link — `complete <id>` alone closes them. Any
# other session type still demands its activity id: done means evidence.
complete_rest! : Str => Try({}, _)
complete_rest! = |session_id_str| {
    path = Db.open_db!({})?
    match I64.from_str(session_id_str) {
        Err(_) => Output.err_out!("bad_id", "complete needs a numeric id: complete <session_id> [activity_id]")
        Ok(session_id) =>
            if !(Report.row_exists!(path, "planned_sessions", session_id)?)
                session_not_found!(session_id)
            else {
                session_type = Sqlite.query!({
                    path: Path.utf8(path),
                    query: "SELECT COALESCE(session_type, '') AS t FROM planned_sessions WHERE id = :pid",
                    bindings: [{ name: ":pid", value: Integer(session_id) }],
                    row: Sqlite.str("t"),
                })?
                if session_type != "rest" {
                    Output.err_out!("activity_required", "planned session #${(session_id).to_str()} is '${session_type}' — completing it needs the activity id (only rest days close without one)")
                } else {
                    Sqlite.execute!({
                        path: Path.utf8(path),
                        query: "UPDATE planned_sessions SET status = 'done' WHERE id = :pid",
                        bindings: [{ name: ":pid", value: Integer(session_id) }],
                    })?
                    Output.out!({ completed_session: session_id, rest: True }, |p| "planned session #${(p.completed_session).to_str()} (rest) marked done")
                }
            }
    }
}
skip! : Str, Str => Try({}, _)
skip! = |session_id_str, reason| {
    path = Db.open_db!({})?
    match I64.from_str(session_id_str) {
        Ok(session_id) =>
            if !(Report.row_exists!(path, "planned_sessions", session_id)?) {
                session_not_found!(session_id)
            } else {
                Sqlite.execute!({
                    path: Path.utf8(path),
                    query: "UPDATE planned_sessions SET status = 'skipped', skipped_reason = :why WHERE id = :pid",
                    bindings: [
                        { name: ":why", value: String(reason) },
                        { name: ":pid", value: Integer(session_id) },
                    ],
                })?
                Output.out!({ skipped_session: session_id, reason }, |p| "planned session #${I64.to_str(p.skipped_session)} skipped: ${p.reason}")
            }
        Err(_) =>
            Output.err_out!("bad_id", "skip needs a numeric id: skip <session_id> \"<reason>\"")

    }
}