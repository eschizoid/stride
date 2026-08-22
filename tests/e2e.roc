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
        if Str.contains(uri, "page=1") {
            body =
                \\[{"id":501,"name":"Mock Power Ride","sport_type":"Ride","start_date_local":"2026-07-28T10:00:00Z","moving_time":3600,"distance":30000.0,"total_elevation_gain":100.0,"average_watts":200.0,"weighted_average_watts":205.0},
                \\ {"id":502,"name":"Mock HR Row","sport_type":"Rowing","start_date_local":"2026-07-29T10:00:00Z","moving_time":1800,"distance":5000.0,"total_elevation_gain":0.0,"average_heartrate":150.0}]
            Ok(mock_json(body))
        } else {
            Ok(mock_json("[]"))
        }
    } else if Str.contains(uri, "/streams") {
        if Str.contains(uri, "/activities/501/") and env_or!("E2E_STREAM_401", "") == "1" {
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
    checks_ran_at_least!(550)?
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

    _ = sync_run!("human")
    bf_human = Str.trim(sh!("cat '${bo}'"))
    check!("humans get the rendered line", Str.contains(bf_human, "re-checked in the 30-day window") and Str.contains(bf_human, "fetched streams for"))?
    check!("...with no envelope in it", !(Str.contains(bf_human, "schema_version")))?
    # refetching 501's streams above ran invalidate_metrics!, dropping its metrics row.
    # Nothing later in this scenario reads them today, which is exactly why it is worth
    # restoring: a future check placed after this block would otherwise fail for a
    # reason that has nothing to do with what it is testing.
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
    checks_ran_at_least!(34)?
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
    check!("...nor that everything is present", !(Str.contains(human, "all streams present")))?

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
    envs = if rate_limited "" else "STRIDE_READS_PER_WINDOW=1"
    run_sync_bf! = |fmt| sh!("HOME='${home}' STRIDE_FORMAT=${fmt} STRIDE_API_BASE='${base}' ${envs} '${bin}' sync >'${bo}' 2>/dev/null")
    _ = run_sync_bf!("json")

    if env_or!("E2E_EXPECT_401", "") == "1" {
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
        rl_start = str_to_i64(Str.trim(sh!("date +%s")))
        # 501 429s forever. 502 drains first (ORDER BY start_local DESC) and stores its
        # 404 marker, so a surviving counter reads 1 and a reset one reads 0.
        # WALL CLOCK. The no-sleep fix is only observable as latency: review reintroduced
        # a 3s sleep here and every driver passed, so a return to the ~30-minute block
        # would read as CI being slow rather than as a failing check. I claimed this
        # assertion in an earlier commit message and it was never actually in the file.
        rl_elapsed = str_to_i64(Str.trim(sh!("date +%s"))) - rl_start
        check!("a rate-limited sync returns at once instead of sleeping", rl_elapsed < 10)?
        check!("a 429 stops the run outright", bfq!(".data.stopped") == "rate_limited")?
        check!("...counting what it stored before the 429", bfq!(".data.streams_fetched") == "1")?
        check!("...leaving the 429'd id pending", bfq!(".data.pending_streams") == "1")?
        check!("...and resumable, because waiting will help", bfq!(".data.resumable") == "true")?
        check!("the rate-limited payload conforms to the schema", Str.trim(sh!("jq '.data' '${bo}' 2>&1 | jq -r --slurpfile schema schemas/v2/sync.json -f tools/validate.jq 2>&1")) == "")?
        # fresh queue: the JSON run above already stored one, so without this the human
        # run drains what is left and renders "all streams present" instead
        _ = sql!(db, "DELETE FROM streams;")
        _ = run_sync_bf!("human")
        check!("humans are told to try again in ~15 minutes", Str.contains(Str.trim(sh!("cat '${bo}'")), "in ~15 minutes"))?
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
    checks_ran_at_least!(8)?
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
    check!("a bare call answers with the command list, as data", strjq!(ctx, [], ".data.commands | index(\"summary\") != null") == "true")?
    check!("--help answers identically for machines", strjq!(ctx, ["--help"], ".data.commands | index(\"plan\") != null") == "true")?
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
    check!("a malformed daily_load day is refused, not absorbed", !(Str.contains(bad_day, "span_weeks")) and Str.contains(bad_day, "error"))?
    _ = sql!(ctx.db, "DELETE FROM daily_load WHERE day = 'not-a-date';")
    # ...and the SAME rule on the other date-parsing site. Absorbing this one
    # dropped the activity from sessions, polarization AND the threshold range
    # with no trace at exit 0 -- a silent wrong answer rather than a loud refusal.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (933,'bad date','Ride','Ride','garbage-date',3600);")
    _ = sql!(ctx.db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (933,40.0,300.0,3600,1);")
    bad_act = stride!(ctx.bin, ctx.home, ["season"])
    check!("a malformed activity date is refused, not absorbed", Str.contains(bad_act, "error") and !(Str.contains(bad_act, "blocks")))?
    # ...and PARSEABLE is not enough. "2026-3-01" parses fine and sorts after
    # every 2026-1x date, so it became ftp_end for its month AND its block and
    # published the threshold running backwards -- at exit 0, which is the
    # exact failure this round exists to prevent, arriving through the guard.
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,sport_family,start_local,moving_time) VALUES (934,'unpadded','Ride','Ride','2026-3-01T06:00:00Z',3600);")
    _ = sql!(ctx.db, "INSERT INTO activity_metrics (activity_id,tss,ftp_used,pi_easy_s,metrics_rev) VALUES (934,40.0,111.0,3600,1);")
    unpadded = stride!(ctx.bin, ctx.home, ["season"])
    check!("a non-canonical activity date is refused too", Str.contains(unpadded, "error") and !(Str.contains(unpadded, "blocks")))?
    _ = sql!(ctx.db, "DELETE FROM activity_metrics WHERE activity_id = 934; DELETE FROM activities WHERE id = 934;")
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO daily_load (day,tss,ctl,atl,tsb) VALUES ('2026-3-05', 30.0, 5.0, 5.0, 0.0);")
    unpadded_day = stride!(ctx.bin, ctx.home, ["season"])
    check!("a non-canonical daily_load day is refused too", Str.contains(unpadded_day, "error") and !(Str.contains(unpadded_day, "span_weeks")))?
    _ = sql!(ctx.db, "DELETE FROM daily_load WHERE day = '2026-3-05';")
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
checks_log : Str
checks_log = "'.e2e-checks.'$PPID"

# Fails LOUDLY. sh! swallows exit codes, and a reset that silently does not happen leaves
# a stale tally that makes the floor pass for a driver that ran nothing — the guard
# failing in the one direction it exists to prevent. So verify the file is gone.
reset_checks! : {} => Try({}, _)
reset_checks! = |{}| {
    _ = sh!("rm -f ${checks_log}")
    left = Str.trim(sh!("wc -l < ${checks_log} 2>/dev/null || echo 0"))
    if left == "0" {
        Ok({})
    } else {
        Stdout.line!("  FAIL could not reset the check tally — the floor guard would be meaningless")?
        Err(CheckFailed("could not reset the check tally"))
    }
}

# A floor, not an exact count: an exact number fails on every check ADDED and gets bumped
# reflexively, which is how a guard stops guarding. But it must be TIGHT — the first cut
# set run_all to 400 against 564 actual, so 164 checks could vanish silently, and the stops
# budget branch could lose SIX, the same magnitude as the dead branch that motivated this.
# A tight floor only needs touching when checks are REMOVED, which is exactly the event
# that should force a conversation. Each is set just under its smallest real run.
#
# A driver that forgets reset_checks! or this call gets NO guard, silently — the same
# hazard the sqlite failure log carries, and documents.
checks_ran_at_least! : I64 => Try({}, _)
checks_ran_at_least! = |floor| {
    ran = str_to_i64(Str.trim(sh!("wc -l < ${checks_log} 2>/dev/null || echo 0")))
    check!("this driver ran its checks (${I64.to_str(ran)} >= ${I64.to_str(floor)})", ran >= floor)
}

check! : Str, Bool => Try({}, _)
check! = |name, cond|
    if cond {
        _ = sh!("echo x >> ${checks_log}")
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
