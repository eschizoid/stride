import Db
import Output
import pf.Http
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
import Drain
import Metrics
import Config
import Render

Strava :: [].{
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
        #
        # DO NOT wrap these bindings in "${...}" to force a copy. That was tried against
        # #105 and crashed real sync every run — see the longer note in upsert_activity!.
        # #105 is FIXED (basic-cli 0.22.0); copying was never the fix, and this note
        # stays so nobody re-tries the copy on the next mystery crash.
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
        # UnreadableConfig, not CorruptToken: that tag was raised here and handled
        # nowhere, so a value the user can set with `config set` surfaced as
        # internal_error -- "please open an issue" for their own typo (#208).
        expires_at = (Metrics.arg_i64(expires_str)).map_err(|_| UnreadableConfig("strava_expires_at", expires_str))?
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
    # `all` forces a full re-list: the watermark is ignored, every activity is re-listed
    # and the prune is unbounded, so a deletion in old history propagates. That is the one
    # thing an incremental run can never see, and the only reason the flag exists — mostly
    # a dev-mode start-from-scratch (#232).
    sync! : Bool => Try({}, _)
    sync! = |all| {
        path = Db.open_db!({})?
        match get_valid_token!(path) {
            Err(NotAuthed) =>
                Output.err_out!("not_authenticated", "not authenticated — run `stride auth` first")

            Err(other) => Err(other)
            Ok(token) => {
                started = Db.now_secs!({})
                # Incremental with a rolling 30-day overlap so recent edits on Strava
                # self-heal. `--all` is the full re-pull when one is wanted.
                #
                # THREE outcomes, not two. Absent means never synced and a full pull is
                # right. A db read error propagates rather than silently burning the rate
                # budget. Unreadable used to collapse into the first, so a bad value
                # forced a full re-pull every run -- conservative, and therefore
                # invisible forever (#208). arg_i64 rather than I64.from_str, so the
                # shape accepted here matches what `config set` enforces.
                after_epoch =
                    if all {
                        # --all: behave exactly as a never-synced install does. No special
                        # path, so the full-pull case stays the one that is exercised on
                        # every fresh install rather than a rarely-run branch of its own.
                        None
                    } else
                    match Db.config_opt!(path, "last_sync_epoch")? {
                        NotFound => None
                        Found(epoch_str) =>
                            match Metrics.arg_i64(epoch_str) {
                                Ok(e) => Some((e - 2592000).max(0))
                                Err(_) => return Err(UnreadableConfig("last_sync_epoch", epoch_str))
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
                # next `sync --all` (full pull), which prunes all unseen ("" window_start). NULL
                # synced_at rows (imports, pre-migration) are exempt regardless of the window.
                window_start =
                    match after_epoch {
                        Some(a) => Metrics.epoch_to_iso(a + 86400)
                        None => ""
                    }
                counts = fetch_pages!(path, token, after_param, started, 1, { relisted: 0, new_n: 0, updated_n: 0 })?
                pruned = prune_deleted!(path, started, window_start)?
                Db.config_set!(path, "last_sync_epoch", I64.to_str(started))?
                pull = drain_missing_streams!(path, token)?
                # `synced` keeps its original meaning (rows re-listed) so existing consumers
                # are untouched; new_activities/updated_activities are ADDITIVE, so the
                # envelope version stays put. `streams_skipped` is additive for the same
                # reason (#224).
                # `stopped` and `resumable` moved here from the retired `backfill` (#232): a sync
                # that drains the whole history can now stop on Strava's read budget, and
                # "should I run it again?" has to be answerable without parsing prose.
                # `resumable` is `pending_streams > 0`, re-measured from the database in
                # EVERY arm — there is no short-circuit that derives it (one existed and was
                # deleted rather than documented, because a hardcoded 0 is a way to silently
                # zero an absence).
                #
                # ANNOTATED, and closed on purpose. An added, removed or retyped key fails
                # `roc check` here. The renderer below is an inline closure, which infers an
                # OPEN record — so without this line a new payload key compiles clean and
                # ships undeclared in schemas/v2/sync.json, which is exactly the drift
                # `additionalKeys: false` exists to catch (ADR 0000 section 9c).
                payload : { synced : U64, new_activities : U64, updated_activities : U64, pruned : U64, streams_fetched : I64, streams_skipped : I64, pending_streams : I64, stopped : Str, resumable : Bool }
                payload = { synced: counts.relisted, new_activities: counts.new_n, updated_activities: counts.updated_n, pruned, streams_fetched: pull.stored, streams_skipped: pull.skipped, pending_streams: pull.pending, stopped: Drain.stopped_label(pull.stopped), resumable: pull.pending > 0 }
                Output.out!(payload, |p| Render.sync_screen(p, all))
            }
        }
    }
    # fetch time/HR/watts/altitude/distance streams for activities that don't have them
    # yet, newest first. Not capped per run — pacing bounds the run (see read_limits!).
    # altitude + distance are requested EXPLICITLY (not relying on Strava's implicit base
    # streams) — together they feed grade-adjusted pace / NGP (ADR 0003). To re-pull for
    # pre-existing streams, DELETE FROM streams (mirror tier — re-pullable) and let the
    # next sync refetch them.

    # close the bar before anything else prints, or the line lands on the bar's row
    # Swallows its own failure on purpose, same policy as the boundary reporter: a stderr
    # write that fails must not convert a successful terminal arm into an error envelope,
    # nor replace an error already being reported with a narration error.
    bar_done! : DrainState => {}
    bar_done! = |st|
        if st.total > 0 {
            match Output.narrate_done!({}) {
                Ok(_) => {}
                Err(_) => {}
            }
        } else {
            {}
        }

    # ONE stream loop for the whole engine (#232). There used to be two — a capped,
    # unpaced one here for `sync` and a paced one for `backfill` — doing the same job.
    # They drifted, and every rate-limit inconsistency in stride came out of that: the
    # same 429 behaved three different ways depending on which loop and which request
    # hit it, and #218's counting bug had to be fixed a second time (#224) purely
    # because the loop existed twice.
    #
    # No per-run cap any more. `sync` drains what is missing, paced against Strava's
    # own limits, and stops on the read budget reporting `resumable: true` so the next
    # run continues. Steady state is a handful of reads — nobody rides 95 times a day —
    # so the long run is not the daily case. It is NOT only a fresh install, though:
    # `stride import` creates activities with no streams at all, and deleting stream rows
    # is the documented way to force a re-pull — both walk into a full drain, which takes
    # one run per 15-minute window until the queue empties.
    drain_missing_streams! : Str, Str => Try(DrainOutcome, _)
    drain_missing_streams! = |path, token| {
        ids = Sqlite.query_many!({
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
        total = List.len(ids)
        # No `total == 0` short-circuit. One existed, returning a hardcoded `pending: 0`
        # that was right only because this query's WHERE clause is character-identical to
        # `pending_streams!`'s — an invariant nothing pinned, whose explaining comment was
        # deleted along with the command that carried it. Falling through to the `[]` arm
        # MEASURES pending instead of asserting it, and `bar_done!` is a no-op at total 0,
        # so the branch bought nothing but a way to silently zero an absence.
        _ = if total > 0 {
            # An immediate 0/total frame BEFORE the first request: narrating only after a
            # response returns shows nothing for exactly as long as a stall lasts.
            Output.narrate!("fetching streams", 0, total)?
            # Said up front, because this run may not finish the job and the retired
            # command said so before spending a read. Strava's daily cap means a large
            # first pull spans days; every stored stream is permanent, so re-running is
            # never wasted work.
            Output.say!("draining ${U64.to_str(total)} activities' streams — Strava caps reads per 15-minute window, so a large first pull takes several runs; every stream stored is kept")?
        } else {
            {}
        }
        match drain_streams!(path, token, ids, { done: 0, window: 0, stored: 0, skipped: 0, total, refreshes: 0 }) {
            Ok(o) => Ok(o)
            Err(e) => {
                # ONE place, covering every propagating `?` in the drain rather than the
                # two sites say_partial! used to be wired to by hand — the promise ("report
                # durable progress before an error escapes") now matches the code. The
                # token refresh, the terminal pending_streams! read and the narration calls
                # were all uncovered, and the refresh is the realistic one: it is the
                # mid-run network call on a long drain.
                #
                # Nothing here uses `?`. This runs on the way out of a failure that is
                # already being reported, so a broken stderr must not replace that error
                # with its own — the policy say_partial! documents, now applied where the
                # contradiction was.
                _ = say_partial_stored!(total)
                Err(e)
            }
        }
    }

    # what the drain durably stored is not knowable from here, so report the queue it was
    # working and point at the command that continues it. The counts live in the payload
    # on every path that returns one.
    say_partial_stored! : U64 => {}
    say_partial_stored! = |total| {
        _ = match Output.narrate_done!({}) {
            Ok(_) => {}
            Err(_) => {}
        }
        match Output.say!("sync stopped on an error partway through ${U64.to_str(total)} activities — everything already stored is saved; run `stride sync` again to continue") {
            Ok(_) => {}
            Err(_) => {}
        }
    }

    # count activities still lacking streams, so a run that stopped on the read budget
    # reports the shortfall honestly instead of looking like completion
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
    invalidate_metrics! = |path, id| {
        # metrics FIRST, segments second, deliberately: if the second delete fails,
        # the missing metrics row makes the next analyze redo the activity, which
        # re-deletes and rebuilds segments — the failure self-heals. The reverse
        # order strands segment-less activities that analyze never revisits.
        _ = Sqlite.execute!({
            path: Path.utf8(path),
            query: "DELETE FROM activity_metrics WHERE activity_id = :id",
            bindings: [{ name: ":id", value: Integer(id) }],
        })?
        Sqlite.execute!({
            path: Path.utf8(path),
            query: "DELETE FROM activity_segments WHERE activity_id = :id",
            bindings: [{ name: ":id", value: Integer(id) }],
        })
    }

    # ── read pacing (Strava's limits, counted by us) ─────────────────────
    # Pacing counts OUR OWN reads BY CHOICE, so it never depends on an endpoint sending
    # rate-limit headers. Strava's limits are 100 reads per 15 minutes and 1000 per day;
    # a run fills one window and stops, and 429 is a backstop for when our count and
    # Strava's disagree, not the mechanism.
    # ── test seams, same species as STRIDE_API_BASE ─────────────────────
    # These three constants made two of the three StopReason values untestable: reaching
    # `budget_reached` honestly costs 940 reads, and `rate_limited` costs two 15-minute
    # sleeps. So a transposed counter in either terminal arm shipped with the whole suite
    # green — review demonstrated exactly that. Overriding them from the environment
    # reaches both arms in milliseconds against the mock. Humans never set these; the
    # defaults are the real limits and are what every non-test run uses.
    # An override may only LOWER a limit, never raise it. These bound requests against
    # Strava's real caps, and an env var that could raise them would let a typo — or a
    # copied command line — hammer the API and get the athlete's own API app suspended.
    # Lowering is all a test needs, so the useful direction is the safe one.
    env_i64! : Str, I64 => I64
    env_i64! = |name, fallback|
        match Env.var_str!(OsStr.from_str(name)) {
            Ok(v) =>
                match I64.from_str(v) {
                    Ok(n) if n > 0 and n < fallback => n
                    _ => fallback
                }
            Err(_) => fallback
        }

    # how many token refreshes one run may spend before calling it an auth problem
    max_refreshes = 2

    read_limits! : {} => Drain.Limits
    read_limits! = |{}| {
        # stop before Strava's 100-reads-per-15-minutes window fills. There is no second
        # per-run budget: `window` is never reset inside a run, so a larger one could
        # never fire. The DAILY cap is respected by arithmetic — ~95 reads a window,
        # ~10 windows a day, just under Strava's 1000.
        reads_per_window: env_i64!("STRIDE_READS_PER_WINDOW", 95),
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
    # THE stream-response policy: 404 => "{}" marker
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
    # Per-run drain state: `done` = reads this run (vs the daily cap), `window` = reads
    # this run (vs the 15-min cap; never reset, because a run does not span windows),
    # `stored`/`skipped` = what those reads actually produced.
    #
    # `done` and `stored` are deliberately different numbers and must stay so. Pacing is
    # about READS — a 404 spends a read and stores a marker, an undecodable body spends a
    # read and stores nothing — while the payload reports WORK. Publishing `done` as
    # `streams_fetched` (as the first cut of #218 did) reports rows that do not exist and
    # disagrees with `sync`'s identically-named field, which counts stores.
    # `total` is the queue length this run started with, carried so the loop can draw a
    # real progress bar rather than a spinner: a first-time sync can spend a long time
    # here, and narrating only after a response returns shows nothing for exactly as
    # long as a stall lasts. It is NOT a counter — nothing decrements it.
    DrainState : { done : I64, window : I64, stored : I64, skipped : I64, total : U64, refreshes : I64 }

    # Walk the missing-streams list once per run. Walking a LIST (not re-querying
    # "next missing") means an unstorable body is skipped, not refetched forever.
    # The pacing DECISION is pure (Drain.decide, unit-tested); this is the thin
    # effectful skin that dispatches on it: fetch, then act.
    # The THREE ways a drain ends, RETURNED rather than printed, because "why did it
    # stop?" is not derivable from the counts. (A fourth exit exists and is deliberately
    # not an outcome: a token refresh that does not help raises Err(HttpStatus(401, …)),
    # which is a failure, not a stopping reason.) Both non-complete reasons stop on the
    # 15-MINUTE window, so both mean ~15 minutes, not tomorrow.
    #
    # `stopped` is a Drain.StopReason tag, so the compiler enforces the set here;
    # Drain.stopped_label is the one place it becomes the string that ships.
    DrainOutcome : { stored : I64, skipped : I64, pending : I64, stopped : Drain.StopReason }

    drain_streams! : Str, Str, List(I64), DrainState => Try(DrainOutcome, _)
    drain_streams! = |path, token, ids, st|
        match ids {
            [] => {
                bar_done!(st)
                Ok({ stored: st.stored, skipped: st.skipped, pending: pending_streams!(path)?, stopped: Complete })
            }
            [id, .. as rest] => {
                uri = "${api_base!({})}/api/v3/activities/${I64.to_str(id)}/streams?keys=time,heartrate,watts,altitude,distance&key_by_type=true"
                resp = send_bearer!(uri, token)?
                match Drain.decide({ status: Response.status(resp), done: st.done, window: st.window }, read_limits!({})) {
                    Refresh => {
                        # Long runs outlive the ~6h access token; refresh and retry the same
                        # id. BOUNDED, like the 429 retry beside it: this arm recurses on the
                        # same id with the same state, so without a counter a persistently
                        # 401ing activity (revoked scope, a private activity without
                        # activity:read_all, a skewed clock) spins forever. Review measured
                        # the unbounded version at ~113 requests/second — 4,500 reads against
                        # a 1000/day cap in under a minute, which is exactly the API-app
                        # suspension the env-override guard exists to prevent. `decide` does
                        # not charge a 401 against `done` either, so the read budget never
                        # ended it. Same token back is still a real auth problem.
                        if st.refreshes >= max_refreshes {
                            bar_done!(st)
                            Err(HttpStatus(401, "kept getting 401 after refreshing the token — re-run `stride auth`"))
                        } else {
                            fresh = get_valid_token!(path)?
                            if fresh == token {
                                bar_done!(st)
                                Err(HttpStatus(401, "token refresh did not help — re-run `stride auth`"))
                            } else {
                                bar_done!(st)
                                Output.say!("  access token expired — refreshed, continuing...")?
                                drain_streams!(path, fresh, ids, { ..st, refreshes: st.refreshes + 1 })
                            }
                        }
                    }
                    # A 429 STOPS the run. It does not sleep: that made a routine sync
                    # block ~30 minutes in the foreground, measured on a two-activity
                    # queue. The rows already stored are durable and `resumable` says
                    # there is more, so the honest move is to hand the terminal back.
                    RateLimited => {
                        bar_done!(st)
                        Ok({ stored: st.stored, skipped: st.skipped, pending: pending_streams!(path)?, stopped: RateLimited })
                    }
                    Store({ done, window, after }) => {
                        # 404 => empty marker, 2xx => body, other => error propagated.
                        # MATCHED, not discarded: SkippedNonUtf8 writes no row, so that id
                        # stays pending and retries next run. Counting it as fetched reported
                        # rows that were never stored and let a lossy run present itself as a
                        # clean one — a bug that had to be fixed twice (#218, #224) back when
                        # this loop had a twin.
                        counted =
                            match store_stream_response!(path, id, resp)? {
                                Stored => { stored: st.stored + 1, skipped: st.skipped }
                                SkippedNonUtf8 => {
                                    bar_done!(st)
                                    Output.say!("  activity ${I64.to_str(id)}: stream data would not decode — skipped, retries next run")?
                                    { stored: st.stored, skipped: st.skipped + 1 }
                                }
                            }
                        # narrate on the id just RETIRED, counting attempts: a 404 or an
                        # undecodable body is progress through the queue too, so counting
                        # only stores would stall the bar on a run full of skips.
                        _ = if st.total > 0 { Output.narrate!("fetching streams", st.total - List.len(rest), st.total)? } else { {} }
                        match after {
                            # the 15-minute window is full. Stop and let the next run
                            # continue — this is the arm a real drain always takes, so
                            # the message it produces is the one users actually read.
                            WindowFull => {
                                bar_done!(st)
                                Ok({ stored: counted.stored, skipped: counted.skipped, pending: pending_streams!(path)?, stopped: BudgetReached })
                            }
                            Continue =>
                                drain_streams!(path, token, rest, { ..st, done, window, stored: counted.stored, skipped: counted.skipped })

                        }
                    }
                }
            }
        }
    per_page = 100

    # acc carries the re-listed total AND the new/updated split (#112): the first is a
    # function of training frequency, the second is what actually happened this run.
    # The `narrate` and `classify` flags are gone with #232. They existed so `backfill`
    # could pass False, False; `sync` is the only caller now and always wants both, so
    # they were two dead parameters and a branch nothing took.
    fetch_pages! : Str, Str, Str, I64, U64, { relisted : U64, new_n : U64, updated_n : U64 } => Try({ relisted : U64, new_n : U64, updated_n : U64 }, _)
    fetch_pages! = |path, token, after_param, stamp, page, acc| {
        page_str = (page).to_str()
        per_str = (per_page).to_str()
        uri = "${api_base!({})}/api/v3/athlete/activities?per_page=${per_str}&page=${page_str}${after_param}"
        # page 1 only, and BEFORE the request: the per-page lines below report pages that
        # already landed, so a stalled first request would otherwise print nothing at all.
        # Later pages need no such line — by then the reader has seen output.
        _ = if page == 1 { Output.say!("fetching activity list…")? } else { {} }
        body = get_bearer!(uri, token)?
        text = Str.from_utf8(body).map_err(|_| ActivityDecodeFailed(page))?
        decoded : Try(List(ActivitySummary), _)
        decoded = Json.parse(text)
        acts = decoded.map_err(|_| ActivityDecodeFailed(page))?
        counts = upsert_all!(path, stamp, acts, { new_n: acc.new_n, updated_n: acc.updated_n })?
        got = List.len(acts)
        total = acc.relisted + got
        # a plain line per page, not a bar: Strava's activity list is paged and its length
        # is unknowable until the short page arrives, so any denominator here would be
        # invented. Pages are few at `per_page` (100) a page, so the lines stay countable.
        _ = Output.say!("fetched activities page ${(page).to_str()} — ${(total).to_str()} so far")?
        next = { relisted: total, new_n: counts.new_n, updated_n: counts.updated_n }
        if got < per_page
            Ok(next)
        else
            fetch_pages!(path, token, after_param, stamp, page + 1, next)
    }
    # What a sync did to one row. Most rows on most days are Unchanged: sync re-lists a
    # rolling 30-day window every run, so the re-listed count is a function of how often
    # the athlete trains, not of anything this sync did (#112).
    UpsertOutcome : [Inserted, Updated, Unchanged]

    SyncCounts : { new_n : U64, updated_n : U64 }

    # The classify SELECT runs per row. It used to be skippable, because `backfill!`
    # re-listed the whole account and never read the counts — paying a query each would
    # have been a real cost for nothing, the same mistake as running classify inside
    # upsert_activity! where CSV import paid it. With one caller that wants the counts,
    # the skip is gone; if a future caller does not want them, bring the flag back rather
    # than making this function guess.
    upsert_all! : Str, I64, List(ActivitySummary), SyncCounts => Try(SyncCounts, _)
    upsert_all! = |path, stamp, acts, acc|
        match acts {
            [] => Ok(acc)
            [a, .. as rest] => {
                # classify HERE, not inside upsert_activity!. Import.roc calls that
                # directly for CSV loads and discards the outcome, so classifying there
                # made every imported row pay for an extra query it never reads — and that
                # extra per-row query in the import loop made the offline e2e flaky
                # (import checks failing ~1 run in 3). The counts are a sync concern; keep
                # the cost on the sync path, and only when someone will read them.
                outcome = classify_activity!(path, a)?
                _ = upsert_activity!(path, stamp, a)?
                next =
                    match outcome {
                        Inserted => { new_n: acc.new_n + 1, updated_n: acc.updated_n }
                        Updated => { new_n: acc.new_n, updated_n: acc.updated_n + 1 }
                        Unchanged => acc
                    }
                upsert_all!(path, stamp, rest, next)
            }

        }

    # Classify BEFORE writing, in one read. `changes()` after the write would have been
    # cheaper, but it is per-CONNECTION state and every Sqlite call here takes a path
    # rather than a handle — whether two calls share a connection is a platform detail we
    # would be silently depending on. A rolling window is ~20 rows, so one extra SELECT
    # each is not worth that risk.
    #
    # `IS` rather than `=` throughout: these columns are nullable and `= NULL` is NULL, not
    # false, so every row with a missing avg_watts would look changed on every sync.
    #
    # synced_at is deliberately NOT compared. It is re-stamped every run by design, so
    # including it would mark every row updated — which is precisely the misreporting this
    # exists to remove.
    classify_activity! : Str, ActivitySummary => Try(UpsertOutcome, _)
    classify_activity! = |path, a| {
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT
                \\  (SELECT COUNT(*) FROM activities WHERE id = :id) AS existed,
                \\  (SELECT COUNT(*) FROM activities WHERE id = :id
                \\     AND name IS :name AND sport_type IS :sport AND start_local IS :start
                \\     AND moving_time IS :mt AND distance IS :dist AND elevation IS :elev
                \\     AND relative_effort IS :re AND avg_watts IS :aw AND avg_hr IS :ahr
                \\     AND weighted_avg_watts IS :waw AND device_watts IS :dw) AS same
            ,
            bindings: activity_bindings(a),
            rows: |cols| |stmt| {
                existed = Sqlite.i64("existed")(cols)(stmt)?
                same = Sqlite.i64("same")(cols)(stmt)?
                Ok((existed, same))
            },
        })?
        match List.first(rows) {
            Ok((0, _)) => Ok(Inserted)
            Ok((_, 0)) => Ok(Updated)
            Ok(_) => Ok(Unchanged)
            # a COUNT always returns a row, so this is unreachable; call it Updated rather
            # than Unchanged so an impossible state over-reports rather than hiding work
            Err(_) => Ok(Updated)
        }
    }

    # The column bindings shared by the classify SELECT and the upsert INSERT, so the two
    # cannot drift into comparing one set of values and writing another. `:synced` is NOT
    # here: it is appended by the writer only, because the comparison must ignore it.
    activity_bindings : ActivitySummary -> List(_)
    activity_bindings = |a| [
        { name: ":id", value: Integer(a.id) },
        # Binding the decoded Str straight through is correct on basic-cli 0.22+ — the
        # 0.21 host double-freed heap Strs in bindings (bug C, #105, fixed upstream in
        # basic-cli#472). Still DO NOT wrap these in "${...}" to force a copy: the copy
        # "fix" built on the wrong theory crashed real sync 12/12 while the short-name
        # e2e mock stayed green. See #105 for the full history.
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
    ]
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
            # the SAME values classify_activity! compared against, so the check and the
            # write cannot disagree about what "changed" means. :synced is appended here
            # only — it is re-stamped every run and must stay out of the comparison.
            bindings: List.append(
                activity_bindings(a),
                # stamp this row with the current sync run so prune_deleted! can tell which
                # activities Strava still has (re-stamped) from ones it deleted (stale stamp)
                { name: ":synced", value: synced_val },
            ),
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
    # (start_local >= window_start; "" = full pull = all rows). Three judgment-tier guards:
    # never prune an activity that carries a rating, completed a planned session, or stands in as a substitute for one —
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
                \\  AND id NOT IN (SELECT substitute_activity_id FROM planned_sessions WHERE substitute_activity_id IS NOT NULL)
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
                _ = Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM activity_segments WHERE activity_id = :id", bindings: b })?
                _ = Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM streams WHERE activity_id = :id", bindings: b })?
                _ = Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM activities WHERE id = :id", bindings: b })?
                prune_txn!(path, rest)
            }
        }
}
