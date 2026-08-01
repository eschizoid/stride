app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
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
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, [Exit(I32), ..])
main! = |raw_args| {
    args = List.map(raw_args, |a| match a { Utf8(s) => s, _ => "" })
    match Command.parse(args) {
        Err(ShowHelp) => Stdout.line!(help_text)
        Err(Usage(u)) => usage!(u)
        Err(BadCount(s)) => err_out!("bad_count", "expected a number, got '${s}'")
        Ok(cmd) => dispatch!(cmd)

    }
}
dispatch! : Command.Command => Try({}, _)
dispatch! = |cmd|
    match cmd {
        Init => init!({})
        Auth => auth!({})
        Sync => sync!({})
        Backfill => backfill!({})
        Analyze => analyze!({})
        Summary => summary!({})
        Stats => stats!({})
        Week => week!({})
        Doctor => doctor!({})
        Zones => pz!({})
        Version => Stdout.line!(version)
        Compare(period) => compare!(period)
        Activities(c, sport) => activities!(c, sport)
        Top(metric, c, sport) => top!(metric, c, sport)
        Import(src) => import_archive!(src)
        Rate(target, rpe_str) => rate!(target, rpe_str)
        Progress(name) => progress!(name)
        Activity(id_str) => activity!(id_str)
        Load(days) => load_series!(days)
        PlanView => plan_view!(ThisWeek)
        PlanViewAll => plan_view!(AllTime)
        PlanAdd(date, session_type, detail, rationale) => plan_add!(date, session_type, detail, rationale)
        Complete(session_id, activity_id) => complete!(session_id, activity_id)
        CompleteRest(session_id) => complete_rest!(session_id)
        Skip(session_id, reason) => skip!(session_id, reason)
        ConfigGet(key) => config_show!(key)
        ConfigSet(key, val) => config_store!(key, val)

    }
usage! : Str => Try({}, _)
usage! = |u|
    Stdout.line!("usage: stride ${u}")

config_show! : Str => Try({}, _)
config_show! = |key| {
    path = open_db!({})?
    if Config.is_secret(key)
        # confirm set-ness without leaking the value
        match config_opt!(path, key)? {
            Found(_) => out!({ key, value: "<redacted>", redacted: True }, |_| "${key} = <redacted> (secret — stored in the db, not shown)")
            NotFound => err_out!("not_set", "(not set)")
        }
    else
        match config_opt!(path, key)? {
            Found(v) => out!({ key, value: v }, |p| p.value)
            NotFound => err_out!("not_set", "(not set)")

        }
}
config_store! : Str, Str => Try({}, _)
config_store! = |key, val| {
    path = open_db!({})?
    config_set!(path, key, val)?
    Stdout.line!("${key} = ${val}")?
    # FTP is the one config that also lives on Strava — keep them in sync so
    # Strava's own power features use the same number
    if key == "ftp_ride" sync_ftp_to_strava!(path, val) else Ok({})
}
# push a new FTP to Strava (PUT /athlete?ftp=). Best-effort: any failure just
# warns — the local `config set` has already succeeded and been reported.
sync_ftp_to_strava! : Str, Str => Try({}, _)
sync_ftp_to_strava! = |path, ftp_str|
    match F64.from_str(ftp_str) {
        Err(_) => Stdout.line!("  (\"${ftp_str}\" isn't a number — not synced to Strava)")
        Ok(_) =>
            match get_valid_token!(path) {
                Err(NotAuthed) => Stdout.line!("  (not synced to Strava — run `stride auth` first)")
                # HttpStatus here can only come from the token-refresh POST: a 4xx
                # means the stored token is dead, and retrying won't fix it
                Err(HttpStatus(status, _)) if status >= 400 and status < 500 =>
                    Stdout.line!("  (Strava rejected the stored token — re-run `stride auth`, then set ftp_ride again)")

                Err(_) => Stdout.line!("  (couldn't sync FTP to Strava this time)")
                Ok(token) => {
                    resp = Http.send!({
                        method: PUT,
                        headers: [{ name: "Authorization", value: "Bearer ${token}" }],
                        uri: "${api_base!({})}/api/v3/athlete?ftp=${ftp_str}",
                        body: [],
                        timeout_ms: TimeoutMilliseconds(30000),
                    })
                    match resp {
                        Ok(r) if r.status < 300 => Stdout.line!("  → synced to Strava (athlete FTP = ${ftp_str})")
                        Ok(r) => Stdout.line!("  (Strava FTP sync failed: HTTP ${(r.status).to_str()} — re-run `stride auth` to grant profile:write, or set it at strava.com/settings)")
                        Err(_) => Stdout.line!("  (couldn't reach Strava to sync FTP — set it at strava.com/settings)")

                    }
                }
            }
    }
# ── paths ────────────────────────────────────────────────────────────

db_path! : {} => Try(Str, _)
db_path! = |{}| {
    home = Env.var_str!(OsStr.from_str("HOME"))?
    Ok("${home}/.stride/db.sqlite")
}
init! : {} => Try({}, _)
init! = |{}| {
    home = Env.var_str!(OsStr.from_str("HOME"))?
    dir = "${home}/.stride"
    # ignore AlreadyExists — idempotent init
    _ = Path.create_dir!(Path.utf8(dir))
    path = "${dir}/db.sqlite"
    ensure_schema!(path)?
    secure_perms!(dir)?
    Stdout.line!("initialized ${path}")
}
# owner-only permissions on the credential store. basic-cli 0.20 has no mode API,
# so shell out; best-effort (never fails the command — a platform without chmod
# just doesn't get hardened, and we don't claim it did). Sidecars may not exist.
secure_perms! : Str => Try({}, _)
secure_perms! = |dir| {
    cmd = "chmod 700 '${dir}' 2>/dev/null; chmod 600 '${dir}/db.sqlite' '${dir}/db.sqlite-wal' '${dir}/db.sqlite-shm' '${dir}/db.sqlite-journal' 2>/dev/null; true"
    _ = Cmd.new("sh").args(["-c", cmd]).exec_output!()
    Ok({})
}
# ── config key-value helpers ─────────────────────────────────────────

config_get! : Str, Str => Try(Str, _)
config_get! = |path, key|
    Sqlite.query!({
        path: Path.utf8(path),
        query: "SELECT value FROM config WHERE key = :key",
        bindings: [{ name: ":key", value: String(key) }],
        row: Sqlite.str("value"),
    })

# read a config key, distinguishing "genuinely absent" from "the db read failed"
# — so a locked/corrupt db surfaces as a real error instead of masquerading as
# "not set" / "not authenticated" / "set your FTP".
config_opt! : Str, Str => Try([Found(Str), NotFound], _)
config_opt! = |path, key|
    match config_get!(path, key) {
        Ok(v) => Ok(Found(v))
        Err(NoRowsReturned) => Ok(NotFound)
        Err(other) => Err(other)

    }
config_set! : Str, Str, Str => Try({}, _)
config_set! = |path, key, value|
    Sqlite.execute!({
        path: Path.utf8(path),
        query: "INSERT OR REPLACE INTO config (key, value) VALUES (:key, :value)",
        bindings: [
            { name: ":key", value: String(key) },
            { name: ":value", value: String(value) },
        ],
    })

# ── strava oauth ─────────────────────────────────────────────────────

TokenResp : { access_token : Str, refresh_token : Str, expires_at : I64 }

# API base override (STRIDE_API_BASE) — lets the e2e point stride at a local
# mock Strava; humans never set it. The browser authorize URL stays real always.
api_base! : {} => Str
api_base! = |{}|
    match Env.var_str!(OsStr.from_str("STRIDE_API_BASE")) {
        Ok(b) if !(Str.is_empty(b)) => b
        _ => "https://www.strava.com"

    }
token_url! : {} => Str
token_url! = |{}| "${api_base!({})}/oauth/token"

# best-effort browser launch: macOS `open`, then Linux `xdg-open`. Silent on
# failure — the URL is always printed as the manual fallback. exec_output! (not
# exec!) so a failing launcher can't spew stderr into the auth instructions or
# hand the inherited TTY to a console browser on headless boxes.
open_browser! : Str => Try({}, _)
open_browser! = |url|
    match Cmd.new("open").arg(url).exec_output!() {
        Ok(_) => Ok({})
        Err(_) =>
            # detach xdg-open: exec waits for the child, and xdg-open can resolve to
            # a FOREGROUND handler (console browser) that would block auth forever
            match Cmd.new("sh").args(["-c", "xdg-open \"${url}\" >/dev/null 2>&1 &"]).exec_output!() {
                Ok(_) => Ok({})
                Err(_) => Ok({})

            }
    }
# a stored token field: absent => NotAuthed (genuine); db failure propagates
token_field! : Str, Str => Try(Str, _)
token_field! = |path, key|
    match config_opt!(path, key)? {
        Found(v) => Ok(v)
        NotFound => Err(NotAuthed)

    }
# client credentials: env var wins, else stored config (written by `auth`)
client_cred! : Str, Str, Str => Try(Str, _)
client_cred! = |path, env_name, key|
    match Env.var_str!(OsStr.from_str(env_name)) {
        Ok(v) => Ok(v)
        Err(_) =>
            # config_opt! so a locked/corrupt db surfaces as a real error, not MissingEnv
            match config_opt!(path, key)? {
                Found(v) => Ok(v)
                NotFound => Err(MissingEnv(env_name))

            }
    }
auth! : {} => Try({}, _)
auth! = |{}| {
    path = open_db!({})?
    # env vars for first-time setup; re-auth falls back to the creds stored last time.
    # Genuinely-missing creds get setup guidance, not a raw MissingEnv crash.
    match (client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id"), client_cred!(path, "STRAVA_CLIENT_SECRET", "strava_client_secret")) {
        (Ok(client_id), Ok(client_secret)) => auth_flow!(path, client_id, client_secret)
        (Err(MissingEnv(name)), _) | (_, Err(MissingEnv(name))) =>
            err_out!("missing_client_creds", "${name} not set and no stored credentials yet — create a (free) Strava API app at strava.com/settings/api, then run:\n  STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth")

        (Err(other), _) | (_, Err(other)) => Err(other)

    }
}
auth_flow! : Str, Str, Str => Try({}, _)
auth_flow! = |path, client_id, client_secret| {
    url = "https://www.strava.com/oauth/authorize?client_id=${client_id}&response_type=code&redirect_uri=http://localhost&approval_prompt=auto&scope=read,activity:read_all,profile:read_all,profile:write"
    Stdout.line!("1) Click Authorize in the browser tab that just opened (URL below if it didn't):")?
    Stdout.line!("")?
    Stdout.line!("   ${url}")?
    Stdout.line!("")?
    open_browser!(url)?
    Stdout.line!("2) You'll land on a localhost page that fails to load — that's expected.")?
    Stdout.line!("   Copy the code=XXXX value from the address bar and paste it here.")?
    Stdout.line!("")?
    Stdout.write!("code: ")?
    code_raw = Stdin.line!()?
    code = Str.trim(code_raw)
    form = "client_id=${client_id}&client_secret=${client_secret}&code=${code}&grant_type=authorization_code"
    body = post_form!(token_url!({}), form)?
    tokens = decode_tokens(body)?
    save_tokens!(path, tokens)?
    # persist client creds so sync never needs env vars again
    config_set!(path, "strava_client_id", client_id)?
    config_set!(path, "strava_client_secret", client_secret)?
    Stdout.line!("authorized — tokens stored. Run `stride sync` to pull your activities.")
}
decode_tokens : List(U8) -> Try(TokenResp, _)
decode_tokens = |body| {
    text = Str.from_utf8(body).map_err(|_| TokenDecodeFailed)?
    decoded : Try(TokenResp, _)
    decoded = Json.parse(text)
    decoded.map_err(|_| TokenDecodeFailed)
}
save_tokens! : Str, TokenResp => Try({}, _)
save_tokens! = |path, tokens| {
    config_set!(path, "strava_access_token", tokens.access_token)?
    config_set!(path, "strava_refresh_token", tokens.refresh_token)?
    config_set!(path, "strava_expires_at", I64.to_str(tokens.expires_at))
}

now_secs! : {} => I64
now_secs! = |{}| {
    millis = Utc.to_millis_since_epoch(Utc.now!())
    (millis // 1000).to_i64_wrap()
}
# How "today"'s civil-day boundary is anchored. The platform clock (Utc.now!) is
# UTC-only, but every activity date is Strava's local civil date — so for any user
# west of UTC, the UTC day rolls over hours before their local day, inserting a
# phantom "tomorrow" into the load series each evening.
#   Zone       — config `timezone` (IANA, e.g. America/Chicago): DST-correct for
#                the CURRENT date via the system tz database. Preferred.
#   FixedOffset — config `utc_offset_minutes`: a fixed offset; set it seasonally
#                if you observe DST (e.g. -300 CDT / -360 CST).
#   BadZone    — `timezone` is set but the name isn't in the system tz database;
#                we fall back to the fixed offset (NEVER silently to UTC) and warn.
#   Utc        — neither configured.
TimeMode : [Zone(Str, I64), FixedOffset(I64), BadZone(Str, I64), Utc]

# Read the current DST-correct offset (minutes east of UTC) for an IANA zone by
# validating it against the system tz database, then reading `date +%z`. An
# unknown name yields Err — we never let a typo silently become +0000 (UTC).
zone_offset_now! : Str => Try(I64, [BadTz])
zone_offset_now! = |tz| {
    cmd = "if [ -f '/usr/share/zoneinfo/${tz}' ]; TZ='${tz}' date +%z; else echo INVALID; fi"
    match Cmd.new("sh").args(["-c", cmd]).exec_output!() {
        Ok(out) => Metrics.parse_utc_offset(out.stdout_utf8).map_err(|_| BadTz)
        Err(_) => Err(BadTz)

    }
}
resolve_time_mode! : Str => Try(TimeMode, _)
resolve_time_mode! = |path| {
    fixed : Try(I64, [NoFixed])
    fixed =
        match config_get!(path, "utc_offset_minutes") {
            Ok(s) => Ok(I64.from_str(s).ok_or(0))
            Err(_) => Err(NoFixed)
        }
    tz =
        match config_get!(path, "timezone") {
            Ok(t) if t != "" => Ok(t)
            _ => Err(NoTz)
        }
    match tz {
        Ok(name) =>
            match zone_offset_now!(name) {
                Ok(off) => Ok(Zone(name, off))
                Err(_) => Ok(BadZone(name, fixed.ok_or(0)))
            }
        Err(_) =>
            match fixed {
                Ok(off) => Ok(FixedOffset(off))
                Err(_) => Ok(Utc)

            }
    }
}
time_mode_offset : TimeMode -> I64
time_mode_offset = |mode|
    match mode {
        Zone(_, off) => off
        FixedOffset(off) => off
        BadZone(_, off) => off
        Utc => 0

    }
# minutes east of UTC => "±HH:MM" for display
fmt_offset : I64 -> Str
fmt_offset = |m| {
    a = (m).abs()
    pad = |n| if n < 10 "0${(n).to_str()}" else (n).to_str()
    "${if m < 0 "-" else "+"}${pad(a // 60)}:${pad(a % 60)}"
}
local_today_days! : Str => Try(I64, _)
local_today_days! = |path| {
    mode = resolve_time_mode!(path)?
    Ok((now_secs!({}) + time_mode_offset(mode) * 60) // 86400)
}
# returns a valid access token, refreshing if expired; NotAuthed if never
# authorized (a genuinely absent token — NOT a db read failure, which propagates)
get_valid_token! : Str => Try(Str, _)
get_valid_token! = |path| {
    access = token_field!(path, "strava_access_token")?
    refresh = token_field!(path, "strava_refresh_token")?
    expires_str = token_field!(path, "strava_expires_at")?
    expires_at = (I64.from_str(expires_str)).map_err(|_| CorruptToken)?
    now = now_secs!({})
    if now < (expires_at - 60)
        Ok(access)
    else {
        client_id = client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id")?
        client_secret = client_cred!(path, "STRAVA_CLIENT_SECRET", "strava_client_secret")?
        form = "client_id=${client_id}&client_secret=${client_secret}&grant_type=refresh_token&refresh_token=${refresh}"
        body = post_form!(token_url!({}), form)?
        tokens = decode_tokens(body)?
        save_tokens!(path, tokens)?
        Ok(tokens.access_token)
    }
}
# ── http helpers ─────────────────────────────────────────────────────

post_form! : Str, Str => Try(List(U8), _)
post_form! = |uri, form| {
    resp = Http.send!({
        method: POST,
        headers: [{ name: "Content-Type", value: "application/x-www-form-urlencoded" }],
        uri,
        body: Str.to_utf8(form),
        timeout_ms: TimeoutMilliseconds(30000),
    })?
    ok_body(resp)
}
get_bearer! : Str, Str => Try(List(U8), _)
get_bearer! = |uri, token|
    ok_body(send_bearer!(uri, token)?)

ok_body : { status : U16, headers : List({ name : Str, value : Str }), body : List(U8) } -> Try(List(U8), _)
ok_body = |resp|
    if resp.status < 300
        Ok(resp.body)
    else {
        text = (Str.from_utf8(resp.body)).ok_or("<non-utf8 body>")
        Err(HttpStatus(resp.status, text))
    }
# ── sync ─────────────────────────────────────────────────────────────

ActivitySummary : {
    id : I64,
    name : Str,
    sport_type : Str,
    start_date_local : Str,
    moving_time : I64,
    distance : F64,
    total_elevation_gain : F64,
    # optional in Strava JSON — missing on activities without power/HR
    suffer_score : Try(F64, [Missing]),
    average_watts : Try(F64, [Missing]),
    average_heartrate : Try(F64, [Missing]),
    weighted_average_watts : Try(F64, [Missing]),
}

opt_real : Try(F64, [Missing]) -> [Real F64, Null]
opt_real = |o|
    match o {
        Ok(v) => Real(v)
        Err(_) => Null

    }
sync! : {} => Try({}, _)
sync! = |{}| {
    path = open_db!({})?
    match get_valid_token!(path) {
        Err(NotAuthed) =>
            err_out!("not_authenticated", "not authenticated — run `stride auth` first")

        Err(other) => Err(other)
        Ok(token) => {
            started = now_secs!({})
            # incremental with a rolling 30-day overlap so recent edits on
            # Strava self-heal (`backfill` is the full re-pull when needed)
            after_param =
                # NotFound (never synced) = full pull is correct; a real db read
                # error propagates instead of silently burning the rate budget
                match config_opt!(path, "last_sync_epoch")? {
                    NotFound => ""
                    Found(epoch_str) =>
                        match I64.from_str(epoch_str) {
                            Ok(e) => "&after=${I64.to_str((e - 2592000).max(0))}"
                            Err(_) => ""
                        }
                }
            count = fetch_pages!(path, token, after_param, 1, 0)?
            config_set!(path, "last_sync_epoch", I64.to_str(started))?
            streams_n = backfill_streams!(path, token)?
            remaining = pending_streams!(path)?
            out!({ synced: count, streams_fetched: streams_n, pending_streams: remaining }, |p| {
                tail =
                    if p.pending_streams > 0
                        " (${I64.to_str(p.pending_streams)} still need streams — run `stride backfill` to pull them all)"
                    else
                        ""
                "synced ${U64.to_str(p.synced)} activities, fetched streams for ${U64.to_str(p.streams_fetched)}${tail}"
            })
        }
    }
}
# fetch time/HR/watts streams for activities that don't have them yet,
# newest first, capped per run to respect Strava's rate limits (~100 reads/15min)
streams_per_run = 60

backfill_streams! : Str, Str => Try(U64, _)
backfill_streams! = |path, token| {
    ids = Sqlite.query_many!({
        path: Path.utf8(path),
        query:
            \\SELECT a.id AS id FROM activities a
            \\LEFT JOIN streams s ON s.activity_id = a.id
            \\WHERE s.activity_id IS NULL AND a.moving_time > 0
            \\ORDER BY a.start_local DESC
            \\LIMIT ${(streams_per_run).to_str()}
        ,
        bindings: [],
        rows: Sqlite.i64("id"),
    })?
    fetch_streams_all!(path, token, ids, 0)
}
# count activities still lacking streams (so sync can report incomplete backfill
# honestly instead of letting the 60/run cap look like completion)
pending_streams! : Str => Try(I64, _)
pending_streams! = |path|
    Sqlite.query!({
        path: Path.utf8(path),
        query:
            \\SELECT COUNT(*) AS n FROM activities a
            \\LEFT JOIN streams s ON s.activity_id = a.id
            \\WHERE s.activity_id IS NULL AND a.moving_time > 0
        ,
        bindings: [],
        row: Sqlite.i64("n"),
    })

fetch_streams_all! : Str, Str, List(I64), U64 => Try(U64, _)
fetch_streams_all! = |path, token, ids, acc|
    match ids {
        [] => Ok(acc)
        [id, .. as rest] => {
            id_str = (id).to_str()
            uri = "${api_base!({})}/api/v3/activities/${id_str}/streams?keys=time,heartrate,watts&key_by_type=true"
            resp = send_bearer!(uri, token)?
            if resp.status == 429 {
                # rate limited — stop gracefully, next sync continues the backfill
                Stdout.line!("rate limited by Strava — stopping streams backfill for now (will resume next sync)")?
                Ok(acc)
            } else if resp.status >= 300 and resp.status != 404 {
                Err(HttpStatus(resp.status, Str.from_utf8(resp.body).ok_or("<non-utf8 body>")))
            } else {
                # 404/2xx/non-utf8 policy lives in store_stream_response! (shared with backfill)
                match store_stream_response!(path, id, resp)? {
                    Stored => fetch_streams_all!(path, token, rest, acc + 1)
                    SkippedNonUtf8 => fetch_streams_all!(path, token, rest, acc)

                }
            }
        }
    }
store_streams! : Str, I64, Str => Try({}, _)
store_streams! = |path, id, text| {
    Sqlite.execute!({
        path: Path.utf8(path),
        query: "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (:id, :raw)",
        bindings: [
            { name: ":id", value: Integer(id) },
            { name: ":raw", value: String(text) },
        ],
    })?
    # streams just arrived — invalidate any metrics computed before them so the
    # next analyze recomputes zones/NP from the real data (they were frozen otherwise)
    invalidate_metrics!(path, id)
}

# drop an activity's computed metrics so the next analyze recomputes it. the
# invalidation story: FTP change (ftp_used check), stream arrival, Strava edit.
invalidate_metrics! : Str, I64 => Try({}, _)
invalidate_metrics! = |path, id|
    Sqlite.execute!({
        path: Path.utf8(path),
        query: "DELETE FROM activity_metrics WHERE activity_id = :id",
        bindings: [{ name: ":id", value: Integer(id) }],
    })

# ── backfill (pull ALL stream history, rate-limit-aware) ─────────────
# For a new user with thousands of activities, the 60/run sync cap means dozens
# of manual runs. `backfill` drains streams hands-off: it fills each 15-min read
# window, sleeps to the next, and stops cleanly at Strava's daily read cap
# (resume by re-running). Paces on the X-ReadRateLimit-* response headers.

# Rate pacing is COUNT-BASED, not header-based: basic-cli 0.20.0 surfaces only a
# handful of response headers (never the x-readratelimit-* ones), AND Strava's
# /streams endpoint doesn't send them anyway. So we count our own reads against
# Strava's known limits (100 reads / 15 min, 1000 / day) and pace proactively,
# with 429 as a bounded backstop.
window_sleep_ms = 905_000 # ~15 min + margin past the window reset
# the read-count limits the pure Backfill.decide reasons about (see Backfill.roc)
read_limits : Backfill.Limits
read_limits = {
    reads_per_window: 95, # sleep before the 100/15-min read window fills
    reads_per_run: 940, # stop before the 1000/day cap (room for list pages + slack)
    max_consecutive_429: 2, # this many 429s after a sleep => assume daily cap, stop
}

send_bearer! = |uri, token|
    Http.send!({
        method: GET,
        headers: [{ name: "Authorization", value: "Bearer ${token}" }],
        uri,
        body: [],
        timeout_ms: TimeoutMilliseconds(60000),
    })

# store a streams response like the sync path: 404 => honest empty marker,
# 2xx => body (skip if non-utf8 so it retries), other => propagate the error
# THE stream-response policy, shared by sync and backfill: 404 => "{}" marker
# (no streams recorded; don't refetch), 2xx => store, non-utf8 => skip WITHOUT
# storing (storing would mark it done forever; it retries next run).
store_stream_response! = |path, id, resp|
    if resp.status == 404 {
        store_streams!(path, id, "{}")?
        Ok(Stored)
    } else if resp.status < 300 {
        match Str.from_utf8(resp.body) {
            Ok(text) => {
                store_streams!(path, id, text)?
                Ok(Stored)
            }
            Err(_) => Ok(SkippedNonUtf8)
        }
    } else {
        text = Str.from_utf8(resp.body).ok_or("<non-utf8 body>")
        Err(HttpStatus(resp.status, text))
    }
backfill! : {} => Try({}, _)
backfill! = |{}| {
    path = open_db!({})?
    match get_valid_token!(path) {
        Err(NotAuthed) => err_out!("not_authenticated", "not authenticated — run `stride auth` first")
        Err(other) => Err(other)
        Ok(token) => {
            # pull the full activity list first so backfill is self-sufficient —
            # no need to run `sync` beforehand (that's what made it two commands)
            Stdout.line!("backfill: refreshing the activity list...")?
            count = fetch_pages!(path, token, "", 1, 0)?
            config_set!(path, "last_sync_epoch", I64.to_str(now_secs!({})))?
            missing_ids = Sqlite.query_many!({
                path: Path.utf8(path),
                query:
                    \\SELECT a.id AS id FROM activities a
                    \\LEFT JOIN streams s ON s.activity_id = a.id
                    \\WHERE s.activity_id IS NULL AND a.moving_time > 0
                    \\ORDER BY a.start_local DESC
                ,
                bindings: [],
                rows: Sqlite.i64("id"),
            })?
            missing = List.len(missing_ids)
            if missing == 0 {
                Stdout.line!("backfill: ${U64.to_str(count)} activities, all streams already present — nothing to do")
            } else {
                Stdout.line!("backfill: ${U64.to_str(count)} activities, ${U64.to_str(missing)} need streams. Strava allows ~1000 reads/day, so a large first pull can span a few days — this run drains as far as today's limit allows and is resumable (just run `stride backfill` again).")?
                drain_streams!(path, token, missing_ids, { done: 0, window: 0, retries: 0 })
            }
        }
    }
}
# Per-run drain state: `done` = reads this run (vs the daily cap), `window` = reads
# since the last window sleep (vs the 15-min cap), `retries` = consecutive 429s
# after a sleep (to detect the daily cap without headers).
DrainState : { done : I64, window : I64, retries : I64 }

# Walk the missing-streams list once per run. Walking a LIST (not re-querying
# "next missing") means an unstorable body is skipped, not refetched forever.
# The pacing DECISION is pure (Backfill.decide, unit-tested); this is the thin
# effectful skin that dispatches on it: fetch, then act.
drain_streams! : Str, Str, List(I64), DrainState => Try({}, _)
drain_streams! = |path, token, ids, st|
    match ids {
        [] => Stdout.line!("backfill complete — ${I64.to_str(st.done)} streams fetched this run; ${I64.to_str(pending_streams!(path)?)} still missing")
        [id, .. as rest] => {
            uri = "${api_base!({})}/api/v3/activities/${I64.to_str(id)}/streams?keys=time,heartrate,watts&key_by_type=true"
            resp = send_bearer!(uri, token)?
            match Backfill.decide({ status: resp.status, done: st.done, window: st.window, retries: st.retries }, read_limits) {
                Refresh => {
                    # multi-hour runs outlive the ~6h access token; refresh once and
                    # retry the same id. Same token back => real auth problem, stop.
                    fresh = get_valid_token!(path)?
                    if fresh == token {
                        Err(HttpStatus(401, "token refresh did not help — re-run `stride auth`"))
                    } else {
                        Stdout.line!("  access token expired — refreshed, continuing...")?
                        drain_streams!(path, fresh, ids, st)
                    }
                }
                Backoff(retries) => {
                    Stdout.line!("  rate limited — pausing ~15 min, then resuming...")?
                    Sleep.millis!(window_sleep_ms)
                    drain_streams!(path, token, ids, { ..st, window: 0, retries })
                }
                GiveUp => {
                    left = pending_streams!(path)?
                    Stdout.line!("still rate-limited after backing off — likely today's Strava read cap (${I64.to_str(st.done)} fetched this run, ${I64.to_str(left)} to go). Run `stride backfill` again later or tomorrow.")
                }
                Store({ done, window, after }) => {
                    # 404 => empty marker, 2xx => body, other => error propagated
                    _stored = store_stream_response!(path, id, resp)?
                    (if done % 50 == 0
                        Stdout.line!("  ...${I64.to_str(done)} fetched this run")
                    else
                        Ok({}))?
                    match after {
                        StopRun => {
                            left = pending_streams!(path)?
                            Stdout.line!("reached this run's safe read budget — ${I64.to_str(done)} fetched, ${I64.to_str(left)} still to go. Run `stride backfill` again tomorrow to continue.")
                        }
                        SleepWindow => {
                            Stdout.line!("  15-min read window nearly full (${I64.to_str(window)}) — sleeping ~15 min...")?
                            Sleep.millis!(window_sleep_ms)
                            drain_streams!(path, token, rest, { done, window: 0, retries: 0 })
                        }
                        Continue =>
                            drain_streams!(path, token, rest, { done, window, retries: 0 })

                    }
                }
            }
        }
    }
per_page = 100

fetch_pages! : Str, Str, Str, U64, U64 => Try(U64, _)
fetch_pages! = |path, token, after_param, page, acc| {
    page_str = (page).to_str()
    per_str = (per_page).to_str()
    uri = "${api_base!({})}/api/v3/athlete/activities?per_page=${per_str}&page=${page_str}${after_param}"
    body = get_bearer!(uri, token)?
    text = Str.from_utf8(body).map_err(|_| ActivityDecodeFailed(page))?
    decoded : Try(List(ActivitySummary), _)
    decoded = Json.parse(text)
    acts = decoded.map_err(|_| ActivityDecodeFailed(page))?
    upsert_all!(path, acts)?
    got = List.len(acts)
    total = acc + got
    if got < per_page
        Ok(total)
    else
        fetch_pages!(path, token, after_param, page + 1, total)
}
upsert_all! : Str, List(ActivitySummary) => Try({}, _)
upsert_all! = |path, acts|
    match acts {
        [] => Ok({})
        [a, .. as rest] => {
            upsert_activity!(path, a)?
            upsert_all!(path, rest)
        }

    }
upsert_activity! : Str, ActivitySummary => Try({}, _)
upsert_activity! = |path, a| {
    Sqlite.execute!({
        path: Path.utf8(path),
        query:
            \\INSERT OR REPLACE INTO activities (id, name, sport_type, start_local, moving_time, distance, elevation, relative_effort, avg_watts, avg_hr, weighted_avg_watts)
            \\VALUES (:id, :name, :sport, :start, :mt, :dist, :elev, :re, :aw, :ahr, :waw)
        ,
        bindings: [
            { name: ":id", value: Integer(a.id) },
            { name: ":name", value: String(a.name) },
            { name: ":sport", value: String(a.sport_type) },
            { name: ":start", value: String(a.start_date_local) },
            { name: ":mt", value: Integer(a.moving_time) },
            { name: ":dist", value: Real(a.distance) },
            { name: ":elev", value: Real(a.total_elevation_gain) },
            { name: ":re", value: opt_real(a.suffer_score) },
            { name: ":aw", value: opt_real(a.average_watts) },
            { name: ":ahr", value: opt_real(a.average_heartrate) },
            { name: ":waw", value: opt_real(a.weighted_average_watts) },
        ],
    })?
    # the row's raw fields may have changed (Strava edit within the rolling
    # window) — invalidate its metrics so "edits self-heal" is actually true
    invalidate_metrics!(path, a.id)
}

# ── analyze ──────────────────────────────────────────────────────────

zone_config_help =
        \\analyze needs your FTP and HR zone upper bounds in config first:
        \\
        \\    stride config set ftp_ride 190
        \\    stride config set hr_z1_max 123
        \\    stride config set hr_z2_max 153
        \\    stride config set hr_z3_max 168
        \\    stride config set hr_z4_max 183
        \\
        \\(find yours at strava.com/settings/heartrate — z5 is everything above z4_max)

analyze! : {} => Try({}, _)
analyze! = |{}| {
    path = open_db!({})?
    match load_zone_config!(path) {
        Err(MissingConfig) => missing_config!({})
        Err(other) => Err(other)
        Ok(cfg) => {
            res = compute_missing_metrics!(path, cfg.zb)?
            rebuild_daily_load!(path)?
            form =
                match Sqlite.query!({
                    path: Path.utf8(path),
                    query: "SELECT tsb AS tsb FROM daily_load ORDER BY day DESC LIMIT 1",
                    bindings: [],
                    row: Sqlite.f64("tsb"),
                }) {
                    Ok(tsb) => Ok(Some(tsb))
                    # no daily_load yet (nothing computed) is fine — skip the verdict;
                    # a real query error propagates instead of being swallowed
                    Err(NoRowsReturned) => Ok(None)
                    Err(other) => Err(other)
                }
            tsb_opt = form?
            if json_mode!({}) {
                form_tsb =
                    match tsb_opt {
                        Some(tsb) => tsb
                        None => 0.0
                    }
                emit_ok!({ computed: res.computed, stream_errors: res.stream_errors, form_tsb })
            } else {
                Stdout.line!("computed metrics for ${U64.to_str(res.computed)} activities")?
                (if res.stream_errors > 0
                    Stdout.line!("⚠ ${U64.to_str(res.stream_errors)} had unreadable stream data — computed from summary fields, will retry next sync")
                else
                    Ok({}))?
                # one verdict line; the full report lives in `stride summary`
                match tsb_opt {
                    Some(tsb) => Stdout.line!("→ today: form ${Render.fmt0(tsb)} — ${Metrics.form_label(tsb)}")
                    None => Ok({})

                }
            }
        }
    }
}
load_zone_config! : Str => Try({ ftp : F64, zb : Metrics.ZoneBounds }, _)
load_zone_config! = |path| {
    ftp = config_f64!(path, "ftp_ride")?
    z1 = config_f64!(path, "hr_z1_max")?
    z2 = config_f64!(path, "hr_z2_max")?
    z3 = config_f64!(path, "hr_z3_max")?
    z4 = config_f64!(path, "hr_z4_max")?
    Ok({ ftp, zb: { z1_max: z1, z2_max: z2, z3_max: z3, z4_max: z4 } })
}
config_f64! : Str, Str => Try(F64, _)
config_f64! = |path, key|
    match config_opt!(path, key)? {
        NotFound => Err(MissingConfig)
        Found(s) =>
            match F64.from_str(s) {
                Ok(v) => Ok(v)
                Err(_) => Err(MissingConfig)

            }
    }
ActivityRow : {
    id : I64,
    start : Str,
    mt : I64,
    sport : Str,
    re : [NotNull F64, Null],
    aw : [NotNull F64, Null],
    ahr : [NotNull F64, Null],
    waw : [NotNull F64, Null],
    rpe : [NotNull F64, Null],
    raw : [NotNull Str, Null],
}

compute_missing_metrics! : Str, Metrics.ZoneBounds => Try({ computed : U64, stream_errors : U64 }, _)
compute_missing_metrics! = |path, zb| {
    # recompute a row when its stored ftp_used no longer matches ITS sport's current
    # FTP (per-sport, via the CASE), or the HR zones / metrics_rev changed.
    ftp_case = sport_ftp_case!(path)?
    rows = Sqlite.query_many!({
        path: Path.utf8(path),
        query:
            \\SELECT a.id AS id, a.start_local AS start, a.moving_time AS mt,
            \\       COALESCE(a.sport_type, '') AS sport,
            \\       CAST(a.relative_effort AS REAL) AS re, CAST(a.avg_watts AS REAL) AS aw, CAST(a.avg_hr AS REAL) AS ahr,
            \\       CAST(a.weighted_avg_watts AS REAL) AS waw, CAST(r.rpe AS REAL) AS rpe, s.raw_json AS raw
            \\FROM activities a
            \\LEFT JOIN streams s ON s.activity_id = a.id
            \\LEFT JOIN ratings r ON r.activity_id = a.id
            \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
            \\WHERE m.activity_id IS NULL
            \\      OR CAST(COALESCE(m.ftp_used, 0) AS INTEGER) <> CAST((${ftp_case}) AS INTEGER)
            \\      OR COALESCE(m.zones_used, '') <> :zones
            \\      OR COALESCE(m.metrics_rev, 0) <> :rev
        ,
        bindings: [
            { name: ":zones", value: String(zones_sig(zb)) },
            { name: ":rev", value: Integer(metrics_rev) },
        ],
        rows: |cols| |stmt| {
            id = Sqlite.i64("id")(cols)(stmt)?
            start = Sqlite.str("start")(cols)(stmt)?
            mt = Sqlite.i64("mt")(cols)(stmt)?
            sport = Sqlite.str("sport")(cols)(stmt)?
            re = Sqlite.nullable_f64("re")(cols)(stmt)?
            aw = Sqlite.nullable_f64("aw")(cols)(stmt)?
            ahr = Sqlite.nullable_f64("ahr")(cols)(stmt)?
            waw = Sqlite.nullable_f64("waw")(cols)(stmt)?
            rpe = Sqlite.nullable_f64("rpe")(cols)(stmt)?
            raw = Sqlite.nullable_str("raw")(cols)(stmt)?
            Ok({ id, start, mt, sport, re, aw, ahr, waw, rpe, raw })
        },
    })?
    process_rows!(path, zb, rows, { computed: 0, stream_errors: 0 })
}
process_rows! : Str, Metrics.ZoneBounds, List(ActivityRow), { computed : U64, stream_errors : U64 } => Try({ computed : U64, stream_errors : U64 }, _)
process_rows! = |path, zb, rows, acc|
    match rows {
        [] => Ok(acc)
        [row, .. as rest] => {
            failed = compute_one!(path, zb, row)?
            next = {
                computed: acc.computed + 1,
                stream_errors: acc.stream_errors + (if failed 1 else 0),
            }
            process_rows!(path, zb, rest, next)
        }
    }
zero_zones : Metrics.ZoneSeconds
zero_zones = { z1: 0, z2: 0, z3: 0, z4: 0, z5: 0 }

# a stable signature of the HR zone bounds a metrics row was computed with, so a
# zone-config change invalidates + recomputes it (the same way ftp_used does for
# FTP). Bounds are whole bpm, so fmt0 is lossless and deterministic on both the
# write (compute_one!) and the compare (compute_missing_metrics! query).
zones_sig : Metrics.ZoneBounds -> Str
zones_sig = |zb|
    "${Render.fmt0(zb.z1_max)},${Render.fmt0(zb.z2_max)},${Render.fmt0(zb.z3_max)},${Render.fmt0(zb.z4_max)}"

# the power threshold (FTP) a sport's power is judged against, read from config key
# `ftp_<sport>` (Metrics.power_ftp_key) — uniform for EVERY sport, cycling included
# (`ftp_ride`). 0 when unset AND nothing to derive, in which case intensity/TSS fall
# back to HR. Fully generic: a new sport needs no code, just its `ftp_<sport>` key —
# or nothing, since we derive from the sport's own history.
sport_ftp! : Str, Str => Try(F64, _)
sport_ftp! = |path, sport| {
    key = Metrics.power_ftp_key(sport)
    configured =
        match config_get!(path, key) {
            Ok(s) => (F64.from_str(s)).ok_or(0.0)
            Err(_) => 0.0
        }
    raw =
        if configured > 0.0 configured
        # no configured FTP → derive from this sport's OWN best 20-min power (× 0.95),
        # so power-intensity works for any power sport with stream history, zero config
        else derive_sport_ftp!(path, sport)?
    # whole watts — keeps the stored ftp_used and the invalidation CASE exactly equal
    Ok(((raw).round_to_i64_try().ok_or(0)).to_f64())
}
derive_sport_ftp! : Str, Str => Try(F64, _)
derive_sport_ftp! = |path, sport| {
    best = Sqlite.query!({
        path: Path.utf8(path),
        query: "SELECT CAST(COALESCE(MAX(m.best_20min_w), 0) AS REAL) AS b FROM activity_metrics m JOIN activities a ON a.id = m.activity_id WHERE a.sport_type = :sport",
        bindings: [{ name: ":sport", value: String(sport) }],
        row: Sqlite.f64("b"),
    })?
    Ok(best * 0.95)
}
# a SQL `CASE a.sport_type WHEN … THEN <ftp> … ELSE 0 END` mapping each sport to its
# resolved FTP, so the analyze recompute-check compares each row's stored ftp_used to
# ITS sport's current FTP (not one global number). Without this, per-sport ftp_used
# would never equal the single cycling ftp and rowing/running rows would recompute
# every run. Sport names come from Strava (no quotes in practice; local single-user).
sport_ftp_case! : Str => Try(Str, _)
sport_ftp_case! = |path| {
    sports = Sqlite.query_many!({
        path: Path.utf8(path),
        query: "SELECT DISTINCT sport_type AS s FROM activities WHERE sport_type IS NOT NULL AND sport_type <> ''",
        bindings: [],
        rows: Sqlite.str("s"),
    })?
    whens = build_ftp_whens!(path, sports, "")?
    Ok("CASE a.sport_type${whens} ELSE 0 END")
}
build_ftp_whens! : Str, List(Str), Str => Try(Str, _)
build_ftp_whens! = |path, sports, acc|
    match sports {
        [] => Ok(acc)
        [s, .. as rest] => {
            f = sport_ftp!(path, s)?
            build_ftp_whens!(path, rest, "${acc} WHEN '${s}' THEN ${(f).to_str()}")
        }
    }
# returns Bool: did the stored stream JSON fail to decode? (surfaced by analyze)
compute_one! : Str, Metrics.ZoneBounds, ActivityRow => Try(Bool, _)
compute_one! = |path, zb, row| {
    decoded = Streams.decode_streams(row.raw)
    streams = decoded.streams

    # sanity-filter HR: some sources (Peloton strength workouts) emit junk
    # near-zero samples — Metrics.valid_hr is the one place the bounds live
    hr_pairs = List.keep_if(
        Streams.stream_pairs(streams.time, streams.heartrate),
        |p| Metrics.valid_hr(p.v),
    )
    # drop non-physiological power samples (sensor glitches) the same way HR is
    # filtered — one 1s spike would inflate NP and the 20-min best behind FTP.
    watts_pairs = List.keep_if(
        Streams.stream_pairs(streams.time, streams.watts),
        |p| Metrics.valid_watts(p.v),
    )
    watts_1s = Metrics.resample_1s(List.map(watts_pairs, |p| { t: p.t, v: p.v }))

    zones = if List.is_empty(hr_pairs) zero_zones else Metrics.time_in_zones(hr_pairs, zb)

    np_stream = Metrics.normalized_power(watts_1s)
    best20 = Metrics.best_rolling_mean(watts_1s, 1200)

    # intensity from power, judged against the sport's own FTP (0 for no-power sports
    # → all-zero, and the display falls back to HR). Stored so the weekly polarization
    # and the activities "hard" column read power where it exists, HR where it doesn't.
    pi_ftp = sport_ftp!(path, row.sport)?
    pintensity = Metrics.time_in_power_intensity(watts_pairs, pi_ftp)

    # the fallback chain lives in Metrics.tss_ladder (pure, expect-tested)
    nn = |x|
        match x {
            NotNull(v) => Ok(v)
            Null => Err(Missing)

        }
    ladder = Metrics.tss_ladder({
        np_stream,
        weighted_watts: nn(row.waw),
        avg_watts: nn(row.aw),
        avg_hr: nn(row.ahr),
        relative_effort: nn(row.re),
        rpe: nn(row.rpe),
        sport_type: row.sport,
        zones,
        zb,
        ftp: pi_ftp, # the SPORT's FTP, not cycling's — so rowing/running load is scaled right
        dur_s: (row.mt).to_f64(),
        moving_time: row.mt,
    })
    tss = ladder.tss

    np_binding =
        match ladder.np {
            Ok(npv) => Real(npv)
            Err(_) => Null

        }
    if_binding =
        match ladder.np {
            Ok(npv) => (if pi_ftp > 0.0 Real(npv / pi_ftp) else Null)
            Err(_) => Null

        }
    best20_binding =
        match best20 {
            Ok(b) => Real(b)
            Err(_) => Null

        }
    Sqlite.execute!({
        path: Path.utf8(path),
        query:
            \\INSERT OR REPLACE INTO activity_metrics
            \\  (activity_id, tss, normalized_power, intensity_factor, z1_s, z2_s, z3_s, z4_s, z5_s, computed_at, best_20min_w, ftp_used, zones_used, metrics_rev, load_model, pi_easy_s, pi_moderate_s, pi_hard_s)
            \\VALUES (:id, :tss, :np, :if, :z1, :z2, :z3, :z4, :z5, :at, :b20, :ftpu, :zused, :rev, :model, :pie, :pim, :pih)
        ,
        bindings: [
            { name: ":pie", value: Integer(pintensity.easy_s) },
            { name: ":pim", value: Integer(pintensity.moderate_s) },
            { name: ":pih", value: Integer(pintensity.hard_s) },
            { name: ":ftpu", value: Real(pi_ftp) },
            { name: ":zused", value: String(zones_sig(zb)) },
            { name: ":rev", value: Integer(metrics_rev) },
            { name: ":model", value: String(ladder.model) },
            { name: ":id", value: Integer(row.id) },
            { name: ":tss", value: Real(tss) },
            { name: ":np", value: np_binding },
            { name: ":if", value: if_binding },
            { name: ":z1", value: Integer(zones.z1) },
            { name: ":z2", value: Integer(zones.z2) },
            { name: ":z3", value: Integer(zones.z3) },
            { name: ":z4", value: Integer(zones.z4) },
            { name: ":z5", value: Integer(zones.z5) },
            { name: ":at", value: String(Metrics.epoch_to_iso(now_secs!({}))) },
            { name: ":b20", value: best20_binding },
        ],
    })?
    Ok(decoded.failed)
}
# ── daily load (CTL/ATL/TSB) ────────────────────────────────────────

rebuild_daily_load! : Str => Try({}, _)
rebuild_daily_load! = |path| {
    day_rows = Sqlite.query_many!({
        path: Path.utf8(path),
        query:
            \\SELECT substr(a.start_local, 1, 10) AS day, SUM(m.tss) AS t
            \\FROM activity_metrics m
            \\JOIN activities a ON a.id = m.activity_id
            \\GROUP BY day ORDER BY day
        ,
        bindings: [],
        rows: |cols| |stmt| {
            day = Sqlite.str("day")(cols)(stmt)?
            t = Sqlite.f64("t")(cols)(stmt)?
            Ok({ day, t })
        },
    })?
    # keep only rows whose date parses. Deriving the walk bounds from these VALID
    # days (not blindly from the first/last row) avoids the trap where a single
    # malformed start_local defaulted to epoch-day 0 and walked from 1970.
    by_day = List.fold(
        day_rows,
        Dict.empty({}),
        |dict, r|
            match Metrics.date_str_to_days(r.day) {
                Ok(d) => Dict.insert(dict, d, r.t)
                Err(_) => dict,
            }
    )
    valid_days = Dict.keys(by_day)
    match List.first(valid_days) {
        Err(_) => Ok({}) # nothing computed yet (or no parseable dates)
        Ok(seed) => {
            bounds = List.fold(valid_days, { lo: seed, hi: seed }, |b, d| { lo: (b.lo).min(d), hi: (b.hi).max(d) })
            # extend through today so rest days decay ATL/CTL and TSB is true as-of-now
            today = local_today_days!(path)?
            last_day = (bounds.hi).max(today)
            Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM daily_load", bindings: [] })?
            walk_days!(path, by_day, bounds.lo, last_day, 0.0, 0.0)
        }
    }
}
walk_days! : Str, Dict(I64, F64), I64, I64, F64, F64 => Try({}, _)
walk_days! = |path, by_day, day, last_day, ctl_prev, atl_prev|
    if day > last_day
        Ok({})
    else {
        tss = (Dict.get(by_day, day)).ok_or(0.0)
        # the CTL/ATL/TSB recurrence lives in Metrics.load_step (pure, expect-tested)
        step = Metrics.load_step({ ctl_prev, atl_prev, tss })
        Sqlite.execute!({
            path: Path.utf8(path),
            query: "INSERT OR REPLACE INTO daily_load (day, tss, ctl, atl, tsb) VALUES (:day, :tss, :ctl, :atl, :tsb)",
            bindings: [
                { name: ":day", value: String(Metrics.days_to_date_str(day)) },
                { name: ":tss", value: Real(tss) },
                { name: ":ctl", value: Real(step.ctl) },
                { name: ":atl", value: Real(step.atl) },
                { name: ":tsb", value: Real(step.tsb) },
            ],
        })?
        walk_days!(path, by_day, day + 1, last_day, step.ctl, step.atl)
    }
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
    path = open_db!({})?
    if period != "week" and period != "month" {
        err_out!("bad_period", "compare week | compare month (got '${period}')")
    } else {
        days = if period == "month" 28 else 7
        label = if period == "month" "28d" else "7d"
        match Sqlite.query!({ path: Path.utf8(path), query: "SELECT day AS day FROM daily_load ORDER BY day DESC LIMIT 1", bindings: [], row: Sqlite.str("day") }) {
            Err(NoRowsReturned) => err_out!("no_data", "nothing analyzed yet — run `stride sync` (or `stride import`) then `stride analyze`")
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
                out!({ period, window_label: label, current: block(cur, cur_ctl), prior: block(pri, pri_ctl) }, Render.compare_screen)
            }
        }
    }
}
# ── machine interface (JSON output for LLM/tool consumption) ────────
# Convention: numeric fields COALESCE to 0 when unknown (0 = "not available").

# one payload, two mouths: JSON for machines, a pure Render screen for humans.
# The pattern for query commands — payload record + Render.<cmd>_screen.
# JSON envelope contract version. Bumped when the wrapper shape changes (NOT the
# db schema_version / metrics_rev). Every machine response is versioned so tool
# callers can detect a contract change.
json_schema_version : I64
json_schema_version = 1

out! = |payload, render|
    if json_mode!({}) emit_ok!(payload) else Stdout.line!(render(payload))

# every JSON success is wrapped `{ schema_version, data }`; `data` is the command
# payload. Errors go through emit_err! and are `{ schema_version, error }` instead —
# a caller discriminates success from failure by which key is present.
emit_ok! = |val|
    print_json!({ schema_version: json_schema_version, data: val })

emit_err! : Str, Str => Try({}, _)
emit_err! = |code, msg|
    print_json!({ schema_version: json_schema_version, error: { code, message: msg } })

print_json! = |val|
    Stdout.line!(Json.to_str(val))
# output mode: humans get tables by default; LLM callers set STRIDE_FORMAT=json
# (CLAUDECODE env also flips to json for harnesses that set it)
json_mode! : {} => Bool
json_mode! = |{}|
    match Env.var_str!(OsStr.from_str("STRIDE_FORMAT")) {
        Ok(v) => Str.with_ascii_lowercased(Str.trim(v)) == "json"
        Err(_) =>
            match Env.var_str!(OsStr.from_str("CLAUDECODE")) {
                # set-but-empty is not "on" — require a non-empty value
                Ok(v) => !(Str.is_empty(v))
                Err(_) => False

            }
    }
# a known, user-fixable error: machine-readable JSON for tool callers, a plain
# line for humans. Exit stays 0 (in-band errors are the codebase convention —
# same as plan-add's dedup guard); the payload carries the failure.
err_out! : Str, Str => Try({}, _)
err_out! = |code, msg|
    if json_mode!({})
        emit_err!(code, msg)
    else
        Stdout.line!(msg)

# unconfigured zones/FTP: JSON error for tools, the setup help for humans
missing_config! : {} => Try({}, _)
missing_config! = |{}|
    if json_mode!({})
        emit_err!("missing_config", "set your FTP and HR zone bounds first — see `stride config`")
    else
        Stdout.line!(zone_config_help)

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
    path = open_db!({})?
    match I64.from_str(id_str) {
        Err(_) => err_out!("activity_not_found", "activity ${id_str} not found (run `stride activities` to list ids)")
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
        Err(_) => err_out!("activity_not_found", "activity ${id_str} not found (run `stride activities` to list ids)")
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
            pi_ftp = sport_ftp!(path, a.sport)?
            pintensity = Metrics.time_in_power_intensity(watts_pairs, pi_ftp)
            has_power_intensity = (pintensity.easy_s + pintensity.moderate_s + pintensity.hard_s) > 0

            if json_mode!({})
                emit_ok!({
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
    path = open_db!({})?
    today_days = local_today_days!(path)?
    year = (Metrics.civil_from_days(today_days)).y
    all_time = stats_rows!(path, "0000-01-01")?
    ytd = stats_rows!(path, "${(year).to_str()}-01-01")?
    if json_mode!({})
        emit_ok!({ all_time, ytd, ytd_year: year })
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
    path = open_db!({})?
    match load_zone_config!(path) {
        Err(MissingConfig) => missing_config!({})
        Err(other) => Err(other)
        Ok({ ftp, zb }) => {
            payload = summary_payload!(path, ftp, zb)?
            out!(payload, Render.summary_screen)
        }
    }
}
# weekly-planning bundle: everything the coach needs to plan a week, in one call
week! : {} => Try({}, _)
week! = |{}| {
    path = open_db!({})?
    match load_zone_config!(path) {
        Err(MissingConfig) => missing_config!({})
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
            if json_mode!({})
                emit_ok!({
                    summary: s,
                    recent_activities_14d: recent,
                    open_sessions: open_p,
                })
            else
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
    path = open_db!({})?
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
    if json_mode!({})
        emit_ok!(rows)
    else
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
    path = open_db!({})?
    match top_metric(metric) {
        Err(_) =>
            err_out!("bad_metric", "unknown metric '${metric}' — use: hr, tss, power, intensity, distance, time, output")

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
            if json_mode!({})
                emit_ok!(rows)
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
# ── import from a Strava account export (no API credentials needed) ──
# Phase 1 of the export path (#6): summary-level rows from activities.csv, fed
# through the SAME upsert as sync — idempotent, metrics-invalidation intact.
# Streams aren't in the CSV, so zone/NP metrics stay honestly absent; the TSS
# ladder falls back to watts/HR/relative-effort exactly as with sparse API data.
import_archive! : Str => Try({}, _)
import_archive! = |src| {
    db = open_db!({})?
    dir_result =
        if Str.ends_with(src, ".zip") {
            tmp = Cmd.new("mktemp").arg("-d").exec_output!().map_err(|_| ImportTempDirFailed)?
            tmp_dir = Str.trim(tmp.stdout_utf8)
            match Cmd.new("unzip").args(["-o", "-q", src, "-d", tmp_dir]).exec_output!() {
                Ok(_) => Ok(tmp_dir)
                Err(_) => Err(UnzipFailed)
            }
        }
        else
            Ok(src)
    match dir_result {
        Err(UnzipFailed) => err_out!("unzip_failed", "couldn't unzip ${src} — is `unzip` installed? (or extract it yourself and `stride import <dir>`)")
        Err(other) => Err(other)
        Ok(dir) => {
            csv_path = "${dir}/activities.csv"
            match Path.read_utf8!(Path.utf8(csv_path)) {
                Err(_) => err_out!("no_activities_csv", "no activities.csv in ${dir} — point me at a Strava account export (Settings → My Account → Download or Delete Your Account)")
                Ok(text) =>
                    match Csv.parse(text) {
                        [headers, .. as rows] => {
                            counts = import_rows!(db, headers, rows, { imported: 0.U64, skipped: 0.U64 })?
                            if json_mode!({})
                                emit_ok!(counts)
                            else
                                Stdout.line!("imported ${(counts.imported).to_str()} activities (${(counts.skipped).to_str()} rows skipped) — run `stride analyze` to compute metrics")
                        }
                        _ => err_out!("empty_csv", "activities.csv is empty")

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
            match export_row_to_summary(headers, row) {
                Ok(summary) => {
                    upsert_activity!(db, summary)?
                    import_rows!(db, headers, rest, { ..acc, imported: acc.imported + 1 })
                }
                Err(_) =>
                    import_rows!(db, headers, rest, { ..acc, skipped: acc.skipped + 1 })

            }
    }
# one CSV row => the same ActivitySummary the API sync feeds to upsert_activity!.
# Strava's export has DUPLICATE headers: the second Distance/Moving Time are the
# precise ones (meters/seconds); the first Distance is km. English exports only.
export_row_to_summary : List(Str), List(Str) -> Try(ActivitySummary, [BadRow])
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
    path = open_db!({})?
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
    pending = pending_streams!(path)?
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
    mode = resolve_time_mode!(path)?
    time_desc =
        match mode {
            Zone(name, off) => "timezone ${name} (${fmt_offset(off)} now, DST-aware)"
            FixedOffset(off) => "fixed offset ${fmt_offset(off)} (adjust seasonally for DST)"
            BadZone(name, off) => "timezone '${name}' UNKNOWN to system tz db — using ${fmt_offset(off)}; fix the name or set utc_offset_minutes"
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
    out!(payload, |p| {
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
# session-RPE rating: the athlete is the sensor for sports without power meters.
# Ratings live in their OWN table (the judgment tier) — never on the activities
# mirror, which sync/import replace wholesale. Rating an activity invalidates its
# metrics so the next analyze rescores it through the sport-aware ladder.
rate! : Str, Str => Try({}, _)
rate! = |target, rpe_str| {
    path = open_db!({})?
    rpe_result =
        match F64.from_str(rpe_str) {
            Ok(r) if r >= 1.0 and r <= 10.0 => Ok(r)
            _ => Err(BadRpe)
        }
    match rpe_result {
        Err(_) => err_out!("bad_rpe", "rate needs an effort from 1 (easy) to 10 (max) — got '${rpe_str}'")
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
                Err(BadId) => err_out!("bad_id", "rate needs an activity id or 'latest': rate <activity_id|latest> <1-10>")
                Err(NoActivities) => err_out!("no_activities", "nothing to rate yet — `stride sync` or `stride import` first")
                Err(other) => Err(other)
                Ok(activity_id) =>
                    if !(row_exists!(path, "activities", activity_id)?) {
                        err_out!("activity_not_found", "no activity ${I64.to_str(activity_id)} in the db — `stride sync` first?")
                    } else {
                        Sqlite.execute!({
                            path: Path.utf8(path),
                            query: "INSERT OR REPLACE INTO ratings (activity_id, rpe, rated_at) VALUES (:id, :rpe, :at)",
                            bindings: [
                                { name: ":id", value: Integer(activity_id) },
                                { name: ":rpe", value: Real(rpe) },
                                { name: ":at", value: String(Metrics.epoch_to_iso(now_secs!({}))) },
                            ],
                        })?
                        # a rating is a metric input — invalidate so analyze rescores
                        invalidate_metrics!(path, activity_id)?
                        out!({ rated: activity_id, rpe }, |p| "activity ${I64.to_str(p.rated)} rated ${Render.fmt0(p.rpe)}/10 — run `stride analyze` to rescore")
                    }
            }
        }
    }
}
# power-zone reference chart: the 7 Coggan/Peloton zones as watt ranges from your
# configured FTP (the targets you'd set on a Power Zone ride).
pz! : {} => Try({}, _)
pz! = |{}| {
    path = open_db!({})?
    match config_f64!(path, "ftp_ride") {
        Err(MissingConfig) => err_out!("missing_config", "set your FTP first: stride config set ftp_ride <watts>")
        Err(other) => Err(other)
        Ok(ftp) => {
            zones = Metrics.power_zones(ftp)
            if json_mode!({})
                emit_ok!({ ftp, zones })
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
    path = open_db!({})?
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
            err_out!("no_scorable_workouts", "nothing to compare yet — analyze activities first (and `stride rate` your strength sessions)")
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
                Ok(a) => err_out!("unscorable", "found \"${a.name}\" on ${date}, but it can't be compared — needs power+HR, distance+HR, or a rating (`stride rate <id> <1-10>`)")
                Err(_) => err_out!("no_workout_on_date", "no workout found on ${date}")
            }
        }
    } else if json_mode!({}) {
        emit_ok!({
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
    path = open_db!({})?
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
    out!(ordered, Render.load_screen)
}
plan_view! : [ThisWeek, AllTime] => Try({}, _)
plan_view! = |scope| {
    path = open_db!({})?
    # default view is the CURRENT training week (Mon-Sun containing today) so `plan`
    # is "this week at a glance", not the whole history spilling into next week. The
    # Monday offset is rem(days+3,7) — the same convention as Metrics.day_of_week.
    today = local_today_days!(path)?
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
    out!(enriched, |rows_enriched|
        Render.render_table(
            ["day", "date", "type", "status", "detail", "id"],
            List.map(rows_enriched, |p| [p.day, p.target_date, p.session_type, p.status, p.detail, (p.id).to_str()]),
        ))
}
plan_add! : Str, Str, Str, Str => Try({}, _)
plan_add! = |target_date, session_type, detail, rationale| {
    path = open_db!({})?
    # guard: one open planned session per date — skip or complete the old one first
    existing = Sqlite.query!({
        path: Path.utf8(path),
        query: "SELECT COALESCE(MAX(id), 0) AS id FROM planned_sessions WHERE target_date = :date AND COALESCE(status, 'open') = 'open'",
        bindings: [{ name: ":date", value: String(target_date) }],
        row: Sqlite.i64("id"),
    })?
    if existing > 0
        err_out!("date_already_planned", "${target_date} already has open planned session #${(existing).to_str()} — `stride skip ${(existing).to_str()} \"reason\"` first")
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
            { name: ":at", value: String(Metrics.epoch_to_iso(now_secs!({}))) },
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
    out!({ id: new_id, target_date, session_type }, |p| "planned #${(p.id).to_str()}: ${p.session_type} on ${p.target_date}")
}
# ONE not-found message for complete/complete-rest/skip — can't drift apart
session_not_found! : I64 => Try({}, _)
session_not_found! = |session_id|
    err_out!("session_not_found", "no planned session #${(session_id).to_str()} — run `stride plan` to see ids")

complete! : Str, Str => Try({}, _)
complete! = |session_id_str, activity_id_str| {
    path = open_db!({})?
    match (I64.from_str(session_id_str), I64.from_str(activity_id_str)) {
        (Ok(session_id), Ok(activity_id)) =>
            # SQLite UPDATE matching 0 rows is not an error — check existence
            # ourselves so a typo'd id can't report false success and silently
            # leave the planned session open / the coaching log out of sync
            if !(row_exists!(path, "planned_sessions", session_id)?) {
                session_not_found!(session_id)
            } else if !(row_exists!(path, "activities", activity_id)?) {
                err_out!("activity_not_found", "no activity ${I64.to_str(activity_id)} in the db — `stride sync` first?")
            } else {
                Sqlite.execute!({
                    path: Path.utf8(path),
                    query: "UPDATE planned_sessions SET completed_activity_id = :aid, status = 'done' WHERE id = :pid",
                    bindings: [
                        { name: ":aid", value: Integer(activity_id) },
                        { name: ":pid", value: Integer(session_id) },
                    ],
                })?
                out!({ completed_session: session_id, activity: activity_id }, |p| "planned session #${I64.to_str(p.completed_session)} completed by activity ${I64.to_str(p.activity)}")
            }
        _ =>
            err_out!("bad_id", "complete needs numeric ids: complete <session_id> <activity_id>")

    }
}
# rest days have no activity to link — `complete <id>` alone closes them. Any
# other session type still demands its activity id: done means evidence.
complete_rest! : Str => Try({}, _)
complete_rest! = |session_id_str| {
    path = open_db!({})?
    match I64.from_str(session_id_str) {
        Err(_) => err_out!("bad_id", "complete needs a numeric id: complete <session_id> [activity_id]")
        Ok(session_id) =>
            if !(row_exists!(path, "planned_sessions", session_id)?)
                session_not_found!(session_id)
            else {
                session_type = Sqlite.query!({
                    path: Path.utf8(path),
                    query: "SELECT COALESCE(session_type, '') AS t FROM planned_sessions WHERE id = :pid",
                    bindings: [{ name: ":pid", value: Integer(session_id) }],
                    row: Sqlite.str("t"),
                })?
                if session_type != "rest"
                    err_out!("activity_required", "planned session #${(session_id).to_str()} is '${session_type}' — completing it needs the activity id (only rest days close without one)")
                else
                    Sqlite.execute!({
                        path: Path.utf8(path),
                        query: "UPDATE planned_sessions SET status = 'done' WHERE id = :pid",
                        bindings: [{ name: ":pid", value: Integer(session_id) }],
                    })?
                    out!({ completed_session: session_id, rest: True }, |p| "planned session #${(p.completed_session).to_str()} (rest) marked done")
            }
    }
}
skip! : Str, Str => Try({}, _)
skip! = |session_id_str, reason| {
    path = open_db!({})?
    match I64.from_str(session_id_str) {
        Ok(session_id) =>
            if !(row_exists!(path, "planned_sessions", session_id)?) {
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
                out!({ skipped_session: session_id, reason }, |p| "planned session #${I64.to_str(p.skipped_session)} skipped: ${p.reason}")
            }
        Err(_) =>
            err_out!("bad_id", "skip needs a numeric id: skip <session_id> \"<reason>\"")

    }
}
# ── migrations ───────────────────────────────────────────────────────

# bump when the schema changes; ensure_schema! re-runs migrations when the db's
# PRAGMA user_version is behind this. (The additive ALTERs below are the columns
# that post-date the original CREATE statements in Schema.roc.)
schema_version = 10

# bump when the metric MATH changes (tss ladder, zone attribution, NP windowing,
# HR validity bounds, ...) so existing rows recompute — config inputs (ftp_used,
# zones_used) can't catch algorithm changes
metrics_rev = 6

run_migrations! : Str => Try({}, _)
run_migrations! = |path| {
    # v5: prescriptions => planned_sessions ("a coach plans sessions" — the
    # medical word is gone). MUST run before the CREATEs below, or an empty
    # planned_sessions would shadow the old data.
    rename_table_if_exists!(path, "prescriptions", "planned_sessions")?
    Sqlite.execute!({ path: Path.utf8(path), query: Schema.activities, bindings: [] })?
    Sqlite.execute!({ path: Path.utf8(path), query: Schema.metrics, bindings: [] })?
    Sqlite.execute!({ path: Path.utf8(path), query: Schema.daily_load, bindings: [] })?
    Sqlite.execute!({ path: Path.utf8(path), query: Schema.planned_sessions, bindings: [] })?
    Sqlite.execute!({ path: Path.utf8(path), query: Schema.config, bindings: [] })?
    Sqlite.execute!({ path: Path.utf8(path), query: Schema.streams, bindings: [] })?
    Sqlite.execute!({ path: Path.utf8(path), query: Schema.ratings, bindings: [] })?
    alter_add_column!(path, "ALTER TABLE activities ADD COLUMN weighted_avg_watts REAL")?
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_20min_w REAL")?
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN ftp_used REAL")?
    alter_add_column!(path, "ALTER TABLE planned_sessions ADD COLUMN status TEXT")?
    alter_add_column!(path, "ALTER TABLE planned_sessions ADD COLUMN skipped_reason TEXT")?
    # v3: metrics record the HR zone bounds they were computed with, so a zone-
    # config change invalidates + recomputes (like ftp_used does for FTP)
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN zones_used TEXT")?
    # v4: metrics record the algorithm revision they were computed with, so a
    # change to the math itself (metrics_rev bump) invalidates + recomputes
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN metrics_rev INTEGER")?
    # v6: metrics record WHICH ladder rung scored them (load provenance)
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN load_model TEXT")?
    # v8: drop load_confidence — it was a pure function of load_model (v7), so storing
    # it was redundant denormalization. Confidence is now derived from load_model at
    # read time (doctor). The drop cleans up dbs that got the v7 column.
    drop_column_if_exists!(path, "ALTER TABLE activity_metrics DROP COLUMN load_confidence")?
    # v9: time-in-intensity from POWER (easy/moderate/hard seconds), judged against the
    # sport's own FTP — the truer "how hard" for power sports than HR zones
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN pi_easy_s INTEGER")?
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN pi_moderate_s INTEGER")?
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN pi_hard_s INTEGER")?
    # v10: FTP is now per-sport under `ftp_<sport>` (uniform, no special cycling key).
    # Move the old cycling `ftp` value to `ftp_ride` if it hasn't been set already.
    Sqlite.execute!({ path: Path.utf8(path), query: "UPDATE config SET key = 'ftp_ride' WHERE key = 'ftp' AND (SELECT COUNT(*) FROM config WHERE key = 'ftp_ride') = 0", bindings: [] })?
    # v2: index the column every date-range filter and the activities sort use
    # (queries now compare a.start_local directly — sargable — instead of substr)
    Sqlite.execute!({ path: Path.utf8(path), query: "CREATE INDEX IF NOT EXISTS idx_activities_start ON activities(start_local)", bindings: [] })
}

# rename old => new when old exists and new doesn't (idempotent, data-preserving)
rename_table_if_exists! : Str, Str, Str => Try({}, _)
rename_table_if_exists! = |path, old, new| {
    count = Sqlite.query!({
        path: Path.utf8(path),
        query: "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = :old",
        bindings: [{ name: ":old", value: String(old) }],
        row: Sqlite.i64("n"),
    })?
    if count > 0
        Sqlite.execute!({ path: Path.utf8(path), query: "ALTER TABLE ${old} RENAME TO ${new}", bindings: [] })
    else
        Ok({})
}
# an additive ADD COLUMN. Swallows ONLY "duplicate column" (the expected re-run
# case); a locked db, disk error, etc. propagate instead of failing silently.
alter_add_column! : Str, Str => Try({}, _)
alter_add_column! = |path, q|
    match Sqlite.execute!({ path: Path.utf8(path), query: q, bindings: [] }) {
        Ok({}) => Ok({})
        Err(SqliteErr(Error, msg)) =>
            if Str.contains(msg, "duplicate column") Ok({}) else Err(SqliteErr(Error, msg))
        Err(other) => Err(other)

    }
# idempotent column drop: a db that never had the column (fresh, or already dropped)
# reports "no such column" — that's the converged state, not a failure.
drop_column_if_exists! : Str, Str => Try({}, _)
drop_column_if_exists! = |path, q|
    match Sqlite.execute!({ path: Path.utf8(path), query: q, bindings: [] }) {
        Ok({}) => Ok({})
        Err(SqliteErr(Error, msg)) =>
            if Str.contains(msg, "no such column") Ok({}) else Err(SqliteErr(Error, msg))
        Err(other) => Err(other)

    }
# run migrations exactly when the db is behind, then stamp the version. Called
# on every command entry (via open_db!) so upgrading the binary against an
# existing db self-migrates instead of failing with an opaque missing-column error.
ensure_schema! : Str => Try({}, _)
ensure_schema! = |path| {
    v = (Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT user_version AS v FROM pragma_user_version()",
            bindings: [],
            row: Sqlite.i64("v"),
        })).ok_or(0)
    if v >= schema_version
        Ok({})
    else
        run_migrations!(path)?
        Sqlite.execute!({ path: Path.utf8(path), query: "PRAGMA user_version = ${(schema_version).to_str()}", bindings: [] })
}
# db path + guaranteed-current schema. Every command opens through this.
open_db! : {} => Try(Str, _)
open_db! = |{}| {
    p = db_path!({})?
    ensure_schema!(p)?
    # harden on every open so existing world-readable installs get fixed too
    home = Env.var_str!(OsStr.from_str("HOME"))?
    secure_perms!("${home}/.stride")?
    Ok(p)
}
# (schema DDL lives in Schema.roc — pure strings, the one kind of SQL that
#  can move out of the app module without splitting a query from its decoder)
