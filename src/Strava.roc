import Db
import Output
import pf.Http
import pf.Sleep
import pf.Sqlite
import pf.Stdout
import pf.Stdin
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import http.Request
import http.Method
import http.Response
import Streams
import Backfill
import Metrics

Strava :: [].{
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
                        resp = Http.send!(
                            Request.from_method(Method.PUT)
                            .with_uri("${api_base!({})}/api/v3/athlete?ftp=${ftp_str}")
                            .add_header("Authorization", "Bearer ${token}")
                            .with_body([])
                            .with_timeout(TimeoutMilliseconds(30000)),
                        )
                        match resp {
                            Ok(r) if Response.status(r) < 300 => Stdout.line!("  → synced to Strava (athlete FTP = ${ftp_str})")
                            Ok(r) => Stdout.line!("  (Strava FTP sync failed: HTTP ${(Response.status(r)).to_str()} — re-run `stride auth` to grant profile:write, or set it at strava.com/settings)")
                            Err(_) => Stdout.line!("  (couldn't reach Strava to sync FTP — set it at strava.com/settings)")

                        }
                    }
                }
        }

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
    open_browser! : Str => {}
    open_browser! = |url|
        match Cmd.new(OsStr.from_str("open")).arg(OsStr.from_str(url)).exec_output!() {
            Ok(_) => {}
            Err(_) =>
                # detach xdg-open: exec waits for the child, and xdg-open can resolve to
                # a FOREGROUND handler (console browser) that would block auth forever
                match Cmd.new(OsStr.from_str("sh")).args(List.map(["-c", "xdg-open \"$1\" >/dev/null 2>&1 &", "sh", url], OsStr.from_str)).exec_output!() {
                    Ok(_) => {}
                    Err(_) => {}
                }
        }
    # a stored token field: absent => NotAuthed (genuine); db failure propagates
    token_field! : Str, Str => Try(Str, _)
    token_field! = |path, key|
        match Db.config_opt!(path, key)? {
            Found(v) => Ok(v)
            NotFound => Err(NotAuthed)

        }
    # client credentials: env var wins, else stored config (written by `auth`)
    client_cred! : Str, Str, Str => Try(Str, _)
    client_cred! = |path, env_name, key|
        match Env.var_str!(OsStr.from_str(env_name)) {
            Ok(v) => Ok(v)
            Err(_) =>
                # Db.config_opt! so a locked/corrupt db surfaces as a real error, not MissingEnv
                match Db.config_opt!(path, key)? {
                    Found(v) => Ok(v)
                    NotFound => Err(MissingEnv(env_name))

                }
        }
    auth! : {} => Try({}, _)
    auth! = |{}| {
        path = Db.open_db!({})?
        # env vars for first-time setup; re-auth falls back to the creds stored last time.
        # Genuinely-missing creds get setup guidance, not a raw MissingEnv crash.
        match (client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id"), client_cred!(path, "STRAVA_CLIENT_SECRET", "strava_client_secret")) {
            (Ok(client_id), Ok(client_secret)) => auth_flow!(path, client_id, client_secret)
            (Err(MissingEnv(name)), _) | (_, Err(MissingEnv(name))) =>
                Output.err_out!("missing_client_creds", "${name} not set and no stored credentials yet — create a (free) Strava API app at strava.com/settings/api, then run:\n  STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth")

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
        open_browser!(url)
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
        Db.config_set!(path, "strava_client_id", client_id)?
        Db.config_set!(path, "strava_client_secret", client_secret)?
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
        Db.config_set!(path, "strava_access_token", tokens.access_token)?
        Db.config_set!(path, "strava_refresh_token", tokens.refresh_token)?
        Db.config_set!(path, "strava_expires_at", I64.to_str(tokens.expires_at))
    }
    # returns a valid access token, refreshing if expired; NotAuthed if never
    # authorized (a genuinely absent token — NOT a db read failure, which propagates)
    get_valid_token! : Str => Try(Str, _)
    get_valid_token! = |path| {
        access = token_field!(path, "strava_access_token")?
        refresh = token_field!(path, "strava_refresh_token")?
        expires_str = token_field!(path, "strava_expires_at")?
        expires_at = (I64.from_str(expires_str)).map_err(|_| CorruptToken)?
        now = Db.now_secs!({})
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
        resp = Http.send!(
            Request.from_method(Method.POST)
            .with_uri(uri)
            .add_header("Content-Type", "application/x-www-form-urlencoded")
            .with_body(form.to_utf8())
            .with_timeout(TimeoutMilliseconds(30000)),
        )?
        ok_body(resp)
    }
    get_bearer! : Str, Str => Try(List(U8), _)
    get_bearer! = |uri, token|
        ok_body(send_bearer!(uri, token)?)

    ok_body : Response -> Try(List(U8), _)
    ok_body = |resp|
        if Response.status(resp) < 300
            Ok(Response.body(resp))
        else {
            text = (Str.from_utf8(Response.body(resp))).ok_or("<non-utf8 body>")
            Err(HttpStatus(Response.status(resp), text))
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

    opt_real : Try(F64, [Missing]) -> [Real(F64), Null, ..]
    opt_real = |o|
        match o {
            Ok(v) => Real(v)
            Err(_) => Null

        }
    sync! : {} => Try({}, _)
    sync! = |{}| {
        path = Db.open_db!({})?
        match get_valid_token!(path) {
            Err(NotAuthed) =>
                Output.err_out!("not_authenticated", "not authenticated — run `stride auth` first")

            Err(other) => Err(other)
            Ok(token) => {
                started = Db.now_secs!({})
                # incremental with a rolling 30-day overlap so recent edits on
                # Strava self-heal (`backfill` is the full re-pull when needed)
                after_param =
                    # NotFound (never synced) = full pull is correct; a real db read
                    # error propagates instead of silently burning the rate budget
                    match Db.config_opt!(path, "last_sync_epoch")? {
                        NotFound => ""
                        Found(epoch_str) =>
                            match I64.from_str(epoch_str) {
                                Ok(e) => "&after=${I64.to_str((e - 2592000).max(0))}"
                                Err(_) => ""
                            }
                    }
                count = fetch_pages!(path, token, after_param, 1, 0)?
                Db.config_set!(path, "last_sync_epoch", I64.to_str(started))?
                streams_n = backfill_streams!(path, token)?
                remaining = pending_streams!(path)?
                Output.out!({ synced: count, streams_fetched: streams_n, pending_streams: remaining }, |p| {
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
                if Response.status(resp) == 429 {
                    # rate limited — stop gracefully, next sync continues the backfill
                    Stdout.line!("rate limited by Strava — stopping streams backfill for now (will resume next sync)")?
                    Ok(acc)
                } else if Response.status(resp) >= 300 and Response.status(resp) != 404 {
                    Err(HttpStatus(Response.status(resp), Str.from_utf8(Response.body(resp)).ok_or("<non-utf8 body>")))
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
        Http.send!(
            Request.from_method(Method.GET)
            .with_uri(uri)
            .add_header("Authorization", "Bearer ${token}")
            .with_body([])
            .with_timeout(TimeoutMilliseconds(60000)),
        )

    # store a streams response like the sync path: 404 => honest empty marker,
    # 2xx => body (skip if non-utf8 so it retries), other => propagate the error
    # THE stream-response policy, shared by sync and backfill: 404 => "{}" marker
    # (no streams recorded; don't refetch), 2xx => store, non-utf8 => skip WITHOUT
    # storing (storing would mark it done forever; it retries next run).
    store_stream_response! = |path, id, resp|
        if Response.status(resp) == 404 {
            store_streams!(path, id, "{}")?
            Ok(Stored)
        } else if Response.status(resp) < 300 {
            match Str.from_utf8(Response.body(resp)) {
                Ok(text) => {
                    store_streams!(path, id, text)?
                    Ok(Stored)
                }
                Err(_) => Ok(SkippedNonUtf8)
            }
        } else {
            text = Str.from_utf8(Response.body(resp)).ok_or("<non-utf8 body>")
            Err(HttpStatus(Response.status(resp), text))
        }
    backfill! : {} => Try({}, _)
    backfill! = |{}| {
        path = Db.open_db!({})?
        match get_valid_token!(path) {
            Err(NotAuthed) => Output.err_out!("not_authenticated", "not authenticated — run `stride auth` first")
            Err(other) => Err(other)
            Ok(token) => {
                # pull the full activity list first so backfill is self-sufficient —
                # no need to run `sync` beforehand (that's what made it two commands)
                Stdout.line!("backfill: refreshing the activity list...")?
                count = fetch_pages!(path, token, "", 1, 0)?
                Db.config_set!(path, "last_sync_epoch", I64.to_str(Db.now_secs!({})))?
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
                match Backfill.decide({ status: Response.status(resp), done: st.done, window: st.window, retries: st.retries }, read_limits) {
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
}
