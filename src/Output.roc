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

    # The setup remedy for a client credential neither in the environment nor stored.
    # ONE definition, two call sites (`auth!` and the app.roc boundary arm) — two
    # spellings of one remedy is how they drift. NOT split into a `_msg` half: only
    # `unreadable_config_msg` earns that split, because `ReportHealth` embeds it in a
    # PAYLOAD; the other message pairs have a single caller each.
    missing_client_creds! : Str => Try({}, _)
    missing_client_creds! = |name|
        Output.err_out!("missing_client_creds", "${name} not set and no stored credentials yet — create a (free) Strava API app at strava.com/settings/api, then run:\n  STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth")

    # The value is THERE and cannot be parsed -- naming the key and echoing the stored
    # text is the whole point, because `config get` will happily show it back and the
    # athlete has no other way to see why it is being ignored.
    ## The pure half, so a caller that must NOT exit can render the same sentence.
    ## `doctor` reports this condition in its payload rather than dying on it, and
    ## carried a truncated copy of the string until this was extracted — one that had
    ## dropped the remedy, which README describes as the thing every gap states.
    unreadable_config_msg : Str, Str -> Str
    unreadable_config_msg = |key, raw|
        "${key} is set to '${raw}', which is not a number — fix it with `stride config set ${key} <value>`"

    # A stored DATE the engine cannot read, from the two tables these errors are
    # raised for: `activities.start_local` (mirrored) and `daily_load.day` (derived).
    # `planned_sessions.target_date` needs no code — `plan_add!` rejects
    # non-canonical dates on the write path and is the only writer.
    #
    # Separate codes because the remedies differ: re-fetch the mirror row vs rebuild
    # the derived table. NOT internal_error — nothing here is unanticipated, the
    # code refuses the date on purpose.
    #
    # PARENTHESISED, not "is": `raw` is the COMPONENT that failed, never the whole
    # column — quoting the whole start_local sent users to a DELETE matching zero
    # rows. The full column is not available from this query (three aggregates, so
    # SQLite's bare-column rule pins nothing) and the id is the handle anyway. The
    # remedy leads with the id because `sync --all` silently no-ops on an imported
    # row (synced_at NULL — Strava does not list it), so the sync remedy is stated
    # as conditional.
    #
    # EMPTY `raw` gets its own wording: NULL and '' arrive identically through the
    # COALESCE, and quoting ('') reads as though the empty string is stored. A BLOB
    # start_local is the remaining gap, recorded rather than repaired: the
    # parenthetical renders the decoded bytes, no TEXT literal can match a BLOB, and
    # the bytes can look like a perfectly plausible date — worse than visible
    # garbage, because the user copies a normal-looking handle into a DELETE and
    # gets zero rows with no signal. The id-based remedy is what works there, and
    # these rows only reach this message because #296 stopped them crashing first.
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

    # The TIME half of the same column, with its own wording: `raw` here is the nine
    # characters after the date — a COMPONENT, never the stored value — so quoting it
    # as the date message does puts a string in the reproduction handle that
    # `WHERE start_local='T37:00:00'` matches zero rows of. The component is named
    # OUTSIDE the handle; the id leads the remedy, being the only actionable thing.
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

    # `stride analyze`, NOT `--all` — that form does not exist and exits `usage`,
    # the same defect this change is about: a remedy that does not work. The remedy
    # itself also failed once, in a state this error is reachable from:
    # rebuild_daily_load! only reached its DELETE when at least one activity date
    # parsed, so `analyze` said `converged: true` while `season` answered this error
    # forever. Fixed in Analyze.roc by clearing on that branch too.
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

    # unconfigured HR zones: JSON error for tools, the setup help for humans
    missing_config! : {} => Try({}, _)
    missing_config! = |{}| {
        (if json_mode!({})
            emit_err!("missing_config", "set your HR zone bounds first — see `stride config` (FTP is derived automatically)")
        else
            Stdout.line!(zone_config_help))?
        Err(Exit(error_status))
    }
}
