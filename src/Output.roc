import pf.Stdout
import pf.Stderr
import pf.Env
import pf.OsStr
import Render

Output :: [].{
    usage! : Str => Try({}, _)
    usage! = |u|
        Stdout.line!("usage: stride ${u}")

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
    # Missing-value contract (#156): literal JSON null is NOT expressible — the
    # builtin encoder stringifies tags ("None"/"Null"), verified by probe. So the
    # contract is per-field, two classes:
    #   IMPOSSIBLE-ZERO fields (np_w, avg_hr, intensity, ftp_used…): a real 0 cannot
    #   occur, so 0 unambiguously means "not available" — and the important surfaces
    #   ALSO carry a _known companion flag (power_known, hr_known) so no client has
    #   to know which fields are impossible-zero.
    #   REAL-ZERO fields (z5_s, tss on an unscored row, distance on strength…): 0 is
    #   an observation. Where a field is BOTH possible-zero and possibly-absent
    #   (decoupling_pct, form_delta_7d, form_tsb, hr_drift, rec_drop_60s), a _known
    #   flag is MANDATORY — the flag is the null.
    # Revisit literal null if the upstream encoder ever learns to emit it.

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
    # output mode: humans get tables by default; LLM callers set STRIDE_FORMAT=json
    # (CLAUDECODE env also flips to json for harnesses that set it)
    json_mode! : {} => Bool
    json_mode! = |{}|
        match Env.var_str!(OsStr.from_str("STRIDE_FORMAT")) {
            Ok(v) => Str.with_ascii_lowercased(Str.trim(v)) == "json"
            Err(_) =>
                match Env.var_str!(OsStr.from_str("CLAUDECODE")) {
                    # set-but-empty is not "on" — require a non-empty value
                    Ok(v) => !(Str.is_empty(v))
                    Err(_) => False

                }
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

    # a known, user-fixable error: machine-readable JSON for tool callers, a plain
    # line for humans. Exit stays 0 (in-band errors are the codebase convention —
    # same as plan-add's dedup guard); the payload carries the failure.
    err_out! : Str, Str => Try({}, _)
    err_out! = |code, msg|
        if json_mode!({})
            emit_err!(code, msg)
        else
            Stdout.line!(msg)

    # unconfigured zones/FTP: JSON error for tools, the setup help for humans
    missing_config! : {} => Try({}, _)
    missing_config! = |{}|
        if json_mode!({})
            emit_err!("missing_config", "set your HR zone bounds first — see `stride config` (FTP is derived automatically)")
        else
            Stdout.line!(zone_config_help)
}
