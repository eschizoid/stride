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
        # prose on stdout in JSON mode, so a caller that survived the prompt collision
        # still got something `jq` cannot read. `init` had exactly this and was fixed to
        # `Output.out!` on the grounds that "EVERY machine response is a versioned
        # envelope" is only true if the setup steps honor it too; auth is the other setup
        # step, and the command table publishing six machine-readable error codes for it
        # is a promise that its stdout is parseable.
        #
        # `expires_at` rather than a bare success flag: it is the one fact a caller can act
        # on (when to expect the refresh), it is already in hand, and a payload whose only
        # field restates the exit code carries nothing. Tokens themselves never appear —
        # the same rule `config get` enforces, for the same reason.
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
                # BEFORE the first request. A run that STARTS with the day's allowance spent
                # has nothing it can do and costs nothing to find out — it reports the same
                # stop and the same remedy as one that spends its last read.
                #
                # "A run", unqualified, was too strong and review caught it: the LIST can
                # push the counter past the cap mid-run (up to one read per page beyond it),
                # and the drain then spends exactly one wasted stream read before `decide`
                # stops it. One read is not worth a branch, but the sentence claimed a
                # property of every run and only has it for runs that start spent.
                #
                # That last clause was measured FALSE and is only true again because of the
                # Render fix that followed. This arm reaches Render with an empty queue by
                # construction, and `FromDrain(_)` used to render nothing at all there — so
                # a capped run printed "synced 0 new, 0 updated, fetched streams for 0" and
                # exited 0, having made no request and with none possible for the rest of
                # the day. Same stop token, no remedy, and a sentence implying a successful
                # quiet sync. The claim and the behaviour now agree; they did not when this
                # sentence was written.
                #
                # `pending_streams!` rather than 0, so `resumable` and the queue count are
                # true: the work is still outstanding, it just cannot be done today.
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
                    # BOUND once, then used twice. The payload's string and the screen's
                    # tag must describe the same run, and writing the tag out at both
                    # spots made that a coincidence rather than a fact.
                    # (Above the annotation, not between it and the body: Roc reads a
                    # separated annotation as a declaration with no value.)
                    # WHICH limit refused the list? The drain's 429 arm asks this and the
                    # list's did not, so "run `stride sync` again in ~15 minutes" survived
                    # on the other endpoint that can 429 — the same defect #246 opened on,
                    # one endpoint over. Review measured it with the counter one below the
                    # cap, which is exactly where a run lands after the list read.
                    #
                    # THE FOLD WAS THE MISTAKE, and two rounds of review were spent
                    # narrowing what it cost before the answer turned out to be "don't".
                    #
                    # Round 1 of this comment said `resumable` and the counts carried the
                    # lost fact. Measured false — `resumable` is True on both paths and
                    # `synced: 0` is indistinguishable from a complete listing over an
                    # empty window, the exact ambiguity #235 exists to remove. Round 2
                    # accepted the loss and wrote it down honestly. Round 3 measured what
                    # "accepted" actually meant on screen: `FromDrain(_)` renders only when
                    # `pending_streams > 0`, so on the empty queue this stop reaches by
                    # construction, the human line went EMPTY. Not a degraded sentence — no
                    # sentence. The same fixture with the counter at 0 printed the full
                    # #235 warning; at 9 it printed nothing.
                    #
                    # So it gets its own tag. Both facts are load-bearing and neither is a
                    # nicety: the listing is incomplete (rows are missing) and the remedy is
                    # tomorrow (fifteen minutes buys nothing). A tag that carries one of
                    # them forces Render to guess the other, and Render guessing from
                    # `pending_streams` is what this whole type was introduced to stop.
                    rl_stop = if day_spent!(path)? ListDailyCapReached else ListRateLimited
                    rl_payload : { synced : U64, new_activities : U64, updated_activities : U64, pruned : U64, streams_fetched : I64, streams_skipped : I64, pending_streams : I64, stopped : Str, resumable : Bool }
                    rl_payload = { synced: counts.relisted, new_activities: counts.new_n, updated_activities: counts.updated_n, pruned: 0, streams_fetched: 0, streams_skipped: 0, pending_streams: pending, stopped: Drain.sync_stopped_label(rl_stop), resumable: True }
                    Output.out!(rl_payload, |p| Render.sync_screen(p, rl_stop, all))
                } else {
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
    # Pacing counts OUR OWN reads BY CHOICE, so it never depends on an endpoint sending
    # rate-limit headers. Strava's limits are 100 reads per 15 minutes and 1000 per day;
    # a run fills one window and stops, and 429 is a backstop for when our count and
    # Strava's disagree, not the mechanism.
    # ── test seams, same species as STRIDE_API_BASE ─────────────────────
    # These three constants made two of the three StopReason values untestable: reaching
    # a stop reason honestly costs a full 95-read window
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

    # reads already made TODAY, in UTC. Two rows rather than one: the count and the day
    # it belongs to. Reading them together is what makes the reset free — a `strava_reads_day`
    # that is not today means the count is stale, so it is zero, and nothing has to run at
    # midnight to make that true.
    #
    # Absent keys are zero rather than an error. A database that has never synced has no
    # count, which is not a fault. The mechanism is `Db.config_opt!`, which maps
    # `NoRowsReturned` to `NotFound` — an earlier version of this sentence credited
    # `query_many` returning an empty list, which is a different function this path never
    # calls.

    # ...and CHARGE one. One read against today's allowance, wherever it is spent from. The
    # drain has its own running counter threaded through DrainState because `decide` needs
    # the value to compare; the listing has no such loop, so it charges directly.
    #
    # Charged BEFORE the request, not after, and the two counters therefore disagree about
    # what a read is: the drain charges from a response it holds, this charges from an
    # intent. A transport failure or a timeout counts a read Strava never saw. That is the
    # deliberate direction — a cap is a ceiling, so under-counting overshoots it and gets
    # every subsequent read refused by Strava, which is the failure #246 exists to prevent.
    #
    # The cost of over-counting is not "a little of the allowance", and that wording was too
    # soft for a branch this one keeps being bitten on: the pre-flight refuses on
    # `today >= reads_per_day`, so a sufficiently over-counted day refuses EVERY run until
    # UTC midnight. It needs on the order of a thousand transport failures in a day to get
    # there, so it is not a practical concern — but it is a different KIND of cost than the
    # sentence implied.
    #
    # It also means the drain's "stride's count can drift under Strava's" is a statement
    # about the drain, which charges from a response it holds, and not about this function,
    # which charges from an intent.
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

    # takes the day rather than reading its own clock, so a caller that already has one
    # cannot end up comparing a count against a different day than it saves against. That
    # pair disagreeing is the bug this feature spent two rounds on.
    #
    # It does NOT make the general problem unrepresentable, and a previous version of this
    # comment claimed it did — along with claiming it REMOVES a clock read. Neither is
    # true: `Db.utc_today_days!` still has several call sites, `charge_read!` reads the
    # clock once per list page, and the drain now reads it once per iteration on purpose
    # (Drain.roll_day). What this signature buys is narrower and worth having anyway — this
    # one function cannot be the site of the disagreement.
    reads_today! : Str, I64 => Try(I64, _)
    reads_today! = |path, day_now| {
        # BOTH rows get the conservative reading, and an earlier version gave them
        # opposite ones. The count's Corrupt arm below argues at length that "I cannot tell
        # how many reads have been spent" must mean "they may all be spent" — and the day
        # STAMP went through `config_i64!`, which folds Corrupt to 0. A stamp of 0 never
        # equals today, so the count was skipped entirely and a full fresh allowance handed
        # out, silently. Measured: `strava_reads_day=garbage` with `strava_reads_today=1000`
        # became day=20690, count=1 after one sync. A thousand reads of history erased and
        # a second allowance spent inside one UTC day — verbatim the outcome the paragraph
        # below calls unacceptable, reached through the row it did not cover.
        #
        # They are one fact stored in two rows, so they take one policy: unreadable means
        # today, and today means the count is consulted rather than skipped.
        stored_day =
            match config_reads!(path, "strava_reads_day")? {
                Known(n) => Ok(n)
                Corrupt(v) => {
                    _ = Output.say!("cannot read the day stamp on Strava's read counter ('${v}') — treating it as today so the count still applies; `stride config set strava_reads_today 0` clears both")
                    # ...and REPAIR it, which is what makes the conservative reading
                    # affordable. `config_reads!`'s argument for guessing the cap is that it
                    # "costs one day, self-heals at UTC midnight" — true of a corrupt COUNT,
                    # whose stamp goes stale on its own, and false of a corrupt STAMP, which
                    # is read as today FOREVER. Measured: three consecutive runs all refused,
                    # all writing nothing, a fixed point with narration as the only exit.
                    #
                    # Writing a real day keeps this run refused — the count still applies —
                    # and makes the stamp genuinely stale tomorrow, so the midnight
                    # self-heal the sibling comment promises is true for both rows.
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

    # ABSENT and UNREADABLE are different facts and get different answers, which an
    # earlier version of this got backwards by folding both to 0.
    #
    # Absent is 0 because it is TRUE: a database that has never synced has spent nothing.
    #
    # Unreadable is the full allowance, because 0 is the most PERMISSIVE value this
    # function can return, not the conservative one — it asserts the athlete has spent
    # nothing and hands out the largest grant available. The conservative reading of "I
    # cannot tell how many reads have been spent" is "they may all be spent". And the cost
    # of guessing 0 is not one window: the first save overwrites the corrupt row with this
    # run's own count, so the day's history is ERASED and a second full allowance is spent
    # inside one UTC day — every read of it refused by Strava. Guessing the cap costs one
    # day, self-heals at UTC midnight, and `stride config set strava_reads_today 0` is a
    # one-command escape hatch.
    #
    # Clamped at 0 because arg_i64 accepts negatives and `config set` will take them: a
    # parseable -5000 would otherwise buy MORE headroom than an unparseable value, which
    # inverts the whole argument above.
    #
    # Still swallowed rather than raised — refusing to sync over a corrupt pacing counter
    # is a worse answer than pacing badly — but it is no longer silent: see the caller.
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

    # ...and write it back, after EVERY read rather than at the end of the run. Reads are
    # spent at Strava the moment they happen, so a drain that dies mid-way — a refresh
    # that fails, a 5xx, a killed process — must not forget the ones it already made. A
    # save-at-exit version loses exactly the reads a crashed run spent, and the counter
    # then drifts UNDER the true total, which is the direction that overshoots the cap.
    #
    # Two small UPDATEs against an HTTP round trip is not a cost worth optimising, and
    # the alternative — batching — reintroduces the window of loss this exists to close.
    #
    # This paragraph used to sit on a `save_reads_today!` wrapper that had no callers
    # anywhere in src/ or tests/ — the rationale for the live design documented on a
    # function that never ran, and a wrapper that read its own clock, which is the pattern
    # the comment above reads_today! claims was designed out. Deleted; the argument belongs
    # here, on the function that does the writing.
    #
    # ...and it writes against the day the count BELONGS to, which is not always the day it
    # is written on. A run in flight at UTC midnight used to stamp the new day with the old
    # day's total: start at 23:59 with 795 spent, cross midnight, and the athlete gets 205
    # of tomorrow's 1000 and is told to come back tomorrow all day on a day they spent
    # almost nothing.
    #
    # Worse, it was the only reachable trigger AT THE TIME. That was true while stride
    # counted stream reads only: the count sat below Strava's, Strava refused first, and the
    # 429 arm stopped the drain before the Store arm could test the day. Once `charge_read!`
    # began counting the LIST read, `DayFull` became reachable on the correct path with no
    # 429 anywhere — it is the arm the e2e mutation kill fires on. The same premise was
    # corrected in Drain.decide's comment and this copy of it was missed, which is the third
    # time a sentence on this branch has outlived the change that falsified it.
    #
    # The caller passes the day it is CURRENTLY on, re-read each iteration rather than
    # captured once, and that changed after review. Captured once, a crossing stamped every
    # read AFTER midnight to the day before it — so the run advised "come back tomorrow" at
    # 00:01 when the allowance had reset sixty seconds earlier, and day D+1 began already
    # owing the reads it had unknowingly spent. The comment that stood here said "the reads
    # before it belong to the day they were spent on", which is true of the reads before the
    # crossing and false of the ones after, and the ones after are the half the sentence was
    # about. Both halves are the same defect #246 exists to remove: advice that cannot
    # succeed.
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
        # The 5-read margin does NOT reliably absorb the list read, and an earlier version
        # of this comment said it did. `window` only advances in the drain's Store arm —
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
    # Per-run drain state: `window` = reads
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
    # `day` is the UTC day the count belongs to, RE-READ at the top of each drain iteration
    # and reset with its count when it changes (Drain.roll_day). `today` is the running
    # count of reads spent against it — the DAILY allowance, persisted, as distinct from
    # `window`, which is the per-run count against the 15-minute limit and lives only for
    # the run.
    #
    # This said "captured ONCE, before the first request, and never recomputed" through two
    # rounds, and it was wrong in three ways at once. It was not captured before the first
    # request — `fetch_pages!` has already issued every list request by then, so it is
    # before the first STREAM request. Capturing it once made a run crossing UTC midnight
    # advise "come back tomorrow" a minute after the allowance reset. And it stamped the
    # reads spent after the crossing onto the day before, so the new day started already
    # owing them. The sentence it replaced — that recomputing per SAVE caused the midnight
    # bug — was true of recomputing at the wrong moment, and got generalised into never
    # recomputing at all.
    DrainState : { window : I64, day : I64, today : I64, stored : I64, skipped : I64, total : U64, refreshes : I64 }

    # Walk the missing-streams list once per run. Walking a LIST (not re-querying
    # "next missing") means an unstorable body is skipped, not refetched forever.
    # The pacing DECISION is pure (Drain.decide, unit-tested); this is the thin
    # effectful skin that dispatches on it: fetch, then act.
    # The FOUR ways a drain ends, RETURNED rather than printed, because "why did it
    # stop?" is not derivable from the counts. (A further exit exists and is deliberately
    # not an outcome: a token refresh that does not help raises Err(HttpStatus(401, …)),
    # which is a failure, not a stopping reason.) Two of the three non-complete reasons
    # clear on the 15-MINUTE window; `DailyCapReached` clears at UTC midnight, and telling
    # the athlete fifteen minutes there is an instruction that cannot succeed. That
    # distinction is the whole of #246, and this comment used to assert its opposite —
    # "both mean ~15 minutes, not tomorrow" — directly above the type.
    #
    # `stopped` is a Drain.StopReason tag with exactly four arms, so the compiler
    # enforces the set here: a drain CANNOT report the list refusal that also ships in
    # the payload's `stopped` field, because that arm lives on Drain.SyncStop and sync!
    # wraps this outcome in FromDrain on the way out. Drain.sync_stopped_label is the
    # one place either becomes the string that ships.
    DrainOutcome : { stored : I64, skipped : I64, pending : I64, stopped : Drain.StopReason }

    drain_streams! : Str, Str, List(I64), DrainState => Try(DrainOutcome, _)
    drain_streams! = |path, token, ids, st_in| {
        # RE-READ each iteration, not captured once for the run. A drain can outlive UTC
        # midnight — a first sync of a large history takes many minutes — and when it does
        # the allowance has genuinely reset. Carrying the old day past that point advised
        # "come back tomorrow" on a day that had already started, sixty seconds after the
        # reset, and stamped the reads spent after midnight onto the day before so the new
        # day began already owing them.
        #
        # The rule is Drain.roll_day and it is pure, so both directions are pinned by
        # expects rather than by a fixture that would need a fake clock. One clock read per
        # stream read, against an HTTP round trip.
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

    # acc carries the re-listed total AND the new/updated split (#112): the first is a
    # function of training frequency, the second is what actually happened this run.
    # The `narrate` and `classify` flags are gone with #232. They existed so `backfill`
    # could pass False, False; `sync` is the only caller now and always wants both, so
    # they were two dead parameters and a branch nothing took.
    # A 429 on the LIST stops the run the way a 429 on a stream does (#235): the pages
    # already upserted are kept and reported, `rate_limited` rides out in the accumulator,
    # and the caller reports it as a successful partial run rather than an error.
    #
    # It used to propagate. That made the same upstream condition behave two ways inside
    # one invocation — a hard exit 1 if it landed on the list, a success envelope with
    # `stopped: "rate_limited"` and exit 0 if it landed twenty lines later on a stream —
    # and the first of those breaks every cron and shell wrapper for a run that did its
    # job up to the cap. Since #232 made `sync` the first-run command too, it also aborted
    # the run that issues the most list reads.
    #
    # Partial progress is REPORTED, not just kept. `fetch_pages!` upserts page by page and
    # `last_sync_epoch` is only stamped after a complete list, so the work self-heals on
    # the next run — but a caller that is told nothing cannot tell a rate-limited partial
    # from a run that found nothing. That was the same complaint the drain's boundary
    # reporter fixed, with no equivalent on this side.
    fetch_pages! : Str, Str, Str, I64, U64, { relisted : U64, new_n : U64, updated_n : U64, rate_limited : Bool } => Try({ relisted : U64, new_n : U64, updated_n : U64, rate_limited : Bool }, _)
    fetch_pages! = |path, token, after_param, stamp, page, acc| {
        page_str = (page).to_str()
        per_str = (per_page).to_str()
        uri = "${api_base!({})}/api/v3/athlete/activities?per_page=${per_str}&page=${page_str}${after_param}"
        # page 1 only, and BEFORE the request: the per-page lines below report pages that
        # already landed, so a stalled first request would otherwise print nothing at all.
        # Later pages need no such line — by then the reader has seen output.
        _ = if page == 1 { Output.say!("fetching activity list…")? } else { {} }
        # COUNTED, because Strava counts it. The list and the streams draw on ONE read
        # limit, and counting only the streams made stride's number a strict subset of
        # Strava's — always low, never equal. That is not a rounding error: it means
        # Strava reaches 1000 first and answers 429, the drain stops on RateLimited
        # without ever entering the Store arm, the counter freezes below the cap, and
        # DayFull becomes unreachable. Review measured the whole chain, and with the
        # defaults the last ~11 reads of the allowance were unspendable while the daily
        # arm was dead code.
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
