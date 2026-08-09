import Db
import Output
import Strava
import Report
import pf.Sqlite
import pf.Stdout
import pf.Path
import Metrics
import Render

Plan :: [].{
    # session-RPE rating: the athlete is the sensor for sports without power meters.
    # Ratings live in their OWN table (the judgment tier) — never on the activities
    # mirror, which sync/import replace wholesale. Rating an activity invalidates its
    # metrics so the next analyze rescores it through the sport-aware ladder.
    rate! : Str, Str => Try({}, _)
    rate! = |target, rpe_str| {
        path = Db.open_db!({})?
        rpe_result =
            match F64.from_str(rpe_str) {
                Ok(r) if r >= 1.0 and r <= 10.0 => Ok(r)
                _ => Err(BadRpe)
            }
        match rpe_result {
            Err(_) => Output.err_out!("bad_rpe", "rate needs an effort from 1 (easy) to 10 (max) — got '${rpe_str}'")
            Ok(rpe) => {
                id_result =
                    if target == "latest" {
                        match Sqlite.query!({
                            path: Path.utf8(path),
                            query: "SELECT COALESCE(MAX(id), 0) AS id FROM activities WHERE start_local = (SELECT MAX(start_local) FROM activities)",
                            bindings: [],
                            row: Sqlite.i64("id"),
                        }) {
                            Ok(0) => Err(NoActivities)
                            Ok(id) => Ok(id)
                            Err(e) => Err(e)
                        }
                    } else {
                        I64.from_str(target).map_err(|_| BadId)
                    }
                match id_result {
                    Err(BadId) => Output.err_out!("bad_id", "rate needs an activity id or 'latest': rate <activity_id|latest> <1-10>")
                    Err(NoActivities) => Output.err_out!("no_activities", "nothing to rate yet — `stride sync` or `stride import` first")
                    Err(other) => Err(other)
                    Ok(activity_id) =>
                        if !(Report.row_exists!(path, "activities", activity_id)?) {
                            Output.err_out!("activity_not_found", "no activity ${I64.to_str(activity_id)} in the db — `stride sync` first?")
                        } else {
                            Sqlite.execute!({
                                path: Path.utf8(path),
                                query: "INSERT OR REPLACE INTO ratings (activity_id, rpe, rated_at) VALUES (:id, :rpe, :at)",
                                bindings: [
                                    { name: ":id", value: Integer(activity_id) },
                                    { name: ":rpe", value: Real(rpe) },
                                    { name: ":at", value: String(Metrics.epoch_to_iso(Db.now_secs!({}))) },
                                ],
                            })?
                            # a rating is a metric input — invalidate so analyze rescores
                            Strava.invalidate_metrics!(path, activity_id)?
                            Output.out!({ rated: activity_id, rpe }, |p| "activity ${I64.to_str(p.rated)} rated ${Render.fmt0(p.rpe)}/10 — run `stride analyze` to rescore")
                        }
                }
            }
        }
    }
    plan_view! : [ThisWeek, AllTime] => Try({}, _)
    plan_view! = |scope| {
        path = Db.open_db!({})?
        # default view is the CURRENT training week (Mon-Sun containing today) so `plan`
        # is "this week at a glance", not the whole history spilling into next week. The
        # Monday offset is rem(days+3,7) — the same convention as Metrics.day_of_week.
        today = Db.local_today_days!(path)
        mon = today - (today + 3) % (7)
        # default `plan` is the LIVE current-week plan. Re-planning a date leaves skipped
        # tombstones (skip-then-add), so hide a skipped row that something SUPERSEDES — either
        # a live open/done session on that date, or a LATER row on that date. That second arm
        # matters when the whole day ends up skipped: with no live session to supersede them,
        # every earlier draft used to surface, so a re-planned-then-missed day rendered as
        # near-identical duplicate rows. A day that was genuinely missed still shows its one
        # final tombstone (nothing supersedes it) — the adherence miss you want to see.
        # `plan all` shows the full log unfiltered.
        # scope filter via a BOUND :all flag, never string interpolation: AllTime binds
        # :all=1 (all rows); ThisWeek binds :all=0 so the date/skip conditions apply. The
        # earlier approach interpolated an optional filter string whose EMPTY branch spliced
        # a compile-time-constant "" into the query, crashing the backend in str_concat
        # (heap-corruption SIGABRT, same class as #32). The date literals below are always
        # non-empty, so they interpolate safely.
        scope_all =
            match scope {
                AllTime => 1
                ThisWeek => 0
            }
        # `plan all` must mean ALL: the older-sessions count and the note pointing at the
        # JSON are both lies if the query silently truncates. SQLite treats a negative
        # LIMIT as unbounded, so this stays a BOUND value — no interpolated clause, which
        # is the pattern that spliced an empty string into the query and crashed the
        # backend (see the :all note above).
        row_limit =
            match scope {
                AllTime => -1
                ThisWeek => 100
            }
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT id AS id, COALESCE(created_at,'') AS created_at, COALESCE(target_date,'') AS target_date,
                \\       COALESCE(session_type,'') AS session_type, COALESCE(detail,'') AS detail,
                \\       COALESCE(rationale,'') AS rationale, COALESCE(completed_activity_id,0) AS completed_activity_id,
                \\       COALESCE(status,'open') AS status, COALESCE(skipped_reason,'') AS skipped_reason,
                \\       COALESCE((SELECT substr(a.start_local,1,10) FROM activities a WHERE a.id = planned_sessions.completed_activity_id), '') AS done_date
                \\FROM planned_sessions
                \\WHERE (:all = 1 OR (COALESCE(target_date,'') >= '${Metrics.days_to_date_str(mon)}' AND COALESCE(target_date,'') <= '${Metrics.days_to_date_str(mon + 6)}' AND (COALESCE(status,'open') <> 'skipped' OR NOT EXISTS (SELECT 1 FROM planned_sessions p2 WHERE p2.target_date = planned_sessions.target_date AND (COALESCE(p2.status,'open') <> 'skipped' OR p2.id > planned_sessions.id)))))
                \\ORDER BY target_date DESC, id DESC LIMIT :lim
            ,
            bindings: [{ name: ":all", value: Integer(scope_all) }, { name: ":lim", value: Integer(row_limit) }],
            rows: |cols| |stmt| {
                id = Sqlite.i64("id")(cols)(stmt)?
                created_at = Sqlite.str("created_at")(cols)(stmt)?
                target_date = Sqlite.str("target_date")(cols)(stmt)?
                session_type = Sqlite.str("session_type")(cols)(stmt)?
                detail = Sqlite.str("detail")(cols)(stmt)?
                rationale = Sqlite.str("rationale")(cols)(stmt)?
                completed_activity_id = Sqlite.i64("completed_activity_id")(cols)(stmt)?
                status = Sqlite.str("status")(cols)(stmt)?
                skipped_reason = Sqlite.str("skipped_reason")(cols)(stmt)?
                done_date = Sqlite.str("done_date")(cols)(stmt)?
                Ok({ id, created_at, target_date, session_type, detail, rationale, completed_activity_id, status, skipped_reason, done_date })
            },
        })?
        # newest-first from SQL, flipped to calendar order for display. `Render.reverse_list`
        # (fold + prepend, linear) rather than fold + `List.concat([x], acc)`, which copies
        # the whole accumulator every step and is quadratic — harmless behind the old
        # LIMIT 100, unbounded now that `plan all` returns the full log.
        ordered = Render.reverse_list(rows)
        dow = |date_str|
            match Metrics.date_str_to_days(date_str) {
                Ok(d) => Metrics.day_of_week(d)
                Err(_) => ""
            }
        # enrich ONCE with the day-of-week; both output modes consume the same rows
        # (constructed explicitly — Roc's `&` can only update fields, not add one)
        enriched = List.map(ordered, |p| {
            id: p.id,
            created_at: p.created_at,
            target_date: p.target_date,
            day: dow(p.target_date),
            session_type: p.session_type,
            detail: p.detail,
            rationale: p.rationale,
            completed_activity_id: p.completed_activity_id,
            status: p.status,
            skipped_reason: p.skipped_reason,
            done_date: p.done_date,
            # A session completed by an activity from ANOTHER day used to render exactly
            # like one completed on time — the plan silently implied the work happened on
            # the date it was prescribed for. Show the real day when they differ.
            status_shown:
                if p.status == "done" and p.done_date != "" and p.done_date != p.target_date {
                    # Full date, year included: `plan all` spans years, so a bare month-day
                    # would be ambiguous exactly where the log is longest. The wider cell
                    # costs a line of wrapping in the detail column; that is the cheaper loss.
                    "done (${dow(p.done_date)} ${p.done_date})"
                } else {
                    p.status
                },
        })
        # `plan all` splits the log into sections: a single slab answers "whatever
        # happened" when the question at hand is usually "what's coming". Partitioned by
        # WEEK rather than by today, so no row can land in two sections — an open session
        # later this week belongs to `this week`, not to `upcoming`. Sections are
        # presentation only; the JSON payload stays one flat array.
        plan_headers = ["day", "date", "type", "status", "detail", "id"]
        plan_cells = |p| [p.day, p.target_date, p.session_type, p.status_shown, p.detail, (p.id).to_str()]
        # an empty section says so rather than vanishing — an absent heading reads as
        # "there is no such thing", which is a different claim from "nothing there yet"
        section = |title, srows|
            if List.is_empty(srows) {
                "── ${title} ──\n(none)"
            } else {
                "── ${title} ──\n${Render.render_table(plan_headers, List.map(srows, plan_cells))}"
            }
        Output.out!(enriched, |rows_enriched|
            match scope {
                ThisWeek => Render.render_table(plan_headers, List.map(rows_enriched, plan_cells))
                AllTime => {
                    # Parse each target_date ONCE and carry the result alongside its row:
                    # every section below tests the same boundaries, so filtering on the
                    # date string re-parsed it four times per row. Keyed here rather than
                    # folded into `enriched` so the JSON payload keeps its shape.
                    # `dated` matters as much as the number. `plan add` stores whatever
                    # date string it is handed (no validation), so an unparseable one is
                    # reachable from the CLI, not just by hand-editing the db. Collapsing
                    # it to day 0 would file a typo under "older sessions" and quietly
                    # claim it was in the past — it is undated, which is a different fact.
                    keyed = List.map(rows_enriched, |p|
                        match Metrics.date_str_to_days(p.target_date) {
                            Ok(n) => { row: p, n, dated: True }
                            Err(_) => { row: p, n: 0, dated: False }
                        })
                    pick = |pred| List.map(List.keep_if(keyed, pred), |k| k.row)
                    # The rule is DATE ONLY, no status filter, and that is deliberate on
                    # both counts. #97's original text said "open sessions dated after
                    # today"; partitioning by week instead keeps a row out of two sections
                    # at once (an open session later this week is `this week`, not
                    # `upcoming`), and dropping the status test keeps a future-dated
                    # skipped row visible — skipping next Tuesday in advance is a normal
                    # act, and an open-only filter would leave that row in no section and
                    # outside the hidden count, i.e. silently gone.
                    upcoming = pick(|k| k.dated and k.n > mon + 6)
                    current = pick(|k| k.dated and k.n >= mon and k.n <= mon + 6)
                    # history reads newest-first: its top row sits directly under `this
                    # week`, so the most recent past is nearest the present
                    history = Render.reverse_list(pick(|k| k.dated and k.n < mon and k.n >= mon - 7))
                    # Unrendered sessions are COUNTED, never silently dropped: `plan all`
                    # still means all, and the JSON payload carries every row. Printing the
                    # number keeps the human view short without the view lying about what
                    # exists — including the undated rows, which belong to no week at all.
                    older = List.len(List.keep_if(keyed, |k| k.dated and k.n < mon - 7))
                    undated = List.len(List.keep_if(keyed, |k| !k.dated))
                    hidden =
                        if older > 0 and undated > 0 {
                            "${(older).to_str()} older, ${(undated).to_str()} undated"
                        } else if undated > 0 {
                            "${(undated).to_str()} undated"
                        } else {
                            "${(older).to_str()} older"
                        }
                    # count the whole hidden set, not either part: the noun trails the
                    # entire list, so "1 older, 1 undated" is two sessions and stays plural
                    noun = if older + undated == 1 "session" else "sessions"
                    older_note =
                        if older == 0 and undated == 0 {
                            ""
                        } else {
                            "\n\n(${hidden} ${noun} not shown — STRIDE_FORMAT=json stride plan all has every row)"
                        }
                    "${Str.join_with([section("upcoming", upcoming), section("this week", current), section("last week", history)], "\n\n")}${older_note}"
                }
            })
    }
    plan_add! : Str, Str, Str, Str => Try({}, _)
    plan_add! = |target_date, session_type, detail, rationale| {
        path = Db.open_db!({})?
        # guard: one open planned session per date — skip or complete the old one first
        existing = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT COALESCE(MAX(id), 0) AS id FROM planned_sessions WHERE target_date = :date AND COALESCE(status, 'open') = 'open'",
            bindings: [{ name: ":date", value: String(target_date) }],
            row: Sqlite.i64("id"),
        })?
        if existing > 0
            # re-planning a date REVISES its open session in place. Editing a future plan
            # is not a "skip" (skip = a session that was going to happen and didn't), so
            # revising keeps one row per date instead of stacking a skipped tombstone every
            # time the week is re-planned — the root cause of the plan graveyard.
            revise_planned_session!(path, existing, target_date, session_type, detail, rationale)
        else
            insert_planned_session!(path, target_date, session_type, detail, rationale)
    }
    revise_planned_session! : Str, I64, Str, Str, Str, Str => Try({}, _)
    revise_planned_session! = |path, id, target_date, session_type, detail, rationale| {
        Sqlite.execute!({
            path: Path.utf8(path),
            query: "UPDATE planned_sessions SET session_type = :type, detail = :detail, rationale = :rationale, created_at = :at WHERE id = :id",
            bindings: [
                { name: ":type", value: String(session_type) },
                { name: ":detail", value: String(detail) },
                { name: ":rationale", value: String(rationale) },
                { name: ":at", value: String(Metrics.epoch_to_iso(Db.now_secs!({}))) },
                { name: ":id", value: Integer(id) },
            ],
        })?
        Output.out!({ id, target_date, session_type }, |p| "revised #${(p.id).to_str()}: ${p.session_type} on ${p.target_date}")
    }
    insert_planned_session! : Str, Str, Str, Str, Str => Try({}, _)
    insert_planned_session! = |path, target_date, session_type, detail, rationale| {
        Sqlite.execute!({
            path: Path.utf8(path),
            query:
                \\INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status)
                \\VALUES (:at, :date, :type, :detail, :rationale, 'open')
            ,
            bindings: [
                { name: ":at", value: String(Metrics.epoch_to_iso(Db.now_secs!({}))) },
                { name: ":date", value: String(target_date) },
                { name: ":type", value: String(session_type) },
                { name: ":detail", value: String(detail) },
                { name: ":rationale", value: String(rationale) },
            ],
        })?
        new_id = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT MAX(id) AS id FROM planned_sessions",
            bindings: [],
            row: Sqlite.i64("id"),
        })?
        Output.out!({ id: new_id, target_date, session_type }, |p| "planned #${(p.id).to_str()}: ${p.session_type} on ${p.target_date}")
    }
    # ONE not-found message for complete/complete-rest/skip — can't drift apart
    session_not_found! : I64 => Try({}, _)
    session_not_found! = |session_id|
        Output.err_out!("session_not_found", "no planned session #${(session_id).to_str()} — run `stride plan` to see ids")

    complete! : Str, Str => Try({}, _)
    complete! = |session_id_str, activity_id_str| {
        path = Db.open_db!({})?
        match (I64.from_str(session_id_str), I64.from_str(activity_id_str)) {
            (Ok(session_id), Ok(activity_id)) =>
                # SQLite UPDATE matching 0 rows is not an error — check existence
                # ourselves so a typo'd id can't report false success and silently
                # leave the planned session open / the coaching log out of sync
                if !(Report.row_exists!(path, "planned_sessions", session_id)?) {
                    session_not_found!(session_id)
                } else if !(Report.row_exists!(path, "activities", activity_id)?) {
                    Output.err_out!("activity_not_found", "no activity ${I64.to_str(activity_id)} in the db — `stride sync` first?")
                } else {
                    Sqlite.execute!({
                        path: Path.utf8(path),
                        query: "UPDATE planned_sessions SET completed_activity_id = :aid, status = 'done' WHERE id = :pid",
                        bindings: [
                            { name: ":aid", value: Integer(activity_id) },
                            { name: ":pid", value: Integer(session_id) },
                        ],
                    })?
                    Output.out!({ completed_session: session_id, activity: activity_id }, |p| "planned session #${I64.to_str(p.completed_session)} completed by activity ${I64.to_str(p.activity)}")
                }
            _ =>
                Output.err_out!("bad_id", "complete needs numeric ids: complete <session_id> <activity_id>")

        }
    }
    # rest days have no activity to link — `complete <id>` alone closes them. Any
    # other session type still demands its activity id: done means evidence.
    complete_rest! : Str => Try({}, _)
    complete_rest! = |session_id_str| {
        path = Db.open_db!({})?
        match I64.from_str(session_id_str) {
            Err(_) => Output.err_out!("bad_id", "complete needs a numeric id: complete <session_id> [activity_id]")
            Ok(session_id) =>
                if !(Report.row_exists!(path, "planned_sessions", session_id)?)
                    session_not_found!(session_id)
                else {
                    session_type = Sqlite.query!({
                        path: Path.utf8(path),
                        query: "SELECT COALESCE(session_type, '') AS t FROM planned_sessions WHERE id = :pid",
                        bindings: [{ name: ":pid", value: Integer(session_id) }],
                        row: Sqlite.str("t"),
                    })?
                    if session_type != "rest" {
                        Output.err_out!("activity_required", "planned session #${(session_id).to_str()} is '${session_type}' — completing it needs the activity id (only rest days close without one)")
                    } else {
                        Sqlite.execute!({
                            path: Path.utf8(path),
                            query: "UPDATE planned_sessions SET status = 'done' WHERE id = :pid",
                            bindings: [{ name: ":pid", value: Integer(session_id) }],
                        })?
                        # rest must be Bool-TYPED (1 == 1), not a bare `True` tag — the new
                        # builtin JSON renders a bare tag as the string "True", not true.
                        Output.out!({ completed_session: session_id, rest: 1 == 1 }, |p| "planned session #${(p.completed_session).to_str()} (rest) marked done")
                    }
                }
        }
    }
    skip! : Str, Str => Try({}, _)
    skip! = |session_id_str, reason| {
        path = Db.open_db!({})?
        match I64.from_str(session_id_str) {
            Ok(session_id) =>
                if !(Report.row_exists!(path, "planned_sessions", session_id)?) {
                    session_not_found!(session_id)
                } else {
                    Sqlite.execute!({
                        path: Path.utf8(path),
                        query: "UPDATE planned_sessions SET status = 'skipped', skipped_reason = :why WHERE id = :pid",
                        bindings: [
                            { name: ":why", value: String(reason) },
                            { name: ":pid", value: Integer(session_id) },
                        ],
                    })?
                    Output.out!({ skipped_session: session_id, reason }, |p| "planned session #${I64.to_str(p.skipped_session)} skipped: ${p.reason}")
                }
            Err(_) =>
                Output.err_out!("bad_id", "skip needs a numeric id: skip <session_id> \"<reason>\"")

        }
    }
}
