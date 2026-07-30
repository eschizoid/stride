app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.20.0/X73hGh05nNTkDHU06FHC0YfFaQB1pimX7gncRcao5mU.tar.br",
    json: "https://github.com/lukewilliamboswell/roc-json/releases/download/0.13.0/RqendgZw5e1RsQa3kFhgtnMP8efWoqGRsAvubx4-zus.tar.br",
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
# computes deterministically; the coach reasons and writes prescriptions back
# through the coaching-log commands. Neither does the other's job.

import pf.Stdout
import pf.Stdin
import pf.Arg exposing [Arg]
import pf.Env
import pf.Dir
import pf.Http
import pf.Utc
import pf.Sleep
import pf.Sqlite
import json.Json
import json.Option exposing [Option]
import Metrics
import Schema
import Render
import Backfill

version = "stride 0.1.0" # x-release-please-version

help_text =
    """
    stride — a local-first multi-sport training engine (built in Roc)
    Designed to be driven by an LLM coach (e.g. Claude Code) or by hand.

    USAGE
        stride <command>

    DATA COMMANDS
        init        create ~/.stride and migrate the SQLite db
        auth        authorize with Strava (one-time paste flow; stores creds)
        sync        pull new activities + streams (rolling 30d self-heal)
        backfill    re-pull the full activity list + ALL missing streams,
                    rate-limit-aware (first-time imports, deep reconcile)
        analyze     compute training metrics (TSS, zones, CTL/ATL/TSB)
        config      get/set config (e.g. ftp, hr zone bounds)

    QUERY COMMANDS (human tables in a terminal; JSON when STRIDE_FORMAT=json
                    or CLAUDECODE is set — for LLM/tool callers)
        summary                 coach-input payload: form, 7d/28d zones, FTP calibration
        stats                   career + year-to-date totals per sport
        week                    weekly-planning bundle: summary + open prescriptions
                                + last 14 days of activities (one call, plan a week)
        activities [limit] [sport]   recent activities with metrics (default 30);
                                     sport filters, e.g. `activities 10 rowing`
        top <metric> [n] [sport]     best sessions ranked by a metric (default 10):
                                     hr | tss | power | intensity | distance | time | output
        pz                           power-zone watt ranges (7 zones) from your FTP
        progress <date>              am I improving on that day's workout? every
                                     comparable instance + EF trend (watts/HR).
                                     auto-named rides compare similar-distance only
        activity <id>           one session in depth: zones, power bests, hard minutes
        load [days]             CTL/ATL/TSB series: daily <=14 days, weekly beyond (default 90)
        prescriptions           prescription log (open/done/skipped), calendar order
                                with day-of-week (Mon-Sun) and rest days

    COACHING LOG
        prescribe <date> <type> <detail> <rationale>   record a prescribed session
                                                       (refuses if date already has an open one)
        complete <prescription_id> <activity_id>       link a prescription to a done activity
        skip <prescription_id> <reason>                mark a prescription as skipped

    FLAGS
        --help      show this help
        --version   show version

    SETUP (first time only)
        Create a Strava API app (strava.com/settings/api), then:
        STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth
        After that, creds live in the db — no env vars needed again.
    """

main! : List Arg => Result {} _
main! = |raw_args|
    args = List.map(raw_args, Arg.display)
    when args is
        [_, "init"] -> init!({})
        [_, "auth"] -> auth!({})
        [_, "sync"] -> sync!({})
        [_, "backfill"] -> backfill!({})
        [_, "analyze"] -> analyze!({})
        [_, "summary"] -> summary!({})
        [_, "stats"] -> stats!({})
        [_, "week"] -> week!({})
        [_, "activities"] -> activities!(30, "")
        [_, "activities", n] -> with_count!(n, |c| activities!(c, ""))
        [_, "activities", n, sport] -> with_count!(n, |c| activities!(c, sport))
        [_, "top", metric] -> top!(metric, 10, "")
        [_, "top", metric, n] -> with_count!(n, |c| top!(metric, c, ""))
        [_, "top", metric, n, sport] -> with_count!(n, |c| top!(metric, c, sport))
        [_, "pz"] -> pz!({})
        [_, "progress", name] -> progress!(name)
        [_, "activity", id_str] -> activity!(id_str)
        [_, "load"] -> load_series!(90)
        [_, "load", n] -> with_count!(n, |c| load_series!(c))
        [_, "prescriptions"] -> prescriptions!({})
        [_, "prescribe", date, session_type, detail, rationale] -> prescribe!(date, session_type, detail, rationale)
        [_, "complete", presc_id, activity_id] -> complete!(presc_id, activity_id)
        [_, "skip", presc_id, reason] -> skip!(presc_id, reason)
        [_, "config", "get", key] -> config_show!(key)
        [_, "config", "set", key, val] -> config_store!(key, val)
        [_, "--version"] -> Stdout.line!(version)
        # wrong arity on multi-arg commands: targeted usage, not the whole help
        [_, "prescribe", ..] -> usage!("prescribe <YYYY-MM-DD> <type> \"<detail>\" \"<rationale>\"")
        [_, "complete", ..] -> usage!("complete <prescription_id> <activity_id>")
        [_, "skip", ..] -> usage!("skip <prescription_id> \"<reason>\"")
        [_, "activity", ..] -> usage!("activity <activity_id>")
        [_, "config", ..] -> usage!("config get <key>  |  config set <key> <value>")
        _ -> Stdout.line!(help_text)

usage! : Str => Result {} _
usage! = |u|
    Stdout.line!("usage: stride ${u}")

# parse a count argument, or emit a clean error instead of silently defaulting
# (so `stride activities banana` tells you it's wrong, not shows 30 rows)
with_count! : Str, (U64 => Result {} _) => Result {} _
with_count! = |s, f!|
    when Str.to_u64(s) is
        Ok(n) -> f!(n)
        Err(_) -> err_out!("bad_count", "expected a number, got '${s}'")

config_show! : Str => Result {} _
config_show! = |key|
    path = open_db!({})?
    when config_opt!(path, key)? is
        Found(v) -> Stdout.line!(v)
        NotFound -> Stdout.line!("(not set)")

config_store! : Str, Str => Result {} _
config_store! = |key, val|
    path = open_db!({})?
    config_set!(path, key, val)?
    Stdout.line!("${key} = ${val}")?
    # FTP is the one config that also lives on Strava — keep them in sync so
    # Strava's own power features use the same number
    if key == "ftp" then sync_ftp_to_strava!(path, val) else Ok({})

# push a new FTP to Strava (PUT /athlete?ftp=). Best-effort: any failure just
# warns — the local `config set` has already succeeded and been reported.
sync_ftp_to_strava! : Str, Str => Result {} _
sync_ftp_to_strava! = |path, ftp_str|
    when Str.to_f64(ftp_str) is
        Err(_) -> Ok({}) # non-numeric ftp — nothing sensible to push
        Ok(_) ->
            when get_valid_token!(path) is
                Err(NotAuthed) -> Stdout.line!("  (not synced to Strava — run `stride auth` first)")
                Err(_) -> Stdout.line!("  (couldn't sync FTP to Strava this time)")
                Ok(token) ->
                    resp = Http.send!({
                        method: PUT,
                        headers: [Http.header(("Authorization", "Bearer ${token}"))],
                        uri: "https://www.strava.com/api/v3/athlete?ftp=${ftp_str}",
                        body: [],
                        timeout_ms: TimeoutMilliseconds(30000),
                    })
                    when resp is
                        Ok(r) if r.status < 300 -> Stdout.line!("  → synced to Strava (athlete FTP = ${ftp_str})")
                        Ok(r) -> Stdout.line!("  (Strava FTP sync failed: HTTP ${Num.to_str(r.status)} — set it at strava.com/settings)")
                        Err(_) -> Stdout.line!("  (couldn't reach Strava to sync FTP — set it at strava.com/settings)")

# ── paths ────────────────────────────────────────────────────────────

db_path! : {} => Result Str _
db_path! = |{}|
    home = Env.var!("HOME")?
    Ok("${home}/.stride/db.sqlite")

init! : {} => Result {} _
init! = |{}|
    home = Env.var!("HOME")?
    dir = "${home}/.stride"
    # ignore AlreadyExists — idempotent init
    _ = Dir.create!(dir)
    path = "${dir}/db.sqlite"
    ensure_schema!(path)?
    Stdout.line!("initialized ${path}")

# ── config key-value helpers ─────────────────────────────────────────

config_get! : Str, Str => Result Str _
config_get! = |path, key|
    Sqlite.query!({
        path,
        query: "SELECT value FROM config WHERE key = :key",
        bindings: [{ name: ":key", value: String(key) }],
        row: Sqlite.str("value"),
    })

# read a config key, distinguishing "genuinely absent" from "the db read failed"
# — so a locked/corrupt db surfaces as a real error instead of masquerading as
# "not set" / "not authenticated" / "set your FTP".
config_opt! : Str, Str => Result [Found Str, NotFound] _
config_opt! = |path, key|
    when config_get!(path, key) is
        Ok(v) -> Ok(Found(v))
        Err(NoRowsReturned) -> Ok(NotFound)
        Err(other) -> Err(other)

config_set! : Str, Str, Str => Result {} _
config_set! = |path, key, value|
    Sqlite.execute!({
        path,
        query: "INSERT OR REPLACE INTO config (key, value) VALUES (:key, :value)",
        bindings: [
            { name: ":key", value: String(key) },
            { name: ":value", value: String(value) },
        ],
    })

# ── strava oauth ─────────────────────────────────────────────────────

TokenResp : { access_token : Str, refresh_token : Str, expires_at : I64 }

token_url = "https://www.strava.com/oauth/token"

env_or_explain! : Str => Result Str _
env_or_explain! = |name|
    when Env.var!(name) is
        Ok(v) -> Ok(v)
        Err(_) -> Err(MissingEnv(name))

# a stored token field: absent -> NotAuthed (genuine); db failure propagates
token_field! : Str, Str => Result Str _
token_field! = |path, key|
    when config_opt!(path, key)? is
        Found(v) -> Ok(v)
        NotFound -> Err(NotAuthed)

# client credentials: env var wins, else stored config (written by `auth`)
client_cred! : Str, Str, Str => Result Str _
client_cred! = |path, env_name, key|
    when Env.var!(env_name) is
        Ok(v) -> Ok(v)
        Err(_) -> Result.map_err(config_get!(path, key), |_| MissingEnv(env_name))

auth! : {} => Result {} _
auth! = |{}|
    path = open_db!({})?
    client_id = env_or_explain!("STRAVA_CLIENT_ID")?
    client_secret = env_or_explain!("STRAVA_CLIENT_SECRET")?
    url = "https://www.strava.com/oauth/authorize?client_id=${client_id}&response_type=code&redirect_uri=http://localhost&approval_prompt=auto&scope=read,activity:read_all"
    Stdout.line!("1) Open this URL in your browser and click Authorize:")?
    Stdout.line!("")?
    Stdout.line!("   ${url}")?
    Stdout.line!("")?
    Stdout.line!("2) You'll land on a localhost page that fails to load — that's expected.")?
    Stdout.line!("   Copy the code=XXXX value from the address bar and paste it here.")?
    Stdout.line!("")?
    Stdout.write!("code: ")?
    code_raw = Stdin.line!({})?
    code = Str.trim(code_raw)
    form = "client_id=${client_id}&client_secret=${client_secret}&code=${code}&grant_type=authorization_code"
    body = post_form!(token_url, form)?
    tokens = decode_tokens(body)?
    save_tokens!(path, tokens)?
    # persist client creds so sync never needs env vars again
    config_set!(path, "strava_client_id", client_id)?
    config_set!(path, "strava_client_secret", client_secret)?
    Stdout.line!("authorized — tokens stored. Run `stride sync` to pull your activities.")

decode_tokens : List U8 -> Result TokenResp _
decode_tokens = |body|
    decoded : Result TokenResp _
    decoded = Decode.from_bytes(body, Json.utf8)
    Result.map_err(decoded, |_| TokenDecodeFailed)

save_tokens! : Str, TokenResp => Result {} _
save_tokens! = |path, tokens|
    config_set!(path, "strava_access_token", tokens.access_token)?
    config_set!(path, "strava_refresh_token", tokens.refresh_token)?
    config_set!(path, "strava_expires_at", Num.to_str(tokens.expires_at))

now_secs! : {} => I64
now_secs! = |{}|
    millis = Utc.to_millis_since_epoch(Utc.now!({}))
    Num.to_i64(millis // 1000)

# "today" as a LOCAL calendar day. The platform clock (Utc.now!) is UTC-only,
# but every activity date is Strava's local civil date — so for any user west
# of UTC, the UTC day rolls over hours before their local day, inserting a
# phantom "tomorrow" into the load series each evening. config utc_offset_minutes
# (default 0) re-anchors the day boundary to local time. Fixed offset — set it
# seasonally if you observe DST (e.g. -300 CDT / -360 CST).
local_today_days! : Str => Result I64 _
local_today_days! = |path|
    offset_min =
        when config_get!(path, "utc_offset_minutes") is
            Ok(s) -> Result.with_default(Str.to_i64(s), 0)
            Err(_) -> 0
    Ok((now_secs!({}) + offset_min * 60) // 86400)

# returns a valid access token, refreshing if expired; NotAuthed if never
# authorized (a genuinely absent token — NOT a db read failure, which propagates)
get_valid_token! : Str => Result Str _
get_valid_token! = |path|
    access = token_field!(path, "strava_access_token")?
    refresh = token_field!(path, "strava_refresh_token")?
    expires_str = token_field!(path, "strava_expires_at")?
    expires_at = Result.map_err(Str.to_i64(expires_str), |_| CorruptToken)?
    now = now_secs!({})
    if now < (expires_at - 60) then
        Ok(access)
    else
        client_id = client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id")?
        client_secret = client_cred!(path, "STRAVA_CLIENT_SECRET", "strava_client_secret")?
        form = "client_id=${client_id}&client_secret=${client_secret}&grant_type=refresh_token&refresh_token=${refresh}"
        body = post_form!(token_url, form)?
        tokens = decode_tokens(body)?
        save_tokens!(path, tokens)?
        Ok(tokens.access_token)

# ── http helpers ─────────────────────────────────────────────────────

post_form! : Str, Str => Result (List U8) _
post_form! = |uri, form|
    resp = Http.send!({
        method: POST,
        headers: [Http.header(("Content-Type", "application/x-www-form-urlencoded"))],
        uri,
        body: Str.to_utf8(form),
        timeout_ms: TimeoutMilliseconds(30000),
    })?
    ok_body(resp)

get_bearer! : Str, Str => Result (List U8) _
get_bearer! = |uri, token|
    resp = Http.send!({
        method: GET,
        headers: [Http.header(("Authorization", "Bearer ${token}"))],
        uri,
        body: [],
        timeout_ms: TimeoutMilliseconds(60000),
    })?
    ok_body(resp)

ok_body : { status : U16, headers : List { name : Str, value : Str }, body : List U8 } -> Result (List U8) _
ok_body = |resp|
    if resp.status < 300 then
        Ok(resp.body)
    else
        text = Result.with_default(Str.from_utf8(resp.body), "<non-utf8 body>")
        Err(HttpStatus(resp.status, text))

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
    suffer_score : Option F64,
    average_watts : Option F64,
    average_heartrate : Option F64,
    weighted_average_watts : Option F64,
}

opt_real : Option F64 -> [Real F64, Null]
opt_real = |o|
    when Option.get(o) is
        Some(v) -> Real(v)
        None -> Null

sync! : {} => Result {} _
sync! = |{}|
    path = open_db!({})?
    when get_valid_token!(path) is
        Err(NotAuthed) ->
            err_out!("not_authenticated", "not authenticated — run `stride auth` first")

        Err(other) -> Err(other)
        Ok(token) ->
            started = now_secs!({})
            # incremental with a rolling 30-day overlap so recent edits on
            # Strava self-heal (`backfill` is the full re-pull when needed)
            after_param =
                # NotFound (never synced) = full pull is correct; a real db read
                # error propagates instead of silently burning the rate budget
                when config_opt!(path, "last_sync_epoch")? is
                    NotFound -> ""
                    Found(epoch_str) ->
                        when Str.to_i64(epoch_str) is
                            Ok(e) -> "&after=${Num.to_str(Num.max(e - 2592000, 0))}"
                            Err(_) -> ""
            count = fetch_pages!(path, token, after_param, 1, 0)?
            config_set!(path, "last_sync_epoch", Num.to_str(started))?
            streams_n = backfill_streams!(path, token)?
            remaining = pending_streams!(path)?
            tail =
                if remaining > 0 then
                    " (${Num.to_str(remaining)} still need streams — run `stride backfill` to pull them all)"
                else
                    ""
            Stdout.line!("synced ${Num.to_str(count)} activities, fetched streams for ${Num.to_str(streams_n)}${tail}")

# fetch time/HR/watts streams for activities that don't have them yet,
# newest first, capped per run to respect Strava's rate limits (~100 reads/15min)
streams_per_run = 60

backfill_streams! : Str, Str => Result U64 _
backfill_streams! = |path, token|
    ids = Sqlite.query_many!({
        path,
        query:
        """
        SELECT a.id AS id FROM activities a
        LEFT JOIN streams s ON s.activity_id = a.id
        WHERE s.activity_id IS NULL AND a.moving_time > 0
        ORDER BY a.start_local DESC
        LIMIT ${Num.to_str(streams_per_run)}
        """,
        bindings: [],
        rows: Sqlite.i64("id"),
    })?
    fetch_streams_all!(path, token, ids, 0)

# count activities still lacking streams (so sync can report incomplete backfill
# honestly instead of letting the 60/run cap look like completion)
pending_streams! : Str => Result I64 _
pending_streams! = |path|
    Sqlite.query!({
        path,
        query:
        """
        SELECT COUNT(*) AS n FROM activities a
        LEFT JOIN streams s ON s.activity_id = a.id
        WHERE s.activity_id IS NULL AND a.moving_time > 0
        """,
        bindings: [],
        row: Sqlite.i64("n"),
    })

fetch_streams_all! : Str, Str, List I64, U64 => Result U64 _
fetch_streams_all! = |path, token, ids, acc|
    when ids is
        [] -> Ok(acc)
        [id, .. as rest] ->
            id_str = Num.to_str(id)
            uri = "https://www.strava.com/api/v3/activities/${id_str}/streams?keys=time,heartrate,watts&key_by_type=true"
            when get_bearer!(uri, token) is
                Ok(body) ->
                    when Str.from_utf8(body) is
                        Ok(text) ->
                            store_streams!(path, id, text)?
                            fetch_streams_all!(path, token, rest, acc + 1)

                        Err(_) ->
                            # non-utf8/corrupt body — do NOT store (storing would
                            # mark it done forever); leave it to retry next sync
                            fetch_streams_all!(path, token, rest, acc)

                Err(HttpStatus(404, _)) ->
                    # no streams recorded (manual entry etc.) — remember that so we don't refetch
                    store_streams!(path, id, "{}")?
                    fetch_streams_all!(path, token, rest, acc + 1)

                Err(HttpStatus(429, _)) ->
                    # rate limited — stop gracefully, next sync continues the backfill
                    Stdout.line!("rate limited by Strava — stopping streams backfill for now (will resume next sync)")?
                    Ok(acc)

                Err(other) -> Err(other)

store_streams! : Str, I64, Str => Result {} _
store_streams! = |path, id, text|
    Sqlite.execute!({
        path,
        query: "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (:id, :raw)",
        bindings: [
            { name: ":id", value: Integer(id) },
            { name: ":raw", value: String(text) },
        ],
    })?
    # streams just arrived — invalidate any metrics computed before them so the
    # next analyze recomputes zones/NP from the real data (they were frozen otherwise)
    invalidate_metrics!(path, id)

# drop an activity's computed metrics so the next analyze recomputes it. the
# invalidation story: FTP change (ftp_used check), stream arrival, Strava edit.
invalidate_metrics! : Str, I64 => Result {} _
invalidate_metrics! = |path, id|
    Sqlite.execute!({
        path,
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

send_bearer! : Str, Str => Result Http.Response _
send_bearer! = |uri, token|
    Http.send!({
        method: GET,
        headers: [Http.header(("Authorization", "Bearer ${token}"))],
        uri,
        body: [],
        timeout_ms: TimeoutMilliseconds(60000),
    })

# store a streams response like the sync path: 404 -> honest empty marker,
# 2xx -> body (skip if non-utf8 so it retries), other -> propagate the error
store_stream_response! : Str, I64, Http.Response => Result {} _
store_stream_response! = |path, id, resp|
    if resp.status == 404 then
        store_streams!(path, id, "{}")
    else if resp.status < 300 then
        when Str.from_utf8(resp.body) is
            Ok(text) -> store_streams!(path, id, text)
            Err(_) -> Ok({})

    else
        text = Result.with_default(Str.from_utf8(resp.body), "<non-utf8 body>")
        Err(HttpStatus(resp.status, text))

backfill! : {} => Result {} _
backfill! = |{}|
    path = open_db!({})?
    when get_valid_token!(path) is
        Err(NotAuthed) -> err_out!("not_authenticated", "not authenticated — run `stride auth` first")
        Err(other) -> Err(other)
        Ok(token) ->
            # pull the full activity list first so backfill is self-sufficient —
            # no need to run `sync` beforehand (that's what made it two commands)
            Stdout.line!("backfill: refreshing the activity list...")?
            count = fetch_pages!(path, token, "", 1, 0)?
            config_set!(path, "last_sync_epoch", Num.to_str(now_secs!({})))?
            missing_ids = Sqlite.query_many!({
                path,
                query:
                """
                SELECT a.id AS id FROM activities a
                LEFT JOIN streams s ON s.activity_id = a.id
                WHERE s.activity_id IS NULL AND a.moving_time > 0
                ORDER BY a.start_local DESC
                """,
                bindings: [],
                rows: Sqlite.i64("id"),
            })?
            missing = List.len(missing_ids)
            if missing == 0 then
                Stdout.line!("backfill: ${Num.to_str(count)} activities, all streams already present — nothing to do")
            else
                Stdout.line!("backfill: ${Num.to_str(count)} activities, ${Num.to_str(missing)} need streams. Strava allows ~1000 reads/day, so a large first pull can span a few days — this run drains as far as today's limit allows and is resumable (just run `stride backfill` again).")?
                drain_streams!(path, token, missing_ids, { done: 0, window: 0, retries: 0 })

# Per-run drain state: `done` = reads this run (vs the daily cap), `window` = reads
# since the last window sleep (vs the 15-min cap), `retries` = consecutive 429s
# after a sleep (to detect the daily cap without headers).
DrainState : { done : I64, window : I64, retries : I64 }

# Walk the missing-streams list once per run. Walking a LIST (not re-querying
# "next missing") means an unstorable body is skipped, not refetched forever.
# The pacing DECISION is pure (Backfill.decide, unit-tested); this is the thin
# effectful skin that dispatches on it: fetch, then act.
drain_streams! : Str, Str, List I64, DrainState => Result {} _
drain_streams! = |path, token, ids, st|
    when ids is
        [] -> Stdout.line!("backfill complete — ${Num.to_str(st.done)} streams fetched this run; ${Num.to_str(pending_streams!(path)?)} still missing")
        [id, .. as rest] ->
            uri = "https://www.strava.com/api/v3/activities/${Num.to_str(id)}/streams?keys=time,heartrate,watts&key_by_type=true"
            resp = send_bearer!(uri, token)?
            when Backfill.decide({ status: resp.status, done: st.done, window: st.window, retries: st.retries }, read_limits) is
                Refresh ->
                    # multi-hour runs outlive the ~6h access token; refresh once and
                    # retry the same id. Same token back => real auth problem, stop.
                    fresh = get_valid_token!(path)?
                    if fresh == token then
                        Err(HttpStatus(401, "token refresh did not help — re-run `stride auth`"))
                    else
                        Stdout.line!("  access token expired — refreshed, continuing...")?
                        drain_streams!(path, fresh, ids, st)

                Backoff(retries) ->
                    Stdout.line!("  rate limited — pausing ~15 min, then resuming...")?
                    Sleep.millis!(window_sleep_ms)
                    drain_streams!(path, token, ids, { st & window: 0, retries })

                GiveUp ->
                    left = pending_streams!(path)?
                    Stdout.line!("still rate-limited after backing off — likely today's Strava read cap (${Num.to_str(st.done)} fetched this run, ${Num.to_str(left)} to go). Run `stride backfill` again later or tomorrow.")

                Store({ done, window, after }) ->
                    # 404 -> empty marker, 2xx -> body, other -> error propagated
                    store_stream_response!(path, id, resp)?
                    (if Num.rem(done, 50) == 0 then
                        Stdout.line!("  ...${Num.to_str(done)} fetched this run")
                    else
                        Ok({}))?
                    when after is
                        StopRun ->
                            left = pending_streams!(path)?
                            Stdout.line!("reached this run's safe read budget — ${Num.to_str(done)} fetched, ${Num.to_str(left)} still to go. Run `stride backfill` again tomorrow to continue.")

                        SleepWindow ->
                            Stdout.line!("  15-min read window nearly full (${Num.to_str(window)}) — sleeping ~15 min...")?
                            Sleep.millis!(window_sleep_ms)
                            drain_streams!(path, token, rest, { done, window: 0, retries: 0 })

                        Continue ->
                            drain_streams!(path, token, rest, { done, window, retries: 0 })

per_page = 100

fetch_pages! : Str, Str, Str, U64, U64 => Result U64 _
fetch_pages! = |path, token, after_param, page, acc|
    page_str = Num.to_str(page)
    per_str = Num.to_str(per_page)
    uri = "https://www.strava.com/api/v3/athlete/activities?per_page=${per_str}&page=${page_str}${after_param}"
    body = get_bearer!(uri, token)?
    decoded : Result (List ActivitySummary) _
    decoded = Decode.from_bytes(body, Json.utf8)
    acts = Result.map_err(decoded, |_| ActivityDecodeFailed(page))?
    upsert_all!(path, acts)?
    got = List.len(acts)
    total = acc + got
    if got < per_page then
        Ok(total)
    else
        fetch_pages!(path, token, after_param, page + 1, total)

upsert_all! : Str, List ActivitySummary => Result {} _
upsert_all! = |path, acts|
    when acts is
        [] -> Ok({})
        [a, .. as rest] ->
            upsert_activity!(path, a)?
            upsert_all!(path, rest)

upsert_activity! : Str, ActivitySummary => Result {} _
upsert_activity! = |path, a|
    Sqlite.execute!({
        path,
        query:
        """
        INSERT OR REPLACE INTO activities (id, name, sport_type, start_local, moving_time, distance, elevation, relative_effort, avg_watts, avg_hr, weighted_avg_watts)
        VALUES (:id, :name, :sport, :start, :mt, :dist, :elev, :re, :aw, :ahr, :waw)
        """,
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

# ── analyze ──────────────────────────────────────────────────────────

StreamSeq : { data : List (Option F64) }
StreamsResp : { time : Option StreamSeq, heartrate : Option StreamSeq, watts : Option StreamSeq }

zone_config_help =
    """
    analyze needs your FTP and HR zone upper bounds in config first:

        stride config set ftp 190
        stride config set hr_z1_max 123
        stride config set hr_z2_max 153
        stride config set hr_z3_max 168
        stride config set hr_z4_max 183

    (find yours at strava.com/settings/heartrate — z5 is everything above z4_max)
    """

analyze! : {} => Result {} _
analyze! = |{}|
    path = open_db!({})?
    when load_zone_config!(path) is
        Err(MissingConfig) -> missing_config!({})
        Err(other) -> Err(other)
        Ok({ ftp, zb }) ->
            res = compute_missing_metrics!(path, ftp, zb)?
            rebuild_daily_load!(path)?
            Stdout.line!("computed metrics for ${Num.to_str(res.computed)} activities")?
            (if res.stream_errors > 0 then
                Stdout.line!("⚠ ${Num.to_str(res.stream_errors)} had unreadable stream data — computed from summary fields, will retry next sync")
            else
                Ok({}))?
            # one verdict line; the full report lives in `stride summary`
            when Sqlite.query!({
                path,
                query: "SELECT tsb AS tsb FROM daily_load ORDER BY day DESC LIMIT 1",
                bindings: [],
                row: Sqlite.f64("tsb"),
            }) is
                Ok(tsb) -> Stdout.line!("→ today: form ${Render.fmt0(tsb)} — ${Metrics.form_label(tsb)}")
                # no daily_load yet (nothing computed) is fine — skip the verdict;
                # a real query error propagates instead of being swallowed
                Err(NoRowsReturned) -> Ok({})
                Err(other) -> Err(other)

load_zone_config! : Str => Result { ftp : F64, zb : Metrics.ZoneBounds } _
load_zone_config! = |path|
    ftp = config_f64!(path, "ftp")?
    z1 = config_f64!(path, "hr_z1_max")?
    z2 = config_f64!(path, "hr_z2_max")?
    z3 = config_f64!(path, "hr_z3_max")?
    z4 = config_f64!(path, "hr_z4_max")?
    Ok({ ftp, zb: { z1_max: z1, z2_max: z2, z3_max: z3, z4_max: z4 } })

config_f64! : Str, Str => Result F64 _
config_f64! = |path, key|
    when config_opt!(path, key)? is
        NotFound -> Err(MissingConfig)
        Found(s) ->
            when Str.to_f64(s) is
                Ok(v) -> Ok(v)
                Err(_) -> Err(MissingConfig)

ActivityRow : {
    id : I64,
    start : Str,
    mt : I64,
    re : [NotNull F64, Null],
    aw : [NotNull F64, Null],
    ahr : [NotNull F64, Null],
    waw : [NotNull F64, Null],
    raw : [NotNull Str, Null],
}

compute_missing_metrics! : Str, F64, Metrics.ZoneBounds => Result { computed : U64, stream_errors : U64 } _
compute_missing_metrics! = |path, ftp, zb|
    rows = Sqlite.query_many!({
        path,
        query:
        """
        SELECT a.id AS id, a.start_local AS start, a.moving_time AS mt,
               CAST(a.relative_effort AS REAL) AS re, CAST(a.avg_watts AS REAL) AS aw, CAST(a.avg_hr AS REAL) AS ahr,
               CAST(a.weighted_avg_watts AS REAL) AS waw, s.raw_json AS raw
        FROM activities a
        LEFT JOIN streams s ON s.activity_id = a.id
        LEFT JOIN activity_metrics m ON m.activity_id = a.id
        WHERE m.activity_id IS NULL OR COALESCE(m.ftp_used, 0) <> :ftp
              OR COALESCE(m.zones_used, '') <> :zones
        """,
        bindings: [
            { name: ":ftp", value: Real(ftp) },
            { name: ":zones", value: String(zones_sig(zb)) },
        ],
        rows: { Sqlite.decode_record <-
            id: Sqlite.i64("id"),
            start: Sqlite.str("start"),
            mt: Sqlite.i64("mt"),
            re: Sqlite.nullable_f64("re"),
            aw: Sqlite.nullable_f64("aw"),
            ahr: Sqlite.nullable_f64("ahr"),
            waw: Sqlite.nullable_f64("waw"),
            raw: Sqlite.nullable_str("raw"),
        },
    })?
    process_rows!(path, ftp, zb, rows, { computed: 0, stream_errors: 0 })

process_rows! : Str, F64, Metrics.ZoneBounds, List ActivityRow, { computed : U64, stream_errors : U64 } => Result { computed : U64, stream_errors : U64 } _
process_rows! = |path, ftp, zb, rows, acc|
    when rows is
        [] -> Ok(acc)
        [row, .. as rest] ->
            failed = compute_one!(path, ftp, zb, row)?
            next = {
                computed: acc.computed + 1,
                stream_errors: acc.stream_errors + (if failed then 1 else 0),
            }
            process_rows!(path, ftp, zb, rest, next)

# pair up stream time+value samples, dropping nulls
stream_pairs : Option StreamSeq, Option StreamSeq -> List { t : I64, v : F64 }
stream_pairs = |time_opt, val_opt|
    when (Option.get(time_opt), Option.get(val_opt)) is
        (Some(ts), Some(vs)) ->
            maybe_pairs = List.map2(
                ts.data,
                vs.data,
                |ot, ov|
                    when (Option.get(ot), Option.get(ov)) is
                        (Some(t), Some(v)) -> Ok({ t: Num.round(t), v })
                        _ -> Err({}),
            )
            List.keep_oks(maybe_pairs, |p| p)

        _ -> []

zero_zones : Metrics.ZoneSeconds
zero_zones = { z1: 0, z2: 0, z3: 0, z4: 0, z5: 0 }

# a stable signature of the HR zone bounds a metrics row was computed with, so a
# zone-config change invalidates + recomputes it (the same way ftp_used does for
# FTP). Bounds are whole bpm, so fmt0 is lossless and deterministic on both the
# write (compute_one!) and the compare (compute_missing_metrics! query).
zones_sig : Metrics.ZoneBounds -> Str
zones_sig = |zb|
    "${Render.fmt0(zb.z1_max)},${Render.fmt0(zb.z2_max)},${Render.fmt0(zb.z3_max)},${Render.fmt0(zb.z4_max)}"

empty_streams : StreamsResp
empty_streams = { time: Option.none({}), heartrate: Option.none({}), watts: Option.none({}) }

# decode stored stream JSON, distinguishing a genuine "no streams" (Null, or the
# {} 404-marker which decodes to all-None) from a real DECODE FAILURE (corrupt /
# schema-drifted JSON) so callers can surface it instead of silently zeroing.
decode_streams : [NotNull Str, Null] -> { streams : StreamsResp, failed : Bool }
decode_streams = |raw|
    when raw is
        NotNull(text) ->
            decoded : Result StreamsResp _
            decoded = Decode.from_bytes(Str.to_utf8(text), Json.utf8)
            when decoded is
                Ok(s) -> { streams: s, failed: Bool.false }
                Err(_) -> { streams: empty_streams, failed: Bool.true }

        Null -> { streams: empty_streams, failed: Bool.false }

# returns Bool: did the stored stream JSON fail to decode? (surfaced by analyze)
compute_one! : Str, F64, Metrics.ZoneBounds, ActivityRow => Result Bool _
compute_one! = |path, ftp, zb, row|
    decoded = decode_streams(row.raw)
    streams = decoded.streams

    # sanity-filter HR: some sources (Peloton strength workouts) emit junk
    # near-zero samples — Metrics.valid_hr is the one place the bounds live
    hr_pairs = List.keep_if(
        stream_pairs(streams.time, streams.heartrate),
        |p| Metrics.valid_hr(p.v),
    )
    watts_pairs = stream_pairs(streams.time, streams.watts)
    watts_1s = Metrics.resample_1s(List.map(watts_pairs, |p| { t: p.t, v: p.v }))

    zones = if List.is_empty(hr_pairs) then zero_zones else Metrics.time_in_zones(hr_pairs, zb)

    np_stream = Metrics.normalized_power(watts_1s)
    best20 = Metrics.best_rolling_mean(watts_1s, 1200)

    # the fallback chain lives in Metrics.tss_ladder (pure, expect-tested)
    nn = |x|
        when x is
            NotNull(v) -> Ok(v)
            Null -> Err(Missing)

    ladder = Metrics.tss_ladder({
        np_stream,
        weighted_watts: nn(row.waw),
        avg_watts: nn(row.aw),
        avg_hr: nn(row.ahr),
        relative_effort: nn(row.re),
        zones,
        zb,
        ftp,
        dur_s: Num.to_f64(row.mt),
        moving_time: row.mt,
    })
    tss = ladder.tss

    np_binding =
        when ladder.np is
            Ok(npv) -> Real(npv)
            Err(_) -> Null

    if_binding =
        when ladder.np is
            Ok(npv) -> (if ftp > 0 then Real(npv / ftp) else Null)
            Err(_) -> Null

    best20_binding =
        when best20 is
            Ok(b) -> Real(b)
            Err(_) -> Null

    Sqlite.execute!({
        path,
        query:
        """
        INSERT OR REPLACE INTO activity_metrics
          (activity_id, tss, normalized_power, intensity_factor, z1_s, z2_s, z3_s, z4_s, z5_s, computed_at, best_20min_w, ftp_used, zones_used)
        VALUES (:id, :tss, :np, :if, :z1, :z2, :z3, :z4, :z5, :at, :b20, :ftpu, :zused)
        """,
        bindings: [
            { name: ":ftpu", value: Real(ftp) },
            { name: ":zused", value: String(zones_sig(zb)) },
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

# ── daily load (CTL/ATL/TSB) ────────────────────────────────────────

rebuild_daily_load! : Str => Result {} _
rebuild_daily_load! = |path|
    day_rows = Sqlite.query_many!({
        path,
        query:
        """
        SELECT substr(a.start_local, 1, 10) AS day, SUM(m.tss) AS t
        FROM activity_metrics m
        JOIN activities a ON a.id = m.activity_id
        GROUP BY day ORDER BY day
        """,
        bindings: [],
        rows: { Sqlite.decode_record <-
            day: Sqlite.str("day"),
            t: Sqlite.f64("t"),
        },
    })?
    # keep only rows whose date parses. Deriving the walk bounds from these VALID
    # days (not blindly from the first/last row) avoids the trap where a single
    # malformed start_local defaulted to epoch-day 0 and walked from 1970.
    by_day = List.walk(
        day_rows,
        Dict.empty({}),
        |dict, r|
            when Metrics.date_str_to_days(r.day) is
                Ok(d) -> Dict.insert(dict, d, r.t)
                Err(_) -> dict,
    )
    valid_days = Dict.keys(by_day)
    when List.first(valid_days) is
        Err(_) -> Ok({}) # nothing computed yet (or no parseable dates)
        Ok(seed) ->
            bounds = List.walk(valid_days, { lo: seed, hi: seed }, |b, d| { lo: Num.min(b.lo, d), hi: Num.max(b.hi, d) })
            # extend through today so rest days decay ATL/CTL and TSB is true as-of-now
            today = local_today_days!(path)?
            last_day = Num.max(bounds.hi, today)
            Sqlite.execute!({ path, query: "DELETE FROM daily_load", bindings: [] })?
            walk_days!(path, by_day, bounds.lo, last_day, 0.0, 0.0)

walk_days! : Str, Dict I64 F64, I64, I64, F64, F64 => Result {} _
walk_days! = |path, by_day, day, last_day, ctl_prev, atl_prev|
    if day > last_day then
        Ok({})
    else
        tss = Result.with_default(Dict.get(by_day, day), 0.0)
        # the CTL/ATL/TSB recurrence lives in Metrics.load_step (pure, expect-tested)
        step = Metrics.load_step({ ctl_prev, atl_prev, tss })
        Sqlite.execute!({
            path,
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

# ── shared queries ──────────────────────────────────────────────────

# zone + TSS totals for activities on/after a cutoff date
zone_sum! : Str, Str => Result { z1 : I64, z2 : I64, z3 : I64, z4 : I64, z5 : I64, tss : F64 } _
zone_sum! = |path, cutoff|
    Sqlite.query!({
        path,
        query:
        """
        SELECT COALESCE(SUM(m.z1_s),0) AS z1, COALESCE(SUM(m.z2_s),0) AS z2, COALESCE(SUM(m.z3_s),0) AS z3,
               COALESCE(SUM(m.z4_s),0) AS z4, COALESCE(SUM(m.z5_s),0) AS z5, CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss
        FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
        WHERE a.start_local >= :cutoff
        """,
        bindings: [{ name: ":cutoff", value: String(cutoff) }],
        row: { Sqlite.decode_record <-
            z1: Sqlite.i64("z1"),
            z2: Sqlite.i64("z2"),
            z3: Sqlite.i64("z3"),
            z4: Sqlite.i64("z4"),
            z5: Sqlite.i64("z5"),
            tss: Sqlite.f64("tss"),
        },
    })

# ── machine interface (JSON output for LLM/tool consumption) ────────
# Convention: numeric fields COALESCE to 0 when unknown (0 = "not available").

print_json! : val => Result {} _ where val implements Encoding
print_json! = |val|
    bytes = Encode.to_bytes(val, Json.utf8)
    text = Result.with_default(Str.from_utf8(bytes), "{}")
    Stdout.line!(text)

# output mode: humans get tables by default; LLM callers set STRIDE_FORMAT=json
# (CLAUDECODE env also flips to json for harnesses that set it)
json_mode! : {} => Bool
json_mode! = |{}|
    when Env.var!("STRIDE_FORMAT") is
        Ok(v) -> Str.with_ascii_lowercased(Str.trim(v)) == "json"
        Err(_) ->
            when Env.var!("CLAUDECODE") is
                # set-but-empty is not "on" — require a non-empty value
                Ok(v) -> !(Str.is_empty(v))
                Err(_) -> Bool.false

# a known, user-fixable error: machine-readable JSON for tool callers, a plain
# line for humans. Exit stays 0 (in-band errors are the codebase convention —
# same as prescribe's dedup guard); the payload carries the failure.
err_out! : Str, Str => Result {} _
err_out! = |code, msg|
    if json_mode!({}) then
        print_json!({ error: code })
    else
        Stdout.line!(msg)

# unconfigured zones/FTP: JSON error for tools, the setup help for humans
missing_config! : {} => Result {} _
missing_config! = |{}|
    if json_mode!({}) then
        print_json!({ error: "missing_config" })
    else
        Stdout.line!(zone_config_help)

# does a row with this id exist? (table is an internal literal, never user input)
row_exists! : Str, Str, I64 => Result Bool _
row_exists! = |path, table, id|
    n = Sqlite.query!({
        path,
        query: "SELECT COUNT(*) AS n FROM ${table} WHERE id = :id",
        bindings: [{ name: ":id", value: Integer(id) }],
        row: Sqlite.i64("n"),
    })?
    Ok(n > 0)

pct_num : I64, I64 -> I64
pct_num = |part, total|
    if total == 0 then
        0
    else
        Num.round(Num.to_f64(part) * 100.0 / Num.to_f64(total))

# one session in depth: metrics + zones + power bests computed from local streams
activity! : Str => Result {} _
activity! = |id_str|
    path = open_db!({})?
    when Str.to_i64(id_str) is
        Err(_) -> err_out!("activity_not_found", "activity ${id_str} not found (run `stride activities` to list ids)")
        Ok(aid) -> activity_body!(path, id_str, aid)

activity_body! : Str, Str, I64 => Result {} _
activity_body! = |path, id_str, aid|
    rows = Sqlite.query_many!({
        path,
        query:
        """
        SELECT a.id AS id, substr(a.start_local, 1, 10) AS date, a.sport_type AS sport, a.name AS name,
               a.moving_time AS moving_time, CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
               CAST(COALESCE(m.tss,0) AS REAL) AS tss, CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
               CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
               CAST(COALESCE(m.ftp_used,0) AS REAL) AS ftp_used,
               COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
               COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s,
               CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr
        FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
        WHERE a.id = :id LIMIT 1
        """,
        bindings: [{ name: ":id", value: Integer(aid) }],
        rows: { Sqlite.decode_record <-
            id: Sqlite.i64("id"),
            date: Sqlite.str("date"),
            sport: Sqlite.str("sport"),
            name: Sqlite.str("name"),
            moving_time: Sqlite.i64("moving_time"),
            distance_m: Sqlite.f64("distance_m"),
            tss: Sqlite.f64("tss"),
            np_w: Sqlite.f64("np_w"),
            intensity: Sqlite.f64("intensity"),
            ftp_used: Sqlite.f64("ftp_used"),
            z1_s: Sqlite.i64("z1_s"),
            z2_s: Sqlite.i64("z2_s"),
            z3_s: Sqlite.i64("z3_s"),
            z4_s: Sqlite.i64("z4_s"),
            z5_s: Sqlite.i64("z5_s"),
            avg_hr: Sqlite.f64("avg_hr"),
        },
    })?
    when List.first(rows) is
        Err(_) ->
            if json_mode!({}) then
                print_json!({ error: "activity_not_found", id: aid })
            else
                Stdout.line!("activity ${id_str} not found (run `stride activities` to list ids)")

        Ok(a) ->
            raw_rows = Sqlite.query_many!({
                path,
                query: "SELECT raw_json AS raw FROM streams WHERE activity_id = :id",
                bindings: [{ name: ":id", value: Integer(aid) }],
                rows: Sqlite.str("raw"),
            })?
            raw_opt =
                when List.first(raw_rows) is
                    Ok(text) -> NotNull(text)
                    Err(_) -> Null
            decoded = decode_streams(raw_opt)
            streams = decoded.streams

            hr_pairs = List.keep_if(
                stream_pairs(streams.time, streams.heartrate),
                |p| Metrics.valid_hr(p.v),
            )
            watts_1s = Metrics.resample_1s(stream_pairs(streams.time, streams.watts))
            best = |w|
                when Metrics.best_rolling_mean(watts_1s, w) is
                    Ok(v) -> v
                    Err(_) -> 0.0
            max_hr = List.walk(hr_pairs, 0.0f64, |acc, p| Num.max(acc, p.v))
            hard_s = a.z4_s + a.z5_s

            if json_mode!({}) then
                print_json!({
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
                    zones: { z1_s: a.z1_s, z2_s: a.z2_s, z3_s: a.z3_s, z4_s: a.z4_s, z5_s: a.z5_s },
                    hard_s,
                    power_bests: { w60: best(60), w180: best(180), w300: best(300), w1200: best(1200) },
                    max_hr,
                    avg_hr: a.avg_hr,
                    # true = stored streams exist but wouldn't decode, so the 0s
                    # above are "unreadable", NOT "no power meter / no strap"
                    streams_unreadable: decoded.failed,
                })
            else
                dist_str = if a.distance_m >= 1000.0 then " · ${Render.fmt1(a.distance_m / 1000.0)} km" else ""
                Stdout.line!(a.name)?
                Stdout.line!("${a.date} · ${a.sport} · ${Render.mins(a.moving_time)}${dist_str}")?
                Stdout.line!("")?
                load_str = if a.tss >= 1.0 then "${Render.fmt0(a.tss)} TSS" else "no usable data"
                np_str = if a.np_w > 0 then " · np ${Render.fmt0(a.np_w)}W @ ftp ${Render.fmt0(a.ftp_used)} (if ${Render.fmt2(a.intensity)})" else ""
                Stdout.line!("load   ${load_str}${np_str}")?
                Stdout.line!("zones  Z1 ${Num.to_str(a.z1_s // 60)}m · Z2 ${Num.to_str(a.z2_s // 60)}m · Z3 ${Num.to_str(a.z3_s // 60)}m · Z4 ${Num.to_str(a.z4_s // 60)}m · Z5 ${Num.to_str(a.z5_s // 60)}m")?
                Stdout.line!("hard   ${Render.mins(hard_s)} in Z4+Z5")?
                if best(60) > 0 then
                    Stdout.line!("power  1min ${Render.fmt0(best(60))}W · 3min ${Render.fmt0(best(180))}W · 5min ${Render.fmt0(best(300))}W · 20min ${Render.fmt0(best(1200))}W")?
                else
                    Ok({})?
                (if max_hr > 0 then
                    Stdout.line!("hr     max ${Render.fmt0(max_hr)} · avg ${Render.fmt0(a.avg_hr)}")
                else
                    Ok({}))?
                if decoded.failed then
                    Stdout.line!("⚠ stored stream data for this activity is unreadable — zeros above are missing data, not real zeros")
                else
                    Ok({})

# career + year-to-date totals per sport
stats! : {} => Result {} _
stats! = |{}|
    path = open_db!({})?
    today_days = local_today_days!(path)?
    year = (Metrics.civil_from_days(today_days)).y
    all_time = stats_rows!(path, "0000-01-01")?
    ytd = stats_rows!(path, "${Num.to_str(year)}-01-01")?
    if json_mode!({}) then
        print_json!({ all_time, ytd, ytd_year: year })
    else
        to_table = |rows|
            Render.render_table(
                ["sport", "sessions", "time", "distance"],
                List.map(rows, |r| [
                    r.sport,
                    Num.to_str(r.sessions),
                    "${Render.fmt0(r.hours)}h",
                    (if r.km >= 1.0 then "${Render.fmt0(r.km)} km" else "-"),
                ]),
            )
        Stdout.line!("ALL TIME")?
        Stdout.line!(to_table(all_time))?
        Stdout.line!("")?
        Stdout.line!("${Num.to_str(year)} YEAR TO DATE")?
        Stdout.line!(to_table(ytd))

stats_rows! : Str, Str => Result (List { sport : Str, sessions : I64, hours : F64, km : F64 }) _
stats_rows! = |path, cutoff|
    Sqlite.query_many!({
        path,
        query:
        """
        SELECT sport_type AS sport, COUNT(*) AS sessions,
               CAST(SUM(moving_time) / 3600.0 AS REAL) AS hours,
               CAST(COALESCE(SUM(distance), 0) / 1000.0 AS REAL) AS km
        FROM activities WHERE start_local >= :cutoff
        GROUP BY sport_type ORDER BY sessions DESC
        """,
        bindings: [{ name: ":cutoff", value: String(cutoff) }],
        rows: { Sqlite.decode_record <-
            sport: Sqlite.str("sport"),
            sessions: Sqlite.i64("sessions"),
            hours: Sqlite.f64("hours"),
            km: Sqlite.f64("km"),
        },
    })

# the one-call coach-input payload
summary! : {} => Result {} _
summary! = |{}|
    path = open_db!({})?
    when load_zone_config!(path) is
        Err(MissingConfig) -> missing_config!({})
        Err(other) -> Err(other)
        Ok({ ftp, zb }) ->
            payload = summary_payload!(path, ftp, zb)?
            if json_mode!({}) then
                print_json!(payload)
            else
                human_summary!(payload)

# renders the human report straight from the payload — ONE source of numbers for
# the whole screen (previously report! re-ran the same queries, so the top of the
# screen could disagree with the bottom)
human_summary! = |s|
    z = s.last_28d
    Stdout.line!("")?
    Stdout.line!("── stride report (as of ${s.as_of}) ──────────────────")?
    Stdout.line!("")?
    Stdout.line!("  fitness (CTL): ${Render.fmt0(s.fitness_ctl)}   fatigue (ATL): ${Render.fmt0(s.fatigue_atl)}   form (TSB): ${Render.fmt0(s.form_tsb)}")?
    Stdout.line!("  → ${Metrics.form_label(s.form_tsb)}")?
    Stdout.line!("")?
    Stdout.line!("  last 28 days:")?
    Stdout.line!("    training load: ${Render.fmt0(z.tss)} TSS")?
    Stdout.line!("    time in HR zones: Z1 ${Num.to_str(z.z1_s // 60)}m  Z2 ${Num.to_str(z.z2_s // 60)}m  Z3 ${Num.to_str(z.z3_s // 60)}m  Z4 ${Num.to_str(z.z4_s // 60)}m  Z5 ${Num.to_str(z.z5_s // 60)}m")?
    Stdout.line!("    polarization: ${Num.to_str(z.easy_pct)}% easy (Z1-2) / ${Num.to_str(z.moderate_pct)}% moderate (Z3) / ${Num.to_str(z.hard_pct)}% hard (Z4-5)")?
    (if z.z5_s == 0 then
        Stdout.line!("    ⚠ zone gap: 0 minutes in Z5 — no VO2max stimulus in 28 days")
    else
        Ok({}))?
    (if s.ftp.best_20min_w_60d > 0 then
        ftp_calibration_lines!(s.ftp)
    else
        Ok({}))?
    Stdout.line!("")?
    Stdout.line!("  last 7 days: ${Render.fmt0(s.last_7d.tss)} TSS — ${Num.to_str(s.last_7d.easy_pct)}% easy / ${Num.to_str(s.last_7d.moderate_pct)}% moderate / ${Num.to_str(s.last_7d.hard_pct)}% hard")?
    last_hard_str = if s.last_hard_session_date == "" then "none on record" else s.last_hard_session_date
    Stdout.line!("  last hard session (5+ min Z4/Z5): ${last_hard_str}")?
    Stdout.line!("  open prescriptions: ${Num.to_str(s.pending_prescriptions)}")

ftp_calibration_lines! = |ftp|
    Stdout.line!("")?
    Stdout.line!("  FTP calibration (60d): best 20-min power ${Render.fmt0(ftp.best_20min_w_60d)}W -> estimated FTP ${Render.fmt0(ftp.estimated_ftp_w)}W (config: ${Render.fmt0(ftp.config_w)}W)")?
    if ftp.stale then
        Stdout.line!("    ⚠ config FTP looks stale — consider: stride config set ftp ${Render.fmt0(ftp.estimated_ftp_w)}")
    else if ftp.detraining then
        Stdout.line!("    note: recent best power is well below config FTP (detraining or no hard efforts recorded)")
    else
        Ok({})

# weekly-planning bundle: everything the coach needs to plan a week, in one call
week! : {} => Result {} _
week! = |{}|
    path = open_db!({})?
    when load_zone_config!(path) is
        Err(MissingConfig) -> missing_config!({})
        Err(other) -> Err(other)
        Ok({ ftp, zb }) ->
            s = summary_payload!(path, ftp, zb)?
            anchor = Result.with_default(Metrics.date_str_to_days(s.as_of), 0)
            cutoff14 = Metrics.days_to_date_str(anchor - 14)
            recent = Sqlite.query_many!({
                path,
                query:
                """
                SELECT a.id AS id, substr(a.start_local, 1, 10) AS date, a.sport_type AS sport, a.name AS name,
                       a.moving_time AS moving_time, CAST(COALESCE(m.tss,0) AS REAL) AS tss,
                       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                       COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
                       COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s
                FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                WHERE a.start_local >= :cutoff
                ORDER BY a.start_local DESC
                """,
                bindings: [{ name: ":cutoff", value: String(cutoff14) }],
                rows: { Sqlite.decode_record <-
                    id: Sqlite.i64("id"),
                    date: Sqlite.str("date"),
                    sport: Sqlite.str("sport"),
                    name: Sqlite.str("name"),
                    moving_time: Sqlite.i64("moving_time"),
                    tss: Sqlite.f64("tss"),
                    intensity: Sqlite.f64("intensity"),
                    z1_s: Sqlite.i64("z1_s"),
                    z2_s: Sqlite.i64("z2_s"),
                    z3_s: Sqlite.i64("z3_s"),
                    z4_s: Sqlite.i64("z4_s"),
                    z5_s: Sqlite.i64("z5_s"),
                },
            })?
            open_p = Sqlite.query_many!({
                path,
                query:
                """
                SELECT id AS id, COALESCE(target_date,'') AS target_date, COALESCE(session_type,'') AS session_type,
                       COALESCE(detail,'') AS detail, COALESCE(rationale,'') AS rationale
                FROM prescriptions WHERE COALESCE(status, 'open') = 'open'
                ORDER BY target_date
                """,
                bindings: [],
                rows: { Sqlite.decode_record <-
                    id: Sqlite.i64("id"),
                    target_date: Sqlite.str("target_date"),
                    session_type: Sqlite.str("session_type"),
                    detail: Sqlite.str("detail"),
                    rationale: Sqlite.str("rationale"),
                },
            })?
            if json_mode!({}) then
                print_json!({
                    summary: s,
                    recent_activities_14d: recent,
                    open_prescriptions: open_p,
                })
            else
                human_summary!(s)?
                Stdout.line!("")?
                Stdout.line!("OPEN PRESCRIPTIONS")?
                Stdout.line!(Render.render_table(
                    ["id", "date", "type", "detail"],
                    List.map(open_p, |p| [Num.to_str(p.id), p.target_date, p.session_type, p.detail]),
                ))?
                Stdout.line!("")?
                Stdout.line!("RECENT 14 DAYS")?
                Stdout.line!(Render.render_table(
                    ["date", "sport", "name", "time", "tss", "hard"],
                    List.map(recent, |a| [a.date, a.sport, a.name, Render.mins(a.moving_time), Render.fmt0(a.tss), Render.mins(a.z4_s + a.z5_s)]),
                ))

summary_payload! = |path, ftp, zb|
    latest = Sqlite.query!({
        path,
        query: "SELECT day AS day, ctl AS ctl, atl AS atl, tsb AS tsb FROM daily_load ORDER BY day DESC LIMIT 1",
        bindings: [],
        row: { Sqlite.decode_record <-
            day: Sqlite.str("day"),
            ctl: Sqlite.f64("ctl"),
            atl: Sqlite.f64("atl"),
            tsb: Sqlite.f64("tsb"),
        },
    })?
    anchor = Result.with_default(Metrics.date_str_to_days(latest.day), 0)
    cutoff28 = Metrics.days_to_date_str(anchor - 28)
    cutoff60 = Metrics.days_to_date_str(anchor - 60)

    zsum = zone_sum!(path, cutoff28)?

    best20_row = Sqlite.query!({
        path,
        query:
        """
        SELECT CAST(COALESCE(MAX(m.best_20min_w),0) AS REAL) AS b FROM activity_metrics m
        JOIN activities a ON a.id = m.activity_id
        WHERE a.start_local >= :cutoff
        """,
        bindings: [{ name: ":cutoff", value: String(cutoff60) }],
        row: Sqlite.f64("b"),
    })?

    sports = Sqlite.query_many!({
        path,
        query:
        """
        SELECT a.sport_type AS sport, COUNT(*) AS sessions, CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss
        FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
        WHERE a.start_local >= :cutoff
        GROUP BY a.sport_type ORDER BY tss DESC
        """,
        bindings: [{ name: ":cutoff", value: String(cutoff28) }],
        rows: { Sqlite.decode_record <-
            sport: Sqlite.str("sport"),
            sessions: Sqlite.i64("sessions"),
            tss: Sqlite.f64("tss"),
        },
    })?

    cutoff7 = Metrics.days_to_date_str(anchor - 7)
    zsum7 = zone_sum!(path, cutoff7)?

    pending = Sqlite.query!({
        path,
        query: "SELECT COUNT(*) AS n FROM prescriptions WHERE COALESCE(status, 'open') = 'open'",
        bindings: [],
        row: Sqlite.i64("n"),
    })?

    # most recent day with a real hard stimulus (5+ min in Z4/Z5); '' = never
    last_hard = Sqlite.query!({
        path,
        query:
        """
        SELECT COALESCE(MAX(substr(a.start_local, 1, 10)), '') AS d
        FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
        WHERE m.z4_s + m.z5_s >= 300
        """,
        bindings: [],
        row: Sqlite.str("d"),
    })?

    total = zsum.z1 + zsum.z2 + zsum.z3 + zsum.z4 + zsum.z5
    easy = zsum.z1 + zsum.z2
    hard = zsum.z4 + zsum.z5
    total7 = zsum7.z1 + zsum7.z2 + zsum7.z3 + zsum7.z4 + zsum7.z5
    easy7 = zsum7.z1 + zsum7.z2
    hard7 = zsum7.z4 + zsum7.z5
    cal = Metrics.ftp_calibration({ best_20min: best20_row, ftp })

    Ok({
        as_of: latest.day,
        fitness_ctl: latest.ctl,
        fatigue_atl: latest.atl,
        form_tsb: latest.tsb,
        last_hard_session_date: last_hard,
        pending_prescriptions: pending,
        last_7d: {
            tss: zsum7.tss,
            z1_s: zsum7.z1,
            z2_s: zsum7.z2,
            z3_s: zsum7.z3,
            z4_s: zsum7.z4,
            z5_s: zsum7.z5,
            easy_pct: pct_num(easy7, total7),
            moderate_pct: pct_num(zsum7.z3, total7),
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
            moderate_pct: pct_num(zsum.z3, total),
            hard_pct: pct_num(hard, total),
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

activities! : U64, Str => Result {} _
activities! = |limit, sport_filter|
    path = open_db!({})?
    where_clause =
        if Str.is_empty(sport_filter) then
            ""
        else
            "WHERE a.sport_type = :sport COLLATE NOCASE"
    filter_bindings =
        if Str.is_empty(sport_filter) then
            []
        else
            [{ name: ":sport", value: String(sport_filter) }]
    rows = Sqlite.query_many!({
        path,
        query:
        """
        SELECT a.id AS id, substr(a.start_local, 1, 10) AS date, a.sport_type AS sport, a.name AS name,
               a.moving_time AS moving_time, CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
               CAST(COALESCE(m.tss,0) AS REAL) AS tss, CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
               CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
               COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
               COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s,
               CAST(COALESCE(a.relative_effort,0) AS REAL) AS relative_effort,
               CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr
        FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
        ${where_clause}
        ORDER BY a.start_local DESC LIMIT ${Num.to_str(limit)}
        """,
        bindings: filter_bindings,
        rows: { Sqlite.decode_record <-
            id: Sqlite.i64("id"),
            date: Sqlite.str("date"),
            sport: Sqlite.str("sport"),
            name: Sqlite.str("name"),
            moving_time: Sqlite.i64("moving_time"),
            distance_m: Sqlite.f64("distance_m"),
            tss: Sqlite.f64("tss"),
            np_w: Sqlite.f64("np_w"),
            intensity: Sqlite.f64("intensity"),
            z1_s: Sqlite.i64("z1_s"),
            z2_s: Sqlite.i64("z2_s"),
            z3_s: Sqlite.i64("z3_s"),
            z4_s: Sqlite.i64("z4_s"),
            z5_s: Sqlite.i64("z5_s"),
            relative_effort: Sqlite.f64("relative_effort"),
            avg_hr: Sqlite.f64("avg_hr"),
        },
    })?
    if json_mode!({}) then
        print_json!(rows)
    else
        Stdout.line!(Render.render_table(
            ["date", "sport", "name", "time", "load (tss)", "intensity (if)", "hard"],
            List.map(rows, |a| [
                a.date,
                a.sport,
                a.name,
                Render.mins(a.moving_time),
                (if a.tss >= 1.0 then Render.fmt0(a.tss) else "-"),
                (if a.intensity > 0 then Render.fmt2(a.intensity) else "-"),
                Render.mins(a.z4_s + a.z5_s),
            ]),
        ))?
        Stdout.line!("")?
        Stdout.line!("load (tss):     session stress — '-' means no usable data (e.g. dead HR strap)")?
        Stdout.line!("intensity (if): vs your FTP — ~0.7 easy · 0.85-0.95 tempo · ~1.0 threshold · 1.05+ vo2max")?
        Stdout.line!("hard:           minutes in HR Z4+Z5 — the column that shows if hard days were actually hard")

# metric keyword -> its ORDER BY column. The column is HARDCODED per keyword, so
# no user input ever reaches the SQL; an unknown metric errors before any query.
top_column : Str -> Result Str [BadMetric]
top_column = |m|
    when m is
        "hr" -> Ok("a.avg_hr")
        "tss" -> Ok("m.tss")
        "power" -> Ok("m.normalized_power")
        "intensity" -> Ok("m.intensity_factor")
        "distance" -> Ok("a.distance")
        "time" -> Ok("a.moving_time")
        "output" -> Ok("(a.avg_watts * a.moving_time)") # total work (Peloton kJ)
        _ -> Err(BadMetric)

# ranked "best sessions": top N activities by a chosen metric (vs `activities`,
# which is chronological). e.g. `top hr`, `top tss 5 rowing`.
top! : Str, U64, Str => Result {} _
top! = |metric, limit, sport_filter|
    path = open_db!({})?
    when top_column(metric) is
        Err(_) ->
            err_out!("bad_metric", "unknown metric '${metric}' — use: hr, tss, power, intensity, distance, time, output")

        Ok(col) ->
            sport_where =
                if Str.is_empty(sport_filter) then "" else " AND a.sport_type = :sport COLLATE NOCASE"
            sport_binding =
                if Str.is_empty(sport_filter) then [] else [{ name: ":sport", value: String(sport_filter) }]
            rows = Sqlite.query_many!({
                path,
                query:
                """
                SELECT a.id AS id, substr(a.start_local, 1, 10) AS date, a.sport_type AS sport, a.name AS name,
                       a.moving_time AS moving_time, CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
                       CAST(COALESCE(m.tss,0) AS REAL) AS tss, CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
                       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
                       CAST(COALESCE(a.avg_watts * a.moving_time / 1000.0, 0) AS REAL) AS output_kj
                FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                WHERE ${col} > 0${sport_where}
                ORDER BY ${col} DESC LIMIT ${Num.to_str(limit)}
                """,
                bindings: sport_binding,
                rows: { Sqlite.decode_record <-
                    id: Sqlite.i64("id"),
                    date: Sqlite.str("date"),
                    sport: Sqlite.str("sport"),
                    name: Sqlite.str("name"),
                    moving_time: Sqlite.i64("moving_time"),
                    distance_m: Sqlite.f64("distance_m"),
                    tss: Sqlite.f64("tss"),
                    np_w: Sqlite.f64("np_w"),
                    intensity: Sqlite.f64("intensity"),
                    avg_hr: Sqlite.f64("avg_hr"),
                    output_kj: Sqlite.f64("output_kj"),
                },
            })?
            if json_mode!({}) then
                print_json!(rows)
            else
                val = |r|
                    when metric is
                        "hr" -> "${Render.fmt0(r.avg_hr)} bpm"
                        "tss" -> Render.fmt0(r.tss)
                        "power" -> "${Render.fmt0(r.np_w)}W"
                        "intensity" -> Render.fmt2(r.intensity)
                        "distance" -> "${Render.fmt1(r.distance_m / 1000.0)} km"
                        "output" -> "${Render.fmt0(r.output_kj)} kJ"
                        _ -> Render.mins(r.moving_time)
                Stdout.line!(Render.render_table(
                    ["date", "sport", metric, "name"],
                    List.map(rows, |r| [r.date, r.sport, val(r), r.name]),
                ))

# power-zone reference chart: the 7 Coggan/Peloton zones as watt ranges from your
# configured FTP (the targets you'd set on a Power Zone ride).
pz! : {} => Result {} _
pz! = |{}|
    path = open_db!({})?
    when config_f64!(path, "ftp") is
        Err(MissingConfig) -> err_out!("missing_config", "set your FTP first: stride config set ftp <watts>")
        Err(other) -> Err(other)
        Ok(ftp) ->
            zones = Metrics.power_zones(ftp)
            if json_mode!({}) then
                print_json!({ ftp, zones })
            else
                range = |z|
                    if z.lo_w <= 0.0 then
                        "< ${Render.fmt0(z.hi_w)}"
                    else if z.hi_w <= 0.0 then
                        "${Render.fmt0(z.lo_w)}+"
                    else
                        "${Render.fmt0(z.lo_w)}-${Render.fmt0(z.hi_w)}"
                Stdout.line!(Render.render_table(
                    ["zone", "name", "watts (ftp ${Render.fmt0(ftp)})"],
                    List.map(zones, |z| [z.z, z.name, range(z)]),
                ))

ProgressRow : { name : Str, date : Str, distance_m : F64, np_w : F64, avg_hr : F64, ef : F64, output_kj : F64, tss : F64 }

# "am I improving on THIS workout?" — anchored on a date: resolves that day's workout(s)
# and shows every comparable instance chronologically, with Efficiency Factor (NP/HR) as
# the fitness tell. Named classes match by exact name; Strava auto-names ("Morning Ride")
# cover different routes, so those only compare rides within ±10% of the anchor's distance.
progress! : Str => Result {} _
progress! = |date|
    path = open_db!({})?
    rows = Sqlite.query_many!({
        path,
        query:
        """
        SELECT a.name AS name, substr(a.start_local, 1, 10) AS date,
               CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
               CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
               CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
               CAST(COALESCE(a.avg_watts * a.moving_time / 1000.0, 0) AS REAL) AS output_kj,
               CAST(COALESCE(m.tss,0) AS REAL) AS tss
        FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
        WHERE a.name IN (SELECT name FROM activities WHERE substr(start_local, 1, 10) = :date)
          AND a.avg_hr > 0 AND m.normalized_power > 0
        ORDER BY a.name, a.start_local
        """,
        bindings: [{ name: ":date", value: String(date) }],
        rows: { Sqlite.decode_record <-
            name: Sqlite.str("name"),
            date: Sqlite.str("date"),
            distance_m: Sqlite.f64("distance_m"),
            np_w: Sqlite.f64("np_w"),
            avg_hr: Sqlite.f64("avg_hr"),
            output_kj: Sqlite.f64("output_kj"),
            tss: Sqlite.f64("tss"),
        },
    })?
    with_ef : List ProgressRow
    with_ef = List.map(rows, |r| {
        name: r.name,
        date: r.date,
        distance_m: r.distance_m,
        np_w: r.np_w,
        avg_hr: r.avg_hr,
        ef: r.np_w / r.avg_hr,
        output_kj: r.output_kj,
        tss: r.tss,
    })
    groups = List.keep_oks(group_progress(with_ef), |g| anchor_filter(g, date))
    flat = List.join(List.map(groups, |g| g.rows))
    if json_mode!({}) then
        print_json!(flat)
    else if List.is_empty(groups) then
        Stdout.line!("no workout with power + HR found on ${date}")
    else
        body = Str.join_with(List.map(groups, |g| progress_section(g.name, g.rows)), "\n\n")
        Stdout.line!("${body}\n\nef = normalized power / avg HR (watts per heartbeat) — climbing = fitter")

# split rows (already sorted by name) into per-workout runs
group_progress : List ProgressRow -> List { name : Str, rows : List ProgressRow }
group_progress = |rows|
    List.walk(rows, [], |acc, r|
        when List.last(acc) is
            Ok(g) if g.name == r.name ->
                List.set(acc, List.len(acc) - 1, { name: g.name, rows: List.append(g.rows, r) })

            _ -> List.append(acc, { name: r.name, rows: [r] }))

# auto-named rides ("Morning Ride") are different routes under one name: keep only rows
# within ±10% of the anchor ride's distance (the instance on the requested date).
# Groups whose anchor isn't on the date, or auto-named anchors with no distance, drop.
anchor_filter : { name : Str, rows : List ProgressRow }, Str -> Result { name : Str, rows : List ProgressRow } [NoAnchor]
anchor_filter = |g, date|
    when List.find_first(g.rows, |r| r.date == date) is
        Err(_) -> Err(NoAnchor)
        Ok(anchor) ->
            if !(Metrics.is_auto_name(g.name)) then
                Ok(g)
            else if anchor.distance_m <= 0.0 then
                Err(NoAnchor)
            else
                kept = List.keep_if(g.rows, |r| Num.abs(r.distance_m - anchor.distance_m) <= anchor.distance_m * 0.10)
                Ok({ name: "${g.name} (~${Render.fmt1(anchor.distance_m / 1000.0)} km rides)", rows: kept })

# one workout's table + EF trend verdict as a string
progress_section : Str, List ProgressRow -> Str
progress_section = |name, rows|
    table = Render.render_table(
        ["date", "np", "hr", "ef", "kj", "tss"],
        List.map(rows, |r| [
            r.date,
            Render.fmt0(r.np_w),
            Render.fmt0(r.avg_hr),
            Render.fmt2(r.ef),
            Render.fmt0(r.output_kj),
            Render.fmt0(r.tss),
        ]),
    )
    t = Metrics.trend_ends(List.map(rows, |r| r.ef))
    pct = if t.early > 0.0 then (t.late - t.early) / t.early * 100.0 else 0.0
    label =
        if pct > 5.0 then "improving" else if pct < -5.0 then "declining" else "holding steady"
    verdict = "→ EF ${Render.fmt2(t.early)} → ${Render.fmt2(t.late)} over ${Num.to_str(List.len(rows))} sessions — ${label} (${Render.fmt0(pct)}%)"
    "── ${name} ──\n${table}\n\n${verdict}"

load_series! : U64 => Result {} _
load_series! = |days|
    path = open_db!({})?
    rows = Sqlite.query_many!({
        path,
        query: "SELECT day AS day, tss AS tss, ctl AS ctl, atl AS atl, tsb AS tsb FROM daily_load ORDER BY day DESC LIMIT ${Num.to_str(days)}",
        bindings: [],
        rows: { Sqlite.decode_record <-
            day: Sqlite.str("day"),
            tss: Sqlite.f64("tss"),
            ctl: Sqlite.f64("ctl"),
            atl: Sqlite.f64("atl"),
            tsb: Sqlite.f64("tsb"),
        },
    })?
    ordered = List.reverse(rows)
    if json_mode!({}) then
        print_json!(ordered)
    else
        verdict =
            when List.last(ordered) is
                Ok(today) -> "→ today: form ${Render.fmt0(today.tsb)} — ${Metrics.form_label(today.tsb)}"
                Err(_) -> ""
        if List.len(ordered) > 14 then
            # long windows: weekly rollup (Mon-aligned) — trajectory, not noise
            day_loads = List.map(ordered, |d| {
                days: Result.with_default(Metrics.date_str_to_days(d.day), 0),
                tss: d.tss,
                ctl: d.ctl,
                atl: d.atl,
                tsb: d.tsb,
            })
            weeks = Metrics.weekly_rollup(day_loads)
            Stdout.line!(Render.render_table(
                ["week of", "sessions", "load (tss)", "fitness end (ctl)", "form end (tsb)"],
                List.map(weeks, |w| [
                    Metrics.days_to_date_str(w.week_start),
                    Num.to_str(w.sessions),
                    Render.fmt0(w.tss),
                    Render.fmt0(w.ctl_end),
                    Render.fmt0(w.tsb_end),
                ]),
            ))?
            Stdout.line!("")?
            Stdout.line!(verdict)?
            Stdout.line!("")?
            Stdout.line!("one row per Mon-Sun week — is fitness (ctl) climbing? is weekly load steady or ramping?")?
            Stdout.line!("(use `stride load 14` or fewer days for the daily view)")
        else
            Stdout.line!(Render.render_table(
                ["day", "trained (tss)", "fitness (ctl)", "fatigue (atl)", "form (tsb)"],
                List.map(ordered, |d| [
                    d.day,
                    (if d.tss >= 1.0 then "${Render.fmt0(d.tss)} TSS" else "rest"),
                    Render.fmt0(d.ctl),
                    Render.fmt0(d.atl),
                    Render.fmt0(d.tsb),
                ]),
            ))?
            Stdout.line!("")?
            Stdout.line!(verdict)?
            Stdout.line!("")?
            Stdout.line!("trained (tss):  training stress score — how much load the day added")?
            Stdout.line!("fitness (ctl):  long-term base, 42d avg — want it climbing slowly")?
            Stdout.line!("fatigue (atl):  short-term tiredness, 7d avg — spikes after big days, fades with rest")?
            Stdout.line!("form (tsb):     fitness - fatigue (same day) — negative = fatigued,")?
            Stdout.line!("                positive = fresh; a hard session drops it the same day")

prescriptions! : {} => Result {} _
prescriptions! = |{}|
    path = open_db!({})?
    rows = Sqlite.query_many!({
        path,
        query:
        """
        SELECT id AS id, COALESCE(created_at,'') AS created_at, COALESCE(target_date,'') AS target_date,
               COALESCE(session_type,'') AS session_type, COALESCE(detail,'') AS detail,
               COALESCE(rationale,'') AS rationale, COALESCE(completed_activity_id,0) AS completed_activity_id,
               COALESCE(status,'open') AS status, COALESCE(skipped_reason,'') AS skipped_reason
        FROM prescriptions ORDER BY target_date DESC, id DESC LIMIT 100
        """,
        bindings: [],
        rows: { Sqlite.decode_record <-
            id: Sqlite.i64("id"),
            created_at: Sqlite.str("created_at"),
            target_date: Sqlite.str("target_date"),
            session_type: Sqlite.str("session_type"),
            detail: Sqlite.str("detail"),
            rationale: Sqlite.str("rationale"),
            completed_activity_id: Sqlite.i64("completed_activity_id"),
            status: Sqlite.str("status"),
            skipped_reason: Sqlite.str("skipped_reason"),
        },
    })?
    # most recent 100 by date, displayed in calendar order
    ordered = List.reverse(rows)
    dow = |date_str|
        when Metrics.date_str_to_days(date_str) is
            Ok(d) -> Metrics.day_of_week(d)
            Err(_) -> ""
    if json_mode!({}) then
        # build a new record with the day added (Roc's `&` can only update
        # existing fields, not add one — so construct it explicitly)
        print_json!(List.map(ordered, |p| {
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
        }))
    else
        Stdout.line!(Render.render_table(
            ["day", "date", "type", "status", "detail", "id"],
            List.map(ordered, |p| [dow(p.target_date), p.target_date, p.session_type, p.status, p.detail, Num.to_str(p.id)]),
        ))

prescribe! : Str, Str, Str, Str => Result {} _
prescribe! = |target_date, session_type, detail, rationale|
    path = open_db!({})?
    # guard: one open prescription per date — skip or complete the old one first
    existing = Sqlite.query!({
        path,
        query: "SELECT COALESCE(MAX(id), 0) AS id FROM prescriptions WHERE target_date = :date AND COALESCE(status, 'open') = 'open'",
        bindings: [{ name: ":date", value: String(target_date) }],
        row: Sqlite.i64("id"),
    })?
    if existing > 0 then
        if json_mode!({}) then
            print_json!({ error: "date_already_prescribed", existing_id: existing, target_date })
        else
            Stdout.line!("${target_date} already has open prescription #${Num.to_str(existing)} — `stride skip ${Num.to_str(existing)} \"reason\"` first")
    else
        insert_prescription!(path, target_date, session_type, detail, rationale)

insert_prescription! : Str, Str, Str, Str, Str => Result {} _
insert_prescription! = |path, target_date, session_type, detail, rationale|
    Sqlite.execute!({
        path,
        query:
        """
        INSERT INTO prescriptions (created_at, target_date, session_type, detail, rationale, status)
        VALUES (:at, :date, :type, :detail, :rationale, 'open')
        """,
        bindings: [
            { name: ":at", value: String(Metrics.epoch_to_iso(now_secs!({}))) },
            { name: ":date", value: String(target_date) },
            { name: ":type", value: String(session_type) },
            { name: ":detail", value: String(detail) },
            { name: ":rationale", value: String(rationale) },
        ],
    })?
    new_id = Sqlite.query!({
        path,
        query: "SELECT MAX(id) AS id FROM prescriptions",
        bindings: [],
        row: Sqlite.i64("id"),
    })?
    if json_mode!({}) then
        print_json!({ id: new_id, target_date, session_type })
    else
        Stdout.line!("prescribed #${Num.to_str(new_id)}: ${session_type} on ${target_date}")

complete! : Str, Str => Result {} _
complete! = |presc_id_str, activity_id_str|
    path = open_db!({})?
    when (Str.to_i64(presc_id_str), Str.to_i64(activity_id_str)) is
        (Ok(presc_id), Ok(activity_id)) ->
            # SQLite UPDATE matching 0 rows is not an error — check existence
            # ourselves so a typo'd id can't report false success and silently
            # leave the prescription open / the coaching log out of sync
            if !(row_exists!(path, "prescriptions", presc_id)?) then
                err_out!("prescription_not_found", "no prescription #${Num.to_str(presc_id)} — run `stride prescriptions` to see ids")
            else if !(row_exists!(path, "activities", activity_id)?) then
                err_out!("activity_not_found", "no activity ${Num.to_str(activity_id)} in the db — `stride sync` first?")
            else
                Sqlite.execute!({
                    path,
                    query: "UPDATE prescriptions SET completed_activity_id = :aid, status = 'done' WHERE id = :pid",
                    bindings: [
                        { name: ":aid", value: Integer(activity_id) },
                        { name: ":pid", value: Integer(presc_id) },
                    ],
                })?
                if json_mode!({}) then
                    print_json!({ completed_prescription: presc_id, activity: activity_id })
                else
                    Stdout.line!("prescription #${Num.to_str(presc_id)} completed by activity ${Num.to_str(activity_id)}")

        _ ->
            err_out!("bad_id", "complete needs numeric ids: complete <prescription_id> <activity_id>")

skip! : Str, Str => Result {} _
skip! = |presc_id_str, reason|
    path = open_db!({})?
    when Str.to_i64(presc_id_str) is
        Ok(presc_id) ->
            if !(row_exists!(path, "prescriptions", presc_id)?) then
                err_out!("prescription_not_found", "no prescription #${Num.to_str(presc_id)} — run `stride prescriptions` to see ids")
            else
                Sqlite.execute!({
                    path,
                    query: "UPDATE prescriptions SET status = 'skipped', skipped_reason = :why WHERE id = :pid",
                    bindings: [
                        { name: ":why", value: String(reason) },
                        { name: ":pid", value: Integer(presc_id) },
                    ],
                })?
                if json_mode!({}) then
                    print_json!({ skipped_prescription: presc_id, reason })
                else
                    Stdout.line!("prescription #${Num.to_str(presc_id)} skipped: ${reason}")

        Err(_) ->
            err_out!("bad_id", "skip needs a numeric id: skip <prescription_id> \"<reason>\"")

# ── migrations ───────────────────────────────────────────────────────

# bump when the schema changes; ensure_schema! re-runs migrations when the db's
# PRAGMA user_version is behind this. (The additive ALTERs below are the columns
# that post-date the original CREATE statements in Schema.roc.)
schema_version = 3

run_migrations! : Str => Result {} _
run_migrations! = |path|
    Sqlite.execute!({ path, query: Schema.activities, bindings: [] })?
    Sqlite.execute!({ path, query: Schema.metrics, bindings: [] })?
    Sqlite.execute!({ path, query: Schema.daily_load, bindings: [] })?
    Sqlite.execute!({ path, query: Schema.prescriptions, bindings: [] })?
    Sqlite.execute!({ path, query: Schema.config, bindings: [] })?
    Sqlite.execute!({ path, query: Schema.streams, bindings: [] })?
    alter_add_column!(path, "ALTER TABLE activities ADD COLUMN weighted_avg_watts REAL")?
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_20min_w REAL")?
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN ftp_used REAL")?
    alter_add_column!(path, "ALTER TABLE prescriptions ADD COLUMN status TEXT")?
    alter_add_column!(path, "ALTER TABLE prescriptions ADD COLUMN skipped_reason TEXT")?
    # v3: metrics record the HR zone bounds they were computed with, so a zone-
    # config change invalidates + recomputes (like ftp_used does for FTP)
    alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN zones_used TEXT")?
    # v2: index the column every date-range filter and the activities sort use
    # (queries now compare a.start_local directly — sargable — instead of substr)
    Sqlite.execute!({ path, query: "CREATE INDEX IF NOT EXISTS idx_activities_start ON activities(start_local)", bindings: [] })

# an additive ADD COLUMN. Swallows ONLY "duplicate column" (the expected re-run
# case); a locked db, disk error, etc. propagate instead of failing silently.
alter_add_column! : Str, Str => Result {} _
alter_add_column! = |path, q|
    when Sqlite.execute!({ path, query: q, bindings: [] }) is
        Ok({}) -> Ok({})
        Err(SqliteErr(Error, msg)) ->
            if Str.contains(msg, "duplicate column") then Ok({}) else Err(SqliteErr(Error, msg))

        Err(other) -> Err(other)

# run migrations exactly when the db is behind, then stamp the version. Called
# on every command entry (via open_db!) so upgrading the binary against an
# existing db self-migrates instead of failing with an opaque missing-column error.
ensure_schema! : Str => Result {} _
ensure_schema! = |path|
    v = Result.with_default(
        Sqlite.query!({
            path,
            query: "SELECT user_version AS v FROM pragma_user_version()",
            bindings: [],
            row: Sqlite.i64("v"),
        }),
        0,
    )
    if v >= schema_version then
        Ok({})
    else
        run_migrations!(path)?
        Sqlite.execute!({ path, query: "PRAGMA user_version = ${Num.to_str(schema_version)}", bindings: [] })

# db path + guaranteed-current schema. Every command opens through this.
open_db! : {} => Result Str _
open_db! = |{}|
    p = db_path!({})?
    ensure_schema!(p)?
    Ok(p)

# (schema DDL lives in Schema.roc — pure strings, the one kind of SQL that
#  can move out of the app module without splitting a query from its decoder)
