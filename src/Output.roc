import pf.Stdout
import pf.Stderr
import pf.Env
import pf.OsStr
import Render

Output :: [].{
    # ── exit status (#163) ───────────────────────────────────────────────
    # Every error surface prints its envelope (or human text) to stdout and then
    # returns Err(Exit(1)), which the platform turns into a non-zero process
    # status WITHOUT printing anything of its own. The ENVELOPE is unchanged —
    # this adds information to a channel that previously carried none, so JSON
    # consumers are unaffected while `set -e`, `&&` chains, CI steps, and
    # supervisors stop reading failures as success. Success paths still exit 0.
    error_status : I32
    error_status = 1

    # A malformed invocation is a failure a machine must be able to READ (#180):
    # under json_mode! it gets the same envelope every other error uses, with the
    # usage line as the message. Humans keep the bare `usage:` line — it is what
    # a terminal wants, and it is the shape the help text advertises.
    usage! : Str => Try({}, _)
    usage! = |u| {
        (if json_mode!({})
            emit_err!("usage", "usage: stride ${u}")
        else
            Stdout.line!("usage: stride ${u}"))?
        Err(Exit(error_status))
    }

    # ── analyze ──────────────────────────────────────────────────────────

    zone_config_help =
            \\analyze needs your HR zone upper bounds in config first (FTP is derived from
            \\your own power history, not configured):
            \\
            \\    stride config set hr_z1_max 123
            \\    stride config set hr_z2_max 153
            \\    stride config set hr_z3_max 168
            \\    stride config set hr_z4_max 183
            \\
            \\(find yours at strava.com/settings/heartrate — z5 is everything above z4_max)
    # ── machine interface (JSON output for LLM/tool consumption) ────────
    # Missing-value contract (#156, ADR 0009): literal JSON null is NOT expressible —
    # the builtin encoder stringifies tags ("None"/"Null"), verified by probe. So the
    # contract is per-field, in ADR 0009's three classes:
    #   IMPOSSIBLE-ZERO fields (np_w, avg_hr, intensity, ftp_used): a real 0 cannot
    #   occur, so 0 means "not available". THREE of those four carry a flag — ftp_used
    #   deliberately does not, because analyze always binds it (0 when no FTP is
    #   derivable), so a NULL-decoded flag would be all-true. Do NOT "fix" that
    #   asymmetry by adding a phantom ftp_used_known; see ADR 0009.
    #   The _known companion flags decode the
    #   STORED NULLs (CASE WHEN … IS NULL), never the coalesced magnitudes — np can
    #   be present while intensity is NULL (power stream, no FTP yet), which is why
    #   power_known and intensity_known are separate flags.
    #   REAL-ZERO fields (z1_s..z5_s when zones_known, distance on strength): 0 is an
    #   observation. tss is NOT in this class: an unscored row COALESCEs to 0, so
    #   tss 0 is ambiguous — load_model is the discriminator ("" or "none" =
    #   unscored; anything else = a scored near-zero effort). An all-zero zone
    #   vector with zones_known false means "no HR stream", not "0s in every zone"
    #   (summary avg_hr can exist without one — hr_known does not cover zones).
    #   Where a field is BOTH possible-zero and possibly-absent (decoupling_pct,
    #   form_delta_7d, hr_drift, rec_drop, and form_tsb in ANALYZE), a _known
    #   flag is MANDATORY — the flag is the null. Per PAYLOAD, not per field name:
    #   summary ships form_tsb bare because it is always computable there, so read
    #   the schema for the command rather than assuming the name carries a flag.
    # Surfaces: activity, activities, plan.recent_activities_14d carry
    # power_known/intensity_known/hr_known/zones_known + load_model; top carries the
    # first three. progress sessions carry only decoupling_known on purpose — rows exist only because
    # the group lens scored them, so the lens signal is present by construction.
    # Key-OMISSION (encode np_w as Try(F64, [Missing]) — Err drops the key) IS
    # expressible today and is the JSON-idiomatic alternative; it was rejected
    # because dropping a key is a REMOVAL (schema_version bump + every jq path
    # needs has()-guards), while flags are additive. Revisit if a bump happens anyway.

    # one payload, two mouths: JSON for machines, a pure Render screen for humans.
    # The pattern for query commands — payload record + Render.<cmd>_screen.
    # JSON envelope contract version. Bumped when the WRAPPER shape changes (NOT the
    # db schema_version / metrics_rev). Every machine response is versioned so tool
    # callers can detect a contract change.
    #
    # ADDING a field to a command's payload does NOT bump this, and that is a decision
    # rather than an oversight: the version describes `{schema_version, data}` vs
    # `{schema_version, error}`, not the keys inside `data`. A consumer reading known keys
    # is unaffected by a new one appearing beside them. Precedent: `converged` was added to
    # the analyze payload in 9c67470 without a bump. Bump when the wrapper changes, or when
    # a field is REMOVED or retyped — those do break a reader. See ADR 0007 Consequences.
    json_schema_version : I64
    json_schema_version = 2

    out! = |payload, render|
        if json_mode!({}) emit_ok!(payload) else Stdout.line!(render(payload))

    # every JSON success is wrapped `{ schema_version, data }`; `data` is the command
    # payload. Errors go through emit_err! and are `{ schema_version, error }` instead —
    # a caller discriminates success from failure by which key is present.
    emit_ok! = |val| {
        # The new compiler can't derive an encoder for a record literal with a generic
        # field inside a generic function (roc #10162), and Json.to_str demands infallible
        # field encoders (encode_f64 can fail on NaN/Infinity). Encoding the payload
        # DIRECTLY with the Try variant sidesteps both: it monomorphizes at each concrete
        # call site (like the platform's send_json!) and tolerates float edge cases. The
        # {schema_version, data} envelope is then assembled by interpolation. Our floats
        # are always finite, so Err never fires.
        d = Json.to_str_try(val) ? JsonEncodeFailed
        Stdout.line!("{\"schema_version\":${(json_schema_version).to_str()},\"data\":${d}}")
    }

    emit_err! : Str, Str => Try({}, _)
    emit_err! = |code, msg|
        Stdout.line!(Json.to_str({ schema_version: json_schema_version, error: { code, message: msg } }))
    # Output mode: humans get tables, machines ask for JSON — by `--json` on the
    # command (which re-execs with STRIDE_FORMAT set for the child, see app.roc)
    # or by STRIDE_FORMAT=json for a whole session.
    #
    # STRIDE_FORMAT is the ONLY environment input to this decision (#181). Stride
    # does not sniff the environment for the caller's identity: a mode inferred
    # from ambient state is one no documented command can describe, and it makes
    # the same invocation return a table here and an envelope there depending on
    # whose shell it ran in. Callers ask.
    json_mode! : {} => Bool
    json_mode! = |{}|
        match Env.var_str!(OsStr.from_str("STRIDE_FORMAT")) {
            Ok(v) => Str.with_ascii_lowercased(Str.trim(v)) == "json"
            Err(_) => False
        }
    # ── progress narration (ADR 0007) ────────────────────────────────────
    #
    # STDERR ONLY, always. stdout carries either the versioned envelope or the human
    # table — both deterministic and golden-fixtured — so narration must never touch it.
    # Stderr carries no contract, so a machine consumer parsing stdout never sees any of
    # this and no fixture changes.
    #
    # Dress follows the SAME output-mode switch as everything else, because basic-cli
    # exposes no tty check: humans get a `\r`-redrawn bar, machines get appended lines.
    # A carriage return is garbage in a CI log, so machine mode must never emit one.

    narrate! : Str, U64, U64 => Try({}, _)
    narrate! = |label, done, total|
        if json_mode!({}) {
            Stderr.line!(Render.progress_line(label, done, total))
        } else {
            # no newline: the next frame's `\r` returns here and overwrites in place
            Stderr.write!("\r${Render.progress_bar(label, done, total)}")
        }

    # Close the bar's line. Without this the command's first stdout line lands on the
    # same terminal row as the final frame, which reads as corruption. No-op in machine
    # mode, where every narration line was already terminated.
    narrate_done! : {} => Try({}, _)
    narrate_done! = |{}|
        if json_mode!({}) Ok({}) else Stderr.line!("")

    # a step with no countable total ("rebuilding daily load…"). Always its own line in
    # both modes — call narrate_done! first if a bar is mid-flight.
    say! : Str => Try({}, _)
    say! = |msg| Stderr.line!(msg)

    # ── prose only a HUMAN can act on (#259) ─────────────────────────────
    #
    # `auth`'s paste-the-code instructions, and nothing else so far. Unlike `say!` these
    # are the command's PRIMARY output in human mode, so they belong on stdout there —
    # and unlike a table they are not the machine answer, so in JSON mode they must not.
    #
    # They were unconditional `Stdout.line!`/`Stdout.write!`, which put prose on the
    # envelope's channel. The prompt made it visible rather than merely untidy: written
    # without a trailing newline, it left the envelope on the SAME LINE —
    # `code: {"error":{"code":"stdin_closed",...}}` — so `stride auth --json | tail -1 |
    # jq` was a parse error. `stdin_closed` exists to tell an unattended caller there was
    # no terminal to paste into, which is exactly the caller that parses rather than reads.
    #
    # Stderr rather than suppressed: a human running `stride auth --json` still deserves
    # to see what to do, and stderr carries no contract, so nothing on stdout moves.
    human_line! : Str => Try({}, _)
    human_line! = |msg| if json_mode!({}) Stderr.line!(msg) else Stdout.line!(msg)

    # ...and the no-newline form, for a prompt the answer is typed after. In JSON mode it
    # goes to stderr as a full LINE: the reason to omit the newline is that a human types
    # on the same row, and there is nobody typing on stderr.
    human_write! : Str => Try({}, _)
    human_write! = |msg| if json_mode!({}) Stderr.line!(msg) else Stdout.write!(msg)

    # a known, user-fixable error: machine-readable JSON for tool callers, a plain
    # line for humans, and exit 1 either way (#163) — the payload carries the
    # failure, the status carries the fact that there WAS one.
    err_out! : Str, Str => Try({}, _)
    err_out! = |code, msg| {
        (if json_mode!({})
            emit_err!(code, msg)
        else
            Stdout.line!(msg))?
        Err(Exit(error_status))
    }

    # unconfigured zones/FTP: JSON error for tools, the setup help for humans
    # The value is THERE and cannot be parsed -- naming the key and echoing the stored
    # text is the whole point, because `config get` will happily show it back and the
    # athlete has no other way to see why it is being ignored.
    ## The pure half, so a caller that must NOT exit can render the same sentence.
    ## `doctor` reports this condition in its payload rather than dying on it, and
    ## carried a truncated copy of the string until this was extracted — one that had
    ## dropped the remedy, which README describes as the thing every gap states.
    # The setup remedy for a client credential that is neither in the environment nor
    # stored. ONE definition, because it has two call sites: `auth!`, which met this first,
    # and the boundary arm in `app.roc` that catches the same tag surfacing from
    # `get_valid_token!`'s refresh branch. Two spellings of one remedy is how they drift.
    #
    # NOT split into a `_msg` half. ONE pair in this file earns that split:
    # `unreadable_config_msg`, which `ReportHealth` also calls to embed the prose in a
    # PAYLOAD rather than an error. The other three — `unreadable_activity_date_msg`,
    # `unreadable_activity_time_msg`, `unreadable_daily_load_day_msg` — have a single caller
    # each, so they are the shape-matching this note is about, not the precedent for it. An
    # earlier version of this comment said the pairs "elsewhere" earn it, generalising from
    # the one example that does; review measured the other three.
    missing_client_creds! : Str => Try({}, _)
    missing_client_creds! = |name|
        Output.err_out!("missing_client_creds", "${name} not set and no stored credentials yet — create a (free) Strava API app at strava.com/settings/api, then run:\n  STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth")

    unreadable_config_msg : Str, Str -> Str
    unreadable_config_msg = |key, raw|
        "${key} is set to '${raw}', which is not a number — fix it with `stride config set ${key} <value>`"

    # A stored DATE the engine cannot read, from the two tables these two errors are
    # raised for: `activities.start_local`, which stride mirrors from Strava, and
    # `daily_load.day`, which stride derives itself. There is a third date column,
    # `planned_sessions.target_date`, and it needs no code here for a good reason rather
    # than an accident: `plan_add!` rejects a non-canonical date with `bad_date` before
    # the database is opened, and it is the only writer of that column.
    #
    #
    # Separate codes rather than one, because the remedies are genuinely different: the
    # mirror row is repaired by re-fetching it, the derived row by rebuilding the table.
    # A caller told only "a date is bad" cannot pick between them. (The boundary's 401 arm
    # is the precedent for CHECKING that, not for splitting — it kept one code and widened
    # the message instead, which is the right call when the remedy really is identical.)
    #
    # These are NOT internal_error. That arm's message asks the user to open an issue,
    # which is the wrong instruction for both: nothing here is unanticipated — the code
    # constructs BadActivityDate and BadDailyLoadDay on purpose, at a date it deliberately
    # refuses to guess at. It just never reached the boundary as itself (#243).
    # PARENTHESISED, not "is" and not "beginning". `raw` is the COMPONENT that failed —
    # the ten-character day for a date fault, the time slice for a time fault — never the
    # whole column and not always its start. Saying "has start_local 'garbage-da'" sent the user to
    # `DELETE FROM activities WHERE start_local='garbage-da'`, which matches zero rows,
    # and made every bug report quoting it unreproducible. Measured against this PR's own
    # fixtures: '2026-3-01T06:00:00Z' printed as '2026-3-01T'. Carrying the whole column
    # out of the query was the other option and it is not available — SQLite's bare-column
    # rule only pins a value to the min/max row when there is ONE min/max aggregate, and
    # this query has three. Not available FROM THIS QUERY, to be exact — a second read by
    # `example_id` would return the true column. That is a round trip and a second failure
    # mode for a string the user does not need: the id is the handle they act on.
    #
    # The ID is therefore the only handle that works, so the remedy leads with it. The
    # order of the two remedies is not cosmetic either: `sync --all` was measured to
    # SILENTLY no-op on a row Strava does not list — an imported one, where `synced_at` is
    # NULL — returning `updated_activities: 0` at exit 0 and leaving the same error. So
    # `sync --all` will not repair an imported row, which is why the id-based remedy leads
    # and the sync one is stated as conditional.
    # EMPTY `raw` gets its own wording, because the parenthetical is the reproduction handle
    # and quoting `('')` makes it a false one. Every reader in #249 reaches this through
    # `COALESCE(substr(start_local, 1, 10), '')`, so a NULL column and a stored empty string
    # arrive identically — and "has an unreadable start_local ('')" reads as though the empty
    # string is what is stored, sending the user to
    # `DELETE FROM activities WHERE start_local=''`, which matches zero rows for a NULL. That
    # is the same defect this comment's own paragraph above records for 'garbage-da', one
    # value further along.
    #
    # It says NULL-or-empty rather than picking one, and that is deliberate rather than lazy:
    # the COALESCE has already collapsed the two by the time anything gets here, and the
    # distinction is not actionable — both repair the same way, by id. Carrying
    # `start_local IS NULL` as its own column through nine call sites would buy a word the
    # user cannot act on differently.
    unreadable_activity_date_msg : Str, I64 -> Str
    unreadable_activity_date_msg = |raw, id| {
        what =
            if Str.is_empty(raw) {
                "no usable start_local (the column is NULL or empty)"
            } else {
                "an unreadable start_local ('${raw}')"
            }
        "activity ${(id).to_str()} has ${what} — delete that row by id and re-sync, or run `stride sync --all` if Strava still lists the activity"
    }

    # The TIME half of the same column, and it needs its own wording for the reason the
    # paragraph above gives about `('')`. `raw` here is the nine characters after the date —
    # a COMPONENT, never the stored value — so quoting it the way the date message does puts
    # a string in the reproduction handle that `WHERE start_local='T37:00:00'` matches zero
    # rows of. Same defect, third instance: 'garbage-da' first, `('')` second, this third.
    #
    # So the component is named OUTSIDE the handle. The id stays where it was, leading the
    # remedy, because it is the only thing here anyone can act on.
    unreadable_activity_time_msg : Str, I64 -> Str
    unreadable_activity_time_msg = |raw, id| {
        what =
            if Str.is_empty(raw) {
                "no time after its date"
            } else {
                "an unreadable time after its date — the time component reads '${raw}'"
            }
        "activity ${(id).to_str()} has ${what} — delete that row by id and re-sync, or run `stride sync --all` if Strava still lists the activity"
    }

    unreadable_activity_time! : Str, I64 => Try({}, _)
    unreadable_activity_time! = |raw, id| {
        msg = unreadable_activity_time_msg(raw, id)
        (if json_mode!({})
            emit_err!("unreadable_activity_date", msg)
        else
            Stdout.line!(msg))?
        Err(Exit(error_status))
    }

    unreadable_activity_date! : Str, I64 => Try({}, _)
    unreadable_activity_date! = |raw, id| {
        msg = unreadable_activity_date_msg(raw, id)
        (if json_mode!({})
            emit_err!("unreadable_activity_date", msg)
        else
            Stdout.line!(msg))?
        Err(Exit(error_status))
    }

    # `stride analyze`, NOT `stride analyze --all` — that form does not exist and exits
    # with `usage`, which is the same defect this whole change is about: an error whose
    # remedy does not work. Measured: `analyze --all` answers
    # `usage: stride analyze — wrong arguments for this command`, exit 1.
    #
    # The remedy itself did not work either, in a state this error is reachable from.
    # rebuild_daily_load! only reached its DELETE when at least one activity date parsed;
    # with none, it returned Ok({}) and left the table exactly as it was — so `analyze`
    # answered `converged: true` at exit 0 and `season` answered this error again,
    # verbatim, forever. Fixed in Analyze.roc by clearing on that branch too. Recorded
    # here because the comment that stood in this spot said "verified end to end against
    # a poisoned snapshot", and it had been — against a snapshot that happened to hold
    # parseable activities. The evidence was real and the sentence generalized past it.
    unreadable_daily_load_day_msg : Str -> Str
    unreadable_daily_load_day_msg = |raw|
        "daily_load holds the day '${raw}', which is not a readable date — rebuild the table with `stride analyze`"

    unreadable_daily_load_day! : Str => Try({}, _)
    unreadable_daily_load_day! = |raw| {
        msg = unreadable_daily_load_day_msg(raw)
        (if json_mode!({})
            emit_err!("unreadable_daily_load_day", msg)
        else
            Stdout.line!(msg))?
        Err(Exit(error_status))
    }

    unreadable_config! : Str, Str => Try({}, _)
    unreadable_config! = |key, raw| {
        msg = unreadable_config_msg(key, raw)
        (if json_mode!({})
            emit_err!("unreadable_config", msg)
        else
            Stdout.line!(msg))?
        Err(Exit(error_status))
    }

    missing_config! : {} => Try({}, _)
    missing_config! = |{}| {
        (if json_mode!({})
            emit_err!("missing_config", "set your HR zone bounds first — see `stride config` (FTP is derived automatically)")
        else
            Stdout.line!(zone_config_help))?
        Err(Exit(error_status))
    }
}
