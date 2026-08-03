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
# Binary under test: $STRIDE_BIN (default ./stride). Mirrors the old tests/e2e.sh +
# tests/e2e_sync.sh assertion-for-assertion: grep-style checks -> Str.contains on raw
# output; python numeric/structural asserts -> jq field extraction + Roc comparison.

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
            # 60 samples, 30s apart: constant 200W, HR ramp — enough for NP + zones
            body =
                \\{"time":{"data":[0,30,60,90,120,150,180,210,240,270,300,330,360,390,420,450,480,510,540,570,600,630,660,690,720,750,780,810,840,870,900,930,960,990,1020,1050,1080,1110,1140,1170,1200,1230,1260,1290,1320,1350,1380,1410,1440,1470,1500,1530,1560,1590,1620,1650,1680,1710,1740,1770]},"watts":{"data":[200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200,200]},"heartrate":{"data":[120,121,122,123,124,125,126,127,128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,176,177,178,179]}}
            Ok(mock_json(body))
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
    b_pz!(ctx)?
    b_config_ftp!(ctx)?
    b_cred_safety!(ctx)?
    b_seed_analyze!(ctx)?
    b_invalidation!(ctx)?
    b_plan!(ctx)?
    b_activities!(ctx)?
    b_top!(ctx)?
    b_load_stats!(ctx)?
    b_activity_detail!(ctx)?
    b_junk_filter!(ctx)?
    b_progress_a!(ctx)?
    b_progress_b!(ctx)?
    b_import!(ctx)?
    b_rpe!(ctx)?
    b_compare!(ctx)?
    b_doctor!(ctx)?
    b_human!(ctx)?
    b_migration!(ctx)?
    _ = sh!("rm -rf '${home}'")
    Stdout.line!("ALL E2E CHECKS PASS")
}

# ── sync mode: drive the real sync path against a running mock (a sibling instance
# started with E2E_MODE=mock). Seeds an EXPIRED token so sync must refresh first,
# then asserts token refresh + activity/stream pull. Mirrors old tests/e2e_sync.sh.
# TSS reads the per-sport ftp_<sport> key, not the legacy bare `ftp` — the power Ride
# (501) scores via ftp_ride. ftp_rowing is seeded too for completeness; the HR-only
# Rowing row (502) scores from HR, not power. ────────────────────────────────────────
run_sync! : () => Try({}, _)
run_sync! = || {
    bin = env_or!("STRIDE_BIN", "./stride")
    base = env_or!("STRIDE_API_BASE", "http://127.0.0.1:8799")
    home = need("mktemp -d", Str.trim(sh!("mktemp -d")))?
    db = "${home}/.stride/db.sqlite"

    _ = wait_ready!(base, 50)
    check!("mock strava came up on ${base}", mock_up!(base))?

    _ = sync_stride!(bin, home, base, ["init"])
    _ = sync_stride!(bin, home, base, ["config", "set", "ftp_ride", "200"])
    _ = sync_stride!(bin, home, base, ["config", "set", "ftp_rowing", "200"])
    _ = sync_stride!(bin, home, base, ["config", "set", "hr_z1_max", "123"])
    _ = sync_stride!(bin, home, base, ["config", "set", "hr_z2_max", "153"])
    _ = sync_stride!(bin, home, base, ["config", "set", "hr_z3_max", "168"])
    _ = sync_stride!(bin, home, base, ["config", "set", "hr_z4_max", "183"])

    _ = sql!(db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_client_id','1'),('strava_client_secret','shh'),('strava_access_token','stale-access'),('strava_refresh_token','stale-refresh'),('strava_expires_at','1');")

    _ = sync_stride!(bin, home, base, ["sync"])
    tok = Str.trim(sql!(db, "SELECT value FROM config WHERE key='strava_access_token';"))
    check!("expired token refreshed via /oauth/token (stale-access -> mock-access)", tok == "mock-access")?

    _ = sync_stride!(bin, home, base, ["analyze"])
    check!("2 mock activities synced", sync_strjq!(bin, home, base, ["activities"], ".data | length") == "2")?
    # 501's mock streams are a constant 200W; NP 200 @ ftp_ride 200 => TSS ~100 for the
    # hour. Pin the exact value (not just >0) so the whole stream->NP->TSS path is checked.
    check_near!("501 power streams score ~100 TSS (NP200 @ FTP200)", sfloat(sync_strjq!(bin, home, base, ["activity", "501"], ".data.tss")), 100.0, 1.0)?

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
    check!("summary envelope is versioned", strjq!(ctx, ["summary"], ".schema_version") == "1")?
    check!("missing-config error code", Str.contains(stride!(ctx.bin, ctx.home, ["summary"]), "missing_config"))?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "ftp_ride", "200"])
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

# ── power zones: watt ranges derived from FTP (200) ──────────────────
b_pz! : Ctx => Try({}, _)
b_pz! = |ctx| {
    check!("pz has 7 power zones", strjq!(ctx, ["pz"], ".data.zones | length") == "7")?
    check_near!("pz z4 lo ~182", sfloat(strjq!(ctx, ["pz"], ".data.zones[3].lo_w")), 182.0, 1.0)?
    check_near!("pz z4 hi ~210", sfloat(strjq!(ctx, ["pz"], ".data.zones[3].hi_w")), 210.0, 1.0)?
    check!("pz z1 opens at 0", strjq!(ctx, ["pz"], ".data.zones[0].lo_w") == "0")?
    check!("pz z7 open above (hi 0)", strjq!(ctx, ["pz"], ".data.zones[6].hi_w") == "0")?
    Ok({})
}

# ── config set ftp_ride: local store + graceful unauthed Strava sync ──
b_config_ftp! : Ctx => Try({}, _)
b_config_ftp! = |ctx| {
    set_out = stride!(ctx.bin, ctx.home, ["config", "set", "ftp_ride", "195"])
    check!("config set reports local value", Str.contains(set_out, "ftp_ride = 195"))?
    check!("unauthed ftp set warns about Strava", Str.contains(set_out, "not synced to Strava"))?
    check!("ftp stored even without Strava sync", Str.trim(stride_human!(ctx.bin, ctx.home, ["config", "get", "ftp_ride"])) == "195")?
    check!("config get json value", strjq!(ctx, ["config", "get", "ftp_ride"], ".data.value") == "195")?
    check!("config get not_set error", Str.contains(stride!(ctx.bin, ctx.home, ["config", "get", "nope"]), "not_set"))?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "ftp_ride", "200"])
    Ok({})
}

# ── credential safety: secrets never surface, db is owner-only ────────
b_cred_safety! : Ctx => Try({}, _)
b_cred_safety! = |ctx| {
    _ = sql!(ctx.db, "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_access_token','SECRETVAL123');")
    sec_out = stride!(ctx.bin, ctx.home, ["config", "get", "strava_access_token"])
    check!("secret key reports redacted", Str.contains(sec_out, "\"redacted\":true"))?
    check!("secret VALUE never appears", !(Str.contains(sec_out, "SECRETVAL123")))?
    perms = Str.trim(sh!("stat -c '%a' '${ctx.db}' 2>/dev/null || stat -f '%Lp' '${ctx.db}' 2>/dev/null"))
    check!("db is chmod 600", perms == "600")?
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "ftp_ride", "200"])
    Ok({})
}

# ── seed + analyze: TSS ladder + daily_load to today ─────────────────
b_seed_analyze! : Ctx => Try({}, _)
b_seed_analyze! = |ctx| {
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,weighted_avg_watts,avg_watts) VALUES (101,'power ride','Ride','${ctx.d1}T10:00:00Z',3600,30000,100,200,200);")
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,avg_hr) VALUES (102,'hr row','Rowing','${ctx.d2}T10:00:00Z',3600,9000,0,150);")
    check!("analyze computes 2", strjq!(ctx, ["analyze"], ".data.computed") == "2")?
    check!("summary as_of is today", strjq!(ctx, ["summary"], ".data.as_of") == ctx.today)?
    check_near!("28d tss ~155 (100 power + 55 hr)", sfloat(strjq!(ctx, ["summary"], ".data.last_28d.tss")), 155.0, 1.0)?
    mp = sfloat(strjq!(ctx, ["summary"], ".data.last_28d.measured_pct"))
    check!("measured_pct ~65 (60..70)", mp >= 60.0 and mp <= 70.0)?
    check!("ftp not stale", strjq!(ctx, ["summary"], ".data.ftp.stale") == "false")?
    check!("fitness_ctl > 0", sfloat(strjq!(ctx, ["summary"], ".data.fitness_ctl")) > 0.0)?
    check!("fatigue_atl > 0", sfloat(strjq!(ctx, ["summary"], ".data.fatigue_atl")) > 0.0)?
    Ok({})
}

# ── per-sport FTP / zone / metrics_rev auto-invalidation ─────────────
b_invalidation! : Ctx => Try({}, _)
b_invalidation! = |ctx| {
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "ftp_ride", "100"])
    check!("ftp_ride change recomputes only cycling", strjq!(ctx, ["analyze"], ".data.computed") == "1")?
    check_near!("28d tss ~455 (NP200@FTP100 => 400 +55 hr)", sfloat(strjq!(ctx, ["summary"], ".data.last_28d.tss")), 455.0, 1.0)?
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
    check!("plan add id 1", strjq!(ctx, ["plan", "add", "2099-01-01", "vo2max", "d", "r"], ".data.id") == "1")?
    # re-planning an open date REVISES it in place (same id 1), not a refuse + tombstone
    check!("re-plan revises open in place", strjq!(ctx, ["plan", "add", "2099-01-01", "threshold", "d", "r"], ".data.id") == "1")?
    check!("skip session", Str.contains(stride!(ctx.bin, ctx.home, ["skip", "1", "sick"]), "\"skipped_session\""))?
    check!("re-plan after skip id 2", strjq!(ctx, ["plan", "add", "2099-01-01", "threshold", "d2", "r2"], ".data.id") == "2")?
    check!("complete session", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "2", "101"]), "\"completed_session\""))?
    check!("plan 1 skipped with reason", strjq!(ctx, ["plan", "all"], ".data[] | select(.id==1) | .skipped_reason") == "sick")?
    check!("plan 1 status skipped", strjq!(ctx, ["plan", "all"], ".data[] | select(.id==1) | .status") == "skipped")?
    check!("plan 2 done", strjq!(ctx, ["plan", "all"], ".data[] | select(.id==2) | .status") == "done")?
    check!("plan 2 completed activity 101", strjq!(ctx, ["plan", "all"], ".data[] | select(.id==2) | .completed_activity_id") == "101")?
    check!("complete nonexistent session", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "999", "101"]), "session_not_found"))?
    check!("complete nonexistent activity", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "2", "88888"]), "activity_not_found"))?
    check!("skip nonexistent session", Str.contains(stride!(ctx.bin, ctx.home, ["skip", "999", "x"]), "session_not_found"))?
    check!("complete non-numeric id", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "abc", "101"]), "bad_id"))?
    check!("plan rest id 3", strjq!(ctx, ["plan", "add", "2099-01-02", "rest", "planned rest", "recovery"], ".data.id") == "3")?
    check!("plan vo2max id 4", strjq!(ctx, ["plan", "add", "2099-01-03", "vo2max", "intervals", "stimulus"], ".data.id") == "4")?
    check!("non-rest bare complete refused", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "4"]), "activity_required"))?
    check!("rest bare complete", Str.contains(stride!(ctx.bin, ctx.home, ["complete", "3"]), "\"rest\":true"))?
    check!("rest is done in db", Str.trim(sql!(ctx.db, "SELECT status FROM planned_sessions WHERE id=3;")) == "done")?
    _ = stride!(ctx.bin, ctx.home, ["skip", "4", "cleanup"])
    check!("pending_sessions 0", strjq!(ctx, ["summary"], ".data.pending_sessions") == "0")?
    check!("week open_sessions empty", strjq!(ctx, ["week"], ".data.open_sessions | length") == "0")?
    check!("bare plan is week-scoped (no far-future 2099 sessions)", strjq!(ctx, ["plan"], "[.data[].target_date] | map(select(. >= \"2099\")) | length") == "0")?
    Ok({})
}

# ── activities (+ sport filter) ──────────────────────────────────────
b_activities! : Ctx => Try({}, _)
b_activities! = |ctx| {
    check!("2 activities", strjq!(ctx, ["activities"], ".data | length") == "2")?
    check_near!("101 tss ~400 (NP200@FTP100)", sfloat(strjq!(ctx, ["activities"], ".data[] | select(.id==101) | .tss")), 400.0, 1.0)?
    check_near!("101 intensity ~2.0", sfloat(strjq!(ctx, ["activities"], ".data[] | select(.id==101) | .intensity")), 2.0, 0.01)?
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
    check_near!("activity 101 tss ~400", sfloat(strjq!(ctx, ["activity", "101"], ".data.tss")), 400.0, 1.0)?
    check_near!("activity 101 intensity ~2.0", sfloat(strjq!(ctx, ["activity", "101"], ".data.intensity")), 2.0, 0.01)?
    check!("no streams -> w60 honest 0", strjq!(ctx, ["activity", "101"], ".data.power_bests.w60") == "0")?
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
    _ = stride!(ctx.bin, ctx.home, ["config", "set", "ftp_ride", "111"])
    check!("analyze reports stream decode errors", sfloat(strjq!(ctx, ["analyze"], ".data.stream_errors")) >= 1.0)?
    check!("activities non-numeric count", Str.contains(stride!(ctx.bin, ctx.home, ["activities", "banana"]), "bad_count"))?
    check!("load non-numeric count", Str.contains(stride!(ctx.bin, ctx.home, ["load", "abc"]), "bad_count"))?
    _ = sql!(ctx.db, "INSERT INTO activities (id,name,sport_type,start_local,moving_time,avg_hr) VALUES (103,'bad date','Ride','0000-0z-01T10:00:00Z',3600,150);")
    _ = stride!(ctx.bin, ctx.home, ["analyze"])
    check!("malformed date does not explode daily_load", str_to_i64(Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM daily_load"))) < 400)?
    Ok({})
}

# ── progress A: EF lens, date -> workout, chronological, no-workout ──
b_progress_a! : Ctx => Try({}, _)
b_progress_a! = |ctx| {
    _ = seed_ride!(ctx.db, "201", "Test Class", "2025-01-01T10:00:00Z", "3600", "20000", "180", "150")
    _ = seed_ride!(ctx.db, "202", "Test Class", "2025-06-01T10:00:00Z", "3600", "20000", "210", "150")
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
    check!("best session renders full ef bar", Str.contains(prog_h, "████████████"))?
    check!("asked-date row carries marker", Str.contains(prog_h, "◀ asked"))?
    check!("far-apart sessions show gap row", Str.contains(prog_h, "···"))?
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
    _ = stride!(ctx.bin, ctx.home, ["import", expdir])
    check!("re-import idempotent (2 rows)", Str.trim(sql!(ctx.db, "SELECT COUNT(*) FROM activities WHERE id IN (9001, 9002);")) == "2")?
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
    check!("doctor rated 1", strjq!(ctx, ["doctor"], ".data.rated") == "1")?
    check!("doctor strength_unrated 0", strjq!(ctx, ["doctor"], ".data.strength_unrated") == "0")?
    check!("doctor scored_by session_rpe 1", strjq!(ctx, ["doctor"], "[.data.scored_by[] | select(.model==\"session_rpe\") | .n] | add // 0") == "1")?
    check!("doctor conf_high >= 1", sfloat(strjq!(ctx, ["doctor"], ".data.conf_high")) >= 1.0)?
    check!("doctor conf_medium >= 1", sfloat(strjq!(ctx, ["doctor"], ".data.conf_medium")) >= 1.0)?
    ch = strjq!(ctx, ["doctor"], ".data.conf_high")
    powr = strjq!(ctx, ["doctor"], "[.data.scored_by[] | select(.model==\"power_stream\" or .model==\"weighted_watts\" or .model==\"avg_watts\") | .n] | add // 0")
    check!("conf_high == power-rung provenance", ch == powr)?
    check!("doctor ftp_configured >= 1", sfloat(strjq!(ctx, ["doctor"], ".data.ftp_configured")) >= 1.0)?
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

# ── human output mode ────────────────────────────────────────────────
b_human! : Ctx => Try({}, _)
b_human! = |ctx| {
    check!("human plan header", Str.contains(stride_human!(ctx.bin, ctx.home, ["plan", "all"]), "status"))?
    check!("human activities header", Str.contains(stride_human!(ctx.bin, ctx.home, ["activities"]), "sport"))?
    check!("human load verdict line", Str.contains(stride_human!(ctx.bin, ctx.home, ["load", "7"]), "today: form"))?
    check!("human stats section", Str.contains(stride_human!(ctx.bin, ctx.home, ["stats"]), "ALL TIME"))?
    check!("human activity zones row", Str.contains(stride_human!(ctx.bin, ctx.home, ["activity", "101"]), "Z1"))?
    check!("human summary banner", Str.contains(stride_human!(ctx.bin, ctx.home, ["summary"]), "stride report"))?
    check!("human week bundle", Str.contains(stride_human!(ctx.bin, ctx.home, ["week"]), "OPEN PLAN"))?
    check!("uppercase STRIDE_FORMAT selects JSON", Str.contains(stride_env!(ctx.bin, ctx.home, ["summary"], [("STRIDE_FORMAT", "JSON")]), "\"schema_version\""))?
    Ok({})
}

# ── schema migration: a legacy db upgrades with data intact ──────────
b_migration! : Ctx => Try({}, _)
b_migration! = |ctx| {
    mighome = Str.trim(sh!("mktemp -d"))
    migdb = "${mighome}/.stride/db.sqlite"
    _ = sh!("mkdir -p '${mighome}/.stride' && sqlite3 '${migdb}' < tests/fixtures/db/v1-legacy.sql")
    check!("fixture starts at user_version 1", Str.trim(sql!(migdb, "PRAGMA user_version;")) == "1")?
    _ = stride!(ctx.bin, mighome, ["config", "get", "ftp_ride"])
    migv = str_to_i64(Str.trim(sql!(migdb, "PRAGMA user_version;")))
    check!("migration advances schema version", migv > 1)?
    check!("rename preserves planned session row", Str.trim(sql!(migdb, "SELECT session_type FROM planned_sessions WHERE id=1;")) == "vo2max")?
    check!("ratings table created", Str.contains(sql!(migdb, "SELECT 1 FROM ratings LIMIT 0; SELECT 'ok';"), "ok"))?
    check!("metric provenance columns added", Str.contains(sql!(migdb, "SELECT load_model, metrics_rev, zones_used FROM activity_metrics LIMIT 0; SELECT 'ok';"), "ok"))?
    check!("weighted_avg_watts column added", Str.contains(sql!(migdb, "SELECT weighted_avg_watts FROM activities LIMIT 0; SELECT 'ok';"), "ok"))?
    check!("activities survive migration", Str.trim(sql!(migdb, "SELECT COUNT(*) FROM activities;")) == "2")?
    _ = stride!(ctx.bin, mighome, ["analyze"])
    _ = stride!(ctx.bin, mighome, ["config", "get", "ftp_ride"])
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
need = |what, v| if Str.is_empty(v) { Err(SetupFailed(what)) } else { Ok(v) }

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
    Str.trim(sh!("awk 'BEGIN{t=\"\";w=\"\";for(i=0;i<120;i++){if(i>0){t=t\",\";w=w\",\"} t=t i; w=w (i==60?\"9999.0\":\"200.0\")} printf \"{\\\"time\\\":{\\\"data\\\":[%s]},\\\"watts\\\":{\\\"data\\\":[%s]}}\", t, w}'"))

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
