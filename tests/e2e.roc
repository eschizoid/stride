app [Context, program] {
    pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.15.0/HcMFsVT26qeMvqWtG5rfNhVMWjceYbKh1An4uYpheBVW.tar.zst",
    http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

# The whole native-Roc test harness in ONE basic-webserver app. `E2E_MODE` picks a role:
#   • (default / "e2e") run the offline check suite in init!, then exit
#   • "sync"            drive the real sync path (token refresh + activity/stream pull)
#                       against a running mock, then exit
#   • "skips"           drive the undecodable-stream skip path against a mock serving one
#   • "stops"           drive the budget_reached / rate_limited stop reasons
#   • "mock"            serve the four Strava endpoints the drivers hit, and listen
# One binary, FIVE roles — `just e2e` runs the offline suite; `just e2e-sync` starts three
# mock instances and points each driver at the one it needs.
#
# It shells out to the built `stride` binary plus `sqlite3`/`jq`/`mktemp`/`date`/`awk`
# via Cmd. It deliberately does NO Roc-side JSON DECODING: every value assertion
# extracts its field with `jq` in the same shell pipeline (`stride … | jq -r …`),
# because deriving a Roc `Json.parse` decoder per response shape triggers the
# compiler's SpecConstr blow-up (roc-lang/roc#10469) and stalls the build — one
# decoder builds in ~2s, a dozen never finish. jq extraction keeps the harness
# building in seconds while staying a native Roc program. (Same reason there's no
# `import pf.Sqlite`: its closure-in-record decoders trip the same bug.)
#
# WHY basic-webserver (not basic-cli): the offline suite fires MANY hundreds of
# subprocess spawns, and grows with every check added (it was ~350 when this was
# written and is well past that now -- which is why the number is not quoted).
# basic-cli's host loses a child's exit code intermittently under that volume
# (FailedToGetExitCode), which the harness reads as an empty result and a spurious
# failure (~2/3 of runs). basic-webserver's exec host reaps children cleanly (proven
# 300/300). So the suite runs every check in init! and exits WITHOUT ever listening;
# only "mock" mode actually serves (via respond!).
#
# Binary under test: $STRIDE_BIN (default ./stride). grep-style checks -> Str.contains on
# raw output; numeric/structural asserts -> jq field extraction + Roc comparison. Pure Roc
# (plus sqlite3/jq/curl CLIs); no other runtime.

import pf.Stdout
import pf.Cmd
import pf.OsStr
import pf.Env
import pf.Server
import pf.Sleep
import http.Response

# `tz` rides on Ctx so every scenario that touches the clock reads the SAME zone the
# dates were computed in. A second literal is exactly how #200 got in.
Ctx : { bin : Str, home : Str, db : Str, today : Str, d1 : Str, d2 : Str, tz : Str }

Context : {}
program = { init!, respond!, shutdown! }

# Run the entire suite in init!, then exit — the server never listens. Exit 0 on
# all-pass, 1 on the first failed check (which run_all! surfaces as an Err).
init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64), ..])
init! = ||
    match env_or!("E2E_MODE", "e2e") {
        # serve the mock Strava API (the sync test's counterpart); listen + serve
        "mock" => {
            port = match U16.from_str(env_or!("MOCK_PORT", "8799")) {
                Ok(p) => p
                Err(_) => 8799
            }
            Ok({ config: Server.default_config.with_listen({ host: "127.0.0.1", port }), context: {} })
        }
        # drive the sync integration test against a running mock, then exit
        "sync" =>
            match run_sync!() {
                Ok(_) => Err(Exit(0))
                Err(_) => Err(Exit(1))
            }
        # drive the undecodable-stream skip path against a mock started with E2E_BAD_STREAM=1
        "skips" =>
            match run_skips!() {
                Ok(_) => Err(Exit(0))
                Err(_) => Err(Exit(1))
            }
        # drive the budget_reached / rate_limited stop reasons (E2E_EXPECT_RATE_LIMIT
        # picks which, against a mock started with the matching E2E_RATE_LIMIT)
        "stops" =>
            match run_stops!() {
                Ok(_) => Err(Exit(0))
                Err(_) => Err(Exit(1))
            }
        # default: run the offline suite, then exit (never listens)
        _ =>
            match run_all!() {
                Ok(_) => Err(Exit(0))
                Err(_) => Err(Exit(1))
            }
    }

# ── mock mode: serve the four Strava endpoints sync/auth/ftp use ─────────────
# Deterministic fixtures; page 2+ is empty so fetch_pages! terminates. Routing
# matches the reconstructed path?query, as the old bw-0.13.1 mock matched req.uri.
respond! : Server.Request, Context => Try(Server.Outcome, [ServerErr(Str), ..])
respond! = |req, _ctx| {
    uri =
        match req.target() {
            Resource({ raw_path, raw_query }) =>
                match raw_query {
                    Present(q) => "${raw_path}?${q}"
                    Absent => raw_path
                }
            _ => ""
        }

    if Str.contains(uri, "/oauth/token") {
        if env_or!("E2E_ROTATING_TOKEN", "") == "1" {
            # A NEW access token every call, already expired. Models a provider that
            # rotates on every refresh — which real Strava does. Without it the drain's
            # refresh arm exits on `fresh == token` after one call and the retry BOUND is
            # never reached, so a test can pin termination while the counter it exists to
            # prove is dead code. Review demonstrated exactly that: with the bound removed
            # the suite stayed green here, and 700 token requests in 12s against a
            # rotating mock.
            #
            # `expires_at: 0` is the load-bearing half — a future expiry lets
            # get_valid_token! serve from cache and the arm is never re-entered.
            stamp = Str.trim(sh!("date +%s%N"))
            body = "{\"access_token\":\"rot-${stamp}\",\"refresh_token\":\"mock-refresh\",\"expires_at\":0}"
            Ok(mock_json(body))
        } else {
            body =
                \\{"access_token":"mock-access","refresh_token":"mock-refresh","expires_at":9999999999}
            Ok(mock_json(body))
        }
    } else if Str.contains(uri, "/api/v3/athlete/activities") {
        # 429 on the LISTING (#235). Nothing exercised this before — the rate-limit arm
        # below refuses a STREAM read only, which is how the list path could abort the run
        # at exit 1 while a 429 twenty lines later stopped gracefully at exit 0, with no
        # test able to tell the two apart.
        if env_or!("E2E_LIST_RATE_LIMIT", "") == "1" {
            Ok(Server.respond(Response.from_status(429).with_body(Str.to_utf8("rate limited"))))
        } else if env_or!("E2E_LIST_RATE_LIMIT", "") == "2" {
            # A FULL page, then a refusal. `=1` refuses page one, so nothing is ever
            # upserted and the partial-progress half of this feature — the pages already
            # committed being carried out and reported — has nothing to report. Review
            # showed that made the carry mechanism unpinned: discarding the accumulator
            # outright passed every driver, which is exactly what the code comment forbids.
            #
            # per_page is 100, and fetch_pages! only recurses when a page comes back FULL,
            # so every page before the refusal has to be exactly 100 rows.
            #
            # TWO full pages, not one, and that is the whole point of the fixture. With a
            # single page, `synced`, `new_activities`, `pending_streams`, the row count and
            # per_page are ALL 100 — and page one must equal per_page for the recursion to
            # happen at all, so no single-page fixture can separate them. Review proved the
            # cost: replacing the running total `acc.relisted + got` with just `got` — which
            # ships the LAST page's count instead of the sum — survived this driver and every
            # other one, because every other fixture is single-page too. On a real three-page
            # account that reports `synced: 100` for 250 activities. Two pages makes the
            # answer 200, which is neither per_page nor any one page's count, so only a
            # running total produces it.
            #
            # `&page=1` with a boundary, NOT `page=1`. The URI is `?per_page=100&page=N`,
            # and "per_page=100" CONTAINS the substring "page=1" — so the loose test matched
            # every page, this arm served a full page forever, and fetch_pages! recursed
            # until the run produced nothing at all. "page=10" and "page=100" are the other
            # side of the same trap, and the arm below had the identical bug until this
            # commit: latent there only because its page returns 2 rows, under per_page, so
            # the recursion stopped after one page whatever the test said.
            if page_is(uri, 1) {
                Ok(mock_json(mock_page_one))
            } else if page_is(uri, 2) {
                Ok(mock_json(mock_page_two))
            } else {
                Ok(Server.respond(Response.from_status(429).with_body(Str.to_utf8("rate limited"))))
            }
        } else if page_is(uri, 1) {
            body =
                \\[{"id":501,"name":"Mock Power Ride","sport_type":"Ride","start_date_local":"2026-07-28T10:00:00Z","moving_time":3600,"distance":30000.0,"total_elevation_gain":100.0,"average_watts":200.0,"weighted_average_watts":205.0},
                \\ {"id":502,"name":"Mock HR Row","sport_type":"Rowing","start_date_local":"2026-07-29T10:00:00Z","moving_time":1800,"distance":5000.0,"total_elevation_gain":0.0,"average_heartrate":150.0}]
            Ok(mock_json(body))
        } else {
            Ok(mock_json("[]"))
        }
    } else if Str.contains(uri, "/streams") {
        if Str.contains(uri, "/activities/501/") and env_or!("E2E_HTTP500", "") == "1" {
            # 500 on 501 ONLY, so the drain reaches store_stream_response!'s `else` arm and
            # raises HttpStatus(500) into the generic strava_error boundary — a production
            # path nothing else here exercises (the other drivers cover 401, 429 and an
            # undecodable body). 502 drains first (ORDER BY start_local DESC) and stores its
            # marker, so the error arrives with work already committed, which is the whole
            # point: it is what makes "everything already stored is saved" a claim rather
            # than a platitude. Salvaged from #225.
            Ok(Server.respond(Response.from_status(500).with_body(Str.to_utf8("boom"))))
        } else if Str.contains(uri, "/activities/501/") and env_or!("E2E_STREAM_401", "") == "1" {
            # 401 forever on 501 ONLY, so the drain enters the token-refresh arm. That arm
            # recurses on the SAME id with unchanged state; before #232 bounded it, review
            # measured ~113 requests per second with no terminal state at all — 4,500 reads
            # against a 1000/day cap in under a minute. 502 drains first (ORDER BY
            # start_local DESC) and stores its marker, so a bounded run still did work.
            Ok(Server.respond(Response.from_status(401).with_body(Str.to_utf8("unauthorized"))))
        } else if Str.contains(uri, "/activities/501/") and env_or!("E2E_RATE_LIMIT", "") == "1" {
            # 429 forever on 501 ONLY. It has to be 501 rather than 502: missing_ids is
            # ORDER BY start_local DESC, so 502 drains first and stores its marker, and
            # the resulting streams_fetched:1 is what proves the counters survived the
            # Backoff rounds. A mock that 429s everything reports 0 and proves nothing.
            Ok(Server.respond(Response.from_status(429).with_body(Str.to_utf8("rate limited"))))
        } else if Str.contains(uri, "/activities/501/") {
            # a realistic 1 Hz stream (1300 samples, constant 200W, HR sawtooth 120–179): long enough that
            # best_20min_w -> derived FTP 190 -> TSS ~110.8. See mock_power_stream_json.
            Ok(mock_json(mock_power_stream_json(1300, 200)))
        } else if env_or!("E2E_BAD_STREAM", "") == "1" {
            # 200 with a body that is NOT UTF-8 — store_stream_response! returns
            # SkippedNonUtf8 and writes no row, so the id stays pending and retries
            # next run. This is the only way to reach `complete` with pending > 0,
            # which is the state `resumable` exists for (#218). Served by a SECOND
            # mock instance so the 404-marker fixture above stays untouched.
            Ok(mock_bad_utf8)
        } else {
            # 404 = "no streams recorded" — exercises the {} marker path
            Ok(mock_not_found("{}"))
        }
    } else if Str.contains(uri, "/api/v3/athlete") {
        # PUT ftp update (and GET athlete) — echo success
        body =
            \\{"id":1,"ftp":243}
        Ok(mock_json(body))
    } else {
        Ok(mock_not_found("not found"))
    }
}

mock_json : Str -> Server.Outcome
mock_json = |body|
    Server.respond(
        Response.from_status(200)
        .add_header("Content-Type", "application/json")
        .with_body(Str.to_utf8(body)),
    )

mock_not_found : Str -> Server.Outcome
mock_not_found = |body|
    Server.respond(Response.from_status(404).with_body(Str.to_utf8(body)))

# a 200 whose body is not valid UTF-8 (a lone 0xff can never appear in UTF-8).
# Raw bytes deliberately — Str.to_utf8 cannot express this, which is the point.
mock_bad_utf8 : Server.Outcome
mock_bad_utf8 =
    Server.respond(
        Response.from_status(200)
        .add_header("Content-Type", "application/json")
        .with_body([0xff, 0xfe, 0xff, 0xfe]),
    )

shutdown! : Server.ShutdownReason, Context => Try({}, [Exit(I64), ..])
shutdown! = |_reason, _ctx| Ok({})

run_all! : () => Try({}, _)
run_all! = || {
    reset_checks!({})?
    reset_sqlite_errors!({})
    bin = env_or!("STRIDE_BIN", "./stride")
    home = need("mktemp -d", Str.trim(sh!("mktemp -d")))?
    # Anchor the harness to the SAME clock the binary will use. These used to be
    # computed with `date -u` while the fixture configured `timezone America/Chicago`.
    # The first `config set timezone` in b_config_ftp! opened a disagreement, but its own
    # DELETE closed it again before any date check ran; what persisted was
    # b_seed_analyze!'s `validate!("config set timezone …")`, after which every remaining
    # date check compared a UTC harness date against a Chicago binary. Between 00:00 and
    # 05:00 UTC that is a whole day: `analyze` regenerates daily_load out to the BINARY's
    # today, which is a day behind the harness's, so the series comes up one row short
    # (#200). CI only saw it when a run landed in that window -- five hours under CDT,
    # six under CST.
    tz = "America/Chicago"
    today = need("date +%F", Str.trim(sh!("TZ=${tz} date +%F")))?
    d1 = need("date -3d", Str.trim(sh!("TZ=${tz} date -v-3d +%F 2>/dev/null || TZ=${tz} date -d '3 days ago' +%F")))?
    d2 = need("date -1d", Str.trim(sh!("TZ=${tz} date -v-1d +%F 2>/dev/null || TZ=${tz} date -d '1 day ago' +%F")))?
    ctx = { bin, home, db: "${home}/.stride/db.sqlite", today, d1, d2, tz }
    b_init_config!(ctx)?
    # Pin the sandbox clock to the same zone the dates above were computed in, BEFORE any
    # date-dependent check runs. b_config_ftp! sets it too, at its "config set emits the
    # JSON envelope" check, for its own assertions. Nothing between here and there is
    # date-dependent TODAY, and the reason is worth stating because two reviews got it
    # wrong in opposite directions: the three analyze calls in that span all run before
    # b_seed_analyze! seeds an activity, and with no parseable day row analyze returns at
    # `List.first(valid_days)` without ever calling Db.local_today_days!. So this pin is
    # defence in depth rather than a fix -- it means a date check ADDED after it inherits
    # a zoned binary rather than a UTC one. Two windows are deliberately NOT covered:
    # b_init_config! runs BEFORE this pin on a freshly-init'ed db with no timezone row;
    # and b_config_ftp! strips the zone twice, so its own analyze calls run on UTC no
    # matter what this pin did. Both stretches are UTC except the two lines pinning a
    # readable utc_offset_minutes at -05:00 -- an UNREADABLE offset and an ABSENT one both
    # resolve to 0 (Db.time_mode_offset maps BadOffset and Utc alike), the same civil-day
    # boundary as UTC.
    #
    # Everything that reads a clock in this harness must go through `tz` or `ctx.today`.
    # A second literal is how this bug got in: the fixture configured one zone and
    # computed its dates in another.
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "timezone", tz])
    match run_scenarios!(ctx) {
        Ok(_) => {}
        Err(e) => {
            # check! already said WHAT broke; name the sandbox it broke in, then propagate
            report_sandbox!(home)
            Err(e)?
        }
    }
    # #226: an sqlite3 fixture write that ERRORED, in EITHER sandbox this run touched —
    # the log is run-scoped, so b_migration!'s second HOME is covered by this one check.
    # Checked here as well as on the abort path above, so a failure with no downstream
    # symptom is still named. The text is printed by check!, not spliced into the name.
    check!("no fixture write errored", Str.is_empty(sqlite_errors!({})))?
    _ = sh!("rm -rf '${home}'")
    reset_sqlite_errors!({})
    checks_ran_exactly!(807)?
    Stdout.line!("ALL E2E CHECKS PASS")
}

# the scenario chain, extracted so its Err path can report before propagating
run_scenarios! : Ctx => Try({}, _)
run_scenarios! = |ctx| {
    b_auth!(ctx)?
    b_config_ftp!(ctx)?
    b_cred_safety!(ctx)?
    b_seed_analyze!(ctx)?
    b_pz!(ctx)?
    b_narration!(ctx)?
    b_invalidation!(ctx)?
    b_plan!(ctx)?
    b_activities!(ctx)?
    b_top!(ctx)?
    b_load_stats!(ctx)?
    b_activity_detail!(ctx)?
    b_junk_filter!(ctx)?
    b_period_ftp!(ctx)?
    b_period_pace!(ctx)?
    b_progress_a!(ctx)?
    b_progress_b!(ctx)?
    b_import!(ctx)?
    b_rpe!(ctx)?
    b_compare!(ctx)?
    # b_device_watts! BEFORE b_doctor!: it seeds the only avg_watts-scored activity,
    # and doctor's confidence cross-check can only guard rungs that exist when it runs.
    # Reversed, that check silently stopped covering the avg_watts rung.
    b_device_watts!(ctx)?
    b_doctor!(ctx)?
    b_human!(ctx)?
    b_command_schemas!(ctx)?
    # LAST of the substantive scenarios: the loop needs a rich, analyzed fixture — real
    # activities to complete against and a populated adherence window — so it runs after
    # everything that builds one, and before the two that rebuild the database.
    b_agent_loop!(ctx)?
    # ...and immediately after it. NOT because it needs the loop's rich window — it seeds
    # three of its five compared rows itself and reads nothing from activity_metrics. Its
    # real dependencies are narrower and worth naming: b_plan!'s two skipped rows on
    # ctx.today, which supply the other 2 of the 5, and the three probe dates being free of
    # open sessions, which holds only because b_agent_loop! cleans up after itself.
    b_week_plan!(ctx)?
    b_concurrency!(ctx)?
    b_migration!(ctx)?
    Ok({})
}

# ── sync mode: drive the real sync path against a running mock (a sibling instance
# started with E2E_MODE=mock). Seeds an EXPIRED token so sync must refresh first,
# then asserts token refresh + activity/stream pull. Mirrors old tests/e2e_sync.sh.
# TSS uses each sport's DERIVED FTP — no ftp_<sport> key is set, because setting one is
# refused. The power Ride (501) scores from its own stream; the HR-only Rowing row (502)
# has no power, so it falls to HR. ───────────────────────────────────────────────────
run_sync! : () => Try({}, _)
run_sync! = || {
    reset_checks!({})?
    reset_sqlite_errors!({})
    bin = env_or!("STRIDE_BIN", "./stride")
    base = env_or!("STRIDE_API_BASE", "http://127.0.0.1:8799")
    home = need("mktemp -d", Str.trim(sh!("mktemp -d")))?
    db = "${home}/.stride/db.sqlite"

    _ = wait_ready!(base, 50)
    check!("mock strava came up on ${base}", mock_up!(base))?

    _ = sync_stride!(bin, home, base, ["init"])
    _ = sync_stride!(bin, home, base, ["config", "set", "hr_z1_max", "123"])
    _ = sync_stride!(bin, home, base, ["config", "set", "hr_z2_max", "153"])
    _ = sync_stride!(bin, home, base, ["config", "set", "hr_z3_max", "168"])
    _ = sync_stride!(bin, home, base, ["config", "set", "hr_z4_max", "183"])

    _ = sql!(db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_client_id','1'),('strava_client_secret','shh'),('strava_access_token','stale-access'),('strava_refresh_token','stale-refresh'),('strava_expires_at','1');")

    first_sync = sync_stride!(bin, home, base, ["sync"])
    tok = Str.trim(sql!(db, "SELECT value FROM config WHERE key='strava_access_token';"))
    check!("expired token refreshed via /oauth/token (stale-access -> mock-access)", tok == "mock-access")?

    # #112: the first sync sees both mock activities for the first time, so both are NEW.
    # Asserting 2/0 rather than just "some number" — a classifier stuck on Updated, or one
    # that counted every re-listed row as new, would both pass a looser check.
    check!("first sync reports 2 new", Str.contains(first_sync, "\"new_activities\":2"))?
    check!("...and 0 updated", Str.contains(first_sync, "\"updated_activities\":0"))?

    # ONE further sync, not two, covering both remaining cases at once. Each extra `sync`
    # multiplies this driver's exposure to #105 — three syncs per attempt needs three
    # consecutive crash-free runs and dropped the suite to passing 1 invocation in 6, so
    # the shape of this test is bounded by that bug until it is fixed.
    #
    # Edit 501 locally to stand in for a Strava-side edit: the next sync re-lists the
    # mock's ORIGINAL name and must see it differ from what is now stored. 502 is left
    # untouched in the same run, so one sync proves three things — a changed row counts as
    # updated, an unchanged row does NOT (updated is 1, not 2), and neither is miscounted
    # as new. Without the edited row the feature could pass by never classifying anything
    # as changed; without the untouched row it could pass by counting every re-listed row.
    _ = sql!(db, "UPDATE activities SET name='edited upstream' WHERE id=501;")
    second_sync = sync_stride!(bin, home, base, ["sync"])
    check!("an edited row counts as updated", Str.contains(second_sync, "\"updated_activities\":1"))?
    check!("...the untouched row does not (1, not 2)", !(Str.contains(second_sync, "\"updated_activities\":2")))?
    check!("...and nothing is miscounted as new", Str.contains(second_sync, "\"new_activities\":0"))?
    check!("...while both rows are still re-checked", Str.contains(second_sync, "\"synced\":2"))?

    _ = sync_stride!(bin, home, base, ["analyze"])
    check!("2 mock activities synced", sync_strjq!(bin, home, base, ["activities"], ".data | length") == "2")?
    # 501's mock streams are a constant 200W. FTP is DERIVED, not configured (#26): best 20-min
    # power 200 x 0.95 = 190, so NP 200 @ derived FTP 190 => IF 1.053, TSS ~110.8 for the hour.
    # Pin the exact value (not just >0) so the whole stream->best20->deriveFTP->NP->TSS path is checked.
    check_near!("501 power streams score ~110.8 TSS (NP200 @ derived FTP190)", sfloat(sync_strjq!(bin, home, base, ["activity", "501"], ".data.tss")), 110.8, 1.0)?

    # ── sync's machine contract (#218, #232) ──────────────────────────────────
    # the stream drain used to print prose on STDOUT and emit no envelope at all, so it
    # was, besides the interactive `auth`, the command `--json` could not deliver:
    # an agent asking for JSON
    # got unparseable text. It now goes through out! like every other query
    # command, with progress narrating on stderr (ADR 0007).
    #
    # These live HERE rather than in the offline suite because sync needs a
    # token AND an API to talk to, which means the mock. That means they run
    # under `just e2e-sync`, which runs in CI. Stated plainly rather than
    # left to be discovered.
    bo = "${home}/bf.out"
    be = "${home}/bf.err"
    sync_run! = |fmt| sh!("HOME='${home}' STRIDE_FORMAT=${fmt} STRIDE_API_BASE='${base}' '${bin}' sync >'${bo}' 2>'${be}'")
    bfq! = |filter| Str.trim(sh!("jq -r '${filter}' '${bo}' 2>&1"))

    _ = sync_run!("json")
    bf_out = Str.trim(sh!("cat '${bo}'"))
    # pin BOTH ends and the line count: starts_with alone would still accept
    # prose appended after the envelope, which is the exact shape of the bug.
    check!(
        "sync's stdout is the envelope and nothing else",
        Str.starts_with(bf_out, "{\"schema_version\"")
        and Str.ends_with(bf_out, "}")
        and List.len(Str.split_on(bf_out, "\n")) == 1,
    )?
    check!("...while its progress narrates on stderr", Str.contains(sh!("cat '${be}'"), "fetching activity list"))?
    check!("...and that narration never reaches stdout", !(Str.contains(bf_out, "fetching activity list")))?
    check!("sync conforms to its schema", Str.trim(sh!("jq '.data' '${bo}' 2>&1 | jq -r --slurpfile schema schemas/v2/sync.json -f tools/validate.jq 2>&1")) == "")?

    # sync already drained both activities' streams, so this run has nothing to
    # fetch. `resumable` is the field a caller acts on -- pin it directly rather
    # than leaving it inferred from the counts.
    check!("a run with nothing to do reports complete", bfq!(".data.stopped") == "complete")?
    check!("...is not resumable", bfq!(".data.resumable") == "false")?
    check!("...and fetched nothing", bfq!(".data.streams_fetched") == "0")?
    # 502's streams 404 here, which STORES a `{}` marker — so it is not pending, and
    # "an activity Strava has no streams for stays pending" is false. That wrong story
    # shipped in four docs before review caught it; this pins the true behaviour.
    check!("...with a 404-marked activity counted as done, not pending", bfq!(".data.pending_streams") == "0")?
    check!("...nothing pruned, since the mock still lists both", bfq!(".data.pruned") == "0")?
    check!("...and nothing skipped on a clean run", bfq!(".data.streams_skipped") == "0")?

    # drop one stored stream and re-run, so the count has to MOVE. Without this
    # every check above would pass just as well against a sync that never
    # fetched anything at all.
    _ = sql!(db, "DELETE FROM streams WHERE activity_id=501;")
    _ = sync_run!("json")
    check!("a run with work to do fetches it", bfq!(".data.streams_fetched") == "1")?
    check!("...and reports complete once drained", bfq!(".data.stopped") == "complete")?
    check!("...still not resumable, having finished the queue", bfq!(".data.resumable") == "false")?

    # ── the drain has NO per-run cap (#234) ────────────────────────────────────
    # This is the invariant that justified retiring `backfill`: before #232 the queue
    # query carried `LIMIT 60`, and the whole argument for one command was that sync no
    # longer needs a second one to get past it. Restoring that LIMIT passed every driver,
    # because the fixture has two activities and any residual cap of 2 or more is
    # structurally invisible. Seed past it.
    #
    # The mock 404s unknown ids, which stores an empty marker without a real fetch, so the
    # rows cost milliseconds. SEVENTY of them, deliberately: the cap being guarded against
    # was 60, so a shorter queue cannot observe it — a 22-row seed passed the mutation.
    # The wipe that OPENS this block puts the two real fixture activities back in the queue
    # too, which is why the expected store count is 72 rather than 70. Deleted at the end
    # of the block: id assertions in this file are positional, and AGENTS.md's rule is to
    # add fixtures LAST and remove whatever you add.
    #
    # `synced_at NULL` is load-bearing, and is the mirror of the deliberate `synced_at 1`
    # on the `--all` fixture below: NULL exempts these rows from prune_deleted!, which runs
    # BEFORE the drain, so a stamped row inside the re-listed window would be deleted before
    # the drain ever saw it. The exemption is what makes the seed date a free choice — the
    # queue query carries no date predicate, so nothing here depends on the literal below
    # falling inside or outside any window. Add a date predicate to either side and that
    # stops being true.
    _ = sql!(db, "DELETE FROM streams;")
    _ = sql!(db, "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,synced_at) WITH RECURSIVE seq(x) AS (SELECT 901 UNION ALL SELECT x+1 FROM seq WHERE x<970) SELECT x,'seed','Ride','2026-08-01T10:00:00Z',3600,1000.0,0.0,NULL FROM seq;")
    # The seed asserted BEFORE the run, because `pending_streams == 0` below is a pure
    # absence and a seed that silently did nothing satisfies it perfectly. Review proved
    # that: replacing this INSERT with a no-op left the cap check itself green.
    #
    # It moves that failure to where it happens; it does not close the absence hole.
    # `streams_fetched == 72` remains the one load-bearing assertion here — seeding rows
    # with `moving_time = 0` passes THREE checks (this one, the budget pin and the cap
    # check) before dying at the store count, because the queue query cannot see them. Closing that properly would mean re-encoding the
    # production WHERE clause in the fixture, which is the hazard the queue query's own
    # comment warns about, so it is left alone knowingly.
    check!("the 70 seed rows landed", Str.trim(sql!(db, "SELECT count(*) FROM activities WHERE id BETWEEN 901 AND 970;")) == "70")?
    _ = sync_run!("json")
    # Ordered FIRST of the three deliberately. 72 reads has to sit UNDER the window budget
    # or the run stops on the budget, and the two checks below would then be measuring the
    # budget rather than the absence of a cap. Asserting it last did not work: the harness
    # aborts on the first failure, so a lowered reads_per_window failed at the cap check
    # with a message blaming a cap that was not there. A real cap does NOT trip this one —
    # drain_streams!'s empty-list arm returns Complete once the capped queue is exhausted,
    # measured at `stopped: "complete"` with `pending_streams: 12` under a restored
    # LIMIT 60 — so putting it first costs the cap checks nothing.
    check!("the drain finished inside one window, so the read budget is not what ended it", bfq!(".data.stopped") == "complete")?
    check!("...and it has no per-run cap — it clears a queue past any old LIMIT", bfq!(".data.pending_streams") == "0")?
    check!("...having stored every one of them in a single run", bfq!(".data.streams_fetched") == "72")?
    _ = sql!(db, "DELETE FROM streams WHERE activity_id >= 901; DELETE FROM activities WHERE id >= 901;")
    # Nothing else asserts this block tidies up. It looks like the `--all` prune check
    # below would catch a leak, and it cannot: prune_deleted! skips `synced_at IS NULL`,
    # which is exactly what these rows carry, so they would survive every later run
    # invisibly. Disabling the DELETE above passed every check then present (38) and leaked
    # 70 activities and 70 streams rows into the rest of the scenario — and, once the
    # downstream analyze ran, 70 activity_metrics rows scored from fake rides.
    #
    # BOTH tables, because deleting either half alone still passes. The declared
    # `REFERENCES activities(id)` on streams is unenforced — nothing sets
    # `PRAGMA foreign_keys=ON` — and it declares no ON DELETE action, so it would not
    # cascade even if something did: with the pragma on, the parent delete ERRORS instead.
    # Either way the child rows never go with the parent, which is the same reason
    # prune_txn! deletes from its tables by hand.
    #
    # activity_metrics needs no clause, but only because of WHERE this sits: no analyze runs
    # between the seed and this line, so at the cleanup instant there is nothing there to
    # leak, and asserting its absence would assert something the block never does. The
    # leaked metrics rows in the history above were created afterwards, by the downstream
    # analyze, which could only see the seeds because the activities half had failed.
    #
    # Compared as STRINGS, not through str_to_i64: that helper maps "" to 0, so a swallowed
    # sqlite error would read as a passing zero on the one check whose whole job is to
    # detect leftover state. "" == "0" is False, which is the answer we want.
    check!("...and the seeded fixtures left nothing behind, in either table", Str.trim(sql!(db, "SELECT (SELECT count(*) FROM activities WHERE id >= 901) + (SELECT count(*) FROM streams WHERE activity_id >= 901);")) == "0")?

    _ = sync_run!("human")
    bf_human = Str.trim(sh!("cat '${bo}'"))
    check!("humans get the rendered line", Str.contains(bf_human, "re-checked in the 30-day window") and Str.contains(bf_human, "fetched streams for"))?
    check!("...with no envelope in it", !(Str.contains(bf_human, "schema_version")))?
    # refetching streams above ran invalidate_metrics!, dropping the metrics rows for BOTH
    # 501 and 502 — the wipe that opens the cap block is unscoped, where the earlier one
    # took only 501. Nothing later in this scenario reads them today, which is exactly why
    # it is worth restoring: a future check placed after this block would otherwise fail
    # for a reason that has nothing to do with what it is testing.
    _ = sync_stride!(bin, home, base, ["analyze"])
    # ── `sync --all` (#232) ────────────────────────────────────────────────────
    # The flag's entire job is the UNBOUNDED prune: an incremental run only prunes inside
    # the window it re-listed, so a deletion in old history is invisible to it forever.
    # Review made the flag a no-op (`Sync(_) => sync!(False)`) and every driver still
    # passed, so nothing observed it at all. `synced_at` is load-bearing here —
    # prune_deleted! exempts NULL, so a raw insert without it passes for the wrong reason.
    _ = sql!(db, "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,synced_at) VALUES (777,'deleted upstream','Ride','2020-01-01T10:00:00Z',3600,30000.0,0.0,1);")
    _ = sync_run!("json")
    check!("an incremental sync leaves old history alone", bfq!(".data.pruned") == "0")?
    check!("...so a row outside the window survives it", Str.trim(sql!(db, "SELECT count(*) FROM activities WHERE id=777;")) == "1")?
    _ = sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' '${bin}' sync --all >'${bo}' 2>/dev/null")
    check!("--all re-lists everything, so the stale row is pruned", bfq!(".data.pruned") == "1")?
    check!("...and it is really gone from the database", Str.trim(sql!(db, "SELECT count(*) FROM activities WHERE id=777;")) == "0")?
    all_human = Str.trim(sh!("HOME='${home}' STRIDE_FORMAT=human STRIDE_API_BASE='${base}' '${bin}' sync --all 2>/dev/null"))
    check!("...and --all does not claim it checked only the 30-day window", !(Str.contains(all_human, "30-day window")))?

    check_near!("501's metrics are restored after the drain block", sfloat(sync_strjq!(bin, home, base, ["activity", "501"], ".data.tss")), 110.8, 1.0)?

    # #208: the two config reads on the SYNC path. Both used to swallow an unreadable
    # value -- last_sync_epoch by folding it into "never synced" (a silent full re-pull,
    # conservative and therefore invisible), strava_expires_at by raising a tag nothing
    # handled, which surfaced as internal_error telling the athlete to file a bug about
    # their own config value. Written with sql! because that is how a legacy row arrives,
    # and because `config set` now refuses these at the write.
    #
    # These live HERE rather than in the offline suite because both reads sit behind the
    # sync path, which needs the mock. That means they run under `just e2e-sync` only --
    # `just e2e-sync`, which runs in CI. Stated plainly rather than left to be discovered.
    _ = sql!(db, "UPDATE config SET value='1e9' WHERE key='last_sync_epoch';")
    bad_epoch = sync_stride!(bin, home, base, ["sync"])
    check!("an unreadable last_sync_epoch is named, not a silent full re-pull", Str.contains(bad_epoch, "unreadable_config") and Str.contains(bad_epoch, "last_sync_epoch"))?
    _ = sql!(db, "DELETE FROM config WHERE key='last_sync_epoch';")
    check!("...while an ABSENT one still means never-synced and syncs", Str.contains(sync_stride!(bin, home, base, ["sync"]), "\"new_activities\""))?
    _ = sql!(db, "UPDATE config SET value='99999999999999999999' WHERE key='strava_expires_at';")
    bad_exp = sync_stride!(bin, home, base, ["sync"])
    check!("an unreadable strava_expires_at is named, not internal_error", Str.contains(bad_exp, "unreadable_config") and Str.contains(bad_exp, "strava_expires_at"))?
    check!("...and never tells the athlete to open an issue", !(Str.contains(bad_exp, "please open an issue")))?

    check!("no fixture write errored", Str.is_empty(sqlite_errors!({})))?
    _ = sh!("rm -rf '${home}'")
    reset_sqlite_errors!({})
    checks_ran_at_least!(41)?
    Stdout.line!("SYNC E2E CHECKS PASS")
}

# ── sync against a mock whose stream bodies do not decode (#218, #232) ───────
# The one state run_sync! cannot reach: a run that DRAINS its queue and still has
# work left. store_stream_response! deliberately does not store a non-UTF-8 body
# ("storing would mark it done forever"), so that id stays pending and retries next
# run — which makes `complete` with pending > 0 reachable, and `resumable` TRUE
# after it.
#
# This scenario exists because review proved the suite was blind here: a build with
# `resumable` hardcoded permanently false passed every check in run_sync!, since
# every run there ends with pending == 0. `resumable` is the one field SKILL.md
# tells agents to branch on, so an unobservable value is not an acceptable gap.
# Runs under `just e2e-sync`, like every mock-backed check — and that recipe is in CI.
run_skips! : () => Try({}, _)
run_skips! = || {
    reset_checks!({})?
    # Every driver resets the run-scoped failure log on entry and asserts it empty before
    # finishing (#226). Adding a driver without both is SILENT: the rebase that brought
    # this scenario onto a main carrying that log merged cleanly and left it with neither,
    # which is the guard's own hole reopened by new code that git had no way to see.
    reset_sqlite_errors!({})
    bin = env_or!("STRIDE_BIN", "./stride")
    base = env_or!("STRIDE_API_BASE", "http://127.0.0.1:8798")
    home = need("mktemp -d", Str.trim(sh!("mktemp -d")))?
    db = "${home}/.stride/db.sqlite"

    _ = wait_ready!(base, 50)
    check!("bad-stream mock came up on ${base}", mock_up!(base))?

    _ = sync_stride!(bin, home, base, ["init"])
    _ = sql!(db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_client_id','1'),('strava_client_secret','shh'),('strava_access_token','mock-access'),('strava_refresh_token','mock-refresh'),('strava_expires_at','9999999999');")
    # sync pulls both activities; 501's streams store, 502's body does not decode.
    # #224: this skip path used to report NOTHING under sync —
    # no counter, no line, no payload field. It is the command that runs daily, so it
    # is where the loss actually happens; the only trace was `pending_streams` failing
    # to move, which is indistinguishable from a rate-limited partial.
    sync_err = "${home}/sync.err"
    _ = sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' '${bin}' sync >'${home}/sync.out' 2>'${sync_err}'")
    syncq! = |filter| Str.trim(sh!("jq -r '${filter}' '${home}/sync.out' 2>&1"))
    check!("sync counts the undecodable body", syncq!(".data.streams_skipped") == "1")?
    check!("...and stores only the one that decoded", syncq!(".data.streams_fetched") == "1")?
    check!("...naming it on stderr, with the activity id", Str.contains(sh!("cat '${sync_err}'"), "502: stream data would not decode"))?
    check!("...while its stdout stays exactly the envelope", Str.starts_with(Str.trim(sh!("cat '${home}/sync.out'")), "{\"schema_version\"") and List.len(Str.split_on(Str.trim(sh!("cat '${home}/sync.out'")), "\n")) == 1)?
    check!("sync conforms to its schema with the new key", Str.trim(sh!("jq '.data' '${home}/sync.out' 2>&1 | jq -r --slurpfile schema schemas/v2/sync.json -f tools/validate.jq 2>&1")) == "")?
    check!("humans are told too, not just machines", Str.contains(Str.trim(sh!("HOME='${home}' STRIDE_FORMAT=human STRIDE_API_BASE='${base}' '${bin}' sync 2>/dev/null")), "unreadable stream data"))?

    bo = "${home}/bf.out"
    be = "${home}/bf.err"
    bfq! = |filter| Str.trim(sh!("jq -r '${filter}' '${bo}' 2>&1"))
    _ = sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' '${bin}' sync >'${bo}' 2>'${be}'")

    check!("an undecodable body is COUNTED, not silently dropped", bfq!(".data.streams_skipped") == "1")?
    # the counter alone is a number nobody reads; the run must SAY it, naming the id
    check!("...and named on stderr, with the activity id", Str.contains(sh!("cat '${be}'"), "502: stream data would not decode"))?
    check!("...and stores nothing", bfq!(".data.streams_fetched") == "0")?
    check!("...so the activity stays pending", bfq!(".data.pending_streams") == "1")?
    # the queue emptied, so the drain IS complete — and there is still work to do.
    # These two assertions together are the whole point: deriving `resumable` from
    # `stopped` reports false here, about a row stride itself intends to retry.
    check!("the queue drained, so stopped is complete", bfq!(".data.stopped") == "complete")?
    check!("...yet the run is resumable, because that id retries next run", bfq!(".data.resumable") == "true")?
    check!("the skip payload conforms to the schema", Str.trim(sh!("jq '.data' '${bo}' 2>&1 | jq -r --slurpfile schema schemas/v2/sync.json -f tools/validate.jq 2>&1")) == "")?

    # re-running really does re-attempt it — the claim `resumable: true` makes
    _ = sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' '${bin}' sync >'${bo}' 2>/dev/null")
    check!("a second run re-attempts the skipped id rather than retiring it", bfq!(".data.streams_skipped") == "1")?

    _ = sh!("HOME='${home}' STRIDE_FORMAT=human STRIDE_API_BASE='${base}' '${bin}' sync >'${bo}' 2>/dev/null")
    human = Str.trim(sh!("cat '${bo}'"))
    check!("humans are told the data was unreadable", Str.contains(human, "unreadable stream data"))?
    # Re-pointed. This asserted the absence of `"all streams present"`, which was meaningful
    # while that string existed and the pending guard suppressed it — and became VACUOUS the
    # moment this branch deleted the string, because a `contains` on text no producer can
    # emit cannot fail for any input. What it actually cares about is that a run which
    # skipped unreadable streams does not also claim the queue is drained, so it says that
    # against the number instead of against a dead literal.
    check!("...and told they retry next sync", Str.contains(human, "retry next sync"))?

    _ = sh!("rm -rf '${home}'")
    check!("no fixture write errored", Str.is_empty(sqlite_errors!({})))?
    reset_sqlite_errors!({})
    checks_ran_at_least!(16)?
    Stdout.line!("SKIPS E2E CHECKS PASS")
}

# ── the two non-complete stop reasons (#218) ─────────────────────────────────
# Until the read limits became env-overridable, reaching `budget_reached` honestly
# cost 940 reads and `rate_limited` cost two 15-minute sleeps — so of the three
# StopReason values only `complete` was ever observed, and review proved a
# transposition in BOTH the StopRun and GiveUp arms (`stored: counted.skipped`)
# passed the entire suite. These two runs are what catches THAT (the check-count floor
# below catches a whole branch going dead, which is a different failure).
run_stops! : () => Try({}, _)
run_stops! = || {
    reset_checks!({})?
    # same contract as every other driver — see run_skips!
    reset_sqlite_errors!({})
    bin = env_or!("STRIDE_BIN", "./stride")
    base = env_or!("STRIDE_API_BASE", "http://127.0.0.1:8797")
    rate_limited = env_or!("E2E_EXPECT_RATE_LIMIT", "") == "1"
    home = need("mktemp -d", Str.trim(sh!("mktemp -d")))?
    db = "${home}/.stride/db.sqlite"

    _ = wait_ready!(base, 50)
    check!("stop-reason mock came up on ${base}", mock_up!(base))?

    _ = sync_stride!(bin, home, base, ["init"])
    _ = sql!(db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_client_id','1'),('strava_client_secret','shh'),('strava_access_token','mock-access'),('strava_refresh_token','mock-refresh'),('strava_expires_at','9999999999');")
    # list the activities WITHOUT draining streams, so the drain has a full queue.
    # STRIDE_READS_PER_WINDOW=0 is rejected by the parser (must be > 0), so sync would
    # still drain; instead seed via sync and delete the rows it stored.
    _ = sync_stride!(bin, home, base, ["sync"])
    _ = sql!(db, "DELETE FROM streams;")

    bo = "${home}/bf.out"
    bfq! = |filter| Str.trim(sh!("jq -r '${filter}' '${bo}' 2>&1"))
    # The two arms need DIFFERENT seams, and setting both breaks the rate-limited one:
    # with a budget of 1 the drain stops after 502 and never reaches 501's 429, so the
    # run reports budget_reached and the 429 arm is never entered.
    #   budget: one read per run, so the second queued id is never requested.
    #   rate:   the real window, so the drain DOES reach 501 and meets its 429.
    #           Nothing sleeps any more, so this costs milliseconds.
    daily_cap = env_or!("E2E_EXPECT_DAILY_CAP", "") == "1"
    # THREE seams now, mutually exclusive on purpose. The daily one needs the WINDOW left
    # at its default: set both to 1 and the window fires first, the run reports
    # budget_reached, and this arm tests the stop it is not about — which is exactly the
    # trap the budget/rate pair above already documents for itself.
    envs =
        if daily_cap {
            "STRIDE_READS_PER_DAY=1"
        } else if rate_limited {
            ""
        } else {
            "STRIDE_READS_PER_WINDOW=1"
        }
    run_sync_bf! = |fmt| sh!("HOME='${home}' STRIDE_FORMAT=${fmt} STRIDE_API_BASE='${base}' ${envs} '${bin}' sync >'${bo}' 2>/dev/null")
    bf_start = str_to_i64(Str.trim(sh!("date +%s")))
    _ = run_sync_bf!("json")
    bf_elapsed = str_to_i64(Str.trim(sh!("date +%s"))) - bf_start

    if env_or!("E2E_EXPECT_LIST_429", "") == "1" {
        # A 429 on the LISTING (#235). Before this, the same upstream condition behaved two
        # ways inside one invocation: a hard exit 1 if it landed on the list, a success
        # envelope with `stopped: "rate_limited"` and exit 0 if it landed on a stream. The
        # first breaks every cron and shell wrapper for a run that did its job up to the cap.
        #
        # The envelope assertions are the contract. The two after them are the ones that
        # matter most, because they are about damage rather than reporting: `prune_deleted!`
        # removes what the listing did NOT re-list, so running it against a partial list
        # would delete activities that exist and were simply never reached — and the
        # watermark must not advance past activities the run never saw.
        # SEEDED first, and this is the whole point. The mock 429s EVERY list request,
        # including the driver's own setup sync, so this branch ran against an empty
        # database — `pruned == 0` and `activities unchanged` were comparing 0 to 0 and
        # were structurally incapable of failing. The destructive property this branch
        # exists to protect was the one thing it did not test.
        #
        # `synced_at` is set to a DIFFERENT value from any run stamp, and `start_local` is
        # inside the 30-day window, which is exactly what makes a row a prune victim: the
        # predicate is `synced_at <> :stamp AND start_local >= :window_start`. If the early
        # return were removed, these rows would be deleted.
        bait_day = Str.trim(sh!("date +%F"))
        _ = sql!(db, "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time,distance,synced_at) VALUES (7001,'prune bait a','Ride','${bait_day}T10:00:00Z',3600,20000,1),(7002,'prune bait b','Ride','${bait_day}T11:00:00Z',3600,20000,1);")
        _ = sql!(db, "INSERT OR REPLACE INTO config (key,value) VALUES ('last_sync_epoch','1700000000');")
        before_epoch = Str.trim(sql!(db, "SELECT COALESCE((SELECT value FROM config WHERE key='last_sync_epoch'),'none');"))
        before_acts = Str.trim(sql!(db, "SELECT count(*) FROM activities;"))
        check!("the prune-bait rows are really there, so the next checks are not 0 == 0", before_acts != "0" and before_epoch != "none")?
        st429 = Str.trim(sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' '${bin}' sync >'${bo}' 2>/dev/null; echo $?"))
        check!("a 429 on the activity list exits 0, like a 429 on a stream", st429 == "0")?
        check!("...reporting list_rate_limited, naming the LIST rather than the drain", bfq!(".data.stopped") == "list_rate_limited")?
        check!("...and resumable, so a caller knows to run it again", bfq!(".data.resumable") == "true")?
        check!("...with no error field at all", bfq!(".error") == "null")?
        # THE destructive one: a partial list must not drive a prune.
        check!("...pruning nothing, because a partial list is not evidence of deletion", bfq!(".data.pruned") == "0")?
        check!("...and deleting no activities", Str.trim(sql!(db, "SELECT count(*) FROM activities;")) == before_acts)?
        # ...and the watermark must not move past what was never listed.
        check!("...leaving last_sync_epoch where it was", Str.trim(sql!(db, "SELECT COALESCE((SELECT value FROM config WHERE key='last_sync_epoch'),'none');")) == before_epoch)?
        check!("...and the human screen blames the LIST too, not the drain", Str.contains(sh!("HOME='${home}' STRIDE_API_BASE='${base}' '${bin}' sync 2>&1"), "rate-limited the activity list"))?
        # ...but with the day's allowance spent it is the DAILY cap, not the window. The
        # drain's 429 arm asks which limit refused and the list's did not, so the
        # fifteen-minute remedy survived here — #246's defect on the other endpoint that
        # can 429. Counter one below the cap, so the list read itself lands exactly on it,
        # which is where a real run ends up.
        lcap_day = Str.trim(sh!("date -u +%s | awk '{ print int($1 / 86400) }'"))
        _ = sql!(db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_reads_day','${lcap_day}'),('strava_reads_today','9');")
        # Written to `$bo` rather than only captured, because the schema check below reads
        # that file — without this it validated the PREVIOUS run's payload and the new enum
        # value was emitted and never checked. Review proved it: deleting
        # "list_daily_cap_reached" from sync.json left every driver green, which is the
        # identical gap the paragraph below records for "list_rate_limited", reproduced by
        # the commit that added the second value.
        _ = sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' STRIDE_READS_PER_DAY=10 '${bin}' sync >'${bo}' 2>/dev/null")
        lcap = Str.trim(sh!("jq -r '.data.stopped' '${bo}' 2>&1"))
        # EXACT, not `contains`. "list_daily_cap_reached" CONTAINS "daily_cap_reached", so a
        # substring test passes for the folded token and the separate one alike — and this
        # check is named for telling them apart. Review reverted the whole list change back
        # to `FromDrain(DailyCapReached)` and every driver stayed green through this line.
        check!("a 429 on the LIST reads as the LIST daily cap once the allowance is spent", lcap == "list_daily_cap_reached")?
        # RE-SEEDED before the human run, and finding that out was worth the round. The run
        # above charges its list read, so the counter goes 9 -> 10 and the NEXT invocation is
        # refused by the pre-flight before it ever reaches the list. The human check below
        # therefore used to assert "again tomorrow" against the PRE-FLIGHT arm while being
        # named for the list one — passing, on the wrong code path, for the whole life of
        # this check. It only surfaced because the incomplete-listing assertion added beside
        # it went red, and that sentence the pre-flight cannot produce.
        _ = sql!(db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_reads_day','${lcap_day}'),('strava_reads_today','9');")
        lcap_human = sh!("HOME='${home}' STRIDE_API_BASE='${base}' STRIDE_READS_PER_DAY=10 '${bin}' sync 2>&1")
        # BOTH facts on one screen, asserted separately, because either alone is satisfied
        # by a version that dropped the other: the fold kept "tomorrow" and lost the
        # listing, and #235's original kept the listing and said "~15 minutes".
        check!("...and its human line says tomorrow rather than ~15 minutes", Str.contains(lcap_human, "again tomorrow"))?
        check!("...while still saying the listing is incomplete, the fact the fold lost", Str.contains(lcap_human, "the activity list, so it is incomplete"))?
        _ = sql!(db, "DELETE FROM config WHERE key IN ('strava_reads_day','strava_reads_today');")
        # The three sibling stop-reason arms each validate their payload and this one did
        # not, which mattered more here than anywhere else: this is the only arm in the
        # suite that ADDS a value to an enum in schemas/v2. Review deleted
        # "list_rate_limited" from sync.json's `stopped` enum and all 19 checks stayed
        # green — a contract break shipping under a green suite, and no other driver could
        # have caught it, because emitting the value at all needs a list-429 mock and only
        # these two halves have one.
        check!("the list-refused payload conforms to the schema", Str.trim(sh!("jq '.data' '${bo}' 2>&1 | jq -r --slurpfile schema schemas/v2/sync.json -f tools/validate.jq 2>&1")) == "")?
        # PARTIAL progress, against a second mock that serves a full page and then refuses.
        # Everything above runs on a page-one refusal, where nothing was ever upserted — so
        # `synced` is 0 whether the run carries its accumulator out or throws it away.
        # Review proved that: discarding the accumulator outright passed every driver, in a
        # PR whose own comment says "a caller that is told nothing cannot tell a
        # rate-limited partial from a run that found nothing".
        #
        # per_page is 100 and fetch_pages! only recurses on a FULL page, so every page
        # before the refusal has to be exactly 100 rows. TWO of them, refused on the third:
        # 200 is neither per_page nor any single page's count, so `synced == 200` can only
        # come from a running total. With one page every quantity in this payload collapsed
        # onto 100 and `total = got` — shipping the last page instead of the sum — passed
        # the whole suite.
        # its own mock instance, since the one this driver runs against refuses page one
        part_base = env_or!("E2E_LIST_PARTIAL_BASE", "")
        part_home = Str.trim(sh!("mktemp -d"))
        part_db = "${part_home}/.stride/db.sqlite"
        _ = sh!("HOME='${part_home}' '${bin}' init >/dev/null 2>&1")
        _ = sql!(part_db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_access_token','t'),('strava_refresh_token','r'),('strava_expires_at','9999999999');")
        part_sync! = |_| sh!("HOME='${part_home}' STRIDE_FORMAT=json STRIDE_API_BASE='${part_base}' '${bin}' sync >'${part_home}/out.json' 2>/dev/null")
        _ = part_sync!({})
        pq! = |q| Str.trim(sh!("jq -r '${q}' '${part_home}/out.json' 2>/dev/null"))
        check!("a list refused on page THREE still reports both pages it kept", pq!(".data.synced") == "200")?
        check!("...counted as new, not silently dropped", pq!(".data.new_activities") == "200")?
        check!("...and those rows really are in the database", Str.trim(sql!(part_db, "SELECT count(*) FROM activities;")) == "200")?
        check!("...spanning BOTH pages, so the second one was stored and not just counted", Str.trim(sql!(part_db, "SELECT count(*) FROM activities WHERE id BETWEEN 20101 AND 20200;")) == "100")?
        check!("...still reporting the list stop, and still pruning nothing", pq!(".data.stopped") == "list_rate_limited" and pq!(".data.pruned") == "0")?
        # The queue at its MAXIMUM, which is the shape Render's tail comment is written
        # about and the reason the list arm is tested before pending_streams. The consumer
        # side pins it (Render's sync_screen expect carries pending_streams: 100); the
        # PRODUCER was unpinned, and zeroing this field passed all 19 checks.
        check!("...reporting the whole listed backlog as pending, not zero", pq!(".data.pending_streams") == "200")?
        # nothing was updated on a first run, and `updated_activities` survived being
        # replaced by `synced` because no check read it
        check!("...and nothing updated, because every row was new", pq!(".data.updated_activities") == "0")?
        check!("the partial-list payload conforms to the schema too", Str.trim(sh!("jq '.data' '${part_home}/out.json' 2>&1 | jq -r --slurpfile schema schemas/v2/sync.json -f tools/validate.jq 2>&1")) == "")?
        # Run it AGAIN against the same mock. `synced` is what was re-listed and
        # `new_activities` is what was inserted, and on the first run both are 200 — so
        # either one hardcoded to the other passes. The second run separates them: the same
        # 200 rows come back, none of them new. (The watermark never advanced, asserted
        # above, so the request is identical.)
        _ = part_sync!({})
        check!("re-listing the same refused pages re-counts them", pq!(".data.synced") == "200")?
        check!("...while reporting none of them as new, which is what splits synced from new", pq!(".data.new_activities") == "0")?
        check!("...and stores no duplicates", Str.trim(sql!(part_db, "SELECT count(*) FROM activities;")) == "200")?
        _ = sh!("rm -rf '${part_home}'")
    } else if env_or!("E2E_EXPECT_500", "") == "1" {
        # A drain that dies with rows already committed. Salvaged from #225, minus its
        # stored-count assertion: #233 reports the queue total at the boundary, and the
        # per-id progress frame above it carries "how far did it get" at finer resolution.
        # a clean queue: the shared run above this if-chain already drained, so without
        # this the branch sees one id, dies on it immediately, and the frame never advances
        # past 0/1 — which would make the progress assertion below pass for the wrong
        # reason or not at all.
        _ = sql!(db, "DELETE FROM streams;")
        be500 = "${home}/500.err"
        _ = sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' '${bin}' sync >'${bo}' 2>'${be500}'")
        err500 = sh!("cat '${be500}'")
        check!("a 5xx mid-drain arrives as an error envelope", bfq!(".error.code") == "strava_error")?
        check!("...and stdout carries nothing else", List.len(Str.split_on(Str.trim(sh!("cat '${bo}'")), "\n")) == 1)?
        check!("...with the partial-progress report naming how to continue", Str.contains(err500, "run `stride sync` again to continue"))?
        # the only assertion anywhere that verifies the CLAIM that message makes
        check!("...and a row really did survive the failed run", Str.trim(sql!(db, "SELECT count(*) FROM streams;")) == "1")?
        # the bar is the only carrier of "how far did it get" on the error path, so
        # deleting narrate! would otherwise pass the whole suite
        # "1/2", not merely "fetching streams" — the opening 0/total frame is emitted by a
        # DIFFERENT call, so matching the label alone passes with the per-id frame deleted.
        # That frame is the only carrier of "how far did it get" on the error path.
        check!("...and the progress frame recorded the id it retired", Str.contains(err500, "1/2"))?
    } else if daily_cap {
        # #246. Every stop used to advise "~15 minutes", including the one where the answer
        # is tomorrow: the daily cap was "respected by arithmetic" — ~95 reads a window x
        # ~10 windows a day under Strava's 1000 — and there are 96 windows in a day, not
        # 10. Follow the advice and you do four runs an hour, cross 1000 in about two and a
        # half hours, and then every read is refused while stride keeps saying fifteen
        # minutes.
        check!("a run that spends the daily allowance says so", bfq!(".data.stopped") == "daily_cap_reached")?
        check!("...and is resumable, because the work is not finished", bfq!(".data.resumable") == "true")?
        # the EXIT CODE, actually read. This check was named for exit 0 and only looked at
        # `.error` — the one exit-code claim in this file not backed by an exit code, in
        # the branch this change added. The sibling 429 branch does it properly and this
        # now copies it.
        cap_st = Str.trim(sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' ${envs} '${bin}' sync >'${bo}' 2>/dev/null; echo $?"))
        check!("...at exit 0 with no error field, like every other stop reason", cap_st == "0" and bfq!(".error") == "null")?
        # THE point of the issue, and not `contains "tomorrow"` alone: the failure mode was
        # two stops sharing one remedy, so the assertion has to be that this one does NOT
        # carry the other's wording.
        # queue refilled first. The json run above spent the one allowed read on the last
        # queued id, so without this the human run finds pending_streams == 0, sync_screen
        # never consults drain_note, and the assertion below tests an empty tail rather
        # than the sentence. Written without it and it failed exactly that way.
        _ = sql!(db, "DELETE FROM streams;")
        # the count BEFORE a run that has nothing it can do. `decide` structurally cannot
        # express "do not start" — it is only reachable with a response in hand — so
        # without a pre-flight check a capped run spent a list read and a stream read just
        # to report that it had none left. At the cadence stride's own advice implies that
        # is ~190 reads a day burned against an allowance already gone, with the counter
        # climbing past the cap all day.
        cap_before = str_to_i64(Str.trim(sql!(db, "SELECT COALESCE((SELECT value FROM config WHERE key='strava_reads_today'),'0');")))
        human_cap = sh!("HOME='${home}' STRIDE_API_BASE='${base}' ${envs} '${bin}' sync 2>&1")
        check!("...and a run with nothing it can do spends NOTHING finding that out", str_to_i64(Str.trim(sql!(db, "SELECT COALESCE((SELECT value FROM config WHERE key='strava_reads_today'),'0');"))) == cap_before)?
        # ...and that payload CONFORMS. Every other stop-reason arm validates its payload
        # and this one did not — the one arm that added a value to a schemas/v2 enum. The
        # closed record annotation pins the shape at compile time (ADR 0000 section 9c), so
        # what this adds is that the `stopped` VALUE lands in the enum, which is precisely
        # what this change touched.
        _ = sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' ${envs} '${bin}' sync >'${bo}' 2>/dev/null")
        check!("...and the daily-cap payload conforms to the sync schema", Str.trim(sh!("jq '.data' '${bo}' 2>&1 | jq -r --slurpfile schema schemas/v2/sync.json -f tools/validate.jq 2>&1")) == "")?
        check!("...and the human line names TOMORROW", Str.contains(human_cap, "again tomorrow"))?
        # anchored on the REMEDY clause, not on "15 minutes" alone: the drain banner on
        # stderr says "Strava caps reads per 15-minute window", so the loose form passes on
        # a hyphen and would go red if that banner were ever reworded — a failure unrelated
        # to what this asserts.
        check!("...and does NOT say ~15 minutes, the instruction that cannot succeed", !(Str.contains(human_cap, "again in ~15 minutes")))?
        # the counter is PERSISTED, which is what makes the cap mean anything across runs.
        # Both rows: a count without its day would never reset, and a day without a count
        # would pace from zero forever.
        cap_day = Str.trim(sh!("date -u +%s | awk '{ print int($1 / 86400) }'"))
        check!("...and the read count is stored against today's UTC day", Str.trim(sql!(db, "SELECT COALESCE((SELECT value FROM config WHERE key='strava_reads_day'),'none');")) == cap_day)?
        check!("...with a non-zero count", str_to_i64(Str.trim(sql!(db, "SELECT COALESCE((SELECT value FROM config WHERE key='strava_reads_today'),'0');"))) > 0)?
        # ...and a STALE day resets it. That is the reset mechanism in full — there is no
        # scheduled job, the stamp not being today IS the reset — so it is asserted rather
        # than described. Backdated by one day, then a run must start from zero, which it
        # can only show by draining again rather than refusing on yesterday's total.
        # Driven at a cap of THREE, and the number is load-bearing twice over.
        #
        # At ONE, a reset count and a stale count behave identically — both stop after a
        # single read — so the assertion passes either way. Mutation-proved: making
        # reads_today! ignore the day stamp left the suite green.
        #
        # At TWO it stopped discriminating again once the LIST read began to be counted,
        # because that read absorbs exactly the one-unit difference between the two states.
        # Both end up fetching one stream. At three: a reset spends list + 2 streams, a
        # stale count (already at 1) spends list + 1, so the fetched count separates them.
        #
        # That the right number moved when an unrelated part of the counter changed is the
        # argument for asserting a DIFFERENCE rather than a magic constant — noted rather
        # than done, because the fixture has only two activities to drain.
        _ = sql!(db, "UPDATE config SET value = '${I64.to_str(str_to_i64(cap_day) - 1)}' WHERE key = 'strava_reads_day';")
        _ = sql!(db, "DELETE FROM streams;")
        _ = sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' STRIDE_READS_PER_DAY=3 '${bin}' sync >'${bo}' 2>/dev/null")
        # the COUNT, not the stamp. `save_reads_for_day!` writes the day unconditionally on
        # every read, so asserting the stamp holds whether the reset happened or not — it
        # survives the exact mutation it is named for. Same defect one line above the one
        # this arm already fixed.
        check!("a stale day stamp resets the count rather than needing a scheduled job", str_to_i64(Str.trim(sql!(db, "SELECT COALESCE((SELECT value FROM config WHERE key='strava_reads_today'),'0');"))) == 3)?
        check!("...and the run spent a FULL fresh allowance, not yesterday's remainder", bfq!(".data.streams_fetched") == "2")?
        # ...and it stopped on the DAY, which is the arm nothing else in this driver
        # reaches. Every other daily-cap assertion here exercises the PRE-FLIGHT refusal:
        # once `charge_read!` began counting the list read, the seeding sync leaves the
        # counter at 3 and the capped runs are refused before the first request. So
        # `DayFull` — the arm that fires on the correct path, with no 429, on the run that
        # actually exhausts the allowance, and the arm review round 1 said was unreachable —
        # was pinned by nothing. Measured: changing it to report `BudgetReached` left all
        # 818 checks green.
        check!("...and stopped on the DAILY cap, the one arm no 429 produces", bfq!(".data.stopped") == "daily_cap_reached")?
        # The count assertion two lines up has the shape its own comment warns about, one
        # field over: a run that IGNORED the stamp also ends at the cap, because it stops
        # when it gets there. `streams_fetched == 2` is what discriminates, and this pins
        # the reason it stopped. Three assertions, three different failure modes.
    } else if env_or!("E2E_EXPECT_401", "") == "1" {
        # The refresh arm recurses on the SAME id. Seed a token the mock will not hand
        # back, so get_valid_token! genuinely rotates once and the arm is entered rather
        # than short-circuiting on `fresh == token`.
        _ = sql!(db, "UPDATE config SET value='stale-access' WHERE key='strava_access_token'; UPDATE config SET value='1' WHERE key='strava_expires_at';")
        started_at = str_to_i64(Str.trim(sh!("date +%s")))
        # HARD kill-after on the invocation itself (`timeout` is not on macOS). Without
        # it an unbounded loop never returns, the elapsed check below is never evaluated,
        # and the harness HANGS instead of failing — review's exact criticism of a latency
        # assertion that only manifests as CI looking slow. With it the run is killed, the
        # envelope is empty, and the checks go red.
        be401 = "${home}/401.err"
        _ = sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' '${bin}' sync >'${bo}' 2>'${be401}' & p=$!; (sleep 25; kill -9 $p) >/dev/null 2>&1 & w=$!; wait $p >/dev/null 2>&1; kill $w >/dev/null 2>&1")
        elapsed = str_to_i64(Str.trim(sh!("date +%s"))) - started_at
        out401 = Str.trim(sh!("cat '${bo}'"))
        # TERMINATION is the invariant. Unbounded, review measured ~113 requests/second
        # with no terminal state — a wall-clock check turns that into a failing assertion
        # instead of a hung job that reads as infrastructure flake.
        check!("a persistent 401 terminates instead of hammering Strava", elapsed < 20)?
        check!("...as an auth error", bfq!(".error.code") == "not_authenticated")?
        # NOT "run `stride auth`". Refreshing worked — twice, with genuinely new tokens —
        # and Strava still refused, so the credential is not the problem and re-authing
        # with the same scope will not fix it. The boundary used to flatten this into the
        # dead-credential message; the diagnosis now reaches the user, and this pins that
        # it names a cause rather than offering a fix that does not fit.
        check!("...naming the real cause, not the wrong remedy", Str.contains(out401, "activity:read_all scope") and !(Str.contains(out401, "run `stride auth`")))?
        check!("...not as a success envelope", bfq!(".data") == "null")?
        # THE bound, in both directions. Every assertion above reads stdout, and both 401
        # exits — "refresh did not help" and "kept getting 401 after refreshing" — are
        # flattened by the boundary into the same envelope, so stdout cannot tell a
        # bounded run from one that never refreshed at all. Review proved it: setting the
        # bound to 0, which disables refreshing entirely, passed every check. The stderr
        # count is what discriminates, and it tracks max_refreshes exactly.
        # The literal 2 is `max_refreshes` in src/Strava.roc, coupled across a module
        # boundary with nothing linking them — bump the bound and this reds like a
        # regression. The count is in the NAME so the red explains itself, the way the
        # floor guard does; without it, 0 means "no refreshes" and "no file" alike.
        refreshes_seen = str_to_i64(Str.trim(sh!("grep -c 'refreshed, continuing' '${be401}' 2>/dev/null")))
        check!("...having spent exactly the bounded number of refreshes (${I64.to_str(refreshes_seen)} == 2)", refreshes_seen == 2)?
        # the boundary reporter fires on this path; nothing asserted it, so deleting it
        # passed the whole suite
        check!("...and the partial-progress report names the run", Str.contains(sh!("cat '${be401}'"), "everything already stored is saved"))?
    } else if rate_limited {
        # 501 429s forever. 502 drains first (ORDER BY start_local DESC) and stores its
        # 404 marker, so a surviving counter reads 1 and a reset one reads 0.
        # WALL CLOCK. The no-sleep fix is only observable as latency: review reintroduced
        # a 3s sleep here and every driver passed, so a return to the ~30-minute block
        # would read as CI being slow rather than as a failing check. I claimed this
        # assertion in an earlier commit message and it was never actually in the file.
        check!("a rate-limited sync returns at once instead of sleeping", bf_elapsed < 10)?
        check!("a 429 stops the run outright", bfq!(".data.stopped") == "rate_limited")?
        # Salvaged from #227. A rate-limited run is a PARTIAL SUCCESS: it did real work
        # before Strava capped it, so it exits 0 while the identically-named error code
        # exits 1. Nothing else in this suite asserts sync's exit code at all — sh! and
        # stride_env! both discard it — so a regression emitting the right payload and
        # exiting 1, which is the tempting reading of "something went wrong", would pass
        # every other check green.
        check!("...as a partial success: exit 0, unlike the error code of the same name", stride_status_env!(bin, home, ["sync"], [("STRIDE_FORMAT", "json"), ("STRIDE_API_BASE", base)]) == 0)?
        check!("...counting what it stored before the 429", bfq!(".data.streams_fetched") == "1")?
        check!("...leaving the 429'd id pending", bfq!(".data.pending_streams") == "1")?
        check!("...and resumable, because waiting will help", bfq!(".data.resumable") == "true")?
        check!("the rate-limited payload conforms to the schema", Str.trim(sh!("jq '.data' '${bo}' 2>&1 | jq -r --slurpfile schema schemas/v2/sync.json -f tools/validate.jq 2>&1")) == "")?
        # fresh queue: the JSON run above already stored one, so without this the human
        # run drains what is left and renders an EMPTY tail instead. (It used to render
        # "all streams present" there — text that never actually shipped, because the
        # pending guard suppressed the tail before it could, and which this branch deleted.)
        _ = sql!(db, "DELETE FROM streams;")
        _ = run_sync_bf!("human")
        check!("humans are told to try again in ~15 minutes", Str.contains(Str.trim(sh!("cat '${bo}'")), "in ~15 minutes"))?
        # ...and the SAME 429 means something different once the day's allowance is spent.
        # This is the path #246 actually travels in production and the one its own e2e arm
        # cannot reach: stride's count is at or below Strava's, so Strava refuses FIRST,
        # the drain stops on the 429, and without this branch the counted day test is never
        # consulted. Review measured the result — "try again in ~15 minutes" printed in the
        # exact state the feature exists to describe — and the daily arm's own driver could
        # not see it, because it sets stride's cap so far below Strava's that the mock never
        # refuses at all.
        #
        # Seeded to ONE BELOW the cap, not at it, and that is the whole difficulty. At the
        # cap the pre-flight check refuses before any request, so the run never reaches a
        # 429 and this branch tests the pre-flight instead — written that way first and
        # mutation-proved: breaking the 429 arm left it green. One below, the pre-flight
        # passes, the LIST read takes the count to the cap, and the stream's 429 then
        # arrives with the allowance exactly spent, which is the state under test.
        cap_now = Str.trim(sh!("date -u +%s | awk '{ print int($1 / 86400) }'"))
        _ = sql!(db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_reads_day','${cap_now}'),('strava_reads_today','9');")
        _ = sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' STRIDE_READS_PER_DAY=10 '${bin}' sync >'${bo}' 2>/dev/null")
        check!("...and the same 429 reads as the DAILY cap once the allowance is spent", bfq!(".data.stopped") == "daily_cap_reached")?
        _ = sql!(db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_reads_day','${cap_now}'),('strava_reads_today','9');")
        check!("...so the human line says tomorrow, not fifteen minutes", Str.contains(sh!("HOME='${home}' STRIDE_API_BASE='${base}' STRIDE_READS_PER_DAY=10 '${bin}' sync 2>/dev/null"), "again tomorrow"))?
    } else {
        # one read, two ids queued: stores the first, stops on the budget with one left
        check!("filling the 15-minute read window stops the run", bfq!(".data.stopped") == "budget_reached")?
        check!("...having stored exactly the one read it spent", bfq!(".data.streams_fetched") == "1")?
        check!("...with the untouched id still pending", bfq!(".data.pending_streams") == "1")?
        check!("...and resumable, because work remains", bfq!(".data.resumable") == "true")?

        # THE convergence proof, and the reason `backfill` could be deleted (#232): a
        # first run that stops on the read budget is not a dead end. Run it again and it
        # finishes, with no flag, no second command, and nothing for the user to know.
        # Without this, every other check here is satisfied by a sync that stops forever.
        _ = run_sync_bf!("json")
        check!("running it again converges — nothing left pending", bfq!(".data.pending_streams") == "0")?
        # it still reports `budget_reached` — it DID stop on the budget, and the queue
        # happened to empty on that same read. This is the case that proves `resumable`
        # must be measured (pending > 0) rather than derived from `stopped`: derived, this
        # run would claim work remains and the caller would loop forever on an empty queue.
        check!("...still reporting the budget stop, honestly", bfq!(".data.stopped") == "budget_reached")?
        check!("...yet NOT resumable, because nothing is left", bfq!(".data.resumable") == "false")?
        check!("...having stored the id the first run could not reach", bfq!(".data.streams_fetched") == "1")?
        check!("the budget-stopped payload conforms to the schema", Str.trim(sh!("jq '.data' '${bo}' 2>&1 | jq -r --slurpfile schema schemas/v2/sync.json -f tools/validate.jq 2>&1")) == "")?
        # fresh queue, same reason as the rate-limited branch above
        _ = sql!(db, "DELETE FROM streams;")
        _ = run_sync_bf!("human")
        check!("humans are told when to run it again, and it is not tomorrow", Str.contains(Str.trim(sh!("cat '${bo}'")), "in ~15 minutes"))?
    }

    _ = sh!("rm -rf '${home}'")
    check!("no fixture write errored", Str.is_empty(sqlite_errors!({})))?
    reset_sqlite_errors!({})
    # Per MODE. run_stops! has three branches of very different size, and a single floor
    # has to be the smallest of them — which makes it loosest where the branch is biggest.
    # At a shared floor of 8 the budget branch could lose a third of its checks unseen.
    checks_ran_at_least!(
        if env_or!("E2E_EXPECT_LIST_429", "") == "1" {
            # its own floor: this branch returns before the shared drain assertions, so the
            # 12 the default arm expects would never be reachable here
            26
        } else if env_or!("E2E_EXPECT_DAILY_CAP", "") == "1" {
            # its own floor, and TIGHT: a floor below the arm's own count lets a check be
            # deleted unseen — the slack this floor's own doctrine forbids.
            14
        } else if env_or!("E2E_EXPECT_500", "") == "1" {
            7
        } else if env_or!("E2E_EXPECT_401", "") == "1" {
            8
        } else if rate_limited {
            # 12 since this arm gained the daily-cap-via-429 pair — the path the daily
            # arm's own driver structurally cannot reach.
            12
        } else {
            12
        },
    )?
    Stdout.line!("STOP-REASON E2E CHECKS PASS")
}

# stride against the sandbox HOME + mock API base; local commands ignore the base
sync_stride! : Str, Str, Str, List(Str) => Str
sync_stride! = |bin, home, base, args|
    stride_env!(bin, home, args, [("STRIDE_FORMAT", "json"), ("STRIDE_API_BASE", base)])

sync_strjq! : Str, Str, Str, List(Str), Str => Str
sync_strjq! = |bin, home, base, args, filter| {
    argstr = List.fold(args, "", |acc, a| "${acc} '${a}'")
    Str.trim(sh!("HOME='${home}' STRIDE_FORMAT=json STRIDE_API_BASE='${base}' '${bin}' ${argstr} | jq -r '${filter}' 2>/dev/null"))
}

# Which page a listing URI asks for. A BOUNDARY test, because the query string is
# `?per_page=100&page=N`: "per_page=100" contains "page=1", and "page=10"/"page=100"
# contain "page=1" as well, so `Str.contains(uri, "page=1")` is true for every page any
# caller will ever request. One function so the two arms above cannot drift, and so the
# next arm added gets the boundary for free instead of re-deriving it.
page_is : Str, I64 -> Bool
page_is = |uri, n| {
    tok = "&page=${n.to_str()}"
    Str.contains(uri, "${tok}&") or Str.ends_with(uri, tok)
}

# Two pages of 100 — each exactly per_page, so fetch_pages! sees a full page and asks for
# the next one, and the sum (200) is a number no single page and no constant can produce.
# Ids 20001+ are clear of every fixture range. Generated rather than written out because
# the only property that matters is the COUNT.
mock_page_one : Str
mock_page_one = "[${bulk_rows(20001, 20100)}]"

mock_page_two : Str
mock_page_two = "[${bulk_rows(20101, 20200)}]"

bulk_rows : I64, I64 -> Str
bulk_rows = |i, last| {
    row = "{\"id\":${(i).to_str()},\"name\":\"bulk ${(i).to_str()}\",\"sport_type\":\"Ride\",\"start_date_local\":\"2026-06-01T10:00:00Z\",\"moving_time\":3600,\"distance\":20000.0,\"total_elevation_gain\":0.0,\"average_heartrate\":140.0}"
    if i >= last row else "${row},${bulk_rows(i + 1, last)}"
}

# poll the mock until it answers (pure Roc: curl via Cmd + Sleep, no shell loop)
wait_ready! : Str, U64 => {}
wait_ready! = |base, tries|
    if tries == 0 {
        {}
    } else if mock_up!(base) {
        {}
    } else {
        Sleep.millis!(200)
        wait_ready!(base, tries - 1)
    }

mock_up! : Str => Bool
mock_up! = |base|
    match Cmd.new(OsStr.from_str("curl")).args(List.map(["-sf", "-m", "1", "-X", "POST", "${base}/oauth/token"], OsStr.from_str)).exec_output!() {
        Ok(_) => True
        Err(_) => False
    }

# ── init + config ────────────────────────────────────────────────────
b_init_config! : Ctx => Try({}, _)
b_init_config! = |ctx| {
    check!("init reports initialized", Str.contains(stride!(ctx.bin, ctx.home, ["init"]), "initialized"))?
    # bumped to 2 when doctor renamed ftp_configured -> ftp_derived_sports: a renamed field
    # IS a shape change, and the envelope version is how a caller detects one
    check!("summary envelope is versioned", strjq!(ctx, ["summary"], ".schema_version") == "2")?
    check!("missing-config error code", Str.contains(stride!(ctx.bin, ctx.home, ["summary"]), "missing_config"))?
    # doctor's MissingConfig arm, reached here because the harness is already in exactly
    # that state — no zones set. This is the first screen a new user sees, and until this
    # check the arm could be garbled with nothing noticing.
    check!("doctor names the absent zone bounds rather than reporting a count", Str.contains(stride!(ctx.bin, ctx.home, ["doctor"]), "hr zone bounds are not set"))?
    # ── platform failures reach the caller as the contract (#183) ────────
    # A query before `stride init` used to die with `Program exited with error:
    # SqliteErr(CanNotOpen, …)` on stderr and EMPTY stdout — no code, no
    # envelope, and it was the first thing a new user met. These run against
    # throwaway HOMEs so the suite's own db is untouched.
    nodb = "${ctx.home}/nodb-probe"
    _ = sh!("rm -rf '${nodb}' && mkdir -p '${nodb}'")
    check!("a missing database is an envelope, not a banner", Str.contains(sh!("HOME='${nodb}' STRIDE_FORMAT=json '${ctx.bin}' summary 2>/dev/null"), "\"code\":\"no_database\""))?
    check!("...and says nothing on stderr", Str.trim(sh!("HOME='${nodb}' STRIDE_FORMAT=json '${ctx.bin}' summary 2>&1 >/dev/null")) == "")?
    check!("...and exits 1", stride_status!(ctx.bin, nodb, ["summary"]) == 1)?
    check!("...and humans get the same guidance in prose", Str.contains(sh!("HOME='${nodb}' '${ctx.bin}' summary 2>/dev/null"), "stride init"))?
    corrupt = "${ctx.home}/corrupt-probe"
    _ = sh!("rm -rf '${corrupt}' && mkdir -p '${corrupt}/.stride' && printf 'definitely not sqlite' > '${corrupt}/.stride/db.sqlite'")
    check!("a corrupt database is an envelope too", Str.contains(sh!("HOME='${corrupt}' STRIDE_FORMAT=json '${ctx.bin}' summary 2>/dev/null"), "\"code\":\"corrupt_database\""))?
    # the boundary must not swallow stride's OWN in-band errors, which have
    # already printed their envelope and raised Exit
    # Err(Exit(_)) MUST pass through the boundary untouched: err_out! already
    # printed the envelope and raised it, so converting it would print a second.
    # Asserting the code alone was vacuous — review built a binary with the
    # pass-through arm deleted and this check still passed, because the doubled
    # output CONTAINS the code. Count the envelopes instead.
    _ = sh!("HOME='${nodb}' STRIDE_FORMAT=json '${ctx.bin}' init >/dev/null 2>&1")
    inband = sh!("HOME='${nodb}' STRIDE_FORMAT=json '${ctx.bin}' sync 2>/dev/null")
    check!("in-band errors still arrive as themselves", Str.contains(inband, "not_authenticated"))?
    check!("...exactly once — the boundary must not re-wrap Exit", Str.trim(sh!("HOME='${nodb}' STRIDE_FORMAT=json '${ctx.bin}' sync 2>/dev/null | grep -c schema_version")) == "1")?
    # #232: `backfill` is retired — `sync` is the only command that pulls data, and
    # it answers `--json` with an envelope on every path including refusal. Asserting the
    # command is GONE rather than merely unused: a dispatch left behind would still run.
    bf_gone = Str.trim(sh!("HOME='${nodb}' STRIDE_FORMAT=json '${ctx.bin}' backfill 2>/dev/null"))
    check!("the retired backfill command is refused, with a pointer at its replacement", Str.contains(bf_gone, "usage") and Str.contains(bf_gone, "`stride sync` drains all missing streams"))?
    check!("...and it is absent from the machine command list", !(Str.contains(sh!("HOME='${nodb}' STRIDE_FORMAT=json '${ctx.bin}' --help 2>/dev/null"), "\"backfill\"")))?
    sync_unauth = Str.trim(sh!("HOME='${nodb}' STRIDE_FORMAT=json '${ctx.bin}' sync 2>/dev/null"))
    check!("sync refuses in-band, as one envelope", Str.contains(sync_unauth, "not_authenticated") and List.len(Str.split_on(sync_unauth, "\n")) == 1)?
    check!("...and exits non-zero", stride_status!(ctx.bin, nodb, ["sync"]) == 1)?
    _ = sh!("mkdir -p '${ctx.home}/freshinit'")
    check!("...and init on a fresh home still succeeds", stride_status!(ctx.bin, "${ctx.home}/freshinit", ["init"]) == 0)?
    _ = sh!("rm -rf '${nodb}' '${corrupt}' '${ctx.home}/freshinit'")
    # ── exit status (#163): the envelope is unchanged, the STATUS now carries
    # success/failure so shell callers stop reading errors as success.
    check!("an error envelope exits non-zero", stride_status!(ctx.bin, ctx.home, ["summary"]) == 1)?
    check!("an unknown command is an invocation error", stride_status!(ctx.bin, ctx.home, ["wat"]) == 1)?
    check!("...and machines get an envelope, not help text", Str.contains(stride!(ctx.bin, ctx.home, ["wat"]), "unknown_command"))?
    check!("a bare invocation asks for help, which is not an error", stride_status!(ctx.bin, ctx.home, []) == 0)?
    # ...and neither is asking for it by name — the catch-all this change
    # replaced was silently serving --help, and deleting it made help an error
    check!("--help is not an error", stride_status!(ctx.bin, ctx.home, ["--help"]) == 0)?
    check!("-h and bare help are not errors either", stride_status!(ctx.bin, ctx.home, ["-h"]) == 0 and stride_status!(ctx.bin, ctx.home, ["help"]) == 0)?
    # a REAL command with wrong arguments must not claim the command is unknown
    argerr = stride!(ctx.bin, ctx.home, ["sync", "extra"])
    check!("wrong arity on a real command is a usage error, not 'unknown'", Str.contains(argerr, "sync") and !(Str.contains(argerr, "unknown_command")))?
    # ── every machine response is an envelope (#180) ─────────────────────
    # These were the last two paths that handed a tool caller bare prose: a
    # usage error printed `usage: stride ...` as text, and a bare invocation
    # printed the whole human help screen.
    check!("a usage error is an envelope for machines", Str.contains(stride!(ctx.bin, ctx.home, ["config"]), "\"code\":\"usage\""))?
    check!("...and stays a plain line for humans", Str.contains(stride_human!(ctx.bin, ctx.home, ["config"]), "usage: stride config") and !(Str.contains(stride_human!(ctx.bin, ctx.home, ["config"]), "schema_version")))?
    # asking what stride can do is a QUESTION, not a failure: same exit 0 in
    # both modes, answered as data for machines and as the help screen for
    # humans — and `--help` is the same request, so it gets the same answer
    check!("a bare call answers with the command list, as data", strjq!(ctx, [], "[.data.commands[].name] | index(\"summary\") != null") == "true")?
    check!("--help answers identically for machines", strjq!(ctx, ["--help"], "[.data.commands[].name] | index(\"plan\") != null") == "true")?

    # ── the command table describes, it does not merely name (#219) ─────
    # A name list lets an agent enumerate and nothing more. These pin the four facts
    # it needs to CALL, and — more importantly — pin them against something other
    # than the table itself, because a table checked only against itself is a
    # restatement, not a test.
    cmdq! = |q| Str.trim(strjq!(ctx, [], q))
    check!("every form carries an argument shape", cmdq!("[.data.commands[] | select(.args == null)] | length") == "0")?
    check!("...and a schema or an explicit blank", cmdq!("[.data.commands[] | select(.schema == null)] | length") == "0")?
    # `week add` writes and `week` reads, which is the whole reason entries are per
    # callable FORM rather than per verb. If these ever collapse into one entry, the
    # payload starts answering `mutates` wrongly for one of them.
    check!("a verb with two forms is two entries", cmdq!("[.data.commands[].name] | (index(\"week\") != null) and (index(\"week add\") != null)") == "true")?
    check!("...that disagree about mutation, which is why they are separate", cmdq!("[.data.commands[] | select(.name == \"week\") | .mutates] == [false] and [.data.commands[] | select(.name == \"week add\") | .mutates] == [true]") == "true")?

    # Every schema a form names must EXIST. Read from the directory, so deleting a
    # schema file without updating the table fails here rather than at some caller.
    missing_schemas = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.commands[].schema | select(. != \"\")' | sort -u | while read -r f; do [ -f schemas/v2/\"$f\" ] || echo \"$f\"; done"))
    check!("every schema a form names exists in schemas/v2", missing_schemas == "")?
    # ...and the reverse: a schema nobody claims is a payload no agent can find its
    # way to. envelope.json is the wrapper every response shares, so it is claimed by
    # all of them and named by none.
    unclaimed = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.commands[].schema' | sort -u > /tmp/e2e-claimed.$$; ls schemas/v2 | grep -v '^envelope.json$' | while read -r f; do grep -qx \"$f\" /tmp/e2e-claimed.$$ || echo \"$f\"; done; rm -f /tmp/e2e-claimed.$$"))
    # Pinned as a VALUE, not waved through by an exclusion list: these two are reached
    # by flag rather than by subcommand — `--version` is listed under `flags`, and
    # commands.json is the schema of this very payload — so no command form names
    # them. Stating the exact set means a genuinely unclaimed schema changes the
    # string and fails, where an exclusion list would quietly absorb it.
    check!("the only schemas no command form claims are the two no SUBCOMMAND claims", unclaimed == "commands.json\nversion.json")?
    # The guard that makes the two lines above non-vacuous: if the jq produced nothing
    # at all, both comparisons are "" == "" and pass on an empty payload.
    check!("...and that pair was not comparing two empty lists", cmdq!("[.data.commands[] | select(.schema != \"\")] | length > 20") == "true")?

    # THE acceptance check: adding a command without describing it fails here.
    #
    # Read from the PARSER rather than from the table, so the two are compared against
    # each other instead of the table being compared to itself. Every arm that yields a
    # real command — `=> Ok(` or `=> count(` — contributes its verb; arms yielding
    # Err(Usage) are excluded on purpose, because those are arity hints and retired
    # names like `backfill`, which must NOT be advertised. Flag and `help` forms are
    # dropped from both sides, matching what the payload itself filters.
    #
    # Verb level. The FORM level is a separate comparison, below — and it has to be, in
    # both directions. The check that follows this one walks the table's forms and asks
    # whether the parser reaches them; that is table→parser. Nothing asked the reverse
    # until the sub-form pin further down, and without it `[_, "week", "remove", id]`
    # dispatched as a real callable sub-form with no table entry and the suite stayed
    # green. This PR gives `week add` its own entry, its own `mutates` and its own
    # schema — by that standard `week remove` is a command, and "adding a command
    # without describing it fails a test" has to hold for it too.
    # NO PROCESS SUBSTITUTION. `sh!` spawns `sh`, which on macOS is bash 3.2 in POSIX
    # mode, where `<(...)` is a SYNTAX ERROR. The first version of these two checks used
    # it, so `comm` never ran, both variables were always "" and both comparisons were
    # "" == "" — they had never executed a single comparison since the day they were
    # written. Review found it by mutating `pz` to `pzz` and watching the whole suite go
    # green while the table advertised a command the parser does not have. Temp files.
    #
    # The extraction takes the FIRST LITERAL of every arm, and does not look at what the
    # arm yields. Keying on `=> Ok(` or `=> count(` seemed right — it excludes the arity
    # hints — but it cannot see an arm that VALIDATES its argument, because that yields an
    # `if` and spans several lines. Review built one:
    #
    #     [_, "hrv", date] =>
    #         if Metrics.is_canonical_date(date) { Ok(Zones) } else { Err(Usage(...)) }
    #
    # `stride hrv <date>` dispatched, the table did not describe it, and the whole suite
    # was green. That is not a hypothetical shape: `reps` in src/Command.roc is
    # written exactly that way, and only survives because a second single-line arm happens
    # to contribute the same verb.
    #
    # Yield-blind extraction means retired names come back too, so the ONE name the table
    # deliberately does not advertise is pinned as a value below rather than filtered by a
    # rule — retiring a command becomes a stated act instead of a silent one.
    #
    # The character class is [A-Za-z0-9_-], not [a-z-]. The narrow version could not see an
    # arm named `zone2`, `power_curve` or `Doctor2`.
    #
    # COMMENTS ARE STRIPPED FIRST. grep reads the file as text, and a comment elsewhere in
    # this repo quotes `[_, "stats"] => Ok(Stats)` while describing a past regression — so
    # that comment fed `stats` into the parser side, and deleting the real arm left every
    # verb check green. The comment documenting the class of bug had become a vector for
    # it. Verified safe: no arm pattern contains a `#`, and the strip leaves the verb set
    # on pristine source identical.
    #
    # Whitespace INSIDE the pattern is tolerated. `[_,"hrv"]` with no space after the comma
    # is a real, callable, undescribed command that the tight pattern could not see, and
    # nothing normalises spacing here — `roc fmt` is blocked upstream (#27).
    #
    # LC_ALL=C so the retired-name pin below compares against a stable collation rather
    # than the runner's locale.
    verbs_dir = "${ctx.home}/.verbs"
    parser_verbs = "sed 's/#.*//' src/Command.roc | grep -oE '\\[[[:space:]]*_[[:space:]]*,[[:space:]]*\"[A-Za-z0-9_-]+\"' | sed 's/.*\"\\([A-Za-z0-9_-]*\\)\"/\\1/' | grep -v '^-' | grep -vx help | LC_ALL=C sort -u"
    spec_verbs = "HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.commands[].name | split(\" \")[0]' | LC_ALL=C sort -u"
    _ = sh!("rm -rf '${verbs_dir}' && mkdir -p '${verbs_dir}' && ${parser_verbs} > '${verbs_dir}/parser' && ${spec_verbs} > '${verbs_dir}/spec'")
    # `backfill` and nothing else. It is the one arm that answers a name with a pointer
    # instead of a command (#232), so it must NOT be advertised — and pinning it as a
    # value means a second undescribed command changes this string and fails, where a
    # filter rule would have quietly absorbed it.
    undescribed = Str.trim(sh!("LC_ALL=C comm -23 '${verbs_dir}/parser' '${verbs_dir}/spec' | tr '\\n' ' '"))
    check!("the parser accepts nothing the table omits, beyond deliberately retired names (got: ${undescribed})", undescribed == "backfill")?
    unparsed = Str.trim(sh!("LC_ALL=C comm -13 '${verbs_dir}/parser' '${verbs_dir}/spec' | tr '\\n' ' '"))
    check!("...and every described command is one the parser accepts (extra: ${unparsed})", unparsed == "")?
    # This pins the SIZE of the command set, and that is now its only unique job. It was
    # added as the non-vacuity guard — pinning the two inputs was the mistake that let a
    # silently-broken `comm` through — but once `undescribed` became a pin on a VALUE
    # rather than on emptiness, it catches every vacuity mode on its own. What survives
    # here is the deliberate-bump discipline: adding a properly described command still
    # has to change a number a reader sees.
    overlap = Str.trim(sh!("LC_ALL=C comm -12 '${verbs_dir}/parser' '${verbs_dir}/spec' | wc -l | tr -d ' '"))
    check!("...and the two lists genuinely overlap on all 27 verbs (got ${overlap})", overlap == "27")?
    _ = sh!("rm -rf '${verbs_dir}'")

    # The sub-form direction. `unknown_command` was the wrong discriminator: it can only
    # come from an unknown FIRST token, which the verb comparison already covers, so
    # `week frobnicate` and `week add` were indistinguishable and renaming a sub-form went
    # undetected. Invoke each multi-word form WITH its declared required arguments and
    # require an answer that is not `usage` — that is what distinguishes a form the parser
    # has from one it does not.
    # Run against a DISCARDED COPY, not the fixture. Two of the three multi-word forms
    # write — `week add` and `config set` — and an earlier version invoked them against
    # ctx.home. That inserted the suite's first planned_sessions row, taking id 1, which
    # collides with a stray-write guard 1500 lines below that asserts "the very next add
    # must still be id 1". The suite passed anyway, by luck: the probe landed on ctx.d1
    # and the next add on that date REVISED it in place rather than inserting. Change
    # either date and the suite breaks far from the cause.
    #
    # An initialised copy, not a bare temp dir: the discriminator is "not usage", and an
    # empty HOME answers `no_database` to everything, which is also not usage — the check
    # would pass on nothing.
    sub_probe = "${ctx.home}/.sub-probe"
    _ = sh!("rm -rf '${sub_probe}' && mkdir -p '${sub_probe}' && cp -R '${ctx.home}/.stride' '${sub_probe}/.stride'")
    subform_cmds = "jq -r '.data.commands[] | select(.name | test(\" \")) | [.name] + [.args[] | select(.required) | .name | if test(\"YYYY-MM-DD\") then \"${ctx.d1}\" else \"1\" end] | join(\" \")'"
    bad_forms = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | ${subform_cmds} | { while read -r line; do code=$(HOME='${sub_probe}' STRIDE_FORMAT=json '${ctx.bin}' $line 2>/dev/null | jq -r '.error.code // \"ok\"'); [ \"$code\" = \"usage\" ] && echo \"$line\"; done; true; } | tr '\\n' ' '"))
    check!("every multi-word form the table names is one the parser reaches (bad: ${bad_forms})", bad_forms == "")?
    n_multi = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '[.data.commands[].name | select(test(\" \"))] | length'"))
    n_probed = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | ${subform_cmds} | wc -l | tr -d ' '"))
    check!("...and every multi-word form was probed (${n_probed} of ${n_multi})", n_probed == n_multi and n_multi != "0")?
    _ = sh!("rm -rf '${sub_probe}'")

    # parser→table at the FORM level. Every two-literal arm the parser has must be
    # accounted for by the table: either as a multi-word form name, or as a literal
    # argument of its verb — the table already distinguishes the two, modelling `week all`
    # as `week`'s optional literal arg and `week add` as a form of its own, so no rule has
    # to guess.
    #
    # What is left over is pinned as a VALUE — see the note beside the accounted side for
    # which leftovers survive and why. A new entry appearing there means a real sub-form
    # was added without a table entry, and the failure prints it.
    pair_dir = "${ctx.home}/.pairs"
    # The arm's FULL leading literal run, not its first two. A two-literal capture set the
    # depth rather than removing it: `[_, "week", "add", "bulk", p]` contributed `week add`,
    # which is already accounted for, so a real three-token form was invisible. Measured to
    # yield the identical nine paths on pristine source, so this is depth-independence at
    # no cost to the pinned value.
    parser_pairs = "sed 's/#.*//' src/Command.roc | grep -oE '\\[[[:space:]]*_([[:space:]]*,[[:space:]]*\"[A-Za-z0-9_-]+\")+' | sed 's/\\[[[:space:]]*_[[:space:]]*,[[:space:]]*//; s/\"//g; s/[[:space:]]*,[[:space:]]*/ /g' | grep ' ' | LC_ALL=C sort -u"
    # Enum placeholders are EXPANDED, so `<asc|desc>` accounts for `progress asc` and
    # `progress desc`. Without that they landed in the leftover list and the comment called
    # them "not commands" — but `[_, "progress", "asc"] => Ok(...)` dispatches, so they are
    # commands the jq simply could not match. The list was conflating "not a command" with
    # "a command this extraction cannot see", and hard-coding the second as excused.
    table_pairs = "HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '(.data.commands[] | select(.name|test(\" \")) | .name), (.data.commands[] | . as $c | .args[]? | .name | (if test(\"^<\") then (if test(\"[|]\") then (ltrimstr(\"<\")|rtrimstr(\">\")|split(\"|\")[]) else empty end) else . end) | select(test(\"^[A-Za-z0-9_-]+$\")) | \"\\($c.name) \\(.)\")' | LC_ALL=C sort -u"
    _ = sh!("rm -rf '${pair_dir}' && mkdir -p '${pair_dir}' && ${parser_pairs} > '${pair_dir}/parser' && ${table_pairs} > '${pair_dir}/table'")
    unaccounted = Str.trim(sh!("LC_ALL=C comm -23 '${pair_dir}/parser' '${pair_dir}/table' | tr '\\n' '|'"))
    # Two leftovers now, not four: the plan/week redirect arms. Those genuinely are not
    # commands — they answer a retired name with a pointer. The sort hints left the list
    # when the enum expansion started accounting for them.
    check!("every sub-form the parser has is accounted for, bar the two redirect arms (got: ${unaccounted})", unaccounted == "plan add|plan all|")?
    # Non-zero, not a literal count. A literal here is bump-bait: it changed the moment
    # enum expansion started accounting for two more paths, and its failure could not say
    # which direction to look. What this guards is that the accounted side produced
    # SOMETHING, so the comm above is not comparing against an empty file.
    check!("...and the table accounted for some of them, so that was not a comparison against nothing", Str.trim(sh!("wc -l < '${pair_dir}/table' | tr -d ' '")) != "0")?
    # The REVERSE direction. `comm -23` is parser-minus-table, so a token the TABLE invents
    # is invisible to it: giving `week` an `opt("recent")` advertises a literal a user is
    # told to type verbatim and the parser refuses, with nothing failing. The size pin that
    # used to sit here caught that incidentally, and I removed it on a premise I had
    # mis-measured by a factor of six. This is what it was carrying, as a property rather
    # than a count — it pins as empty, names the offender, and needs no bump when a command
    # is added.
    _ = sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.commands[] | . as $c | .args[]? | select(.name|test(\"^<\")|not) | \"\\($c.name) \\(.name)\"' | LC_ALL=C sort -u > '${pair_dir}/literals'")
    unaccepted = Str.trim(sh!("LC_ALL=C comm -23 '${pair_dir}/literals' '${pair_dir}/parser' | tr '\\n' '|'"))
    check!("every literal argument the table advertises is one the parser accepts (got: ${unaccepted})", unaccepted == "")?
    check!("...and there were literal arguments to check", Str.trim(sh!("wc -l < '${pair_dir}/literals' | tr -d ' '")) != "0")?
    _ = sh!("rm -rf '${pair_dir}'")

    _ = sh!("rm -rf '${pair_dir}'")
    # The fixture must be untouched by the probe above — that is the property the earlier
    # version broke, so it is asserted rather than assumed.
    check!("...leaving the fixture's session log empty, as it was", Str.trim(sql!(ctx.db, "SELECT count(*) FROM planned_sessions;")) == "0")?

    # `mutates` CHECKED AGAINST BEHAVIOUR, not trusted. Every form declaring
    # mutates:false runs against a copy of the fixture and the database CONTENTS must not
    # move. Without this the flag is a comment, and an agent told a command is read-only
    # would be acting on a declaration nobody checked.
    #
    # Contents, not file bytes. Hashed through `sqlite3 .dump`: the database runs in WAL
    # mode, so a committed write can leave db.sqlite byte-identical and land in the -wal
    # sidecar. The first version of this sweep hashed the file and would have passed with
    # every command writing; the proof at the end is what caught it.
    #
    # Arguments come from the TABLE'S OWN `args`, one filler per required argument,
    # optional ones omitted. An earlier version appended a blanket `1 1` to every form,
    # which made 15 of the 19 forms a wrong arity — `parse` rejected them before dispatch
    # ever ran, so the hash comparison was a tautology for all but four. That is the
    # failure this repo keeps hitting: the check was green and measuring nothing, and its
    # own "did the sweep run" guard counted the jq list rather than the executions.
    #
    # The filler is chosen from the placeholder text, because a wrong-TYPE value is
    # rejected by the parser just as an arity error is: `reps 1` answers "not a date" and
    # never dispatches. A wrong-VALUE argument is fine and still exercises the command —
    # `activity 1` reaching activity_not_found has run the handler, which is the point.
    # The probe database is SEEDED, not just copied. This block runs before the fixture
    # scenarios, so the copy is empty, and a command that writes only when there is data
    # to write cannot be caught on an empty database however good its arguments are.
    # Review demonstrated it: mislabelling `rate` as read-only left the sweep green,
    # because `rate` on an empty database finds no activity and returns rather than
    # writing. One activity closes that.
    ro_probe = "${ctx.home}/.ro-probe"
    _ = sh!("rm -rf '${ro_probe}' && mkdir -p '${ro_probe}' && cp -R '${ctx.home}/.stride' '${ro_probe}/.stride'")
    _ = sql!("${ro_probe}/.stride/db.sqlite", "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time,distance,weighted_avg_watts,avg_watts,avg_hr) VALUES (1,'ro probe','Ride','${ctx.d1}T10:00:00Z',3600,20000,180,180,140);")
    fillers = "jq -r '.data.commands[] | select(.mutates == false) | [.name] + [.args[] | select(.required) | .name | if test(\"YYYY-MM-DD\") then \"${ctx.d1}\" elif test(\"hr\\\\|tss\") then \"tss\" elif test(\"week\\\\|month\") then \"week\" elif test(\"1-10\") then \"5\" else \"1\" end] | join(\" \")'"
    dirty = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | ${fillers} | while read -r line; do before=$(sqlite3 '${ro_probe}/.stride/db.sqlite' .dump | shasum | cut -d' ' -f1); HOME='${ro_probe}' STRIDE_FORMAT=json '${ctx.bin}' $line >/dev/null 2>&1; after=$(sqlite3 '${ro_probe}/.stride/db.sqlite' .dump | shasum | cut -d' ' -f1); [ \"$before\" = \"$after\" ] || echo \"$line\"; done; true"))
    check!("every form declaring mutates:false leaves the database contents unmoved", dirty == "")?
    # The guard that matters: how many forms REACHED their handler. Counting the jq list
    # instead — which is what this used to do — reports green on a sweep where every
    # invocation bounced off the parser.
    # Compared to the OTHER COUNT measured in the same run, not to a literal. A literal
    # here was bump-bait: its failure message could not say which direction to look, so
    # the natural repair was to edit the number — which is the repair that removes the
    # guard. Two counts cannot be reconciled that way, and adding a read-only command
    # needs no edit at all. The loop names the forms that did not arrive.
    stalled = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | ${fillers} | { while read -r line; do code=$(HOME='${ro_probe}' STRIDE_FORMAT=json '${ctx.bin}' $line 2>/dev/null | jq -r '.error.code // \"ok\"'); [ \"$code\" = \"usage\" ] && echo \"$line\"; done; true; } | tr '\\n' ' '"))
    declared_ro = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '[.data.commands[] | select(.mutates == false)] | length'"))
    check!("...and every read-only form actually reached its handler (stalled: ${stalled})", stalled == "")?
    check!("...with ${declared_ro} of them declared, and at least one to sweep", declared_ro != "0")?

    # COMMENTS STRIPPED FIRST. These grep the source, and a comment naming `Http.send!`
    # counts as a call site — a doc comment added in this very PR said "Http.send! is
    # pinned to two functions" and turned `Command.roc` into a second module that reaches
    # Strava. Same defect the verb extraction had, in a different check, found the same
    # way: by a comment breaking it.
    #
    # `network` against the SOURCE, not against itself. An earlier version of the schema
    # description claimed a test pinned this set; none did, which is worse than saying
    # nothing — a reader trusts an enforcement that is not there. Http.send! is the only
    # way out to Strava, and it lives in exactly two functions, both in Strava.roc: the
    # token exchange and the bearer GET. The commands that can reach them are auth and
    # sync, so that is what the table must say.
    check!("the network set is exactly auth and sync", cmdq!("[.data.commands[] | select(.network) | .name] | sort") == "[\n  \"auth\",\n  \"sync\"\n]")?
    check!("...and Strava is still reachable from exactly two call sites", Str.trim(sh!("sed 's/#.*//' src/Strava.roc | grep -c 'Http.send!'")) == "2")?
    check!("...with no other module able to reach one", Str.trim(sh!("for f in src/*.roc; do sed 's/#.*//' $f | grep -q 'Http.send!' && printf '%s' $f; done")) == "src/Strava.roc")?
    # `interactive` the same way: Stdin is what blocking on a human looks like, and it
    # appears once in the whole source, inside the auth flow.
    check!("the interactive set is exactly auth", cmdq!("[.data.commands[] | select(.interactive) | .name]") == "[\n  \"auth\"\n]")?
    check!("...and stdin is read from exactly one place", Str.trim(sh!("sed 's/#.*//' src/Strava.roc | grep -c 'Stdin\\.'")) == "1")?
    check!("...which is the only module that reads it", Str.trim(sh!("for f in src/*.roc; do sed 's/#.*//' $f | grep -q 'Stdin\\.' && printf '%s' $f; done")) == "src/Strava.roc")?
    # The mutation-proof for the sweep itself: a form that DOES write, run the same way,
    # must be caught. `week add` is declared mutates:true so it is not in the sweep, and
    # it is chosen over `rate` because it writes unconditionally — `rate` depends on the
    # fixture holding the activity id it is given, which makes a silent no-op possible
    # and would leave this proof asserting nothing.
    rate_before = Str.trim(sh!("sqlite3 '${ro_probe}/.stride/db.sqlite' .dump | shasum | cut -d' ' -f1"))
    _ = sh!("HOME='${ro_probe}' STRIDE_FORMAT=json '${ctx.bin}' week add '${ctx.d2}' endurance 'ro probe' 'ro probe' >/dev/null 2>&1")
    rate_after = Str.trim(sh!("sqlite3 '${ro_probe}/.stride/db.sqlite' .dump | shasum | cut -d' ' -f1"))
    check!("...and the sweep's method detects a write, so passing it means something", rate_before != rate_after)?
    _ = sh!("rm -rf '${ro_probe}'")

    check!("-h and help answer the same way", strjq!(ctx, ["-h"], ".data.commands | length > 0") == "true" and strjq!(ctx, ["help"], ".data.commands | length > 0") == "true")?
    check!("...and all four stay exit 0", stride_status!(ctx.bin, ctx.home, []) == 0 and stride_status!(ctx.bin, ctx.home, ["--help"]) == 0 and stride_status!(ctx.bin, ctx.home, ["-h"]) == 0 and stride_status!(ctx.bin, ctx.home, ["help"]) == 0)?
    check!("humans still get the help screen", Str.contains(stride_human!(ctx.bin, ctx.home, []), "USAGE") and !(Str.contains(stride_human!(ctx.bin, ctx.home, []), "schema_version")))?
    check!("...and still exits non-zero", stride_status!(ctx.bin, ctx.home, ["sync", "extra"]) == 1)?
    # the FLAG path owns the exit code too (#162's re-exec wrapper): without
    # Err(Exit(child_code)) the parent collapses every child status to 1 and
    # stacks a platform banner on the child's own message. Deleting that arm
    # passed the entire suite before this check existed.
    check!("an error through --json propagates the child's status", stride_status!(ctx.bin, ctx.home, ["--json", "activity", "99999999"]) == 1)?
    # (a db-free success: at this point in the fixture almost every query is
    # legitimately an error, and --version exercises the same re-exec path)
    check!("...and success through --json still exits 0", stride_status!(ctx.bin, ctx.home, ["--json", "--version"]) == 0)?
    check!("...with no platform banner stacked on the envelope", Str.contains(stride!(ctx.bin, ctx.home, ["--json", "activity", "99999999"]), "activity_not_found"))?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "hr_z1_max", "123"])
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "hr_z2_max", "153"])
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "hr_z3_max", "168"])
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "hr_z4_max", "183"])
    # #154 ""-arm: no activities yet, so TSB is unknown and analyze must say so
    # honestly — form_state "" (absent), never a fabricated band id
    check!("analyze form_state is honestly empty pre-data", strjq!(ctx, ["analyze"], ".data.form_state == \"\" and .data.form_tsb_known == false") == "true")?
    Ok({})
}

# ── auth without creds: setup guidance, not a raw MissingEnv crash ────
b_auth! : Ctx => Try({}, _)
b_auth! = |ctx| {
    # mirror the bash: unset any real creds (env -u) and feed EOF on stdin
    out = sh!("env -u STRAVA_CLIENT_ID -u STRAVA_CLIENT_SECRET HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' auth < /dev/null")
    check!("credless auth gives setup guidance", Str.contains(out, "missing_client_creds"))?
    Ok({})
}

# ── power zones: watt ranges from the DERIVED ride FTP (190, from b_seed_analyze!'s
# 200W stream). Runs after seed+analyze so a derived FTP exists. ──────────────────────
b_pz! : Ctx => Try({}, _)
b_pz! = |ctx| {
    check!("pz has 7 power zones", strjq!(ctx, ["pz"], ".data.zones | length") == "7")?
    check_near!("pz z4 lo ~173 (FTP 190)", sfloat(strjq!(ctx, ["pz"], ".data.zones[3].lo_w")), 172.9, 1.0)?
    check_near!("pz z4 hi ~200 (FTP 190)", sfloat(strjq!(ctx, ["pz"], ".data.zones[3].hi_w")), 199.5, 1.0)?
    check!("pz z1 opens at 0", strjq!(ctx, ["pz"], ".data.zones[0].lo_w") == "0")?
    check!("pz z7 open above (hi 0)", strjq!(ctx, ["pz"], ".data.zones[6].hi_w") == "0")?
    Ok({})
}

# ── config set/get: local key-value store. FTP keys are REFUSED (ADR 0005 — derived from
# power history, never configured). Everything else round-trips except two classes:
# validated keys reject malformed values (exponent zone bounds, an out-of-range or signed
# utc_offset_minutes), asserted in this function; and secret keys store but read back
# redacted, asserted in b_cred_safety! rather than here. ──────────────────────────────
b_config_ftp! : Ctx => Try({}, _)
b_config_ftp! = |ctx| {
    # FTP is DERIVED (ADR 0005): setting it must be refused, not silently stored. This block
    # used to assert the opposite — that `config set ftp_ride 195` reported "ftp_ride = 195"
    # — which is exactly the trap: a confirmation for a value the engine never reads.
    set_out = stride!(ctx.bin, ctx.home, ["config", "set", "ftp_ride", "195"])
    check!("setting a derived key is refused", Str.contains(set_out, "derived_key"))?
    check!("refusal explains where FTP comes from", Str.contains(set_out, "power history"))?
    check!("reading a derived key is refused too", Str.contains(stride!(ctx.bin, ctx.home, ["config", "get", "ftp_ride"]), "derived_key"))?
    # #201: a numeric key is validated at the WRITE. Narrowing only the READ made
    # `config set hr_z1_max 1.18e2` succeed, echo back, and then report missing_config --
    # a stored value that parses nowhere, which is the same trap as one read nowhere.
    # `utc_offset_minutes +330` was the silent version: it became UTC instead of +05:30.
    check!("a numeric key refuses exponent notation at set time", Str.contains(stride!(ctx.bin, ctx.home, ["config", "set", "hr_z1_max", "1.18e2"]), "bad_value"))?
    # "+330" parsed fine on both pins -- it becomes 0 only because THIS PR narrowed the
    # read in Db.roc, which is why the refusal has to live at the write.
    # the write gate must accept exactly what the READ can parse. It checked syntax only,
    # so an overflowing but well-formed integer stored fine and then failed every read --
    # a value permanently ignored, which is the trap this gate exists to prevent. Only the
    # INT side is pinned: I64 overflows at 19 digits, which a human can fat-finger, while
    # F64 needs 300+ and a literal that long says nothing a reader would learn from.
    check!("a value too large for the reader is refused at the write", Str.contains(stride!(ctx.bin, ctx.home, ["config", "set", "utc_offset_minutes", "99999999999999999999"]), "bad_value"))?
    check!("...and refuses a leading +, which this narrowing would otherwise coalesce to 0", Str.contains(stride!(ctx.bin, ctx.home, ["config", "set", "utc_offset_minutes", "+330"]), "bad_value"))?
    check!("...while the plain forms still store", strjq!(ctx, ["config", "set", "hr_z1_max", "118.5"], ".data.value") == "118.5")?
    check!("...and a free-text key is untouched by the rule", strjq!(ctx, ["config", "set", "timezone", ctx.tz], ".data.value") == ctx.tz)?
    # #206: a LEGACY row -- written by SQL, as one written before the write-side
    # validation existed would be -- must be reported, not coalesced. `+330` parsed fine
    # on both compiler pins, so this is exactly what an athlete could have stored.
    _ = sql!(ctx.db, "DELETE FROM config WHERE key='timezone'; INSERT OR REPLACE INTO config VALUES ('utc_offset_minutes','+330');")
    check!("an unreadable stored offset is named, not silently UTC", Str.contains(strjq!(ctx, ["doctor"], ".data.time"), "not a whole number"))?
    check!("...and it fails time_ok rather than passing as a UTC setting", strjq!(ctx, ["doctor"], ".data.time_ok") == "false")?
    _ = sql!(ctx.db, "UPDATE config SET value='-300' WHERE key='utc_offset_minutes';")
    check!("...while a readable one still resolves", Str.contains(strjq!(ctx, ["doctor"], ".data.time"), "fixed offset -05:00"))?
    # an unreadable HR zone is NOT missing_config: the key is present and config get
    # echoes it, so telling the athlete to set it sends them to the wrong place
    _ = sql!(ctx.db, "DELETE FROM config WHERE key='utc_offset_minutes'; UPDATE config SET value='1.18e2' WHERE key='hr_z1_max';")
    check!("an unreadable zone bound says unreadable, not missing", Str.contains(stride!(ctx.bin, ctx.home, ["analyze"]), "unreadable_config"))?
    # ...and doctor's GLOBAL-key arm, the third of its three, reached from the same state.
    # `plan` exits 1 here; doctor degrades and names the key, which is the asymmetry the
    # schema describes.
    check!("doctor degrades on an unreadable GLOBAL zone key too", Str.contains(stride!(ctx.bin, ctx.home, ["doctor"]), "hr_z1_max is set to '1.18e2'"))?
    _ = sql!(ctx.db, "UPDATE config SET value='118' WHERE key='hr_z1_max';")
    # the PER-SPORT variant: an unreadable override silently used the global ceiling, so
    # the athlete's sport zones were ignored with nothing to see. Absent still falls back
    # -- that is designed -- so the next two lines pin both halves.
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO config VALUES ('hr_z2_max_soccer','1.5e2');")
    check!("an unreadable per-sport zone is refused, not silently globalised", Str.contains(stride!(ctx.bin, ctx.home, ["analyze"]), "unreadable_config"))?
    _ = sql!(ctx.db, "DELETE FROM config WHERE key='hr_z2_max_soccer';")
    check!("...while an ABSENT per-sport zone still falls back to the global", Str.contains(stride!(ctx.bin, ctx.home, ["analyze"]), "\"computed\":"))?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "timezone", ctx.tz])

    # the trap this closes: a db from before FTP was derived still holds an ftp_ride row.
    # Setting is refused, so only a LEGACY row can exist — and it must not be echoed back.
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO config (key,value) VALUES ('ftp_ride','999');")
    legacy = stride!(ctx.bin, ctx.home, ["config", "get", "ftp_ride"])
    check!("a LEGACY stored value is not echoed", !(Str.contains(legacy, "999")))?
    check!("legacy read explains why", Str.contains(legacy, "derived_key"))?
    _ = sql!(ctx.db, "DELETE FROM config WHERE key='ftp_ride';")

    # a configurable key still round-trips normally
    # config set success is now a JSON envelope for tools (matching the refusal path) —
    # assert the envelope, and the human line separately
    check!("config set emits the JSON envelope", strjq!(ctx, ["config", "set", "timezone", ctx.tz], ".data.value") == ctx.tz)?
    check!("config set human line", Str.contains(stride_human!(ctx.bin, ctx.home, ["config", "set", "timezone", ctx.tz]), "timezone = ${ctx.tz}"))?
    check!("value stored + read back (human)", Str.trim(stride_human!(ctx.bin, ctx.home, ["config", "get", "timezone"])) == ctx.tz)?
    # ── explicit format flags (#162): the flag beats the environment, works in
    # any argv position, and the last flag wins. stride_env! pins STRIDE_FORMAT
    # so each check is a real precedence fight, not an ambient default.
    # #181: STRIDE_FORMAT is the ONLY environment input to the mode. Stride used
    # to sniff a tool-specific variable as well; the invariant that replaced it
    # is stronger and vendor-neutral — no other environment variable, whatever a
    # harness happens to export, may produce machine output.
    # `env -u`, not the stride_env! helper: Cmd.env can only SET, so passing
    # STRIDE_FORMAT="" lands in the Ok arm of json_mode! and short-circuits
    # before any fallback is reached — the check could not fail for the
    # regression it names. Review proved it by restoring a fallback on AGENT
    # (a variable this very check sets) and watching the suite stay green.
    ambient_sh = "env -u STRIDE_FORMAT AGENT=1 CI=true TERM=dumb CLAUDECODE=1 HOME='${ctx.home}' '${ctx.bin}' config get timezone"
    check!("no ambient variable selects JSON", !(Str.contains(sh!(ambient_sh), "schema_version")))?
    check!("...only the flag does, with the environment saying nothing", Str.contains(sh!("${ambient_sh} --json"), "schema_version"))?
    check!("--json beats STRIDE_FORMAT=human", Str.contains(stride_env!(ctx.bin, ctx.home, ["config", "get", "timezone", "--json"], [("STRIDE_FORMAT", "human")]), "schema_version"))?
    check!("--human beats STRIDE_FORMAT=json", !(Str.contains(stride_env!(ctx.bin, ctx.home, ["config", "get", "timezone", "--human"], [("STRIDE_FORMAT", "json")]), "schema_version")))?
    check!("flag position is free (before the subcommand)", Str.contains(stride_env!(ctx.bin, ctx.home, ["--json", "config", "get", "timezone"], [("STRIDE_FORMAT", "human")]), "schema_version"))?
    check!("last flag wins", Str.contains(stride_env!(ctx.bin, ctx.home, ["config", "get", "timezone", "--human", "--json"], [("STRIDE_FORMAT", "human")]), "schema_version"))?
    check!("args survive the strip (value intact)", Str.contains(stride_env!(ctx.bin, ctx.home, ["config", "get", "timezone", "--json"], [("STRIDE_FORMAT", "human")]), ctx.tz))?
    # `--` ends flag parsing, proven by ROUND TRIP rather than by absence: the
    # literal "--json" must land in the database as the skip reason, and the
    # requested format must survive the escape (the first version of this check
    # asserted only that the output was neither JSON nor the config value — it
    # passed against help text, and would have passed with `--` unimplemented).
    term_sess = Str.trim(strjq!(ctx, ["week", "add", "2099-06-06", "endurance", "terminator probe", "r"], ".data.id"))
    term_out = stride_env!(ctx.bin, ctx.home, ["--json", "skip", term_sess, "--", "--json"], [("STRIDE_FORMAT", "human")])
    check!("`--` protects a literal flag argument", Str.trim(sql!(ctx.db, "SELECT COALESCE(skipped_reason,'') FROM planned_sessions WHERE id = ${term_sess};")) == "--json")?
    check!("...and the requested format still wins", Str.contains(term_out, "schema_version"))?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id = ${term_sess};")
    check!("config get json value", strjq!(ctx, ["config", "get", "timezone"], ".data.value") == ctx.tz)?
    check!("config get not_set error", Str.contains(stride!(ctx.bin, ctx.home, ["config", "get", "nope"]), "not_set"))?
    # delete the row rather than storing "" — not because they differ (Db.roc collapses
    # both to NoTz, and doctor reports the same UTC fallback for each; that equivalence
    # is pinned in b_doctor!) but because an absent row is the state a fresh install is
    # actually in.
    _ = sql!(ctx.db, "DELETE FROM config WHERE key='timezone';")
    # ...and ASSERT the absent path, which nothing did before: the DELETE sat as the last
    # statement of this function with no observation of its effect, so it proved nothing
    # while still changing the clock for every check that followed. With no timezone and
    # no utc_offset_minutes, doctor must report the UTC fallback rather than an error.
    check!("absent timezone falls back to UTC, not an error", Str.contains(strjq!(ctx, ["doctor"], ".data.time"), "UTC") and strjq!(ctx, ["doctor"], ".data.time_ok") == "true")?
    # ...then put it back, because the harness is now anchored to ${tz}: an absent row
    # leaves the binary on UTC, and the two would disagree for the rest of the run.
    #
    # This DELETE was NOT the cause of #200, though an earlier revision of this fix said
    # so. On main the harness computed its dates with `date -u` and a fresh binary also
    # defaults to UTC, so the DELETE returned them to AGREEMENT -- it was harmless there,
    # and only became harmful once the harness moved to ${tz}. The line that actually
    # broke the run is the `validate!("config set timezone ...")` in b_seed_analyze!.
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "timezone", ctx.tz])
    Ok({})
}

# ── credential safety: secrets never surface, db is owner-only ────────
b_cred_safety! : Ctx => Try({}, _)
b_cred_safety! = |ctx| {
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_access_token','SECRETVAL123');")
    sec_out = stride!(ctx.bin, ctx.home, ["config", "get", "strava_access_token"])
    check!("secret key reports redacted", Str.contains(sec_out, "\"redacted\":true"))?
    check!("secret VALUE never appears", !(Str.contains(sec_out, "SECRETVAL123")))?
    # the SET path must not leak either — it used to echo the raw value back
    set_sec = stride!(ctx.bin, ctx.home, ["config", "set", "strava_client_secret", "SETSECRET456"])
    check!("set never echoes a secret", !(Str.contains(set_sec, "SETSECRET456")))?
    check!("set reports redacted", Str.contains(set_sec, "redacted"))?
    check!("secret was still stored", Str.trim(sql!(ctx.db, "SELECT value FROM config WHERE key='strava_client_secret';")) == "SETSECRET456")?
    perms = Str.trim(sh!("stat -c '%a' '${ctx.db}' 2>/dev/null || stat -f '%Lp' '${ctx.db}' 2>/dev/null"))
    check!("db is chmod 600", perms == "600")?
    # The WAL sidecar holds recently written pages, and the write just above put the Strava
    # client secret in one of them — so it needs the same protection as the db itself. The
    # directory is the real guarantee (nobody else can traverse into 0700), which is why it
    # is hardened BEFORE the schema runs and can create these files.
    dperms = Str.trim(sh!("stat -c '%a' '${ctx.home}/.stride' 2>/dev/null || stat -f '%Lp' '${ctx.home}/.stride' 2>/dev/null"))
    check!("the .stride directory is chmod 700", dperms == "700")?
    # "absent" is a real, correct outcome: SQLite removes the -wal file when the last
    # connection closes cleanly, so this cannot demand the file exist. Say which case ran
    # rather than defaulting a missing file to "600", which passed while checking nothing.
    wperms = Str.trim(sh!("if [ -f '${ctx.db}-wal' ]; then stat -c '%a' '${ctx.db}-wal' 2>/dev/null || stat -f '%Lp' '${ctx.db}-wal' 2>/dev/null; else echo absent; fi"))
    check!("the WAL sidecar is chmod 600 when present", wperms == "600" or wperms == "absent")?
    Ok({})
}

# ── seed + analyze: TSS ladder + daily_load to today ─────────────────
b_seed_analyze! : Ctx => Try({}, _)
b_seed_analyze! = |ctx| {
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,weighted_avg_watts,avg_watts) VALUES (101,'power ride','Ride','${ctx.d1}T10:00:00Z',3600,30000,100,200,200);")
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,avg_hr) VALUES (102,'hr row','Rowing','${ctx.d2}T10:00:00Z',3600,9000,0,150);")
    # a real 200W stream so the ride derives an FTP (best-20min 200 x 0.95 = 190). Post-#26
    # FTP is derived from stream power, not config, so a summary-watts-only ride scores 0
    # only while its sport family has no stream power at all. Once this stream lands the
    # Ride family HAS a derived FTP, and a later summary-watts ride scores against it
    # (402, "NULL device_watts still scores as measured"). The Ski row later in this
    # function ("an out-of-family sport keeps its own empty window") is the genuinely
    # unscored case — a family with no stream anywhere.
    _ = seed_power_stream!(ctx.db, 101, 3600, 200)
    # first analyze converges the derived FTP: pass 1 scores both rows (best_20min_w still 0
    # -> FTP 0), pass 2 recomputes the ride once its best_20min_w resolves FTP to 190: 2+1=3
    check!("analyze computes 3 (derived-FTP convergence)", strjq!(ctx, ["analyze"], ".data.computed") == "3")?
    # form_delta_known must be a JSON BOOLEAN, not the string "True". An unconstrained Roc
    # tag serializes as a quoted string, and analyze's payload is encode-only so nothing
    # constrains it — that is how "True" shipped. Asserting the TYPE rather than the value:
    # `jq -r` prints the string "True" as True, so `== "true"` would in fact have caught
    # THAT spelling, but it would still pass on a lowercase string, and on null/absent.
    # The type check catches every one.
    check!("analyze form_delta_known is a boolean, not a string", strjq!(ctx, ["analyze"], ".data.form_delta_known | type") == "boolean")?
    check!("analyze form_tsb_known is a boolean too", strjq!(ctx, ["analyze"], ".data.form_tsb_known | type") == "boolean")?
    check!("summary as_of is today", strjq!(ctx, ["summary"], ".data.as_of") == ctx.today)?
    # #154: the stable machine id for the form band — one of the five enum values,
    # never prose, never coaching vocabulary
    check!("summary form_state is a stable band id", strjq!(ctx, ["summary"], ".data.form_state | IN(\"high_modeled_fatigue\",\"modeled_fatigue_building\",\"balanced\",\"fresh\",\"very_fresh\")") == "true")?
    # ── stimulus features (#159): measurements only. Fixture 101 (power ride,
    # threshold-plus for an hour) is hard by the POWER-AWARE predicate; the flags
    # are typed booleans (the "True"-string trap), and window identities hold.
    check!("hard-session counts are live and d14 <= d28", strjq!(ctx, ["summary"], ".data.hard_days | (.d28 >= 1) and (.d14 <= .d28)") == "true")?
    check!("spacing flags are typed booleans", strjq!(ctx, ["summary"], ".data.hard_days | ((.spacing_known | type) == \"boolean\") and ((.days_since_known | type) == \"boolean\")") == "true")?
    check!("days-since-hard is known with a hard fixture", strjq!(ctx, ["summary"], ".data.hard_days | .days_since_known == true and .days_since_last >= 0") == "true")?
    check!("load windows carry raw deltas (identity, not judgment)", strjq!(ctx, ["summary"], ".data.load_windows | (.delta_7d == .d7 - .prior_d7) and (.delta_28d == .d28 - .prior_d28) and (.d90 >= .d28)") == "true")?
    check!("sports rows carry last_date", strjq!(ctx, ["summary"], "[.data.sports_28d[] | .last_date | length == 10] | all") == "true")?
    # the flag decodes the stored NULL: with no power anywhere in the prior 60d
    # window the fixture must read known=false AND value 0 — a genuinely
    # falsifiable pair, not a tautology of the implementation
    check!("ftp trajectory prior window is flagged honestly", strjq!(ctx, ["summary"], ".data.ftp | ((.prior_60d_known | type) == \"boolean\") and (.prior_60d_known == false) and (.prior_60d_best_20min_w == 0)") == "true")?
    # ── load coverage (#157): TSS-weighted confidence tiers on the aggregates.
    # The invariant is EXACT-100 (largest-remainder rounding, pure-pinned in
    # Metrics); the fixture mixes power_stream and HR/RPE-scored rows so both
    # high and medium tiers are live, and known is a typed boolean (ADR 0009).
    check!("28d load coverage sums to exactly 100", strjq!(ctx, ["summary"], ".data.last_28d.load_coverage | (.high_pct + .medium_pct + .low_pct == 100) and .known == true") == "true")?
    check!("coverage tiers discriminate (high and medium both live)", strjq!(ctx, ["summary"], ".data.last_28d.load_coverage | (.high_pct > 0) and (.medium_pct > 0)") == "true")?
    check!("form coverage carries the 90d window", strjq!(ctx, ["summary"], ".data.form_coverage_90d | (.high_pct + .medium_pct + .low_pct == 100) and ((.known | type) == \"boolean\")") == "true")?
    # with fixtures loaded TSB is known, so the enum arm is required here; the
    # ""-unknown arm is pinned separately on the pre-fixture empty db
    check!("analyze form_state is a stable band id once scored", strjq!(ctx, ["analyze"], ".data.form_state | IN(\"high_modeled_fatigue\",\"modeled_fatigue_building\",\"balanced\",\"fresh\",\"very_fresh\")") == "true")?
    # ── missing-vs-zero (#156): the flags distinguish what the magnitudes cannot.
    # Activity 101 has a REAL power stream -> power_known true with np_w > 0;
    # activity 102 is HR-only -> power_known false AND np_w 0 (absence, not zero
    # watts); both flags are proper JSON booleans, never "True" strings.
    check!("power ride: power_known true", strjq!(ctx, ["activity", "101"], ".data.power_known") == "true")?
    check!("hr row: power absent is flagged, not zero-faked", strjq!(ctx, ["activity", "102"], "(.data.power_known == false) and (.data.np_w == 0)") == "true")?
    check!("hr row: hr_known true", strjq!(ctx, ["activity", "102"], ".data.hr_known") == "true")?
    check!("the flags are typed booleans", strjq!(ctx, ["activity", "101"], "(.data.power_known | type) == \"boolean\" and (.data.hr_known | type) == \"boolean\"") == "true")?
    check!("activities rows carry the flag set", strjq!(ctx, ["activities", "5"], "[.data[] | has(\"power_known\") and has(\"intensity_known\") and has(\"hr_known\") and has(\"zones_known\") and has(\"load_model\")] | all") == "true")?
    # F3 pin: 102 has a SUMMARY avg_hr but no HR stream — hr_known true while
    # zones_known false. Its all-zero z-vector is absence, not "0s in every zone".
    check!("summary-hr row: hr_known true but zones_known false", strjq!(ctx, ["activity", "102"], "(.data.hr_known == true) and (.data.zones_known == false)") == "true")?
    # F2 pin: tss 0 is read through load_model, and a scored row names its model
    check!("scored row names its load_model", strjq!(ctx, ["activity", "101"], "(.data.load_model | length) > 0 and .data.load_model != \"none\"") == "true")?
    # F1 pin: flags decode stored NULLs, so power_known and intensity_known are
    # SEPARATE — both true here (101 has power AND ftp by this point), both false
    # on the HR-only row.
    check!("hr row: intensity absent too", strjq!(ctx, ["activity", "102"], "(.data.intensity_known == false) and (.data.power_known == false)") == "true")?
    check!("top rows carry the trio", strjq!(ctx, ["top", "tss", "3"], "[.data[] | has(\"power_known\") and has(\"intensity_known\") and has(\"hr_known\")] | all") == "true")?
    check!("plan recent rows carry the flag set", strjq!(ctx, ["plan"], "[.data.recent_activities_14d[] | has(\"power_known\") and has(\"zones_known\") and has(\"load_model\")] | all") == "true")?

    # ── personal baselines (#160): 101 vs its own prior comparables. Probe 99
    # sits 5 days earlier, same family (Ride) and duration band (3600s), with
    # summary watts + HR so it scores an np and an EF — one comparable.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,weighted_avg_watts,avg_watts,avg_hr,device_watts) SELECT 99,'baseline probe','Ride',date(start_local,'-5 days')||'T09:00:00Z',3500,28000,180,180,140,1 FROM activities WHERE id=101;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("baseline: np compares against the prior comparable", strjq!(ctx, ["activity", "101"], ".data.baselines.np | .known == true and .sample_count >= 1 and (.percentile | type) == \"number\"") == "true")?
    # 101 has power but NO avg_hr, while probe 99 carries both — so the ef
    # baseline EXISTS (sample_count 1) yet 101 cannot rank in it: known false
    # with a live sample_count is the honest split, not a fake p0
    check!("baseline: ef needs both signals on the CURRENT side too", strjq!(ctx, ["activity", "101"], ".data.baselines.ef | .known == false and .sample_count >= 1") == "true")?
    check!("baseline: comparability rule is visible", strjq!(ctx, ["activity", "101"], ".data.baselines | .window_days == 90 and .band_lo_s == 2700 and .band_hi_s == 4500") == "true")?
    check!("baseline: hr-only row has honest unknowns", strjq!(ctx, ["activity", "102"], ".data.baselines | .np.known == false and .ef.known == false") == "true")?
    # NO FUTURE LEAK: a monster ride AFTER 101 must not move 101's baseline
    check!("baseline sample count is exactly the one probe", strjq!(ctx, ["activity", "101"], ".data.baselines.np.sample_count") == "1")?
    # the probe lands BETWEEN 101's date and today, so a window anchored to
    # "now" would swallow it while the activity-anchored window must not — this
    # discriminates the two anchorings, not just far-future leakage; == 1 also
    # catches a <= upper bound (self-inclusion would read 2)
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,weighted_avg_watts,avg_watts,avg_hr,device_watts) SELECT 98,'future probe','Ride',date(start_local,'+1 days')||'T09:00:00Z',3600,30000,400,400,150,1 FROM activities WHERE id=101;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("baselines never include later activities (activity-anchored, not today-anchored)", strjq!(ctx, ["activity", "101"], ".data.baselines.np.sample_count") == "1")?
    # family exclusion: a same-band Ski before 101 is not comparable
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,weighted_avg_watts,avg_watts,avg_hr,device_watts) SELECT 97,'ski probe','Ski',date(start_local,'-4 days')||'T09:00:00Z',3600,0,300,300,150,1 FROM activities WHERE id=101;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("comparability excludes other families", strjq!(ctx, ["activity", "101"], ".data.baselines.np.sample_count") == "1")?
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id IN (97,98,99); DELETE FROM activity_metrics WHERE activity_id IN (97,98,99); DELETE FROM activities WHERE id IN (97,98,99);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    # #93: ramp carries BOTH fields, and a short history reports an honest 0 rather than
    # today's whole CTL — which is what treating "no data 7 days back" as a CTL of 0 would
    # produce. The fixture has only a couple of days, so 0 is the correct answer here.
    # `| type` rather than `has(...)`: the value check below compares against 0.0, and
    # sfloat of a missing field is ALSO 0.0 — so presence and value together would still
    # pass if the field vanished or came back null. Asserting the JSON type is what makes
    # the pair non-vacuous.
    check!("summary ramp_7d is a number", strjq!(ctx, ["summary"], ".data.ramp_7d | type") == "number")?
    check!("summary ramp_28d_avg is a number", strjq!(ctx, ["summary"], ".data.ramp_28d_avg | type") == "number")?
    check_near!("short history ramps to an honest 0", sfloat(strjq!(ctx, ["summary"], ".data.ramp_7d")), 0.0, 0.001)?
    check_near!("...and so does the 28d average", sfloat(strjq!(ctx, ["summary"], ".data.ramp_28d_avg")), 0.0, 0.001)?
    check!("ctl_warming_up agrees it is short", strjq!(ctx, ["summary"], ".data.ctl_warming_up") == "true")?
    # #111: the form verdict carries a weekly delta. Same non-vacuity trick as the ramp
    # checks above — assert the JSON type, because sfloat of a missing field is also 0.0
    # and value-alone would pass if the field disappeared.
    check!("summary form_delta_7d is a number", strjq!(ctx, ["summary"], ".data.form_delta_7d | type") == "number")?
    # This fixture has only a couple of days, so nothing reaches back a week. The flag must
    # say so rather than the 0.0 being read as "form held level" — that distinction is the
    # whole reason the field exists.
    check!("summary form_delta_known is a boolean too", strjq!(ctx, ["summary"], ".data.form_delta_known | type") == "boolean")?

    # ── interval detection (ADR 0008, #95) ──────────────────────────────
    # a stream with 3 clean 180s@250W reps over a 120s@100W floor must detect
    # EXACTLY 3 work segments; the constant-200W ride (101) must detect NONE —
    # a steady effort has no interval structure, and inventing reps there is the
    # failure mode the structure gates exist to prevent.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,weighted_avg_watts,avg_watts,device_watts) VALUES (103,'interval ride','Ride','${ctx.d2}T18:00:00Z',1500,15000,50,180,180,1)")
    _ = seed_interval_stream!(ctx.db, 103)
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("interval ride detects exactly 3 work segments", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_segments WHERE activity_id=103 AND kind='work';")) == "3")?
    check!("steady ride detects zero segments", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_segments WHERE activity_id=101;")) == "0")?
    check!("work reps sit near 250W", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_segments WHERE activity_id=103 AND kind='work' AND avg_signal BETWEEN 235 AND 265;")) == "3")?
    # the activity payload carries the structure — WIRING check (count + non-empty
    # summary), not just types, per the #127 lesson
    check!("activity JSON carries 3 work segments", strjq!(ctx, ["activity", "103"], "[.data.segments[] | select(.kind == \"work\")] | length") == "3")?
    check!("activity JSON interval_summary is non-empty", strjq!(ctx, ["activity", "103"], ".data.interval_summary | length > 3") == "true")?
    check!("activity JSON says detection was attempted", strjq!(ctx, ["activity", "103"], ".data.detection_attempted") == "true")?
    # ordinal 0 is the warmup and ordinals ascend with start_s — a scrambled insert
    # order would flip the drift verdict's sign while every count check stays green
    check!("ordinal 0 is the warmup", Str.trim(sql!(ctx.db, "SELECT kind FROM activity_segments WHERE activity_id=103 AND ordinal=0;")) == "warmup")?
    check!("ordinals ascend with start_s", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM (SELECT ordinal, start_s, LAG(start_s) OVER (ORDER BY ordinal) AS prev FROM activity_segments WHERE activity_id=103) WHERE prev IS NOT NULL AND start_s <= prev;")) == "0")?
    # work durations, not just counts — the seeded reps are 180 s
    check!("work reps last ~180s", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_segments WHERE activity_id=103 AND kind='work' AND dur_s BETWEEN 176 AND 184;")) == "3")?
    # the seeded stream has NO heartrate: HR columns must be NULL (honest absence),
    # never 0 posing as a measurement
    check!("absent HR stores NULL, not zero", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_segments WHERE activity_id=103 AND kind='work' AND (peak_hr IS NOT NULL OR avg_hr IS NOT NULL OR rec_drop_60s IS NOT NULL);")) == "0")?
    # computed tier: segments live and die WITH the metrics row — every real
    # invalidation path (stream arrival, rating, prune) deletes both, and the next
    # analyze rebuilds both. Deleting segments alone is not a supported operation:
    # analyze keys recompute off the metrics row, and an empty segments set is a
    # legitimate result (steady ride), not a "please recompute" marker.
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id=103; DELETE FROM activity_metrics WHERE activity_id=103;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("segments rebuild with the metrics row", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_segments WHERE activity_id=103 AND kind='work';")) == "3")?
    # ── pace decoupling (#134/#135) ─────────────────────────────────────
    # a run with pace+HR streams gets a real decoupling number (HR steps up in the
    # second half at constant speed => positive drift); a meter-less RIDE with the
    # same streams stays NULL — terrain speed over HR is not efficiency
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_hr) VALUES (104,'drift run','Run','${ctx.d2}T07:00:00Z',1300,4000,145);")
    _ = seed_pace_hr_stream!(ctx.db, 104, 1300, 3)
    # a comparable earlier run with the same name, so progress has a group to score
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_hr) VALUES (106,'drift run','Run','${ctx.d1}T07:00:00Z',1300,4000,144);")
    _ = seed_pace_hr_stream!(ctx.db, 106, 1300, 3)
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (105,'meterless ride','Ride','${ctx.d2}T09:00:00Z',1300,9000);")
    _ = seed_pace_hr_stream!(ctx.db, 105, 1300, 7)
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    # F3 companion (see the flag block above): a row WITH an HR stream reads
    # zones_known true — 104's pace_hr stream carries in-band HR samples
    check!("streamed-hr row: zones_known true", strjq!(ctx, ["activity", "104"], ".data.zones_known") == "true")?
    run_drift = Str.trim(sql!(ctx.db, "SELECT ROUND(COALESCE(decoupling_pct, -999), 1) FROM activity_metrics WHERE activity_id=104;"))
    check!("run decoupling is computed and positive", sfloat(run_drift) > 0.0)?
    check!("meter-less ride decoupling stays NULL", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_metrics WHERE activity_id=105 AND decoupling_pct IS NOT NULL;")) == "0")?
    check!("activity JSON labels the run drift as pace", strjq!(ctx, ["activity", "104"], ".data.decoupling_signal") == "pace")?
    # an altitude-less run (a watch without a barometer — a REAL common case) still
    # gets its drift, labeled "speed" so nobody reads terrain effects as grade-adjusted
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_hr) VALUES (107,'barometerless run','Run','${ctx.d2}T05:00:00Z',1300,4000,140);")
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO streams (activity_id, raw_json) SELECT 107, json_remove(raw_json, '$.altitude') FROM streams WHERE activity_id = 104;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("altitude-less run drift is known", strjq!(ctx, ["activity", "107"], ".data.decoupling_known") == "true")?
    check!("altitude-less run drift is labeled speed", strjq!(ctx, ["activity", "107"], ".data.decoupling_signal") == "speed")?
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id=107; DELETE FROM activity_segments WHERE activity_id=107; DELETE FROM streams WHERE activity_id=107; DELETE FROM activities WHERE id=107;")

    # F1 lock (#142 retro): a run whose stream CARRIES a watts channel flagged
    # device_watts=0 must still label its drift "pace" — the label is stored
    # provenance from analyze's gated routing, never re-derived from the raw stream
    _ = sql!(ctx.db, "UPDATE activities SET device_watts = 0 WHERE id = 104;")
    _ = sql!(ctx.db, "UPDATE streams SET raw_json = (SELECT json_insert(raw_json, '$.watts', json('{\"data\": ' || (SELECT json_extract(raw_json,'$.heartrate.data') FROM streams WHERE activity_id=104) || '}')) FROM streams s2 WHERE s2.activity_id=104) WHERE activity_id = 104;")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id=104; DELETE FROM activity_segments WHERE activity_id=104;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("estimated-watts run still labels drift as pace", strjq!(ctx, ["activity", "104"], ".data.decoupling_signal") == "pace")?
    # progress rows carry the per-session drift with its known flag (#135), pinned
    # PER SESSION so a flag inversion cannot pass on some other session's row
    check!("the drift run's session is known and positive", strjq!(ctx, ["progress", "${ctx.d2}"], "[.data.groups[] | select(.name | contains(\"drift run\")) | .sessions[] | select(.date == \"${ctx.d2}\")] | .[0] | (.decoupling_known == true and .decoupling_pct > 0)") == "true")?
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id IN (104,105,106); DELETE FROM activity_metrics WHERE activity_id IN (104,105,106); DELETE FROM streams WHERE activity_id IN (104,105,106); DELETE FROM activities WHERE id IN (104,105,106);")

    # ── sport words (#150): human words widen to Strava families, and an empty
    # result names the sports that exist instead of a silent empty table ──
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (310,'gravel jaunt','GravelRide','${ctx.d1}T10:00:00Z',3600,30000);")
    check!("'bike' finds Ride AND GravelRide", strjq!(ctx, ["top", "distance", "10", "bike"], "[.data[].sport] | unique | length >= 2") == "true")?
    check!("'BIKE' matches case-insensitively", strjq!(ctx, ["top", "distance", "10", "BIKE"], ".data | length >= 2") == "true")?
    check!("a non-family literal filters exactly", strjq!(ctx, ["top", "distance", "10", "GravelRide"], "[.data[].sport] | unique | join(\",\")") == "GravelRide")?
    # 'ride' IS a family key and deliberately widens — pinned so the semantic is
    # a documented choice, not an accident
    check!("'ride' widens to its family", strjq!(ctx, ["top", "distance", "10", "ride"], "[.data[].sport] | unique | length >= 2") == "true")?
    # empty because the METRIC is missing, not the sport: the hint must say so
    # instead of denying the sport exists while listing it
    metric_hint = stride_human!(ctx.bin, ctx.home, ["top", "power", "10", "gravelride"])
    check!("metric-empty hint blames the metric, not the sport", Str.contains(metric_hint, "but none with"))?
    # power-curve rides the same filter machinery — cover it at all (it had zero e2e)
    check!("power-curve has real points bare", strjq!(ctx, ["pc"], ".data.points | length > 0") == "true")?
    check!("a family word still reaches the curve's watts", strjq!(ctx, ["pc", "90", "bike"], "[.data.points[].watts] | max > 0") == "true")?
    unknown_top = stride_human!(ctx.bin, ctx.home, ["top", "distance", "10", "kayak"])
    check!("unknown sport names the sports that exist", Str.contains(unknown_top, "sports in your data") and Str.contains(unknown_top, "GravelRide"))?
    check!("activities honors the family too", strjq!(ctx, ["activities", "10", "bike"], "[.data[].sport] | unique | length >= 2") == "true")?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id = 310;")

    # ── power population invariant (#151): FTP derives from the sport FAMILY.
    # A GravelRide with no gravel power history inherits the family's 20-min best
    # (activity 101's 200W stream -> FTP 190) instead of scoring against an empty
    # window — the curve and the FTP it explains now read the same population.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,weighted_avg_watts,avg_watts,device_watts) VALUES (320,'gravel loop','GravelRide','${ctx.d2}T15:00:00Z',3600,25000,180,180,1);")
    # the INSERT trigger canonicalized the family — the query population is the
    # stored COLUMN (sargable), never a CASE at query time
    check!("insert trigger stores the canonical family", Str.trim(sql!(ctx.db, "SELECT COALESCE(sport_family,'?') FROM activities WHERE id=320;")) == "Ride")?
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("a family sport inherits the family FTP", Str.trim(sql!(ctx.db, "SELECT CAST(ftp_used AS INTEGER) FROM activity_metrics WHERE activity_id=320;")) == "190")?
    # ...and an out-of-family sport still derives from nothing but itself — the
    # guard against OVER-collapsing (this passes before #151 too, on purpose:
    # it pins that the fix did not widen any population it shouldn't have)
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,weighted_avg_watts,avg_watts,device_watts) VALUES (321,'ski erg','Ski','${ctx.d2}T16:00:00Z',1800,0,150,150,1);")
    check!("non-family sport passes through as its own family", Str.trim(sql!(ctx.db, "SELECT COALESCE(sport_family,'?') FROM activities WHERE id=321;")) == "Ski")?
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("an out-of-family sport keeps its own empty window", Str.trim(sql!(ctx.db, "SELECT CAST(COALESCE(ftp_used,0) AS INTEGER) FROM activity_metrics WHERE activity_id=321;")) == "0")?
    # a sport_type EDIT re-canonicalizes through the UPDATE trigger
    _ = sql!(ctx.db, "UPDATE activities SET sport_type='TrailRun' WHERE id=321;")
    check!("update trigger re-canonicalizes the family", Str.trim(sql!(ctx.db, "SELECT COALESCE(sport_family,'?') FROM activities WHERE id=321;")) == "Run")?
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id IN (320,321); DELETE FROM activity_metrics WHERE activity_id IN (320,321); DELETE FROM activities WHERE id IN (320,321);")

    # ── skill contract drift guard (#155): the coach skill is a CLIENT of the
    # CLI contract, and it once instructed `config set ftp_ride` — a command the
    # CLI refuses. Retired interfaces must never reappear in the shipped skill.
    skill_text = sh!("cat .claude/skills/stride/SKILL.md")
    # sh! swallows errors into "" — assert readability FIRST so a moved/renamed
    # skill file fails loudly here instead of green-lighting the negative checks
    check!("skill file is readable", !(Str.is_empty(skill_text)))?
    check!("skill never sets FTP via config", !(Str.contains(skill_text, "config set ftp")))?
    # the review proved banning exact spellings misses re-worded drift ("config vs
    # estimated" carried the same dead flags without any banned string) — ban the
    # SEMANTIC phrase too, and pin the real key names positively: a positive
    # assert catches wrong-key drift the denylist can never enumerate
    check!("skill carries no dead ftp.stale flag", !(Str.contains(skill_text, "ftp.stale")) and !(Str.contains(skill_text, "detraining: true")) and !(Str.contains(skill_text, "config vs estimated")))?
    check!("skill names the real ftp keys", Str.contains(skill_text, "best_20min_w_60d") and Str.contains(skill_text, "estimated_ftp_w"))?
    check!("skill names the real pc/summary keys", Str.contains(skill_text, "dur_s") and !(Str.contains(skill_text, "duration_s")) and Str.contains(skill_text, "form_delta_known") and !(Str.contains(skill_text, "form_delta_7d_known")))?
    check!("skill documents the envelope", Str.contains(skill_text, "schema_version"))?
    # if this fails after a platform bump: update the skill's toolchain line too
    check!("skill names the current platform", Str.contains(skill_text, "basic-cli 0.22"))?
    # ...and the commands it teaches exist: spot-check the ones this guard grew from
    check!("skill documents the derived-key refusal", Str.contains(skill_text, "derived_key"))?
    # #181: the skill must TELL the coach to pass --json, and must not teach the
    # retired environment detection as a way to get machine output
    check!("skill instructs passing --json", Str.contains(skill_text, "PASS `--json` ON EVERY QUERY"))?
    # the skill must not teach ANY environment sniffing as a way to get machine
    # output — STRIDE_FORMAT is a session default, the flag is the instruction
    # exact-phrase bans miss paraphrase (review slipped one past the previous
    # version); the tree has zero occurrences of the retired name, so banning
    # the name itself is both free and airtight
    # the help text is a doc too, and it out-lived the removal once already
    help_text_out = stride_human!(ctx.bin, ctx.home, ["--help"])
    check!("help text teaches no environment detection", !(Str.contains(help_text_out, "CLAUDECODE")) and !(Str.contains(help_text_out, "JSON for tools")))?
    check!("help text documents the flag", Str.contains(help_text_out, "--json"))?
    check!("skill teaches no environment detection", !(Str.contains(skill_text, "CLAUDECODE")) and !(Str.contains(skill_text, "detected automatically")))?

    # ── the JSON contract as a tested artifact (#164) ────────────────────
    # schemas/v2/*.json is the ONE source of truth for the machine interface;
    # tools/validate.jq checks a payload against it and prints one line per
    # violation. Run from the repo root (same CWD assumption as the skill guard
    # above). additionalKeys:false is the drift catcher — a payload that GAINS a
    # field without a schema update fails here, which is the whole point.
    # An empty capture used to read as "conforms" — a crashing binary or
    # truncated JSON left jq with nothing and its parse error went to the
    # SUITE's stderr. The first fix merged 2>&1 into every stage, which then
    # corrupted the JSON of the commands that NARRATE to stderr by design
    # (analyze, sync — ADR 0007). So: keep stderr out of the pipe, and fail
    # explicitly on an empty payload instead of inferring conformance from it.
    validate! = |cmd, schema| validate_schema!(ctx, cmd, schema)
    check!("summary conforms to its schema", validate!("summary", "summary") == "")?
    check!("plan conforms to its schema", validate!("plan", "plan") == "")?
    check!("activity conforms to its schema", validate!("activity 101", "activity") == "")?
    # 101 is the STEADY ride — zero segments, so its `segments` item schema (ten
    # required keys and two enums) passes vacuously on an empty array. 103 is the
    # interval ride and carries every segment kind, so it is what actually
    # exercises those declarations. It is deleted a few lines below.
    check!("interval activity conforms (non-empty segments)", validate!("activity 103", "activity") == "")?
    # ── spending the CP model (#186/#187) ────────────────────────────────
    # The fixture has no 5/10/20-min power bests spread widely enough to fit a
    # CP model, so both features must REFUSE rather than invent one — which is
    # the behaviour that matters most, since a fabricated CP would silently
    # mis-scale every W' number downstream.
    check!("no CP fit is an in-band refusal, not a number", Str.contains(stride!(ctx.bin, ctx.home, ["tte", "300"]), "no_cp_fit"))?
    # fit_points counts the bests AVAILABLE, on every command that publishes it.
    # power-curve used to zero it on a refused fit, making one key mean two
    # different things; `cp` of 0 is the refusal signal. This fixture refuses a
    # fit while having bests, so it distinguishes the two meanings.
    check!("a refused fit still counts the bests it had", strjq!(ctx, ["pc"], ".data | (.cp == 0) and (.fit_points > 0)") == "true")?
    check!("a non-numeric power is refused", Str.contains(stride!(ctx.bin, ctx.home, ["tte", "abc"]), "bad_watts"))?
    check!("a negative power is refused", Str.contains(stride!(ctx.bin, ctx.home, ["tte", "-50"]), "bad_watts"))?
    check!("an exponent power is refused", Str.contains(stride!(ctx.bin, ctx.home, ["tte", "3e2"]), "bad_watts"))?
    # F64.from_str accepts nan/inf, and `w <= 0.0` is FALSE for NaN, so these
    # sailed past the guard: JSON mode died with JsonEncodeFailed(NaN) outside
    # the envelope, and human mode printed "~0:00" and exited 0. The refusal
    # must be an ENVELOPE, so assert the code AND that the output still parses
    # as the contract rather than merely lacking a number.
    nan_out = stride!(ctx.bin, ctx.home, ["tte", "nan"])
    check!("NaN is refused in-band, not at the encoder", Str.contains(nan_out, "bad_watts") and !(Str.contains(nan_out, "JsonEncodeFailed")))?
    check!("infinity is refused", Str.contains(stride!(ctx.bin, ctx.home, ["tte", "Infinity"]), "bad_watts"))?
    check!("an absurd power is refused", Str.contains(stride!(ctx.bin, ctx.home, ["tte", "1e9"]), "bad_watts"))?
    # 5000 reaches the RANGE guard; nan/Infinity/1e9 above no longer do, because #201's
    # arg_f64 refuses them at the parse layer first. Without this the `w > 3000.0`
    # ceiling and the `!(w > 0.0)` form (#183) both became unpinned -- three checks that
    # still passed while guarding nothing.
    check!("a power over the ceiling is refused BY THE CEILING", Str.contains(stride!(ctx.bin, ctx.home, ["tte", "5000"]), "under 3000"))?
    check!("...and zero is refused by the same guard", Str.contains(stride!(ctx.bin, ctx.home, ["tte", "0"]), "positive number"))?
    check!("a plausible power is NOT refused by the ceiling", Str.contains(stride!(ctx.bin, ctx.home, ["tte", "3000"]), "no_cp_fit"))?
    check!("without a fit, W' balance is flagged unknown rather than zeroed", strjq!(ctx, ["activity", "101"], ".data.w_prime_balance | (.known == false) and ((.known | type) == \"boolean\")") == "true")?
    check!("...and the fit it would have used travels with it", strjq!(ctx, ["activity", "101"], ".data.w_prime_balance | has(\"cp_used\") and has(\"fit_points\")") == "true")?
    # ── rep-level comparison (#149) ──────────────────────────────────────
    # 103 is the fixture's interval ride, so it anchors `reps`. The shape block
    # is the comparability rule made visible; a session whose rep COUNT or
    # rep-duration BAND differs must not appear beside it.
    check!("reps anchors on the interval ride", strjq!(ctx, ["reps"], ".data.anchor_activity_id") == "103")?
    check!("reps states the shape it compared on", strjq!(ctx, ["reps"], ".data.shape | (.rep_count > 0) and (.band_hi_s > .band_lo_s)") == "true")?
    check!("every session shares the anchor's rep count", strjq!(ctx, ["reps"], "[.data.sessions[].rep_count] | unique | length == 1") == "true")?
    check!("...and every rep duration sits inside the stated band", strjq!(ctx, ["reps"], ".data as $d | [$d.sessions[].mean_dur_s | (. >= $d.shape.band_lo_s and . < $d.shape.band_hi_s)] | all") == "true")?
    # a second genuinely comparable session, so the rep-count and band
    # assertions above stop being trivially true on a one-row result — review
    # showed three mutations (count filter, rep ordering, fade sign) surviving
    # against a single-session fixture
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,distance,weighted_avg_watts,avg_watts,device_watts,avg_hr) VALUES (331,'earlier comparable','Ride','Ride',date('${ctx.d1}','-20 days')||'T06:00:00Z',1800,15000,200,200,1,150);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal,avg_hr) VALUES (331,0,'work',0,300,200.0,'power',140.0),(331,1,'work',400,300,190.0,'power',150.0),(331,2,'work',800,300,180.0,'power',160.0);")
    check!("a second comparable session appears", strjq!(ctx, ["reps"], ".data.sessions | length >= 2") == "true")?
    # fade SIGN: 331 descends 200->180, so its fade must be NEGATIVE. Flipping
    # the subtraction in Report.roc must fail here.
    check!("fade is last minus first, signed", strjq!(ctx, ["reps"], "[.data.sessions[] | select(.id == 331) | .fade_signal] | .[0] < 0") == "true")?
    # rep ORDER: reps must be in ordinal order, so the first is the 200W one
    check!("reps are in ordinal order", strjq!(ctx, ["reps"], "[.data.sessions[] | select(.id == 331) | .reps[0].avg_signal] | .[0] == 200") == "true")?
    check!("hr rise spans first to last rep", strjq!(ctx, ["reps"], "[.data.sessions[] | select(.id == 331) | .hr_rise_bpm] | .[0] == 20") == "true")?
    check!("each session reports its own dispersion", strjq!(ctx, ["reps"], "[.data.sessions[] | has(\"uniformity\") and has(\"min_dur_s\") and has(\"max_dur_s\")] | all") == "true")?
    check!("the payload discloses how many matched", strjq!(ctx, ["reps"], ".data.matched_total >= (.data.sessions | length)") == "true")?
    # ── each round-2 guarantee gets a mutation-killing probe ────────────
    # count: a 4-rep session whose mean duration sits in the SAME band must be
    # excluded, or `HAVING COUNT(*) = :reps` is untested (it was)
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,weighted_avg_watts,avg_watts,device_watts) VALUES (332,'four reps','Ride','Ride',date('${ctx.d1}','-19 days')||'T06:00:00Z',1800,200,200,1);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal) VALUES (332,0,'work',0,300,200.0,'power'),(332,1,'work',400,300,200.0,'power'),(332,2,'work',800,300,200.0,'power'),(332,3,'work',1200,300,200.0,'power');")
    check!("a different rep COUNT is not comparable", strjq!(ctx, ["reps"], "[.data.sessions[].id] | index(332) == null") == "true")?
    # signal: watts and m/s must never share a column
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,weighted_avg_watts,avg_watts,device_watts) VALUES (333,'pace signal','Ride','Ride',date('${ctx.d1}','-18 days')||'T06:00:00Z',1800,200,200,1);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal) VALUES (333,0,'work',0,300,4.0,'pace'),(333,1,'work',400,300,4.0,'pace'),(333,2,'work',800,300,4.0,'pace');")
    check!("a different SIGNAL is not comparable", strjq!(ctx, ["reps"], "[.data.sessions[].id] | index(333) == null") == "true")?
    # hr span: HR on the MIDDLE rep only must read unknown, not a narrowed span
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,weighted_avg_watts,avg_watts,device_watts) VALUES (334,'middle hr','Ride','Ride',date('${ctx.d1}','-17 days')||'T06:00:00Z',1800,200,200,1);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal,avg_hr) VALUES (334,0,'work',0,300,200.0,'power',140.0),(334,1,'work',400,300,200.0,'power',150.0),(334,2,'work',800,300,200.0,'power',NULL);")
    # HR on reps 1 and 2 but NOT the last: the old semantics reported a
    # "first-to-last" rise that actually spanned reps 1-2. Two HR-bearing reps
    # is what makes this discriminate — a single one reads unknown either way.
    check!("hr rise is unknown unless BOTH end reps carry it", strjq!(ctx, ["reps"], "[.data.sessions[] | select(.id == 334) | .hr_rise_known] | .[0] == false") == "true")?
    # ── the ranking itself, pinned ───────────────────────────────────────
    # A dedicated anchor (reps 700/800/950 — uniformity 1.36, inside the 1.6x
    # gate but NOT the most uniform session), twelve candidates whose uniformity
    # IMPROVES with age, and six clearly uneven ones. That shape makes rank
    # order the reverse of date order and puts the anchor mid-pack, so each of
    # ranking-by-uniformity, the anchor pin, and the display re-sort can fail
    # independently. Round 3's probes were all uniformity 1.0 with the anchor
    # newest and most uniform, so every ordering picked the same rows.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,weighted_avg_watts,avg_watts,device_watts) VALUES (336,'ranking anchor','Ride','Ride','2099-06-01T06:00:00Z',3000,200,200,1),(340,'rank uniform 0','Ride','Ride','2099-01-02T06:00:00Z',3000,200,200,1),(341,'rank uniform 1','Ride','Ride','2099-01-03T06:00:00Z',3000,200,200,1),(342,'rank uniform 2','Ride','Ride','2099-01-04T06:00:00Z',3000,200,200,1),(343,'rank uniform 3','Ride','Ride','2099-01-05T06:00:00Z',3000,200,200,1),(344,'rank uniform 4','Ride','Ride','2099-01-06T06:00:00Z',3000,200,200,1),(345,'rank uniform 5','Ride','Ride','2099-01-07T06:00:00Z',3000,200,200,1),(346,'rank uniform 6','Ride','Ride','2099-01-08T06:00:00Z',3000,200,200,1),(347,'rank uniform 7','Ride','Ride','2099-01-09T06:00:00Z',3000,200,200,1),(348,'rank uniform 8','Ride','Ride','2099-01-10T06:00:00Z',3000,200,200,1),(349,'rank uniform 9','Ride','Ride','2099-02-02T06:00:00Z',3000,200,200,1),(360,'rank uneven 0','Ride','Ride','2099-05-20T06:00:00Z',3000,200,200,1),(361,'rank uneven 1','Ride','Ride','2099-05-21T06:00:00Z',3000,200,200,1),(362,'rank uneven 2','Ride','Ride','2099-05-22T06:00:00Z',3000,200,200,1),(363,'rank uneven 3','Ride','Ride','2099-05-23T06:00:00Z',3000,200,200,1),(364,'rank uneven 4','Ride','Ride','2099-05-24T06:00:00Z',3000,200,200,1),(365,'rank uneven 5','Ride','Ride','2099-05-25T06:00:00Z',3000,200,200,1);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal) VALUES (336,0,'work',0,700,260.0,'power'),(336,1,'work',900,800,255.0,'power'),(336,2,'work',1900,950,250.0,'power'),(340,0,'work',0,800,200.0,'power'),(340,1,'work',1000,800,200.0,'power'),(340,2,'work',2000,800,200.0,'power'),(341,0,'work',0,800,200.0,'power'),(341,1,'work',1000,800,200.0,'power'),(341,2,'work',2000,807,200.0,'power'),(342,0,'work',0,800,200.0,'power'),(342,1,'work',1000,800,200.0,'power'),(342,2,'work',2000,814,200.0,'power'),(343,0,'work',0,800,200.0,'power'),(343,1,'work',1000,800,200.0,'power'),(343,2,'work',2000,821,200.0,'power'),(344,0,'work',0,800,200.0,'power'),(344,1,'work',1000,800,200.0,'power'),(344,2,'work',2000,828,200.0,'power'),(345,0,'work',0,800,200.0,'power'),(345,1,'work',1000,800,200.0,'power'),(345,2,'work',2000,835,200.0,'power'),(346,0,'work',0,800,200.0,'power'),(346,1,'work',1000,800,200.0,'power'),(346,2,'work',2000,842,200.0,'power'),(347,0,'work',0,800,200.0,'power'),(347,1,'work',1000,800,200.0,'power'),(347,2,'work',2000,849,200.0,'power'),(348,0,'work',0,800,200.0,'power'),(348,1,'work',1000,800,200.0,'power'),(348,2,'work',2000,856,200.0,'power'),(349,0,'work',0,800,200.0,'power'),(349,1,'work',1000,800,200.0,'power'),(349,2,'work',2000,863,200.0,'power'),(360,0,'work',0,500,200.0,'power'),(360,1,'work',1200,800,200.0,'power'),(360,2,'work',2400,1100,200.0,'power'),(361,0,'work',0,500,200.0,'power'),(361,1,'work',1200,800,200.0,'power'),(361,2,'work',2400,1100,200.0,'power'),(362,0,'work',0,500,200.0,'power'),(362,1,'work',1200,800,200.0,'power'),(362,2,'work',2400,1100,200.0,'power'),(363,0,'work',0,500,200.0,'power'),(363,1,'work',1200,800,200.0,'power'),(363,2,'work',2400,1100,200.0,'power'),(364,0,'work',0,500,200.0,'power'),(364,1,'work',1200,800,200.0,'power'),(364,2,'work',2400,1100,200.0,'power'),(365,0,'work',0,500,200.0,'power'),(365,1,'work',1200,800,200.0,'power'),(365,2,'work',2400,1100,200.0,'power');")
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,weighted_avg_watts,avg_watts,device_watts) VALUES (370,'ratio worse spread better','Ride','Ride','2099-04-01T06:00:00Z',3000,200,200,1),(371,'ratio better spread worse','Ride','Ride','2099-04-02T06:00:00Z',3000,200,200,1);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal) VALUES (370,0,'work',0,600,200.0,'power'),(370,1,'work',900,600,200.0,'power'),(370,2,'work',1900,680,200.0,'power'),(371,0,'work',0,800,200.0,'power'),(371,1,'work',900,800,200.0,'power'),(371,2,'work',1900,890,200.0,'power');")
    check!("the window caps at 12 rows", strjq!(ctx, ["reps", "2099-06-01"], ".data.sessions | length == 12") == "true")?
    check!("...and matched_total exceeds them, so truncation is visible", strjq!(ctx, ["reps", "2099-06-01"], ".data.matched_total > (.data.sessions | length)") == "true")?
    check!("the window keeps the most uniform, not the most recent", strjq!(ctx, ["reps", "2099-06-01"], "[.data.sessions[].id | select(. >= 360 and . <= 365)] | length == 0") == "true")?
    # WHICH dispersion metric ranks, not merely that one does. These two
    # disagree by construction: 600/600/680 has ratio 1.133 but spread 80 and
    # max 680, while 800/800/890 has ratio 1.1125 but spread 90 and max 890.
    # The RATIO prefers 371; absolute spread and max-duration both prefer 370.
    # Ten candidates strictly more uniform than either sit above them, so the
    # window's last slot goes to exactly one of the pair — whichever the key
    # picks. Swapping the key silently readmits sessions at 6.9x uniformity
    # (review constructed that), and nothing else in the suite would notice.
    # Without this the key could be swapped silently and readmit sessions at
    # uniformity 6.9 — review constructed exactly that.
    check!("ranking uses the RATIO, not absolute spread or max duration", strjq!(ctx, ["reps", "2099-06-01"], ".data as $d | ([$d.sessions[].id] | index(371) != null) and ([$d.sessions[].id] | index(370) == null)") == "true")?
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id IN (370,371); DELETE FROM activities WHERE id IN (370,371);")
    check!("the anchor keeps its row even when others are more uniform", strjq!(ctx, ["reps", "2099-06-01"], "[.data.sessions[].id] | index(336) != null") == "true")?
    check!("rows are displayed newest first, whatever the ranking", strjq!(ctx, ["reps", "2099-06-01"], "[.data.sessions[].date] == ([.data.sessions[].date] | sort | reverse)") == "true")?
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id BETWEEN 336 AND 365; DELETE FROM activity_metrics WHERE activity_id BETWEEN 336 AND 365; DELETE FROM activities WHERE id BETWEEN 336 AND 365;")
    # the anchor gate: a session whose blocks are NOT one repeated shape cannot
    # be an anchor, and being the most recent must not change that
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,weighted_avg_watts,avg_watts,device_watts) VALUES (335,'irregular','Ride','Ride','2099-01-01T06:00:00Z',3000,200,200,1);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal) VALUES (335,0,'work',0,60,200.0,'power'),(335,1,'work',200,1800,200.0,'power'),(335,2,'work',2100,120,200.0,'power');")
    check!("an irregular session is refused as an anchor", Str.contains(stride!(ctx.bin, ctx.home, ["reps"]), "irregular_anchor"))?
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id=335; DELETE FROM activities WHERE id=335;")
    # ...and the gate sits exactly where the constant says. Without a probe ON
    # THE BOUNDARY the literal in this effectful path could move from 1.6x to
    # 9.9x with the whole suite green -- it did, for one round, while a pure
    # expect asserted a constant the gate was not actually using. Reuses id 335
    # because that insert is proven to land above; a fresh id silently did not,
    # and the "accepted" assertion passed on `no_intervals_on_date` instead.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,weighted_avg_watts,avg_watts,device_watts) VALUES (335,'gate probe','Ride','Ride','2099-01-01T06:00:00Z',3000,200,200,1);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal) VALUES (335,0,'work',0,100,200.0,'power'),(335,1,'work',300,160,200.0,'power');")
    # asserted POSITIVELY: the anchor must actually render at the boundary, not
    # merely avoid one error string
    check!("a spread of exactly the gate is accepted as an anchor", strjq!(ctx, ["reps", "2099-01-01"], ".data.anchor_activity_id") == "335")?
    _ = sql!(ctx.db, "UPDATE activity_segments SET dur_s = 161 WHERE activity_id = 335 AND ordinal = 1;")
    check!("one second past the gate is refused", Str.contains(stride!(ctx.bin, ctx.home, ["reps", "2099-01-01"]), "irregular_anchor"))?
    # the refusal quotes the gate it enforced rather than a literal that could
    # drift away from the number actually applied
    check!("the refusal quotes the gate it enforced", Str.contains(stride!(ctx.bin, ctx.home, ["reps", "2099-01-01"]), "1.6x"))?
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id=335; DELETE FROM activities WHERE id=335;")
    check!("reps conforms to its schema", validate!("reps", "reps") == "")?
    check!("a date with no detected structure says so in band", Str.contains(stride!(ctx.bin, ctx.home, ["reps", "1999-01-01"]), "no_intervals_on_date"))?
    # comparability is not just the count: a same-count session whose reps sit
    # in a DIFFERENT duration band must be excluded, which is the whole reason
    # rep-scale bands exist rather than the session-scale ones
    before_n = Str.trim(strjq!(ctx, ["reps"], ".data.sessions | length"))
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,distance,weighted_avg_watts,avg_watts,device_watts) VALUES (330,'short vo2','Ride','Ride','${ctx.d1}T05:00:00Z',1200,8000,240,240,1);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal) VALUES (330,0,'work',0,90,300.0,'power'),(330,1,'work',200,90,300.0,'power'),(330,2,'work',400,90,300.0,'power');")
    check!("a same-count session in another rep band is not comparable", Str.trim(strjq!(ctx, ["reps"], ".data.sessions | length")) == before_n)?
    # every probe activity leaves before the block ends — a later analyze would
    # otherwise score them and move CTL, which surfaced as an unrelated form
    # check failing 90 lines further down
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id IN (330,331,332,333,334); DELETE FROM activity_metrics WHERE activity_id IN (330,331,332,333,334); DELETE FROM activities WHERE id IN (330,331,332,333,334);")
    # --help rather than a bare call: interpolating a compile-time empty string
    # into the command slot is the #32-class crash, and --help returns the
    # identical discovery payload
    check!("the command list conforms to its schema", validate!("--help", "commands") == "")?
    # the remaining query payloads (#164 shipped three; the coach reads all of
    # these). Each runs the real command against the fixture db.
    check!("activities conforms", validate!("activities 30", "activities") == "")?
    check!("top conforms", validate!("top tss 20", "top") == "")?
    check!("load conforms", validate!("load 90", "load") == "")?
    check!("stats conforms", validate!("stats", "stats") == "")?
    check!("doctor conforms", validate!("doctor", "doctor") == "")?
    check!("zones conforms", validate!("zones", "zones") == "")?
    check!("power-curve conforms", validate!("power-curve", "power_curve") == "")?
    check!("compare conforms", validate!("compare week", "compare") == "")?
    check!("progress conforms", validate!("progress", "progress") == "")?
    # `week` is the CURRENT Mon-Sun window, and the fixture's sessions are dated
    # relative to today — d1/d2 can both land in the PREVIOUS week, leaving the
    # payload empty and the item schema (14 required keys + the status enum)
    # evaluated against nothing. Seed a session dated TODAY and assert the array
    # is non-empty before trusting the validation. Third instance of this trap
    # in this PR; the assertion is the cheap half.
    wk_sess = Str.trim(strjq!(ctx, ["week", "add", "${ctx.today}", "endurance", "week schema probe", "r"], ".data.id"))
    check!("the week payload has rows to validate", strjq!(ctx, ["week"], ".data | length > 0") == "true")?
    check!("week conforms (with rows)", validate!("week", "week") == "")?
    check!("week all conforms (with rows)", validate!("week all", "week") == "")?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id = ${wk_sess};")
    check!("version conforms", validate!("--version", "version") == "")?
    # the action payloads the coach consumes — week add's id is parsed back out,
    # complete/skip results are branched on, analyze's converged flag drives a
    # re-run. analyze NARRATES to stderr, which is exactly why validate! keeps
    # stderr out of the pipe.
    check!("analyze conforms", validate!("analyze", "analyze") == "")?
    # config SET rather than get: set always returns the payload, while get on a
    # key the fixture has not written is the not_set ERROR envelope (a different
    # shape). Re-setting the value the suite already configured is idempotent.
    # NOTE this validate! EXECUTES its argument, so it is a clock write, not a read.
    # On main this was the line that actually caused #200 -- it flipped the binary to
    # Chicago for the whole remainder of the run while the harness was still on UTC.
    check!("config conforms", validate!("config set timezone ${ctx.tz}", "config") == "")?
    act_sess = Str.trim(strjq!(ctx, ["week", "add", "2099-11-11", "endurance", "schema action probe", "r"], ".data.id"))
    check!("week add conforms", validate!("week add 2099-11-12 endurance d r", "week_add") == "")?
    check!("skip conforms", validate!("skip ${act_sess} \"probe reason\"", "skip") == "")?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE target_date LIKE '2099-11-%';")
    # ...and an empty capture must FAIL rather than read as conformance, which
    # is what it did before (a crashed binary validated clean)
    check!("an empty payload is not conformance", Str.contains(Str.trim(sh!("out=$(false 2>/dev/null); if [ -z \"$out\" ]; then echo 'no output from `x` — nothing was validated'; fi")), "nothing was validated"))?
    # the error arm of the envelope, with its code vocabulary enumerated: an
    # error code that is not in the schema fails here, which is the same drift
    # bargain additionalKeys makes for payload keys
    check!("an error envelope conforms, code included", Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' activity 99999999 2>&1 | jq -r --slurpfile schema schemas/v2/envelope.json -f tools/validate.jq 2>&1")) == "")?
    # The enum is hand-maintained beside 27 emit sites, and this PR proved twice
    # in one file that it drifts: a fabricated code (bad_args, left over from a
    # rewritten branch) and a missing one (activity_required, a routine
    # response). Set equality in BOTH directions, extracted multi-line-aware
    # because err_out! calls wrap. A count check would have passed — the sets
    # were both 27.
    code_diff = Str.trim(sh!("cat src/*.roc | tr '\\n' ' ' | grep -oE '(err_out!|emit_err!)\\( *\"[a-z_]+\"' | grep -oE '\"[a-z_]+\"' | tr -d '\"' | sort -u > /tmp/stride_src_codes.$$; jq -r '.properties.error.properties.code.enum[]' schemas/v2/envelope.json | sort > /tmp/stride_enum_codes.$$; diff /tmp/stride_src_codes.$$ /tmp/stride_enum_codes.$$; rm -f /tmp/stride_src_codes.$$ /tmp/stride_enum_codes.$$"))
    check!("every error code the source emits is in the contract, and vice versa", code_diff == "")?
    # ── the two directions of the error-code declaration (#239) ─────────────────
    # Done in jq, NOT with `comm` and process substitution. `sh!` runs under /bin/sh, which
    # on macOS is bash 3.2 in POSIX mode, where `<(...)` is a SYNTAX ERROR — both operands
    # come back empty and `"" == ""` passes. This file has been bitten by exactly that
    # before; the first draft of this check was written that way.
    decl_f = Str.trim(sh!("mktemp"))
    _ = sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' --help | jq -c '(.data.universal_error_codes // []) + [.data.commands[].error_codes[]?] | unique' > '${decl_f}'")
    ndecl = Str.trim(sh!("jq -r 'length' '${decl_f}' 2>/dev/null"))
    # the probe has to be able to speak: an empty declared set would make BOTH directions
    # below trivially satisfiable in one of the two, and a jq error yields "" not 0.
    check!("the declared error-code set is non-empty (got ${ndecl})", ndecl != "" and ndecl != "0")?
    # The selector is PINNED to the error-code enum's path rather than sweeping every
    # enum in the file. Enums are the house style here — 11 of 26 schemas in schemas/v2
    # carry at least one, activity.json carries three — and envelope.json is a likely home
    # for a second: the natural next step from this PR is a retriability or severity field
    # on the error object, whose members would then be folded into the "contract" set and
    # demanded as error-code attributions.
    #
    # A pinned path is only safe because of the guard immediately below. Pinned and
    # unguarded, a restructure that moved the enum would silently empty the contract set
    # and make contract->declared vacuous — the exact hazard the guard closes. The two
    # belong together; either alone is worse than the generic selector.
    #
    # ...and the CONTRACT set too, symmetrically. Without this the contract->declared
    # direction passes vacuously if envelope.json's `enum` key is ever renamed: the
    # selector yields [], and [] mapped and joined is "", which is the pass condition.
    # It held only through an undocumented coupling — the declared->contract sibling fails
    # loudly in that same scenario — and the commit message ranked that sibling as the
    # lesser of the two, so anyone trimming the "redundant" direction would have turned the
    # load-bearing one into "" == "".
    ncontract = Str.trim(sh!("jq -r '.properties.error.properties.code.enum | length' schemas/v2/envelope.json 2>/dev/null"))
    check!("the contract error-code set is non-empty (got ${ncontract})", ncontract != "" and ncontract != "0")?
    # DECLARED -> CONTRACT. A typo, or a code deleted from the envelope but left declared.
    notin = Str.trim(sh!("jq -r --slurpfile d '${decl_f}' '.properties.error.properties.code.enum as $c | $d[0] | map(select(. as $x | ($c | index($x)) == null)) | join(\" \")' schemas/v2/envelope.json 2>&1"))
    check!("every declared error code exists in the envelope contract (stray: ${notin})", notin == "")?
    # CONTRACT -> DECLARED, which is the direction that matters. A code added to the
    # envelope and attributed to nothing is how a hand-maintained list rots; it fails here
    # instead of sitting undiscovered. `unknown_command` is the one exemption and it is a
    # real one — it is what you get when there IS no form, so naming a form would be false.
    unattr = Str.trim(sh!("jq -r --slurpfile d '${decl_f}' '.properties.error.properties.code.enum | unique | map(select(. as $x | ($d[0] | index($x)) == null)) | map(select(. != \"unknown_command\")) | join(\" \")' schemas/v2/envelope.json 2>&1"))
    check!("every contract error code is attributed to a form or to universal (unattributed: ${unattr})", unattr == "")?
    _ = sh!("rm -f '${decl_f}'")
    check!("...and an unknown code would be caught", Str.contains(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' activity 99999999 2>&1 | jq '.error.code = \"not_a_real_code\"' 2>&1 | jq -r --slurpfile schema schemas/v2/envelope.json -f tools/validate.jq 2>&1"), "not in enum"))?
    check!("the envelope itself conforms", Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' summary 2>&1 | jq -r --slurpfile schema schemas/v2/envelope.json -f tools/validate.jq 2>&1")) == "")?
    # the summary EMBEDDED in the plan bundle is the same shape as the standalone
    # one — asserted, not assumed (plan.json types it loosely because the
    # validator has no $ref)
    check!("plan's embedded summary conforms to the summary schema", Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' plan 2>&1 | jq '.data.summary' 2>&1 | jq -r --slurpfile schema schemas/v2/summary.json -f tools/validate.jq 2>&1")) == "")?
    # ...and the plan ARRAYS need rows, or their item schemas (5 and 9 required
    # keys, plus the status enum) pass on empty arrays exactly like segments did
    sch_done = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d1}", "endurance", "schema probe done", "r"], ".data.id"))
    _ = stride!(ctx.bin, ctx.home, ["complete", sch_done, "101"])
    sch_open = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d2}", "threshold", "schema probe open", "r"], ".data.id"))
    check!("plan arrays are populated for this check", strjq!(ctx, ["plan"], "(.data.open_sessions | length > 0) and (.data.plan_history_28d | length > 0)") == "true")?
    check!("plan with populated arrays conforms", validate!("plan", "plan") == "")?

    # ── data freshness (#221) ───────────────────────────────────────────
    # The schema check above proves SHAPE, and shape is exactly what a hardcoded zero
    # satisfies. These pin the counts to state the test controls, in both directions, so a
    # constant fails: the fixture is analyzed here, so metrics reads 0 and streams reads
    # its resting 1 (see below), then each moves when its underlying condition is created,
    # then returns.
    pf! = |q| Str.trim(strjq!(ctx, ["plan"], ".data.data_freshness.${q}"))
    check!("a current database is awaiting no metrics", pf!("activities_awaiting_metrics") == "0")?
    # 1 is the RESTING value here, not a bug — pinning it to 0 would have been pinning a
    # wish. It matters that this is non-zero: the checks below move it to 2 and back, which
    # a field hardcoded to any single constant cannot survive.
    #
    # WHICH row is named by assertion rather than by comment. An earlier draft said "id 99,
    # the baseline probe"; 99 is deleted four hundred lines above this, so that comment sent
    # the next reader to a row which no longer exists. The real one is 102, the HR-only
    # Rowing row deliberately seeded without streams. Asserting it means anyone who adds an
    # unstreamed activity earlier in the seed gets told exactly what changed, instead of
    # three checks failing with a message about the wrong id.
    unstreamed = Str.trim(sh!("sqlite3 '${ctx.db}' \"SELECT COALESCE(group_concat(a.id),'') FROM activities a LEFT JOIN streams s ON s.activity_id = a.id WHERE s.activity_id IS NULL AND a.moving_time > 0;\""))
    check!("exactly one fixture activity has no streams, and it is 102 (got ${unstreamed})", unstreamed == "102")?
    check!("...so awaiting streams rests at 1", pf!("activities_awaiting_streams") == "1")?
    # ...and it is the same count doctor reports, which is what the schema claims and
    # nothing checked. A cross-COMMAND oracle: it catches one side drifting from the other —
    # a field wired to the wrong query, a stale copy, a type slip — and is blind BY
    # CONSTRUCTION to a bug inside the Strava.pending_streams! they both call, since both
    # payloads would move together and the equality would still hold.
    check!("...the same count doctor reports as pending_streams", pf!("activities_awaiting_streams") == Str.trim(strjq!(ctx, ["doctor"], ".data.pending_streams")))?
    # newest_activity read a second way, so a hardcoded date or a full timestamp fail — the
    # schema's "string" accepts both. Not "the wrong column": `activities` has exactly one
    # date column, so that is not a case this fixture can express.
    newest_sql = Str.trim(sh!("sqlite3 '${ctx.db}' \"SELECT COALESCE(MAX(substr(start_local,1,10)),'') FROM activities;\""))
    # ...and the fixture must actually HAVE activities, or the line above is "" == "" and
    # reports green on a field that was never computed.
    check!("the fixture has activities, so the next check is not \"\" == \"\"", newest_sql != "")?
    check!("newest_activity agrees with the database", pf!("newest_activity") == newest_sql)?
    # The oracle above is byte-identical SQL, so it catches plumbing errors and nothing the
    # two share. This anchors the oracle ITSELF to a date the harness computed independently
    # of any query.
    check!("...and that date is the fixture's own d2, not merely what sqlite agrees to", newest_sql == ctx.d2)?
    # as_of and newest_activity pinned side by side, as DIFFERENT dates with different
    # provenance. Three rounds of prose on this PR described their relationship wrongly —
    # "the gap is days since the last ride", "the gap goes to zero on stale data" — and a
    # comment cannot catch the fourth. analyze has just run, so as_of is floored at today
    # while newest_activity stays on the last activity's own date, one day earlier.
    check!("analyze floors as_of at today...", Str.trim(strjq!(ctx, ["plan"], ".data.summary.as_of")) == ctx.today)?
    check!("...while newest_activity stays on the last activity's date, a different day", pf!("newest_activity") == ctx.d2 and ctx.today != ctx.d2)?
    # ...and that as_of FREEZES when analyze does not run, which is the half the pair above
    # cannot see: recompute as_of from the clock at read time and both checks still pass,
    # while the reasoning that makes last_sync the primary signal goes silently dead.
    # Truncating daily_load is what "analyze has not run since" looks like to a reader.
    _ = sql!(ctx.db, "DELETE FROM daily_load WHERE day > '${ctx.d1}';")
    check!("d1 is not today, so the next check cannot pass by the two dates coinciding", ctx.d1 != ctx.today)?
    check!("as_of is pinned to the last analyze, not recomputed from the clock", Str.trim(strjq!(ctx, ["plan"], ".data.summary.as_of")) == ctx.d1)?
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("...and analyze puts it back on today", Str.trim(strjq!(ctx, ["plan"], ".data.summary.as_of")) == ctx.today)?
    # Bumping every stored metrics_rev is precisely what a release that changes the metric
    # definitions does, and it is the case doctor's `unanalyzed` cannot see: the rows still
    # have metrics, so `m.activity_id IS NULL` counts none of them.
    _ = sql!(ctx.db, "UPDATE activity_metrics SET metrics_rev = 0;")
    n_stale = pf!("activities_awaiting_metrics")
    check!("a stale metrics_rev puts every scored row back in the queue", n_stale != "0")?
    check!("...which doctor's `unanalyzed` still reads as 0, being a coverage number", Str.trim(strjq!(ctx, ["doctor"], ".data.unanalyzed")) == "0")?
    # ...and doctor's own awaiting_metrics DOES see it (#238). Asserted equal to plan's,
    # not merely non-zero: the two commands answer the same question through the same
    # function, and a check that only said "> 0" would pass while they disagreed.
    check!("...while doctor's awaiting_metrics sees it, agreeing with plan exactly", Str.trim(strjq!(ctx, ["doctor"], ".data.awaiting_metrics")) == n_stale)?
    check!("...and reports the count as known", Str.trim(strjq!(ctx, ["doctor"], ".data.awaiting_metrics_known")) == "true")?
    check!("...with no config error to report", Str.trim(strjq!(ctx, ["doctor"], ".data.config_error")) == "")?
    # The HUMAN line too, against the same oracle. Review collapsed the known/unknown `if`
    # to its else branch — so the screen read "unknown" on every healthy install — and
    # nothing failed, because the only human check ran in the corrupt state.
    # Terminated at end-of-line. Without the \n this is a prefix match, so appending a
    # digit to the rendered number — "…analyze: 37" against an expected 3 — passed.
    check!("...and doctor's human screen carries the same number", Str.contains(sh!("HOME='${ctx.home}' '${ctx.bin}' doctor 2>/dev/null"), "would be recomputed by analyze: ${n_stale}\n"))?
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("...and running analyze returns it to zero", pf!("activities_awaiting_metrics") == "0")?
    # doctor's SECOND measurement point. One point let the count be hardcoded to the
    # fixture's value and survive; two, with different values, cannot be met by a constant.
    check!("...doctor's count returning with it", Str.trim(strjq!(ctx, ["doctor"], ".data.awaiting_metrics")) == "0")?
    # Same again for streams: a different predicate, on a different table. Done by ADDING a
    # row rather than deleting 101's, because 101's stored streams are what its power
    # metrics are computed from — dropping them, or restoring them as an empty marker,
    # would silently change every number the checks after this one read. This driver is
    # OFFLINE, so the row cannot be restored by re-syncing it.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (9221,'freshness probe','Ride','2019-01-01T10:00:00Z',3600,20000);")
    check!("a second activity with no streams row raises the count", pf!("activities_awaiting_streams") == "2")?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id = 9221;")
    # The probe must leave the fixture exactly as it found it: id assertions in this file
    # are positional and every later check reads the analyzed fixture.
    check!("the freshness probe left the fixture current", pf!("activities_awaiting_metrics") == "0")?
    check!("...on both counts", pf!("activities_awaiting_streams") == "1")?
    check!("...and newest_activity is back where it started", pf!("newest_activity") == newest_sql)?
    # The count needs the FULL zone config, including per-sport overrides, where the rest
    # of `plan` needs only the four global keys. Propagating that stricter read killed the
    # whole command — no summary, no sessions, no adherence — on a database that planned
    # fine before this feature existed. `config set` refuses this value today, but the
    # write gate is newer than the key, so a database written earlier can still hold one.
    check!("the metrics count is known on a healthy config", pf!("activities_awaiting_metrics_known") == "true")?
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO config (key,value) VALUES ('hr_z2_max_ride','1.6e2');")
    # Compared against `summary`, which is unaffected by this key, rather than merely
    # asserted non-empty: on an error envelope `.data.summary.as_of` is absent and `jq -r`
    # prints "null", so a `!= ""` test passes on exactly the failure it is meant to catch.
    check!("an unparseable per-sport zone override does not cost the planning bundle", strjq!(ctx, ["plan"], ".data.summary.as_of") == Str.trim(strjq!(ctx, ["summary"], ".data.as_of")))?
    check!("...and that comparison is against a real date, not null == null", !(Str.contains(Str.trim(strjq!(ctx, ["summary"], ".data.as_of")), "null")))?
    check!("...with the rest of the bundle intact", strjq!(ctx, ["plan"], ".data.adherence_28d.planned | type") == "number")?
    check!("...it reports the metrics count as UNKNOWN rather than a bare zero", pf!("activities_awaiting_metrics_known") == "false")?
    check!("...and `plan` still exits 0", Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' plan >/dev/null 2>&1; echo $?")) == "0")?
    # ...and the human line SPEAKS on that state rather than staying silent, which is the
    # whole point of the known flag: the count is 0 there.
    check!("...and the human line names it instead of going quiet", Str.contains(sh!("HOME='${ctx.home}' '${ctx.bin}' plan 2>/dev/null"), "awaiting-metrics count unreadable"))?
    # ...and doctor NAMES THE KEY (#238). `plan` degrades silently and correctly — a
    # planning read should not lecture about config — but that left the condition
    # reported nowhere, which review of #221 established and this closes. doctor is the
    # command whose job is to say what is wrong with the installation.
    check!("doctor degrades on the same config rather than failing", Str.trim(strjq!(ctx, ["doctor"], ".data.awaiting_metrics_known")) == "false")?
    # The FULL sentence, remedy included. doctor carried a truncated copy of this string
    # until the pure half was extracted from Output.unreadable_config! — one that had
    # dropped the "fix it with" clause, which README says every gap states. Pinned whole
    # so the two renderings cannot drift apart again.
    check!("...and names the offending key, its value and the fix", Str.trim(strjq!(ctx, ["doctor"], ".data.config_error")) == "hr_z2_max_ride is set to '1.6e2', which is not a number — fix it with `stride config set hr_z2_max_ride <value>`")?
    check!("...while still reporting everything else it knows", Str.trim(strjq!(ctx, ["doctor"], ".data.activities | type")) == "number")?
    check!("...and exits 0, because a diagnosis is not a failure", Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' doctor >/dev/null 2>&1; echo $?")) == "0")?
    # The WHOLE line, reason included. A `contains` on the "unknown" prefix let the
    # `— ${config_error}` suffix be deleted silently, and that suffix is the entire
    # justification for surfacing this in the diagnostic command.
    #
    # The remedy half of this literal is OWNED BY Output.unreadable_config_msg and pinned
    # by three checks across this file. Reword it for `analyze`'s benefit and this one
    # fails under a name pointing at doctor's rendering, which is a module away from the
    # cause. That misdirection is the price of the guard, not a reason to drop it.
    check!("...and its human screen says so too, with the reason attached", Str.contains(sh!("HOME='${ctx.home}' '${ctx.bin}' doctor 2>/dev/null"), "would be recomputed by analyze: unknown — hr_z2_max_ride is set to '1.6e2', which is not a number — fix it with `stride config set hr_z2_max_ride <value>`"))?
    # The schema says the count is 0 whenever the flag is false. Nothing asserted it, so a
    # degraded arm returning a stale or invented number passed.
    check!("...and the count really is zero, as the schema promises", Str.trim(strjq!(ctx, ["doctor"], ".data.awaiting_metrics")) == "0")?
    check!("...with the degraded payload still conforming", validate!("doctor", "doctor") == "")?
    _ = sql!(ctx.db, "DELETE FROM config WHERE key = 'hr_z2_max_ride';")
    check!("...and removing it restores doctor's count too", Str.trim(strjq!(ctx, ["doctor"], ".data.awaiting_metrics_known")) == "true")?
    check!("...and removing the bad override restores the count", pf!("activities_awaiting_metrics_known") == "true")?
    check!("...to a real zero, not merely a known one", pf!("activities_awaiting_metrics") == "0")?
    # ── last_sync (#221) ────────────────────────────────────────────────
    # This driver never syncs, so the CORRECT value here is "" — which is also what every
    # broken implementation produces. Asserting "" would be the vacuous absence check this
    # file warns about, and it showed: deleting the whole lookup, and returning the raw
    # stored epoch unconverted, BOTH passed the entire suite. The only real test is to
    # write the key, which costs one line.
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO config (key,value) VALUES ('last_sync_epoch','1700000000');")
    check!("last_sync is the stored epoch as UTC ISO, not the raw value", pf!("last_sync") == "2023-11-14T22:13:20Z")?
    # arg_i64 takes plain integers only, so exponent notation is the unparseable case.
    _ = sql!(ctx.db, "UPDATE config SET value = '1e9' WHERE key = 'last_sync_epoch';")
    check!("...an unparseable one reads empty rather than failing plan", pf!("last_sync") == "")?
    # Negative is a THIRD arm, and the one that used to emit "1970-01-01T00:00:0-1Z" — a
    # malformed string the schema's bare "string" type accepts without complaint.
    _ = sql!(ctx.db, "UPDATE config SET value = '-1' WHERE key = 'last_sync_epoch';")
    check!("...and a negative one does not become a malformed timestamp", pf!("last_sync") == "")?
    _ = sql!(ctx.db, "DELETE FROM config WHERE key = 'last_sync_epoch';")
    check!("...and with the key gone it is empty again", pf!("last_sync") == "")?
    # ── the human line (#221) ───────────────────────────────────────────
    # Render.freshness_note is called ONLY from the human path, so the pure expects prove
    # the formatting and nothing proves the wiring. Deleting the print block outright
    # passed the whole suite. The block already sits on non-zero state, so this costs one
    # line and pins the separator, the arm order and the call itself end to end.
    _ = sql!(ctx.db, "UPDATE activity_metrics SET metrics_rev = 0;")
    check!("the human line carries both arms, in order, with the separator", Str.contains(sh!("HOME='${ctx.home}' '${ctx.bin}' plan 2>/dev/null"), "DATA: 3 awaiting metrics (stride analyze) · 1 awaiting streams (stride sync)"))?
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    # ...and it goes SILENT once there is nothing to say — the arm that runs on almost
    # every real invocation, and the one no "contains" check can see. Reaching it means
    # retiring the fixture's resting 1: giving 102 an empty-streams marker moves BOTH counts
    # — it leaves the `s.activity_id IS NULL` set, and stream_len_used goes 0 -> 2 so the row
    # goes pending — hence the analyze. `{}` is this codebase's 404 marker, not a real
    # stream, which is why it is written directly rather than fetched.
    # Both sides are then undone, and the resting state is re-asserted rather than assumed.
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (102, '{}');")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    # Paired with a POSITIVE marker. On its own this was a pure absence assertion and it was
    # vacuous: deleting the HR zone bounds makes `plan` print the missing-config screen,
    # which contains no "DATA:" either, so the check reported ok on a command that produced
    # no bundle at all. "OPEN PLAN" is a heading only the real human bundle emits.
    plan_silent = sh!("HOME='${ctx.home}' '${ctx.bin}' plan 2>/dev/null")
    check!("...and says nothing at all once both counts are zero", !(Str.contains(plan_silent, "DATA:")) and Str.contains(plan_silent, "OPEN PLAN"))?
    _ = sql!(ctx.db, "DELETE FROM streams WHERE activity_id = 102;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("...and the fixture is back to its resting 1 awaiting stream", pf!("activities_awaiting_streams") == "1")?
    check!("...with nothing awaiting metrics", pf!("activities_awaiting_metrics") == "0")?

    # ── season: blocks bounded by absence (#139, ADR 0011) ──────────────
    # The fixture's activities sit in a handful of dates, so this exercises the
    # boundary rule rather than a rich history: what matters is that a gap
    # OPENS a block, that a one-week gap does NOT, and that the count is a
    # measured consequence of the dates rather than a constant.
    # The human screens have a 100-column table budget (render_table's
    # max_total). Nothing anywhere asserted it, which is how season shipped a
    # 126-column table -- the only violator in the CLI -- that wrapped rows
    # mid-number into unreadable fragments on any narrower terminal. Applied
    # CLI-wide because a guard on one command is a guard nobody generalises.
    # awk's length() counts BYTES on macOS whatever the locale, and every box
    # glyph is three of them, so `wc -m` is what actually measures a column.
    # The list is every command that DRAWS a table -- summary, doctor and reps
    # emit none, so listing them added three vacuous passes and hid that `top`
    # and `week all` were missing (the latter sits at exactly 100 on real data).
    wide = Str.trim(sh!("for c in season activities plan week 'week all' compare progress load stats zones 'power-curve' 'top tss'; do HOME='${ctx.home}' '${ctx.bin}' $c 2>/dev/null; done | grep -E '[│╭├╰]' | while IFS= read -r l; do printf '%s' \"$l\" | LC_ALL=en_US.UTF-8 wc -m; done | tr -d ' ' | awk '$1 > 100' | sort -rn | head -1"))
    check!("no human table exceeds the 100-column budget", wide == "")?
    # ...and again with a cell that has NO break opportunity, which is what gives the
    # sweep above teeth. On the fixture every table sits well inside the budget, so that
    # one passes even on a binary whose squeeze does not work (#194). The lever is a
    # user-supplied token, not the data: `week add`'s detail is free text, so a hyphenated
    # phrase with no spaces is a single unbreakable word in the widest column of `week`.
    # Inflating daily_load does NOT work here and is the trap worth naming -- season's
    # block cell is a fixed-width date span, so load only widens the NUMERIC columns and
    # never the unbreakable one. Measured inside this harness on a reverted binary:
    # 84/84/87/89/98 at x1 through x1e14, green every time.
    # A FAR-FUTURE date swept through `week all`, not ctx.d1 through bare `week`. Two
    # traps, both hit while writing this: `week add` on an existing date REVISES that
    # date's open session in place, so a fixture date would have been clobbered rather
    # than added to; and bare `week` renders only the current Mon-Sun window, so a date
    # three days back can land in the PREVIOUS week and never appear. That version of
    # this check passed against a reverted binary -- the token rendered at 138 columns
    # standalone and the check never saw it. The row is deleted again because
    # planned_sessions ids are positional in this suite.
    _ = stride!(ctx.bin, ctx.home, ["week", "add", "2099-06-15", "endurance", "Z2-endurance-90min-outdoor-conversational-no-chasing-wheels-keep-it-truly-easy", "unbreakable-detail-probe"])
    wide_tok = Str.trim(sh!("HOME='${ctx.home}' '${ctx.bin}' week all 2>/dev/null | grep -E '[│╭├╰]' | while IFS= read -r l; do printf '%s' \"$l\" | LC_ALL=en_US.UTF-8 wc -m; done | tr -d ' ' | awk '$1 > 100' | sort -rn | head -1"))
    # The probe must have been INSERTED, asserted before the width is judged.
    # `wide_tok == ""` is satisfied by absence, so if `week add` ever stops inserting -- a
    # bad date, a changed arity -- the width check goes green against a binary that fails
    # it. Verified: breaking the add made the whole suite pass on a REVERTED binary.
    # Asserted against the ROW, not the rendered text: at min_col the token is broken into
    # twelve-column pieces, so no word of it survives whole on one line to grep for. The
    # first version of this assertion did grep, and failed against a working binary.
    tok_rows = Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM planned_sessions WHERE rationale = 'unbreakable-detail-probe';"))
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE rationale = 'unbreakable-detail-probe';")
    check!("the unbreakable-token probe was inserted", tok_rows == "1")?
    check!("...and none exceeds the budget when a detail is one unbreakable token", wide_tok == "")?
    # #201: the 2026-08-17 compiler widened I64.from_str/U64.from_str to accept
    # exponent notation -- "1e1" was a parse error on the previous pin and is 10 now.
    # It reached MUTATING commands (`skip 1e1` addressed planned session 10, an
    # unrecoverable write to judgment-tier data) and no test could see it, because
    # nothing exercised an exponent argument.
    #
    # #197 pinned the accepting behaviour so a future bump could not move it silently,
    # and said that if #201 narrowed the parse this check should be INVERTED rather than
    # deleted. This is that inversion: stride now refuses exponent notation in user
    # arguments deliberately (Metrics.arg_i64/arg_u64), so the assertion is the REFUSAL.
    # Deleting it would let a future stdlib change quietly hand the accident back.
    #
    # Assert the RESULT, not the envelope: `schema_version` appears in the error arm
    # too, so the first version of this check stayed green in exactly the state it
    # exists to detect (proved by mutation).
    check!("exponent notation is refused in a count arg", Str.contains(stride!(ctx.bin, ctx.home, ["activities", "1e1"]), "bad_count"))?
    check!("...while the plain integer it would have meant still works", Str.trim(strjq!(ctx, ["activities", "10"], ".data | length > 0")) == "true")?
    check!("exponent notation is refused by a judgment-tier write", Str.contains(stride!(ctx.bin, ctx.home, ["skip", "1e1", "probe"]), "bad_id"))?
    check!("...and a non-numeric arg is still refused", Str.contains(stride!(ctx.bin, ctx.home, ["activities", "ten"]), "bad_count"))?
    # The secret arm of `config get` is a DIFFERENT payload shape from the arm
    # already covered — it adds `redacted` — and nothing validated it, which is
    # how an undeclared key shipped under additionalKeys:false.
    check!("config get on a secret conforms", validate!("config get strava_client_secret", "config") == "")?
    check!("...and it really is the redacting arm", Str.contains(strjq!(ctx, ["config", "get", "strava_client_secret"], ".data.redacted"), "true"))?
    check!("season conforms", validate!("season", "season") == "")?
    check!("season reports at least one block", strjq!(ctx, ["season"], ".data.blocks | length > 0") == "true")?
    check!("the gap threshold travels with the payload", strjq!(ctx, ["season"], ".data.gap_weeks") == "2")?
    # every block must have a start no later than its end, and a positive week
    # count -- a fabricated boundary usually shows up as one of these inverting
    # phrased as "no block violates" rather than "count of good == total":
    # after a pipe, jq's `.data.blocks` resolves against the piped array rather
    # than the root, so the comparison silently read `1 == 0`
    check!("blocks are well-formed spans", strjq!(ctx, ["season"], "[.data.blocks[] | select((.start_date <= .end_date | not) or .weeks <= 0)] | length == 0") == "true")?
    # under three weeks the trend is WITHHELD, not zero-with-confidence
    check!("short blocks withhold their trend", strjq!(ctx, ["season"], "[.data.blocks[] | select(.weeks < 3 and .trend_known)] | length == 0") == "true")?
    # a threshold range must name the family it belongs to, or a rowing
    # threshold and a cycling FTP get averaged into a number describing nobody
    # The DESCRIPTION layer, not just the boundary. Review mutated the easy/hard
    # orientation, the dominant-family rule and the block end date, and all
    # three survived the whole suite -- the e2e checks only ever guarded where
    # blocks START and STOP.
    # easy/moderate/hard must land in that order, not transposed: the call site
    # reads `easy_pct: pcts.high_pct`, which looks inverted and is not.
    # snapshot the ROW, not a joined string -- the first version restored only
    # pi_easy_s and left the other two mutated for the rest of the suite
    _ = sql!(ctx.db, "CREATE TABLE pi_bak AS SELECT activity_id, pi_easy_s, pi_moderate_s, pi_hard_s FROM activity_metrics WHERE activity_id = 101;")
    _ = sql!(ctx.db, "UPDATE activity_metrics SET pi_easy_s = 3600, pi_moderate_s = 600, pi_hard_s = 0 WHERE activity_id = 101;")
    check!("easy time is reported as easy, not transposed onto hard", strjq!(ctx, ["season"], "[.data.blocks[] | select(.polarization_known and .easy_pct > .hard_pct)] | length > 0") == "true")?
    # restore ALL THREE, or every check below this one runs on mutated state
    _ = sql!(ctx.db, "UPDATE activity_metrics SET pi_easy_s = (SELECT pi_easy_s FROM pi_bak), pi_moderate_s = (SELECT pi_moderate_s FROM pi_bak), pi_hard_s = (SELECT pi_hard_s FROM pi_bak) WHERE activity_id = 101; DROP TABLE pi_bak;")
    # the block must END on a training day, never later -- it used to end on the
    # Sunday closing the last training week, dating an open block into the future
    # ctx.today, not jq's `now | strftime` -- jq resolves strftime through gmtime and
    # ignores TZ entirely, so that compared a Chicago-anchored end_date against a UTC
    # wall clock. It could not false-FAIL under this zone, which is why it survived two
    # rounds; it was simply a day weaker than it read, and wrong for any zone east of UTC.
    check!("no block ends after the last day it contains", strjq!(ctx, ["season"], "[.data.blocks[] | select(.end_date > \"${ctx.today}\")] | length == 0") == "true")?
    # trained weeks can never exceed the calendar weeks spanned
    check!("trained weeks never exceed the span", strjq!(ctx, ["season"], "[.data.blocks[] | select(.weeks > .span_weeks)] | length == 0") == "true")?
    # sessions counts ACTIVITIES. On THIS fixture the totals happen to agree,
    # which pins the join fix -- but equality is not an invariant in general
    # (see the absence case below), so this is a fixture pin, not a contract.
    check!("block and month session counts agree", strjq!(ctx, ["season"], "([.data.blocks[].sessions] | add) == ([.data.months[].sessions] | add)") == "true")?
    # ...including in the ordinary post-sync, pre-analyze state, where an
    # activity exists with no metrics row. Blocks used an inner join and months
    # a left join, so the two disagreed exactly there.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (921,'unscored probe','Ride','Ride','2010-01-05T06:00:00Z',3600);")
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day, tss, ctl, atl, tsb) VALUES ('2010-01-05', 30.0, 5.0, 5.0, 0.0);")
    check!("...and still agree when an activity has no metrics row yet", strjq!(ctx, ["season"], "([.data.blocks[].sessions] | add) == ([.data.months[].sessions] | add)") == "true")?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id = 921; DELETE FROM daily_load WHERE day = '2010-01-05';")
    # An activity that scored NO load inside an absence belongs to a month and
    # to no block -- correct, and the reason equality is not an invariant. The
    # earlier guard inserted a daily_load row alongside the activity, which put
    # it inside a block and guaranteed the answer it was checking.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (922,'unloaded in a gap','WeightTraining','WeightTraining','2010-06-15T06:00:00Z',3600);")
    # the month row itself comes from daily_load, so the month must EXIST for
    # the activity to be visible to it -- a zero-load day is exactly that:
    # present on the calendar, absent from training
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day, tss, ctl, atl, tsb) VALUES ('2010-06-15', 0.0, 1.0, 1.0, 0.0);")
    check!("an activity inside an absence counts for its month, not a block", strjq!(ctx, ["season"], "([.data.months[].sessions] | add) > ([.data.blocks[].sessions] | add)") == "true")?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id = 922; DELETE FROM daily_load WHERE day = '2010-06-15';")
    # `closed` must be decided on the same axis the blocks were cut on. A
    # day-aligned test declared a block closed up to 7 days before a session
    # today would actually have opened a new one. Asserting "all but the last
    # are closed" against this fixture proves nothing -- every block in it is
    # historical, so it passes under any rule, including `closed = True`. The
    # discriminating probe replaces daily_load with ONE row on each side of the
    # boundary and restores it afterwards.
    dl_rows_before = Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load;"))
    _ = sql!(ctx.db, "CREATE TABLE dl_bak AS SELECT * FROM daily_load; DELETE FROM daily_load;")
    # anchored to ctx.today, NOT to SQLite's 'now': 'now' is UTC while the binary is on
    # ${tz}, so on a Monday between 00:00 and 05:00 UTC the harness's Monday and the
    # binary's this_week were a week apart and the `closed` checks failed. Same bug as
    # #200, weekly rather than daily -- the first fix anchored the three shell `date`
    # reads and left three more: these two SQLite ones and a jq `now | strftime` about
    # 40 lines above.
    mon = "date('${ctx.today}', '-' || ((CAST(strftime('%w','${ctx.today}') AS INTEGER) + 6) % 7) || ' days')"
    # two clear weeks short of the gap: a session today would EXTEND this block
    _ = sql!(ctx.db, "INSERT INTO daily_load (day,tss,ctl,atl,tsb) VALUES (date(${mon}, '-14 days'), 50.0, 5.0, 5.0, 0.0);")
    check!("a block the gap has not yet closed reports open", strjq!(ctx, ["season"], ".data.blocks | last | .closed") == "false")?
    # exactly the gap: a session today would OPEN a new block, so this one is closed
    _ = sql!(ctx.db, "DELETE FROM daily_load; INSERT INTO daily_load (day,tss,ctl,atl,tsb) VALUES (date(${mon}, '-21 days'), 50.0, 5.0, 5.0, 0.0);")
    check!("a block the gap HAS closed reports closed", strjq!(ctx, ["season"], ".data.blocks | last | .closed") == "true")?
    # and training in the current week is unambiguously open
    _ = sql!(ctx.db, "DELETE FROM daily_load; INSERT INTO daily_load (day,tss,ctl,atl,tsb) VALUES (date('${ctx.today}'), 50.0, 5.0, 5.0, 0.0);")
    check!("training this week is never reported closed", strjq!(ctx, ["season"], ".data.blocks | last | .closed") == "false")?
    _ = sql!(ctx.db, "DELETE FROM daily_load; INSERT INTO daily_load SELECT * FROM dl_bak; DROP TABLE dl_bak;")
    check!("daily_load is restored after the closed probe", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load;")) == dl_rows_before)?
    # a malformed day used to become epoch 0 and publish span_weeks -2937 at
    # exit 0; it must refuse loudly, the way summary already does
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day, tss, ctl, atl, tsb) VALUES ('not-a-date', 30.0, 5.0, 5.0, 0.0);")
    bad_day = stride!(ctx.bin, ctx.home, ["season"])
    # `contains "error"` was the whole assertion here, and internal_error satisfies it —
    # so this check shipped in v0.7.0 while `season` was answering "unhandled failure:
    # BadDailyLoadDay(...) — please open an issue" (#243). Asserting the CODE is the
    # difference between "it refused" and "it refused for the reason it names".
    #
    # No ordinal here on purpose. This was written as "the second time in this file a
    # `contains` accepted the failure it was written to catch"; review found at least
    # seven already recorded, and nobody adding the eighth would come here to update a
    # number. The rule is the durable part: a `contains` accepts every superstring, so it
    # cannot distinguish the failure it names from the one it got.
    check!("a malformed daily_load day is refused, not absorbed", !(Str.contains(bad_day, "span_weeks")) and Str.contains(bad_day, "error"))?
    check!("...naming the code, not internal_error", strjq!(ctx, ["season"], ".error.code") == "unreadable_daily_load_day")?
    check!("...and quoting the unreadable day back", Str.contains(strjq!(ctx, ["season"], ".error.message"), "'not-a-date'"))?
    check!("...with a remedy that is a real command form", Str.contains(strjq!(ctx, ["season"], ".error.message"), "`stride analyze`"))?
    # ...and EVERY command that anchors on that day refuses it, not just the ones that
    # happened to have a guard. `compare` ran the identical
    # `SELECT day FROM daily_load ORDER BY day DESC LIMIT 1` and collapsed the failure to
    # epoch day 0 — which does not fail, it ANSWERS. Review measured a real 28-day block
    # (138 TSS, 2 sessions, 58% easy) coming back as `has_data: false` with every figure 0
    # at exit 0, and the human line "no load recorded either 28d · fitness holding", while
    # `summary` refused on the same database in the same run.
    #
    # Pinned here, against `not-a-date`, and NOT against the non-canonical `2026-3-05`
    # below: that one PARSES. `date_str_to_days` accepts it, so this guard cannot fire on
    # it and a check placed there would have been asserting the wrong mechanism —
    # `season` refuses it through a separate `is_canonical_date` test. First draft did
    # exactly that and went red, which is the only reason the distinction is written down.
    check!("...and `compare` refuses the same anchor rather than answering with an empty month", strjq!(ctx, ["compare", "month"], ".error.code") == "unreadable_daily_load_day")?
    # ...and `load`, which was the LAST reader of this column still absorbing (#249). It
    # collapsed an unreadable day to epoch 0 and rendered it as a real-looking
    # `1969-12-29` week carrying real load numbers, under a verdict line saying "form 0 —
    # balanced", at exit 0 — on the same database where summary, compare and season all
    # refused. A plausible wrong date is worse than a missing one: nothing about the row
    # tells the reader not to believe it.
    #
    # Guarded in Report.load_series! rather than in Render — not because Render could not
    # act (it has a third option and uses it four lines away, at the `keep_oks` that builds
    # tsb_series) but because a pure renderer can DROP the row and cannot NAME it, and
    # naming the row is the whole of #243. Dropping would also under-count the weekly
    # rollup with no marker, trading a large absorption for a small one.
    check!("...and `load` too, which invented a 1969 week rather than refusing", strjq!(ctx, ["load"], ".error.code") == "unreadable_daily_load_day")?
    check!("...so no fabricated week reaches the human table", !(Str.contains(stride_human!(ctx.bin, ctx.home, ["load"]), "1969")))?
    # ...and the verdict LINE, not just the table row. `List.last(ordered)` made the
    # fabricated day `today`, so the form reading was computed from it — a poisoned day
    # measured `form -6 — modeled fatigue building` off a trend anchored at epoch. Fixing
    # only the row would have left the verdict lying, which is why this is a separate
    # assertion and not a second `contains` on the same string.
    check!("...nor a verdict computed from the invented day", !(Str.contains(stride_human!(ctx.bin, ctx.home, ["load"]), "form")))?
    # `load` declares the code it can now raise. It was the only reader of daily_load that
    # did not, and the union check elsewhere in this file could not see the gap: summary,
    # plan and compare all declare it, so the union was satisfied by three other forms
    # while this one was wrong — green for the wrong reason.
    check!("...and `load` DECLARES the code it can raise", Str.contains(strjq!(ctx, ["--help"], "[.data.commands[] | select(.name == \"load\") | .error_codes[]]"), "unreadable_daily_load_day"))?
    # ...and a NULL day, which is the OTHER half of this column and was left out of the
    # first pass entirely. Fourteen `activities.start_local` reads got a COALESCE so the
    # decode would survive and the Roc guard could name the row; none of the six
    # `daily_load.day` reads did, so every guard above was unreachable for NULL and all five
    # readers answered `internal_error` — "please open an issue" — which is the exact shape
    # #243 was opened to remove, on the column #249 calls out first.
    #
    # Reaching it needs the NULL row to be the ONLY one: `ORDER BY day DESC` sorts NULLs
    # LAST, so with any readable day present the anchor queries never see it. That is the
    # same trap that hid three sites from the first pass, so the probe empties the table
    # rather than hoping.
    _ = sql!(ctx.db, "CREATE TABLE dl_bak249n AS SELECT * FROM daily_load; DELETE FROM daily_load; INSERT INTO daily_load (day,tss,ctl,atl,tsb) VALUES (NULL, 30.0, 5.0, 5.0, 0.0);")
    check!("a NULL daily_load day refuses by name on every reader, not internal_error", strjq!(ctx, ["load"], ".error.code") == "unreadable_daily_load_day" and strjq!(ctx, ["summary"], ".error.code") == "unreadable_daily_load_day" and strjq!(ctx, ["compare", "month"], ".error.code") == "unreadable_daily_load_day" and strjq!(ctx, ["season"], ".error.code") == "unreadable_daily_load_day" and strjq!(ctx, ["plan"], ".error.code") == "unreadable_daily_load_day")?
    _ = sql!(ctx.db, "DELETE FROM daily_load; INSERT INTO daily_load SELECT * FROM dl_bak249n; DROP TABLE dl_bak249n;")
    check!("...with daily_load restored, poisoned row and all", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load WHERE day = 'not-a-date';")) == "1")?

    # ── #249: an unreadable date must not become a wrong ANSWER ──────────────────────
    #
    # #243 made the readers refuse a POISONED date. This is the other half: the sites that
    # ABSORBED one — into an empty string, an epoch day, a fabricated trend — and answered
    # at exit 0. Nine sites, and the rule they follow is not "guard every read". It is a
    # SPLIT by what the command DOES with the date:
    #
    #   report — `activities` and `top` list or rank, so a wrong date cannot become a wrong
    #            answer; they show the row and let the reader act on its id
    #   refuse — `activity`, `reps`, `progress`, `week` and `analyze` compute from it (a
    #            90-day window, a comparables filter, a trend, an ordering key, a TSS), so
    #            a wrong date IS a wrong answer and they name the row instead
    #
    # The first draft of this change reported everywhere, and review measured what that
    # cost: `progress` moved its verdict from "improving (28%)" to "improving (19%)" and
    # printed `best: 1.49 ()`, because an empty date is not a missing cell — it is a
    # POSITION, and `ORDER BY a.name, a.start_local` sorts it first. Every number real, the
    # conclusion wrong, nothing marking it. On origin/main that command answered
    # internal_error, so reporting would have traded a loud failure for a quiet fabrication.
    #
    # A NULL start_local is the reachable form and needs hand-written SQL, which is why it
    # outlived #243: the column is nullable, and every `substr(start_local, 1, 10)` without
    # a COALESCE failed the decode with UnexpectedType(Null) — `internal_error`, "please
    # open an issue", the exact shape #243 was opened to remove.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (940,'null date','Ride','Ride',NULL,3600);")
    check!("a NULL start_local does not answer internal_error", strjq!(ctx, ["activities"], ".error.code // \"none\"") != "internal_error")?
    check!("...and the row is listed with an empty date rather than an invented one", Str.contains(strjq!(ctx, ["activities"], "[.data[] | select(.id == 940) | .date]"), "\"\""))?
    # FIRST, and this is the assertion that makes "report" defensible at all. SQLite sorts
    # NULL last under DESC, so before the ordering fix this row landed at position 736 of
    # 736 on a real database and fell outside the default limit of 30 entirely — a listing
    # that "shows what is stored" hiding the one row that needs repair. The check above
    # passes either way, because it looks the row up by id rather than reading the listing
    # the user gets; this one is what pins visibility.
    check!("...at the TOP of the listing, where no default limit can hide it", strjq!(ctx, ["activities"], ".data[0].id") == "940")?
    # ...and the rest of the listing keeps its contract. Ordering asserted in jq, not Roc:
    # Str has no ordering operator here, and a check that cannot express the property it
    # names is how "newest-first" would have gone unverified while the CASE arm reordered
    # everything below it.
    # `length >= 3` is the anti-vacuity half, and it is a MEASURED floor rather than a
    # round number: this fixture's listing is four rows, three of them readable, two
    # distinct dates. That is enough for the assertion to bite — reversing the order gives
    # ["2026-08-21","2026-08-23","2026-08-23"], which is not its own sort|reverse — and a
    # fixture that shrank below it would fail here rather than pass on an empty comparison.
    # An earlier draft wrote `> 5` from habit and went red on a listing that was never that
    # long, which is the only reason the real number is written down.
    check!("...while the readable rows below it are still newest-first", strjq!(ctx, ["activities"], "[.data[1:][].date] | (length >= 3) and (. == (sort | reverse))") == "true")?
    # ...and the OTHER unreadable shapes, because the hoist tests three of them and the
    # first version tested one. Review measured a stored empty string at position 737 of 737
    # and '0000-0z-01…' at 745 — both outside the default limit, which is verbatim the
    # failure the paragraph above claims to have fixed. 'garbage-da' escaped only by sorting
    # high. Asserted as a SET so the four cannot be checked one at a time and pass by luck of
    # which one leads.
    #
    # '1000-02-30' is the fourth shape and it is here for a platform reason, not a date one:
    # it is IMPOSSIBLE but well FORMED, so the only thing that rejects it is the bundled
    # SQLite's date(), and the version bundled differs from the one on this machine's PATH
    # (3.49.1 vs 3.43.2 — the older returns it verbatim). The refusal rule is Roc and
    # version-independent; this visibility rule is not. This row is what holds them together
    # across a platform upgrade.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (941,'poisoned low','Ride','Ride','0000-0z-01T10:00:00Z',3600),(942,'stored empty','Ride','Ride','',3600),(947,'impossible low','Ride','Ride','1000-02-30T10:00:00Z',3600);")
    check!("...and an empty string, a lexically-low poisoned date and an impossible day surface too", strjq!(ctx, ["activities"], "[.data[0:4][].id] | sort | join(\",\")") == "940,941,942,947")?
    # ...and `date_known` agrees with the REFUSAL rule on the one input where the two can
    # diverge. '1000-02-30' is impossible but well FORMED, so no string inspection rejects
    # it — only the bundled SQLite's date() does, and only since 3.46. That makes it the
    # single input holding four SQL copies of the predicate to the Roc one, and it matters
    # more than it did for the hoist: `date_known` is a PUBLISHED boolean SKILL.md tells the
    # coach to trust for "is this date a hole", so a platform change that loosened date()
    # would ship `date_known: true` on a row every computing command refuses — a contract
    # statement contradicting the engine, where before it was only a sort order.
    check!("...and `date_known` is false for the impossible day, holding SQL to the Roc rule", strjq!(ctx, ["activities"], "[.data[] | select(.id == 947) | .date_known] | join(\",\")") == "false")?
    check!("...while a readable row says true, so the flag is not simply always false", strjq!(ctx, ["activities"], "[.data[] | select(.date_known == true)] | length > 0") == "true")?
    # `doctor`'s COUNT, which is the whole of #265 and had nothing asserting its behaviour.
    # The schema loop validates the key's presence and type on `doctor` and `top`, so a
    # predicate that drifted to always-0 passed everything. All four SQL sites now share
    # `Report.date_known_sql`, so the fixture above holds them by construction — but the
    # count is a different CONSUMER of that predicate and could be wired wrong on its own.
    check!("`doctor` counts the undateable rows rather than reporting a clean engine", strjq!(ctx, ["doctor"], ".data.undateable_activities") == "4")?
    # ...and a READABLE lexically-low date is NOT hoisted, which is the other half of the
    # predicate. Without this the clause could hoist everything and still pass above.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (948,'readable low','Ride','Ride','1000-01-01T10:00:00Z',3600);")
    check!("...while a readable early date stays in date order, so the hoist is not hoisting everything", strjq!(ctx, ["activities"], "[.data[0:5][].id] | map(select(. == 948)) | length") == "0")?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id IN (941,942,947,948);")
    # `top time`, NOT `top tss`, and the difference is the whole check. `top tss` filters on
    # `m.tss > 0` and row 940 has no activity_metrics row at this point in the fixture — the
    # analyze probe that would score it runs later — so 940 is absent from the result set
    # entirely and nothing about it could affect the answer. Review dumped the ids: [101,
    # 102, 103]. `top time` filters on `a.moving_time > 0`, which 940 satisfies.
    #
    # And a POSITIVE marker rather than "the code is not unreadable_activity_date". That
    # absence is also satisfied by a crash, an empty payload, `bad_metric`, or deleting the
    # command — the shape this file has been caught by repeatedly. Asserting the row is
    # present WITH an empty date is what proves `top` reported rather than refused.
    check!("...and `top` ranks on its metric, so it reports the row rather than refusing", Str.contains(strjq!(ctx, ["top", "time"], "[.data[] | select(.id == 940) | .date]"), "\"\""))?
    # The refusers. Each one COMPUTES from the date, and each was measured absorbing it.
    check!("`activity` refuses rather than dropping its comparison line", strjq!(ctx, ["activity", "940"], ".error.code") == "unreadable_activity_date")?
    check!("...naming the ROW, because a date is not something a caller can act on", Str.contains(strjq!(ctx, ["activity", "940"], ".error.message"), "940"))?
    # The MESSAGE distinguishes a NULL from a stored value. Quoting `('')` back reads as
    # though the empty string is what is in the column, which sends the reader to
    # `DELETE FROM activities WHERE start_local=''` — zero rows for a NULL, and an
    # unreproducible bug report. Output.roc records the identical failure one value along,
    # for 'garbage-da'.
    check!("...and says NULL rather than quoting an empty string back", Str.contains(strjq!(ctx, ["activity", "940"], ".error.message"), "no usable start_local"))?
    # ...and the three commands #249 names as exemplars, none of which had a check while 940
    # existed. `season` was measured answering internal_error on this exact row.
    #
    # The poisoned daily_load row planted higher in this function has to come OUT for the
    # duration, and finding that out is the point of writing it down: with it in place all
    # three refuse on `unreadable_daily_load_day` instead — a correct refusal, for the other
    # column, reached first. A check asserting `unreadable_activity_date` there would have
    # been red; one asserting "some error" would have passed without ever reaching the guard
    # it names. `compare`, `stats` and `week` need no such care because their activity sweep
    # runs before they touch daily_load at all.
    _ = sql!(ctx.db, "CREATE TABLE dl_bak249a AS SELECT * FROM daily_load; DELETE FROM daily_load WHERE day = 'not-a-date';")
    check!("`season`, `summary` and `plan` refuse the same row by name", strjq!(ctx, ["season"], ".error.code") == "unreadable_activity_date" and strjq!(ctx, ["summary"], ".error.code") == "unreadable_activity_date" and strjq!(ctx, ["plan"], ".error.code") == "unreadable_activity_date")?
    check!("...each naming the row, not just the class", Str.contains(strjq!(ctx, ["season"], ".error.message"), "940") and Str.contains(strjq!(ctx, ["summary"], ".error.message"), "940") and Str.contains(strjq!(ctx, ["plan"], ".error.message"), "940"))?
    # `compare` belongs INSIDE this scope for the same reason, and it is the reason the
    # sweep sits after the anchor read rather than at the top of the command: with the
    # poisoned day present it must answer `unreadable_daily_load_day`, exactly as `summary`
    # does, and a check placed outside here would have quietly pinned the opposite order.
    check!("`compare` refuses rather than publishing a verdict over a window a row left", strjq!(ctx, ["compare", "month"], ".error.code") == "unreadable_activity_date")?
    _ = sql!(ctx.db, "DELETE FROM daily_load; INSERT INTO daily_load SELECT * FROM dl_bak249a; DROP TABLE dl_bak249a;")
    check!("...and the poisoned daily_load row is back, so the checks below still have it", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load WHERE day = 'not-a-date';")) == "1")?
    # The THIRD bucket, and the one the split originally had no row for: `compare` and
    # `stats` use the date as a FILTER over an aggregate. `WHERE start_local >= :from` is
    # NULL-false, so the row does not produce a wrong value — it silently leaves the set, and
    # the failure is an ABSENCE. Review measured `compare` moving its verdict from
    # "load steady (4%)" to "load backed off (-16%)" and `stats` printing 474 sessions under
    # a heading that says ALL TIME while the database held 475. Both at exit 0, no marker.
    check!("`stats` refuses rather than printing an ALL TIME total that is quietly short", strjq!(ctx, ["stats"], ".error.code") == "unreadable_activity_date")?
    # `week` too, and this replaced a probe that was reachable only on some CALENDARS. The
    # first version planted a poisoned date built by corrupting the Monday's last digit, on
    # the reasoning that it always sorts inside the week. It does not: when Monday and
    # Monday+7 share a nine-character prefix — 18 of 72 Mondays, first 2026-09-21 — every
    # 10-character string inside the window is a readable date, so there was nothing to
    # plant and the check would have gone red pointing at a regression that did not exist.
    # Guarding the whole table in Plan.roc rather than the windowed rows makes a plain NULL
    # reach it on every week, which is also what made the NULL half reachable at all.
    check!("`week` refuses on any week, not only the ones the calendar allows", strjq!(ctx, ["week"], ".error.code") == "unreadable_activity_date")?
    # BOTH analyze runs rewrite daily_load, so the backup goes up before the FIRST one.
    # That ordering is not obvious and it cost a red run: the refusing run still reaches
    # the rebuild, because #243's deliberate policy is to walk and write every day it CAN
    # read and only then refuse. So even the refusal deletes the 'not-a-date' row the
    # checks above and below this block depend on — and the failure lands on THEM, tens of
    # lines away, reading as a bug in `compare`.
    #
    # The restore is asserted rather than assumed, and against the row COUNT taken before
    # anything ran, the same way the `closed` probe higher in this function does it.
    dl_249 = Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load;"))
    _ = sql!(ctx.db, "CREATE TABLE dl_bak249 AS SELECT * FROM daily_load;")
    check!("`analyze` refuses too — it is a WRITE, and an unplaceable row cannot be scored", strjq!(ctx, ["analyze"], ".error.code") == "unreadable_activity_date")?
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 940; DELETE FROM activities WHERE id = 940;")
    # `converged: true` ALONE is the bug's own signature, not the recovery — an empty
    # database answers exactly that at exit 0, and this file says so a hundred lines below:
    # "`analyze` exiting 0 is NOT the assertion — it exited 0 throughout the bug, reporting
    # converged: true while changing nothing." Paired with two positive markers, both
    # measured: `form_tsb_known` is true here and false on a database analyze did nothing to,
    # and the rebuild really ran, which the poisoned daily_load row being gone proves.
    check!("...and analyze recovers once the row is gone", strjq!(ctx, ["analyze"], ".data.converged") == "true" and strjq!(ctx, ["analyze"], ".data.form_tsb_known") == "true")?
    check!("...having actually rebuilt the table, not just exited 0 over it", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load WHERE day = 'not-a-date';")) == "0" and str_to_i64(Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load;"))) > 0)?
    _ = sql!(ctx.db, "DELETE FROM daily_load; INSERT INTO daily_load SELECT * FROM dl_bak249; DROP TABLE dl_bak249;")
    check!("...with daily_load restored, so the probe leaves no state behind", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load;")) == dl_249)?
    # `progress` groups by workout NAME, so an unreadable row only enters through a name it
    # SHARES with the anchor date's session — which is exactly what a repeated workout is.
    # Two rows, one dated and one not, is the smallest fixture that reaches it; a lone NULL
    # row is invisible to this command and a check built on one would pass without ever
    # exercising the guard.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,distance) VALUES (942,'repeat probe','Ride','Ride','${ctx.d1}T07:00:00Z',3600,20000),(943,'repeat probe','Ride','Ride',NULL,3600,20000);")
    check!("`progress` refuses rather than sorting an empty date to the front of its trend", strjq!(ctx, ["progress", ctx.d1], ".error.code") == "unreadable_activity_date" and Str.contains(strjq!(ctx, ["progress", ctx.d1], ".error.message"), "943"))?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id IN (942,943);")
    # ...and the BARE form, which picks its own anchor and is a different guard on a
    # different query. Naming a date skips that subquery entirely, so the check above cannot
    # reach it — mutation-testing found the anchor guard SURVIVING while `progress <date>`
    # stayed green, which is precisely the "one check, two sites" shape #243 spent its last
    # rounds on. The anchor is `ORDER BY start_local DESC LIMIT 1` over scored activities and
    # NULLs sort LAST there, so the unreadable row becomes the anchor only when it is the
    # only scored one; the probe clears activity_metrics down to that and restores it.
    _ = sql!(ctx.db, "CREATE TABLE am_bak249 AS SELECT * FROM activity_metrics;")
    am_249 = Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM am_bak249;"))
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,distance) VALUES (946,'anchor probe','Ride','Ride',NULL,3600,20000);")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics; INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (946,40.0,111.0,3600,1);")
    check!("bare `progress` refuses when its own anchor is the unreadable row", strjq!(ctx, ["progress"], ".error.code") == "unreadable_activity_date" and Str.contains(strjq!(ctx, ["progress"], ".error.message"), "946"))?
    _ = sql!(ctx.db, "DELETE FROM activity_metrics; INSERT INTO activity_metrics SELECT * FROM am_bak249; DROP TABLE am_bak249; DELETE FROM activities WHERE id = 946;")
    check!("...with activity_metrics restored, so the probe leaves no state behind", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_metrics;")) == am_249)?
    # `reps` anchors on the most recent work-segmented session, and `ORDER BY start_local
    # DESC` puts NULLs LAST — so the unreadable row wins only when it is the SOLE one. That
    # is a real state (one analyzed ride on a fresh database) and it is the only way to
    # reach this guard, so the probe clears the table and restores it.
    _ = sql!(ctx.db, "CREATE TABLE seg_bak249 AS SELECT * FROM activity_segments; DELETE FROM activity_segments;")
    seg_249 = Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM seg_bak249;"))
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,distance) VALUES (944,'reps probe','Ride','Ride',NULL,3600,20000);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal) VALUES (944,1,'work',0,720,200.0,'power'),(944,2,'work',900,720,200.0,'power'),(944,3,'work',1800,720,200.0,'power');")
    check!("`reps` refuses rather than answering 0 of 0 over a database that holds one", strjq!(ctx, ["reps"], ".error.code") == "unreadable_activity_date" and Str.contains(strjq!(ctx, ["reps"], ".error.message"), "944"))?
    # ...and a poisoned COMPARABLE, which is a different site from the anchor and was the
    # whole of #270: `reps` refused an unreadable anchor date and absorbed an unreadable
    # comparable one, in the same screen. The comparables query has NO lower date bound
    # (only `a2.start_local <= self.start_local`), so a second work-segmented row with a
    # date that sorts under the anchor reaches it — no history needed, which is why this
    # turned out cheap after I had written it off as needing one.
    #
    # The assertion is that the message names the COMPARABLE and not the anchor. Reverting
    # the fix restores `.ok_or(0)`, which sorts that row to the epoch and answers at exit 0.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,distance) VALUES (949,'reps comparable','Ride','Ride','0000-0z-01T10:00:00Z',3600,20000);")
    _ = sql!(ctx.db, "INSERT INTO activity_segments (activity_id,ordinal,kind,start_s,dur_s,avg_signal,signal) VALUES (949,1,'work',0,720,200.0,'power'),(949,2,'work',900,720,200.0,'power'),(949,3,'work',1800,720,200.0,'power');")
    _ = sql!(ctx.db, "UPDATE activities SET start_local = '${ctx.d1}T07:00:00Z' WHERE id = 944;")
    check!("...and a poisoned COMPARABLE is refused too, naming it rather than the anchor", strjq!(ctx, ["reps"], ".error.code") == "unreadable_activity_date" and Str.contains(strjq!(ctx, ["reps"], ".error.message"), "949") and !(Str.contains(strjq!(ctx, ["reps"], ".error.message"), "944")))?
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id = 949; DELETE FROM activities WHERE id = 949; UPDATE activities SET start_local = NULL WHERE id = 944;")
    # `doctor`'s human screen keeps its SECTION SPACERS, which nothing pinned. The two
    # checks that read this screen are `Str.contains` on single lines, so when a global
    # empty-line filter — added so a conditional row could disappear when it had nothing to
    # say — removed all of them, the suite stayed green at 785 through a change that altered
    # every section boundary and detached the footer arrow.
    #
    # FIVE, not six, and a floor rather than an equality. Five are unconditional; the sixth
    # belongs to `hint`, which fires only when there are unrated strength sessions and does
    # not in this fixture. Pinning six went red here, which is the version of this check
    # that would have had to be "fixed" by someone who did not know why the number moved.
    # The regression this catches took the count to zero, so a floor discriminates it
    # completely while surviving a fixture that gains or loses the conditional block.
    check!("doctor's human screen keeps its section spacers", str_to_i64(Str.trim(sh!("HOME='${ctx.home}' '${ctx.bin}' doctor 2>/dev/null | grep -c '^$'"))) >= 5)?
    # ...and ONE named spacer by adjacency, which the floor cannot hold. A floor decays: if
    # this fixture ever gains an unrated strength session, `hint` fires, the count becomes 6,
    # and losing an unconditional spacer would then still clear 5. Asserting that a specific
    # section is preceded by a blank line is indifferent to the conditional block entirely.
    check!("...including the one before `scored by`, which a floor alone cannot hold", Str.trim(sh!("HOME='${ctx.home}' '${ctx.bin}' doctor 2>/dev/null | grep -B1 '^  scored by' | head -1 | wc -c | tr -d ' '")) == "1")?
    _ = sql!(ctx.db, "DELETE FROM activity_segments; INSERT INTO activity_segments SELECT * FROM seg_bak249; DROP TABLE seg_bak249; DELETE FROM activities WHERE id = 944;")
    check!("...with the segment table restored, so the probe leaves no state behind", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_segments;")) == seg_249)?
    # ...and the POISONED shape for `week`, alongside the NULL one asserted above. This used
    # to be the ONLY week probe, built by corrupting the Monday's last digit so the value
    # would land lexically inside the week window. That construction is calendar-dependent:
    # when Monday and Monday+7 share a nine-character prefix — 18 of the 72 Mondays from
    # 2026-08-24, first 2026-09-21 — every 10-character string inside the window is a
    # readable date, so there is nothing to plant and the check would have gone red four
    # weeks out, naming `week`, over a regression that did not exist. Kept as a SECOND probe
    # rather than deleted: a date-shaped corruption and a NULL take different routes into
    # the guard, and this one costs nothing now that the guard sweeps the whole table.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time,distance) VALUES (945,'poisoned week','Ride','Ride','2026-08-2xT09:00:00Z', 3600, 20000);")
    check!("`week` refuses a poisoned date too, on any calendar", strjq!(ctx, ["week"], ".error.code") == "unreadable_activity_date")?
    check!("...naming the row rather than listing it above the week with an empty day", Str.contains(strjq!(ctx, ["week"], ".error.message"), "945"))?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id = 945;")
    # the error code alone is not the assertion. A confident all-zero window is the
    # failure; the code is just how it surfaces. Paired with a POSITIVE marker, because
    # `.data.current.has_data == null` is also what a renamed field, a moved payload or any
    # other failure of `compare` returns — an absence on its own cannot tell those apart
    # from the thing it is here to catch. The pair does: the message must quote the day.
    check!("...publishing no all-zero window as if it had been measured", strjq!(ctx, ["compare", "month"], ".data.current.has_data") == "null")?
    check!("...and saying which day it choked on, so the absence above is not the whole claim", Str.contains(strjq!(ctx, ["compare", "month"], ".error.message"), "'not-a-date'"))?
    check!("...while `summary` refuses it too, which is where this guard already was", strjq!(ctx, ["summary"], ".error.code") == "unreadable_daily_load_day")?
    # ...and the remedy the message names actually clears it. rebuild_daily_load! only
    # reached its DELETE when at least one activity date parsed; with none it returned
    # Ok({}) and left the poisoned row in place, so `analyze` answered converged: true at
    # exit 0 and `season` answered the same error forever. Asserted as a LOOP: run the
    # remedy, then re-run the command that named it, and require the second answer to
    # differ. Checking only that `analyze` exits 0 is what let this ship — it exited 0
    # throughout.
    #
    # Its OWN database, and that is the whole point. rebuild_daily_load! reaches its
    # DELETE on the branch where at least one activity date parsed — and this fixture has
    # hundreds that do, so running `analyze` here clears the row through the branch that
    # was never broken. Written that way first and mutation-proved: reverting the fix left
    # the check green. The broken branch is the one with NO parseable date, which cannot
    # be constructed in a shared fixture without destroying it for every check after.
    an_home = Str.trim(sh!("mktemp -d"))
    an_db = "${an_home}/.stride/db.sqlite"
    _ = sh!("HOME='${an_home}' '${ctx.bin}' init >/dev/null 2>&1")
    # zones first: `analyze` refuses with missing_config BEFORE it reaches the rebuild, so
    # without these the remedy never runs and every check below would pass or fail for a
    # reason that has nothing to do with the branch under test. That refusal is itself the
    # second way the printed remedy can fail to work, and it is why this seeds a real
    # config rather than the bare `init` default.
    _ = sql!(an_db, "INSERT OR REPLACE INTO config (key,value) VALUES ('hr_z1_max','123'),('hr_z2_max','150'),('hr_z3_max','165'),('hr_z4_max','175');")
    _ = sql!(an_db, "INSERT OR REPLACE INTO daily_load (day,tss,ctl,atl,tsb) VALUES ('not-a-date', 30.0, 5.0, 5.0, 0.0);")
    check!("a poisoned daily_load with no readable activity date is refused", Str.contains(sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' season 2>/dev/null"), "unreadable_daily_load_day"))?
    an_out = sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' analyze 2>/dev/null")
    # `analyze` exiting 0 is NOT the assertion — it exited 0 throughout the bug, reporting
    # converged: true while changing nothing. The assertion is that the row is gone and
    # the command that named this remedy stops naming it.
    check!("...and `stride analyze`, the remedy it names, really does clear the row", Str.trim(sql!(an_db, "SELECT count(*) FROM daily_load WHERE day = 'not-a-date';")) == "0")?
    check!("...so re-running the command that sent you there no longer refuses", !(Str.contains(sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' season 2>/dev/null"), "unreadable_daily_load_day")))?
    # guards the two checks above against passing for the wrong reason: a row that
    # vanished because `analyze` errored out would satisfy both. This pins that it
    # SUCCEEDED, which is also the state the bug shipped in — exit 0, converged: true,
    # nothing changed. All four zone keys are needed to get here; seeding three left
    # `analyze` answering missing_config and the clear never ran.
    check!("...having actually run, not errored out before touching the table", Str.contains(an_out, "\"converged\":true"))?
    # ...and the OTHER shape of "nothing to walk" is not the same fact and must not get the
    # same answer. Rows exist and not one date parses: clearing the table is still right,
    # but reporting converged: true is not — the engine holds scored activities and would
    # then tell the athlete "no scored training days yet, run `stride sync` then `stride
    # analyze`" while `stats` reports their sessions in the same breath. Review measured
    # that loop after the fix above closed the first one; it is the same defect one layer
    # down, so `analyze` names the row.
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (801,'unreadable','Ride','Ride','0000-0z-01T10:00:00Z',3600);")
    _ = sql!(an_db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (801,40.0,111.0,3600,1);")
    an_bad = sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' analyze 2>/dev/null")
    check!("scored rows with no readable date make `analyze` refuse, not report converged", Str.contains(an_bad, "unreadable_activity_date"))?
    check!("...naming the row, and NOT claiming convergence over data it dropped", Str.contains(an_bad, "activity 801") and !(Str.contains(an_bad, "\"converged\":true")))?
    # ...and the PARTIAL case, which is the likely one: some dates read, one does not.
    # It refuses too — but only after writing what it could read, so a readable series is
    # not thrown away over one bad row. Both halves asserted, because either alone is
    # satisfiable the wrong way: refusing while wiping the table, or keeping the table and
    # saying nothing.
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (802,'readable','Ride','Ride','${ctx.d1}T07:00:00Z',3600);")
    _ = sql!(an_db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (802,40.0,111.0,3600,1);")
    an_part = sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' analyze 2>/dev/null")
    check!("one unreadable date among readable ones still refuses, naming it", Str.contains(an_part, "unreadable_activity_date") and Str.contains(an_part, "activity 801"))?
    check!("...while keeping the series it COULD read, rather than discarding it all", str_to_i64(Str.trim(sql!(an_db, "SELECT count(*) FROM daily_load;"))) > 0)?
    # ...and a NON-CANONICAL date counts as unreadable here, which is the one that matters
    # most in this file because this is the writer. `date_str_to_days` alone accepts
    # "2026-3-05T" and the fold would then write 2026-03-05 back through days_to_date_str
    # — a perfectly canonical row invented from a malformed one, which every downstream
    # guard then trusts. Report.canonical_day cannot catch it: by the time the value
    # reaches daily_load it has already been laundered.
    _ = sql!(an_db, "DELETE FROM activity_metrics WHERE activity_id = 801; DELETE FROM activities WHERE id = 801;")
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (803,'non-canonical','Ride','Ride','2026-3-05T10:00:00Z',3600);")
    _ = sql!(an_db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (803,40.0,111.0,3600,1);")
    an_lndr = sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' analyze 2>/dev/null")
    check!("a non-canonical activity date is refused by the WRITER, not laundered into a real-looking day", Str.contains(an_lndr, "unreadable_activity_date") and Str.contains(an_lndr, "activity 803"))?
    check!("...so no invented day reaches daily_load", Str.trim(sql!(an_db, "SELECT count(*) FROM daily_load WHERE day = '2026-03-05';")) == "0")?
    # 803 goes now that it has done its job. Left in place it outlives its own check and
    # decides, by byte order, which row the sweep below names — review measured the checks
    # below naming 803 instead of 811 in a 2027 fixture. The block was written to be
    # construction-safe and a leftover row put the calendar back into it.
    _ = sql!(an_db, "DELETE FROM activity_metrics WHERE activity_id = 803; DELETE FROM activities WHERE id = 803;")
    # ...and `summary`'s hard-session statistics refuse it too — the fifth site of this
    # class and the last one in Report.roc. It read activity dates with `keep_oks`, which
    # dropped an unparseable date silently AND accepted a non-canonical one, so the fold
    # both under-counted and mis-dated. Review measured one poisoned hard session:
    # hard_days.d14 fell 1 -> 0 and days_since_last rose 3 -> 172 with
    # days_since_known still TRUE — a fabricated number carrying a flag that certifies it,
    # and 172 days versus 3 is "badly overdue for intensity" versus "recovering".
    # pi_hard_s, not pi_easy_s: the row has to qualify as HARD or the fold never sees it.
    # Constructed, not a literal — same reasoning as the daily_load block below, plus one
    # more constraint: this row has to land inside summary's 28-day window or the fold
    # never sees it, so the date must be BOTH non-canonical AND recent.
    #
    # A single-digit DAY, not month. An unpadded month is only non-canonical from January
    # to September, so a test built on it would quietly stop testing anything for the last
    # quarter of every year. Every month has a 1st through a 9th, so stepping back to the
    # 5th (or the 1st, when today is earlier than the 5th) is always single-digit and
    # always within 28 days.
    hard_off = "D=$(TZ='${ctx.tz}' date +%-d); if [ \"$D\" -ge 5 ]; then echo $((D-5)); else echo $((D-1)); fi"
    hard_bad = Str.trim(sh!("TZ='${ctx.tz}' date -v-$(${hard_off})d '+%Y-%m-%-d' 2>/dev/null || TZ='${ctx.tz}' date -d \"$(${hard_off}) days ago\" '+%Y-%m-%-d'"))
    hard_pad = Str.trim(sh!("TZ='${ctx.tz}' date -v-$(${hard_off})d +%F 2>/dev/null || TZ='${ctx.tz}' date -d \"$(${hard_off}) days ago\" +%F"))
    # non-canonical BY CONSTRUCTION means it differs from the padded spelling of the same
    # day — asserted rather than assumed, because if the shell ever pads it anyway the row
    # becomes a perfectly ordinary activity and the two checks below pass on nothing.
    check!("the constructed hard-session date is genuinely non-canonical (got ${hard_bad} vs ${hard_pad})", hard_bad != hard_pad and hard_bad != "")?
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (804,'hard non-canonical','Ride','Ride','${hard_bad}T10:00:00Z',3600);")
    _ = sql!(an_db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_hard_s,metrics_rev) VALUES (804,40.0,111.0,3600,1);")
    an_hard = sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' summary 2>/dev/null")
    check!("a non-canonical date on a HARD session refuses in summary rather than skewing its stats", Str.contains(an_hard, "unreadable_activity_date"))?
    check!("...naming that row, not just the date", Str.contains(an_hard, "activity 804"))?
    # ...and the two string MAXes that have no parse to guard. Both publish into fields the
    # schema calls dates and both were measured shipping malformed values at exit 0.
    # `last_hard_session_date` is ALL-TIME, so the 28-day fold above cannot see the row:
    # one malformed hard session older than the window, with none inside it, is an athlete
    # on a rest block. `sports_28d.last_date` needs no hard_expr at all, so any poisoned
    # activity sorting above the cutoff becomes its sport's "last seen".
    _ = sql!(an_db, "DELETE FROM activity_metrics WHERE activity_id = 804; DELETE FROM activities WHERE id = 804;")
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (810,'old hard','Ride','Ride','0000-0z-02T10:00:00Z',3600);")
    _ = sql!(an_db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_hard_s,metrics_rev) VALUES (810,40.0,111.0,3600,1);")
    an_old = sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' summary 2>/dev/null")
    check!("an unreadable hard session OUTSIDE the 28-day window is refused too, not published as last_hard_session_date", Str.contains(an_old, "unreadable_activity_date") and Str.contains(an_old, "activity 810"))?
    _ = sql!(an_db, "DELETE FROM activity_metrics WHERE activity_id = 810; DELETE FROM activities WHERE id = 810;")
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (811,'easy run','Run','Run','${hard_bad}T10:00:00Z',3600);")
    _ = sql!(an_db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (811,40.0,111.0,3600,1);")
    an_soft = sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' summary 2>/dev/null")
    check!("...and a NON-hard unreadable activity too, rather than becoming its sport's last_date", Str.contains(an_soft, "unreadable_activity_date") and Str.contains(an_soft, "activity 811"))?
    # ...and `rate latest` resolves by PARSED day, which is the seventh site of this class
    # and the only one that WRITES. `MAX(start_local)` is a byte comparison, so 811's
    # malformed date outranked every real one and the rating landed on it — reported back
    # as the id it rated, at exit 0, on a database where summary and season both refuse.
    # Ratings are the one table prune_deleted! will not touch, because they cannot be
    # re-derived, so this put unrecoverable human judgment on the wrong session. It also
    # collided with the remedy: deleting 811 by id would have destroyed a rating meant for
    # another activity, which would still have none.
    an_rate = sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' rate latest 8 2>/dev/null")
    check!("`rate latest` refuses an unreadable date rather than rating the wrong session", Str.contains(an_rate, "unreadable_activity_date"))?
    check!("...and writes nothing", Str.trim(sql!(an_db, "SELECT count(*) FROM ratings;")) == "0")?
    _ = sql!(an_db, "DELETE FROM activity_metrics WHERE activity_id = 811; DELETE FROM activities WHERE id = 811;")
    # ...and with every date readable it picks the newest, not the highest-sorting string.
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (700,'older','Ride','Ride','${ctx.d1}T10:00:00Z',3600),(701,'newest','Ride','Ride','${ctx.d2}T10:00:00Z',3600);")
    check!("...and on readable dates rates the newest activity", Str.contains(sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' rate latest 7 2>/dev/null"), "\"rated\":701"))?
    # ...and on a TWO-A-DAY it rates the later session, not the higher id. Ranking on the
    # parsed day instead of the full timestamp manufactures a tie that the old string max
    # never had, and then breaks it by id — which has no relationship to time of day. The
    # evening ride here deliberately carries the LOWER id, because ids track upload order
    # and a backfill, a manual entry or an import all break that correlation. Review
    # measured the morning session being rated; this is the check that would have caught it.
    _ = sql!(an_db, "DELETE FROM ratings; DELETE FROM activities WHERE id IN (700,701);")
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (800,'evening','Ride','Ride','${ctx.d1}T18:00:00Z',3600),(900,'morning','Ride','Ride','${ctx.d1}T08:00:00Z',3600);")
    check!("...and on a two-a-day rates the LATER session, not the higher id", Str.contains(sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' rate latest 6 2>/dev/null"), "\"rated\":800"))?
    # ...and a malformed TIME on a valid DATE is refused, not ranked. This is the seam
    # between the two halves of the fix: the guard read substr(1,10) while the ranker
    # compared the whole string, so an impossible hour passed on its date part and then
    # outranked a real session byte-wise — `T3` beats `T1`. Not a hypothetical row shape:
    # Metrics.export_date_to_iso is documented to have produced exactly T37 from
    # "25:00:00 PM" before its components were range-checked.
    _ = sql!(an_db, "DELETE FROM ratings;")
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (810,'impossible hour','Ride','Ride','${ctx.d1}T37:00:00Z',3600);")
    an_t37 = sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' rate latest 6 2>/dev/null")
    check!("an impossible HOUR on a valid date is refused, not ranked above a real session", Str.contains(an_t37, "unreadable_activity_date") and Str.contains(an_t37, "activity 810"))?
    # ...and the message names the half that FAILED. It used to hand back the date — a
    # perfectly readable '2026-08-24' — for a row whose fault is the hour, which is the
    # round-1 defect ("quotes a value the column does not hold") wearing new clothes:
    # quoting the half that is correct.
    check!("...naming the TIME, not the date half that is perfectly readable", Str.contains(an_t37, "T37:00:00") and !(Str.contains(an_t37, "('${ctx.d1}')")))?
    _ = sql!(an_db, "DELETE FROM activities WHERE id = 810;")
    # ...and the ranker compares exactly the slice the guard validates. Anything past
    # position 19 is unvalidated, so ranking on the whole string let a lowercase 'z' in
    # position 20 outrank an uppercase 'Z' on an identical timestamp — bounded (it cannot
    # misorder rows that differ) but it silently overrode the documented tie-break, which
    # says MAX(id) decides identical stamps. Ranking on substr(1,19) makes the two domains
    # the same expression rather than two lists that have to agree, which is the invariant
    # this branch re-derived four times and came up short on every time.
    _ = sql!(an_db, "DELETE FROM ratings;")
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (830,'lower z','Ride','Ride','${ctx.d1}T18:00:00z',3600),(930,'upper Z','Ride','Ride','${ctx.d1}T18:00:00Z',3600);")
    check!("a byte past position 19 cannot override the tie-break", Str.contains(sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' rate latest 5 2>/dev/null"), "\"rated\":930"))?
    _ = sql!(an_db, "DELETE FROM ratings; DELETE FROM activities WHERE id IN (830,930);")
    # ratings cleared just above, so this is "the refusal wrote nothing" rather than
    # "the table happens to be empty" — the distinction the whole block is about.
    check!("...and nothing was rated", Str.trim(sql!(an_db, "SELECT count(*) FROM ratings;")) == "0")?
    _ = sql!(an_db, "DELETE FROM activities WHERE id = 810;")
    # ...and a NULL start_local is NAMED rather than crashing the decoder. One commit of
    # this PR dropped the COALESCE and it regressed to `internal_error` — "please open an
    # issue" — which is the shape #243 exists to remove, on a write path.
    _ = sql!(an_db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (820,'null date','Ride','Ride',NULL,3600);")
    an_null = sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' rate latest 6 2>/dev/null")
    check!("a NULL start_local is named, not answered with internal_error", Str.contains(an_null, "unreadable_activity_date") and !(Str.contains(an_null, "internal_error")))?
    _ = sql!(an_db, "DELETE FROM activities WHERE id = 820;")
    _ = sql!(an_db, "DELETE FROM ratings; DELETE FROM activities WHERE id IN (800,900);")
    # ...and the year bound is still in the shared guard. `date_str_to_days` parses the year
    # with arg_i64 and `days_to_date_str` emits it unpadded, so "999-01-01" round-trips —
    # and sorts ABOVE every real date under ORDER BY day DESC, which is the exact hazard
    # every caller of that guard exists to prevent. A rewrite that kept the round trip and
    # dropped the bound let `summary` anchor on year 999 and report it as as_of at exit 0.
    _ = sql!(an_db, "INSERT OR REPLACE INTO daily_load (day,tss,ctl,atl,tsb) VALUES ('999-01-01', 30.0, 5.0, 5.0, 0.0);")
    check!("a year-999 day is refused, not accepted as canonical because it round-trips", Str.contains(sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' summary 2>/dev/null"), "unreadable_daily_load_day"))?
    # ...and the OTHER definition of the rule agrees, which is the thing that went wrong:
    # `week add` kept the bound while every stored-date guard lost it, in one binary.
    check!("...and `week add` refuses the same year, so one rule means one answer", Str.contains(sh!("HOME='${an_home}' STRIDE_FORMAT=json '${ctx.bin}' week add 999-01-01 endurance x y 2>/dev/null"), "bad_date"))?
    _ = sql!(an_db, "DELETE FROM daily_load WHERE day = '999-01-01';")
    _ = sql!(an_db, "DELETE FROM ratings; DELETE FROM activities WHERE id IN (700,701);")
    _ = sql!(an_db, "DELETE FROM activity_metrics WHERE activity_id = 804; DELETE FROM activities WHERE id = 804;")
    _ = sh!("rm -rf '${an_home}'")
    _ = sql!(ctx.db, "DELETE FROM daily_load WHERE day = 'not-a-date';")
    # ...and the SAME rule on the other date-parsing site. Absorbing this one
    # dropped the activity from sessions, polarization AND the threshold range
    # with no trace at exit 0 -- a silent wrong answer rather than a loud refusal.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (933,'bad date','Ride','Ride','garbage-date',3600);")
    _ = sql!(ctx.db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (933,40.0,300.0,3600,1);")
    bad_act = stride!(ctx.bin, ctx.home, ["season"])
    check!("a malformed activity date is refused, not absorbed", Str.contains(bad_act, "error") and !(Str.contains(bad_act, "blocks")))?
    check!("...naming the code, not internal_error", strjq!(ctx, ["season"], ".error.code") == "unreadable_activity_date")?
    # THE point of the issue: a date is not something a caller can act on. The id is.
    check!("...and naming the ROW, so a caller can repair or delete it", Str.contains(strjq!(ctx, ["season"], ".error.message"), "activity 933"))?
    # The quoted value, asserted — and asserted as a PREFIX claim. The query reads
    # `substr(start_local, 1, 10)`, so the message can only speak about the first ten
    # characters; it said "has start_local 'garbage-da'" and sent the user to a DELETE
    # matching zero rows. The daily_load arm quotes its column whole and has always been
    # asserted; this one was not, which is how the sentence stayed false.
    check!("...quoting the ten characters it actually read", Str.contains(strjq!(ctx, ["season"], ".error.message"), "start_local ('garbage-da')"))?
    # and the remedy leads with the one that always works. `sync --all` silently no-ops on
    # an imported row (synced_at NULL, so the upsert never sees it and prune exempts it),
    # so it is stated as conditional and second.
    check!("...leading with the remedy that does not depend on Strava still listing it", Str.contains(strjq!(ctx, ["season"], ".error.message"), "delete that row by id and re-sync"))?
    # ...and PARSEABLE is not enough. "2026-3-01" parses fine and sorts after
    # every 2026-1x date, so it became ftp_end for its month AND its block and
    # published the threshold running backwards -- at exit 0, which is the
    # exact failure this round exists to prevent, arriving through the guard.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (934,'unpadded','Ride','Ride','2026-3-01T06:00:00Z',3600);")
    _ = sql!(ctx.db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (934,40.0,111.0,3600,1);")
    unpadded = stride!(ctx.bin, ctx.home, ["season"])
    check!("a non-canonical activity date is refused too", Str.contains(unpadded, "error") and !(Str.contains(unpadded, "blocks")))?
    check!("...with the same code as the unparseable one", strjq!(ctx, ["season"], ".error.code") == "unreadable_activity_date")?
    # 934, not 933, and that is the assertion: both bad rows are in the table here, and
    # "2026-3-01T" sorts before "garbage-da" (ten-character prefixes — the query reads
    # substr(start_local, 1, 10), so those are the values compared), so the row named
    # must be the one the walk
    # actually met first. Naming a row that is merely bad, rather than the one that
    # stopped the run, sends the user to repair the wrong activity.
    check!("...naming the row the walk met FIRST, not merely a bad one", Str.contains(strjq!(ctx, ["season"], ".error.message"), "activity 934"))?
    # ...and when the refused date is shared, the LOWEST id. The query groups by (date,
    # family), so one bad date can hold several rows and `example_id` has to choose. MIN
    # rather than any is what makes the answer reproducible — a bug report that quotes a
    # different id on every run is not a bug report. Nothing pinned this until now: with
    # one row per group MIN, MAX and "whichever" are the same value, so the choice was
    # asserted only by the comment claiming it.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (932,'same bad day','Ride','Ride','2026-3-01T06:00:00Z',3600);")
    _ = sql!(ctx.db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (932,40.0,111.0,3600,1);")
    check!("...and the LOWEST id when one bad date groups several rows", Str.contains(strjq!(ctx, ["season"], ".error.message"), "activity 932"))?
    # ...and NOT the globally lowest id, which is the claim the first draft of this made
    # and had backwards. The grouping is (date, fam), so one bad date shared by a Run and
    # a Ride is TWO groups, and MIN picks inside whichever the walk reaches first — with
    # `fam` in the ORDER BY that is the alphabetically first family, and "Ride" < "Run".
    # So 931, a Run with a LOWER id on the same bad date, must NOT displace 932.
    #
    # The guarantee this pins is DETERMINISM, not global minimality: the same database
    # names the same row every time, which is what makes a bug report reproducible. Two
    # bad rows still take two repairs, and no single id can change that. Direct probe of
    # the query returned `2026-3-01T|Ride|932` then `2026-3-01T|Run|931`, in that order.
    # Dropping `fam` from the ORDER BY hands the choice back to SQLite; dropping it from
    # the GROUP BY makes the answer 931 and fails here.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (931,'same day other sport','Run','Run','2026-3-01T06:00:00Z',3600);")
    _ = sql!(ctx.db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (931,40.0,111.0,3600,1);")
    check!("...and a lower id in a later-sorting family does not displace it", Str.contains(strjq!(ctx, ["season"], ".error.message"), "activity 932"))?
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 931; DELETE FROM activities WHERE id = 931;")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 932; DELETE FROM activities WHERE id = 932;")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 934; DELETE FROM activities WHERE id = 934;")
    # CONSTRUCTED, not written as a literal. These checks only work because the bad day
    # outranks every fixture day under byte order, and the fixture's max daily_load day is
    # roughly TODAY — rebuild_daily_load! extends the series through today regardless of
    # activity dates. So a hardcoded '2026-3-05' stops outranking anything on 1 Jan 2027,
    # and review measured what that looks like: `summary` and `compare` SUCCEED at exit 0
    # and both checks go red. Failing by the command succeeding reads as the guard being
    # broken, and whoever hits it starts by debugging canonical_day.
    #
    # Next year with an unpadded month is always non-canonical and always above any day in
    # the current year. The two tempting shortcuts both fail: an unpadded month of TODAY
    # breaks every December ('2026-1-05' < '2026-12-24'), and an unpadded DAY only works on
    # the 1st through the 9th.
    late_day = "${Str.trim(sh!("TZ=${ctx.tz} date -v+1y +%Y 2>/dev/null || TZ=${ctx.tz} date -d '1 year' +%Y"))}-1-05"
    # asserted, not assumed: both properties this fixture depends on. The comparison runs
    # in SQL because Str has no ordering in Roc — and byte order is the property under
    # test anyway, so doing it in SQLite is the honest place for it.
    check!("the constructed day is non-canonical and really does sort above every fixture day", !(Str.contains(late_day, "-01-")) and Str.trim(sql!(ctx.db, "SELECT CASE WHEN '${late_day}' > COALESCE((SELECT MAX(day) FROM daily_load),'') THEN 'yes' ELSE 'no' END;")) == "yes")?
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day,tss,ctl,atl,tsb) VALUES ('${late_day}', 30.0, 5.0, 5.0, 0.0);")
    unpadded_day = stride!(ctx.bin, ctx.home, ["season"])
    check!("a non-canonical daily_load day is refused too", Str.contains(unpadded_day, "error") and !(Str.contains(unpadded_day, "span_weeks")))?
    check!("...with the daily_load code, not the activity one", strjq!(ctx, ["season"], ".error.code") == "unreadable_daily_load_day")?
    check!("...quoting the day it refused", Str.contains(strjq!(ctx, ["season"], ".error.message"), "'${late_day}'"))?
    # ...and so do the other two, which is what "close the class" has to mean. Both guarded
    # with `date_str_to_days` alone, and that ACCEPTS "2026-3-05" — while a non-canonical
    # day is the dangerous one, not the harmless one: `ORDER BY day DESC` is a string sort,
    # so "2026-3-05" beats every "2026-08-xx" and becomes the anchor. Measured before the
    # fix, on this exact value: `summary` reported as_of 2026-3-05 and `compare` published
    # an all-zero 28-day window, both at exit 0, while season refused. The previous commit
    # fixed compare's parse check and its comment claimed every command now refused. Half
    # the class was still open, inside the sentence declaring it closed.
    check!("...and so does `summary`, on the non-canonical day and not just the unparseable one", strjq!(ctx, ["summary"], ".error.code") == "unreadable_daily_load_day")?
    check!("...and `compare` too, rather than anchoring on a day that sorts last", strjq!(ctx, ["compare", "month"], ".error.code") == "unreadable_daily_load_day")?
    _ = sql!(ctx.db, "DELETE FROM daily_load WHERE day = '${late_day}';")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 933; DELETE FROM activities WHERE id = 933;")
    # A CONTROLLED block, because the fixture's own data does not discriminate:
    # asserting "end_date is not in the future" and "ftp_family is non-empty"
    # both passed with the end date reverted to the week end and the family
    # picked by highest threshold instead of most sessions.
    # 2010-01-04 is a Monday; the last training day is Thursday the 7th, so a
    # block ending on its calendar week would report the 10th.
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day, tss, ctl, atl, tsb) VALUES ('2010-01-04', 50.0, 5.0, 5.0, 0.0), ('2010-01-07', 50.0, 5.0, 5.0, 0.0);")
    # two Rides and one Rowing in that week; Rowing carries the HIGHER threshold,
    # so picking by threshold rather than by session count names the wrong sport
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (911,'probe ride a','Ride','Ride','2010-01-04T06:00:00Z',3600),(912,'probe ride b','Ride','Ride','2010-01-07T06:00:00Z',3600),(913,'probe row','Rowing','Rowing','2010-01-07T09:00:00Z',3600);")
    _ = sql!(ctx.db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,pi_moderate_s,pi_hard_s,z1_s,z2_s,z3_s,z4_s,z5_s,metrics_rev) VALUES (911,25.0,200.0,3000,400,200,0,0,0,0,0,1),(912,25.0,210.0,3000,400,200,0,0,0,0,0,1),(913,25.0,400.0,3000,400,200,0,0,0,0,0,1);")
    check!("a block ends on its last TRAINING day, not its last calendar week", Str.trim(strjq!(ctx, ["season"], "[.data.blocks[] | select(.start_date == \"2010-01-04\")] | .[0].end_date")) == "2010-01-07")?
    check!("the threshold names the family with the most sessions, not the highest number", Str.trim(strjq!(ctx, ["season"], "[.data.blocks[] | select(.start_date == \"2010-01-04\")] | .[0].ftp_family")) == "Ride")?
    check!("and reports that family's own range", Str.trim(strjq!(ctx, ["season"], "[.data.blocks[] | select(.start_date == \"2010-01-04\")] | .[0].ftp_hi")) == "210")?
    check!("the probe block counts activities, not days", Str.trim(strjq!(ctx, ["season"], "[.data.blocks[] | select(.start_date == \"2010-01-04\")] | .[0].sessions")) == "3")?
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id IN (911,912,913); DELETE FROM activities WHERE id IN (911,912,913); DELETE FROM daily_load WHERE day IN ('2010-01-04','2010-01-07');")
    # The month FTP had no coverage at all, which is why it shipped as a min/max
    # aliased to chronological names: every month was non-decreasing BY
    # CONSTRUCTION, so a falling threshold rendered as a rise. The probe forces
    # a fall, which is impossible to produce from a min/max.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (931,'ftp high','Ride','Ride','2010-03-02T06:00:00Z',3600),(932,'ftp low','Ride','Ride','2010-03-20T06:00:00Z',3600);")
    _ = sql!(ctx.db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (931,40.0,300.0,3600,1),(932,40.0,250.0,3600,1);")
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day,tss,ctl,atl,tsb) VALUES ('2010-03-02',40.0,5.0,5.0,0.0),('2010-03-20',40.0,5.0,5.0,0.0);")
    check!("a month whose threshold FELL reports start > end", strjq!(ctx, ["season"], "[.data.months[] | select(.month == \"2010-03\")] | .[0] | (.ftp_start == 300 and .ftp_end == 250)") == "true")?
    # ...and the unordered range still reports the same two numbers the other way
    check!("...while lo/hi stay unordered", strjq!(ctx, ["season"], "[.data.months[] | select(.month == \"2010-03\")] | .[0] | (.ftp_lo == 250 and .ftp_hi == 300)") == "true")?
    # blocks were already correct; pin them so the two paths cannot diverge again
    check!("the block covering it agrees", strjq!(ctx, ["season"], "[.data.blocks[] | select(.start_date <= \"2010-03-02\" and .end_date >= \"2010-03-20\")] | .[0] | (.ftp_start == 300 and .ftp_end == 250)") == "true")?
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id IN (931,932); DELETE FROM activities WHERE id IN (931,932); DELETE FROM daily_load WHERE day IN ('2010-03-02','2010-03-20');")
    check!("a known FTP range names its sport family", strjq!(ctx, ["season"], "[.data.blocks[] | select(.ftp_known and (.ftp_family | length == 0))] | length == 0") == "true")?
    # the boundary rule, end to end: insert a training day two clear weeks after
    # the last one and the block COUNT must rise by exactly one — asserted as an
    # equality against before+1, so "two new blocks" fails here too
    season_before = Str.trim(strjq!(ctx, ["season"], ".data.blocks | length"))
    last_day = Str.trim(strjq!(ctx, ["season"], ".data.blocks | last | .end_date"))
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day, tss, ctl, atl, tsb) VALUES (date('${last_day}', '+21 days'), 55.0, 10.0, 10.0, 0.0);")
    # `== before + 1`, not `!= before`: strjq! swallows stderr, so a crashed binary
    # yields "" — which satisfies any inequality and made this pass on a dead engine.
    check!("a gap of two clear weeks opens a new block", Str.trim(strjq!(ctx, ["season"], ".data.blocks | length == (${season_before} + 1)")) == "true")?
    # ...and a day only ONE week later joins the block instead of opening one
    _ = sql!(ctx.db, "DELETE FROM daily_load WHERE day = date('${last_day}', '+21 days');")
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day, tss, ctl, atl, tsb) VALUES (date('${last_day}', '+7 days'), 55.0, 10.0, 10.0, 0.0);")
    check!("a single week off does NOT open a block", Str.trim(strjq!(ctx, ["season"], ".data.blocks | length")) == season_before)?
    _ = sql!(ctx.db, "DELETE FROM daily_load WHERE day = date('${last_day}', '+7 days');")
    # A zero-load day is ABSENCE, not a light week -- daily_load carries rest
    # days so CTL can decay, and counting them as training would erase every
    # gap. Asserting "the count did not change" after inserting a lone zero day
    # proves nothing: it does not change under either rule. The discriminating
    # shape puts the zero week INSIDE what is otherwise a two-week gap --
    # absence keeps the split, training bridges it into one block.
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day, tss, ctl, atl, tsb) VALUES (date('${last_day}', '+7 days'), 0.0, 10.0, 10.0, 0.0);")
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day, tss, ctl, atl, tsb) VALUES (date('${last_day}', '+21 days'), 55.0, 10.0, 10.0, 0.0);")
    check!("a zero-load week does not bridge a gap", Str.trim(strjq!(ctx, ["season"], ".data.blocks | length == (${season_before} + 1)")) == "true")?
    _ = sql!(ctx.db, "DELETE FROM daily_load WHERE day IN (date('${last_day}', '+7 days'), date('${last_day}', '+21 days'));")
    check!("season is back to its original block count", Str.trim(strjq!(ctx, ["season"], ".data.blocks | length")) == season_before)?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id IN (${sch_done}, ${sch_open});")
    # ...and the validator is not a rubber stamp: each mutation MUST be caught,
    # or "conforms" above would mean nothing (a validator that passes everything
    # passes everything).
    mutate! = |filter| Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' summary | jq '.data | ${filter}' | jq -r --slurpfile schema schemas/v2/summary.json -f tools/validate.jq 2>&1"))
    check!("validator catches a MISSING required key", Str.contains(mutate!("del(.as_of)"), "missing required key"))?
    check!("validator catches a WRONG type", Str.contains(mutate!(".form_tsb = \"x\""), "expected number"))?
    check!("validator catches an UNDECLARED key (payload drift)", Str.contains(mutate!(".surprise = 1"), "absent from the schema"))?
    check!("validator catches a bad ENUM value", Str.contains(mutate!(".form_state = \"vibing\""), "not in enum"))?
    # the validator reads a documented SUBSET, and anything outside it is
    # silently ignored — so this is a WHITELIST over schema positions, not a
    # denylist of keywords. The case that matters: `additionalProperties: false`
    # is what a JSON-Schema-literate contributor writes instead of the house
    # `additionalKeys: false`; it looks right and would turn drift detection off.
    check!("schemas stay inside the validator's subset", Str.trim(sh!("for f in schemas/v2/*.json; do jq -r -f tools/schema-lint.jq \"$f\" 2>&1; done")) == "")?
    check!("...and the linter catches the dangerous look-alike", Str.contains(sh!("echo '{\"type\":\"object\",\"additionalProperties\":false}' | jq -r -f tools/schema-lint.jq 2>&1"), "additionalProperties"))?

    # keep later fixture-sensitive checks honest: remove the interval ride again
    _ = sql!(ctx.db, "DELETE FROM activity_segments WHERE activity_id=103; DELETE FROM activity_metrics WHERE activity_id=103; DELETE FROM streams WHERE activity_id=103; DELETE FROM activities WHERE id=103;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("form_delta_known is false on a short history", strjq!(ctx, ["summary"], ".data.form_delta_known") == "false")?
    # #123: the verdict NAMES the state and stops prescribing. Asserting the absence of the
    # old advice AND the presence of the label, so it cannot pass by the line disappearing.
    check!("form_band_days is a number", strjq!(ctx, ["summary"], ".data.form_band_days | type") == "number")?
    # The TYPE check alone is stub-safe: a hard-coded `form_band_days: 0` satisfies it, and
    # band_days_phrase suppresses 0, so the feature could be fully disconnected from
    # days_in_band with the suite green. The fixture's daily_load runs consecutive days
    # ending today, so a real streak is >= 1 — pin that it is WIRED, and that the capped
    # flag is a genuine boolean rather than another stringified tag.
    check!("...and is wired to a real streak, not a stub", str_to_i64(strjq!(ctx, ["summary"], ".data.form_band_days")) >= 1)?
    check!("...with a boolean capped flag beside it", strjq!(ctx, ["summary"], ".data.form_band_days_capped | type") == "boolean")?
    summary_verdict = stride_human!(ctx.bin, ctx.home, ["summary"])
    # "→ form " — the ARROW is what makes this the verdict line. Plain "form " also matches
    # the header row above it ("fitness (CTL): ... form (TSB): ..."), so the earlier version
    # of this check passed even with the entire verdict deleted, which is exactly what its
    # comment claimed it prevented.
    check!("the verdict still names the state", Str.contains(summary_verdict, "→ form "))?
    check!("...and no longer prescribes training", !(Str.contains(summary_verdict, "favor easy work")) and !(Str.contains(summary_verdict, "good day for")))?
    check_near!("...and the delta itself is an honest 0", sfloat(strjq!(ctx, ["summary"], ".data.form_delta_7d")), 0.0, 0.001)?
    # reuses summary_verdict above rather than running `summary` a second time — one
    # invocation, several assertions about the same output
    check!("...and omits the week-ago clause when the trend is unknown", !(Str.contains(summary_verdict, "week ago")))?
    # power ride NP 200 @ derived FTP 190 => TSS ~110.8; HR row ~55 => ~166
    check_near!("28d tss ~166 (111 power + 55 hr)", sfloat(strjq!(ctx, ["summary"], ".data.last_28d.tss")), 165.8, 1.0)?
    mp = sfloat(strjq!(ctx, ["summary"], ".data.last_28d.measured_pct"))
    check!("measured_pct ~67 (60..70)", mp >= 60.0 and mp <= 70.0)?
    # FTP is derived now (the config-FTP `stale` flag was removed in #26)
    check_near!("derived FTP ~190 (best-20min 200 x 0.95)", sfloat(strjq!(ctx, ["summary"], ".data.ftp.estimated_ftp_w")), 190.0, 1.0)?
    check!("fitness_ctl > 0", sfloat(strjq!(ctx, ["summary"], ".data.fitness_ctl")) > 0.0)?
    check!("fatigue_atl > 0", sfloat(strjq!(ctx, ["summary"], ".data.fatigue_atl")) > 0.0)?
    Ok({})
}

# ── ADR 0007: analyze narrates progress on STDERR, and stdout stays byte-identical.
# Both streams are captured SEPARATELY here — each run redirects stderr and stdout to
# its OWN file (`2>'…err' >'…out'`) — because the point of the ADR is that the two
# never mix, and asserting that needs them held apart rather than interleaved.
b_narration! : Ctx => Try({}, _)
b_narration! = |ctx| {
    # Each capture gets its OWN forced invalidation, and each mode is run ONCE with both
    # streams saved to files. The first draft re-ran analyze per assertion, which quietly
    # broke them: the first run rescored everything, so every later run had nothing
    # pending and narrated nothing — making "machine mode emits no carriage returns" pass
    # for the wrong reason. One run, one capture, several assertions.
    ej = "${ctx.home}/narr-json.err"
    eh = "${ctx.home}/narr-human.err"
    oj = "${ctx.home}/narr-json.out"
    _ = sql!(ctx.db, "UPDATE activity_metrics SET metrics_rev = 0;")
    _ = sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' analyze 2>'${ej}' >'${oj}'")
    narr_j = sh!("cat '${ej}'")
    check!("analyze narrates rescoring progress on stderr", Str.contains(narr_j, "rescoring"))?
    check!("analyze narrates the daily_load rebuild", Str.contains(narr_j, "rebuilding daily load"))?
    # a carriage return is garbage in a CI log, so machine mode must never emit one
    check!("machine-mode narration has no carriage returns", !(Str.contains(narr_j, "\r")))?
    # ...while human mode DOES redraw in place, and draws the bar with the table glyph
    _ = sql!(ctx.db, "UPDATE activity_metrics SET metrics_rev = 0;")
    _ = sh!("HOME='${ctx.home}' STRIDE_FORMAT=human '${ctx.bin}' analyze 2>'${eh}' >/dev/null")
    narr_h = sh!("cat '${eh}'")
    check!("human narration draws the bar", Str.contains(narr_h, "█") or Str.contains(narr_h, "░"))?
    check!("human narration redraws in place", Str.contains(narr_h, "\r"))?
    # the contract that matters: narration NEVER reaches stdout, so machine consumers and
    # golden fixtures are untouched. stdout must still be exactly the envelope — asserted
    # on the SAME run whose stderr carried the narration above.
    out_only = Str.trim(sh!("cat '${oj}'"))
    # "nothing else" has to mean it: starts_with + "no rescoring" would still accept any
    # amount of text appended AFTER the envelope. Pin both ends and the line count, so a
    # stray line anywhere in stdout fails rather than sneaking past on a substring miss.
    check!(
        "stdout carries the envelope and nothing else",
        Str.starts_with(out_only, "{\"schema_version\"")
        and Str.ends_with(out_only, "}")
        and List.len(Str.split_on(out_only, "\n")) == 1
        and !(Str.contains(out_only, "rescoring"))
        and !(Str.contains(out_only, "rebuilding")),
    )?
    Ok({})
}

# ── zone + metrics_rev auto-invalidation. Config-FTP invalidation was removed in #26
# (FTP is derived, not set); the derived-FTP recompute path is covered by
# b_seed_analyze!'s "computes 3" convergence. ─────────────────────────────────────────
b_invalidation! : Ctx => Try({}, _)
b_invalidation! = |ctx| {
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "hr_z2_max", "140"])
    check!("zone change recomputes all", strjq!(ctx, ["analyze"], ".data.computed") == "2")?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "hr_z2_max", "153"])
    check!("restoring zone recomputes again", strjq!(ctx, ["analyze"], ".data.computed") == "2")?
    _ = sql!(ctx.db, "UPDATE activity_metrics SET metrics_rev = 0;")
    check!("metrics_rev change recomputes all", strjq!(ctx, ["analyze"], ".data.computed") == "2")?
    rev = Str.trim(sql!(ctx.db, "SELECT DISTINCT metrics_rev FROM activity_metrics;"))
    check!("recomputed rows carry one nonzero rev", rev != "" and rev != "0" and !(Str.contains(rev, "\n")))?
    Ok({})
}

# ── plan lifecycle: revise-in-place, skip, re-plan, done ─────────────
## The `schema` field's VALUE, checked by running each form (#219). Its own scenario, and
## registered LATE, because it has to run where the fixture has data: sitting inside
## b_init_config! it validated only the seven commands that succeed on an empty database,
## and neither `pz` nor `stats` was among them — so pointing either at the wrong existing
## schema passed.
b_command_schemas! : Ctx => Try({}, _)
b_command_schemas! = |ctx| {
    # Not merely that the file exists. Both existing checks
    # pass with `pz` pointed at activities.json: the file is there, and zones.json is still
    # claimed by `zones`. So of the six fields, schema was the one that was purely asserted
    # — and a wrong-but-existing filename looks exactly like a right one.
    #
    # Driven from the TABLE rather than a hardcoded list, so the value is verified by the
    # same act that validates the payload. Only argument-free forms that actually succeed
    # are validated: a form that errors returns an error envelope, which conforms to no
    # success schema and would report a failure that is not about `schema` at all.
    #
    # READ-ONLY and OFFLINE, both stated. Filtering on `mutates` alone happens to exclude
    # the networked forms today only because `auth` and `sync` both write — a future
    # read-only networked command would be swept straight back into the offline driver.
    # READ-ONLY forms only. The first version of this loop selected on schema and arity
    # alone, which swept in `init` and `sync` — one writes to the fixture and the other
    # would reach for the network from the OFFLINE driver. A check written to close a gap
    # about the table was quietly writing to the database the rest of the suite reads.
    schema_mismatch = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.commands[] | select(.schema != \"\") | select(.mutates == false) | select(.network == false) | select([.args[] | select(.required)] | length == 0) | \"\\(.name)\\t\\(.schema)\"' | while IFS=$'\\t' read -r n sc; do out=$(HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' $n 2>/dev/null); echo \"$out\" | jq -e '.data' >/dev/null 2>&1 || continue; bad=$(echo \"$out\" | jq '.data' | jq -r --slurpfile schema schemas/v2/$sc -f tools/validate.jq 2>&1 | head -1); [ -z \"$bad\" ] || echo \"$n->$sc\"; done | tr '\\n' ' '"))
    check!("every form's payload conforms to the schema the TABLE names for it (bad: ${schema_mismatch})", schema_mismatch == "")?
    # ...and that loop validated a real number of forms rather than skipping them all.
    # Selected minus validated, NAMED. The guard was `validated != "0"`, which cannot see
    # the difference between 15 selected and 13 validated — the `|| continue` drops any
    # form whose call errors, so its schema goes unverified and swapping two skipped forms'
    # schemas passed. `reps` is the one legitimate skip: it has no detected intervals on
    # this fixture, so there is no payload to validate, and it is pinned by name rather
    # than absorbed into a count.
    schema_skipped = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.commands[] | select(.schema != \"\") | select(.mutates == false) | select(.network == false) | select([.args[] | select(.required)] | length == 0) | .name' | while read -r n; do HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' $n 2>/dev/null | jq -e '.data' >/dev/null 2>&1 || printf '%s ' \"$n\"; done"))
    check!("...and the only form with no payload to validate is the one with no intervals (got: ${schema_skipped})", schema_skipped == "reps")?

    # ── args arity, both bounds (#219) ──────────────────────────────────
    # The only dimension of the six with no derivation check until now, and the one with
    # the demonstrated defect history. Both probes run against a THROWAWAY COPY, because a
    # form filled to its declared arity may write — `week add` does.
    #
    # Networked forms are excluded: filling `sync`'s arguments would reach Strava from the
    # OFFLINE driver. Their arity is unchecked here, stated rather than quietly skipped.
    #
    # UPPER bound: filling every declared argument must not be a usage error. Without it
    # the table could advertise an argument the parser refuses — giving `activities` a
    # third `<since>` tells an agent to pass three, and `stride activities 1 Ride X`
    # answers usage.
    arity_probe = "${ctx.home}/.arity-probe"
    _ = sh!("rm -rf '${arity_probe}' && mkdir -p '${arity_probe}' && cp -R '${ctx.home}/.stride' '${arity_probe}/.stride'")
    # A LITERAL argument is passed verbatim — `sync --all` and `week all` are tokens the
    # user types, not slots to fill, and substituting "1" for them makes a usage error out
    # of a correct invocation.
    fill = "| .name | if test(\"^<\") then (if test(\"YYYY-MM-DD\") then \"${ctx.d1}\" elif test(\"hr[|]tss\") then \"tss\" elif test(\"week[|]month\") then \"week\" elif test(\"1-10\") then \"5\" elif test(\"asc[|]desc\") then \"asc\" elif test(\"zip[|]dir\") then \"/nonexistent/1\" else \"1\" end) else . end"
    over = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.commands[] | select(.network == false) | [.name] + [.args[] ${fill}] | join(\" \")' | { while read -r line; do code=$(HOME='${arity_probe}' STRIDE_FORMAT=json '${ctx.bin}' $line 2>/dev/null | jq -r '.error.code // \"ok\"'); [ \"$code\" = \"usage\" ] && echo \"$line\"; done; true; } | tr '\\n' '|'"))
    check!("filling every argument the table declares is never a usage error (bad: ${over})", over == "")?
    # LOWER bound: one FEWER than the declared required count must BE a usage error.
    # Declaring an optional argument required is the mutation this catches — and it is
    # worse than it looks, because the schema loop selects on "no required args", so
    # marking one required drops a form out of validation entirely and `schema_skipped`
    # never mentions it, since that only reports forms selected and then errored.
    under = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.commands[] | select(.network == false) | select([.args[] | select(.required)] | length > 0) | [.name] + ([.args[] | select(.required) ${fill}] | .[0:-1]) | join(\" \")' | { while read -r line; do code=$(HOME='${arity_probe}' STRIDE_FORMAT=json '${ctx.bin}' $line 2>/dev/null | jq -r '.error.code // \"ok\"'); [ \"$code\" = \"usage\" ] || echo \"$line\"; done; true; } | tr '\\n' '|'"))
    check!("...and one short of the required count always is (bad: ${under})", under == "")?
    check!("...with forms on both sides of that, so neither swept nothing", Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '[.data.commands[] | select([.args[] | select(.required)] | length > 0)] | length'")) != "0")?
    # The two NETWORK forms, which both probes skip — pinned as a value rather than
    # probed, because reaching them means coupling this check to the mock and losing the
    # purely-offline property, for a two-form and near-static exposure. `sync --all` is
    # already verified as a parser path by the literal-argument check above, and `auth`
    # takes nothing; the only uncovered case is a PLACEHOLDER argument appearing on one of
    # them, which changes this string.
    netargs = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '[.data.commands[] | select(.network) | \"\\(.name)[\\([.args[].name] | join(\",\"))]\"] | sort | join(\"|\")'"))
    check!("the two networked forms declare exactly what they always have (got: ${netargs})", netargs == "auth[]|sync[--all]")?
    # ORDERING: required arguments must form a PREFIX. Both probes verify the required
    # COUNT and neither verifies its position,
    # so swapping a required and an optional argument preserves both counts and passes:
    # `top [opt(<metric>), req(<limit>), opt(<sport>)]` tells an agent the metric is
    # optional, and `stride top 10` answers bad_metric.
    #
    # This is not only a lie about the contract. schemas/v2/commands.json states
    # "optional ones last" as an invariant, and THREE probes rely on it — subform_cmds,
    # the arity fillers, and the lower-bound line all build command lines with
    # `select(.required)`, which silently drops any optional argument sitting between
    # required ones. Asserting it makes those three sound rather than lucky, which is the
    # same lesson as the justfile line that was safe only by being last.
    #
    # `!= (sort | reverse)` is exactly "required ones form a prefix", which is the sentence
    # schemas/v2/commands.json states. The first version asked whether the FIRST optional
    # precedes the FIRST required — which coincides with the invariant on every form the
    # table has today and diverges the moment a third argument appears. It missed
    # `[req, opt, req]`, and that shape is the only arg mutation so far whose consequence
    # is a silent WRONG WRITE rather than an error: declaring skip as
    # [req(<session_id>), opt(<reason>), req(<activity_id>)] tells an agent the reason is
    # optional, and `stride skip 1 12345` then records 12345 as the REASON, exits 0, and
    # never makes the substitute link. jq orders false < true, so this is codepoint- and
    # locale-independent.
    misordered = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '[.data.commands[] | select([.args[].required] | . != (sort | reverse)) | .name] | join(\"|\")'"))
    check!("required arguments form a prefix — no optional one precedes a required one (bad: ${misordered})", misordered == "")?
    check!("...and there were forms with required arguments to order", Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '[.data.commands[] | select([.args[] | select(.required)] | length > 0)] | length'")) != "0")?
    # The OTHER array. Twelve rounds of this PR derived every field of `commands` from the
    # parser, the schema directory, the database and the payloads — and `flags` sat beside
    # it in the same `.data`, described by the same schema, read by the same agent, still
    # exactly what `commands` was before any of it: a hand-written literal nothing checked.
    # Adding "--verbose" to it advertised a flag that answers unknown_command, and the
    # whole suite stayed green.
    #
    # A listed flag must be EITHER accepted bare, OR a literal argument of some form —
    # and literal arguments are already verified against the parser by the check above, so
    # this leans on that rather than re-deriving. `--all` is the second case: sync-only, so
    # bare `--all` is unknown_command, which is what the schema says. No exception list.
    flag_dir = "${ctx.home}/.flags"
    _ = sh!("rm -rf '${flag_dir}' && mkdir -p '${flag_dir}' && HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.commands[] | . as $c | .args[]? | select(.name|test(\"^<\")|not) | .name' | LC_ALL=C sort -u > '${flag_dir}/literals'")
    unaccounted_flags = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.flags[]' | while read -r fl; do code=$(HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' $fl 2>/dev/null | jq -r '.error.code // \"ok\"'); [ \"$code\" != \"unknown_command\" ] && continue; grep -qx -- \"$fl\" '${flag_dir}/literals' && continue; printf '%s ' \"$fl\"; done"))
    check!("every flag the table advertises is one the binary accepts (bad: ${unaccounted_flags})", unaccounted_flags == "")?
    check!("...and there were flags to check", Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' 2>/dev/null | jq -r '.data.flags | length'")) != "0")?
    _ = sh!("rm -rf '${flag_dir}'")
    _ = sh!("rm -rf '${arity_probe}'")
    Ok({})
}

## The closed agent loop (#220): observe state, write intent, reconcile against real
## training, observe again — with the reconciliation reflected.
##
## Every leg of this is already covered by a per-command check. What is NOT covered, and
## what this exists for, is that the legs COMPOSE: that completing a session moves
## adherence in the direction it should, that the history row and the open-session list
## agree afterwards, and that a count derived from a DIFFERENT query moves with them. A
## per-command test cannot see a break there, because each payload is individually
## correct while the pair contradicts.
##
## Every expectation is computed from a baseline read at the top rather than hardcoded,
## so the scenario asserts DELTAS. Hardcoding would make it a second, weaker copy of the
## per-command checks and would rot the first time an earlier scenario adds a session.
b_agent_loop! : Ctx => Try({}, _)
b_agent_loop! = |ctx| {
    pj! = |q| Str.trim(strjq!(ctx, ["plan"], q))
    # The loop needs an activity NOT already telling another session's story: a completion
    # is permanent, and the fixture's 101 is linked by an earlier scenario. Seeded here
    # rather than borrowed, so this scenario does not depend on which activities earlier
    # ones happened to leave free — that dependency is invisible until it breaks, and it
    # broke on the first run of this test. Dated d2, one day AFTER the session it will be
    # completed against, so `completed_on` can be told apart from `target_date`.
    # Id 9220 is clear of the fixture's range and is deleted at the end.
    #
    # Dated d2 while the session below targets d1 — DELIBERATELY different days. With both
    # on the same date, `completed_on` could not tell "the date of the activity it was
    # completed against" from "the session's own target date", and the assertion that it
    # comes from the activity would have passed against either. Found by asking what
    # mutation it would catch, which was none.
    # Read BEFORE the seed as well as after: the cleanup deletes the probe activity, so
    # the state to return to is the one from before it existed, not the baseline the
    # deltas are measured against. Getting that wrong is a check that fails on its own
    # tidying rather than on anything the loop did.
    pre_unplanned = str_to_i64(Str.trim(strjq!(ctx, ["plan"], ".data.adherence_28d.unplanned_activities")))
    # ...and the same for planned, read before the BYSTANDER below exists. `base_planned`
    # is read after it, so it cannot answer "did this scenario put the plan back": the
    # bystander is a row this scenario created and must therefore remove. The end-state
    # check compares against this.
    pre_planned = str_to_i64(Str.trim(strjq!(ctx, ["plan"], ".data.adherence_28d.planned")))
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time,distance,weighted_avg_watts,avg_watts,avg_hr) VALUES (9220,'agent loop ride','Ride','${ctx.d2}T07:00:00Z',3600,25000,190,190,145);")
    # A BYSTANDER open session, created before the baselines so every delta below is
    # unaffected by it. It exists for one assertion, after the completion: that the list
    # still holds it.
    #
    # Without it the loop's own session is the ONLY open one when it completes, and the
    # check that it disappeared is `index(sid) == null` — which is also what an EMPTY list
    # returns. Review proved the gap rather than argued it: filtering every row out of
    # `open_p` once a session is done left the whole suite green at 685 == 685. An agent
    # reading `plan` would see no open sessions and conclude the week was finished.
    #
    # Note this failure shape is specific to negative membership. The plan_history checks
    # compare against non-empty expected values, so an emptied history fails on its own.
    # `index(...) == null` is the one that degenerates, and it degenerates silently.
    # Its OWN day, five back, and that is not cosmetic. `week add` revises rather than
    # inserts when the date already has an OPEN session — `plan_add_checked!` looks up
    # `WHERE target_date = :date AND status = 'open'` and takes the existing id — so the
    # bystander cannot share d1 with the session under test, and cannot share d2 either,
    # where an earlier scenario leaves one open. Both wrong versions were written before
    # this one: the first returned `sid_other == sid == 7`, which made "leaves the OTHER
    # session alone" mean "leaves itself alone" — a check that passes by construction and
    # asserts nothing. It only surfaced because `planned` then did not rise and the delta
    # check caught it three lines on. Changing the TYPE did not help, because the lookup
    # keys on the date alone.
    #
    # Computed here rather than borrowed from an earlier scenario's leftovers, for the
    # reason the probe activity above is seeded rather than borrowed: that dependency is
    # invisible until it breaks.
    d5 = Str.trim(sh!("TZ=${ctx.tz} date -v-5d +%F 2>/dev/null || TZ=${ctx.tz} date -d '5 days ago' +%F"))
    sid_other = Str.trim(strjq!(ctx, ["week", "add", "${d5}", "endurance", "agent loop bystander", "not the session under test"], ".data.id"))
    check!("the bystander session exists, so the removal check below has something to survive it", sid_other != "" and sid_other != "null")?
    # ── leg 0: observe ──────────────────────────────────────────────────
    # Baselines read AFTER the seed, so the deltas below are the loop's own and not the
    # seed's — unplanned_activities in particular counts this new row.
    base_planned = str_to_i64(pj!(".data.adherence_28d.planned"))
    base_completed = str_to_i64(pj!(".data.adherence_28d.completed"))
    base_open = str_to_i64(pj!(".data.adherence_28d.still_open"))
    base_unplanned = str_to_i64(pj!(".data.adherence_28d.unplanned_activities"))
    base_open_len = str_to_i64(pj!(".data.open_sessions | length"))
    base_skipped_plain = str_to_i64(pj!(".data.adherence_28d.skipped")) - str_to_i64(pj!(".data.adherence_28d.substituted"))
    base_hist_len = str_to_i64(pj!(".data.plan_history_28d | length"))
    # The invariant SKILL.md states to the coach, asserted before anything moves so a
    # later failure is attributable to this scenario rather than inherited.
    check!("the adherence identity holds at the start", base_planned == base_completed + str_to_i64(pj!(".data.adherence_28d.skipped")) + base_open)?

    # ── leg 1: write intent ─────────────────────────────────────────────
    # Dated d1: inside the 28-day adherence window, and a DIFFERENT day from the probe
    # activity above, which is what lets `completed_on` prove it comes from the activity
    # rather than from the session's own target.
    sid = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d1}", "endurance", "agent loop probe", "closing the loop"], ".data.id"))
    check!("the loop's session was created", sid != "" and sid != "null")?
    check!("...and appears in open_sessions", pj!("[.data.open_sessions[].id] | index(${sid}) != null") == "true")?
    check!("...and in plan_history_28d, as open", pj!("[.data.plan_history_28d[] | select(.id == ${sid}) | .status]") == "[\n  \"open\"\n]")?
    check!("...raising planned by exactly one", str_to_i64(pj!(".data.adherence_28d.planned")) == base_planned + 1)?
    check!("...and still_open by exactly one", str_to_i64(pj!(".data.adherence_28d.still_open")) == base_open + 1)?
    check!("...while completed did not move — planning is not completing", str_to_i64(pj!(".data.adherence_28d.completed")) == base_completed)?
    check!("...and both lists grew by one", str_to_i64(pj!(".data.open_sessions | length")) == base_open_len + 1 and str_to_i64(pj!(".data.plan_history_28d | length")) == base_hist_len + 1)?
    # The identity asserted here, where `still_open` is at its highest — measured at
    # planned=4, completed=0, skipped=2, still_open=2. Not all four terms: `completed` is
    # necessarily 0 in leg 1, and there is no point in this scenario where all four are
    # non-zero at once. This assertion is correct and cheap; it is NOT load-bearing —
    # review could construct no mutation for which it is the unique catcher, because every
    # delta check fires first.
    #
    # This comment used to say "the ONLY moment still_open is non-zero", and that the two
    # sibling assertions of the identity reduced to `planned == skipped` because still_open
    # was 0 at both. The bystander session added above made all three false in one stroke —
    # still_open is now 1 / 2 / 1 at baseline, here, and at the end — and it took review
    # measuring the three points to notice, because every check stayed green. A comment
    # describing which assertions are weak is only worth having if it is re-derived when
    # the fixture moves underneath it.
    check!("...and the adherence identity holds with still_open actually non-zero", str_to_i64(pj!(".data.adherence_28d.still_open")) > 0 and str_to_i64(pj!(".data.adherence_28d.planned")) == str_to_i64(pj!(".data.adherence_28d.completed")) + str_to_i64(pj!(".data.adherence_28d.skipped")) + str_to_i64(pj!(".data.adherence_28d.still_open")))?

    # ── leg 2: reconcile against real training ──────────────────────────
    # Asserted, not fired and forgotten: if the link is REFUSED — the activity already told another
    # session's story, say — every delta below would compare against an unchanged payload
    # and the failures would point at the assertions rather than at the cause.
    done_out = stride!(ctx.bin, ctx.home, ["complete", sid, "9220"])
    check!("the session completes against a real activity (got ${Str.trim(done_out)})", Str.contains(done_out, "\"activity\":9220") and Str.contains(done_out, "\"completed_session\":${sid}"))?
    # The assertions a per-command test cannot make, because each of these
    # payload fields is computed by a DIFFERENT query and only their agreement is the
    # contract.
    check!("completing removes the session from open_sessions", pj!("[.data.open_sessions[].id] | index(${sid})") == "null")?
    # ...and removes ONLY it. The line above cannot tell "sid was removed" from "the list
    # is empty" — `index()` returns null for both — and the loop's session would be the
    # only open one without the bystander seeded above.
    check!("...and leaves the OTHER open session alone, so an emptied list is not mistaken for a removal", pj!("[.data.open_sessions[].id] | index(${sid_other}) != null") == "true")?
    # ...and the two really are distinct rows. Without this the check above degrades to
    # "the session is still there" the moment anything makes `week add` return an existing
    # id, which is exactly what it did on the first attempt.
    check!("...which is a DIFFERENT session from the one just completed", sid_other != sid)?
    # `done`, not `completed` — the status enum is open|done|skipped. Pinned against the
    # schema's own vocabulary, which is what a coach branches on.
    check!("...but keeps it in plan_history_28d, now done", pj!("[.data.plan_history_28d[] | select(.id == ${sid}) | .status]") == "[\n  \"done\"\n]")?
    check!("...linked to the activity it was completed against", pj!("[.data.plan_history_28d[] | select(.id == ${sid}) | .completed_activity_id]") == "[\n  9220\n]")?
    check!("...and dated by that activity, not by the session's target", pj!("[.data.plan_history_28d[] | select(.id == ${sid}) | .completed_on]") == "[\n  \"${ctx.d2}\"\n]")?
    check!("...which is a different day from the target, so that check can tell them apart", pj!("[.data.plan_history_28d[] | select(.id == ${sid}) | .target_date]") == "[\n  \"${ctx.d1}\"\n]")?
    # ...and its own CONTENTS, which nothing read. `open_sessions` got its session_type and
    # detail pinned when this scenario was written; `plan_history_28d` did not, and review
    # proved the gap rather than argued it: returning `bogus_hist_type` / `WRONG HIST DETAIL`
    # for every history row was fully green at 692 == 692 with nothing neutralised (#251).
    # These are the two fields an agent branches on to describe what was actually done.
    check!("...carrying the type and detail it was created with, which nothing read before", pj!("[.data.plan_history_28d[] | select(.id == ${sid}) | .session_type]") == "[\n  \"endurance\"\n]" and pj!("[.data.plan_history_28d[] | select(.id == ${sid}) | .detail]") == "[\n  \"agent loop probe\"\n]")?
    # `d1` is today-3 and `d2` today-1 by construction, so they can never coincide — the
    # guard that used to ride along here could not fail and read like it could. What makes
    # the check above discriminating is that completed_on is d2 while target_date is d1.
    check!("...moving completed up by one", str_to_i64(pj!(".data.adherence_28d.completed")) == base_completed + 1)?
    check!("...and still_open back down to where it started", str_to_i64(pj!(".data.adherence_28d.still_open")) == base_open)?
    check!("...while planned stays put — a completion is not a new plan", str_to_i64(pj!(".data.adherence_28d.planned")) == base_planned + 1)?
    # The strongest coherence assertion here: unplanned_activities comes from an entirely
    # separate query over `activities`, counting those NOT linked to any session. Linking
    # 9220 has to move it, and nothing in a per-command test relates the two.
    check!("...and the activity stops counting as unplanned, a fact from another query", str_to_i64(pj!(".data.adherence_28d.unplanned_activities")) == base_unplanned - 1)?
    # ...and the OTHER link. `Plan.roc`'s unplanned query excludes activities
    # referenced by EITHER link, and only the completion half was tested — deleting the
    # substitute clause from the query passed the entire suite, this scenario included.
    # A substitution is `skip <id> "<reason>" <activity>`: the session did not happen, the
    # activity did, and it stops being unplanned just the same.
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time,distance,weighted_avg_watts,avg_watts,avg_hr) VALUES (9221,'agent loop substitute','Ride','${ctx.d2}T08:00:00Z',3600,20000,180,180,140);")
    sub_unplanned = str_to_i64(pj!(".data.adherence_28d.unplanned_activities"))
    sid2 = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d1}", "endurance", "agent loop substitute probe", "closing the other half"], ".data.id"))
    # Asserted, for the same reason the completion above is: `skip` has five refusal paths,
    # and every one of them leaves `unplanned` unchanged — so the next check would fail
    # pointing at the assertion rather than at the cause, which is what the comment twenty
    # lines above forbids. Fired and forgotten is house style elsewhere in this file; the
    # block that sets the stricter standard should not be the one breaking it.
    sub_out = stride!(ctx.bin, ctx.home, ["skip", sid2, "did something else instead", "9221"])
    check!("...the substitution is accepted, not refused (got ${Str.trim(sub_out)})", Str.contains(sub_out, "\"substitute_activity\":9221") and Str.contains(sub_out, "\"skipped_session\":${sid2}"))?
    # ...and a SKIPPED session is not in the actionable list either. The removal check
    # above bounds `open_sessions` from BELOW — it cannot be emptied — and this bounds it
    # from above. Review found the gap between them: changing open_p's predicate from
    # `= 'open'` to `<> 'done'` is a one-token slip that puts every skipped session back
    # into the list an agent branches on. `base_open_len` is measured with the slip already
    # active so it absorbs the phantom rows, leg 1's +1 still holds, and `still_open` comes
    # from a different query — so nothing in this scenario noticed. The agent re-plans
    # against sessions it already skipped.
    #
    # Negative membership is safe here only because the bystander guarantees the list is
    # non-empty; without it, `index(...) == null` would pass on an emptied list too, which
    # is the defect the bystander exists for. The two checks hold each other up.
    check!("...and the skipped session is NOT in the actionable list", pj!("[.data.open_sessions[].id] | index(${sid2})") == "null")?
    # ...and the rows carry their own CONTENTS, not just the right ids. Membership is now
    # bounded both ways — the list cannot be emptied and cannot gain skipped sessions —
    # and a list with the right ids and garbage fields is still indistinguishable from a
    # correct one. Across the whole suite `open_sessions` was only ever read as `[].id` or
    # `| length`, and the schema pins types without patterns, so review replaced every
    # row's target_date with '1999-01-01', session_type with 'bogus_type' and detail with
    # 'WRONG DETAIL' and got 690 == 690, exit 0. `target_date` and `session_type` are
    # exactly what an agent branches on to decide what to do today.
    check!("...and the open row carries its own fields, not just its id", pj!("[.data.open_sessions[] | select(.id == ${sid_other}) | .target_date]") == "[\n  \"${d5}\"\n]")?
    check!("...including the type and detail it was created with", pj!("[.data.open_sessions[] | select(.id == ${sid_other}) | .session_type]") == "[\n  \"endurance\"\n]" and pj!("[.data.open_sessions[] | select(.id == ${sid_other}) | .detail]") == "[\n  \"agent loop bystander\"\n]")?
    check!("...and a SUBSTITUTED activity stops counting as unplanned too", str_to_i64(pj!(".data.adherence_28d.unplanned_activities")) == sub_unplanned - 1)?
    # Named for what it asserts. It was "counted as skipped, not completed" and contains no
    # `completed` term — and review aimed four mutations at the completed half, all of
    # which pre-existing checks caught first, so the name promised coverage that lives
    # elsewhere. What this actually pins is that the PLAIN-skip count did not move: the
    # new skip is a substitution, so `skipped` and `substituted` must rise together.
    check!("...and the plain-skip count is unmoved, so the new skip is a substitution", str_to_i64(pj!(".data.adherence_28d.skipped")) == str_to_i64(pj!(".data.adherence_28d.substituted")) + base_skipped_plain)?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id = ${sid2}; DELETE FROM activity_metrics WHERE activity_id = 9221; DELETE FROM activities WHERE id = 9221;")
    check!("...with the identity still holding after all of it", str_to_i64(pj!(".data.adherence_28d.planned")) == str_to_i64(pj!(".data.adherence_28d.completed")) + str_to_i64(pj!(".data.adherence_28d.skipped")) + str_to_i64(pj!(".data.adherence_28d.still_open")))?
    # completion_pct is derived from two of the counts above; asserted against them rather
    # than against a literal, so it cannot drift from its own inputs.
    check!("...and completion_pct agrees with the counts it is derived from", str_to_i64(pj!(".data.adherence_28d.completion_pct")) == ((str_to_i64(pj!(".data.adherence_28d.completed"))).to_f64() / (str_to_i64(pj!(".data.adherence_28d.planned"))).to_f64() * 100.0).round_to_i64_try().ok_or(-1))?

    # ── leg 3: the machine-mode error invariant ─────────────────────────
    # `run_command!` is the single boundary converting platform failures into envelopes,
    # and its comment calls an uncoded failure "a missing arm in this match rather than a
    # habit nobody enforced". Nothing enforced it. In machine mode no handled failure may
    # exit non-zero with empty stdout — that shape is what an agent cannot recover from,
    # because there is nothing to branch on.
    # The EXPECTED CODE, not merely that a code exists. Asserting only the shape cannot
    # tell "reached the failure this probe names" from "fell off the command table": review
    # ran these six through a shell that does not word-split, so each arrived as one
    # argument, and ALL SIX came back `unknown_command` with a non-zero exit and a
    # non-empty code — satisfying the old assertion while five of the six never reached the
    # path their label named. The harness splices `${args}` unquoted, so any future
    # argument containing a space reroutes a probe the same way and it stays green.
    err_probe! = |args, want, label| {
        out = "${ctx.home}/.err-probe.out"
        st = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' ${args} > '${out}' 2>/dev/null; echo $?"))
        code = Str.trim(sh!("jq -r '.error.code // \"\"' '${out}' 2>/dev/null"))
        check!("${label}: exits non-zero with `${want}` on stdout (exit ${st}, code '${code}')", st != "0" and code == want)
    }
    # OBSERVED -> DECLARED (#239). Every code a probe actually gets back must be one the
    # command table says that form can return — universal, or declared on the form itself.
    #
    # This is the direction the two schema-level checks cannot reach. Those prove the
    # declaration agrees with the envelope CONTRACT; neither can tell whether a form's own
    # list is missing a code it really produces, because nothing in a static file knows
    # what a command does at runtime. Wiring it to the probes means the completeness
    # evidence grows with the suite instead of being asserted once — every error path a
    # future test drives has to be declared or this fails.
    #
    # It takes the VERB, because `config get nosuchkey` is the form `config get` while
    # `activity 99999999` is the form `activity`: the table keys on the form name, and a
    # two-word form has to match on two words.
    declared_probe! = |args, want, label| {
        err_probe!(args, want, label)?
        # The form is resolved AGAINST THE TABLE, by longest matching prefix of its own
        # names — not by an awk that hardcodes which verbs are two words.
        #
        # The awk version degraded silently, which is the defect this check exists to
        # catch. When the extracted name matched nothing, the jq below yielded [] and
        # `codes` fell back to the six universal codes, so the check became "is `want`
        # universal?" and passed. `week` made that live rather than hypothetical: it is a
        # ONE-word form that appears in the two-word list because `week add` exists, so
        # every `week` probe that is not literally `week add ...` resolved to nothing. And
        # the one probe in this set whose `want` is universal — `reps notadate` -> `usage`
        # — would have passed either way, so it proved nothing about attribution at all.
        form = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' --help | jq -r --arg a '${args}' '[.data.commands[].name | . as $n | select(($a + \" \") | startswith($n + \" \"))] | (sort_by(length) | last) // \"\"'"))
        check!("...the probed form `${form}` is one the command table declares", form != "")?
        codes = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' --help | jq -r --arg f '${form}' '((.data.universal_error_codes // []) + ([.data.commands[] | select(.name == $f) | .error_codes // []] | flatten)) | unique | join(\" \")'"))
        check!("...and `${want}` is declared for `${form}` (declared: ${codes})", Str.contains(" ${codes} ", " ${want} "))
    }
    declared_probe!("activity 99999999", "activity_not_found", "unknown activity")?
    declared_probe!("tte notanumber", "bad_watts", "unparseable watts")?
    declared_probe!("config get nosuchkey", "not_set", "absent config key")?
    declared_probe!("top notametric", "bad_metric", "unknown metric")?
    declared_probe!("reps notadate", "usage", "unparseable date")?
    err_probe!("frobnicate", "unknown_command", "unknown command")?
    # The code alone does not pin the MESSAGE, and for `reps` the value is the point:
    # the arm exists because `reps asc` once answered "no detected interval structure on
    # asc" — a data fact about a date that does not exist. Gutting the message to a bare
    # "reps" is NOT what this catches: three expects in Command.roc assert it contains
    # "not a date", and they abort `just test` before e2e runs. What this catches is a
    # message that still says "not a date" and drops the VALUE, which passes all three.
    # ONE assertion in two halves, not a check and a spare. `usage` is a single code fed
    # by 30 distinct Usage(...) raises in Command.roc, so `code == "usage"` alone proves
    # only that SOME malformed invocation was refused — the arity arm answers
    # "usage: stride reps — wrong arguments for this command", echoing nothing of what was
    # typed. The token is the only thing separating the date arm from the other 29. Delete
    # this and the probe above silently weakens to 1-of-30.
    check!("...and the date-refusal message names what it refused", Str.contains(stride!(ctx.bin, ctx.home, ["reps", "notadate"]), "notadate"))?
    _ = sh!("rm -f '${ctx.home}/.err-probe.out'")

    # ── the rows this scenario did NOT create ───────────────────────────
    #
    # Everything above pins facts about three known ids, which leaves the payload
    # unconstrained wherever the loop did not put something. Those are different shapes of
    # assertion — "facts about known ids" versus "facts about the whole list" — and the
    # second was missing entirely (#251).
    #
    # Measured during review of #242, not inferred: widening `open_p` to
    # `status='open' OR (status='skipped' AND substitute_activity_id IS NULL)` serves a
    # SKIPPED session as actionable, and the suite stayed green at 691 == 691 with only
    # b_plan!'s incidental guard removed. Membership pinned by naming ids cannot see a
    # phantom that is none of them. An agent reading `open_sessions` would plan against a
    # session the athlete had already skipped.
    #
    # CROSS-REFERENCED rather than enumerated, so it constrains rows nobody named.
    # `open_sessions` has no date filter while `plan_history_28d` is windowed on BOTH sides
    # (>= today-27 and <= today), so a bare subtraction would flag a legitimate open session
    # outside that window. No such row exists in this fixture — which is exactly the kind of
    # thing that must not be depended on silently, hence the explicit date restriction
    # below rather than a membership one.
    #
    # BEFORE the cleanup, and that is not cosmetic: run after it, the loop's own open rows
    # are gone, `open_sessions` is empty, and the overlap is trivially zero — the check
    # passes having compared nothing. It is the FIRST conjunct of the guard that catches
    # that; the shut-row side survives the cleanup untouched, because the rows it counts are
    # b_plan!'s tombstones rather than anything this scenario or the loop created. An
    # earlier version of this paragraph said "both lists empty" and named the loop's skipped
    # session, which is deleted a hundred lines earlier and not by the cleanup at all.
    # RESTRICTED BY DATE, not by membership, and the first version got that backwards.
    #
    # Restricting to ids present in BOTH arrays excludes exactly the class being hunted: a
    # phantom is by definition a row history does not call open, so "only judge rows history
    # mentions" lets through every phantom outside history's window. And history is bounded
    # ABOVE by `:today` as well as below — so a session dated later this week, which is the
    # primary use of `week add`, is invisible to it.
    #
    # Review proved it live. Widening `open_p` to
    # `status='open' OR target_date > as_of` — a plausible "show me what's upcoming" change
    # — left the full suite green with only b_plan!'s 8th-scenario guard neutralised, while
    # `open_sessions` served four phantoms: two skipped sessions and two already done. That
    # is verbatim the harm #251 names, past the check written to stop it.
    #
    # The sting is that the issue's own bare-subtraction sketch WOULD have caught it. The
    # intersection was adopted to dodge a false positive this fixture cannot produce (there
    # is no open session older than the window) and bought a false negative it populates.
    # The date window is sound both ways: it excuses genuinely out-of-window rows, and it
    # catches the documented phantom, the future-dated one, and an in-window open row that
    # history omits entirely.
    # AGAINST THE TABLE, not against the other array, and that took two wrong shapes to get
    # to. Cross-referencing `plan_history_28d` cannot work in either form: it is windowed on
    # both sides, so restricting to ids it mentions excludes every phantom outside the
    # window, and restricting `open_sessions` to the window excludes them too. Measured —
    # a widened `open_p` serving four phantoms dated 2099 passed BOTH shapes, because every
    # one of them is outside the window that either side could see.
    #
    # `planned_sessions` has no window and is the thing the payload is a claim about, so
    # the assertion is the invariant itself: nothing `open_sessions` offers may be anything
    # but open in the table. That constrains rows nobody named, which is #251's subject,
    # without inheriting a second query's date bounds.
    open_ids = Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' plan 2>/dev/null | jq -r '[.data.open_sessions[].id] | join(\",\")'"))
    # THREE conjuncts, and the third is not a spare. `id IN (…)` is silent about an offered
    # id that resolves to NO row: `COUNT(*) WHERE id IN (7,999999) AND status <> 'open'` is 0
    # because 999999 matches nothing. I argued that was closed by coincidence — every id
    # `open_sessions` carries is checked by name upstream — and review proved the reasoning
    # protects the wrong class. Named-id checks close TRANSFORMATION (shift every id and
    # `index(${sid})` stops finding it); they structurally cannot close ADDITION, which is
    # this issue's own thesis in one sentence: membership pinned by naming ids cannot see a
    # row that is none of them. A fabricated id is a phantom with no row behind it.
    #
    # Measured: `open_p` gaining a synthesised `UNION ALL SELECT 999999, …` row — a
    # plausible "suggested next session" feature on the array an agent reads to decide what
    # to do — passed the whole suite including this check, and produces an id the agent will
    # try to `complete` and cannot.
    #
    # The count equality also closes the direction the check had nothing to say about:
    # open rows being DROPPED. Both sides are read from live state in the same breath, so it
    # is not a delta and nothing rots when a fixture edit adds or removes a session — both
    # sides move together. Between them the conjuncts cover promotion, fabrication,
    # duplication and thinning.
    #
    # A third conjunct rather than a fourth check, deliberately: the tally stays 755, and
    # #263 and this PR already collide on `checks_ran_exactly!`.
    #
    # One residual left alone: dropping one open row AND adding one fabricated id keeps the
    # count equal. Closing it needs the explicit converse, and I cannot construct a mutation
    # that loses one and gains one — that is the term this repo deletes, where the
    # fabrication term is not.
    check!("nothing `open_sessions` offers is anything but open in planned_sessions, and it offers every one of them", open_ids != "" and Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM planned_sessions WHERE id IN (${open_ids}) AND COALESCE(status,'open') <> 'open';")) == "0" and str_to_i64(pj!(".data.open_sessions | length")) == str_to_i64(Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM planned_sessions WHERE COALESCE(status,'open') = 'open';"))))?
    # The guard measures the population the CHECK depends on, which is the table — and the
    # previous version measured `plan_history_28d`, left over from when the check read it
    # too. Those can no longer agree: history is windowed on both sides and the table is
    # not. Review proved the mismatch with a matched pair. Re-date b_plan!'s tombstones out
    # of the 28-day window and the check is undamaged while the guard fails, crying "no shut
    # row a phantom could occupy" over a table holding seven of them; apply the same drift
    # WITH the documented phantom and the check still goes red, because it sees all four
    # promoted rows through the table regardless of date. A false alarm in the first case
    # and an actively misleading one in the second.
    #
    # The overlap conjunct went with it. After the cleanup `open_sessions` is empty, so
    # `open_ids != ""` inside the check already goes red — it guarded nothing the check does
    # not guard itself.
    #
    # What genuinely disarms this check is a table with nothing to promote, and that is what
    # is asserted. Measured: 7 non-open rows at this point.
    check!("...over a non-empty offer, against a table holding non-open rows to promote", open_ids != "" and str_to_i64(Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM planned_sessions WHERE COALESCE(status,'open') <> 'open';"))) > 0)?

    # ── cleanup: the loop leaves no trace ───────────────────────────────
    # Deleted by id, and the deletion asserted — every counter this scenario moved has to
    # come back, or a later scenario inherits a session it never created.
    # The BYSTANDER goes too, and it is compared against `pre_planned` rather than
    # `base_planned` for the same reason `pre_unplanned` exists: the state to return to is
    # the one from before this scenario built anything, not the baseline the deltas are
    # measured against. `base_planned` is read AFTER the bystander, so comparing against it
    # let the bystander leak while the check reported the plan restored — measured, one row
    # and one open session inherited by every scenario after this one.
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id = ${sid}; DELETE FROM planned_sessions WHERE id = ${sid_other}; DELETE FROM activity_metrics WHERE activity_id = 9220; DELETE FROM activities WHERE id = 9220;")
    check!("the loop left the plan exactly as it found it", str_to_i64(pj!(".data.adherence_28d.planned")) == pre_planned and str_to_i64(pj!(".data.adherence_28d.completed")) == base_completed and str_to_i64(pj!(".data.adherence_28d.unplanned_activities")) == pre_unplanned)?
    check!("...leaving no open session behind either, bystander included", str_to_i64(pj!(".data.open_sessions | length")) == base_open_len - 1)?
    Ok({})
}

# `week` and `plan` read the same two tables and answer the same question about them, and
# they are DELIBERATELY allowed to disagree in exactly one place. Nothing tested that (#250).
#
# The assertion is not "they agree". It is: for every session in the shared window they
# classify identically, EXCEPT that an activity whose skip tombstone was superseded is
# `unplanned` to `week` and is not counted as unplanned by `plan`. Plan.roc states the
# divergence in a comment and gives the reason — for adherence, counting it would make one
# ride both substituted and unplanned — and until now a comment was the whole enforcement.
#
# Its OWN scenario rather than a leg of the agent loop, which is the choice #220's issue
# argued for: that loop's thesis is that ONE payload is self-consistent, and a cross-command
# red there would be ambiguous between "plan drifted", "week drifted", and "the sanctioned
# difference moved".
#
# Runs AFTER b_agent_loop! and before the database rebuilds, for the same reason it does:
# the comparison needs a populated adherence window, and an empty one would make every set
# equality below true.
b_week_plan! : Ctx => Try({}, _)
b_week_plan! = |ctx| {
    pj! = |q| Str.trim(strjq!(ctx, ["plan"], q))
    # ── half one: they agree everywhere else ────────────────────────────
    #
    # SEEDED, not borrowed, and that is the difference between this check and a green one
    # that proves nothing. Measured at this point in the run, `plan_history_28d` holds TWO
    # rows, both skipped with neither link set — so a comparison over the fixture as found
    # would never exercise a `done` row, a `completed_activity_id`, or a substitute link,
    # which is three quarters of what the two commands have to agree about. The floor was
    # written larger than this window turned out to be, which is how the two-row window
    # surfaced. (The exact habit number is development history and the commit message and
    # this comment disagreed about it, so it is not recorded.)
    #
    # One session per classification, each on its OWN day: `week add` revises rather than
    # inserts when the date already holds an open session, so two probes sharing a date
    # collapse into one row and the set silently shrinks. The agent-loop scenario above
    # records that trap after being caught by it.
    # The highest id BEFORE this scenario builds anything, so the check below can tell an
    # INSERT from a revision of a foreign row. `week add` revises when the date already
    # holds an open session, and the three probe dates are not this scenario's to reserve:
    # measured, wpa is today-3 which is b_agent_loop!'s ctx.d1, and wpc is today-5 which is
    # its bystander's day. Two of three dates are shared with the scenario that runs
    # immediately before. Comparing the three ids to EACH OTHER cannot see a revision — a
    # foreign id is still distinct from the other two — and the cleanup sweep at the end
    # would then DELETE another scenario's row.
    wp_max_before = str_to_i64(Str.trim(sql!(ctx.db, "SELECT COALESCE(MAX(id),0) FROM planned_sessions;")))
    wpa = Str.trim(sh!("TZ=${ctx.tz} date -v-3d +%F 2>/dev/null || TZ=${ctx.tz} date -d '3 days ago' +%F"))
    wpb = Str.trim(sh!("TZ=${ctx.tz} date -v-4d +%F 2>/dev/null || TZ=${ctx.tz} date -d '4 days ago' +%F"))
    wpc = Str.trim(sh!("TZ=${ctx.tz} date -v-5d +%F 2>/dev/null || TZ=${ctx.tz} date -d '5 days ago' +%F"))
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_watts,avg_hr) VALUES (9251,'wp done ride','Ride','${wpb}T07:00:00Z',3600,25000,190,145),(9252,'wp sub ride','Ride','${wpc}T07:00:00Z',3600,25000,190,145);")
    wp_open = Str.trim(strjq!(ctx, ["week", "add", "${wpa}", "endurance", "wp open", "stays open"], ".data.id"))
    wp_done = Str.trim(strjq!(ctx, ["week", "add", "${wpb}", "endurance", "wp done", "gets completed"], ".data.id"))
    _ = strjq!(ctx, ["complete", wp_done, "9251"], ".data.id")
    wp_skip = Str.trim(strjq!(ctx, ["week", "add", "${wpc}", "endurance", "wp skipped", "gets substituted"], ".data.id"))
    _ = strjq!(ctx, ["skip", wp_skip, "swapped", "9252"], ".data.id")
    check!("the three probe sessions are distinct rows, not one revised three times", wp_open != wp_done and wp_done != wp_skip and wp_open != wp_skip and wp_open != "" and wp_done != "" and wp_skip != "")?
    check!("...and all three are rows this scenario INSERTED, not foreign rows it revised", str_to_i64(wp_open) > wp_max_before and str_to_i64(wp_done) > wp_max_before and str_to_i64(wp_skip) > wp_max_before)?
    check!("...and they cover the two classifications with LINKS, which the fixture had none of", pj!("[.data.plan_history_28d[] | select(.id == ${wp_done}) | .status] | join(\",\")") == "done" and pj!("[.data.plan_history_28d[] | select(.id == ${wp_skip}) | .status] | join(\",\")") == "skipped")?
    # Compared as SETS through jq over both payloads at once, rather than field by field in
    # Roc. Two `strjq!` calls could not do it: `week all` covers the whole log while
    # `plan_history_28d` covers 28 days, so one side is a superset and the assertion is
    # "every plan row appears in week, unchanged" — a lookup per row, not a string equality.
    pf = Str.trim(sh!("mktemp"))
    wf = Str.trim(sh!("mktemp"))
    _ = sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' plan > '${pf}' 2>/dev/null")
    _ = sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' week all > '${wf}' 2>/dev/null")
    # `// 0` on both link fields, on both sides, because null and absent must compare equal
    # here. Measured, neither payload ever emits null — both queries COALESCE the links to
    # 0 — so this is a harmless no-op kept for the shape rather than a fix for an observed
    # mismatch. An earlier version of this sentence presented it as answering a measured
    # fact, which is the class of claim this branch keeps having to correct.
    mismatched = Str.trim(sh!("jq -rn --slurpfile p '${pf}' --slurpfile w '${wf}' '[$p[0].data.plan_history_28d[] | . as $s | (($w[0].data | map(select(.id == $s.id)) | first) // null) as $x | select($x == null or $x.status != $s.status or (($x.completed_activity_id // 0) != ($s.completed_activity_id // 0)) or (($x.substitute_activity_id // 0) != ($s.substitute_activity_id // 0))) | ($s.id | tostring)] | join(\",\")'"))
    compared = Str.trim(sh!("jq -rn --slurpfile p '${pf}' '$p[0].data.plan_history_28d | length'"))
    # NON-EMPTY first, and the order matters: an empty history makes the set equality below
    # vacuously true, which is the exact shape this file keeps catching elsewhere. The floor
    # is what this fixture actually holds at this point, not a round number.
    # BOTH payloads measured, not just the left one. `sh!` returns stdout and discards the
    # exit code, so if `wf` ends up without a `.data` array — empty file, crash, or an error
    # envelope — the jq expression fails at `null | map(...)`, prints nothing, and
    # `mismatched == ""` reads as PERFECT AGREEMENT. Review proved it: replacing the
    # `week all` capture with `: > wf` left the suite green at 763, both agreement checks
    # passing against an absent right-hand payload. `compared` reads only `pf`, so it
    # guarded the left side and left the side the check is actually about unmeasured.
    week_rows = Str.trim(sh!("jq -rn --slurpfile w '${wf}' '$w[0].data | length'"))
    _ = sh!("rm -f '${pf}' '${wf}'")
    check!("the two commands have a shared window to disagree about", str_to_i64(compared) >= 5)?
    check!("...and both payloads were actually read, not just the left one", str_to_i64(week_rows) >= str_to_i64(compared))?
    check!("week and plan classify every session in it identically", mismatched == "")?

    # ── half two: the one sanctioned disagreement, in exactly its direction ──
    #
    # Built rather than borrowed. A superseded tombstone needs two sessions on ONE date: the
    # first skipped WITH a substitute, the second alive. `week add` revises rather than
    # inserts when the date already holds an OPEN session, so the order is load-bearing —
    # the first must be skipped BEFORE the second is added, or the second silently becomes a
    # revision of the first and there is only ever one row.
    # Read BEFORE the probe exists, so the restore check at the end compares against the
    # state to return TO rather than against a mid-probe number. Getting that wrong gives a
    # cleanup assertion that is satisfied by the probe still being linked — it would read
    # `base_unplanned - 1` either way, and could not tell a restored window from a leaked
    # one. The agent-loop scenario above records the same trap, in the same words.
    pre_unplanned = str_to_i64(pj!(".data.adherence_28d.unplanned_activities"))
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_watts,avg_hr) VALUES (9250,'divergence probe','Ride','${ctx.today}T07:00:00Z',3600,25000,190,145);")
    base_unplanned = str_to_i64(pj!(".data.adherence_28d.unplanned_activities"))
    check!("the probe activity starts out unplanned to plan, so the divergence is a CHANGE", base_unplanned == pre_unplanned + 1)?
    dsid1 = Str.trim(strjq!(ctx, ["week", "add", "${ctx.today}", "endurance", "divergence probe session", "the one that will be skipped"], ".data.id"))
    _ = strjq!(ctx, ["skip", dsid1, "swapped for the probe ride", "9250"], ".data.id")
    dsid2 = Str.trim(strjq!(ctx, ["week", "add", "${ctx.today}", "endurance", "divergence successor", "supersedes the tombstone above"], ".data.id"))
    # `dsid1` gets the same INSERT-not-revision term the three agreement probes got, and it
    # needs it more than they do: it is added on ctx.today, a date that already holds two
    # rows, and it inserts only because both are SKIPPED. The moment an earlier scenario
    # leaves an OPEN session on today, `week add` revises it — `dsid1` becomes a foreign id,
    # `dsid1 != dsid2` still passes, and the cleanup sweep below deletes another scenario's
    # row. `dsid2` needs no term: `dsid1` is skipped by the time it is added, so it always
    # inserts.
    check!("the fixture really made two sessions on one date, not one revised twice", dsid1 != dsid2 and dsid1 != "" and dsid2 != "" and str_to_i64(dsid1) > wp_max_before)?
    # `week`, not `week all`: the unplanned merge is scoped to the current week by
    # construction (`WHERE :all = 0`), so `week all` never carries these rows at all.
    check!("`week` calls the superseded substitute unplanned", Str.trim(strjq!(ctx, ["week"], "[.data[] | select(.activity_id == 9250) | .status] | join(\",\")")) == "unplanned")?
    check!("...while `plan` does NOT count it, which is the sanctioned divergence", str_to_i64(pj!(".data.adherence_28d.unplanned_activities")) == base_unplanned - 1)?
    # BOTH directions of that one row. Without this, `plan` dropping the activity for any
    # unrelated reason would satisfy the check above — the count falling by one is also what
    # a lost row looks like. The link is what makes it a substitution rather than an absence.
    check!("...because it is still linked as the substitution it was", pj!("[.data.plan_history_28d[] | select(.substitute_activity_id == 9250) | .status] | join(\",\")") == "skipped")?
    # Everything this scenario created, in one sweep: the divergence pair AND the three
    # agreement probes. Split across two cleanups earlier, and the second one silently did
    # not run when the first check failed — leaving five sessions and three activities for
    # every scenario after this to inherit. One `?` short-circuits the rest of the function.
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id IN (${dsid1}, ${dsid2}, ${wp_open}, ${wp_done}, ${wp_skip}); DELETE FROM activity_metrics WHERE activity_id IN (9250,9251,9252); DELETE FROM activities WHERE id IN (9250,9251,9252);")
    check!("the divergence probe left the window as it found it", str_to_i64(pj!(".data.adherence_28d.unplanned_activities")) == pre_unplanned)?
    # Negative membership, so it needs the companion: `length == "0"` is also what an
    # EMPTIED history returns, which is the degeneracy the agent-loop scenario documents at
    # its bystander. History holds b_plan!'s two rows at this moment, so the companion is
    # free.
    check!("...and no probe session survived it", pj!("[.data.plan_history_28d[] | select(.id == ${wp_open} or .id == ${wp_done} or .id == ${wp_skip} or .id == ${dsid1} or .id == ${dsid2})] | length") == "0" and str_to_i64(pj!(".data.plan_history_28d | length")) > 0)?
    Ok({})
}

b_plan! : Ctx => Try({}, _)
b_plan! = |ctx| {
    # #100: a bad date is refused at the door. planned_sessions is judgment tier, so a
    # typo that lands there cannot be re-derived — and it would belong to no training
    # week, matching no completion or adherence query. Each of the rejects below PARSES;
    # the last two would be silently normalized to a different day than the one typed.
    # Apostrophes must round-trip byte-for-byte through the INSERT and back out. Written
    # when #105's workaround SPLICED dynamic text into SQL as an escaped literal; that
    # workaround was deleted when the bug was fixed in basic-cli 0.22.0 and Plan.roc binds
    # normally now (`:detail`, `:rationale`). The check is worth keeping either way -- it
    # is the regression test for ever reaching for a splice again. A broken round trip
    # either corrupts the text (assert catches it) or fails the INSERT loudly (also
    # caught -- the id check fails).
    # stride! (direct exec, no shell) rather than strjq! — the harness's sh-based jq
    # wrapper single-quotes its args, so an apostrophed arg breaks the TEST's own
    # quoting before stride ever sees it. The id is read back with sql!, whose command
    # text contains no user data.
    apo_detail = "coach's 3x12' @ FTP — don''t skip; O'Brien's rule"
    apo_out = stride!(ctx.bin, ctx.home, ["week", "add", "2099-03-01", "threshold", apo_detail, "it's the plan"])
    check!("a detail full of apostrophes inserts", Str.contains(apo_out, "\"target_date\":\"2099-03-01\""))?
    apo_id = Str.trim(sql!(ctx.db, "SELECT MAX(id) FROM planned_sessions WHERE target_date = '2099-03-01';"))
    stored = Str.trim(sql!(ctx.db, "SELECT detail FROM planned_sessions WHERE id = ${apo_id};"))
    check!("...and round-trips byte-for-byte", stored == apo_detail)?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id = ${apo_id};")

    check!("a non-date is refused", Str.contains(stride!(ctx.bin, ctx.home, ["week", "add", "tomorrow", "vo2max", "d", "r"]), "bad_date"))?
    check!("an unpadded date is refused", Str.contains(stride!(ctx.bin, ctx.home, ["week", "add", "2099-1-2", "vo2max", "d", "r"]), "bad_date"))?
    check!("an impossible day is refused", Str.contains(stride!(ctx.bin, ctx.home, ["week", "add", "2099-02-30", "vo2max", "d", "r"]), "bad_date"))?
    check!("a timestamp is refused", Str.contains(stride!(ctx.bin, ctx.home, ["week", "add", "2099-01-01T06:00:00Z", "vo2max", "d", "r"]), "bad_date"))?
    # refused means NOT WRITTEN — the guard runs before the db is opened, so the very
    # next add must still be id 1. Without that, this check would read id 5.
    check!("week add id 1", strjq!(ctx, ["week", "add", "2099-01-01", "vo2max", "d", "r"], ".data.id") == "1")?
    # re-planning an open date REVISES it in place (same id 1), not a refuse + tombstone
    check!("re-plan revises open in place", strjq!(ctx, ["week", "add", "2099-01-01", "threshold", "d", "r"], ".data.id") == "1")?
    check!("skip session", Str.contains(stride!(ctx.bin, ctx.home, ["skip", "1", "sick"]), "\"skipped_session\""))?
    check!("re-plan after skip id 2", strjq!(ctx, ["week", "add", "2099-01-01", "threshold", "d2", "r2"], ".data.id") == "2")?
    check!("complete session", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "2", "101"]), "\"completed_session\""))?
    check!("session 1 skipped with reason", strjq!(ctx, ["week", "all"], ".data[] | select(.id==1) | .skipped_reason") == "sick")?
    check!("session 1 status skipped", strjq!(ctx, ["week", "all"], ".data[] | select(.id==1) | .status") == "skipped")?
    check!("session 2 done", strjq!(ctx, ["week", "all"], ".data[] | select(.id==2) | .status") == "done")?
    check!("session 2 completed activity 101", strjq!(ctx, ["week", "all"], ".data[] | select(.id==2) | .completed_activity_id") == "101")?
    check!("complete nonexistent session", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "999", "101"]), "session_not_found"))?
    # complete_rest! is a SEPARATE parse from the two-argument form above
    check!("an exponent id is refused by the rest-day complete", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "2e0"]), "bad_id"))?
    # #201 on the OTHER judgment-tier writes. `2e0` is session 2 and `3e2` is activity
    # 300 under the widened stdlib -- both real rows here, so these fail on a revert
    # instead of trading one error for another. NOT `1.01e2`: a fractional mantissa does
    # not parse on either pin, so that form returned bad_id with or without the
    # narrowing and the check proved nothing.
    check!("an exponent session id is refused by complete", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "2e0", "101"]), "bad_id"))?

    check!("complete nonexistent activity", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "2", "88888"]), "activity_not_found"))?
    check!("skip nonexistent session", Str.contains(stride!(ctx.bin, ctx.home, ["skip", "999", "x"]), "session_not_found"))?
    # ── substitutions (#144): a skip can name the activity that replaced the plan ──
    # today-dated so the ThisWeek window sees both the session and the activity
    today_sess = Str.trim(strjq!(ctx, ["week", "add", "${ctx.today}", "threshold", "sub test", "r"], ".data.id"))
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_hr) VALUES (300,'unplanned spin','Ride','${ctx.today}T08:00:00Z',3600,20000,120);")
    # 3e2 addresses a REAL id (300). An earlier version used 1e1, which resolves to 10 --
    # absent from the fixture, so both the narrowed and the widened binary answered
    # activity_not_found and the check proved nothing.
    check!("an exponent activity id is refused", Str.contains(stride!(ctx.bin, ctx.home, ["--json", "activity", "3e2"]), "activity_not_found"))?
    # `complete!` validates the SESSION before the activity, so this needs a session that
    # EXISTS as well as activity 300. Placed earlier with session 3 absent, it returned
    # session_not_found and killed its mutant by accident, proving nothing about the
    # activity-id parse.
    ex_sess = Str.trim(sql!(ctx.db, "SELECT id FROM planned_sessions WHERE status='open' ORDER BY id LIMIT 1;"))
    check!("an exponent activity id is refused by complete", Str.contains(stride!(ctx.bin, ctx.home, ["complete", ex_sess, "3e2"]), "bad_id"))?
    check!("...while the id it would have meant does resolve", Str.contains(stride!(ctx.bin, ctx.home, ["--json", "activity", "300"]), "\"id\":300"))?
    # before any link: the activity surfaces as an UNPLANNED row in week
    check!("unlinked activity shows as unplanned", strjq!(ctx, ["week"], "[.data[] | select(.status == \"unplanned\" and .activity_id == 300)] | length") == "1")?
    # anti-stable-sort regression pin: today's SESSION row precedes today's
    # unplanned row — ties must order sessions first, never reversed
    check!("session precedes unplanned on the same day", strjq!(ctx, ["week"], "[.data[] | select(.target_date == \"${ctx.today}\") | .status] | index(\"unplanned\") > 0") == "true")?
    check!("skip with substitute refuses a bogus activity", Str.contains(stride!(ctx.bin, ctx.home, ["skip", today_sess, "x", "88888"]), "activity_not_found"))?
    # #201 on skip's SUBSTITUTE id: 3e2 is activity 300, which the next line links for
    # real, so this fails on a revert rather than trading one not-found for another.
    check!("skip refuses an exponent substitute id", Str.contains(stride!(ctx.bin, ctx.home, ["skip", today_sess, "x", "3e2"]), "bad_id"))?
    check!("skip with substitute links the activity", Str.contains(stride!(ctx.bin, ctx.home, ["skip", today_sess, "rode easy instead", "300"]), "\"substitute_activity\""))?
    check!("week carries the substitute id", strjq!(ctx, ["week"], "[.data[] | select(.substitute_activity_id == 300)] | length") == "1")?
    # once linked, the activity is no longer unplanned — one row, not two
    check!("linked substitute leaves no unplanned row", strjq!(ctx, ["week"], "[.data[] | select(.status == \"unplanned\" and .activity_id == 300)] | length") == "0")?
    # the HUMAN table renders the link as an arrow and unplanned ids as "-"
    human_week = stride_human!(ctx.bin, ctx.home, ["week"])
    check!("human week renders the substitute arrow", Str.contains(human_week, "→ 300"))?
    # one activity, one story: a LIVE claim (the visible skip on today) refuses a
    # second claim from another date, and the error names the blocking session
    extra_sess = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d1}", "endurance", "double claim probe", "r"], ".data.id"))
    dc_out = stride!(ctx.bin, ctx.home, ["skip", extra_sess, "x", "300"])
    check!("double-claiming a linked activity is refused", Str.contains(dc_out, "activity_already_linked"))?
    check!("...naming the blocking session", Str.contains(dc_out, "#${today_sess}"))?
    _ = stride!(ctx.bin, ctx.home, ["skip", extra_sess, "cleanup"])
    # re-planning the day must NOT hide the substitute: the superseded tombstone
    # keeps its reference invisible, so the activity RETURNS as an unplanned row
    # rather than vanishing from the week entirely
    replan = Str.trim(strjq!(ctx, ["week", "add", "${ctx.today}", "threshold", "re-planned", "r"], ".data.id"))
    check!("superseded substitute resurfaces as unplanned", strjq!(ctx, ["week"], "[.data[] | select(.status == \"unplanned\" and .activity_id == 300)] | length") == "1")?
    # ...and acting on the advertised-free activity SUCCEEDS: the claim steals the
    # display-dead tombstone link instead of refusing what week just offered
    check!("claiming a tombstone-held activity steals the link", Str.contains(stride!(ctx.bin, ctx.home, ["complete", replan, "300"]), "\"completed_session\""))?
    check!("the tombstone link was released", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM planned_sessions WHERE substitute_activity_id = 300;")) == "0")?
    # a bare re-skip PRESERVES a substitute link (judgment-tier survives wording fixes)
    resess = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d1}", "endurance", "reskip probe", "r"], ".data.id"))
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (303,'probe spin','Ride','${ctx.d1}T09:00:00Z',1800,9000);")
    _ = stride!(ctx.bin, ctx.home, ["skip", resess, "first wording", "303"])
    reskip_out = stride!(ctx.bin, ctx.home, ["skip", resess, "second wording"])
    check!("bare re-skip keeps the substitute link", Str.trim(sql!(ctx.db, "SELECT COALESCE(substitute_activity_id,0) FROM planned_sessions WHERE id = ${resess};")) == "303")?
    check!("...and says so in the output", Str.contains(reskip_out, "kept_substitute"))?
    # completing a substituted session clears the arrow — the completion IS the story
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (304,'real evidence','Ride','${ctx.d1}T18:00:00Z',1800,9000);")
    _ = stride!(ctx.bin, ctx.home, ["complete", resess, "304"])
    check!("completion clears the substitute link", Str.trim(sql!(ctx.db, "SELECT COALESCE(substitute_activity_id,0) FROM planned_sessions WHERE id = ${resess};")) == "0")?
    # the COMPLETION arm of the claim guard: an activity that already completed a
    # session refuses a second claim, naming the session and the permanence
    dc2sess = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d2}", "endurance", "completion claim probe", "r"], ".data.id"))
    dc2 = stride!(ctx.bin, ctx.home, ["skip", dc2sess, "try to reclaim", "304"])
    check!("a completing activity refuses a second claim", Str.contains(dc2, "activity_already_linked") and Str.contains(dc2, "completions are permanent"))?
    _ = stride!(ctx.bin, ctx.home, ["skip", dc2sess, "cleanup"])
    # `none` is the explicit release path the refusal message points at
    relsess = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d1}", "endurance", "release probe", "r"], ".data.id"))
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (305,'to be released','Ride','${ctx.d1}T06:00:00Z',1800,9000);")
    _ = stride!(ctx.bin, ctx.home, ["skip", relsess, "with sub", "305"])
    rel_out = stride!(ctx.bin, ctx.home, ["skip", relsess, "changed my mind", "none"])
    check!("skip none releases the link", Str.trim(sql!(ctx.db, "SELECT COALESCE(substitute_activity_id,0) FROM planned_sessions WHERE id = ${relsess};")) == "0")?
    check!("...and reports WHICH id it released, as a number", Str.contains(rel_out, "\"released_substitute\":305"))?
    # releasing when nothing is linked must not claim otherwise
    norel = stride!(ctx.bin, ctx.home, ["skip", relsess, "third wording", "none"])
    check!("none on an unlinked session claims nothing", !(Str.contains(norel, "released_substitute")))?
    # a steal is SURFACED, never silent: re-link 305, supersede, claim it elsewhere
    _ = stride!(ctx.bin, ctx.home, ["skip", relsess, "with sub again", "305"])
    relsup = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d1}", "endurance", "supersedes release probe", "r"], ".data.id"))
    steal_out = stride!(ctx.bin, ctx.home, ["skip", relsup, "did 305 instead", "305"])
    check!("a steal names the session it released", Str.contains(steal_out, "released_substitute_of"))?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id IN (${relsess}, ${relsup}, ${dc2sess}); DELETE FROM activities WHERE id = 305;")

    # a DONE session refuses skip (#148): the old flip left a skipped row
    # displaying a completion — falsified adherence, guarded at the mechanism now
    done_skip = stride!(ctx.bin, ctx.home, ["skip", resess, "trying to unskip history"])
    check!("skipping a done session is refused, naming the activity", Str.contains(done_skip, "session_done") and Str.contains(done_skip, "activity 304"))?
    check!("...and the row is untouched", Str.trim(sql!(ctx.db, "SELECT status || '|' || COALESCE(completed_activity_id,0) FROM planned_sessions WHERE id = ${resess};")) == "done|304")?
    check!("skip none on a done session is refused too", Str.contains(stride!(ctx.bin, ctx.home, ["skip", resess, "x", "none"]), "session_done"))?

    # a rest day completed bare clears any lingering substitute the same way
    restsess = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d1}", "rest", "rest probe", "r"], ".data.id"))
    _ = sql!(ctx.db, "UPDATE planned_sessions SET substitute_activity_id = 303 WHERE id = ${restsess};")
    _ = stride!(ctx.bin, ctx.home, ["complete", restsess])
    check!("bare rest completion clears the substitute link", Str.trim(sql!(ctx.db, "SELECT COALESCE(substitute_activity_id,0) FROM planned_sessions WHERE id = ${restsess};")) == "0")?
    # the NULL-link arm: a completed rest day refuses skip with its own wording —
    # this also pins the COALESCE that keeps a NULL from hard-failing the decoder
    check!("a completed rest day refuses skip in the NULL-link wording", Str.contains(stride!(ctx.bin, ctx.home, ["skip", restsess, "x"]), "completed rest day"))?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id IN (${today_sess}, ${extra_sess}, ${replan}, ${resess}, ${restsess}); DELETE FROM activities WHERE id IN (300, 303, 304);")

    # ── plan history + adherence (#158): planned-vs-actual from ONE call.
    # Self-contained probes on in-window dates (the 2099 lifecycle sessions
    # above sit outside the 28d window on purpose), cleaned up after.
    ph1 = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d1}", "endurance", "history probe skip", "r"], ".data.id"))
    ph2 = Str.trim(strjq!(ctx, ["week", "add", "${ctx.d2}", "threshold", "history probe sub", "r"], ".data.id"))
    _ = stride!(ctx.bin, ctx.home, ["skip", ph1, "weather"])
    _ = stride!(ctx.bin, ctx.home, ["skip", ph2, "did the row instead", "102"])
    check!("history row carries the skip reason", strjq!(ctx, ["plan"], ".data.plan_history_28d[] | select(.id == ${ph1}) | .status == \"skipped\" and .skipped_reason == \"weather\"") == "true")?
    check!("history row carries the substitute link AND its date", strjq!(ctx, ["plan"], ".data.plan_history_28d[] | select(.id == ${ph2}) | (.substitute_activity_id == 102) and (.completed_on | length == 10)") == "true")?
    # the adherence identity: every in-window session is exactly one of
    # completed / skipped / still_open — leftover-proof, no magic totals
    check!("adherence counts partition the planned set", strjq!(ctx, ["plan"], ".data.adherence_28d | .planned == (.completed + .skipped + .still_open)") == "true")?
    check!("substituted is a subset of skipped", strjq!(ctx, ["plan"], ".data.adherence_28d | .substituted <= .skipped and .substituted >= 1") == "true")?
    check!("completion_pct is a raw number", strjq!(ctx, ["plan"], ".data.adherence_28d.completion_pct | type") == "number")?
    # 101 and 102 are both LINKED at this point (completion + substitute), so an
    # unplanned probe activity proves the counter counts only unreferenced work
    before_unplanned = Str.trim(strjq!(ctx, ["plan"], ".data.adherence_28d.unplanned_activities"))
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time) VALUES (399,'unplanned probe','Ride','${ctx.d2}T12:00:00Z',1800);")
    after_unplanned = Str.trim(strjq!(ctx, ["plan"], ".data.adherence_28d.unplanned_activities"))
    check!("an unreferenced activity raises the unplanned count by one", sfloat(after_unplanned) == sfloat(before_unplanned) + 1.0)?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id = 399; DELETE FROM planned_sessions WHERE id IN (${ph1}, ${ph2});")

    check!("complete non-numeric id", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "abc", "101"]), "bad_id"))?
    check!("week add rest id 3", strjq!(ctx, ["week", "add", "2099-01-02", "rest", "planned rest", "recovery"], ".data.id") == "3")?
    check!("week add vo2max id 4", strjq!(ctx, ["week", "add", "2099-01-03", "vo2max", "intervals", "stimulus"], ".data.id") == "4")?
    check!("non-rest bare complete refused", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "4"]), "activity_required"))?
    # Refusing is not enough — the id lives in the database, and a message that names the
    # rule without naming the ids leaves the reader with no way forward short of opening
    # SQLite. The refusal must show the exact command AND the candidate activities.
    bare_refusal = stride!(ctx.bin, ctx.home, ["complete", "4"])
    check!("...and shows the command to run", Str.contains(bare_refusal, "stride complete 4 <activity_id>"))?
    # session 4 is 2099-01-03 and the fixture activity 101 is not within a day of it, so
    # this exercises the EMPTY branch — which must still hand the reader a next step
    check!("...and says what to do when nothing is near", Str.contains(bare_refusal, "No activities recorded within a day"))?
    # ...and the NON-empty branch, which is the whole point of the change. Without this the
    # suite passes with the candidate lookup returning [] every time: the two checks above
    # assert text that BOTH branches emit, so they cannot tell a working lookup from a
    # dead one. Caught by deliberately blanking the lookup and watching nothing fail.
    near_date = Str.trim(sql!(ctx.db, "SELECT substr(start_local,1,10) FROM activities WHERE id=101;"))
    _ = sql!(ctx.db, "INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status) VALUES ('0','${near_date}','endurance','needs an id','r','open');")
    near_id = Str.trim(sql!(ctx.db, "SELECT MAX(id) FROM planned_sessions;"))
    near_refusal = stride!(ctx.bin, ctx.home, ["complete", near_id])
    check!("a refusal lists the activity ids actually near that date", Str.contains(near_refusal, "Activities near that date"))?
    check!("...naming the real activity, not a placeholder", Str.contains(near_refusal, "101"))?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id = ${near_id};")
    check!("rest bare complete", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "3"]), "\"rest\":true"))?
    check!("rest is done in db", Str.trim(sql!(ctx.db, "SELECT status FROM planned_sessions WHERE id=3;")) == "done")?
    _ = stride!(ctx.bin, ctx.home, ["skip", "4", "cleanup"])
    check!("pending_sessions 0", strjq!(ctx, ["summary"], ".data.pending_sessions") == "0")?
    check!("plan open_sessions empty", strjq!(ctx, ["plan"], ".data.open_sessions | length") == "0")?
    check!("bare week is week-scoped (no far-future 2099 sessions)", strjq!(ctx, ["week"], "[.data[].target_date] | map(select(. >= \"2099\")) | length") == "0")?
    # a day that ends up FULLY skipped shows only its FINAL tombstone. With no live session on
    # the date, supersession falls to the "is there a LATER row?" arm — without it every earlier
    # draft leaked through and a re-planned-then-missed day rendered as near-identical duplicate
    # rows. Dated ctx.today because the bare `week` view is scoped to the current week — and
    # ctx.today is the suite's ONE time source (captured once at startup), so these assertions
    # can't straddle a midnight boundary the way a freshly-sampled clock could.
    check!("today draft id 5", strjq!(ctx, ["week", "add", ctx.today, "strength", "draft", "r"], ".data.id") == "5")?
    _ = stride!(ctx.bin, ctx.home, ["skip", "5", "re-tag as upper body"])
    check!("today final id 6", strjq!(ctx, ["week", "add", ctx.today, "strength", "final", "r"], ".data.id") == "6")?
    _ = stride!(ctx.bin, ctx.home, ["skip", "6", "exhausted"])
    check!("fully-skipped day shows ONE row", strjq!(ctx, ["week"], "[.data[] | select(.target_date==\"${ctx.today}\")] | length") == "1")?
    check!("fully-skipped day shows the FINAL tombstone", strjq!(ctx, ["week"], ".data[] | select(.target_date==\"${ctx.today}\") | .id") == "6")?
    check!("week all keeps every draft", strjq!(ctx, ["week", "all"], "[.data[] | select(.target_date==\"${ctx.today}\")] | length") == "2")?
    # #84 follow-up: a session completed by an activity from ANOTHER day rendered exactly
    # like one completed on time, so the plan quietly implied the work happened on the date
    # it was prescribed for. The completing activity's own day is shown when they differ.
    # Activity 101 lives on ctx.d1, so target a fixed date it cannot coincide with.
    _ = sql!(ctx.db, "INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status) VALUES ('0','2025-01-15','endurance','early ride','r','open');")
    early_id = Str.trim(sql!(ctx.db, "SELECT MAX(id) FROM planned_sessions;"))
    date_101 = Str.trim(sql!(ctx.db, "SELECT substr(start_local,1,10) FROM activities WHERE id=101;"))
    # 101 already completes session 2, and one activity tells one story (#146):
    # the early session completes with its own activity on 101's date
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (302,'early evidence','Ride','${date_101}T08:00:00Z',1800,10000);")
    _ = stride!(ctx.bin, ctx.home, ["complete", early_id, "302"])
    # The control has to be an ON-TIME session checked BY ID. Asserting the output merely
    # contains "│ done " is a false positive: it is a prefix of "│ done (Fri ...", so the
    # check passed even when every row carried a date.
    _ = sql!(ctx.db, "INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status) VALUES ('0','${date_101}','endurance','same day ride','r','open');")
    ontime_id = Str.trim(sql!(ctx.db, "SELECT MAX(id) FROM planned_sessions;"))
    # 101 already completes early_id, and one activity tells one story now
    # (#146 guard) — the on-time control gets its own same-day activity
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (301,'same day spin','Ride','${date_101}T12:00:00Z',1800,10000);")
    _ = stride!(ctx.bin, ctx.home, ["complete", ontime_id, "301"])
    ontime_status = strjq!(ctx, ["week", "all"], ".data[] | select(.id==${ontime_id}) | .status_shown")
    early_status = strjq!(ctx, ["week", "all"], ".data[] | select(.id==${early_id}) | .status_shown")
    # Every assertion selects its OWN row by id. Matching the whole plan output for
    # "done (" proved nothing: session 2 is completed with activity 101 earlier in this
    # scenario, so that string is already present regardless of what this row renders.
    check!("an on-time session renders exactly done", ontime_status == "done")?
    check!("the early one carries its real completion date", Str.starts_with(early_status, "done (") and Str.contains(early_status, date_101))?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id = ${ontime_id}; DELETE FROM activities WHERE id IN (301, 302);")
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id = ${early_id};")
    # #97: `week all` sections. Partition is by WEEK so no row appears twice, and rows
    # older than last week are COUNTED rather than silently dropped — `week all` still
    # means all, and the JSON payload keeps every row.
    _ = sql!(ctx.db, "INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status) VALUES ('0','2099-06-01','vo2max','far future session','r','open');")
    fut_id = Str.trim(sql!(ctx.db, "SELECT MAX(id) FROM planned_sessions;"))
    _ = sql!(ctx.db, "INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status) VALUES ('0','2020-01-06','rest','ancient session','r','skipped');")
    old_id = Str.trim(sql!(ctx.db, "SELECT MAX(id) FROM planned_sessions;"))
    all_h = stride_human!(ctx.bin, ctx.home, ["week", "all"])
    check!("week all has the three sections", Str.contains(all_h, "── upcoming ──") and Str.contains(all_h, "── this week ──") and Str.contains(all_h, "── last week ──"))?
    # Both ids are visible, because they are different things and the table was the only
    # place either appeared. Session 2 was completed by activity 101 above; asserting the
    # ACTIVITY id proves the new column carries a real value rather than a placeholder,
    # and the header proves the column exists at all even if no row happens to be done.
    check!("the week table has an activity column", Str.contains(all_h, "activity"))?
    check!("...showing the linked activity for a done session", Str.contains(all_h, "101"))?
    # anchor on the seeded target_date, not the detail text: `date` is its own
    # non-wrapping column, and 2099/2020 are sentinels that cannot appear by accident.
    # (The bare id would be worse than either — a 2-3 digit number matches digits in the
    # date and load cells of unrelated rows, so the negative check would go flaky.)
    check!("a future session lands in the table", Str.contains(all_h, "2099-06-01"))?
    check!("an ancient session is not rendered", !(Str.contains(all_h, "2020-01-06")))?
    check!("but it is counted, not dropped", Str.contains(all_h, "older session not shown"))?
    # sections partition by DATE ALONE. An open-only `upcoming` would leave a future-dated
    # skipped row in no section AND outside the hidden count — silently gone, which is the
    # one thing `week all` must never do. Skipping next week in advance is ordinary use.
    _ = sql!(ctx.db, "INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status) VALUES ('0','2099-06-02','rest','future skip','r','skipped');")
    skip_h = stride_human!(ctx.bin, ctx.home, ["week", "all"])
    check!("a future-dated skipped session still renders", Str.contains(skip_h, "2099-06-02"))?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE target_date = '2099-06-02';")
    # JSON stays a FLAT array carrying every row — sections are presentation only
    # an unparseable target_date belongs to no week. `week add` stores the date string
    # verbatim, so a typo reaches this code path; collapsing it to day 0 would count it
    # as "older" and claim it was in the past. It must be named as undated instead.
    _ = sql!(ctx.db, "INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status) VALUES ('0','tomorrow','vo2max','typo date','r','open');")
    undated_h = stride_human!(ctx.bin, ctx.home, ["week", "all"])
    check!("an undated session is counted as undated, not as older", Str.contains(undated_h, "1 undated"))?
    check!("and it is not silently filed under a week", !(Str.contains(undated_h, "typo date")))?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE target_date = 'tomorrow';")
    check!("json still carries the ancient row", strjq!(ctx, ["week", "all"], "[.data[] | select(.id==${old_id})] | length") == "1")?
    check!("json carries the future row too", strjq!(ctx, ["week", "all"], "[.data[] | select(.id==${fut_id})] | length") == "1")?
    check!("bare week is unsectioned", !(Str.contains(stride_human!(ctx.bin, ctx.home, ["week"]), "── upcoming ──")))?
    # `week all` must mean ALL — the older-count and its "json has every row" pointer are
    # both lies if the query truncates. Seed past 100 rows and check nothing is dropped.
    # a recursive CTE, not INSERT..SELECT FROM planned_sessions: that only adds as many
    # rows as already exist (~30 here), never crosses 100, and the check passes against
    # the capped build — the negative control caught it doing exactly that
    _ = sql!(ctx.db, "INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status) WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<150) SELECT '0','2019-03-04','rest','bulk filler','r','skipped' FROM c;")
    total = Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM planned_sessions;"))
    check!("week all returns every row past the old 100 cap", strjq!(ctx, ["week", "all"], ".data | length") == total)?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE target_date = '2019-03-04';")
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id IN (${fut_id}, ${old_id});")
    Ok({})
}

# ── activities (+ sport filter) ──────────────────────────────────────
b_activities! : Ctx => Try({}, _)
b_activities! = |ctx| {
    check!("2 activities", strjq!(ctx, ["activities"], ".data | length") == "2")?
    # NP 200 @ derived FTP 190 (config-FTP removed in #26): TSS ~110.8, IF ~1.05
    check_near!("101 tss ~111 (NP200 @ derived FTP 190)", sfloat(strjq!(ctx, ["activities"], ".data[] | select(.id==101) | .tss")), 110.8, 1.0)?
    check_near!("101 intensity ~1.05 (200/190)", sfloat(strjq!(ctx, ["activities"], ".data[] | select(.id==101) | .intensity")), 1.053, 0.02)?
    check_near!("102 hrTSS ~55", sfloat(strjq!(ctx, ["activities"], ".data[] | select(.id==102) | .tss")), 55.0, 1.0)?
    check!("sport filter returns 1", strjq!(ctx, ["activities", "10", "rowing"], ".data | length") == "1")?
    check!("sport filter is 102", strjq!(ctx, ["activities", "10", "rowing"], ".data[0].id") == "102")?
    Ok({})
}

# ── top: ranked best-sessions view ───────────────────────────────────
b_top! : Ctx => Try({}, _)
b_top! = |ctx| {
    check!("top tss ranks power ride first", strjq!(ctx, ["top", "tss"], ".data[0].id") == "101")?
    check!("top hr only the HR activity (len 1)", strjq!(ctx, ["top", "hr"], ".data | length") == "1")?
    check!("top hr is 102", strjq!(ctx, ["top", "hr"], ".data[0].id") == "102")?
    check!("top sport filter len 1", strjq!(ctx, ["top", "tss", "5", "rowing"], ".data | length") == "1")?
    check!("top sport filter is 102", strjq!(ctx, ["top", "tss", "5", "rowing"], ".data[0].id") == "102")?
    check!("top output ranks 101", strjq!(ctx, ["top", "output"], ".data[0].id") == "101")?
    check_near!("top output kJ ~720", sfloat(strjq!(ctx, ["top", "output"], ".data[0].output_kj")), 720.0, 1.0)?
    check!("top rejects unknown metric", Str.contains(stride!(ctx.bin, ctx.home, ["top", "bogus"]), "bad_metric"))?
    Ok({})
}

# ── load + stats ─────────────────────────────────────────────────────
b_load_stats! : Ctx => Try({}, _)
b_load_stats! = |ctx| {
    check!("load >= 4 daily rows", sfloat(strjq!(ctx, ["load"], ".data | length")) >= 4.0)?
    check!("load extends to today", strjq!(ctx, ["load"], ".data[-1].day") == ctx.today)?
    check!("load nonzero fitness", sfloat(strjq!(ctx, ["load"], ".data[-1].ctl")) > 0.0)?
    check!("Ride 1 session", strjq!(ctx, ["stats"], ".data.all_time[] | select(.sport==\"Ride\") | .sessions") == "1")?
    check_near!("Ride ~1.0h", sfloat(strjq!(ctx, ["stats"], ".data.all_time[] | select(.sport==\"Ride\") | .hours")), 1.0, 0.01)?
    check_near!("Ride ~30km", sfloat(strjq!(ctx, ["stats"], ".data.all_time[] | select(.sport==\"Ride\") | .km")), 30.0, 0.1)?
    check!("Rowing 1 session", strjq!(ctx, ["stats"], ".data.all_time[] | select(.sport==\"Rowing\") | .sessions") == "1")?
    check_near!("Rowing ~9km", sfloat(strjq!(ctx, ["stats"], ".data.all_time[] | select(.sport==\"Rowing\") | .km")), 9.0, 0.1)?
    Ok({})
}

# ── activity detail ──────────────────────────────────────────────────
b_activity_detail! : Ctx => Try({}, _)
b_activity_detail! = |ctx| {
    check!("activity 101 id", strjq!(ctx, ["activity", "101"], ".data.id") == "101")?
    check_near!("activity 101 tss ~111 (NP200 @ derived FTP 190)", sfloat(strjq!(ctx, ["activity", "101"], ".data.tss")), 110.8, 1.0)?
    check_near!("activity 101 intensity ~1.05 (200/190)", sfloat(strjq!(ctx, ["activity", "101"], ".data.intensity")), 1.053, 0.02)?
    check!("101 w60 computed from stream = 200", strjq!(ctx, ["activity", "101"], ".data.power_bests.w60") == "200")?
    check!("no power streams -> w60 honest 0", strjq!(ctx, ["activity", "102"], ".data.power_bests.w60") == "0")?
    check!("activity not-found", Str.contains(stride!(ctx.bin, ctx.home, ["activity", "999"]), "activity_not_found"))?

    # ── aerobic decoupling (#94) ─────────────────────────────────────
    # 101 has power streams but NO heart rate, so drift is not computable. It must report
    # honest ABSENCE, not 0 — a 0 would render a session with no strap identically to a
    # perfectly steady ride, which is the whole reason the flag exists.
    check!("no HR -> decoupling is not known", strjq!(ctx, ["activity", "101"], ".data.decoupling_known") == "false")?
    check!("...and the human line omits it entirely", !(Str.contains(stride_human!(ctx.bin, ctx.home, ["activity", "101"]), "drift")))?

    # A ride with FLAT 200W and HR stepping 130 -> 150 at the midpoint. Efficiency falls
    # from 200/130 to ~200/150, so the drift is ~13% — the same watts costing more
    # heartbeats. Pinning the value, not just its presence: a stub returning any constant
    # would satisfy "is a number".
    dtimes = Str.join_with(List.map(int_seq(600), |i| U64.to_str(i)), ",")
    dwatts = Str.join_with(List.map(int_seq(600), |_| "200"), ",")
    dhr = Str.join_with(List.map(int_seq(600), |i| if i < 300 "130" else "150"), ",")
    draw = "{\"time\":{\"data\":[${dtimes}]},\"watts\":{\"data\":[${dwatts}]},\"heartrate\":{\"data\":[${dhr}]}}"
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time,distance,device_watts) VALUES (777,'drift ride','Ride','${ctx.d1}T09:00:00Z',600,10000,1);")
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (777, '${draw}');")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("a drifting ride knows its decoupling", strjq!(ctx, ["activity", "777"], ".data.decoupling_known") == "true")?
    check_near!("...and reports ~13% Pw:HR drift", sfloat(strjq!(ctx, ["activity", "777"], ".data.decoupling_pct")), 13.3, 0.5)?
    check!("...and the human line shows it", Str.contains(stride_human!(ctx.bin, ctx.home, ["activity", "777"]), "drift"))?
    _ = sql!(ctx.db, "DELETE FROM streams WHERE activity_id = 777;")
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id = 777;")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 777;")
    Ok({})
}

# ── power junk filter + corrupt-stream flag + count/date resilience ──
b_junk_filter! : Ctx => Try({}, _)
b_junk_filter! = |ctx| {
    spike = spike_json!({})
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (101, '${spike}');")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 101;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    w60 = sfloat(strjq!(ctx, ["activity", "101"], ".data.power_bests.w60"))
    check!("9999W spike filtered from bests", w60 >= 190.0 and w60 <= 210.0)?
    pisum = sfloat(strjq!(ctx, ["activity", "101"], ".data.power_intensity.easy_s + .data.power_intensity.moderate_s + .data.power_intensity.hard_s"))
    check!("power ride has power-intensity time", pisum > 0.0)?
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (101, 'not json at all');")
    check!("corrupt streams flagged unreadable", strjq!(ctx, ["activity", "101"], ".data.streams_unreadable") == "true")?
    # force 101 to recompute so analyze re-decodes the now-corrupt stream: the SQL stream
    # swap above bypassed store_streams! (which is what deletes metrics on stream change),
    # and config-FTP no longer invalidates anything post-#26.
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 101;")
    check!("analyze reports stream decode errors", sfloat(strjq!(ctx, ["analyze"], ".data.stream_errors")) >= 1.0)?
    check!("activities non-numeric count", Str.contains(stride!(ctx.bin, ctx.home, ["activities", "banana"]), "bad_count"))?
    check!("load non-numeric count", Str.contains(stride!(ctx.bin, ctx.home, ["load", "abc"]), "bad_count"))?
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,avg_hr) VALUES (103,'bad date','Ride','0000-0z-01T10:00:00Z',3600,150);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("malformed date does not explode daily_load", str_to_i64(Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load"))) < 400)?
    # ...and remove it, as the neighbours below remove theirs. It was inserted to exercise
    # the refusal and then left in the fixture, which broke `stride season` for the whole
    # rest of every offline run — season is the one command that walks every activity date,
    # so it met the bad row and returned internal_error. Nothing noticed because nothing
    # called season after this point, until #219's schema loop did and silently skipped it.
    # The product half of that — a malformed date reaching the boundary as the catch-all
    # instead of a named error — is #243, and is unchanged by this cleanup.
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 103; DELETE FROM activities WHERE id = 103;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("...and removing it lets season run again, which is how the leak was found", Str.contains(stride!(ctx.bin, ctx.home, ["season"]), "blocks"))?
    # restore 101's good stream so downstream tests (import, doctor) still see a clean
    # measured-power ride — the corruption above was only to exercise the unreadable flag,
    # and power now needs a derivable FTP to score as measured.
    _ = seed_power_stream!(ctx.db, 101, 3600, 200)
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 101;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    Ok({})
}

# ── ADR 0005: FTP is period-accurate, so history stops moving ────────
# The whole point of the decision: an activity is scored by the fitness in force WHEN it
# happened, so a later personal best cannot retroactively rewrite it. Under the old
# today's-FTP model the 2024 ride was rescored every time the 60-day window slid.
b_period_ftp! : Ctx => Try({}, _)
b_period_ftp! = |ctx| {
    _ = seed_ride!(ctx.db, "801", "Old Ride", "2024-01-10T09:00:00Z", "3600", "30000", "200", "150")
    _ = seed_power_stream!(ctx.db, 801, 1300, 200)
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    old_tss = strjq!(ctx, ["activities", "50"], "[.data[] | select(.name==\"Old Ride\")][0].tss")
    check!("old ride scored", sfloat(old_tss) > 0.0)?

    # a much stronger ride, two years later — a genuine PR well outside the old ride's window
    _ = seed_ride!(ctx.db, "802", "New PR", "2026-01-10T09:00:00Z", "3600", "35000", "320", "150")
    _ = seed_power_stream!(ctx.db, 802, 1300, 320)
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    after_tss = strjq!(ctx, ["activities", "50"], "[.data[] | select(.name==\"Old Ride\")][0].tss")
    check!("later PR does NOT rescore the old ride", (sfloat(old_tss) - sfloat(after_tss)).abs() < 0.01)?

    # ...and the new ride is scored on its own fitness, not the old ride's
    pr_tss = strjq!(ctx, ["activities", "50"], "[.data[] | select(.name==\"New PR\")][0].tss")
    check!("new ride scored on its own window", sfloat(pr_tss) > 0.0)?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id IN (801,802);")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id IN (801,802);")
    _ = sql!(ctx.db, "DELETE FROM streams WHERE activity_id IN (801,802);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    Ok({})
}

# ── ADR 0005 (amended): the PACE threshold is period-accurate too (#79) ──
# The pace twin of b_period_ftp!. A faster swim two years later must not rescore the old
# one — under the old global threshold (best 20-min speed over the 60 days before TODAY)
# it did, and deleting any recent row moved that single number and requeued all history.
b_period_pace! : Ctx => Try({}, _)
b_period_pace! = |ctx| {
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (811,'Old Swim','Swim','2024-02-10T09:00:00Z',1800,2400);")
    _ = seed_pace_stream!(ctx.db, 811, 1300, 1)
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    old = Str.trim(sql!(ctx.db, "SELECT ROUND(tss,3) FROM activity_metrics WHERE activity_id=811;"))
    check!("old swim scored on pace", sfloat(old) > 0.0)?

    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (812,'Fast Swim','Swim','2026-02-10T09:00:00Z',1800,4800);")
    _ = seed_pace_stream!(ctx.db, 812, 1300, 2)
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    after = Str.trim(sql!(ctx.db, "SELECT ROUND(tss,3) FROM activity_metrics WHERE activity_id=811;"))
    check!("a later faster swim does NOT rescore the old one", old == after)?
    thr_old = sfloat(Str.trim(sql!(ctx.db, "SELECT ROUND(threshold_pace_used,3) FROM activity_metrics WHERE activity_id=811;")))
    thr_new = sfloat(Str.trim(sql!(ctx.db, "SELECT ROUND(threshold_pace_used,3) FROM activity_metrics WHERE activity_id=812;")))
    check!("each swim carries its OWN period threshold", thr_old < thr_new)?

    # The blast radius, which is what #79 was actually about: sync deletes the metrics for
    # its rolling window, and that must requeue only the affected rows. Under the global
    # threshold, dropping the recent row moved the one derived number and invalidated every
    # activity of that sport in history.
    # A sentinel, not a count: `computed` accumulates across fixed-point passes, so the
    # dropped row legitimately recomputes more than once as its own best repopulates.
    # load_model is rewritten by any recompute and is not read by the invalidation WHERE,
    # so it survives iff the old row was genuinely left alone.
    _ = sql!(ctx.db, "UPDATE activity_metrics SET load_model='SENTINEL' WHERE activity_id=811;")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id=812;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("dropping a recent row leaves older rows untouched", Str.trim(sql!(ctx.db, "SELECT load_model FROM activity_metrics WHERE activity_id=811;")) == "SENTINEL")?
    check!("the dropped row itself is rescored", str_to_i64(Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_metrics WHERE activity_id=812;"))) == 1)?

    _ = sql!(ctx.db, "DELETE FROM activities WHERE id IN (811,812);")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id IN (811,812);")
    _ = sql!(ctx.db, "DELETE FROM streams WHERE activity_id IN (811,812);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    Ok({})
}

# ── progress A: EF lens, date -> workout, chronological, no-workout ──
b_progress_a! : Ctx => Try({}, _)
b_progress_a! = |ctx| {
    _ = seed_ride!(ctx.db, "201", "Test Class", "2025-01-01T10:00:00Z", "3600", "20000", "180", "150")
    _ = seed_ride!(ctx.db, "202", "Test Class", "2025-06-01T10:00:00Z", "3600", "20000", "210", "150")
    # Each ride carries its OWN power stream. Under period-accurate FTP (ADR 0005) a ride is
    # scored by the fitness in force in ITS era, so a 2025 ride with no 20-min best anywhere
    # near it derives FTP 0, the ladder skips the power rungs, and np_w is never stored — the
    # EF lens (NP per heartbeat) then has nothing to read. Today's-FTP used to hide that by
    # lending these rides a 2026 number. Give them real power so the lens has real input.
    _ = seed_power_stream!(ctx.db, 201, 1300, 180)
    _ = seed_power_stream!(ctx.db, 202, 1300, 210)
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("progress anchor echoes date", strjq!(ctx, ["progress", "2025-06-01"], ".data.anchor_date") == "2025-06-01")?
    check!("progress 2 sessions", strjq!(ctx, ["progress", "2025-06-01"], ".data.groups[0].sessions | length") == "2")?
    check!("progress group name", strjq!(ctx, ["progress", "2025-06-01"], ".data.groups[0].name") == "Test Class")?
    check!("progress uses EF lens", strjq!(ctx, ["progress", "2025-06-01"], ".data.groups[0].lens") == "ef")?
    check!("progress chronological (earliest first)", strjq!(ctx, ["progress", "2025-06-01"], ".data.groups[0].sessions[0].date") == "2025-01-01")?
    check_near!("progress EF[0] ~1.20", sfloat(strjq!(ctx, ["progress", "2025-06-01"], ".data.groups[0].sessions[0].score")), 1.20, 0.01)?
    check_near!("progress EF[1] ~1.40", sfloat(strjq!(ctx, ["progress", "2025-06-01"], ".data.groups[0].sessions[1].score")), 1.40, 0.01)?
    # #96: a workout with only ONE session must say so in its own terms. "one comparable
    # session" read as though it pointed at some other session to compare with — the single
    # row IS the session. Seeded as its own uniquely-named class so it cannot group with
    # the Test Class rows above.
    # id 204, not 203: b_progress_b! below re-seeds 203 as a DIFFERENT activity, and
    # seed_ride! is a plain INSERT whose UNIQUE failure sql! would swallow. Today this
    # block's DELETEs run first so the collision never bites — but that makes correctness
    # depend on cleanup that looks redundant, and deleting it would break a check 30 lines
    # away with a message naming verdict averaging rather than a duplicate id.
    _ = seed_ride!(ctx.db, "204", "Solo Class", "2025-03-03T10:00:00Z", "3600", "20000", "190", "150")
    _ = seed_power_stream!(ctx.db, 204, 1300, 190)
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    solo_h = stride_human!(ctx.bin, ctx.home, ["progress", "2025-03-03"])
    check!("a lone session says it is the first, not that it has a comparable", Str.contains(solo_h, "first session of this workout"))?
    # NOT `!contains("one comparable session")` — that is the mutually exclusive arm of the
    # same `if`, so proving the new string present already proves it absent and the check
    # could never fail independently. These two catch a different regression: the
    # single-session branch being removed entirely so a lone row falls through to the trend
    # arm, which would report a fabricated 0% change.
    check!("...and does not fall through to the trend arm", !(Str.contains(solo_h, "holding steady")) and !(Str.contains(solo_h, "(0%)")))?
    # remove the fixture and REBUILD daily_load — later checks assert on fitness numbers,
    # and an extra scored activity left behind silently moves them. A seeded row that
    # outlives its own check is how a suite starts testing the state of its neighbours.
    _ = sql!(ctx.db, "DELETE FROM streams WHERE activity_id = 204;")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 204;")
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id = 204;")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("progress json no-workout error", Str.contains(stride!(ctx.bin, ctx.home, ["progress", "1999-01-01"]), "no_workout_on_date"))?
    Ok({})
}

# ── progress B: distance gate, bare anchor, last-vs-best rendering ──
b_progress_b! : Ctx => Try({}, _)
b_progress_b! = |ctx| {
    _ = seed_ride!(ctx.db, "211", "Morning Ride", "2025-03-01T08:00:00Z", "3600", "20000", "150", "140")
    _ = seed_ride!(ctx.db, "212", "Morning Ride", "2025-03-08T08:00:00Z", "3600", "21000", "160", "140")
    _ = seed_ride!(ctx.db, "213", "Morning Ride", "2025-03-15T08:00:00Z", "7200", "40000", "170", "140")
    # own streams, same reason as the block above: under ADR 0005 a ride is scored by the
    # fitness in force in its own era, so each fixture ride needs its own power basis.
    _ = seed_power_stream!(ctx.db, 211, 1300, 150)
    _ = seed_power_stream!(ctx.db, 212, 1300, 160)
    _ = seed_power_stream!(ctx.db, 213, 1300, 170)
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("auto-name distance-gated to 2 sessions", strjq!(ctx, ["progress", "2025-03-01"], ".data.groups[0].sessions | length") == "2")?
    check!("40km ride excluded", sfloat(strjq!(ctx, ["progress", "2025-03-01"], ".data.groups[0].sessions | map(.distance_m) | max")) < 30000.0)?
    check!("progress human empty-date guard", Str.contains(stride_human!(ctx.bin, ctx.home, ["progress", "1999-01-01"]), "no workout found"))?
    check!("unscorable workout explains lens", Str.contains(stride_human!(ctx.bin, ctx.home, ["progress", ctx.d1]), "can't be compared"))?
    check!("bare progress resolves an anchor", is_nonempty(strjq!(ctx, ["progress"], ".data.anchor_date")))?
    check!("bare progress has sessions", sfloat(strjq!(ctx, ["progress"], ".data.groups[0].sessions | length")) >= 1.0)?
    check!("rowing anchor uses speed_hr lens", strjq!(ctx, ["progress"], ".data.groups[0].lens") == "speed_hr")?
    check!("SpeedHr lens shows pace column", Str.contains(stride_human!(ctx.bin, ctx.home, ["progress"]), "pace (min/km)"))?
    _ = seed_ride!(ctx.db, "203", "Test Class", "2025-07-01T10:00:00Z", "3600", "20000", "150", "150")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    prog_h = stride_human!(ctx.bin, ctx.home, ["progress", "2025-07-01"])
    check!("weaker last shows below-your-best line", Str.contains(prog_h, "below your best"))?
    check!("verdict computes overall avg EF 1.20", Str.contains(prog_h, "(overall avg 1.20)"))?
    # the value and the FULL 12-block bar on one physical line — the bar column must
    # never be the one render_table squeezes and word-wraps (it was, before headers
    # went terse: the split bar looked broken and unreadable)
    check!("best session renders full ef bar unwrapped", Str.contains(prog_h, "1.40 ████████████"))?
    check!("asked-date row carries marker on the date", Str.contains(prog_h, "2025-07-01 ◀"))?
    check!("far-apart sessions show gap row", Str.contains(prog_h, "···"))?
    check!("progress desc lists newest session first", strjq!(ctx, ["progress", "2025-07-01", "desc"], ".data.groups[0].sessions[0].date") == "2025-07-01")?
    # The verdict must be computed on the CHRONOLOGICAL series regardless of display order:
    # this fixture rises 1.20 -> 1.40 -> falls, and reads "declining" either way. Asserting
    # the trend LABEL, not the last-vs-best footer — the footer compares the final session
    # to the best one and would still read "below your best" even if reversing the list had
    # flipped the trend, so it could not catch the regression this check is named for.
    desc_h = stride_human!(ctx.bin, ctx.home, ["progress", "2025-07-01", "desc"])
    asc_h = stride_human!(ctx.bin, ctx.home, ["progress", "2025-07-01", "asc"])
    check!("progress desc keeps the chronological verdict", Str.contains(desc_h, "declining") and Str.contains(asc_h, "declining"))?
    check!("progress rejects a bad sort word", Str.contains(stride!(ctx.bin, ctx.home, ["progress", "2025-07-01", "sideways"]), "asc|desc"))?

    # #84: the anchor session is not exempt from its own lens. Two rides sharing a name and
    # distance so they group together, neither with power so the lens is speed/HR: the anchor
    # has NO hr and drops out, the sibling stays. That kept the group non-empty, so the
    # unscorable branch never fired and the table rendered as though the trend included the
    # session that was asked about.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (215,'Anchor Probe Ride','Ride','2025-04-01T08:00:00Z',3600,20000);")
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_hr) VALUES (216,'Anchor Probe Ride','Ride','2025-04-20T08:00:00Z',3600,20000,140);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    anchor_h = stride_human!(ctx.bin, ctx.home, ["progress", "2025-04-01"])
    check!("an unscorable anchor says so", Str.contains(anchor_h, "isn't shown in its own table"))?
    check!("and the table still shows the scorable sibling", Str.contains(anchor_h, "2025-04-20"))?
    check!("anchor_scored false when the anchor drops out", strjq!(ctx, ["progress", "2025-04-01"], ".data.anchor_scored") == "false")?
    check!("anchor_scored true when the anchor survives", strjq!(ctx, ["progress", "2025-04-20"], ".data.anchor_scored") == "true")?
    check!("a scorable anchor stays silent", !(Str.contains(stride_human!(ctx.bin, ctx.home, ["progress", "2025-04-20"]), "isn't shown in its own table")))?

    # ...and one surviving group must not mask another that lost its anchor. Same date, a
    # SECOND workout that scores fine: asking whether ANY group still holds the date said
    # "all good" while the first group's anchor was missing from its own table.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_hr) VALUES (217,'Second Probe Ride','Ride','2025-04-01T18:00:00Z',3600,20000,145);")
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_hr) VALUES (218,'Second Probe Ride','Ride','2025-04-25T18:00:00Z',3600,20000,150);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    both_h = stride_human!(ctx.bin, ctx.home, ["progress", "2025-04-01"])
    check!("a scorable group does not mask an unscorable anchor", Str.contains(both_h, "isn't shown in its own table"))?
    check!("the scorable group still renders", Str.contains(both_h, "Second Probe Ride"))?
    check!("anchor_scored false while any group lost its anchor", strjq!(ctx, ["progress", "2025-04-01"], ".data.anchor_scored") == "false")?
    # ...and a twin on the SAME date must not cover for the anchor. anchor_filter takes the
    # FIRST row on the date, so an unscorable anchor with a scorable same-day sibling was
    # still "present by date" — the check has to ask whether the anchor ROW itself scores.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (219,'Twin Probe Ride','Ride','2025-05-01T08:00:00Z',3600,20000);")
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_hr) VALUES (220,'Twin Probe Ride','Ride','2025-05-01T18:00:00Z',3600,20000,145);")
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,avg_hr) VALUES (221,'Twin Probe Ride','Ride','2025-05-20T08:00:00Z',3600,20000,150);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    twin_h = stride_human!(ctx.bin, ctx.home, ["progress", "2025-05-01"])
    check!("a same-day twin does not cover for a dropped anchor", Str.contains(twin_h, "isn't shown in its own table"))?
    check!("anchor_scored false when the anchor row itself cannot score", strjq!(ctx, ["progress", "2025-05-01"], ".data.anchor_scored") == "false")?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id IN (219,220,221);")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id IN (219,220,221);")
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id IN (217,218);")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id IN (217,218);")
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id IN (215,216);")
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id IN (215,216);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    Ok({})
}

# ── import: Strava account export ────────────────────────────────────
validate_schema! : Ctx, Str, Str => Str
validate_schema! = |ctx, cmd, schema| Str.trim(sh!("out=$(HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' ${cmd} 2>/dev/null); if [ -z \"$out\" ]; then echo \"no output from '${cmd}' — nothing was validated\"; else printf '%s' \"$out\" | jq '.data' 2>&1 | jq -r --slurpfile schema schemas/v2/${schema}.json -f tools/validate.jq 2>&1; fi"))

b_import! : Ctx => Try({}, _)
b_import! = |ctx| {
    expdir = Str.trim(sh!("mktemp -d"))
    _ = write_csv!(expdir)
    imp = stride!(ctx.bin, ctx.home, ["import", expdir])
    check!("import 2 + skip 12", Str.contains(imp, "\"imported\":2") and Str.contains(imp, "\"skipped\":12"))?
    check!("a poison row skips rather than crashing the whole import", Str.contains(imp, "\"imported\":"))?
    check!("an exponent id is skipped, not upserted over id 700", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activities WHERE id IN (700, 7);")) == "0")?
    # scoped to the IMPORT fixture (ids 9000+): activity 103 carries a deliberately
    # malformed date for the bad-date path. The previous form of this check looked for a
    # 3-digit day or a short substring, and returned 0 for both real poison shapes --
    # green while "1e3-07-03T..." and "20250-07-0..." sat in the table.
    # GLOB the WHOLE column, not substr(...,1,10): the substring form truncated
    # "2025-07-100T..." to "2025-07-10" and matched, so it was green on the exact poison
    # it was written to catch. Scoped to imported ids because activity 103 carries a
    # deliberately malformed date for the bad-date path.
    # Defence in depth on STORED shape, and worth being exact about what it does and does
    # not pin, because an earlier comment here credited it with catching rows it cannot.
    #
    # What pins each component parse is the row COUNT above: widen any of them and the
    # poison row imports instead of skipping, so skipped drops and the count check fails.
    # Proved by reverting each of day/year/hour/minute/second/id one at a time.
    #
    # This check cannot see those, and that is a consequence of the fix rather than a
    # gap: the components are parsed and re-emitted through pad2, so a widened parse now
    # yields a VALID-but-wrong time ("1e1" becomes minute 10), not a malformed one. It
    # guards the older failure -- a component interpolated verbatim into start_local --
    # which is what produced 2025-07-100 and T37 in the first place. Shape plus a
    # julianday round trip, because the GLOB alone passes Feb 30 and Apr 31: SQLite
    # normalises an impossible date, so the round-tripped string differs from the stored.
    check!("no imported date is stored non-canonical", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activities WHERE id >= 9000 AND (start_local NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' OR strftime('%Y-%m-%dT%H:%M:%SZ', julianday(start_local)) IS NOT start_local);")) == "0")?
    check!("import conforms to its schema", validate_schema!(ctx, "import ${expdir}", "import") == "")?
    row9001 = Str.trim(sql!(ctx.db, "SELECT name || '|' || sport_type || '|' || start_local || '|' || moving_time || '|' || CAST(distance AS INT) || '|' || weighted_avg_watts FROM activities WHERE id=9001;"))
    check!("imported 9001 row exact", row9001 == "Morning ride, easy one|Ride|2025-07-01T06:30:00Z|3600|20100|190.0")?
    check!("HR-only 9002 keeps avg_hr", Str.trim(sql!(ctx.db, "SELECT avg_hr FROM activities WHERE id=9002;")) == "145.0")?
    check!("analyze after import", Str.contains(stride!(ctx.bin, ctx.home, ["analyze"]), "\"computed\":"))?
    tss9001 = Str.trim(sql!(ctx.db, "SELECT ROUND(tss) FROM activity_metrics WHERE activity_id=9001;"))
    check!("imported power ride gets TSS", tss9001 != "" and tss9001 != "0.0")?
    # #112: invalidation must fire on a REAL change, not on every re-write. `sync` re-lists
    # a rolling 30-day window every run, so invalidating on re-list deleted a month of
    # metrics per sync and left reports under-reporting load until the next analyze.
    # `import` shares upsert_activity!, so it exercises the same mechanism without network.
    before = Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_metrics WHERE activity_id IN (9001,9002);"))
    _ = stride!(ctx.bin, ctx.home, ["import", expdir])
    check!("re-import idempotent (2 rows)", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activities WHERE id IN (9001, 9002);")) == "2")?
    after = Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_metrics WHERE activity_id IN (9001,9002);"))
    # `before == "2"` matters as much as the equality: if both were 0 this would pass while
    # proving nothing
    check!("a no-op re-import keeps the computed metrics", before == "2" and after == "2")?
    # ...and the other half: a GENUINE change must still be rescored, or "edits self-heal"
    # quietly stops being true and the no-op check above could be satisfied by never
    # invalidating anything at all.
    #
    # Staleness lives in analyze now, which compares the inputs each metrics row was scored
    # from against the row as it stands. So the row is NOT deleted on write — it is
    # rescored on the next analyze. The edit is +7s duration and -1m distance on purpose:
    # a hash-based signature cancelled exactly on that pair and missed the edit entirely,
    # which is why the comparison is value-by-value.
    # Rewritten with sed rather than a second CSV helper: adding another top-level function
    # to this file segfaults the compiler (it already sits near the limit noted at the top).
    # `sed -i.bak … && rm` rather than `sed -i ''`: the empty-argument form is BSD-only and
    # fails on GNU sed, so a contributor running `just e2e` on Linux would break. CI runs
    # macOS, which is exactly how that would have gone unnoticed. No new tool either — the
    # harness already depends on sed via sh.
    _ = sh!("sed -i.bak '/^9001,/ s/,55,3600,20100\\.0,/,55,3607,20099.0,/' '${expdir}/activities.csv' && rm -f '${expdir}/activities.csv.bak'")
    _ = stride!(ctx.bin, ctx.home, ["import", expdir])
    check!("an edited row keeps its metrics row until analyze runs", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activity_metrics WHERE activity_id=9001;")) == "1")?
    check!("analyze rescores the edited row", strjq!(ctx, ["analyze"], ".data.computed") != "0")?
    check!("and the stored duration now matches the edit", Str.trim(sql!(ctx.db, "SELECT mt_used FROM activity_metrics WHERE activity_id=9001;")) == "3607")?
    check!("and it settles instead of rescoring forever", strjq!(ctx, ["analyze"], ".data.computed") == "0")?
    _ = sh!("cd '${expdir}' && zip -q export.zip activities.csv 2>/dev/null")
    check!("import from zip", Str.contains(stride!(ctx.bin, ctx.home, ["import", "${expdir}/export.zip"]), "\"imported\":2"))?
    check!("missing export explains itself", Str.contains(stride_human!(ctx.bin, ctx.home, ["import", "/nonexistent-dir-xyz"]), "no activities.csv"))?
    _ = sh!("rm -rf '${expdir}'")
    Ok({})
}

# ── session-RPE: the athlete scores what sensors can't ──────────────
b_rpe! : Ctx => Try({}, _)
b_rpe! = |ctx| {
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time) VALUES (301,'Heavy Lift','WeightTraining','2025-05-05T18:00:00Z',2700);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("sensorless strength scores none", Str.trim(sql!(ctx.db, "SELECT load_model FROM activity_metrics WHERE activity_id=301;")) == "none")?
    check!("rpe over 10 refused", Str.contains(stride!(ctx.bin, ctx.home, ["rate", "301", "11"]), "bad_rpe"))?
    # #201's headline case: `1e1` parses to 10.0, clears the 1..10 range guard, and
    # writes a rating -- judgment-tier data that cannot be re-derived. The id argument
    # of this same command was narrowed first and this one was left open.
    check!("an exponent RPE is refused", Str.contains(stride!(ctx.bin, ctx.home, ["rate", "301", "1e1"]), "bad_rpe"))?
    check!("an exponent activity id is refused by rate", Str.contains(stride!(ctx.bin, ctx.home, ["rate", "3e2", "5"]), "bad_id"))?
    check!("...and a fractional RPE still works", Str.contains(stride!(ctx.bin, ctx.home, ["rate", "301", "7.5"]), "\"rated\":301"))?
    check!("rate confirms", Str.contains(stride!(ctx.bin, ctx.home, ["rate", "301", "7"]), "\"rated\":301"))?
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("45min @ RPE 7 => session_rpe 52.5", Str.trim(sql!(ctx.db, "SELECT load_model || '|' || ROUND(tss, 1) FROM activity_metrics WHERE activity_id=301;")) == "session_rpe|52.5")?
    _ = stride!(ctx.bin, ctx.home, ["rate", "301", "5"])
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("re-rate to 5 rescores to 37.5", Str.trim(sql!(ctx.db, "SELECT ROUND(tss, 1) FROM activity_metrics WHERE activity_id=301;")) == "37.5")?
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time) VALUES (301,'Heavy Lift','WeightTraining','2025-05-05T18:00:00Z',2700);")
    check!("rating survives mirror replace", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM ratings WHERE activity_id=301;")) == "1")?
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("rated strength uses RPE lens", strjq!(ctx, ["progress", "2025-05-05"], ".data.groups[0].lens") == "rpe")?
    check_near!("RPE score is the rating (5.0)", sfloat(strjq!(ctx, ["progress", "2025-05-05"], ".data.groups[0].sessions[0].score")), 5.0, 0.01)?
    Ok({})
}

# ── compare: this window vs the prior one ───────────────────────────
b_compare! : Ctx => Try({}, _)
b_compare! = |ctx| {
    cmp_raw = stride!(ctx.bin, ctx.home, ["compare", "week"])
    check!("compare period week", Str.contains(cmp_raw, "\"period\":\"week\""))?
    check!("compare window 7d", Str.contains(cmp_raw, "\"window_label\":\"7d\""))?
    check!("compare current has >=1 session", sfloat(strjq!(ctx, ["compare", "week"], ".data.current.sessions")) >= 1.0)?
    check!("compare exposes a prior window", is_nonempty(strjq!(ctx, ["compare", "week"], ".data.prior.sessions")))?
    check!("compare current carries all metric fields", strjq!(ctx, ["compare", "week"], ".data.current | [has(\"tss\"),has(\"sessions\"),has(\"hard_min\"),has(\"easy_pct\"),has(\"ctl\")] | all") == "true")?
    check!("compare prior carries all metric fields", strjq!(ctx, ["compare", "week"], ".data.prior | [has(\"tss\"),has(\"sessions\"),has(\"hard_min\"),has(\"easy_pct\"),has(\"ctl\")] | all") == "true")?
    check!("compare rejects unknown period", Str.contains(stride!(ctx.bin, ctx.home, ["compare", "year"]), "bad_period"))?
    Ok({})
}

# ── doctor: coverage + provenance + honest gaps + time mode ─────────
b_doctor! : Ctx => Try({}, _)
b_doctor! = |ctx| {
    check!("doctor activities > 0", sfloat(strjq!(ctx, ["doctor"], ".data.activities")) > 0.0)?
    # #92 watchdog. Every assertion selects its OWN field with jq rather than matching the
    # whole report, so a number appearing elsewhere cannot satisfy it by accident.
    # Seeded dated AFTER the fixture activities so they are genuinely the most recent —
    # the streak is a newest-first walk, and rows seeded in the past would prove nothing.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation) VALUES (9401,'strapless ride 1','Ride','2099-03-01T10:00:00Z',3600,30000,0);")
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation) VALUES (9402,'strapless ride 2','Ride','2099-03-02T10:00:00Z',3600,30000,0);")
    check!("two strapless rides make a streak of 2", strjq!(ctx, ["doctor"], ".data.hr_missing_streak") == "2")?
    # a lifting session with no strap sits between them and must NOT reset the streak —
    # strength routinely runs strapless, and counting it would hide the endurance gap
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation) VALUES (9403,'lift','WeightTraining','2099-03-03T10:00:00Z',2700,0,0);")
    check!("a strapless lift neither counts nor resets the streak", strjq!(ctx, ["doctor"], ".data.hr_missing_streak") == "2")?
    # ...and a strapped ride on top resets it to 0
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,avg_hr) VALUES (9404,'strapped ride','Ride','2099-03-04T10:00:00Z',3600,30000,0,140);")
    check!("a strapped ride resets the streak", strjq!(ctx, ["doctor"], ".data.hr_missing_streak") == "0")?
    # device_watts = 0 is Strava flagging ESTIMATED watts; dated today so it lands in 30d
    est_before = sfloat(strjq!(ctx, ["doctor"], ".data.estimated_power_count_30d"))
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,avg_watts,device_watts) VALUES (9405,'estimated watts','Ride','${ctx.today}T09:00:00Z',3600,30000,0,180,0);")
    est_after = sfloat(strjq!(ctx, ["doctor"], ".data.estimated_power_count_30d"))
    check_near!("an estimated-power ride is counted in 30d", est_after, est_before + 1.0, 0.001)?
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id IN (9401,9402,9403,9404,9405);")
    # #92 junk%: pooled share over the window AND the worst single session, which answer
    # different questions — pooled is the trend, worst is the incident. Counters are
    # written where valid_hr / valid_watts run, so they are seeded directly here rather
    # than by re-analyzing.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation) VALUES (9410,'clean','Ride','${ctx.today}T07:00:00Z',3600,30000,0);")
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation) VALUES (9411,'junky','WeightTraining','${ctx.today}T08:00:00Z',600,0,0);")
    # Counts deliberately far larger than anything the fixture's own activities carry, so
    # the pooled figure is dominated by these two and the assertion tests the pooling rule
    # rather than whatever the rest of the fixture happens to contribute.
    # 9410: 100k of 1M HR samples dropped (10%). 9411: 100k of 200k dropped (50%).
    _ = sql!(ctx.db, "INSERT INTO activity_metrics (activity_id,hr_samples_total,hr_samples_dropped,watts_samples_total,watts_samples_dropped,metrics_rev) VALUES (9410,1000000,100000,0,0,0);")
    _ = sql!(ctx.db, "INSERT INTO activity_metrics (activity_id,hr_samples_total,hr_samples_dropped,watts_samples_total,watts_samples_dropped,metrics_rev) VALUES (9411,200000,100000,0,0,0);")
    # pooled = 200k dropped / 1.2M total = 16.67%. A per-session MEAN would give 30% —
    # the assertion fails against that, which is the whole point of choosing pooled.
    check_near!("junk pct pools across the window", sfloat(strjq!(ctx, ["doctor"], ".data.junk_filtered_pct_30d")), 16.667, 0.5)?
    # worst session = 100/200 = 50%, which pooling alone would have hidden
    check_near!("worst session is reported separately", sfloat(strjq!(ctx, ["doctor"], ".data.junk_worst_session_pct_30d")), 50.0, 0.05)?
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id IN (9410,9411);")
    _ = sql!(ctx.db, "DELETE FROM activities WHERE id IN (9410,9411);")
    check!("doctor rated 1", strjq!(ctx, ["doctor"], ".data.rated") == "1")?
    check!("doctor strength_unrated 0", strjq!(ctx, ["doctor"], ".data.strength_unrated") == "0")?
    check!("doctor scored_by session_rpe 1", strjq!(ctx, ["doctor"], "[.data.scored_by[] | select(.model==\"session_rpe\") | .n] | add // 0") == "1")?
    check!("doctor conf_high >= 1", sfloat(strjq!(ctx, ["doctor"], ".data.conf_high")) >= 1.0)?
    check!("doctor conf_medium >= 1", sfloat(strjq!(ctx, ["doctor"], ".data.conf_medium")) >= 1.0)?
    ch = strjq!(ctx, ["doctor"], ".data.conf_high")
    # This must enumerate EVERY rung the code maps to `high`, including rtss -- the
    # comment over that mapping claimed the cross-check made it undriftable while this
    # list omitted rtss, so dropping rtss from the mapping left the suite green.
    powr = strjq!(ctx, ["doctor"], "[.data.scored_by[] | select(.model==\"power_stream\" or .model==\"weighted_watts\" or .model==\"avg_watts\" or .model==\"rtss\") | .n] | add // 0")
    check!("conf_high == every rung mapped to high", ch == powr)?
    # The guard is only as strong as the rungs that EXIST when it runs: a rung with zero
    # rows leaves both sides of the equality unchanged, so dropping it from the mapping is
    # invisible. That is an ordering property, not a fixture property -- avg_watts was
    # uncovered only because b_doctor! ran before the body seeding it, and a comment here
    # once asserted the fixture had no such row at all. Pin the coverage so a reorder that
    # re-hides a rung fails HERE rather than silently weakening the check above.
    covered = strjq!(ctx, ["doctor"], "[.data.scored_by[] | select(.n > 0) | .model] | sort | join(\",\")")
    check!("every power rung the mapping names exists by the time doctor measures it", Str.contains(covered, "power_stream") and Str.contains(covered, "weighted_watts") and Str.contains(covered, "avg_watts") and Str.contains(covered, "rtss"))?
    check!("doctor reports sports with a DERIVED ftp", sfloat(strjq!(ctx, ["doctor"], ".data.ftp_derived_sports")) >= 1.0)?
    check!("doctor zones_set true", strjq!(ctx, ["doctor"], ".data.zones_set") == "true")?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "timezone", ctx.tz])
    check!("valid tz time_ok", strjq!(ctx, ["doctor"], ".data.time_ok") == "true")?
    dtime = strjq!(ctx, ["doctor"], ".data.time")
    check!("a valid tz is reported DST-aware", Str.contains(dtime, ctx.tz) and Str.contains(dtime, "DST-aware"))?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "timezone", "Not/ARealZone"])
    check!("bad tz not ok", strjq!(ctx, ["doctor"], ".data.time_ok") == "false")?
    check!("bad tz shows UNKNOWN", Str.contains(strjq!(ctx, ["doctor"], ".data.time"), "UNKNOWN"))?
    # an empty value and an absent row are the SAME state -- Db.roc collapses both to
    # NoTz. That equivalence was assumed by a comment in b_config_ftp! and asserted
    # nowhere, and this write sat here with nothing observing it -- on main it was the
    # LAST statement of this body, so it leaked the blank zone into every scenario after
    # it, which is the actual reason it needs a restore. It asserts the equivalence now
    # rather than sitting there as dead code wearing a test's clothes.
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "timezone", ""])
    check!("empty timezone is the absent state, not an invalid one", strjq!(ctx, ["doctor"], ".data.time_ok") == "true" and Str.contains(strjq!(ctx, ["doctor"], ".data.time"), "UTC"))?
    # restore before returning: three scenarios run after this one, and leaving the zone
    # blank -- or on the unresolvable name set just above, which also resolves to UTC --
    # hands them a binary on a different clock than the harness -- the same defect
    # this PR fixes at b_config_ftp!. Latent today (nothing after here is date-sensitive)
    # and a trap for the next date-sensitive check appended to the suite.
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "timezone", ctx.tz])
    Ok({})
}

# ── #73: estimated watts must not outrank honest fallbacks ──────────
# Twin rides on ctx.d1 (ride 101's derived FTP 190 is in force): identical watts/HR,
# only the device_watts flag differs. NULL (legacy rows, CSV imports) = measured;
# 0 = Strava's estimate, which must fall through to the HR rung.
b_device_watts! : Ctx => Try({}, _)
b_device_watts! = |ctx| {
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,avg_watts,avg_hr,device_watts) VALUES (401,'estimated ride','Ride','${ctx.d1}T12:00:00Z',3600,200,150,0);")
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,avg_watts,avg_hr) VALUES (402,'meterless-flag ride','Ride','${ctx.d1}T14:00:00Z',3600,200,150);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("estimated watts fall through to HR", Str.trim(sql!(ctx.db, "SELECT load_model FROM activity_metrics WHERE activity_id=401;")) == "hr_avg")?
    check!("NULL device_watts still scores as measured", Str.trim(sql!(ctx.db, "SELECT load_model FROM activity_metrics WHERE activity_id=402;")) == "avg_watts")?
    # one pace-scored activity that SURVIVES to b_doctor!, so doctor's confidence
    # cross-check can guard the rtss rung. b_period_pace! seeds one too and then deletes
    # it, which is the only reason the rung was invisible there -- a threshold speed
    # derives from a single activity via period_threshold_sql's TRAILING-60-day arm,
    # whose `b2.start_local <= a.start_local` includes the activity's own row, so no
    # accumulated history is needed. (Not the cold-start forward-fill: delete that arm
    # outright and the suite stays green.) Without this row, dropping 'rtss' from
    # high_models_sql leaves the whole suite green.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance) VALUES (403,'doctor pace swim','Swim','${ctx.d1}T05:00:00Z',1800,2400);")
    _ = seed_pace_stream!(ctx.db, 403, 1300, 1)
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("a pace-scored activity survives to doctor", Str.trim(sql!(ctx.db, "SELECT load_model FROM activity_metrics WHERE activity_id=403;")) == "rtss")?
    Ok({})
}

# ── human output mode ────────────────────────────────────────────────
b_human! : Ctx => Try({}, _)
b_human! = |ctx| {
    check!("human week all header", Str.contains(stride_human!(ctx.bin, ctx.home, ["week", "all"]), "status"))?
    check!("human activities header", Str.contains(stride_human!(ctx.bin, ctx.home, ["activities"]), "sport"))?
    check!("human load verdict line", Str.contains(stride_human!(ctx.bin, ctx.home, ["load", "7"]), "today: form"))?
    check!("human stats section", Str.contains(stride_human!(ctx.bin, ctx.home, ["stats"]), "ALL TIME"))?
    check!("human activity zones row", Str.contains(stride_human!(ctx.bin, ctx.home, ["activity", "101"]), "Z1"))?
    check!("human summary banner", Str.contains(stride_human!(ctx.bin, ctx.home, ["summary"]), "stride report"))?
    # `plan` is the priciest read in the suite, so every HUMAN-mode assertion here shares
    # one capture rather than shelling out again — two copies of the same output can drift
    # apart. The JSON-mode checks still invoke it separately: a different output mode
    # cannot reuse this capture. (No count here on purpose — one that says "three
    # assertions" goes stale the next time somebody adds a fourth.)
    plan_h = stride_human!(ctx.bin, ctx.home, ["plan"])
    check!("human plan bundle", Str.contains(plan_h, "OPEN PLAN"))?
    # the 14-day table is a DATE RANGE: a day with nothing on it is information, and week
    # boundaries are drawn as full-width rules
    check!("days with no activity are shown, not skipped over", Str.contains(plan_h, "(no activity)"))?
    # A full-width RULE in the table's own border glyphs, not dotted cells: `···` reads as
    # data, and `progress` already uses it to mean a GAP in time, so a boundary between two
    # CONSECUTIVE days looked like missing days.
    #
    # Scoped to the RECENT block and COUNTED. The first draft asserted `contains "├────"`,
    # which every table satisfies via its header rule, and `!contains "│ ··· │"`, which
    # never matched because cells are padded — both passed against the dotted version.
    # A ruled table has 2+ mid-borders, a dotted one exactly 1 (its header rule), so >= 2
    # discriminates. NOT >= 3: a 14-day window spans two Sundays, but when the anchor day
    # is itself a Sunday the first one is suppressed (no divider above the first row), so
    # the count drops to 2 — this check would have failed every Sunday in CI.
    # ONE block, and its header asserted FIRST. Splitting on a marker that is absent
    # returns the whole output, so every assertion below would then be measuring the OPEN
    # PLAN table above and passing for the wrong reason — the same vacuous-pass shape this
    # block has already been bitten by twice.
    check!("the recent-activity section is present", Str.contains(plan_h, "RECENT 14 DAYS"))?
    recent_block = List.last(Str.split_on(plan_h, "RECENT 14 DAYS")).ok_or("")
    rule_count = List.len(Str.split_on(recent_block, "├────")) - 1
    check!("week boundaries are drawn as full-width rules", rule_count >= 2)?
    check!("and no dotted cells remain anywhere in the table", !(Str.contains(recent_block, "···")))?
    # The window has to be as wide as its name. Both the header and the JSON field say 14,
    # so the oldest day rendered is anchor-13 — an inclusive `>= anchor - 14` spans fifteen.
    oldest_in = Str.trim(sql!(ctx.db, "SELECT date(MAX(day), '-13 days') FROM daily_load;"))
    first_out = Str.trim(sql!(ctx.db, "SELECT date(MAX(day), '-14 days') FROM daily_load;"))
    check!("the 14-day table reaches back exactly 13 days", Str.contains(recent_block, oldest_in))?
    check!("and stops there — anchor-14 is outside the window", !(Str.contains(recent_block, first_out)))?
    # ...and the JSON stays a list of REAL activities — no pseudo-rows without an id
    check!("json recent list has no placeholder rows", strjq!(ctx, ["plan"], "[.data.recent_activities_14d[] | select(.id == null or .id == 0)] | length") == "0")?
    # #103: the bundle exists to answer a planning question in ONE call. Its activity rows
    # used to drop four fields `activities` returns for the same rows — avg_hr worst of
    # all, since "was that ride actually easy" is an average-HR question. Assert every row
    # carries the full shape, not just the first.
    check!("bundle rows carry the same fields as activities", strjq!(ctx, ["plan"], "[.data.recent_activities_14d[] | select((has(\"avg_hr\") and has(\"np_w\") and has(\"relative_effort\") and has(\"distance_m\")) | not)] | length") == "0")?
    check!("uppercase STRIDE_FORMAT selects JSON", Str.contains(stride_env!(ctx.bin, ctx.home, ["summary"], [("STRIDE_FORMAT", "JSON")]), "\"schema_version\""))?
    Ok({})
}

# ── a reader must never be able to abort a writer (#80) ─────────────
# analyze rebuilds daily_load in one transaction. Under the rollback journal that locked
# the whole db, and with busy_timeout 0 a concurrent reader failed instantly — a single
# `stride week` in another terminal killed a running analyze and discarded its work.
b_concurrency! : Ctx => Try({}, _)
b_concurrency! = |ctx| {
    # Racing a real analyze proved nothing here — the sandbox db computes in well under a
    # second, so the reader never overlapped the transaction and the check still passed with
    # the fix reverted. Hold a lock DETERMINISTICALLY instead: a background sqlite3 keeps a
    # transaction open, since its connection lives as long as its stdin does.
    check!("journal mode is WAL", Str.trim(sql!(ctx.db, "PRAGMA journal_mode;")) == "wal")?
    # Clear what analyze must rebuild. Without this the "it wrote" check below passed on
    # rows left by earlier scenarios, so it proved nothing about the run under contention.
    _ = sql!(ctx.db, "DELETE FROM activity_metrics;")
    _ = sql!(ctx.db, "DELETE FROM daily_load;")
    # A FIFO, not a backgrounded pipeline: `$!` on a pipeline is the last command in some
    # shells and the subshell in others, so `kill $!` could leave sqlite3 alive holding the
    # transaction and block every test after this one. Feeding sqlite3 from a fifo makes it
    # a single background command, so $! is unambiguously sqlite3; holding the write end
    # open (fd 3) keeps its transaction open for exactly as long as this scenario needs,
    # and closing fd 3 ends it immediately — no timer bounding the hold, and nothing left
    # running afterwards. The one `sleep 1` below is a readiness wait, giving sqlite3 time
    # to take its read lock before analyze starts; without it the two might not overlap and
    # the check would pass without ever testing contention.
    # No `set -e`: if analyze ever fails again, the shell would exit before `exec 3>&-`
    # and the fifo cleanup, leaving sqlite3 alive holding the transaction and hanging every
    # check after this one — the regression would present as a stuck suite instead of a
    # failed assertion, and held.out would be lost.
    # STRIDE_FORMAT is pinned because this bypasses the stride! helper, which sets
    # it. This check once depended on an environment variable that happened to be
    # exported in the developer's shell and not on CI, so it passed locally and
    # failed there; since #181 nothing infers the mode from ambient state, and
    # pinning it explicitly is the whole story.
    held = Str.trim(sh!("f='${ctx.home}/hold.fifo'; rm -f \"$f\"; mkfifo \"$f\"; sqlite3 '${ctx.db}' < \"$f\" > /dev/null 2>&1 & holder=$!; exec 3> \"$f\"; printf 'BEGIN;\\nSELECT COUNT(*) FROM activities;\\n' >&3; sleep 1; HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' analyze > '${ctx.home}/held.out' 2>&1; exec 3>&-; wait $holder 2>/dev/null; rm -f \"$f\"; cat '${ctx.home}/held.out'"))
    # NOT schema_version: the ERROR envelope carries that too, so matching it would accept
    # the very failure this scenario exists to catch. `converged` appears only in analyze's
    # success payload, and daily_load — emptied above, rebuilt by analyze alone — proves
    # THIS run wrote under contention rather than some earlier one.
    check!("analyze finishes while a reader holds the db", Str.contains(held, "\"converged\":true"))?
    check!("no busy error under a held read lock", !(Str.contains(held, "Busy")) and !(Str.contains(held, "locked")) and !(Str.contains(held, "\"error\"")))?
    check!("and it rebuilt daily_load under contention", str_to_i64(Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load;"))) > 0)?
    # doctor must report the mode actually in force, not assume it engaged
    check!("doctor reports concurrent reads ok", strjq!(ctx, ["doctor"], ".data.concurrent_reads_ok") == "true")?
    check!("doctor reports the journal mode", strjq!(ctx, ["doctor"], ".data.journal_mode") == "wal")?
    Ok({})
}

# ── schema migration: a legacy db upgrades with data intact ──────────
b_migration! : Ctx => Try({}, _)
b_migration! = |ctx| {
    mighome = Str.trim(sh!("mktemp -d"))
    migdb = "${mighome}/.stride/db.sqlite"
    # the one fixture write that does not go through sql! — it reads a FILE rather than a
    # heredoc — so it gets the same timeout and logs to the same run-scoped file by hand
    # rather than being the single unguarded sqlite3 write left in the file it is hardening
    _ = sh!("mkdir -p '${mighome}/.stride' && sqlite3 -cmd '.timeout 5000' '${migdb}' 2>'${sqlfail_log}.err' < tests/fixtures/db/v1-legacy.sql || { echo \"sqlite3 failed seeding the v1 fixture into ${migdb}:\" >> '${sqlfail_log}'; cat '${sqlfail_log}.err' >> '${sqlfail_log}'; }")
    check!("fixture starts at user_version 1", Str.trim(sql!(migdb, "PRAGMA user_version;")) == "1")?
    # any command that OPENS the db runs migrations. It used to be `config get ftp_ride`,
    # which no longer touches the db at all — a derived key is refused before open_db!, so
    # that would have silently stopped exercising the migration path.
    _ = stride!(ctx.bin, mighome, ["config", "get", "timezone"])
    migv = str_to_i64(Str.trim(sql!(migdb, "PRAGMA user_version;")))
    check!("migration advances schema version", migv > 1)?
    check!("rename preserves planned session row", Str.trim(sql!(migdb, "SELECT session_type FROM planned_sessions WHERE id=1;")) == "vo2max")?
    check!("ratings table created", Str.contains(sql!(migdb, "SELECT 1 FROM ratings LIMIT 0; SELECT 'ok';"), "ok"))?
    check!("metric provenance columns added", Str.contains(sql!(migdb, "SELECT load_model, metrics_rev, zones_used FROM activity_metrics LIMIT 0; SELECT 'ok';"), "ok"))?
    check!("weighted_avg_watts column added", Str.contains(sql!(migdb, "SELECT weighted_avg_watts FROM activities LIMIT 0; SELECT 'ok';"), "ok"))?
    check!("activities survive migration", Str.trim(sql!(migdb, "SELECT COUNT(*) FROM activities;")) == "2")?
    # the idempotency re-run must OPEN the db; ftp_ride no longer does (refused before
    # open_db!), so it would test nothing here — timezone still goes through the db
    _ = stride!(ctx.bin, mighome, ["analyze"])
    _ = stride!(ctx.bin, mighome, ["config", "get", "timezone"])
    check!("re-run idempotent (version stable)", str_to_i64(Str.trim(sql!(migdb, "PRAGMA user_version;"))) == migv)?
    check!("re-run keeps data", Str.trim(sql!(migdb, "SELECT COUNT(*) FROM activities;")) == "2")?
    # No guard of its own: migdb is a SECOND sandbox, and a per-db log needed a per-db
    # check here to be read at all before this `rm -rf` deleted it. The run-scoped log
    # made that check redundant — run_all!'s single one covers this sandbox too, and
    # covers it on the ABORT path as well, which a check placed here never could.
    _ = sh!("rm -rf '${mighome}'")
    Ok({})
}

# ── helpers ──────────────────────────────────────────────────────────

env_or! : Str, Str => Str
env_or! = |name, dflt|
    match Env.var_str!(OsStr.from_str(name)) {
        Ok(v) if !(Str.is_empty(v)) => v
        _ => dflt
    }

# a required setup value: empty (a failed mktemp/date shellout) aborts the run instead
# of silently building bad paths like "/.stride/db.sqlite" or seeding empty dates
need : Str, Str -> Try(Str, [SetupFailed(Str), ..])
need = |what, v| if Str.is_empty(v) Err(SetupFailed(what)) else Ok(v)

# stdout of a shell one-liner. The script's own exit status is NOT the assertion
# here — since #163 a stride error exits non-zero, and the interesting output is
# the envelope it printed on the way out, which the Err payload carries.
sh! : Str => Str
sh! = |script|
    match Cmd.new(OsStr.from_str("sh")).args(List.map(["-c", script], OsStr.from_str)).exec_output!() {
        Ok(o) => o.stdout_utf8
        Err(NonZeroExitCode(e)) => e.stdout_utf8_lossy
        Err(_) => ""
    }

# run SQL against the db. The query is fed via a quoted heredoc so it can contain
# BOTH single quotes (SQL string literals) and double quotes (e.g. embedded JSON
# stream fixtures) without any shell-quoting breakage.
# Two guards, both for #226 — the suite failed twice in ~18 runs at two unrelated checks.
#
# `.timeout 5000`: the sqlite3 CLI defaults to busy_timeout 0, so ANY lock contention
# fails instantly instead of waiting. stride's own connections set exactly this value
# (Db.roc, "busy_timeout FIRST"); these fixture writes were the one path in the system
# without one. Hardening on its own merits — NOT a diagnosis. The first draft of this
# comment claimed the failures happened under `just test` "which runs a build and eight
# test invocations alongside"; that recipe is strictly sequential and nothing runs
# alongside anything, so the mechanism was invented. No concurrent writer to ctx.db has
# been demonstrated at all: the harness is single-process, and b_concurrency!'s holder
# takes a READ transaction under WAL, which blocks no writer.
#
# A competing hypothesis this guard is BLIND to, and which the file's own header makes
# at least as plausible: sh!'s `Err(_) => ""` arm fires when a child never runs or its
# exit code is lost, and this harness moved off basic-cli precisely because that host
# "loses a child's exit code intermittently under that volume". Then sqlite3 never runs,
# nothing is appended, and sql! returns "" — indistinguishable from success. Worth
# reaching for before lock contention if #226 recurs.
#
# The failure log: a failing write used to be invisible three times over. sqlite3 reports
# on stderr, sh! discards stderr AND the exit code, and 199 of the 277 call sites discard
# the return with `_ = sql!(...)`. So the write silently did not happen and surfaced later
# as an unrelated-looking assertion about state. That half is worth having whether or not
# the timeout was the cause: a harness that ignores failed setup writes will mislead again.
sql! : Str, Str => Str
sql! = |db, query|
    sh!("sqlite3 -cmd '.timeout 5000' '${db}' 2>'${sqlfail_log}.err' <<'SQLHEREDOC' || { echo \"sqlite3 failed on ${db}:\" >> '${sqlfail_log}'; cat '${sqlfail_log}.err' >> '${sqlfail_log}'; }\n${query}\nSQLHEREDOC")

# ONE log for the whole run, at a FIXED path — not a `<db>.sqlfail` beside each database.
# Keying the log to the db was wrong in three ways, all proven by mutation:
#
#   • only a scenario holding that db's path can read it. b_migration! works against a
#     second sandbox, so its call sites went unread and `rm -rf '${mighome}'` deleted the
#     evidence; a deliberately failing write there passed the suite 560-ok and exit 0.
#   • the abort-path reporter takes ONE db, so it could only ever speak for the sandbox it
#     was handed. A migdb error that aborted inside b_migration! printed a bare `FAIL
#     rename preserves planned session row` with the real cause unread — finding #1 again,
#     one sandbox over.
#   • a `sql!` against a MISTYPED path logged beside the db nobody reads (silent), and one
#     under a directory that does not exist could not even open the log, so the `2>`
#     redirect failed and NOTHING was recorded anywhere. The fixed path always exists, and
#     naming the db in the line is what makes a typo visible rather than invisible.
#
# Cwd-relative because the harness already runs from the repo root — b_migration! reads
# tests/fixtures/db/ the same way. Gitignored. Safe to share across drivers because they
# run sequentially and each resets it on entry.
sqlfail_log : Str
sqlfail_log = ".e2e-sqlfail"

# Truncate before the first fixture write of a run. The cleanup at the end of a scenario
# chain is skipped when a check aborts, so without this a log left by a previously FAILED
# run would fail every later run at a write that never happened — and a guard that cries
# wolf about someone else's run is a guard that gets deleted.
reset_sqlite_errors! : {} => {}
reset_sqlite_errors! = |{}| {
    _ = sh!("rm -f '${sqlfail_log}' '${sqlfail_log}.err'")
    {}
}

# sqlite3's own words for every fixture write that ERRORED in this run, or "" if none did.
#
# "errored", not "happened": a syntactically valid statement whose WHERE matches nothing
# exits 0 and is invisible here. That shape is real in this file — there are UPDATEs
# against config rows that may be absent — so the name says what an exit code can prove
# and no more.
sqlite_errors! : {} => Str
sqlite_errors! = |{}| Str.trim(sh!("cat '${sqlfail_log}' 2>/dev/null"))

# `check!` already printed sqlite3's words; this adds the one thing it cannot know, the
# sandbox HOME. An abort skips the `rm -rf`, so the whole database is still on disk — but
# in a `mktemp -d` directory whose path the harness otherwise never says out loud, which
# is what made the first version of this guard undebuggable even when it had recorded the
# cause. Only speaks when there IS a fixture error, so an ordinary assertion failure is
# not buried under paths nobody needs.
report_sandbox! : Str => {}
report_sandbox! = |home| {
    errs = sqlite_errors!({})
    say! = |line|
        match Stdout.line!(line) {
            Ok(_) => {}
            Err(_) => {}
        }
    if Str.is_empty(errs) {
        {}
    } else {
        say!("  ↳ sandbox kept for inspection: ${home}")
    }
}

# seed a constant-power stream (n 1 Hz samples at w watts) as Strava-style raw_json so an
# analyzed ride computes best_20min_w -> a derived per-sport FTP. Post-#26 FTP is derived
# from stream power (not config), so a power ride needs real streams to score. Inserted
# straight into the streams table via the heredoc sql! — the JSON's double-quotes sit fine
# inside the single-quoted SQL literal (no single quotes in the JSON to escape).
# a pace stream: time + CUMULATIVE distance at a constant speed (m/s), no altitude —
# the flat-triple path a swim or indoor row produces
# pace + HR stream: constant speed, HR drifting up in the second half — the shape
# pace decoupling (#134) exists to measure
seed_pace_hr_stream! : Str, I64, U64, U64 => {}
seed_pace_hr_stream! = |db, id, n, mps| {
    times = Str.join_with(List.map(int_seq(n), |i| U64.to_str(i)), ",")
    dist = Str.join_with(List.map(int_seq(n), |i| U64.to_str(i * mps)), ",")
    hr = Str.join_with(List.map(int_seq(n), |i| U64.to_str(if i * 2 < n 140 else 150)), ",")
    # flat measured altitude: real outdoor streams carry one, and only the
    # GRADE-ADJUSTED pace arm requires a graded triple. An altitude-less run
    # still gets a known drift — it is just labeled "speed" rather than pace,
    # so nobody reads terrain effects as grade-adjusted (activity 107 pins this)
    alt = Str.join_with(List.map(int_seq(n), |_| "100"), ",")
    raw = "{\"time\":{\"data\":[${times}]},\"distance\":{\"data\":[${dist}]},\"altitude\":{\"data\":[${alt}]},\"heartrate\":{\"data\":[${hr}]}}"
    _ = sql!(db, "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (${I64.to_str(id)}, '${raw}');")
    {}
}

seed_pace_stream! : Str, I64, U64, U64 => {}
seed_pace_stream! = |db, id, n, mps| {
    times = Str.join_with(List.map(int_seq(n), |i| U64.to_str(i)), ",")
    dist = Str.join_with(List.map(int_seq(n), |i| U64.to_str(i * mps)), ",")
    raw = "{\"time\":{\"data\":[${times}]},\"distance\":{\"data\":[${dist}]}}"
    _ = sql!(db, "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (${I64.to_str(id)}, '${raw}');")
    {}
}

seed_power_stream! : Str, I64, U64, U64 => {}
seed_power_stream! = |db, id, n, w| {
    times = Str.join_with(List.map(int_seq(n), |i| U64.to_str(i)), ",")
    watts = Str.join_with(List.map(int_seq(n), |_| U64.to_str(w)), ",")
    raw = "{\"time\":{\"data\":[${times}]},\"watts\":{\"data\":[${watts}]}}"
    _ = sql!(db, "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (${I64.to_str(id)}, '${raw}');")
    {}
}
# interval-shaped power stream: warmup, reps x (work_s @ work_w / rec_s @ rec_w), cooldown
seed_interval_stream! : Str, I64 => {}
seed_interval_stream! = |db, id| {
    wtt = |i| {
        # 300s warmup @120, 3x(180s @250 / 120s @100), then cooldown @110
        rel = if i >= 300 (i - 300) % 300 else 0
        if i < 300 120 else if i < 1200 (if rel < 180 250 else 100) else 110
    }
    n : U64
    n = 1500
    times = Str.join_with(List.map(int_seq(n), |i| U64.to_str(i)), ",")
    watts = Str.join_with(List.map(int_seq(n), |i| U64.to_str(wtt(i))), ",")
    raw = "{\"time\":{\"data\":[${times}]},\"watts\":{\"data\":[${watts}]}}"
    _ = sql!(db, "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (${I64.to_str(id)}, '${raw}');")
    {}
}
# [0, 1, .., n-1]
int_seq : U64 -> List(U64)
int_seq = |n| int_seq_go(n, [])
int_seq_go : U64, List(U64) -> List(U64)
int_seq_go = |n, acc| if n == 0 acc else int_seq_go(n - 1, List.prepend(acc, n - 1))

# a 1 Hz power stream as JSON for the mock endpoint: time 0..n-1, constant w watts, and a
# repeating HR sawtooth (120 + i%60, so 120–179 cycling every 60 s — enough for HR zones).
# n must be >= 1200 so best_20min_w (and thus the derived FTP) is computed — the http twin of
# seed_power_stream!. The old hardcoded 60-sample/30s stream was too sparse: resample_1s treats
# 30s gaps as pauses, leaving < 1200 samples, so the 20-min best never populated and TSS was 0.
mock_power_stream_json : U64, U64 -> Str
mock_power_stream_json = |n, w| {
    times = Str.join_with(List.map(int_seq(n), |i| U64.to_str(i)), ",")
    watts = Str.join_with(List.map(int_seq(n), |_| U64.to_str(w)), ",")
    hrs = Str.join_with(List.map(int_seq(n), |i| U64.to_str(120 + (i % 60))), ",")
    "{\"time\":{\"data\":[${times}]},\"watts\":{\"data\":[${watts}]},\"heartrate\":{\"data\":[${hrs}]}}"
}

stride! : Str, Str, List(Str) => Str
stride! = |bin, home, sargs|
    stride_env!(bin, home, sargs, [("STRIDE_FORMAT", "json")])

stride_human! : Str, Str, List(Str) => Str
stride_human! = |bin, home, sargs|
    stride_env!(bin, home, sargs, [("STRIDE_FORMAT", "human")])

stride_env! : Str, Str, List(Str), List((Str, Str)) => Str
stride_env! = |bin, home, sargs, extra| {
    base = Cmd.new(OsStr.from_str(bin))
        .args(List.map(sargs, OsStr.from_str))
        .env(OsStr.from_str("HOME"), OsStr.from_str(home))
    cmd = List.fold(extra, base, |c, pair| c.env(OsStr.from_str(pair.0), OsStr.from_str(pair.1)))
    # errors now exit non-zero (#163) and the platform surfaces that as
    # Err(NonZeroExitCode) — whose payload CARRIES the stdout we assert on. A
    # bare Err(_) => "" would blind every error-code check in this suite.
    match cmd.exec_output!() {
        Ok(o) => o.stdout_utf8
        Err(NonZeroExitCode(e)) => e.stdout_utf8_lossy
        Err(_) => ""
    }
}

# exit STATUS of a stride invocation (#163): 0 on success, 1 on any error
# envelope. Separate from the output helpers so a check can assert the process
# contract without re-deriving it from text.
# stride_status! cannot reach the mock — it sets only HOME and STRIDE_FORMAT — so no
# exit code has ever been asserted against a mock-backed run. This mirrors stride_env!'s
# extra-env fold so any driver can pin one.
stride_status_env! : Str, Str, List(Str), List((Str, Str)) => I32
stride_status_env! = |bin, home, sargs, extra| {
    base = Cmd.new(OsStr.from_str(bin))
        .args(List.map(sargs, OsStr.from_str))
        .env(OsStr.from_str("HOME"), OsStr.from_str(home))
    cmd = List.fold(extra, base, |c, pair| c.env(OsStr.from_str(pair.0), OsStr.from_str(pair.1)))
    match cmd.exec_output!() {
        Ok(_) => 0
        Err(NonZeroExitCode(e)) => e.exit_code
        Err(_) => -1
    }
}

stride_status! : Str, Str, List(Str) => I32
stride_status! = |bin, home, sargs| {
    cmd = Cmd.new(OsStr.from_str(bin))
        .args(List.map(sargs, OsStr.from_str))
        .env(OsStr.from_str("HOME"), OsStr.from_str(home))
        .env(OsStr.from_str("STRIDE_FORMAT"), OsStr.from_str("json"))
    match cmd.exec_output!() {
        Ok(_) => 0
        Err(NonZeroExitCode(e)) => e.exit_code
        Err(_) => -1
    }
}

# run `stride <args>` in json mode against the sandbox HOME and pipe stdout through
# a jq filter; returns the trimmed extracted field. Args are single-quoted for the
# shell (none of the test args contain a single quote); the filter is single-quoted
# too, so it may use double quotes freely (e.g. select(.sport=="Ride")).
strjq! : Ctx, List(Str), Str => Str
strjq! = |ctx, args, filter| {
    argstr = List.fold(args, "", |acc, a| "${acc} '${a}'")
    Str.trim(sh!("HOME='${ctx.home}' STRIDE_FORMAT=json '${ctx.bin}' ${argstr} | jq -r '${filter}' 2>/dev/null"))
}

seed_ride! : Str, Str, Str, Str, Str, Str, Str, Str => Str
seed_ride! = |db, id, name, date, secs, meters, watts, hr|
    sql!(db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,weighted_avg_watts,avg_watts,avg_hr) VALUES (${id},'${name}','Ride','${date}',${secs},${meters},${watts},${watts},${hr});")

# the 9999W-spike stream fixture (120 samples @200W, index 60 spiked), built by
# awk in the shell — NOT by a recursive Roc closure (that would trip roc#10469).
spike_json! : {} => Str
spike_json! = |{}|
    # 1300 samples (>= the 1200-sample best_20min_w window) so the ride derives an FTP
    # post-#26 (FTP now comes from stream power, not config); one 9999W spike at i=60 to
    # verify junk-power filtering. Baseline 200W -> best_20min_w 200 -> derived FTP 190.
    Str.trim(sh!("awk 'BEGIN{t=\"\";w=\"\";for(i=0;i<1300;i++){if(i>0){t=t\",\";w=w\",\"} t=t i; w=w (i==60?\"9999.0\":\"200.0\")} printf \"{\\\"time\\\":{\\\"data\\\":[%s]},\\\"watts\\\":{\\\"data\\\":[%s]}}\", t, w}'"))

# write the realistic Strava-export CSV (duplicate headers, quoted comma, junk row)
write_csv! : Str => Str
write_csv! = |dir| {
    h = "Activity ID,Activity Date,Activity Name,Activity Type,Elapsed Time,Distance,Relative Effort,Moving Time,Distance,Elevation Gain,Average Heart Rate,Average Watts,Weighted Average Power"
    r1 = "9001,\\\"Jul 1, 2025, 6:30:00 AM\\\",\\\"Morning ride, easy one\\\",Ride,3700,20.10,55,3600,20100.0,150,,180,190"
    r2 = "9002,\\\"Jul 2, 2025, 7:00:00 PM\\\",Evening Row,Rowing,1900,5.00,30,1800,5000.0,0,145,,"
    junk = "junk,not a date,Broken Row,Ride,x,y,z,q,w,e,r,t,y"
    # #201: an exponent in the ID imported as 700 on the widened stdlib, and
    # upsert_activity! is an UPSERT on that key -- it would overwrite whatever real
    # activity holds id 700. An exponent in the DATE stored start_local as
    # "2025-07-100T...", which every week filter compares as a STRING while
    # date_str_to_days normalises it to a different month. All four poison rows must be
    # skipped: exponent id, exponent day, exponent hour, exponent year.
    exp_id = "7e2,\\\"Jul 3, 2025, 6:00:00 AM\\\",Exp Id Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    # 1e1 (=10), NOT 1e2 (=100): a 100th day is calendar-invalid and would be rejected
    # whether or not the parse is narrowed, so it pinned nothing. Day 10 is valid, so
    # only the exponent refusal can keep this row out.
    exp_day = "9003,\\\"Jul 1e1, 2025, 6:00:00 AM\\\",Exp Day Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    exp_hour = "9004,\\\"Jul 3, 2025, 1e1:00:00 AM\\\",Exp Hour Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    # 2e3, not 1e3: 1000 is also caught by the 1900-2999 range check, so a revert of the
    # PARSE would still skip the row and the mutant would survive. 2000 is in range.
    exp_year = "9005,\\\"Jul 3, 2e3, 6:00:00 AM\\\",Exp Year Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    # plain digits, out of range: parsing is not enough, pad2 pads but never truncates,
    # so "Jul 100" stored 2025-07-100 and "25:00:00 PM" stored T37. Both imported clean
    # and then broke `season` with BadActivityDate.
    big_day = "9006,\\\"Jul 100, 2025, 6:00:00 AM\\\",Big Day Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    big_hour = "9007,\\\"Jul 3, 2025, 25:00:00 PM\\\",Big Hour Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    feb30 = "9008,\\\"Feb 30, 2025, 6:00:00 AM\\\",Feb30 Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    # minute and second were interpolated verbatim -- never parsed, never bounded
    exp_min = "9009,\\\"Jul 3, 2025, 6:1e1:00 AM\\\",Exp Min Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    big_sec = "9010,\\\"Jul 3, 2025, 6:00:99 AM\\\",Big Sec Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    # 1e1 (=10) is an IN-RANGE second, so only the exponent refusal can reject it --
    # 6:00:99 above pins the range check instead, and pinned nothing about the parse.
    exp_sec = "9012,\\\"Jul 3, 2025, 6:00:1e1 AM\\\",Exp Sec Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    # a large plain-digit hour used to overflow U64 in the +12 and CRASH the import
    ovf_hour = "9011,\\\"Jul 3, 2025, 18446744073709551615:00:00 PM\\\",Overflow Probe,Ride,3600,10.00,20,3600,10000.0,0,140,,"
    sh!("mkdir -p '${dir}' && printf '%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n' \"${h}\" \"${r1}\" \"${r2}\" \"${junk}\" \"${exp_id}\" \"${exp_day}\" \"${exp_hour}\" \"${exp_year}\" \"${big_day}\" \"${big_hour}\" \"${feb30}\" \"${exp_min}\" \"${big_sec}\" \"${ovf_hour}\" \"${exp_sec}\" > '${dir}/activities.csv'")
}

sfloat : Str -> F64
sfloat = |s| F64.from_str(Str.trim(s)).ok_or(0.0)

str_to_i64 : Str -> I64
str_to_i64 = |s| I64.from_str(Str.trim(s)).ok_or(0)

is_nonempty : Str -> Bool
is_nonempty = |s| !(Str.is_empty(Str.trim(s))) and Str.trim(s) != "null"

# print a check result; abort the run on the first failure
#
# #226: the failing check is where a botched fixture write SURFACES, so it is where the
# real cause has to be printed. Reporting here rather than in each driver's Err path is
# what makes the run-scoped log worth having: `check!` knows no db and no HOME, and with
# one fixed path it does not need to — so every driver, including run_sync! and any added
# later, gets the report without its own wrapper.
# ONE line per check that PASSED — check! appends inside the success branch, and a failing
# check aborts the driver anyway. So a driver can assert it ran the checks it contains.
#
# Costs a subprocess per assertion: measured at ~12ms each, +15% on the offline suite
# (44s -> 50s). Accepted rather than optimised, because it caught a real silent-coverage
# bug and the suite is not on anyone's critical path. If it ever is, check! already prints
# one `  ok   ` line per pass, so the same population is countable without a spawn.
# A whole `else if` branch went dead in this file — a duplicated fragment made an EMPTY
# branch match first — and its six assertions silently stopped running while the driver
# still printed PASS and exited 0. Nothing observed that, because every other guard here
# asserts on VALUES, and a check that never runs has no value to be wrong. Counting is
# the only thing that catches it IN THIS SHAPE. `if/else if` on a Bool gets no redundancy
# analysis from the compiler; the same dispatch written as a `match` on a tag would have
# been a build-failing warning. Worth restructuring if this file grows another scenario.
# PER PROCESS, not a fixed path. `sh` is a child of this binary, so $PPID inside the
# script is this driver's own pid — each e2e invocation gets its own tally with no env
# plumbing. A shared path was worse than no guard: two drivers in one checkout inflate
# each other's counts, so a driver whose branch had gone dead PASSED its floor; and a
# second driver's reset wipes the first's tally mid-run, producing a false red that looks
# exactly like a real regression. Review reproduced both with nothing artificial, and the
# false-red construction explains failures previously blamed on port collisions.
checks_log! : {} => Str
checks_log! = |{}| ".e2e-checks.${env_or!("E2E_MODE", "e2e")}"

# Fails LOUDLY. sh! swallows exit codes, and a reset that silently does not happen leaves
# a stale tally that makes the floor pass for a driver that ran nothing — the guard
# failing in the one direction it exists to prevent. So verify the file is gone.
reset_checks! : {} => Try({}, _)
reset_checks! = |{}| {
    _ = sh!("rm -f ${checks_log!({})}")
    left = Str.trim(sh!("wc -l 2>/dev/null < ${checks_log!({})} || echo 0"))
    if left == "0" {
        Ok({})
    } else {
        Stdout.line!("  FAIL could not reset the check tally — the floor guard would be meaningless")?
        Err(CheckFailed("could not reset the check tally"))
    }
}

# A floor, NOT an exact count — and note the comparison is `>=`, so setting one to today's
# count does not make it exact: adding checks never fails it, so a number set to the real
# count quietly drifts back into slack the first time someone adds without bumping. But it
# must be TIGHT — the first cut
# set run_all to 400 against 564 actual, so 164 checks could vanish silently, and the stops
# budget branch could lose SIX, the same magnitude as the dead branch that motivated this.
# A tight floor only needs touching when checks are REMOVED, which is exactly the event
# that should force a conversation. run_all uses checks_ran_exactly! instead, for the reason
# recorded on that function — a floor set to an exact count is not enforced as exact, and
# quietly stops being one. The mock drivers keep floors: skips and stops sit just under
# their smallest real run, while run_sync is set to its current count, which makes it tight
# rather than enforced. That is deliberate for now — the failure this guard exists for is
# silent REMOVAL, which a tight floor catches, and moving a fourth driver onto the exact
# gate is a change to shared tally semantics that belongs in its own PR rather than one
# about a drain cap. A tight floor does cost something: with no margin a single lost tally
# append — check!'s `echo x >>` going missing under sh!'s swallowed exit code, the failure
# mode documented above — reddens the run instead of being absorbed. Loud is the right
# default for a guard, but it is a behaviour change rather than a free tightening.
#
# A driver that forgets reset_checks! or this call gets NO guard, silently — the same
# hazard the sqlite failure log carries, and documents.
checks_ran_at_least! : I64 => Try({}, _)
checks_ran_at_least! = |floor| {
    ran = str_to_i64(Str.trim(sh!("wc -l 2>/dev/null < ${checks_log!({})} || echo 0")))
    check!("this driver ran its checks (${I64.to_str(ran)} >= ${I64.to_str(floor)})", ran >= floor)
}

# The EXACT variant, for a driver whose count is meant to be pinned rather than floored.
#
# A tight `>=` floor is not the same thing as an exact one, and the difference is invisible
# until it matters: `>=` never fails on a check ADDED, so a driver set to its exact count
# drifts back into slack the first time someone adds checks without bumping the number, and
# nothing says so. Review demonstrated it on this very file — two checks added against a
# floor of 595 ran 597 and passed. That is the same silent decay a slack floor has, arriving
# by a slower road.
#
# `==` costs a deliberate bump on every added check. That is the objection the note above
# records, and it is real — but a forgotten bump FAILS THE RUN, where decay is silent. The
# cost is enforced, not merely visible, and the distinction matters: this branch bumped the
# number in every one of its six commits and no review round ever checked it against the
# checks actually added. Relying on someone reading the diff was the weaker argument, and
# the evidence against it is this file's own history.
checks_ran_exactly! : I64 => Try({}, _)
checks_ran_exactly! = |expected| {
    ran = str_to_i64(Str.trim(sh!("wc -l 2>/dev/null < ${checks_log!({})} || echo 0")))
    check!("this driver ran exactly its checks (${I64.to_str(ran)} == ${I64.to_str(expected)})", ran == expected)
}

check! : Str, Bool => Try({}, _)
check! = |name, cond|
    if cond {
        _ = sh!("echo x >> ${checks_log!({})}")
        Stdout.line!("  ok   ${name}")
    } else {
        Stdout.line!("  FAIL ${name}")?
        errs = sqlite_errors!({})
        _ =
            if Str.is_empty(errs) {
                Ok({})
            } else {
                Stdout.line!("  ↳ a fixture write ERRORED during this run — likely the real cause:\n${errs}")
            }
        Err(CheckFailed(name))
    }

# float check with tolerance (floats have no Eq)
check_near! : Str, F64, F64, F64 => Try({}, _)
check_near! = |name, got, want, tol|
    check!(name, (got - want).abs() < tol)
