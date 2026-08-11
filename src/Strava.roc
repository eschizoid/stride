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
import Config

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
                        Stdout.line!("  (Strava rejected the stored token — re-run `stride auth`)")

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
            # only honor an allowed override (https, or http to loopback) — a disallowed
            # base can't exfiltrate the client_secret/refresh token; fall back to real Strava
            Ok(b) if !(Str.is_empty(b)) and Config.api_base_allowed(b) => b
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
    save_tokens! = |path, tokens|
        # ONE atomic multi-row upsert. Strava rotates the refresh token on every refresh, so
        # three separate writes risked a crash between them leaving new-access + a DEAD refresh
        # token → auth bricked until a manual re-`auth`. A single SQL statement is atomic.
        Sqlite.execute!({
            path: Path.utf8(path),
            query:
                \\INSERT OR REPLACE INTO config (key, value) VALUES
                \\  ('strava_access_token', :at), ('strava_refresh_token', :rt), ('strava_expires_at', :exp)
            ,
            bindings: [
                { name: ":at", value: String(tokens.access_token) },
                { name: ":rt", value: String(tokens.refresh_token) },
                { name: ":exp", value: String(I64.to_str(tokens.expires_at)) },
            ],
        })
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
        # Strava sets this FALSE when watts are estimated (no meter). Estimated watts are
        # not measurements and must not outrank honest fallbacks (#73).
        device_watts : Try(Bool, [Missing]),
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
                # NotFound (never synced) = full pull; a real db read error propagates
                # instead of silently burning the rate budget
                after_epoch =
                    match Db.config_opt!(path, "last_sync_epoch")? {
                        NotFound => None
                        Found(epoch_str) =>
                            match I64.from_str(epoch_str) {
                                Ok(e) => Some((e - 2592000).max(0))
                                Err(_) => None
                            }
                    }
                after_param =
                    match after_epoch {
                        Some(a) => "&after=${I64.to_str(a)}"
                        None => ""
                    }
                # window_start bounds the prune to rows solidly inside the window Strava
                # re-listed this run. It is the `after` epoch PLUS a one-day margin, rendered
                # by epoch_to_iso to `YYYY-MM-DDTHH:MM:SSZ` (UTC) and compared lexically to
                # activities.start_local (Strava's LOCAL start_date_local). The margin is the
                # fix for that UTC-vs-local mismatch: without it, timezone skew (up to ~14h) at
                # the boundary could mark an activity that is merely just OUTSIDE Strava's
                # `after` window — still present upstream, only older — as a deletion and prune
                # it. A full day exceeds any offset, so only rows definitely in the response are
                # eligible. A deletion in that one-day sliver at the far edge is caught by the
                # next `backfill` (full pull), which prunes all unseen ("" window_start). NULL
                # synced_at rows (imports, pre-migration) are exempt regardless of the window.
                window_start =
                    match after_epoch {
                        Some(a) => Metrics.epoch_to_iso(a + 86400)
                        None => ""
                    }
                count = fetch_pages!(path, token, after_param, started, 1, 0, True)?
                pruned = prune_deleted!(path, started, window_start)?
                Db.config_set!(path, "last_sync_epoch", I64.to_str(started))?
                streams_n = backfill_streams!(path, token)?
                remaining = pending_streams!(path)?
                Output.out!({ synced: count, pruned, streams_fetched: streams_n, pending_streams: remaining }, |p| {
                    prune_note = if p.pruned > 0 " (pruned ${U64.to_str(p.pruned)} removed on Strava)" else ""
                    tail =
                        if p.pending_streams > 0
                            " (${I64.to_str(p.pending_streams)} still need streams — run `stride backfill` to pull them all)"
                        else
                            ""
                    "synced ${U64.to_str(p.synced)} activities${prune_note}, fetched streams for ${U64.to_str(p.streams_fetched)}${tail}"
                })
            }
        }
    }
    # fetch time/HR/watts/altitude/distance streams for activities that don't have them
    # yet, newest first, capped per run to respect Strava's rate limits (~100 reads/15min).
    # altitude + distance are requested EXPLICITLY (not relying on Strava's implicit base
    # streams) — together they feed grade-adjusted pace / NGP (ADR 0003). To re-pull for
    # pre-existing streams, DELETE FROM streams (mirror tier — re-pullable) and let this
    # backfill refetch them.
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
        # the stream backfill is the long half of a sync and its total IS knowable — the
        # id list is already in hand — so this half gets a real bar rather than a spinner.
        #
        # The completion and rate-limit paths close the bar themselves, because each prints
        # something straight after. Every OTHER way out is an error propagating from the
        # HTTP call, the status check or the store — none of which can close it on the way
        # past — so the error case is closed here, once, instead of at each `?`.
        # An immediate 0/total frame BEFORE the first request. Narrating only after a
        # response returns means a stalled network call shows nothing for exactly as long
        # as the stall lasts — which is the "it looks hung" failure this whole change
        # exists to prevent, reintroduced at the one moment it matters most.
        _ = if !(List.is_empty(ids)) { Output.narrate!("fetching streams", 0, List.len(ids))? } else { {} }
        res = fetch_streams_all!(path, token, ids, 0, List.len(ids))
        match res {
            Ok(n) => Ok(n)
            Err(e) => {
                _ = if !(List.is_empty(ids)) { Output.narrate_done!({})? } else { {} }
                Err(e)
            }
        }
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

    fetch_streams_all! : Str, Str, List(I64), U64, U64 => Try(U64, _)
    fetch_streams_all! = |path, token, ids, acc, total|
        match ids {
            [] => {
                # close the bar before sync's stdout summary prints, or the summary lands
                # on the same terminal row as the last frame
                _ = if total > 0 { Output.narrate_done!({})? } else { {} }
                Ok(acc)
            }

            [id, .. as rest] => {
                id_str = (id).to_str()
                uri = "${api_base!({})}/api/v3/activities/${id_str}/streams?keys=time,heartrate,watts,altitude,distance&key_by_type=true"
                resp = send_bearer!(uri, token)?
                if Response.status(resp) == 429 {
                    # rate limited — stop gracefully, next sync continues the backfill.
                    # STDERR, not stdout: this runs inside `sync`, which emits a JSON
                    # envelope at the end, so a plain line on stdout would sit in front of
                    # that JSON and break every machine consumer parsing it. It is
                    # narration about how the run went, which is exactly what stderr is
                    # for. (`backfill` prints its own progress on stdout legitimately —
                    # that command emits no envelope, so its lines ARE its output.)
                    _ = if total > 0 { Output.narrate_done!({})? } else { {} }
                    Output.say!("rate limited by Strava — stopping streams backfill for now (will resume next sync)")?
                    Ok(acc)
                } else if Response.status(resp) >= 300 and Response.status(resp) != 404 {
                    Err(HttpStatus(Response.status(resp), Str.from_utf8(Response.body(resp)).ok_or("<non-utf8 body>")))
                } else {
                    # narrate on the id just RETIRED, counting attempts rather than stores:
                    # a 404 or non-utf8 body is progress through the queue too, so counting
                    # only stored rows would stall the bar on a run full of skips.
                    done = total - List.len(rest)
                    _ = if total > 0 { Output.narrate!("fetching streams", done, total)? } else { {} }
                    # 404/2xx/non-utf8 policy lives in store_stream_response! (shared with backfill)
                    match store_stream_response!(path, id, resp)? {
                        Stored => fetch_streams_all!(path, token, rest, acc + 1, total)
                        SkippedNonUtf8 => fetch_streams_all!(path, token, rest, acc, total)

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
                started = Db.now_secs!({})
                count = fetch_pages!(path, token, "", started, 1, 0, False)?
                # full re-pull: window_start "" prunes every activity Strava no longer lists
                pruned = prune_deleted!(path, started, "")?
                (if pruned > 0 Stdout.line!("backfill: pruned ${U64.to_str(pruned)} activities removed on Strava") else Ok({}))?
                Db.config_set!(path, "last_sync_epoch", I64.to_str(started))?
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
                uri = "${api_base!({})}/api/v3/activities/${I64.to_str(id)}/streams?keys=time,heartrate,watts,altitude,distance&key_by_type=true"
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

    fetch_pages! : Str, Str, Str, I64, U64, U64, Bool => Try(U64, _)
    fetch_pages! = |path, token, after_param, stamp, page, acc, narrate| {
        page_str = (page).to_str()
        per_str = (per_page).to_str()
        uri = "${api_base!({})}/api/v3/athlete/activities?per_page=${per_str}&page=${page_str}${after_param}"
        # page 1 only, and BEFORE the request: the per-page lines below report pages that
        # already landed, so a stalled first request would otherwise print nothing at all.
        # Later pages need no such line — by then the reader has seen output.
        _ = if narrate and page == 1 { Output.say!("fetching activity list…")? } else { {} }
        body = get_bearer!(uri, token)?
        text = Str.from_utf8(body).map_err(|_| ActivityDecodeFailed(page))?
        decoded : Try(List(ActivitySummary), _)
        decoded = Json.parse(text)
        acts = decoded.map_err(|_| ActivityDecodeFailed(page))?
        upsert_all!(path, stamp, acts)?
        got = List.len(acts)
        total = acc + got
        # a plain line per page, not a bar: Strava's activity list is paged and its length
        # is unknowable until the short page arrives, so any denominator here would be
        # invented. Pages are few at `per_page` (100) a page, so the lines stay countable.
        # Gated because `backfill!` shares this function and ALREADY reports its own
        # progress on stdout — narrating here too would duplicate it in a second stream.
        _ = if narrate { Output.say!("fetched activities page ${(page).to_str()} — ${(total).to_str()} so far")? } else { {} }
        if got < per_page
            Ok(total)
        else
            fetch_pages!(path, token, after_param, stamp, page + 1, total, narrate)
    }
    upsert_all! : Str, I64, List(ActivitySummary) => Try({}, _)
    upsert_all! = |path, stamp, acts|
        match acts {
            [] => Ok({})
            [a, .. as rest] => {
                upsert_activity!(path, stamp, a)?
                upsert_all!(path, stamp, rest)
            }

        }
    upsert_activity! : Str, I64, ActivitySummary => Try({}, _)
    upsert_activity! = |path, stamp, a| {
        # stamp 0 = a non-sync writer (CSV import): leave synced_at NULL so the prune
        # never mistakes an imported activity (never on Strava) for a deleted one. Real
        # sync stamps are now_secs epochs, never 0.
        synced_val = if stamp == 0 Null else Integer(stamp)
        Sqlite.execute!({
            path: Path.utf8(path),
            query:
                \\INSERT OR REPLACE INTO activities (id, name, sport_type, start_local, moving_time, distance, elevation, relative_effort, avg_watts, avg_hr, weighted_avg_watts, device_watts, synced_at)
                \\VALUES (:id, :name, :sport, :start, :mt, :dist, :elev, :re, :aw, :ahr, :waw, :dw, :synced)
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
                # NULL = Strava did not say (old data); 1 = real meter; 0 = estimated
                { name: ":dw", value: match a.device_watts { Ok(True) => Integer(1)  Ok(False) => Integer(0)  Err(_) => Null } },
                # stamp this row with the current sync run so prune_deleted! can tell which
                # activities Strava still has (re-stamped) from ones it deleted (stale stamp)
                { name: ":synced", value: synced_val },
            ],
        })?
        # NO metrics invalidation here, deliberately. `sync` re-lists a rolling 30-day
        # window every run and cannot cheaply tell an edit from a no-op, so deleting here
        # wiped a month of computed metrics on every sync and left every report
        # under-reporting load until the next analyze.
        #
        # Staleness is detected in `analyze` instead, by comparing the activity inputs each
        # metrics row was computed from against the row as it now stands — the same
        # contract as `ftp_used`. That path is stateless and self-correcting: it cannot
        # drift, and it costs nothing extra because analyze already runs that predicate.
        Ok({})
    }

    # remove activities that vanished from Strava. A row is a victim when this sync run
    # did NOT re-stamp it (synced_at stale or null) AND it sits inside the pulled window
    # (start_local >= window_start; "" = full pull = all rows). Two judgment-tier guards:
    # never prune an activity that carries a rating or that completed a planned session —
    # those rows can't be re-derived, so we leave the (now-orphaned) activity as a
    # tombstone rather than destroy the human input. Everything else in the mirror tier is
    # re-pullable, so pruning is safe. Cascades to the computed tables and runs in one
    # transaction so a crash can't half-prune. Returns the number of activities removed.
    prune_deleted! : Str, I64, Str => Try(U64, _)
    prune_deleted! = |path, stamp, window_start| {
        victims = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT id AS id FROM activities
                \\-- only rows a PRIOR sync stamped then this run didn't re-stamp are
                \\-- confirmed Strava deletions. NULL (CSV imports, pre-migration rows)
                \\-- is never a victim — conservative, avoids nuking non-sync data.
                \\WHERE synced_at IS NOT NULL AND synced_at <> :stamp
                \\  AND start_local >= :ws
                \\  AND id NOT IN (SELECT activity_id FROM ratings)
                \\  AND id NOT IN (SELECT completed_activity_id FROM planned_sessions WHERE completed_activity_id IS NOT NULL)
            ,
            bindings: [
                { name: ":stamp", value: Integer(stamp) },
                { name: ":ws", value: String(window_start) },
            ],
            rows: Sqlite.i64("id"),
        })?
        if List.len(victims) == 0
            Ok(0)
        else {
            _ = Sqlite.execute!({ path: Path.utf8(path), query: "BEGIN", bindings: [] })?
            match prune_txn!(path, victims) {
                Ok(_) => {
                    _ = Sqlite.execute!({ path: Path.utf8(path), query: "COMMIT", bindings: [] })?
                    Ok(List.len(victims))
                }
                Err(e) =>
                    # a failed ROLLBACK (lock, corruption) is the more actionable signal —
                    # surface it; otherwise return the error that aborted the prune
                    match Sqlite.execute!({ path: Path.utf8(path), query: "ROLLBACK", bindings: [] }) {
                        Ok(_) => Err(e)
                        Err(re) => Err(re)
                    }
            }
        }
    }
    prune_txn! : Str, List(I64) => Try({}, _)
    prune_txn! = |path, ids|
        match ids {
            [] => Ok({})
            [id, .. as rest] => {
                b = [{ name: ":id", value: Integer(id) }]
                _ = Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM activity_metrics WHERE activity_id = :id", bindings: b })?
                _ = Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM streams WHERE activity_id = :id", bindings: b })?
                _ = Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM activities WHERE id = :id", bindings: b })?
                prune_txn!(path, rest)
            }
        }
}
