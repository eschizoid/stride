import Db
import Output
import Strava
import Streams
import Analyze
import Csv
import pf.Sqlite
import pf.Stdout
import pf.Path
import Metrics
import Sports
import Render

Report :: [].{
    # ── shared queries ──────────────────────────────────────────────────

    # ONE home for the load_model -> confidence-tier mapping (#157): doctor's
    # session counts and summary's TSS-weighted coverage read these same lists,
    # so the ladder cannot drift between surfaces. high = measured power (and
    # rtss: pace threshold derives from measured speed), medium = HR/RPE-scaled,
    # low = relative_effort (Strava's opaque estimate).
    high_models_sql = "'power_stream','weighted_watts','avg_watts','rtss'"

    # "is this activity's stored date readable", in SQL, for the sites that cannot call
    # Metrics.usable_date_days because they need the answer inside a query — the `activities`
    # ORDER BY hoist, `date_known` on `activities` and `top`, and `doctor`'s undateable count.
    #
    # ONE constant because it was four byte-identical copies, and the count is not the
    # argument. Review pinned the value of exactly ONE of them: the `1000-02-30` fixture
    # holds the `activities` copy, `top` and `doctor` were validated only for the KEY's
    # presence and type by the schema loop, and a predicate that drifted to always-0 — or a
    # copy edited in one place — passed everything. Collapsing them makes that one fixture
    # hold all four sites by construction, which is strictly better than three more value
    # checks over four things that must agree.
    #
    # The ROUND TRIP through SQLite's own date(), plus the year bound. It agrees with
    # usable_date_days on every shape measured, impossible-but-well-formed days included
    # ('2026-02-30', '1000-02-30'), and that agreement is version-dependent: the system CLI
    # here is 3.43.2 and returns '2026-02-30' verbatim, while the binary links 3.49.1 and
    # does not. `date_known` is a PUBLISHED boolean SKILL.md tells the coach to trust, so the
    # e2e fixture for '1000-02-30' — the one shape only the newer date() rejects — is what
    # holds SQL to the Roc rule across a platform upgrade.
    # The SQL twin of Metrics.usable_date_days lives THERE now, beside the Roc rule it has
    # to agree with — `Analyze` and `Strava` also rank on this column and cannot import
    # Report, which imports them. This stays as the name four sites already use.
    date_known_sql = Metrics.date_known_sql_for("a.start_local")
    # ...and its sibling, for the same reason and the same four-copies argument. `date_known`
    # answers "is the DATE readable"; this answers "is the TIME usable", and the two together
    # are exactly what every ranking site requires (#281).
    time_known_sql = Metrics.time_known_sql_for("a.start_local")
    medium_models_sql = "'hr_zones','hr_avg','session_rpe'"
    low_models_sql = "'relative_effort'"

    # TSS-weighted tier sums for one window: {high, medium, low} as F64 TSS
    coverage_sums! : Str, Str => Try({ high : F64, medium : F64, low : F64 }, _)
    coverage_sums! = |path, cutoff|
        Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT CAST(COALESCE(SUM(CASE WHEN m.load_model IN (${high_models_sql}) THEN m.tss ELSE 0 END),0) AS REAL) AS hi,
                \\       CAST(COALESCE(SUM(CASE WHEN m.load_model IN (${medium_models_sql}) THEN m.tss ELSE 0 END),0) AS REAL) AS med,
                \\       CAST(COALESCE(SUM(CASE WHEN m.load_model IN (${low_models_sql}) THEN m.tss ELSE 0 END),0) AS REAL) AS lo
                \\FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
                \\WHERE a.start_local >= :cutoff
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff) }],
            row: |cols| |stmt| {
                hi = Sqlite.f64("hi")(cols)(stmt)?
                med = Sqlite.f64("med")(cols)(stmt)?
                lo = Sqlite.f64("lo")(cols)(stmt)?
                Ok({ high: hi, medium: med, low: lo })
            },
        })

    # zone + TSS totals for activities on/after a cutoff date
    zone_sum! : Str, Str => Try({ z1 : I64, z2 : I64, z3 : I64, z4 : I64, z5 : I64, tss : F64, measured : F64, easy : I64, moderate : I64, hard : I64, sessions : I64, moving_time : I64, distance_m : F64, hr_streams : I64, intensity_streams : I64 }, _)
    zone_sum! = |path, cutoff|
        Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(SUM(m.z1_s),0) AS z1, COALESCE(SUM(m.z2_s),0) AS z2, COALESCE(SUM(m.z3_s),0) AS z3,
                \\       COALESCE(SUM(m.z4_s),0) AS z4, COALESCE(SUM(m.z5_s),0) AS z5, CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss,
                \\       -- load from a MEASURED source — a power meter or distance-measured pace
                \\       -- (high-confidence rungs) — vs estimated from HR/RPE/relative-effort
                \\       CAST(COALESCE(SUM(CASE WHEN m.load_model IN (${high_models_sql}) THEN m.tss ELSE 0 END),0) AS REAL) AS measured,
                \\       -- polarization intensity per activity: the pi_* split when the activity
                \\       -- has one (power-derived with watts, pace-derived for a distance sport
                \\       -- without), else the HR zones. So a power ride's threshold work counts
                \\       -- as hard even when HR sat on a zone boundary.
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_easy_s ELSE m.z1_s + m.z2_s END),0) AS easy,
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_moderate_s ELSE m.z3_s END),0) AS moderate,
                \\       COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_hard_s ELSE m.z4_s + m.z5_s END),0) AS hard,
                \\       COUNT(*) AS sessions, COALESCE(SUM(a.moving_time),0) AS moving_time,
                \\       CAST(COALESCE(SUM(a.distance),0) AS REAL) AS distance_m,
                \\       COALESCE(SUM(CASE WHEN s.raw_json LIKE '%"heartrate"%' THEN 1 ELSE 0 END),0) AS hr_streams,
                \\       COALESCE(SUM(CASE WHEN s.raw_json LIKE '%"heartrate"%' OR s.raw_json LIKE '%"watts"%' OR s.raw_json LIKE '%"distance"%' THEN 1 ELSE 0 END),0) AS intensity_streams
                \\FROM activities a
                \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\LEFT JOIN streams s ON s.activity_id = a.id
                \\WHERE a.start_local >= :cutoff
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff) }],
            row: |cols| |stmt| {
                z1 = Sqlite.i64("z1")(cols)(stmt)?
                z2 = Sqlite.i64("z2")(cols)(stmt)?
                z3 = Sqlite.i64("z3")(cols)(stmt)?
                z4 = Sqlite.i64("z4")(cols)(stmt)?
                z5 = Sqlite.i64("z5")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                measured = Sqlite.f64("measured")(cols)(stmt)?
                easy = Sqlite.i64("easy")(cols)(stmt)?
                moderate = Sqlite.i64("moderate")(cols)(stmt)?
                hard = Sqlite.i64("hard")(cols)(stmt)?
                sessions = Sqlite.i64("sessions")(cols)(stmt)?
                moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                distance_m = Sqlite.f64("distance_m")(cols)(stmt)?
                hr_streams = Sqlite.i64("hr_streams")(cols)(stmt)?
                intensity_streams = Sqlite.i64("intensity_streams")(cols)(stmt)?
                Ok({ z1, z2, z3, z4, z5, tss, measured, easy, moderate, hard, sessions, moving_time, distance_m, hr_streams, intensity_streams })
            },
        })

    # activity stats within a half-open [from, to) date window (both are date strings
    # compared against start_local; ISO makes the lexical compare correct)
    window_stats! : Str, Str, Str => Try({ z1 : I64, z2 : I64, z3 : I64, z4 : I64, z5 : I64, tss : F64, sessions : I64 }, _)
    window_stats! = |path, from_str, to_str|
        Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(SUM(m.z1_s),0) AS z1, COALESCE(SUM(m.z2_s),0) AS z2, COALESCE(SUM(m.z3_s),0) AS z3,
                \\       COALESCE(SUM(m.z4_s),0) AS z4, COALESCE(SUM(m.z5_s),0) AS z5,
                \\       CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss, COUNT(*) AS sessions
                \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE a.start_local >= :from AND a.start_local < :to
            ,
            bindings: [{ name: ":from", value: String(from_str) }, { name: ":to", value: String(to_str) }],
            row: |cols| |stmt| {
                z1 = Sqlite.i64("z1")(cols)(stmt)?
                z2 = Sqlite.i64("z2")(cols)(stmt)?
                z3 = Sqlite.i64("z3")(cols)(stmt)?
                z4 = Sqlite.i64("z4")(cols)(stmt)?
                z5 = Sqlite.i64("z5")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                sessions = Sqlite.i64("sessions")(cols)(stmt)?
                Ok({ z1, z2, z3, z4, z5, tss, sessions })
            },
        })

    # CTL as of a given day (most recent daily_load row on or before it); 0 if none
    ctl_at! : Str, Str => Try(F64, _)
    ctl_at! = |path, day_str|
        match Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT ctl AS ctl FROM daily_load WHERE day <= :d ORDER BY day DESC LIMIT 1",
            bindings: [{ name: ":d", value: String(day_str) }],
            row: Sqlite.f64("ctl"),
        }) {
            Ok(v) => Ok(v)
            Err(NoRowsReturned) => Ok(0.0)
            Err(e) => Err(e)
        }

    # period-over-period: this rolling window vs the one immediately before it
    compare! : Str => Try({}, _)
    compare! = |period| {
        path = Db.open_db!({})?
        if period != "week" and period != "month" {
            Output.err_out!("bad_period", "compare week | compare month (got '${period}')")
        } else {
            days = if period == "month" 28 else 7
            label = if period == "month" "28d" else "7d"
            match Sqlite.query!({ path: Path.utf8(path), query: "SELECT COALESCE(day, '') AS day FROM daily_load ORDER BY day DESC LIMIT 1", bindings: [], row: Sqlite.str("day") }) {
                Err(NoRowsReturned) => Output.err_out!("no_data", "nothing analyzed yet — run `stride sync` (or `stride import`) then `stride analyze`")
                Err(e) => Err(e)
                Ok(latest_day) => {
                    # PROPAGATE, through the same helper summary_payload! uses on the same
                    # anchor 130 lines below. (Same anchor semantics, NOT the same
                    # statement — that one selects day, ctl, atl and tsb.) Collapsing to
                    # epoch day 0 here does not fail loudly — it answers. Measured on one
                    # poisoned row: a real 28-day block (138
                    # TSS, 2 sessions, 58% easy) came back as `has_data: false`, every
                    # figure 0, exit 0, and the human line said "no load recorded either 28d
                    # · fitness holding". `summary` refused on the same database in the same
                    # run. An athlete told their fitness is holding, by a command that could
                    # not read the day it anchored on, is the worst shape this class has.
                    anchor = canonical_day(latest_day)?
                    # AFTER the daily_load anchor, before the windows. Both halves matter.
                    #
                    # After, because `summary` reads its anchor first too, and putting this
                    # sweep at the top of the command made `compare` answer
                    # `unreadable_activity_date` on a database where `summary` answered
                    # `unreadable_daily_load_day` — two commands disagreeing about which of
                    # two faults they met first, over the same rows. e2e pins that agreement
                    # and caught it.
                    #
                    # Before the windows, because an unreadable date does not make this
                    # command answer wrongly about one row — it removes the row from BOTH
                    # windows and the DELTA between them is what `compare` publishes.
                    # Measured with one date NULLed on an otherwise unchanged database:
                    # 331 vs 319 became 270 vs 319, and the verdict crossed a category, from
                    # "load steady (4%)" to "load backed off (-16%)", at exit 0 with
                    # has_data true.
                    _ = guard_activity_dates!(path)?
                    cur_from = Metrics.days_to_date_str(anchor - (days - 1))
                    cur_to = Metrics.days_to_date_str(anchor + 1)
                    pri_from = Metrics.days_to_date_str(anchor - (2 * days - 1))
                    cur = window_stats!(path, cur_from, cur_to)?
                    pri = window_stats!(path, pri_from, cur_from)?
                    cur_ctl = ctl_at!(path, Metrics.days_to_date_str(anchor))?
                    pri_ctl = ctl_at!(path, Metrics.days_to_date_str(anchor - days))?
                    # has_data distinguishes a genuinely-empty window (no activities AND no
                    # accrued fitness) from a real all-easy/zero week. Without it the prior
                    # block reads as "0 TSS, 0% easy, 0 ctl" — indistinguishable from a rest
                    # week — and the current-vs-prior delta looks like a phantom spike.
                    block = |w, ctl| {
                        tss: w.tss,
                        sessions: w.sessions,
                        hard_min: (w.z4 + w.z5) // 60,
                        easy_pct: pct_num(w.z1 + w.z2, w.z1 + w.z2 + w.z3 + w.z4 + w.z5),
                        ctl,
                        has_data: w.sessions > 0 or ctl > 0.0,
                    }
                    Output.out!({ period, window_label: label, current: block(cur, cur_ctl), prior: block(pri, pri_ctl) }, Render.compare_screen)
                }
            }
        }
    }

    # does a row with this id exist? (table is an internal literal, never user input)
    row_exists! : Str, Str, I64 => Try(Bool, _)
    row_exists! = |path, table, id| {
        n = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT COUNT(*) AS n FROM ${table} WHERE id = :id",
            bindings: [{ name: ":id", value: Integer(id) }],
            row: Sqlite.i64("n"),
        })?
        Ok(n > 0)
    }
    # The daily_load.day guard. BOTH halves — canonical and parseable — because the
    # non-canonical day is the dangerous one, not the harmless one: `ORDER BY day DESC` is
    # a string sort, so "2026-3-05" beats every "2026-08-xx" and becomes `latest`.
    #
    # Used by every read of that column here that must not ABSORB: the two anchors and the
    # ramp series. The ramp series needs it separately, because a bad day only has to BE
    # the anchor when it sorts highest — put a canonical day above it and the poisoned row
    # slips into the 30-day window with the anchor guard none the wiser, publishing a
    # ramp_7d of -49 and a form_delta of -79 under `form_delta_known: true`, at exit 0.
    # `load_series!` below now goes through it too, which closes the last reader of this
    # column that absorbed. This sentence used to say the opposite and call it a known open
    # defect — a claim about tracker state, asserted in the branch that closes it, so
    # `tools/issue-claims.sh` would have gone red the moment #249 did.
    #
    # Scoped to the property rather than the count on purpose. The PREDICATE is factored
    # into Metrics.usable_date_days and every site in the tree calls it, so what can differ
    # between them is which tag each raises — which is the part that should differ.
    canonical_day : Str -> Try(I64, _)
    canonical_day = |d| (Metrics.usable_date_days(d)).map_err(|_| BadDailyLoadDay(d))

    # Same rule, different table, so a different tag: an activity date is repaired by
    # re-fetching or deleting the ROW, a daily_load day by rebuilding the table, and the
    # boundary picks the message from the tag. Takes the id rather than inventing one:
    # naming the date alone is what #243 was opened about, and "activity -1" would be that
    # defect wearing a number.
    canonical_activity_day : Str, I64 -> Try(I64, _)
    canonical_activity_day = |d, id| (Metrics.usable_date_days(d)).map_err(|_| BadActivityDate(d, id))

    # Every stored activity date, refused if any is unreadable, naming a row.
    #
    # ONE BODY, because it was copies of the same query and the next copy is how a rule
    # drifts. #243's last rounds were spent collapsing exactly this shape — five spellings of
    # "canonical and parseable" that had to agree and did not.
    #
    # FIVE call sites, reaching `rate`, `week`, `compare`, `summary`, `plan` and `stats`.
    # `season` is NOT one of them and that is deliberate, not an omission: it guards inline
    # over its own query, which groups by (date, family) rather than by date, so the id it
    # names is the lowest within the group the walk reaches first. Sharing this body there
    # would name a different row than its own comment promises.
    #
    # The count is written down because it was wrong three ways at once — "four commands"
    # here, "six" in the commit message, and a list naming `season` two files over. A number
    # in a comment is a claim like any other.
    #
    # CONTRACT FOR CALLERS: a command that reads `daily_load` must guard THAT column before
    # calling this. The reason is the user's path, not consistency for its own sake. With
    # both faults present, `analyze` — the daily_load remedy — clears the poisoned day AND
    # surfaces the activity fault in the same run, exiting non-zero: one user action between
    # the two messages. Measured. Reverse the order and it costs strictly more — the user
    # deletes the activity row, re-syncs, runs `compare`, and meets a second failure nobody
    # warned them about, which `analyze` would have told them for free.
    #
    # `stats` and `week` name the activity row first, and that is not an inconsistency to
    # tidy away: they never read `daily_load`, so it is the only fault they can see. Every
    # message is true and the terminal state is reached from either entry point.
    #
    # The fragile holder is `summary`, not `compare`. `compare` holds the order locally and
    # visibly — anchor at :158, sweep at :175. `summary` holds it ACROSS TWO FUNCTIONS: the
    # daily_load guard, and this sweep inside `hard_day_block!`, which runs later. Nothing
    # but call order and one e2e check holds that, so it is the site that breaks first if
    # either function is reorganised.
    #
    # It exists as a WHOLE-TABLE sweep rather than a per-query guard because of the failure
    # mode it covers, which is the one #249's split had no row for. `summary`, `season` and
    # `plan` compute an ordering or an anchor, and a guard on the read is enough. `compare`
    # and `stats` do something else with the date: they use it as a FILTER over an aggregate
    # — `WHERE start_local >= :from AND < :to`, or `>= '0000-01-01'` meaning "everything".
    # An unreadable date makes that comparison NULL, so the row does not produce a wrong
    # value, it silently LEAVES THE SET, and the failure is an absence rather than a
    # fabrication. Review measured both: `compare` moved its verdict from
    # "load steady (4%)" to "load backed off (-16%)" with one date NULLed, and `stats`
    # reported 474 sessions under a heading that says ALL TIME while holding 475. Exit 0,
    # has_data true, no marker, on a screen an athlete reads for a decision.
    #
    # A guard on the filtering query itself could not catch that — the row is already gone
    # by the time the rows come back, which is why it survived a review that was looking for
    # wrong numbers rather than missing ones.
    guard_activity_dates! : Str => Try({}, _)
    guard_activity_dates! = |path| {
        act_days = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(substr(start_local, 1, 10), '') AS d, MIN(id) AS example_id
                \\FROM activities GROUP BY d ORDER BY d, example_id
            ,
            bindings: [],
            rows: |cols| |stmt| {
                d = Sqlite.str("d")(cols)(stmt)?
                example_id = Sqlite.i64("example_id")(cols)(stmt)?
                Ok({ d, example_id })
            },
        })?
        _ = List.map_try(act_days, |r| canonical_activity_day(r.d, r.example_id))?
        Ok({})
    }

    pct_num : I64, I64 -> I64
    pct_num = |part, total|
        if total == 0
            0
        else
            ((part).to_f64() * 100.0 / (total).to_f64()).round_to_i64_try().ok_or(0)

    # one session in depth: metrics + zones + power bests computed from local streams
    summary! : {} => Try({}, _)
    summary! = |{}| {
        path = Db.open_db!({})?
        match Analyze.load_zone_config!(path) {
            Err(MissingConfig) => Output.missing_config!({})
            Err(other) => Err(other)
            Ok(zb) =>
                match summary_payload!(path, zb) {
                    Err(NoDataYet) => Output.err_out!("no_data", "nothing analyzed yet — run `stride sync` (or `stride import`) then `stride analyze`")
                    Err(e) => Err(e)
                    Ok(payload) => Output.out!(payload, Render.summary_screen)
                }
        }
    }
    # The hard-day block of summary_payload!, lifted whole (#196). It is the one
    # self-contained stretch in that function -- three inputs, one record out, and
    # nothing downstream re-reads an intermediate. `hard_expr` stays inside: it is SQL
    # text used twice here and nowhere else, and returning it would put a query
    # fragment in a payload record.
    hard_day_stats! = |path, anchor, cutoff28| {
        # most recent day with a real hard stimulus (5+ min in Z4/Z5); '' = never
        # ONE hard-session predicate (#159): power-aware like every other hard
        # surface (week's hard column, polarization) — pi_hard when the activity
        # has a pi_* intensity split (power- or pace-derived), HR Z4+Z5 otherwise,
        # 5+ min either way.
        # last_hard previously used HR zones alone, which missed power-only rides
        # with junk HR straps; consolidated rather than grown a second definition.
        # MAX(substr(...)) is a STRING max and reached the payload with no Roc-side parse
        # at all, so a malformed start_local shipped verbatim into a field the schema calls
        # a date — measured: last_hard_session_date: "2026-3-05T". Covered by the all-time
        # sweep below, NOT by anything in this query: a cutoff-scoped guard cannot see a
        # row this one can return, because this one has no cutoff.
        hard_expr = "COALESCE(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_hard_s ELSE m.z4_s + m.z5_s END, 0) >= 300"
        last_hard = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(MAX(substr(a.start_local, 1, 10)), '') AS d
                \\FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
                \\WHERE ${hard_expr}
            ,
            bindings: [],
            row: Sqlite.str("d"),
        })?
        # stimulus features (#159): counts, spacing, and windowed loads the coach
        # would otherwise re-derive from raw lists — measurements only, never
        # judgments (hard_days.d14 is a count; whether 4 is "too many" is
        # the coach's call, per the #154 boundary)
        # ONE sweep over every activity date, before any of the reads below. This is what
        # makes those reads safe, and it replaces a per-query guard that was wrong in a way
        # worth recording: MIN(a.id) inside a GROUP BY names the lowest id IN THE GROUP,
        # not the id of the row whose date is the MAX — so guarding sports_28d.last_date
        # that way named a healthy activity and pointed the user at the wrong row.
        #
        # It also covers the two string MAXes that have no parse at all to hang a guard on:
        # `last_hard` (all-time, so a cutoff-scoped guard cannot see it — one malformed hard
        # session older than 28 days with none inside the window shipped "0000-0z-02" into
        # last_hard_session_date at exit 0) and `sports_28d.last_date` (no hard_expr, so any
        # poisoned activity sorting above the cutoff became its sport's "last seen").
        #
        # All-time, matching `season`, which already refuses any activity with an unreadable
        # date. `summary` was the surface where the same row answered at exit 0.
        _ = guard_activity_dates!(path)?
        hard_days = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(substr(a.start_local, 1, 10), '') AS d,
                \\       -- carried so a refused date can name a row, as everywhere else in
                \\       -- #243. MIN because DISTINCT on the date collapses several
                \\       -- activities onto one day and the id has to be reproducible;
                \\       -- ORDER BY makes "first" a stated property rather than SQLite's.
                \\       MIN(a.id) AS example_id
                \\FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
                \\WHERE ${hard_expr} AND a.start_local >= :cutoff
                \\GROUP BY d ORDER BY d, example_id
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff28) }],
            rows: |cols| |stmt| {
                d = Sqlite.str("d")(cols)(stmt)?
                example_id = Sqlite.i64("example_id")(cols)(stmt)?
                Ok({ d, example_id })
            },
        })?
        # PROPAGATE, on the same rule and for the same reason as the daily_load reads
        # above — every activity date this fold parses goes through it.
        # `keep_oks` was doing both jobs badly: it dropped an unparseable date SILENTLY and
        # it ACCEPTED a non-canonical one, so the fold both under-counted and mis-dated.
        # Measured: a fabricated days_since_last shipped under days_since_known: true,
        # which is the shape the ramp fix removed one screen up in this same file.
        hard_day_nums = List.map_try(hard_days, |r| canonical_activity_day(r.d, r.example_id))?
        # Str has no ordering — count on parsed day numbers, same anchor math
        hard_d14 = List.len(List.keep_if(hard_day_nums, |d| d >= anchor - 13))
        spacing = Metrics.median_gap_days(hard_day_nums)
        days_since_hard =
            match List.sort_with(hard_day_nums, |a, b| if a > b LT else if a < b GT else EQ) {
                [newest_hard, ..] => Known(anchor - newest_hard)
                [] => Unknown
            }
        # ANNOTATED Bools: this payload is encode-only, and a bare tag would
        # serialize as the STRING "True" (the #32-class flag bug, pinned in e2e)
        spacing_known_b : Bool
        spacing_known_b = match spacing { Known(_) => True  Unknown => False }
        days_since_known_b : Bool
        days_since_known_b = match days_since_hard { Known(_) => True  Unknown => False }
        Ok({ last_hard, d14: hard_d14, d28: (List.len(hard_day_nums)).to_i64_wrap(), spacing, days_since: days_since_hard, spacing_known: spacing_known_b, days_since_known: days_since_known_b })
    }

    summary_payload! = |path, zb| {
        # empty daily_load (nothing analyzed yet) is a clean "no data" state, not an
        # error to blow up on — map NoRowsReturned to a tag the callers turn into a
        # friendly message instead of leaking a raw SQLite error to the user.
        latest =
            match Sqlite.query!({
                path: Path.utf8(path),
                query: "SELECT COALESCE(day, '') AS day, ctl AS ctl, atl AS atl, tsb AS tsb FROM daily_load ORDER BY day DESC LIMIT 1",
                bindings: [],
                row: |cols| |stmt| {
                    day = Sqlite.str("day")(cols)(stmt)?
                    ctl = Sqlite.f64("ctl")(cols)(stmt)?
                    atl = Sqlite.f64("atl")(cols)(stmt)?
                    tsb = Sqlite.f64("tsb")(cols)(stmt)?
                    Ok({ day, ctl, atl, tsb })
                },
            }) {
                Ok(v) => Ok(v)
                Err(NoRowsReturned) => Err(NoDataYet)
                Err(e) => Err(e)
            }?
        # PROPAGATE a bad anchor day, exactly as the ramp rows below do — the same guard,
        # applied to the value those rows are compared AGAINST. Defaulting to epoch day 0
        # here is worse than for a row: this one binding drives every cutoff, the ramp
        # window, form_delta_7d and days_in_band. A junk `day` sorts to the top of
        # `ORDER BY day DESC` (string sort), becomes `latest`, and then either lands the
        # cutoffs in the far future (every window returns nothing, and summary prints a
        # confident all-zero report) or in 1969 (every "last 28 days" window silently
        # becomes all-time). Both exit 0 with nothing flagged.
        anchor = canonical_day(latest.day)?
        # Inclusive >= cutoffs: today plus 27/59 prior days are true 28/60-day windows.
        cutoff28 = Metrics.days_to_date_str(anchor - 27)
        cutoff60 = Metrics.days_to_date_str(anchor - 59)

        zsum = zone_sum!(path, cutoff28)?

        # the RIDE family's population, same as pz — this was a global cross-sport
        # MAX, which happened to equal the ride max only while no other family
        # out-rowed it (#151 round 2: the exact bug one level up)
        best20_row = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT CAST(COALESCE(MAX(m.best_20min_w),0) AS REAL) AS b FROM activity_metrics m
                \\JOIN activities a ON a.id = m.activity_id
                \\WHERE a.sport_family = :fam AND a.start_local >= :cutoff
            ,
            bindings: [{ name: ":fam", value: String(Sports.canonical("Ride")) }, { name: ":cutoff", value: String(cutoff60) }],
            row: Sqlite.f64("b"),
        })?

        sports = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.sport_type AS sport, COUNT(*) AS sessions, CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss,
                \\       COALESCE(SUM(a.moving_time),0) AS moving_time, CAST(COALESCE(SUM(a.distance),0) AS REAL) AS distance_m,
                \\       COALESCE(MAX(substr(a.start_local, 1, 10)), '') AS last_date
                \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE a.start_local >= :cutoff
                \\GROUP BY a.sport_type ORDER BY tss DESC, a.sport_type
            ,
            bindings: [{ name: ":cutoff", value: String(cutoff28) }],
            rows: |cols| |stmt| {
                sport = Sqlite.str("sport")(cols)(stmt)?
                sessions = Sqlite.i64("sessions")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                distance_m = Sqlite.f64("distance_m")(cols)(stmt)?
                # when this sport was last seen (#159) — '' can't happen inside the
                # window filter, but COALESCE keeps the decoder total
                last_date = Sqlite.str("last_date")(cols)(stmt)?
                Ok({ sport, sessions, tss, moving_time, distance_m, last_date })
            },
        })?


        cutoff7 = Metrics.days_to_date_str(anchor - 6)
        zsum7 = zone_sum!(path, cutoff7)?
        # TSS-weighted confidence coverage per window (#157): 7d and 28d speak for
        # the load numbers beside them; 90d spans two CTL time constants, so it is
        # the honest provenance for CTL/ATL/TSB. Percentages sum to exactly 100
        # (Metrics.coverage_pcts) and known=false marks an empty window — 0/0/0
        # with known true would claim a measurement nobody took (ADR 0009).
        cutoff90 = Metrics.days_to_date_str(anchor - 89)
        cov7_raw = coverage_sums!(path, cutoff7)?
        cov28_raw = coverage_sums!(path, cutoff28)?
        cov90_raw = coverage_sums!(path, cutoff90)?
        cov_block = |c| {
            pcts = Metrics.coverage_pcts(c.high, c.medium, c.low)
            known : Bool
            known = c.high + c.medium + c.low > 0.0
            { high_pct: pcts.high_pct, medium_pct: pcts.medium_pct, low_pct: pcts.low_pct, known }
        }
        cov7 = cov_block(cov7_raw)
        cov28 = cov_block(cov28_raw)
        cov90 = cov_block(cov90_raw)

        pending = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT COUNT(*) AS n FROM planned_sessions WHERE COALESCE(status, 'open') = 'open'",
            bindings: [],
            row: Sqlite.i64("n"),
        })?

        hd = hard_day_stats!(path, anchor, cutoff28)?
        last_hard = hd.last_hard
        hard_d14 = hd.d14
        spacing = hd.spacing
        days_since_hard = hd.days_since
        spacing_known_b : Bool
        spacing_known_b = hd.spacing_known
        days_since_known_b : Bool
        days_since_known_b = hd.days_since_known
        # windowed loads + prior windows of the SAME length, deltas raw. The
        # prior-7d window is [-13..-7] and prior-28d is [-55..-28]: adjacent,
        # non-overlapping, same width — the delta compares like with like.
        loadw = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT CAST(COALESCE(SUM(CASE WHEN a.start_local >= :c90 THEN m.tss ELSE 0 END),0) AS REAL) AS d90,
                \\       CAST(COALESCE(SUM(CASE WHEN a.start_local >= :p7lo AND a.start_local < :c7 THEN m.tss ELSE 0 END),0) AS REAL) AS p7,
                \\       CAST(COALESCE(SUM(CASE WHEN a.start_local >= :p28lo AND a.start_local < :c28 THEN m.tss ELSE 0 END),0) AS REAL) AS p28
                \\FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
            ,
            bindings: [
                { name: ":c90", value: String(Metrics.days_to_date_str(anchor - 89)) },
                { name: ":p7lo", value: String(Metrics.days_to_date_str(anchor - 13)) },
                { name: ":c7", value: String(cutoff7) },
                { name: ":p28lo", value: String(Metrics.days_to_date_str(anchor - 55)) },
                { name: ":c28", value: String(cutoff28) },
            ],
            row: |cols| |stmt| {
                d90 = Sqlite.f64("d90")(cols)(stmt)?
                p7 = Sqlite.f64("p7")(cols)(stmt)?
                p28 = Sqlite.f64("p28")(cols)(stmt)?
                Ok({ d90, p7, p28 })
            },
        })?
        # threshold trajectory: the ride-family best-20-min of the PRIOR 60-day
        # window ([-119..-60]) beside the current one — the delta says which way
        # the demonstrated ceiling moved; known=false when the prior window has
        # no power (a delta against nothing is not 0, ADR 0009)
        prior_best20 = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT CAST(COALESCE(MAX(m.best_20min_w),0) AS REAL) AS b,
                \\       CASE WHEN MAX(m.best_20min_w) IS NULL THEN 0 ELSE 1 END AS bk
                \\FROM activity_metrics m
                \\JOIN activities a ON a.id = m.activity_id
                \\WHERE a.sport_family = :fam AND a.start_local >= :lo AND a.start_local < :hi
            ,
            bindings: [
                { name: ":fam", value: String(Sports.canonical("Ride")) },
                { name: ":lo", value: String(Metrics.days_to_date_str(anchor - 119)) },
                { name: ":hi", value: String(cutoff60) },
            ],
            row: |cols| |stmt| {
                b = Sqlite.f64("b")(cols)(stmt)?
                bk = Sqlite.i64("bk")(cols)(stmt)?
                Ok({ b, bk })
            },
        })?
        # flag decodes the stored NULL, never the magnitude (ADR 0009)
        prior_b20_known_b : Bool
        prior_b20_known_b = prior_best20.bk != 0

        # polarization is intensity-aware: easy/moderate/hard come from the pi_* split for
        # activities that have one (power-derived with watts, pace-derived for a distance
        # sport without), HR zones otherwise (zone_sum! per-activity)
        total = zsum.easy + zsum.moderate + zsum.hard
        easy = zsum.easy
        hard = zsum.hard
        # what fraction of the 28d load is measured (power OR distance-measured pace) vs estimated
        # (HR/RPE/RE) —
        # so the fitness number carries its own confidence, not just doctor's
        measured_pct = if zsum.tss > 0.0 ((zsum.measured / zsum.tss) * 100.0).round_to_i64_try().ok_or(0) else 0
        total7 = zsum7.easy + zsum7.moderate + zsum7.hard
        easy7 = zsum7.easy
        hard7 = zsum7.hard

        # CTL/ATL seed at zero on the first day with any activity, so a short history reads
        # LOW rather than unknown. One 42-day time constant only gets CTL to ~63% of its true
        # value, so 42 days is where it is still MOST wrong, not where it becomes right; the
        # threshold is two constants (~90 d, ~88% converged), past which the form bands —
        # absolute numbers — start meaning something. COUNT(*) always returns a row, so this
        # query cannot hit the absent-key crash.
        load_days = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT COUNT(*) AS n FROM daily_load",
            bindings: [],
            row: Sqlite.i64("n"),
        })?

        # #93 ramp: reuses the `anchor` this function already computed, rather than
        # deriving the same day again — two bindings for one day can drift, and then the
        # ramp window and summary's 7d/28d windows would disagree about which day "now"
        # is. 30 days of series covers the 28-day ramp lookback with room for gaps — and now
        # also bounds days_in_band, which has NO natural upper limit. That is why the streak
        # returns AtLeast when it fills this window rather than a bare number: widening the
        # window moves the truncation point, it does not remove it.
        ramp_rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT COALESCE(day, '') AS day, CAST(ctl AS REAL) AS ctl, CAST(tsb AS REAL) AS tsb FROM daily_load WHERE day >= :cutoff ORDER BY day DESC",
            bindings: [{ name: ":cutoff", value: String(Metrics.days_to_date_str(anchor - 30)) }],
            rows: |cols| |stmt| {
                d = Sqlite.str("day")(cols)(stmt)?
                c = Sqlite.f64("ctl")(cols)(stmt)?
                # tsb rides along on the ramp query rather than getting its own: the two
                # lookbacks want the same rows over the same window, and a second query
                # could disagree with this one about which days exist (#111).
                t = Sqlite.f64("tsb")(cols)(stmt)?
                Ok({ d, ctl: c, tsb: t })
            },
        })?
        # Convert OUTSIDE the decoder, whose error union has no room for BadDate, and
        # PROPAGATE rather than defaulting a bad day to epoch-day 0. That default is not
        # harmless: a day-0 row is a valid candidate for any lookback, so where the series
        # genuinely does not reach back far enough, ctl_as_of would return that row's ctl
        # as Found instead of Missing — a fabricated ramp exactly where the honest answer
        # is 0. daily_load days are engine-written and canonical, so this is a guard
        # against corruption, and corruption should stop the command rather than quietly
        # change the number it prints.
        # Prepend, not append: ctl_as_of takes the max qualifying day and so does not care
        # about order, and appending inside a fold is the quadratic trap.
        dated_load = List.fold(ramp_rows, Ok([]), |acc, r|
            match acc {
                Err(e) => Err(e)
                Ok(xs) =>
                    match canonical_day(r.d) {
                        Ok(day) => Ok(List.prepend(xs, { day, ctl: r.ctl, tsb: r.tsb }))
                        Err(e) => Err(e)
                    }
            })?
        # one validated series, two views — each helper takes a closed record, so the
        # projections keep the date validation above from being done twice
        ramps = Metrics.ramp_rates(List.map(dated_load, |e| { day: e.day, ctl: e.ctl }), anchor)
        form_delta = Metrics.form_delta_7d(List.map(dated_load, |e| { day: e.day, tsb: e.tsb }), anchor)
        # how long the band has held (#123) — the thing the label itself cannot say
        band_days = Metrics.days_in_band(List.map(dated_load, |e| { day: e.day, tsb: e.tsb }), anchor)
        # ANNOTATED Bool, not a bare `True`/`False` tag. The builtin JSON serializes an
        # unconstrained tag as the STRING "True". This payload happens to escape that
        # already — but for a reason worth stating correctly, because the wrong reason
        # teaches the wrong rule: it is RENDERED as well as encoded, and
        # `Render.summary_screen` consumes the field as an `if` condition, which flows the
        # Bool constraint back through the un-annotated renderer. analyze's payload is
        # encode-only, so nothing constrained it and it shipped "True". Neighbouring Bool
        # fields have nothing to do with it — record fields do not constrain one another.
        # The rule: an encode-only payload has no constraint on its tags, so annotate.
        band_capped : Bool
        band_capped = match band_days { AtLeast(_) => True  _ => False }
        delta_known : Bool
        delta_known = match form_delta { Known(_) => True  Unknown => False }

        Ok({
            as_of: latest.day,
            fitness_ctl: latest.ctl,
            ramp_7d: ramps.ramp_7d,
            ramp_28d_avg: ramps.ramp_28d_avg,
            fatigue_atl: latest.atl,
            form_tsb: latest.tsb,
            # stable machine identifier for the form band (#154) — ADDITIVE; clients
            # switch on this instead of re-deriving band boundaries from raw TSB
            form_state: Metrics.form_state(latest.tsb),
            # ADDITIVE field, so the envelope version stays (same precedent as `converged`
            # and the ramp fields). Unknown flattens to 0.0 here, which is the house
            # meaning of a numeric 0 — "not available", not "form did not move". The human
            # renderer keeps the distinction and simply omits the clause.
            form_delta_7d: match form_delta { Known(d) => d  Unknown => 0.0 },
            # 0.0 is ambiguous HERE in a way the house "0 = not available" rule does not
            # cover: form genuinely level for a week is a real, useful answer that is also
            # exactly 0. So the flag carries what the number cannot, for machine consumers
            # as much as for the renderer.
            form_delta_known: delta_known,
            # 0 = not available, per the house rule; a real streak is always >= 1.
            # The value alone cannot say whether it is exact or truncated by the window,
            # so it travels with a flag — see form_band_days_capped.
            form_band_days: match band_days { Known(n) => n  AtLeast(n) => n  Unknown => 0 },
            # TRUE means the streak filled the whole series and is a FLOOR, not a count.
            # `dated_load` is a 31-day window sized for the #93 ramp, so a 45-day streak
            # arrives here as 31; without this flag the coach reads 31 as fact. Annotated
            # Bool for the same reason delta_known is.
            form_band_days_capped: band_capped,
            load_days: load_days,
            ctl_warming_up: load_days < 90,
            last_hard_session_date: last_hard,
            # stimulus features (#159) — counts and spacing are MEASUREMENTS; the
            # spacing/days-since flags are the ADR 0009 null (0 with known false)
            hard_days: {
                d14: (hard_d14).to_i64_wrap(),
                d28: hd.d28,
                spacing_median_days_28d: match spacing { Known(g) => g  Unknown => 0 },
                spacing_known: spacing_known_b,
                days_since_last: match days_since_hard { Known(d) => d  Unknown => 0 },
                days_since_known: days_since_known_b,
            },
            # windowed loads with same-width adjacent prior windows; deltas raw
            load_windows: {
                d7: zsum7.tss,
                d28: zsum.tss,
                d90: loadw.d90,
                prior_d7: loadw.p7,
                prior_d28: loadw.p28,
                delta_7d: zsum7.tss - loadw.p7,
                delta_28d: zsum.tss - loadw.p28,
            },
            pending_sessions: pending,
            last_7d: {
                tss: zsum7.tss,
                z1_s: zsum7.z1,
                z2_s: zsum7.z2,
                z3_s: zsum7.z3,
                z4_s: zsum7.z4,
                z5_s: zsum7.z5,
                easy_pct: pct_num(easy7, total7),
                moderate_pct: pct_num(zsum7.moderate, total7),
                hard_pct: pct_num(hard7, total7),
                sessions: zsum7.sessions,
                moving_time: zsum7.moving_time,
                distance_m: zsum7.distance_m,
                hr_streams: zsum7.hr_streams,
                intensity_streams: zsum7.intensity_streams,
                load_coverage: cov7,
            },
            last_28d: {
                tss: zsum.tss,
                z1_s: zsum.z1,
                z2_s: zsum.z2,
                z3_s: zsum.z3,
                z4_s: zsum.z4,
                z5_s: zsum.z5,
                easy_pct: pct_num(easy, total),
                moderate_pct: pct_num(zsum.moderate, total),
                hard_pct: pct_num(hard, total),
                measured_pct: measured_pct,
                sessions: zsum.sessions,
                moving_time: zsum.moving_time,
                distance_m: zsum.distance_m,
                hr_streams: zsum.hr_streams,
                intensity_streams: zsum.intensity_streams,
                load_coverage: cov28,
            },
            # provenance for the CTL/ATL/TSB numbers above: what the trailing ~two
            # CTL time constants of load are MADE of. Descriptive only (#154) —
            # stride states the mix, the coach decides whether it matters.
            form_coverage_90d: cov90,
            ftp: {
                best_20min_w_60d: best20_row,
                estimated_ftp_w: Metrics.ftp_from_best_20min(best20_row),
                # trajectory (#159): the PRIOR 60d window's best beside the current —
                # which way the demonstrated ceiling moved; known=false = no power
                # in that window (a delta against nothing is not 0)
                prior_60d_best_20min_w: prior_best20.b,
                prior_60d_known: prior_b20_known_b,
            },
            hr_zones: { z1_max: zb.z1_max, z2_max: zb.z2_max, z3_max: zb.z3_max, z4_max: zb.z4_max },
            sports_28d: sports,
        })
    }
    sport_filter_sql : Str -> { frag : Str, binds : List({ name : Str, value : [Null, Real(F64), Integer(I64), String(Str), Bytes(List(U8))] }) }
    sport_filter_sql = |word|
        if Str.is_empty(word) {
            # a lone SPACE, never "": interpolating a compile-time-constant empty
            # string USED to be the #32-class str_concat trap. Fixed upstream in
            # roc#10595 (closed 2026-08-04, before this pin), so this is now a style
            # rule rather than survival — non-empty by construction, same as Plan.roc
            { frag: " ", binds: [] }
        } else {
            fam = Sports.family(word)
            names = List.map_with_index(fam, |_, i| ":sp${(i).to_str()}")
            { frag: " AND a.sport_type COLLATE NOCASE IN (${Str.join_with(names, ", ")})", binds: List.map_with_index(fam, |s, i| { name: ":sp${(i).to_str()}", value: String(s) }) }
        }

    # the no-silent-empty hint: what sports DOES the data hold
    load_series! : U64 => Try({}, _)
    load_series! = |days| {
        path = Db.open_db!({})?
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT COALESCE(day, '') AS day, tss AS tss, ctl AS ctl, atl AS atl, tsb AS tsb FROM daily_load ORDER BY day DESC LIMIT ${(days).to_str()}",
            bindings: [],
            rows: |cols| |stmt| {
                day = Sqlite.str("day")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                ctl = Sqlite.f64("ctl")(cols)(stmt)?
                atl = Sqlite.f64("atl")(cols)(stmt)?
                tsb = Sqlite.f64("tsb")(cols)(stmt)?
                Ok({ day, tss, ctl, atl, tsb })
            },
        })?
        # GUARDED here rather than in Render. Not because Render could not act — it has a
        # third option and uses it four lines from the damage, at the `keep_oks` that builds
        # `tsb_series` — but because a pure renderer can DROP the row and cannot NAME it, and
        # naming the row is the whole of #243. (An earlier version of this comment claimed
        # Render's only options were to absorb or invent. That is false, it is visible on
        # screen next to the code, and stating it would have invited the decision to be
        # re-litigated on a premise anyone could disprove in ten seconds.)
        #
        # What Render absorbed is real: `.ok_or(0)` collapsed an unreadable day to epoch 0,
        # rendering a `1969-12-29` week row carrying real load numbers under a verdict line
        # saying "form 0 — balanced", at exit 0. And the fabricated row was not confined to
        # the table — `List.last(ordered)` makes it `today`, so the VERDICT was computed from
        # it too: a poisoned day measured `form -6 — modeled fatigue building` off a trend
        # anchored at epoch. Fixing only the table row would have left the verdict lying.
        #
        # Extending `keep_oks` here would have removed both without refusing anything, and it
        # is the smaller change. It is still the wrong one: dropping the row silently
        # under-counts the weekly rollup's sessions and load with no marker, which trades a
        # large absorption for a small one. `daily_load` is DERIVED, so the remedy is one
        # command and the message says it; contrast `activities`, where the row is source
        # data and the user must delete and re-sync.
        #
        # Refusing the whole command costs nothing that was ever available, either: a
        # lexically-high garbage day sorts to the top of `ORDER BY day DESC`, so it is inside
        # every window — `load 7`, `load 14` and `load 90` all meet it.
        #
        # Same rule and same helper as every other daily_load.day read in this module
        # (#243), so `load` stops being the one command that answers where the rest refuse.
        # The asymmetry was already visible on one database: `summary` and `compare`
        # refused while `load` printed the invented week.
        _ = List.map_try(rows, |r| canonical_day(r.day))?
        ordered = List.fold(rows, [], |acc, x| List.concat([x], acc))
        Output.out!(ordered, Render.load_screen)
    }

    # power-duration curve: the best mean-max power sustained for each ladder duration,
    # taken as the MAX across a window (per sport), plus a Critical Power / W' fit over the
    # aerobic points. Reads the stored best_<dur>_w columns — no stream re-read. 0-power
    # durations (no ride long enough) are dropped, so the curve only shows real data.
    # ── season view (#139, ADR 0011) ────────────────────────────────────
    # Blocks are bounded by ABSENCE and described by measurement. Nothing here
    # names a phase: "base"/"build"/"peak" are claims about intent, and load
    # observes only volume.
    cp_fit_as_of! : Str, Str, Str, U64 => Try({ cp : F64, w_prime : F64, points : I64, family : Str, r2 : F64, pts : List({ dur_s : F64, watts : F64 }) }, _)
    cp_fit_as_of! = |path, family, on_date, days| {
        row = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT CAST(COALESCE(MAX(m.best_300s_w), 0) AS REAL) AS d300,
                \\       CAST(COALESCE(MAX(m.best_600s_w), 0) AS REAL) AS d600,
                \\       CAST(COALESCE(MAX(m.best_20min_w), 0) AS REAL) AS d1200
                \\FROM activity_metrics m JOIN activities a ON a.id = m.activity_id
                \\WHERE a.sport_family = :fam
                \\  AND substr(a.start_local, 1, 10) < :on
                \\  AND a.start_local >= date(:on, '-' || :days || ' days')
            ,
            bindings: [
                { name: ":fam", value: String(family) },
                { name: ":on", value: String(on_date) },
                { name: ":days", value: String((days).to_str()) },
            ],
            row: |cols| |stmt| {
                d300 = Sqlite.f64("d300")(cols)(stmt)?
                d600 = Sqlite.f64("d600")(cols)(stmt)?
                d1200 = Sqlite.f64("d1200")(cols)(stmt)?
                Ok({ d300, d600, d1200 })
            },
        })?
        pts = List.keep_if(
            [{ dur_s: 300.0, watts: row.d300 }, { dur_s: 600.0, watts: row.d600 }, { dur_s: 1200.0, watts: row.d1200 }],
            |p| p.watts > 0.0,
        )
        match Metrics.critical_power(pts) {
            Ok(c) => Ok({ cp: c.cp, w_prime: c.w_prime, points: (List.len(pts)).to_i64_wrap(), family, r2: c.r2, pts })
            Err(_) => Ok({ cp: 0.0, w_prime: 0.0, points: (List.len(pts)).to_i64_wrap(), family, r2: 0.0, pts })
        }
    }

    # Time to exhaustion at a caller-named power (#187). NOT the same fit
    # power-curve publishes: that one spans every power sport and includes
    # today, this one is per-family and excludes its anchor date. They agree
    # on an athlete whose rides dominate the curve, and only then. Every refusal is explicit:
    # no fit, at-or-below CP, or a result outside the 2-20 minute band where the
    # 2-parameter model holds — that last still returns the number, LABELLED,
    # rather than hiding it or pretending it is trustworthy.
}
