app [Context, program] {
    pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.15.0/HcMFsVT26qeMvqWtG5rfNhVMWjceYbKh1An4uYpheBVW.tar.zst",
    http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

# The whole native-Roc test harness in ONE basic-webserver app. `E2E_MODE` picks a role:
#   • (default / "e2e") run the ~140-check offline suite in init!, then exit
#   • "sync"            drive the real sync path (token refresh + activity/stream pull)
#                       against a running mock, then exit
#   • "mock"            serve the four Strava endpoints the sync test hits, and listen
# One binary, three roles — `just e2e` runs the offline suite; `just e2e-sync` starts a
# mock instance and points a sync-driver instance at it.
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
# WHY basic-webserver (not basic-cli): the offline suite fires ~350 subprocess spawns.
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

Ctx : { bin : Str, home : Str, db : Str, today : Str, d1 : Str, d2 : Str }

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
        body =
            \\{"access_token":"mock-access","refresh_token":"mock-refresh","expires_at":9999999999}
        Ok(mock_json(body))
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
        if Str.contains(uri, "/activities/501/") {
            # a realistic 1 Hz stream (1300 samples, constant 200W, HR sawtooth 120–179): long enough that
            # best_20min_w -> derived FTP 190 -> TSS ~110.8. See mock_power_stream_json.
            Ok(mock_json(mock_power_stream_json(1300, 200)))
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

shutdown! : Server.ShutdownReason, Context => Try({}, [Exit(I64), ..])
shutdown! = |_reason, _ctx| Ok({})

run_all! : () => Try({}, _)
run_all! = || {
    bin = env_or!("STRIDE_BIN", "./stride")
    home = need("mktemp -d", Str.trim(sh!("mktemp -d")))?
    today = need("date +%F", Str.trim(sh!("date -u +%F")))?
    d1 = need("date -3d", Str.trim(sh!("date -u -v-3d +%F 2>/dev/null || date -u -d '3 days ago' +%F")))?
    d2 = need("date -1d", Str.trim(sh!("date -u -v-1d +%F 2>/dev/null || date -u -d '1 day ago' +%F")))?
    ctx = { bin, home, db: "${home}/.stride/db.sqlite", today, d1, d2 }
    b_init_config!(ctx)?
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
    b_doctor!(ctx)?
    b_device_watts!(ctx)?
    b_human!(ctx)?
    b_concurrency!(ctx)?
    b_migration!(ctx)?
    _ = sh!("rm -rf '${home}'")
    Stdout.line!("ALL E2E CHECKS PASS")
}

# ── sync mode: drive the real sync path against a running mock (a sibling instance
# started with E2E_MODE=mock). Seeds an EXPIRED token so sync must refresh first,
# then asserts token refresh + activity/stream pull. Mirrors old tests/e2e_sync.sh.
# TSS uses each sport's DERIVED FTP — no ftp_<sport> key is set, because setting one is
# refused. The power Ride (501) scores from its own stream; the HR-only Rowing row (502)
# has no power, so it falls to HR. ───────────────────────────────────────────────────
run_sync! : () => Try({}, _)
run_sync! = || {
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

    _ = sh!("rm -rf '${home}'")
    Stdout.line!("SYNC E2E CHECKS PASS")
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
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "hr_z1_max", "123"])
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "hr_z2_max", "153"])
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "hr_z3_max", "168"])
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "hr_z4_max", "183"])
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
# power history, never configured); everything else round-trips. ──────────────────────
b_config_ftp! : Ctx => Try({}, _)
b_config_ftp! = |ctx| {
    # FTP is DERIVED (ADR 0005): setting it must be refused, not silently stored. This block
    # used to assert the opposite — that `config set ftp_ride 195` reported "ftp_ride = 195"
    # — which is exactly the trap: a confirmation for a value the engine never reads.
    set_out = stride!(ctx.bin, ctx.home, ["config", "set", "ftp_ride", "195"])
    check!("setting a derived key is refused", Str.contains(set_out, "derived_key"))?
    check!("refusal explains where FTP comes from", Str.contains(set_out, "power history"))?
    check!("reading a derived key is refused too", Str.contains(stride!(ctx.bin, ctx.home, ["config", "get", "ftp_ride"]), "derived_key"))?

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
    check!("config set emits the JSON envelope", strjq!(ctx, ["config", "set", "timezone", "America/Chicago"], ".data.value") == "America/Chicago")?
    check!("config set human line", Str.contains(stride_human!(ctx.bin, ctx.home, ["config", "set", "timezone", "America/Chicago"]), "timezone = America/Chicago"))?
    check!("value stored + read back (human)", Str.trim(stride_human!(ctx.bin, ctx.home, ["config", "get", "timezone"])) == "America/Chicago")?
    check!("config get json value", strjq!(ctx, ["config", "get", "timezone"], ".data.value") == "America/Chicago")?
    check!("config get not_set error", Str.contains(stride!(ctx.bin, ctx.home, ["config", "get", "nope"]), "not_set"))?
    # delete the row rather than storing "" — an empty value is a stored-but-invalid
    # timezone, not an absent one, and doctor treats those differently
    _ = sql!(ctx.db, "DELETE FROM config WHERE key='timezone';")
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
    # FTP is derived from stream power, not config, so a summary-watts-only ride scores 0.
    _ = seed_power_stream!(ctx.db, 101, 3600, 200)
    # first analyze converges the derived FTP: pass 1 scores both rows (best_20min_w still 0
    # -> FTP 0), pass 2 recomputes the ride once its best_20min_w resolves FTP to 190: 2+1=3
    check!("analyze computes 3 (derived-FTP convergence)", strjq!(ctx, ["analyze"], ".data.computed") == "3")?
    check!("summary as_of is today", strjq!(ctx, ["summary"], ".data.as_of") == ctx.today)?
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
    check!("form_delta_known is false on a short history", strjq!(ctx, ["summary"], ".data.form_delta_known") == "false")?
    # #123: the verdict NAMES the state and stops prescribing. Asserting the absence of the
    # old advice AND the presence of the label, so it cannot pass by the line disappearing.
    check!("form_band_days is a number", strjq!(ctx, ["summary"], ".data.form_band_days | type") == "number")?
    summary_verdict = stride_human!(ctx.bin, ctx.home, ["summary"])
    check!("the verdict still names the state", Str.contains(summary_verdict, "form "))?
    check!("...and no longer prescribes training", !(Str.contains(summary_verdict, "favor easy work")) and !(Str.contains(summary_verdict, "good day for")))?
    check_near!("...and the delta itself is an honest 0", sfloat(strjq!(ctx, ["summary"], ".data.form_delta_7d")), 0.0, 0.001)?
    # and the human line must NOT claim a trend it does not have
    summary_h = stride_human!(ctx.bin, ctx.home, ["summary"])
    check!("human verdict still prints the form line", Str.contains(summary_h, "form "))?
    check!("...but omits the week-ago clause when unknown", !(Str.contains(summary_h, "week ago")))?
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
    check!("complete nonexistent activity", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "2", "88888"]), "activity_not_found"))?
    check!("skip nonexistent session", Str.contains(stride!(ctx.bin, ctx.home, ["skip", "999", "x"]), "session_not_found"))?
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
    _ = stride!(ctx.bin, ctx.home, ["complete", early_id, "101"])
    date_101 = Str.trim(sql!(ctx.db, "SELECT substr(start_local,1,10) FROM activities WHERE id=101;"))
    # The control has to be an ON-TIME session checked BY ID. Asserting the output merely
    # contains "│ done " is a false positive: it is a prefix of "│ done (Fri ...", so the
    # check passed even when every row carried a date.
    _ = sql!(ctx.db, "INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status) VALUES ('0','${date_101}','endurance','same day ride','r','open');")
    ontime_id = Str.trim(sql!(ctx.db, "SELECT MAX(id) FROM planned_sessions;"))
    _ = stride!(ctx.bin, ctx.home, ["complete", ontime_id, "101"])
    ontime_status = strjq!(ctx, ["week", "all"], ".data[] | select(.id==${ontime_id}) | .status_shown")
    early_status = strjq!(ctx, ["week", "all"], ".data[] | select(.id==${early_id}) | .status_shown")
    # Every assertion selects its OWN row by id. Matching the whole plan output for
    # "done (" proved nothing: session 2 is completed with activity 101 earlier in this
    # scenario, so that string is already present regardless of what this row renders.
    check!("an on-time session renders exactly done", ontime_status == "done")?
    check!("the early one carries its real completion date", Str.starts_with(early_status, "done (") and Str.contains(early_status, date_101))?
    _ = sql!(ctx.db, "DELETE FROM planned_sessions WHERE id = ${ontime_id};")
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
b_import! : Ctx => Try({}, _)
b_import! = |ctx| {
    expdir = Str.trim(sh!("mktemp -d"))
    _ = write_csv!(expdir)
    imp = stride!(ctx.bin, ctx.home, ["import", expdir])
    check!("import 2 + skip 1", Str.contains(imp, "\"imported\":2") and Str.contains(imp, "\"skipped\":1"))?
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
    powr = strjq!(ctx, ["doctor"], "[.data.scored_by[] | select(.model==\"power_stream\" or .model==\"weighted_watts\" or .model==\"avg_watts\") | .n] | add // 0")
    check!("conf_high == power-rung provenance", ch == powr)?
    check!("doctor reports sports with a DERIVED ftp", sfloat(strjq!(ctx, ["doctor"], ".data.ftp_derived_sports")) >= 1.0)?
    check!("doctor zones_set true", strjq!(ctx, ["doctor"], ".data.zones_set") == "true")?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "timezone", "America/Chicago"])
    check!("valid tz time_ok", strjq!(ctx, ["doctor"], ".data.time_ok") == "true")?
    dtime = strjq!(ctx, ["doctor"], ".data.time")
    check!("valid tz is DST-aware Chicago", Str.contains(dtime, "America/Chicago") and Str.contains(dtime, "DST-aware"))?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "timezone", "Not/ARealZone"])
    check!("bad tz not ok", strjq!(ctx, ["doctor"], ".data.time_ok") == "false")?
    check!("bad tz shows UNKNOWN", Str.contains(strjq!(ctx, ["doctor"], ".data.time"), "UNKNOWN"))?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "timezone", ""])
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
    # STRIDE_FORMAT is pinned because this bypasses the stride! helper, which sets it. The
    # mode otherwise depends on CLAUDECODE being set in the developer's shell, so this
    # passed locally and failed on CI, where the human table has no schema_version.
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
    _ = sh!("mkdir -p '${mighome}/.stride' && sqlite3 '${migdb}' < tests/fixtures/db/v1-legacy.sql")
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

sh! : Str => Str
sh! = |script|
    match Cmd.new(OsStr.from_str("sh")).args(List.map(["-c", script], OsStr.from_str)).exec_output!() {
        Ok(o) => o.stdout_utf8
        Err(_) => ""
    }

# run SQL against the db. The query is fed via a quoted heredoc so it can contain
# BOTH single quotes (SQL string literals) and double quotes (e.g. embedded JSON
# stream fixtures) without any shell-quoting breakage.
sql! : Str, Str => Str
sql! = |db, query|
    sh!("sqlite3 '${db}' <<'SQLHEREDOC'\n${query}\nSQLHEREDOC")

# seed a constant-power stream (n 1 Hz samples at w watts) as Strava-style raw_json so an
# analyzed ride computes best_20min_w -> a derived per-sport FTP. Post-#26 FTP is derived
# from stream power (not config), so a power ride needs real streams to score. Inserted
# straight into the streams table via the heredoc sql! — the JSON's double-quotes sit fine
# inside the single-quoted SQL literal (no single quotes in the JSON to escape).
# a pace stream: time + CUMULATIVE distance at a constant speed (m/s), no altitude —
# the flat-triple path a swim or indoor row produces
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
    match cmd.exec_output!() {
        Ok(o) => o.stdout_utf8
        Err(_) => ""
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
    sh!("mkdir -p '${dir}' && printf '%s\\n%s\\n%s\\n%s\\n' \"${h}\" \"${r1}\" \"${r2}\" \"${junk}\" > '${dir}/activities.csv'")
}

sfloat : Str -> F64
sfloat = |s| F64.from_str(Str.trim(s)).ok_or(0.0)

str_to_i64 : Str -> I64
str_to_i64 = |s| I64.from_str(Str.trim(s)).ok_or(0)

is_nonempty : Str -> Bool
is_nonempty = |s| !(Str.is_empty(Str.trim(s))) and Str.trim(s) != "null"

# print a check result; abort the run on the first failure
check! : Str, Bool => Try({}, _)
check! = |name, cond|
    if cond {
        Stdout.line!("  ok   ${name}")
    } else {
        Stdout.line!("  FAIL ${name}")?
        Err(CheckFailed(name))
    }

# float check with tolerance (floats have no Eq)
check_near! : Str, F64, F64, F64 => Try({}, _)
check_near! = |name, got, want, tol|
    check!(name, (got - want).abs() < tol)
