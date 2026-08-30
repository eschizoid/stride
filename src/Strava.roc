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
    # failure — the URL is always printed as the manual fallback. exec_output! so a
    # failing launcher can't spew stderr into the auth instructions or hand the TTY
    # to a console browser on a headless box.
    # ...and NOT when the token endpoint is a loopback mock: `STRIDE_API_BASE` is
    # the e2e seam, and the authorize URL staying real is what made `just test` open
    # seven strava.com tabs on a dev machine.
    #
    # A PREFIX test is safe HERE ONLY because it reads `api_base!({})`, which has
    # already applied the allow-list (`Config.api_base_allowed` exists precisely
    # because `http://localhost:8799@attacker.tld` starts with `http://localhost:`).
    # Do NOT hoist these calls into a direct `Env.var_str!` as a tidy-up — that is
    # exactly what makes the bypass live.
    open_browser! : Str => {}
    open_browser! = |url|
        if Str.starts_with(api_base!({}), "http://127.0.0.1") or Str.starts_with(api_base!({}), "http://localhost") {
            {}
        } else
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
                Output.missing_client_creds!(name)

            (Err(other), _) | (_, Err(other)) => Err(other)

        }
    }
    auth_flow! : Str, Str, Str => Try({}, _)
    auth_flow! = |path, client_id, client_secret| {
        url = "https://www.strava.com/oauth/authorize?client_id=${client_id}&response_type=code&redirect_uri=http://localhost&approval_prompt=auto&scope=read,activity:read_all"
        # Output.human_line!, not Stdout.line! — stdout carries the envelope in JSON mode
        # and this prose is not it (#259). The prompt below is the one that made it more
        # than untidy: no trailing newline meant the envelope landed on the same line.
        Output.human_line!("1) Click Authorize in the browser tab that just opened (URL below if it didn't):")?
        Output.human_line!("")?
        Output.human_line!("   ${url}")?
        Output.human_line!("")?
        open_browser!(url)
        Output.human_line!("2) You'll land on a localhost page that fails to load — that's expected.")?
        Output.human_line!("   Copy the code=XXXX value from the address bar and paste it here.")?
        Output.human_line!("")?
        Output.human_write!("code: ")?
        code_raw = Stdin.line!()?
        code = Str.trim(code_raw)
        form = "client_id=${client_id}&client_secret=${client_secret}&code=${code}&grant_type=authorization_code"
        body = post_form!(token_url!({}), form)?
        tokens = decode_tokens(body)?
        save_tokens!(path, tokens)?
        # persist client creds so sync never needs env vars again
        Db.config_set!(path, "strava_client_id", client_id)?
        Db.config_set!(path, "strava_client_secret", client_secret)?
        # ...and the SUCCESS line was the same defect as the prompt, one path over: bare
        # prose on stdout in JSON mode. Auth is a setup step whose command-table entry
        # publishes six machine-readable error codes — a promise its stdout is parseable.
        # `expires_at` rather than a bare success flag: the one fact a caller can act on,
        # already in hand. Tokens themselves never appear (same rule as `config get`).
        Output.out!({ authorized: 1 == 1, expires_at: tokens.expires_at }, |_| "authorized — tokens stored. Run `stride sync` to pull your activities.")
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
        # ONE atomic multi-row upsert: Strava rotates the refresh token on every refresh,
        # so three separate writes risked a crash leaving new-access + a DEAD refresh
        # token — auth bricked until a manual re-`auth`.
        # DO NOT wrap these bindings in "${...}" to force a copy: tried against #105 and
        # crashed real sync every run. #105 is FIXED (basic-cli 0.22.0); this note stays
        # so nobody re-tries the copy on the next mystery crash.
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
                # BEFORE the first request: a run that STARTS with the day's allowance spent has
                # nothing it can do and costs nothing to find out — same stop, same remedy as one
                # that spends its last read. (The LIST can still push the counter past the cap
                # mid-run, and the drain then spends exactly one wasted stream read before
                # `decide` stops it — one read is not worth a branch.)
                # `pending_streams!` rather than 0, so `resumable` and the queue count stay true:
                # the work is outstanding, it just cannot be done today.
                if day_spent!(path)? {
                    pend0 = pending_streams!(path)?
                    cap_stop = FromDrain(DailyCapReached)
                    cap_payload : { synced : U64, new_activities : U64, updated_activities : U64, pruned : U64, streams_fetched : I64, streams_skipped : I64, pending_streams : I64, stopped : Str, resumable : Bool }
                    cap_payload = { synced: 0, new_activities: 0, updated_activities: 0, pruned: 0, streams_fetched: 0, streams_skipped: 0, pending_streams: pend0, stopped: Drain.sync_stopped_label(cap_stop), resumable: True }
                    Output.out!(cap_payload, |p| Render.sync_screen(p, cap_stop, all))
                } else {
                counts = fetch_pages!(path, token, after_param, started, 1, { relisted: 0, new_n: 0, updated_n: 0, rate_limited: False })?
                # A rate-limited list stops the run HERE, before pruning and before the
                # drain (#235). Three reasons, and the first is the one that matters:
                #
                #   • PRUNE. prune_deleted! removes what the listing did not re-list, so
                #     running it against a PARTIAL list would delete activities that exist
                #     and simply were not reached. That is destructive and unrecoverable
                #     from the mirror side; everything else here is merely wasted.
                #   • the watermark. last_sync_epoch must not advance on a partial list, or
                #     the next run starts after activities it never saw.
                #   • the drain. It reads from the same budget that just refused us, so it
                #     would spend the run's remaining requests failing.
                #
                # The pages already upserted are kept — upsert_all! ran per page — and are
                # reported below, so the caller sees what landed rather than nothing.
                if counts.rate_limited {
                    # `resumable: True` unconditionally, and that is a DEPARTURE from the
                    # rule stated below — "resumable is pending_streams > 0, re-measured in
                    # every arm". Here the thing left undone is the LIST, not the queue: a
                    # run refused on page one has zero pending streams and absolutely must
                    # be repeated. The field's definition widens to "something is still
                    # missing — pending streams, or a list that was cut short", and the
                    # schema and SKILL.md say so rather than the old equality.
                    pending = pending_streams!(path)?
                    # BOUND once, then used twice: the payload's string and the screen's tag must
                    # describe the same run, and writing the tag at both spots made that a
                    # coincidence. (Above the annotation — Roc reads a separated annotation as a
                    # declaration with no value.)
                    # WHICH limit refused the list? The drain's 429 arm asks; the list's did not, so
                    # "~15 minutes" survived on the other endpoint that can 429 (#246's defect, one
                    # endpoint over). Its own tag, because both facts are load-bearing: the listing
                    # is incomplete (rows are missing) AND the remedy is tomorrow. A tag carrying
                    # one of them forces Render to guess the other from `pending_streams`, which is
                    # what this type was introduced to stop.
                    rl_stop = if day_spent!(path)? ListDailyCapReached else ListRateLimited
                    rl_payload : { synced : U64, new_activities : U64, updated_activities : U64, pruned : U64, streams_fetched : I64, streams_skipped : I64, pending_streams : I64, stopped : Str, resumable : Bool }
                    rl_payload = { synced: counts.relisted, new_activities: counts.new_n, updated_activities: counts.updated_n, pruned: 0, streams_fetched: 0, streams_skipped: 0, pending_streams: pending, stopped: Drain.sync_stopped_label(rl_stop), resumable: True }
                    Output.out!(rl_payload, |p| Render.sync_screen(p, rl_stop, all))
                } else {
                pruned = prune_deleted!(path, started, window_start)?
                Db.config_set!(path, "last_sync_epoch", I64.to_str(started))?
                pull = drain_missing_streams!(path, token)?
                # `synced` keeps its meaning (rows re-listed) so existing consumers are
                # untouched; new/updated/streams_skipped are ADDITIVE (#112, #224). `stopped` and
                # `resumable` moved here from the retired `backfill` (#232): "should I run it
                # again?" must be answerable without parsing prose. `resumable` is
                # `pending_streams > 0`, re-measured from the database in EVERY arm — a hardcoded
                # 0 is a way to silently zero an absence.
                #
                # ANNOTATED, and closed on purpose: the renderer below is an inline closure,
                # which infers an OPEN record — without this line a new payload key compiles
                # clean and ships undeclared in schemas/v3/sync.json (ADR 0000 s9c).
                # BOUND once — see the note at the rate-limited payload above.
                stop = FromDrain(pull.stopped)
                payload : { synced : U64, new_activities : U64, updated_activities : U64, pruned : U64, streams_fetched : I64, streams_skipped : I64, pending_streams : I64, stopped : Str, resumable : Bool }
                payload = { synced: counts.relisted, new_activities: counts.new_n, updated_activities: counts.updated_n, pruned, streams_fetched: pull.stored, streams_skipped: pull.skipped, pending_streams: pull.pending, stopped: Drain.sync_stopped_label(stop), resumable: pull.pending > 0 }
                Output.out!(payload, |p| Render.sync_screen(p, stop, all))
                }
                }
            }
        }
    }
    # close the bar before anything else prints, or the line lands on the bar's row.
    # Swallows its own failure, same policy as the boundary reporter: a failed stderr
    # write must not convert a successful arm into an error envelope.
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

    # ONE stream loop for the whole engine (#232). There were two — a capped unpaced
    # one for `sync`, a paced one for `backfill` — and every rate-limit inconsistency
    # came out of the drift between them. No per-run cap: `sync` drains what is
    # missing, paced against Strava's limits, and stops on the read budget with
    # `resumable: true`. Steady state is a handful of reads; `stride import` and a
    # deleted streams table both walk into a full drain, one run per 15-minute
    # window until the queue empties.
    #
    # fetch time/HR/watts/altitude/distance streams for activities that lack them,
    # newest first; pacing bounds the run (see read_limits!). altitude + distance are
    # requested EXPLICITLY — they feed grade-adjusted pace / NGP (ADR 0003). To force
    # a re-pull, DELETE FROM streams (mirror tier) and let the next sync refetch.
    drain_missing_streams! : Str, Str => Try(DrainOutcome, _)
    drain_missing_streams! = |path, token| {
        ids = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.id AS id FROM activities a
                \\LEFT JOIN streams s ON s.activity_id = a.id
                \\WHERE s.activity_id IS NULL AND a.moving_time > 0
                \\ORDER BY ${Metrics.rank_ts_sql("a.start_local", Desc)}
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
            # ORDER MATTERS. Say the sentence FIRST, then open the bar. narrate! writes a
            # bar frame with no trailing newline, so a say! after it lands on the bar's row
            # — and since the next frame's \r rewrites only the frame's own width, the tail
            # of a 138-character message stays welded to the right of a 33-character bar
            # for the whole drain. That is the failure bar_done!'s comment names, and it
            # shipped because nothing asserts on stderr framing.
            Output.say!("draining ${U64.to_str(total)} activities' streams — Strava caps reads per 15-minute window, so a large first pull takes several runs; every stream stored is kept")?
            # an immediate 0/total frame BEFORE the first request: narrating only after a
            # response returns shows nothing for exactly as long as a stall lasts
            Output.narrate!("fetching streams", 0, total)?
        } else {
            {}
        }

        # the day's read count, carried in from the database. Stored per UTC day, so a
        # stale stamp means a new day and the count starts over — that is the reset, and
        # it needs no scheduled job.
        day0 = Db.utc_today_days!({})
        today0 = reads_today!(path, day0)?
        match drain_streams!(path, token, ids, { window: 0, day: day0, today: today0, stored: 0, skipped: 0, total, refreshes: 0 }) {
            Ok(o) => Ok(o)
            Err(e) => {
                # ONE place covering every propagating `?` in the drain — the token refresh, the
                # terminal pending_streams! read and the narration calls were all uncovered, and
                # the refresh is the realistic one: the mid-run network call on a long drain.
                # Nothing here uses `?`: this runs on the way out of a failure already being
                # reported, so a broken stderr must not replace that error with its own.
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
        # guarded like bar_done!, which has the same job: at total 0 no bar was ever
        # opened, so closing one emits a stray blank line and the sentence below would
        # read "partway through 0 activities"
        _ = if total > 0 {
            match Output.narrate_done!({}) {
                Ok(_) => {}
                Err(_) => {}
            }
        } else {
            {}
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
    # Pacing counts OUR OWN reads BY CHOICE, never depending on rate-limit headers:
    # 100 reads per 15 minutes, 1000 per day; a run fills one window and stops, and
    # 429 is a backstop for when the counts disagree, not the mechanism.
    # ── test seams, same species as STRIDE_API_BASE ─────────────────────
    # Without these, reaching the budget stops honestly costs a full window (95) —
    # and the daily cap a full day (1000) — of real HTTP reads, so a transposed
    # counter in a terminal arm shipped green.
    # An override may only LOWER a limit, never raise it: a raised cap lets a typo
    # hammer the API and get the athlete's own API app suspended. Lowering is all a
    # test needs, so the useful direction is the safe one.
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

    # reads already made TODAY, in UTC. Two rows: the count and the day it belongs
    # to. Reading them together makes the reset free — a stale `strava_reads_day`
    # means the count is zero, and nothing has to run at midnight. Absent keys are
    # zero (a never-synced database has no count; `Db.config_opt!` maps NoRowsReturned
    # to NotFound).
    #
    # ...and CHARGE one, BEFORE the request: a transport failure counts a read Strava
    # never saw, and that is the deliberate direction — a cap is a ceiling, so
    # UNDER-counting overshoots it and gets every subsequent read refused (#246).
    # The cost of over-counting is bounded but real: the pre-flight refuses on
    # `today >= reads_per_day`, so a heavily over-counted day refuses every run until
    # UTC midnight — it takes ~a thousand transport failures to get there.
    charge_read! : Str => Try({}, _)
    charge_read! = |path| {
        day = Db.utc_today_days!({})
        n = reads_today!(path, day)?
        save_reads_for_day!(path, day, n + 1)
    }

    # is the allowance already spent, WITHOUT spending anything to find out? `decide` is
    # structurally unable to answer this — it is only reachable with a response in hand —
    # so a capped run used to spend a list read and a stream read to report that it had
    # none left. At the cadence stride's own advice implies that is ~190 reads a day
    # burned against an allowance that is already gone, with the counter climbing past the
    # cap all day. The day is knowable from the database with zero requests.
    day_spent! : Str => Try(Bool, _)
    day_spent! = |path| Ok(reads_today!(path, Db.utc_today_days!({}))? >= (read_limits!({})).reads_per_day)

    # takes the day rather than reading its own clock, so a caller that already has
    # one cannot compare a count against a different day than it saves against —
    # that pair disagreeing was this feature's recurring bug. Narrower than
    # "unrepresentable": other sites still read the clock; this one function just
    # cannot be the site of the disagreement.
    reads_today! : Str, I64 => Try(I64, _)
    reads_today! = |path, day_now| {
        # BOTH rows get the conservative reading. The count's Corrupt arm argues that
        # "cannot tell" must mean "may all be spent" — and the day STAMP went through
        # `config_i64!`, which folds Corrupt to 0: a stamp of 0 never equals today, so
        # the count was skipped and a full fresh allowance handed out silently. One fact
        # in two rows takes one policy: unreadable means today, and today means the
        # count is consulted.
        stored_day =
            match config_reads!(path, "strava_reads_day")? {
                Known(n) => Ok(n)
                Corrupt(v) => {
                    _ = Output.say!("cannot read the day stamp on Strava's read counter ('${v}') — treating it as today so the count still applies; `stride config set strava_reads_today 0` clears both")
                    # ...and REPAIR it, which is what makes the conservative reading affordable: a
                    # corrupt COUNT self-heals when its stamp goes stale, but a corrupt STAMP is read
                    # as today FOREVER (measured: three consecutive runs refused, a fixed point).
                    # Writing a real day keeps this run refused — the count still applies — and makes
                    # the stamp genuinely stale tomorrow.
                    _ = Db.config_set!(path, "strava_reads_day", I64.to_str(day_now))?
                    Ok(day_now)
                }
            }?
        if stored_day != day_now {
            Ok(0)
        } else {
            match config_reads!(path, "strava_reads_today")? {
                Known(n) => Ok(n)
                Corrupt(v) => {
                    # NARRATED, because the consequence is a day of refused reads and the
                    # athlete would otherwise get no signal at all. This is the one place
                    # in the codebase that deliberately breaks the "unreadable config is
                    # an error" rule, so it says so out loud rather than quietly.
                    _ = Output.say!("cannot read today's Strava read count ('${v}') — assuming the daily allowance is spent; `stride config set strava_reads_today 0` clears it")
                    Ok((read_limits!({})).reads_per_day)
                }
            }
        }
    }

    # ABSENT and UNREADABLE are different facts. Absent is 0 because it is TRUE: a
    # database that never synced has spent nothing. Unreadable is the full allowance,
    # because 0 is the most PERMISSIVE value, not the conservative one — "I cannot
    # tell how many reads were spent" conservatively means "they may all be spent".
    # Guessing 0 also ERASES the day's history on the first save and spends a second
    # full allowance inside one UTC day, every read refused by Strava; guessing the
    # cap costs one day, self-heals at midnight, and `config set strava_reads_today
    # 0` is the escape hatch.
    #
    # Clamped at 0: arg_i64 accepts negatives, and a parseable -5000 would buy MORE
    # headroom than an unparseable value, inverting the argument above. Swallowed
    # rather than raised — refusing to sync over a corrupt pacing counter is worse
    # than pacing badly — but no longer silent: see the caller.
    config_reads! : Str, Str => Try([Known(I64), Corrupt(Str)], _)
    config_reads! = |path, key|
        match Db.config_opt!(path, key)? {
            NotFound => Ok(Known(0))
            Found(v) =>
                match Metrics.arg_i64(v) {
                    Ok(n) => Ok(Known((n).max(0)))
                    Err(_) => Ok(Corrupt(v))
                }
        }

    config_i64! : Str, Str => Try(I64, _)
    config_i64! = |path, key|
        match config_reads!(path, key)? {
            Known(n) => Ok(n)
            Corrupt(_) => Ok(0)
        }

    # ...and write it back after EVERY read, not at the end of the run: reads are
    # spent at Strava the moment they happen, so a drain that dies mid-way must not
    # forget the ones it made — losing them drifts the counter UNDER the true total,
    # the direction that overshoots the cap. Two small UPDATEs against an HTTP round
    # trip is not worth optimising, and batching reintroduces the loss window.
    #
    # It writes against the day the count BELONGS to, which is not always the day it
    # is written on: a run in flight at UTC midnight used to stamp the new day with
    # the old day's total — start at 23:59 with 795 spent, cross midnight, and the
    # athlete gets 205 of tomorrow's 1000. The caller passes the day it is CURRENTLY
    # on, re-read each iteration: captured once, the crossing stamped every read
    # after midnight onto the day before, so day D+1 began already owing them.
    save_reads_for_day! : Str, I64, I64 => Try({}, _)
    save_reads_for_day! = |path, day, n| {
        Db.config_set!(path, "strava_reads_day", I64.to_str(day))?
        Db.config_set!(path, "strava_reads_today", I64.to_str(n))
    }

    read_limits! : {} => Drain.Limits
    read_limits! = |{}| {
        # stop before Strava's 100-reads-per-15-minutes window fills. There is no second
        # per-run budget: `window` is never reset inside a run, so a larger one could
        # never fire. The day gets no margin because it counts the list read directly
        # (#246); it used to be "respected by arithmetic", which assumed ten runs a day
        # and enforced nothing.
        #
        # The 5-read margin does NOT reliably absorb the list read.
        # `window` only advances in the drain's Store arm —
        # fetch_pages! never touches it, and neither do the 401/429 charges — so a first
        # run on a 2,000-activity history issues 20 list pages plus 95 stream reads inside
        # one window, against Strava's 100. That is C-1's shape one limit over: a counter
        # counting a strict subset of what the limit counts. It degrades gracefully, since
        # the 429 that follows really is a window refusal and ~15 minutes really is the
        # remedy, so it is a follow-up rather than part of #246.
        reads_per_window: env_i64!("STRIDE_READS_PER_WINDOW", 95),
        # Strava's documented daily read cap. Overridable for the same reason the window
        # is: the e2e suite drives this arm at a limit small enough to reach in a fixture.
        reads_per_day: env_i64!("STRIDE_READS_PER_DAY", 1000),
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
    # Per-run drain state: `window` = reads this run (vs the 15-min cap; never reset,
    # a run does not span windows); `stored`/`skipped` = what the reads produced.
    # `done` and `stored` are deliberately different: pacing is about READS (a 404
    # spends a read and stores a marker) while the payload reports WORK — publishing
    # `done` as `streams_fetched` reported rows that do not exist. `total` is the
    # queue length at start, for a real progress bar; nothing decrements it.
    # `day` is the UTC day the count belongs to, RE-READ at the top of each iteration
    # and reset with its count when it changes (Drain.roll_day); `today` is the
    # running count against it, as distinct from the per-run `window`.
    DrainState : { window : I64, day : I64, today : I64, stored : I64, skipped : I64, total : U64, refreshes : I64 }

    # Walk the missing-streams list once per run — walking a LIST (not re-querying
    # "next missing") means an unstorable body is skipped, not refetched forever. The
    # pacing DECISION is pure (Drain.decide, unit-tested); this is the thin effectful
    # skin. The FOUR ways a drain ends, RETURNED rather than printed, because "why
    # did it stop?" is not derivable from the counts. Two of the non-complete reasons
    # clear on the 15-minute window; `DailyCapReached` clears at UTC midnight, and
    # fifteen minutes there is an instruction that cannot succeed (#246). `stopped`
    # has exactly four arms, so a drain CANNOT report the list refusal — that arm
    # lives on Drain.SyncStop, and sync! wraps this outcome in FromDrain.
    DrainOutcome : { stored : I64, skipped : I64, pending : I64, stopped : Drain.StopReason }

    drain_streams! : Str, Str, List(I64), DrainState => Try(DrainOutcome, _)
    drain_streams! = |path, token, ids, st_in| {
        # RE-READ each iteration, not captured once: a drain can outlive UTC midnight,
        # and when it does the allowance has genuinely reset. Carrying the old day
        # advised "come back tomorrow" sixty seconds after the reset and stamped the
        # post-midnight reads onto the day before. The rule is Drain.roll_day and it is
        # pure, so both directions are pinned by expects without a fake clock.
        rolled = Drain.roll_day({ day: st_in.day, today: st_in.today }, Db.utc_today_days!({}))
        st = { ..st_in, day: rolled.day, today: rolled.today }
        match ids {
            [] => {
                bar_done!(st)
                Ok({ stored: st.stored, skipped: st.skipped, pending: pending_streams!(path)?, stopped: Complete })
            }
            [id, .. as rest] => {
                uri = "${api_base!({})}/api/v3/activities/${I64.to_str(id)}/streams?keys=time,heartrate,watts,altitude,distance&key_by_type=true"
                resp = send_bearer!(uri, token)?
                match Drain.decide({ status: Response.status(resp), window: st.window, today: st.today }, read_limits!({})) {
                    Refresh => {
                        # the 401'd read is spent too, and this arm RETRIES the same id —
                        # so the read is charged here and the retry charges its own. Two
                        # reads at Strava, two on the counter.
                        _ = save_reads_for_day!(path, st.day, st.today + 1)?
                        # Long runs outlive the ~6h access token; refresh and retry the same id.
                        # BOUNDED, like the 429 retry beside it: this arm recurses on the same id, so a
                        # persistently 401ing activity (revoked scope, private without activity:read_all)
                        # would spin forever — measured at ~113 requests/second unbounded, 4,500
                        # reads against a 1000/day cap in under a minute, which is the shape that
                        # gets an API app suspended. `decide` does not charge a 401 against `done`,
                        # so the read budget never ends it. Same token back is a real auth problem.
                        if st.refreshes >= max_refreshes {
                            # no bar_done! here: this propagates, and the boundary reporter
                            # closes the bar on the way out. Closing twice leaves a stray
                            # blank line on stderr.
                            Err(HttpStatus(401, "refreshed the token twice and Strava still returned 401 for this activity — the credential is working, so this is likely a missing activity:read_all scope or a clock skew rather than a dead login"))
                        } else {
                            fresh = get_valid_token!(path)?
                            if fresh == token {
                                Err(HttpStatus(401, "token refresh did not help — re-run `stride auth`"))
                            } else {
                                bar_done!(st)
                                Output.say!("  access token expired — refreshed, continuing...")?
                                # `today` advances with the charge above. Charging the row
                                # and not the running total would leave `decide` comparing
                                # a stale count on the retry — the disk and the loop would
                                # disagree about how much of the day is left.
                                drain_streams!(path, fresh, ids, { ..st, today: st.today + 1, refreshes: st.refreshes + 1 })
                            }
                        }
                    }
                    # A 429 STOPS the run. It does not sleep: that made a routine sync
                    # block ~30 minutes in the foreground, measured on a two-activity
                    # queue. The rows already stored are durable and `resumable` says
                    # there is more, so the honest move is to hand the terminal back.
                    # the daily allowance, recognised from the 429 rather than only from
                    # our own count — see Drain.decide. Same stop, different remedy.
                    DailyCapReached => {
                        # the 429'd read is a REAL read. It never reaches the Store arm, so
                        # without this the counter sits below the cap while Strava is
                        # already refusing — and since #246's whole comparison is
                        # `today >= reads_per_day`, an undercount makes it false at exactly
                        # the moment it needs to be true.
                        _ = save_reads_for_day!(path, st.day, st.today + 1)?
                        bar_done!(st)
                        Ok({ stored: st.stored, skipped: st.skipped, pending: pending_streams!(path)?, stopped: DailyCapReached })
                    }
                    RateLimited => {
                        _ = save_reads_for_day!(path, st.day, st.today + 1)?
                        bar_done!(st)
                        Ok({ stored: st.stored, skipped: st.skipped, pending: pending_streams!(path)?, stopped: RateLimited })
                    }
                    Store({ window, today, after }) => {
                        save_reads_for_day!(path, st.day, today)?
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
                            # the DAILY allowance, which is a different stop with a
                            # different remedy: the window clears in fifteen minutes, this
                            # one clears at UTC midnight.
                            DayFull => {
                                bar_done!(st)
                                Ok({ stored: counted.stored, skipped: counted.skipped, pending: pending_streams!(path)?, stopped: DailyCapReached })
                            }
                            Continue =>
                                drain_streams!(path, token, rest, { ..st, window, today, stored: counted.stored, skipped: counted.skipped })

                        }
                    }
                }
            }
        }
    }
    per_page = 100

    # acc carries the re-listed total AND the new/updated split (#112): the first is
    # training frequency, the second is what happened this run.
    # A 429 on the LIST stops the run the way a 429 on a stream does (#235): pages
    # already upserted are kept and reported, `rate_limited` rides the accumulator,
    # and the caller reports a successful partial run. Propagating instead made one
    # upstream condition behave two ways in one invocation — exit 1 on the list, a
    # success envelope on a stream — breaking every cron wrapper on the run that
    # issues the most list reads.
    fetch_pages! : Str, Str, Str, I64, U64, { relisted : U64, new_n : U64, updated_n : U64, rate_limited : Bool } => Try({ relisted : U64, new_n : U64, updated_n : U64, rate_limited : Bool }, _)
    fetch_pages! = |path, token, after_param, stamp, page, acc| {
        page_str = (page).to_str()
        per_str = (per_page).to_str()
        uri = "${api_base!({})}/api/v3/athlete/activities?per_page=${per_str}&page=${page_str}${after_param}"
        # page 1 only, and BEFORE the request: the per-page lines below report pages that
        # already landed, so a stalled first request would otherwise print nothing at all.
        # Later pages need no such line — by then the reader has seen output.
        _ = if page == 1 { Output.say!("fetching activity list…")? } else { {} }
        # COUNTED, because Strava counts it: the list and the streams draw on ONE read
        # limit, and counting only the streams made stride's number a strict subset of
        # Strava's — Strava reaches 1000 first, answers 429, the drain stops on
        # RateLimited, the counter freezes below the cap, and DayFull becomes dead code
        # (the last ~11 reads of the allowance were unspendable).
        _ = charge_read!(path)?
        body =
            match get_bearer!(uri, token) {
                Ok(b) => b
                # Only 429. Every other status propagates, including a 401 — this function
                # has NO refresh arm, and does not need one: get_valid_token! refreshes
                # proactively at run start with a 60-second margin, and the listing takes
                # seconds where the drain takes fifteen minutes, so a mid-list expiry is not
                # the case drain_streams!'s arm was built for. A 500 is not something to
                # report as a successful partial run.
                Err(HttpStatus(429, _)) => return Ok({ ..acc, rate_limited: True })
                Err(e) => return Err(e)
            }
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
        next = { ..acc, relisted: total, new_n: counts.new_n, updated_n: counts.updated_n }
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
        # NO metrics invalidation here, deliberately: sync re-lists a rolling 30-day
        # window and cannot tell an edit from a no-op, so deleting here wiped a month of
        # metrics every run. Staleness is detected in `analyze` by comparing the stored
        # activity inputs against the row as it stands (same contract as ftp_used) —
        # stateless, self-correcting, and free since analyze already runs the predicate.
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
