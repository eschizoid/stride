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
import Plan
import Import

version = "stride 0.3.0" # x-release-please-version

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
        \\    config      get/set config (hr zone bounds, timezone) — FTP is derived, not set
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
        \\    power-curve [days] [sport]   power-duration curve + Critical Power (alias: pc)
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
    # basic-cli 0.21 hands args over as an OS-native tag union — that union IS `OsStr`
    # (Utf8 | UnixBytes raw argv | WindowsU16s UTF-16 code units). OsStr.display decodes ALL
    # three, including Windows UTF-16, best-effort (invalid text -> U+FFFD). This is why macOS +
    # Linux + Windows all Just Work here: the platform owns the decoding, not us.
    args = List.map(raw_args, |a| OsStr.display(a))
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
        Command.Import(src) => Import.import_archive!(src)
        Command.Rate(target, rpe_str) => Plan.rate!(target, rpe_str)
        Command.Progress(name) => Report.progress!(name)
        Command.Activity(id_str) => Report.activity!(id_str)
        Command.Load(days) => Report.load_series!(days)
        Command.PowerCurve(days, sport) => Report.power_curve!(days, sport)
        Command.PlanView => Plan.plan_view!(ThisWeek)
        Command.PlanViewAll => Plan.plan_view!(AllTime)
        Command.PlanAdd(date, session_type, detail, rationale) => Plan.plan_add!(date, session_type, detail, rationale)
        Command.Complete(session_id, activity_id) => Plan.complete!(session_id, activity_id)
        Command.CompleteRest(session_id) => Plan.complete_rest!(session_id)
        Command.Skip(session_id, reason) => Plan.skip!(session_id, reason)
        Command.ConfigGet(key) => config_show!(key)
        Command.ConfigSet(key, val) => config_store!(key, val)

    }

config_show! : Str => Try({}, _)
config_show! = |key| {
    path = Db.open_db!({})?
    if Config.is_secret(key)
        # confirm set-ness without leaking the value
        match Db.config_opt!(path, key)? {
            # redacted must be Bool-TYPED, not a bare `True` tag: the new builtin JSON
            # serializes a bare tag as the string "True". Config.is_secret(key) is Bool
            # and is True here (we're inside the is_secret branch).
            Found(_) => Output.out!({ key, value: "<redacted>", redacted: Config.is_secret(key) }, |_| "${key} = <redacted> (secret — stored in the db, not shown)")
            NotFound => Output.err_out!("not_set", "(not set)")
        }
    else
        match Db.config_opt!(path, key)? {
            Found(v) => Output.out!({ key, value: v }, |p| p.value)
            NotFound => Output.err_out!("not_set", "(not set)")

        }
}
config_store! : Str, Str => Try({}, _)
config_store! = |key, val|
    # refuse the keys the engine derives — storing one would confirm a change that never
    # happens, since sport_ftp! reads power history and not config (ADR 0005)
    if Config.is_derived(key)
        Output.err_out!(
            "derived_key",
            "${key} is derived from your power history, not configured — stride uses that sport's best 20-min power x 0.95 over the 60 days around each activity. Nothing to set; `stride summary` shows the current value.",
        )
    else {
        path = Db.open_db!({})?
        Db.config_set!(path, key, val)?
        Stdout.line!("${key} = ${val}")
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