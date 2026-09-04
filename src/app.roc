app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst",
    http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

# stride — a local-first multi-sport training engine.
#
# This module is argv -> dispatch, plus the handful of effects that have no better
# home yet (`init!`, `config_show!`, `config_store!`) and a set of platform imports
# left over from when it owned everything. It used to own every effect,
# because alpha4 could not type-check a wide decoder once effects were injected
# into a module; the new compiler lifted that wall, so effects now live with
# their concern — Db (SQLite + migrations), Strava (OAuth + sync), Analyze/Plan/
# Import, and the report family (Report plus ReportSessions/ReportHealth/
# ReportSeason, split by read-command family in #196). See ADR 0001.
#
# The logic worth testing lives in pure modules — Metrics (training math),
# Sports (sport vocabulary), Render (tables/formatting), Command (argv parsing),
# Config, Csv, Streams and Drain. Schema (DDL) is pure but carries no expects;
# it is type-checked only, and is not in the `just test` recipe.
#
# Two consumers, one contract: humans get tables (with legends and a verdict),
# LLM coaches get JSON by ASKING for it (--json, else STRIDE_FORMAT=json —
# nothing is inferred from the environment). The engine
# computes deterministically; the coach reasons and writes the plan back
# through the coaching-log commands. Neither does the other's job.

import pf.Stdout
import pf.Stdin
import pf.Env
import pf.OsStr
import pf.Http
import http.Request
import http.Response
import http.Method
import pf.Utc
import pf.Sleep
import pf.Sqlite
import pf.Cmd
import pf.Path
import Csv
import Streams
import Metrics
import Command
import Config
import Schema
import Render
import Drain
import Db
import Output
import Strava
import Analyze
import Report
import ReportHealth
import ReportSeason
import ReportSessions
import Plan
import Import

version : Str
version = "stride 0.10.0" # x-release-please-version

help_text =
        \\stride — a local-first, deterministic training analytics engine (built in Roc)
        \\Designed to be driven by an LLM coach (e.g. Claude Code) or by hand.
        \\
        \\USAGE
        \\    stride <command>
        \\
        \\Commands print human tables. Pass --json for machine output (or --human to
        \\force tables); nothing is inferred from the environment, so a tool asks.
        \\STRIDE_FORMAT=json sets a default for a whole shell session and the flag
        \\beats it. Use -- to end flag parsing when an argument is literally
        \\"--json": stride skip 5 --json -- --json
        \\
        \\SETUP (once)
        \\    init                        create ~/.stride and migrate the SQLite db
        \\    auth                        authorize with Strava (one-time paste flow; stores creds)
        \\    config                      list the config that is set (secrets redacted)
        \\    config get|set <key> [value]   read or write one key (hr zone bounds, timezone)
        \\                                — FTP is derived, never set
        \\
        \\GET DATA
        \\    sync                        pull new activities + streams (rolling 30d self-heal)
        \\    sync --all                  force a full re-list from scratch (dev escape hatch)
        \\    import <zip|dir>            load a Strava account export — no API creds needed
        \\    analyze                     compute training metrics (TSS, zones, CTL/ATL/TSB)
        \\
        \\WHERE DO I STAND?
        \\    summary                     form, 7d/28d zones + polarization, derived FTP, per-sport
        \\    stats                       career + year-to-date totals per sport
        \\    doctor                      dataset health: coverage + how each activity was scored
        \\
        \\AM I IMPROVING?
        \\    tte <watts>                 how long the CP model says you could hold a power
        \\    reps [date]                 the same workout shape across sessions, rep by rep
        \\    progress [date] [asc|desc]  trend on a repeated workout, sport-aware lens
        \\                                (power→EF, distance→speed/HR, rated→RPE);
        \\                                latest by default, oldest-first — desc reverses
        \\    compare [week|month]        this period vs the one before it (default week)
        \\    season                      training blocks, monthly load, polarization, FTP
        \\    top <metric> [n] [sport]    best sessions by a metric — hr, tss, power,
        \\                                intensity, distance, time or output
        \\
        \\WHAT HAPPENED?
        \\    activities [limit] [sport]  recent sessions with metrics (default 30)
        \\    activity <id>               one session in depth: zones, bests, hard minutes
        \\    load [days]                 fitness/fatigue/form series (default 90)
        \\    power-curve [days] [sport]  power-duration curve + Critical Power (alias: pc)
        \\    pace-curve [days] <sport>   speed-duration curve + Critical Speed (alias: cs)
        \\
        \\WHAT SHOULD I DO?
        \\    plan                        planning bundle: summary + open sessions + 14d
        \\    week                        this week's sessions (Mon-Sun, all statuses)
        \\    week all                    upcoming + this week + last week
        \\    week add <date> <type> <detail> <rationale> [RxMM:SS@WWWW]
        \\                                add a planned session; the optional literal is a
        \\                                structured target, e.g. 3x12:00@230W
        \\    complete <session_id> [activity_id]
        \\                                mark done (bare = rest day)
        \\    skip <session_id> <reason> [activity_id|none]
        \\                                mark skipped — name the activity done instead,
        \\                                or `none` to release an existing link
        \\    relabel <session_id> <type> <detail> [rationale]
        \\                                fix a session's label, any status — links,
        \\                                status and metrics stay untouched
        \\    rate <activity_id|latest> <1-10>
        \\                                session-RPE — scores strength honestly
        \\    event add <date> <name>    record an event target (judgment tier)
        \\    event remove <event_id>    delete an event target
        \\    events                      projected CTL/ATL/TSB on each event date,
        \\                                from the open plan's structured targets
        \\    project <date> [plan]       CTL/ATL/TSB on a date — recorded plan, or a
        \\                                hypothetical one (date=target pairs, echoed
        \\                                back, never stored)
        \\
        \\REFERENCE
        \\    zones                       power-zone watt ranges (7) from your FTP (alias: pz)
        \\
        \\FLAGS
        \\    --json                      machine output (beats STRIDE_FORMAT)
        \\    --human                     human tables, even for tool callers
        \\    --help, -h                  show this help
        \\    --version                   show version
        \\    --all                       sync only — force a full re-list
        \\    --                          end flag parsing, so a following
        \\                                --json is a literal value
        \\
        \\STRAVA CREDENTIALS (first time only)
        \\    Create a Strava API app (strava.com/settings/api), then:
        \\    STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth
        \\    After that, creds live in the db — no env vars needed again.

# main! stays thin: parse argv into a typed Command (pure, in Command.roc), then
# dispatch. All arity/count validation lives in the parser and is unit-tested there.
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |raw_args| {
    # basic-cli hands args over as an OS-native tag union — that union IS `OsStr`
    # (Utf8 | UnixBytes raw argv | WindowsU16s UTF-16 code units). OsStr.display decodes ALL
    # three, including Windows UTF-16, best-effort (invalid text -> U+FFFD). This is why macOS +
    # Linux + Windows all Just Work here: the platform owns the decoding, not us.
    args = List.map(raw_args, |a| OsStr.display(a))
    # explicit format flags (#162): --json / --human anywhere in argv beat the
    # environment. basic-cli has no setenv and json_mode! is consulted from
    # every error path, so rather than thread a mode through the whole output
    # layer, the flag re-execs THIS binary with STRIDE_FORMAT set for the child.
    # It is a shim, and an honest one: it costs ~10 ms and one extra process,
    # and it now OWNS the exit code of every flagged invocation, which is why
    # reexec_with_format! propagates the child's status verbatim (#163 made
    # those codes carry meaning, so the propagation is load-bearing, not tidy).
    #
    # The child's args are prefixed with `--` so its own parse treats every
    # token as literal: that is what makes recursion impossible AND what keeps
    # an escaped `stride skip 5 -- --human` from being re-read as a flag by the
    # child (review of #177 caught both). Argv is re-encoded via OsStr.display,
    # which is lossy for non-UTF8 bytes — only on the flag path, and stride
    # arguments are ids, dates and words in practice.
    split = Command.split_format_args(args)
    match split.mode {
        Auto =>
            match Command.parse(split.rest) {
                # Asking what stride can do — bare, or `--help` — is a question,
                # not a failure, so it stays exit 0 in both modes (#163). A
                # machine asking it got a screen of prose it could not parse
                # (#180); it now gets the same question answered as DATA: the
                # command list. `--help` and a bare call are the same request,
                # so they get the same answer rather than one becoming an error.
                Err(ShowHelp) =>
                    if Output.json_mode!({}) {
                        # subcommands and flags separately: the unknown-command envelope says "run
                        # `stride` for the list", so the list must lead to everything runnable,
                        # --version included.
                        # Records, not bare names (#219): a name list lets an agent enumerate and
                        # nothing more — no argument shape, no mutates, no network, no schema. ADR 0000
                        # s10 declines an MCP server because the CLI plus versioned JSON already IS the
                        # agent interface; this is that claim made true.
                        # `--` and `-h` are listed because the binary accepts them: `--` ends flag
                        # parsing and is the ONLY way to pass an argument beginning with `--json`.
                        # The flags are bare strings where `commands` are records — known, not endorsed:
                        # the payload cannot say `--all` is sync-only or that `--` is a terminator, and
                        # deriving records is not available while flags are handled in three places.
                        # `help`/`--help`/`-h` are filtered because they answer WITH this list (a loop);
                        # `--version` because it belongs in `flags`.
                        Output.emit_ok!({
                            commands: List.keep_if(Command.specs, |s| !(Str.starts_with(s.name, "-")) and s.name != "help"),
                            flags: ["--json", "--human", "--help", "-h", "--version", "--all", "--"],
                            # once, not on all nineteen forms. A caller's effective set for
                            # a form is this list PLUS that form's `error_codes` — the split
                            # is the information: a database that will not open is not worth
                            # retrying, and `no_power_data` on `tte` says something about the
                            # data rather than the machine.
                            universal_error_codes: Command.universal_error_codes,
                        })
                    } else {
                        Stdout.line!(help_text)
                    }
                # an unknown command is an invocation error (#163): machines get
                # an envelope, humans still get the help text, both exit non-zero
                Err(UnknownCmd(name)) =>
                    if Output.json_mode!({}) {
                        Output.err_out!("unknown_command", "no such command '${name}' — run `stride` for the list")
                    } else {
                        Stdout.line!(help_text)?
                        Err(Exit(1))
                    }
                Err(Usage(u)) => Output.usage!(u)
                Err(BadCount(s)) => Output.err_out!("bad_count", "expected a number, got '${s}'")
                Ok(cmd) => run_command!(cmd)

            }
        ForceJson => reexec_with_format!(split.rest, "json")
        ForceHuman => reexec_with_format!(split.rest, "human")
    }
}

# Re-run THIS executable with STRIDE_FORMAT pinned for the child; stdio is
# inherited, so output streams exactly as if the child were the process.
# The program is Env.exe_path!(), never argv[0]: a bare argv[0] re-resolves
# through PATH for the child, so a shadowing entry could run a DIFFERENT binary
# than the one executing. Killing the parent orphans the child — inherent to
# re-exec, and the reason this stays a shim rather than growing features.
reexec_with_format! : List(Str), Str => Try({}, _)
reexec_with_format! = |cleaned, fmt| {
    self = Env.exe_path!()?
    # `--` first: the child parses every remaining token as literal
    child_args = List.prepend(List.map(List.drop_first(cleaned, 1), OsStr.from_str), OsStr.from_str("--"))
    match Cmd.new(Path.to_os_str(self)).args(child_args).env(OsStr.from_str("STRIDE_FORMAT"), OsStr.from_str(fmt)).exec_cmd!() {
        Ok(_) => Ok({})
        # the child already printed its own error surface (envelope or human
        # text) — carry its STATUS verbatim and print nothing more. Exit(code)
        # is the one error the platform reports silently; anything else would
        # stack a Roc runtime banner on top of the child's own message.
        Err(ExecCmdFailed(f)) => Err(Exit(f.exit_code))
        Err(e) => Err(ReexecFailed(e))
    }
}
# THE boundary between platform failures and the published contract (#183).
#
# An uncaught platform error reaches main! as an opaque tag and the platform
# prints `Program exited with error: <Tag>` to STDERR with empty stdout — no
# code, no envelope, nothing a machine can branch on, and it was the first
# thing a new user met (a query before `stride init`). Catching here rather
# than at each of the many platform call sites means one place decides, and a failure
# that reaches a caller without a code is a missing arm in this match rather
# than a habit nobody enforced.
#
# Err(Exit(_)) passes through untouched: that is stride's own clean signal,
# raised by err_out! AFTER it has already printed the envelope. Converting it
# here would print a second one.
run_command! : Command.Command => Try({}, _)
run_command! = |cmd|
    match dispatch!(cmd) {
        Ok(_) => Ok({})
        Err(Exit(code)) => Err(Exit(code))
        # SQLite collapses "absent" and "present but unopenable" into one code,
        # and the remedy differs: `init` fixes the first and loops forever on the
        # second (permissions, a directory where the file should be, an immutable
        # flag). Ask the filesystem which one it is.
        Err(SqliteErr(CanNotOpen, _)) => {
            p = Db.db_path!({})?
            # a directory at the db path answers False to is_file! but is very
            # much "present and unopenable" — the case `init` cannot fix either
            exists = ((Path.is_file!(Path.utf8(p))) ?? False) or ((Path.is_dir!(Path.utf8(p))) ?? False)
            if exists {
                Output.err_out!("unreadable_database", "${p} exists but could not be opened — check its permissions and the ownership of its directory (`init` will not fix this)")
            } else {
                Output.err_out!("no_database", "no database at ${p} — run `stride init` first")
            }
        }
        # A stored config value the engine cannot parse. Converted HERE rather than at
        # each call site: several commands load config, and the remedy is identical for
        # all of them -- name the key, echo the stored text (#206).
        Err(UnreadableConfig(key, raw)) => Output.unreadable_config!(key, raw)
        # ...and the sibling tag: `MissingEnv` was handled by `auth!` and nothing else,
        # so the SAME tag surfacing through `get_valid_token!`'s refresh branch fell to
        # the catch-all — `sync` answered `internal_error … please open an issue` for a
        # state `stride auth` fixes in one command. (`internal_error` is universal, so
        # the envelope validated and nothing flagged it, #279.)
        #
        # Safe to key on the TAG because `MissingEnv` has exactly one raiser,
        # `Strava.client_cred!`, and every call passes a client credential — so every
        # value this arm sees fits the remedy. Raise `MissingEnv` for some other
        # variable and this arm will hand out Strava setup instructions for it.
        Err(MissingEnv(name)) => Output.missing_client_creds!(name)
        # A stored date the engine refuses to guess at. Converted HERE, at the one
        # boundary, because four commands can RAISE these tags and the remedy depends on
        # the TABLE rather than the command. One other reader still absorbs: `load`
        # collapses an unreadable day to epoch 0 (a fabricated 1969 week in the rollup
        # view). `stats` and `doctor` never parse a date — they compare start_local as
        # bytes in SQL, so an unreadable value joins or leaves a window by string order;
        # a different failure, named separately.
        Err(BadActivityDate(raw, id)) => Output.unreadable_activity_date!(raw, id)
        # Same CODE, different wording. The time half's `raw` is a COMPONENT of start_local,
        # never the column, so rendering it through the date message put a string that is not
        # stored inside a parenthetical Output.roc documents as the reproduction handle —
        # `DELETE FROM activities WHERE start_local='T37:00:00'` matches zero rows, which is
        # the third instance of that exact defect in this file's history.
        Err(BadActivityTime(raw, id)) => Output.unreadable_activity_time!(raw, id)
        Err(BadDailyLoadDay(raw)) => Output.unreadable_daily_load_day!(raw)
        Err(SqliteErr(NotADatabase, _)) =>
            Output.err_out!("corrupt_database", "~/.stride/db.sqlite is not a readable SQLite database — restore a backup or re-run `stride init` against a fresh path")
        Err(SqliteErr(code, msg)) =>
            Output.err_out!("database_error", "the database refused this operation (${Str.inspect(code)}): ${msg}")
        # Strava ANSWERED, with a status the caller must distinguish: an expired
        # or revoked token is the routine one and has a code already, rate limits
        # need their own so a caller can back off, and anything else is Strava's
        # problem rather than a stride bug. All of these once landed in
        # internal_error, telling users to file an issue for an expired token.
        Err(HttpStatus(status, body)) =>
            if status == 401 or status == 403 {
                # `body` was bound and DISCARDED here, unlike the strava_error arm two
                # lines down. That flattened two 401s with different causes and different
                # remedies into one message: a dead credential, where `stride auth` is
                # right, and a resource that keeps 401ing after the token was successfully
                # refreshed twice — a missing scope or a clock skew, where re-authing with
                # the same scope will not help. This arm's justification for flattening is
                # that the remedy is identical for all of them; that premise fails here,
                # so pass the diagnosis through rather than printing a fix that does not fit.
                Output.err_out!("not_authenticated", "Strava rejected the credentials (HTTP ${(status).to_str()}): ${clip_msg(body)}")
            } else if status == 429 {
                Output.err_out!("rate_limited", "Strava rate limit reached (HTTP 429) — wait for the window to reset and retry")
            } else {
                Output.err_out!("strava_error", "Strava returned HTTP ${(status).to_str()}: ${clip_msg(body)}")
            }
        # Strava never answered: DNS, TLS, connection refused. The payload is a
        # byte list, and inspecting it raw is the unreadable shape #183 was filed
        # about — decode it.
        Err(HttpErr(Other(bytes))) =>
            Output.err_out!("network_unreachable", "could not reach the Strava API (${clip_msg(Str.from_utf8_lossy(bytes))}) — check the connection and retry")
        Err(HttpErr(e)) =>
            Output.err_out!("network_unreachable", "could not reach the Strava API (${clip_msg(Str.inspect(e))}) — check the connection and retry")
        # a paste flow with nothing on stdin
        Err(EndOfFile) =>
            Output.err_out!("stdin_closed", "stdin closed before input arrived — `stride auth` needs a terminal to paste into")
        # anything else still becomes an envelope rather than a runtime banner;
        # the inspected tag rides in the message so the report is actionable
        Err(other) =>
            Output.err_out!("internal_error", "unhandled failure: ${clip_msg(Str.inspect(other))} — please open an issue with the command you ran")
    }

# An inspected tag carries whatever payload it holds — a 200 KB error body
# produced a 200,157-byte single-line envelope in review, and response bodies
# can carry credentials. Clip before it reaches stdout.
clip_msg : Str -> Str
clip_msg = |s| {
    bytes = Str.to_utf8(s)
    if List.len(bytes) <= 200 {
        s
    } else {
        "${Str.from_utf8_lossy(List.take_first(bytes, 200))}… (truncated)"
    }
}

dispatch! : Command.Command => Try({}, _)
dispatch! = |cmd|
    match cmd {
        Command.Init => init!({})
        Command.Auth => Strava.auth!({})
        Command.Sync(all) => Strava.sync!(all)
        Command.Analyze => Analyze.analyze!({})
        Command.Summary => Report.summary!({})
        Command.Stats => ReportHealth.stats!({})
        Command.Plan => Plan.plan_bundle!({})
        Command.Doctor => ReportHealth.doctor!({})
        Command.Zones => ReportHealth.pz!({})
        # a machine calls this alongside schema_version to negotiate, so it
        # answers in the envelope like every other query (#182)
        Command.Version => Output.out!({ version: version }, |p| p.version)
        Command.Compare(period) => Report.compare!(period)
        Command.Activities(c, sport) => ReportSessions.activities!(c, sport)
        Command.Top(metric, c, sport) => ReportSessions.top!(metric, c, sport)
        Command.Import(src) => Import.import_archive!(src)
        Command.Rate(target, rpe_str) => Plan.rate!(target, rpe_str)
        Command.Progress(name, sort) => ReportSessions.progress!(name, sort)
        Command.Tte(watts) => ReportHealth.tte!(watts)
        Command.Reps(date) => ReportSessions.reps!(date)
        Command.Activity(id_str) => ReportSessions.activity!(id_str)
        Command.Load(days) => Report.load_series!(days)
        Command.PowerCurve(days, sport) => ReportHealth.power_curve!(days, sport)
        Command.PaceCurve(days, sport) => ReportHealth.pace_curve!(days, sport)
        Command.Season => ReportSeason.season!({})
        Command.WeekView => Plan.plan_view!(ThisWeek)
        Command.WeekViewAll => Plan.plan_view!(AllTime)
        Command.WeekAdd(date, session_type, detail, rationale) => Plan.plan_add!(date, session_type, detail, rationale, NoTarget)
        Command.WeekAddT(date, session_type, detail, rationale, target) => Plan.plan_add!(date, session_type, detail, rationale, Target(target))
        Command.Relabel(session_id, session_type, detail) => Plan.relabel!(session_id, session_type, detail, KeepRationale)
        Command.RelabelWith(session_id, session_type, detail, rationale) => Plan.relabel!(session_id, session_type, detail, SetRationale(rationale))
        Command.EventAdd(date, name) => Plan.event_add!(date, name)
        Command.EventRemove(event_id) => Plan.event_remove!(event_id)
        Command.Events => Plan.events!({})
        Command.Project(date) => Plan.project!(date, Recorded)
        Command.ProjectWith(date, plan) => Plan.project!(date, Hypothetical(plan))
        Command.Complete(session_id, activity_id) => Plan.complete!(session_id, activity_id)
        Command.CompleteRest(session_id) => Plan.complete_rest!(session_id)
        Command.Skip(session_id, reason) => Plan.skip!(session_id, reason, NoSub)
        Command.SkipWith(session_id, reason, activity_id) => Plan.skip!(session_id, reason, Sub(activity_id))
        Command.ConfigList => config_list!({})
        Command.ConfigGet(key) => config_show!(key)
        Command.ConfigSet(key, val) => config_store!(key, val)
        Command.ConfigUnset(key) => config_unset!(key)

    }

config_show! : Str => Try({}, _)
config_show! = |key|
    # A derived key must not be READ back either: pre-derivation databases still
    # hold ftp_ride rows, and echoing the stored value keeps the "looks like it
    # worked" trap alive — a number the engine never consults. Refusing to set while
    # still printing is half a fix. `known_key` deliberately excludes the derived
    # family so the two cannot both claim a key.
    if Config.is_derived(key)
        Output.err_out!(
            "derived_key",
            "${key} is derived from your power history, not configured. Any value stored under this key is ignored (older databases may still hold one). `stride summary` shows the value actually in use.",
        )
    # ...and a key the engine looks up NOTHING for is its own answer (#254). This was
    # `not_set`, which reads as "the key is fine, it is just empty" — so the next step after
    # `config get timezon` is `config set timezon <value>`, and that succeeded too, so both
    # halves of the round trip agreed the key was real while nothing ever read it.
    #
    # Before the db is opened, because whether the binary recognises a key is a fact about
    # the BINARY: a typo gets the same answer on a fresh install as on a populated one.
    else if !(Config.known_key(key))
        Output.err_out!("unknown_key", unknown_key_message(key))
    else {
        # only the paths that actually read a value open the db
        path = Db.open_db!({})?
        if Config.is_secret(key)
            # confirm set-ness without leaking the value
            match Db.config_opt!(path, key)? {
                # redacted must be Bool-TYPED, not a bare `True` tag: the new builtin JSON
                # serializes a bare tag as the string "True". Config.is_secret(key) is Bool
                # and is True here (we're inside the is_secret branch).
                # An EMPTY value is `not_set`, not a set-but-blank secret. Same rule as the
                # non-secret arm below, and for the same reason.
                Found(v) =>
                    if v == ""
                        Output.err_out!("not_set", "(not set)")
                    else
                        Output.out!({ key, value: "<redacted>", redacted: Config.is_secret(key) }, |_| "${key} = <redacted> (secret — stored in the db, not shown)")

                NotFound => Output.err_out!("not_set", "(not set)")
            }
        else
            match Db.config_opt!(path, key)? {
                # An empty ROW is not a set key. Every read path in the engine already says
                # so — `Db.roc` collapses `''` and absent to the same `NoTz`, and `doctor`
                # reports the identical UTC fallback for each — so `config get` answering
                # success with `value: ""` was the outlier, and it made this command
                # disagree with bare `config`, which lists only keys holding a value.
                # A key that reads as configured while nothing consults it is the shape of
                # #254 itself, one layer in.
                Found(v) =>
                    if v == ""
                        Output.err_out!("not_set", "(not set)")
                    else
                        Output.out!({ key, value: v }, |p| p.value)

                NotFound => Output.err_out!("not_set", "(not set)")
            }
    }
# Bare `config`: the keys that hold a value, in reading order — "which config do
# I have set?", which nothing answered (`doctor` reports counts, not names).
#
# Values are NOT returned: a listing that returned them would dump every secret,
# defeating `config get`'s redaction by going around it. `redacted` marks which
# entries `config get` would refuse, so "set, and I may read it" is separable
# without a call per key.
#
# Every row that holds a value, MARKED, not filtered: dropping the rows the
# engine does not read made the command unable to answer its own question and
# turned a visible dead row invisible — for an issue whose subject is "a row
# nothing reads", backwards. `status` says which: `read`, `derived` (stored,
# ignored), `unrecognised` (retired name or pre-#254 typo). `just schema-check`
# selects `status == "read"` rather than trusting an upstream filter. The
# emptiness test is the SAME rule `config get` uses, decided in SQL once.
config_list! : {} => Try({}, _)
config_list! = |{}| {
    path = Db.open_db!({})?
    rows = Sqlite.query_many!({
        path: Path.utf8(path),
        query: "SELECT COALESCE(CAST(key AS TEXT), '') AS k FROM config WHERE COALESCE(CAST(value AS TEXT), '') <> '' ORDER BY key",
        bindings: [],
        rows: Sqlite.str("k"),
    })?
    entries = List.map(
        rows,
        |k| {
            key: k,
            status: if Config.is_derived(k) "derived" else if Config.user_settable(k) "settable" else if Config.known_key(k) "managed" else "unrecognised",
            redacted: Config.is_secret(k),
        },
    )
    Output.out!(
        { keys: entries },
        |p|
            if List.is_empty(p.keys)
                "no config set — `stride config set <key> <value>`"
            else
                Str.join_with(
                    List.map(
                        p.keys,
                        |e| {
                            shown = if e.redacted "${e.key} = <redacted>" else e.key
                            if e.status == "settable" shown else "${shown}  (${e.status})"
                        },
                    ),
                    "\n",
                ),
    )
}
config_unset! : Str => Try({}, _)
config_unset! = |key| {
    path = Db.open_db!({})?
    existed =
        match Db.config_opt!(path, key)? {
            Found(_) => 1 == 1
            NotFound => 1 == 2
        }
    # Q1: a per-sport override falls back to the GLOBAL bound — when one exists. Read that
    # before the closure, beside `existed`, and let the message capture it: the payload and
    # `config_unset.json` stay a two-field `{key, removed}`. I had deferred this claiming it
    # "needs a database read inside the message closure, a different shape"; the read fits
    # here, and the claim was wrong.
    global_present =
        match Str.split_first(key, "_max_") {
            Ok({ before, .. }) =>
                match Db.config_opt!(path, "${before}_max")? {
                    Found(_) => True
                    NotFound => False
                }

            Err(_) => False
        }
    Db.config_delete!(path, key)?
    # ONE branch per OUTCOME, not per key class: keyed on `known_key`, every
    # recognised key was told "stride will fall back to its default" — false for
    # half (removing hr_z1_max exits 1 with missing_config; hr_z2_max_ride really
    # does fall back). A per-sport override is `hr_zN_max_<sport>`; the underscore
    # AFTER `max` separates it from the global (#276).
    Output.out!(
        { key, removed: existed },
        |p|
            if !(p.removed) {
                "${p.key} was not stored, so there was nothing to remove"
            } else if Config.is_derived(p.key) {
                "${p.key} removed — stride derives it from your power history anyway; `stride summary` shows the current value"
            } else if Config.is_client_credential(p.key) {
                # BOTH client credentials, by predicate rather than name-and-position:
                # `strava_client_id` reached the catch-all and was told stride "will re-fetch it
                # as needed" — false, the next sync asks the user to supply it by hand — while
                # its sibling got the truthful sentence. Ordering was the wrong mechanism too:
                # below `is_secret` this arm is unreachable, and only one branch is asserted
                # anywhere.
                "${p.key} removed — stride cannot re-authenticate until you supply it again and run `stride auth`"
            } else if Config.is_session_credential(p.key) or Config.is_secret(p.key) {
                "${p.key} removed — stride is no longer authenticated; run `stride auth` to reconnect"
            } else if Config.is_zone_key(p.key) and Str.contains(p.key, "_max_") and global_present {
                "${p.key} removed — the global bound applies to this sport again"
            } else if Config.is_zone_key(p.key) and Str.contains(p.key, "_max_") {
                "${p.key} removed — and no global bound is set for that zone, so `summary` and `analyze` refuse until one is"
            } else if Config.is_zone_key(p.key) {
                "${p.key} removed — stride needs this bound; `summary` and `analyze` refuse until it is set again"
            } else if p.key == "timezone" or p.key == "utc_offset_minutes" {
                # `utc_offset_minutes` belongs HERE, not in the catch-all. It is user config —
                # one of the three settable families — never recomputed and never re-fetched,
                # and removing it collapses to the same state as removing `timezone`.
                "${p.key} removed — stride reads dates as UTC until a zone or offset is set"
            } else if p.key == "units" {
                # Its own branch rather than the catch-all, which would say "run `stride
                # doctor` if a command starts refusing" — nothing refuses. Removing this key
                # cannot break a command, it only changes how numbers are printed, and the
                # message says exactly that.
                "${p.key} removed — distances and pace render in metric again"
            } else if Config.is_bookkeeping(p.key) {
                "${p.key} removed — stride recomputes or re-fetches this one as needed"
            } else if Config.known_key(p.key) {
                # The catch-all is now the SAFE default rather than the unrouted default.
                # It used to promise "recompute or re-fetch", which was false for whichever
                # `known_key` member had not been routed yet — `strava_client_id`,
                # `utc_offset_minutes` and `strava_expires_at` in three consecutive rounds,
                # each found by enumerating the list rather than by anything in the code.
                # This sentence is true of every key that reaches it, so a member added
                # tomorrow and not routed inherits a weaker message rather than a lie.
                "${p.key} removed — stride reads this key; run `stride doctor` if a command starts refusing"
            } else {
                "${p.key} removed — stride does not read it"
            },
    )
}

unknown_key_message : Str -> Str
unknown_key_message = |key|
    "${key} is not a key stride reads. ${Config.known_key_summary} `stride config` lists what this database has set."

numeric_refusal : Str, Str -> Str
# arg_i64/arg_f64, NOT is_plain_int/is_plain_decimal. The predicates check SYNTAX; the
# readers use arg_*, which is the predicate PLUS from_str -- and from_str also rejects
# overflow. Gating the write on the syntax half alone let `config set utc_offset_minutes
# 99999999999999999999` succeed and then be unparseable at every read, which is a value
# stored and permanently ignored: the exact trap #206 is about, created by the gate meant
# to prevent it. The write must accept exactly what the read can parse, so it calls the
# same function the read does.
numeric_refusal = |key, val|
    match Config.numeric_key(key) {
        Free => ""
        Int =>
            if Metrics.arg_i64(val).is_ok() "" else "${key} takes a whole number — got '${val}'"
        Decimal =>
            if Metrics.arg_f64(val).is_ok() "" else "${key} takes a number — got '${val}'"
    }

config_store! : Str, Str => Try({}, _)
config_store! = |key, val|
    # An empty value is REFUSED for every key class; the removal it used to mean
    # lives in `config unset`. History in #276 and config_unset!'s comment —
    # restating deleted behaviour above its replacement is how a reader gets told
    # the opposite of what runs.
    if val == ""
        # An empty value is not a WRITE, and `config set` says so instead of guessing: it
        # used to mean three things by key class — removal, `bad_value`, or an empty
        # WRITE that left a row reading as SET so `sync` spent a round trip to be told
        # 401 (#276). The removal payload also failed config.json's `value` requirement,
        # unseen because the form is `mutates: true` and schema-check covers read-only
        # forms. `config unset` carries the removal shape under its own schema now.
        Output.err_out!(
            "bad_value",
            "an empty value is not a setting — use `stride config unset ${key}` to remove the row, or give ${key} a value",
        )
    # refuse the keys the engine derives — storing one would confirm a change that never
    # happens, since sport_ftp! reads power history and not config (ADR 0005)
    else if Config.is_derived(key)
        Output.err_out!(
            "derived_key",
            "${key} is derived from your power history, not configured — stride uses the sport family's best 20-min power x 0.95 over the 60 days up to each activity. Nothing to set; `stride summary` shows the current value.",
        )
    # ...and the WRITE half of #254: guarding only `config get` produced a CLI that
    # confirmed a write and then denied the key existed (`set timezon x` printed
    # `timezon = x`; `get timezon` answered `unknown_key`). Internal writers call
    # `Db.config_set!` directly and never pass through here.
    # A NON-empty write to an unknown key is the trap itself: "you are storing a
    # value nothing will ever consult".
    else if !(Config.known_key(key))
        Output.err_out!("unknown_key", unknown_key_message(key))
    # The enum half of the same rule numeric_refusal enforces for numbers. Not folded into
    # numeric_key, which answers "how does this parse as a NUMBER" — units is the only key
    # with a closed value set, and a general mechanism for one member would be machinery
    # nothing else uses. Refused here so a typo cannot be stored: every read resolves an
    # unrecognised value to metric, so without this `config set units imperail` would
    # succeed, echo back, and render metric forever.
    else if key == "units" and !(Config.is_unit_value(val))
        Output.err_out!(
            "bad_value",
            "units takes metric or imperial — got '${val}'",
        )
    else if numeric_refusal(key, val) != ""
        # a stored value that parses nowhere is the same trap as one that is read
        # nowhere (Config.is_derived's comment) -- refuse it here rather than let
        # `config get` echo it back as though it took. numeric_refusal is pure and
        # called twice rather than bound, because the body is an if-expression and
        # a binding would need a block around the whole thing for no real gain.
        Output.err_out!("bad_value", numeric_refusal(key, val))
    else {
        path = Db.open_db!({})?
        Db.config_set!(path, key, val)?
        # same contract as every query command: JSON envelope for tools, plain line for
        # humans. The refusal above already emits the envelope, so success must too. And a
        # SECRET is never echoed back — not to the terminal (shell history, CI logs) and
        # not into the JSON envelope — matching the redaction config get enforces.
        (if Config.is_secret(key)
            Output.out!({ key, value: "<redacted>", redacted: Config.is_secret(key) }, |p| "${p.key} = <redacted> (stored)")
        else
            Output.out!({ key, value: val }, |p| "${p.key} = ${p.value}"))
    }
init! : {} => Try({}, _)
init! = |{}| {
    home = Env.var_str!(OsStr.from_str("HOME"))?
    dir = "${home}/.stride"
    # ignore AlreadyExists — idempotent init
    _ = Path.create_dir!(Path.utf8(dir))
    path = "${dir}/db.sqlite"
    # Harden the directory BEFORE the schema runs, for the same reason open_db! does:
    # ensure_schema! enables WAL, which creates the -wal/-shm sidecars, and those hold
    # recently written pages. This is the very first run, so it is the one call where the
    # files do not exist yet — hardening only afterwards would leave the whole of init
    # as the exposure window it is meant to close.
    Db.secure_perms!(dir)?
    Db.ensure_schema!(path)?
    Db.secure_perms!(dir)?
    # init printed its line directly, so it was the ONE command that ignored
    # --json — an absolute the skill states ("EVERY machine response is a
    # versioned envelope") is only true if the setup step honors it too
    Output.out!({ initialized: path }, |p| "initialized ${p.initialized}")
}