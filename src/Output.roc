import pf.Stdout
import pf.Env
import pf.OsStr

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
    # Convention: numeric fields COALESCE to 0 when unknown (0 = "not available").

    # one payload, two mouths: JSON for machines, a pure Render screen for humans.
    # The pattern for query commands — payload record + Render.<cmd>_screen.
    # JSON envelope contract version. Bumped when the wrapper shape changes (NOT the
    # db schema_version / metrics_rev). Every machine response is versioned so tool
    # callers can detect a contract change.
    json_schema_version : I64
    json_schema_version = 1

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
    # a known, user-fixable error: machine-readable JSON for tool callers, a plain
    # line for humans. Exit stays 0 (in-band errors are the codebase convention —
    # same as plan-add's dedup guard); the payload carries the failure.
    err_out! : Str, Str => Try({}, _)
    err_out! = |code, msg|
        if json_mode!({})
            emit_err!(code, msg)
        else
            Stdout.line!(msg)

    # unconfigured HR zones: JSON error for tools, the setup help for humans
    missing_config! : {} => Try({}, _)
    missing_config! = |{}|
        if json_mode!({})
            emit_err!("missing_config", "set your HR zone bounds first — see `stride config` (FTP is derived automatically)")
        else
            Stdout.line!(zone_config_help)
}
