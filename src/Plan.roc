import Db
import Output
import Strava
import Report
import pf.Sqlite
import pf.Stdout
import pf.Path
import Analyze
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
            match Metrics.arg_f64(rpe_str) {
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
                        Metrics.arg_i64(target).map_err(|_| BadId)
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
        # `week all` shows the full log unfiltered.
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
        # `week all` must mean ALL: the older-sessions count and the note pointing at the
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
                \\       COALESCE(substitute_activity_id,0) AS substitute_activity_id,
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
                substitute_activity_id = Sqlite.i64("substitute_activity_id")(cols)(stmt)?
                done_date = Sqlite.str("done_date")(cols)(stmt)?
                Ok({ id, created_at, target_date, session_type, detail, rationale, completed_activity_id, status, skipped_reason, substitute_activity_id, done_date })
            },
        })?
        # newest-first from SQL, flipped to calendar order for display. `Render.reverse_list`
        # (fold + prepend, linear) rather than fold + `List.concat([x], acc)`, which copies
        # the whole accumulator every step and is quadratic — harmless behind the old
        # LIMIT 100, unbounded now that `week all` returns the full log.
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
            # 0 on session rows — only unplanned rows carry a bare activity_id
            activity_id: 0.I64,
            status: p.status,
            skipped_reason: p.skipped_reason,
            substitute_activity_id: p.substitute_activity_id,
            done_date: p.done_date,
            # A session completed by an activity from ANOTHER day used to render exactly
            # like one completed on time — the plan silently implied the work happened on
            # the date it was prescribed for. Show the real day when they differ.
            status_shown:
                if p.status == "done" and p.done_date != "" and p.done_date != p.target_date {
                    # Full date, year included: `week all` spans years, so a bare month-day
                    # would be ambiguous exactly where the log is longest. The wider cell
                    # costs a line of wrapping in the detail column; that is the cheaper loss.
                    "done (${dow(p.done_date)} ${p.done_date})"
                } else {
                    p.status
                },
        })
        # plan-vs-actual (#144): activities this week that no session references —
        # neither as completion nor as substitute — get their own rows, so the week
        # stops hiding what actually happened. ThisWeek only: `week all` is the
        # SESSION log, and a lifetime of unplanned activities would bury it.
        # NOTE: the substitute arm's supersession predicate below is mirrored in
        # live_claimant! and (positively) in the sessions query above — the three
        # MUST agree or week's offers and the claim commands contradict each other.
        # A week-window clause was once on this arm and caused exactly that
        # (cross-week substitutes advertised as unplanned but refused); claims are
        # not week-relative, so neither is this exclusion.
        unplanned = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.id AS aid, substr(a.start_local,1,10) AS adate, COALESCE(a.sport_type,'') AS sport,
                \\       COALESCE(a.name,'') AS aname, COALESCE(a.moving_time,0) AS mt,
                \\       CAST(COALESCE(m.tss,0) AS REAL) AS tss
                \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE :all = 0
                \\  AND a.start_local >= '${Metrics.days_to_date_str(mon)}'
                \\  AND a.start_local < '${Metrics.days_to_date_str(mon + 7)}'
                \\  AND NOT EXISTS (SELECT 1 FROM planned_sessions ps
                \\       WHERE ps.completed_activity_id = a.id
                \\          OR (ps.substitute_activity_id = a.id
                \\              AND (COALESCE(ps.status,'open') <> 'skipped'
                \\                   OR NOT EXISTS (SELECT 1 FROM planned_sessions p3
                \\                                  WHERE p3.target_date = ps.target_date
                \\                                    AND (COALESCE(p3.status,'open') <> 'skipped' OR p3.id > ps.id)))))
                \\ORDER BY a.start_local
            ,
            bindings: [{ name: ":all", value: Integer(scope_all) }],
            rows: |cols| |stmt| {
                aid = Sqlite.i64("aid")(cols)(stmt)?
                adate = Sqlite.str("adate")(cols)(stmt)?
                sport = Sqlite.str("sport")(cols)(stmt)?
                aname = Sqlite.str("aname")(cols)(stmt)?
                mt = Sqlite.i64("mt")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                Ok({ aid, adate, sport, aname, mt, tss })
            },
        })?
        unplanned_rows = List.map(unplanned, |u| {
            # bind first, then interpolate — `${if … else ""}` splices a compile-time
            # "" into str_concat, the #32-class heap trap. Fixed upstream in roc#10595
            # and our pin now carries the fix, so this is style rather than survival;
            # kept because non-empty-by-construction is the clearer rule either way.
            load_part = if u.tss >= 1.0 ", ${Render.fmt0(u.tss)} load" else " "
            {
            id: 0.I64,
            created_at: "",
            target_date: u.adate,
            day: dow(u.adate),
            session_type: Str.with_ascii_lowercased(u.sport),
            detail: Str.trim_end("${u.aname} — ${Render.mins(u.mt)}${load_part}"),
            rationale: "",
            completed_activity_id: 0.I64,
            activity_id: u.aid,
            status: "unplanned",
            skipped_reason: "",
            substitute_activity_id: 0.I64,
            done_date: "",
            status_shown: "unplanned",
            }
        })
        # merged calendar order: sessions and unplanned actuals interleave by date.
        # Three traps live here, each measured: Str has no ordering (parse day
        # numbers); this toolchain's List.sort_with is ANTI-STABLE (ties come out
        # REVERSED, so the comparator must be a total order — day, then sessions
        # before unplanned, then id); and sort_with is O(n^2) on already-sorted
        # input, which `enriched` always is — so when nothing was merged (week all,
        # or a week with no unplanned activities) we skip the sort entirely.
        # Keys are computed ONCE per row, never inside the comparator.
        with_actuals =
            if List.is_empty(unplanned_rows) {
                enriched
            } else {
                day_key = |ds|
                    match Metrics.date_str_to_days(ds) {
                        Ok(n) => n
                        Err(_) => 0
                    }
                keyed = List.map(List.concat(enriched, unplanned_rows), |r| {
                    row: r,
                    day: day_key(r.target_date),
                    rank: if r.status == "unplanned" 1.I64 else 0.I64,
                    ord: if r.id != 0 r.id else r.activity_id,
                })
                sorted = List.sort_with(keyed, |x, y| {
                    d = I64.compare(x.day, y.day)
                    if d != EQ d else {
                        rk = I64.compare(x.rank, y.rank)
                        if rk != EQ rk else I64.compare(x.ord, y.ord)
                    }
                })
                List.map(sorted, |k| k.row)
            }

        # `week all` splits the log into sections: a single slab answers "whatever
        # happened" when the question at hand is usually "what's coming". Partitioned by
        # WEEK rather than by today, so no row can land in two sections — an open session
        # later this week belongs to `this week`, not to `upcoming`. Sections are
        # presentation only; the JSON payload stays one flat array.
        # Two id columns, because they are two different things and the table was the only
        # place either was visible. `id` is the SESSION — the handle every command takes
        # (`complete`, `skip`, `rate`). `activity` is the Strava activity linked to it,
        # which exists only once the session is done; an open row has nothing to show yet,
        # so it reads `-` like every other unavailable value.
        plan_headers = ["day", "date", "type", "status", "detail", "id", "activity"]
        plan_cells = |p| [
            p.day,
            p.target_date,
            p.session_type,
            p.status_shown,
            p.detail,
            if p.id == 0 "-" else (p.id).to_str(),
            if p.activity_id != 0 {
                (p.activity_id).to_str()
            } else if p.completed_activity_id != 0 {
                (p.completed_activity_id).to_str()
            } else if p.substitute_activity_id != 0 {
                # a substitution is not a completion — the arrow keeps them distinct
                "→ ${(p.substitute_activity_id).to_str()}"
            } else {
                "-"
            },
        ]
        # an empty section says so rather than vanishing — an absent heading reads as
        # "there is no such thing", which is a different claim from "nothing there yet"
        section = |title, srows|
            if List.is_empty(srows) {
                "── ${title} ──\n(none)"
            } else {
                "── ${title} ──\n${Render.render_table(plan_headers, List.map(srows, plan_cells))}"
            }
        Output.out!(with_actuals, |rows_enriched|
            match scope {
                ThisWeek => Render.render_table(plan_headers, List.map(rows_enriched, plan_cells))
                AllTime => {
                    # Parse each target_date ONCE and carry the result alongside its row:
                    # every section below tests the same boundaries, so filtering on the
                    # date string re-parsed it four times per row. Keyed here rather than
                    # folded into `enriched` so the JSON payload keeps its shape.
                    # `dated` matters as much as the number. `week add` stores whatever
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
                    # Unrendered sessions are COUNTED, never silently dropped: `week all`
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
                            "\n\n(${hidden} ${noun} not shown — STRIDE_FORMAT=json stride week all has every row)"
                        }
                    "${Str.join_with([section("upcoming", upcoming), section("this week", current), section("last week", history)], "\n\n")}${older_note}"
                }
            })
    }
    plan_add! : Str, Str, Str, Str => Try({}, _)
    plan_add! = |target_date, session_type, detail, rationale| {
        # Reject a bad date at the door, BEFORE the db is even opened. planned_sessions is
        # judgment tier — nothing here can be re-derived from Strava — so a typo that lands
        # in the table stays until someone edits SQL by hand. It would also belong to no
        # training week, matching no completion or adherence query, and would surface only
        # as a number in `week all`'s undated count.
        if !(Metrics.is_canonical_date(target_date)) {
            Output.err_out!("bad_date", "week add needs a calendar date written YYYY-MM-DD — got '${target_date}'")
        } else {
            plan_add_checked!(target_date, session_type, detail, rationale)
        }
    }
    plan_add_checked! : Str, Str, Str, Str => Try({}, _)
    plan_add_checked! = |target_date, session_type, detail, rationale| {
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
        Output.err_out!("session_not_found", "no planned session #${(session_id).to_str()} — `stride plan` lists open ones, `stride week all` the whole log")

    complete! : Str, Str => Try({}, _)
    complete! = |session_id_str, activity_id_str| {
        path = Db.open_db!({})?
        match (Metrics.arg_i64(session_id_str), Metrics.arg_i64(activity_id_str)) {
            (Ok(session_id), Ok(activity_id)) =>
                # SQLite UPDATE matching 0 rows is not an error — check existence
                # ourselves so a typo'd id can't report false success and silently
                # leave the planned session open / the coaching log out of sync
                if !(Report.row_exists!(path, "planned_sessions", session_id)?) {
                    session_not_found!(session_id)
                } else if !(Report.row_exists!(path, "activities", activity_id)?) {
                    Output.err_out!("activity_not_found", "no activity ${I64.to_str(activity_id)} in the db — `stride sync` first?")
                } else {
                    match live_claimant!(path, activity_id, session_id)? {
                        CompletedBy(cid) =>
                            # a completion is permanent evidence — there is no release
                            # path, and saying otherwise once sent a reader into a
                            # done→skipped corruption. Name the fact, suggest the fix.
                            Output.err_out!("activity_already_linked", "activity ${I64.to_str(activity_id)} already completed session #${I64.to_str(cid)} — completions are permanent; pick a different activity")
                        SubstituteOf(cid) =>
                            Output.err_out!("activity_already_linked", "activity ${I64.to_str(activity_id)} substitutes session #${I64.to_str(cid)} — release it first: stride skip ${I64.to_str(cid)} \"<reason>\" none")
                        Free => {
                            # write first, steal second: a failure between the two
                            # leaves only a dead tombstone link (self-healing), never
                            # a released link with nothing written in its place
                            _ = Sqlite.execute!({
                                path: Path.utf8(path),
                                query: "UPDATE planned_sessions SET completed_activity_id = :aid, status = 'done', substitute_activity_id = NULL WHERE id = :pid",
                                bindings: [
                                    { name: ":aid", value: Integer(activity_id) },
                                    { name: ":pid", value: Integer(session_id) },
                                ],
                            })?
                            match steal_dead_links!(path, activity_id, session_id)? {
                                ReleasedFrom(holder) =>
                                    Output.out!({ completed_session: session_id, activity: activity_id, released_substitute_of: holder }, |o| "planned session #${I64.to_str(o.completed_session)} completed by activity ${I64.to_str(o.activity)} (released its old substitute link on session #${I64.to_str(o.released_substitute_of)})")
                                NothingReleased =>
                                    Output.out!({ completed_session: session_id, activity: activity_id }, |o| "planned session #${I64.to_str(o.completed_session)} completed by activity ${I64.to_str(o.activity)}")
                            }
                        }
                    }
                }
            _ =>
                Output.err_out!("bad_id", "complete needs numeric ids: complete <session_id> <activity_id>")

        }
    }
    # Activities within a day either side of a planned session's date, newest first, so a
    # refusal to complete can show the reader the ids they might have meant. ±1 day rather
    # than the exact date: start_local is a civil timestamp, and a late-evening or
    # early-morning session routinely lands on the neighbouring day.
    #
    # A HALF-OPEN range on the raw column, not `date(a.start_local) BETWEEN …`. Wrapping the
    # column in a function makes the predicate non-sargable, so idx_activities_start cannot
    # be used and the query degrades to a full scan. The bounds work because start_local is
    # ISO text and the comparison is lexical: `date()` yields '2026-08-10', and
    # '2026-08-10T09:30:00Z' sorts after it, so `>=` catches the whole lower day; the upper
    # bound is target+2 EXCLUSIVE, so every timestamp on target+1 still sorts below
    # '2026-08-13' and is included. (Same lexical reasoning as period_ftp_sql in
    # Analyze.roc, where getting it wrong dropped every activity on the cutoff day.)
    candidate_activities! : Str, I64 => Try(List({ id : I64, start : Str, sport : Str, name : Str }), _)
    candidate_activities! = |path, session_id|
        Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.id AS id, a.start_local AS start,
                \\       COALESCE(a.sport_type, '') AS sport, COALESCE(a.name, '') AS name
                \\FROM activities a
                \\JOIN planned_sessions p ON p.id = :pid
                \\WHERE a.start_local >= date(p.target_date, '-1 day')
                \\  AND a.start_local <  date(p.target_date, '+2 day')
                \\ORDER BY a.start_local DESC, a.id DESC
                \\LIMIT 5
            ,
            bindings: [{ name: ":pid", value: Integer(session_id) }],
            rows: |cols| |stmt| {
                id = Sqlite.i64("id")(cols)(stmt)?
                start = Sqlite.str("start")(cols)(stmt)?
                sport = Sqlite.str("sport")(cols)(stmt)?
                name = Sqlite.str("name")(cols)(stmt)?
                Ok({ id, start, sport, name })
            },
        })

    # rest days have no activity to link — `complete <id>` alone closes them. Any
    # other session type still demands its activity id: done means evidence.
    complete_rest! : Str => Try({}, _)
    complete_rest! = |session_id_str| {
        path = Db.open_db!({})?
        match Metrics.arg_i64(session_id_str) {
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
                        # Naming the rule is not enough: the id lives in the database and
                        # the old message left the reader with no way to find it short of
                        # opening SQLite. So list the activities actually near this
                        # session's date — the answer is almost always one of them.
                        candidates = candidate_activities!(path, session_id)?
                        hint =
                            if List.is_empty(candidates) {
                                "\nNo activities recorded within a day of that date. Run `stride sync` first, or `stride skip ${(session_id).to_str()} \"<reason>\"` if it didn't happen."
                            } else {
                                lines = List.map(candidates, |c| "  ${(c.id).to_str()}  ${c.start}  ${c.sport}  ${c.name}")
                                "\nActivities near that date:\n${Str.join_with(lines, "\n")}"
                            }
                        Output.err_out!(
                            "activity_required",
                            "planned session #${(session_id).to_str()} is '${session_type}' — done means evidence, so it needs an activity id (only rest days close without one).\n  stride complete ${(session_id).to_str()} <activity_id>${hint}",
                        )
                    } else {
                        Sqlite.execute!({
                            path: Path.utf8(path),
                            query: "UPDATE planned_sessions SET status = 'done', substitute_activity_id = NULL WHERE id = :pid",
                            bindings: [{ name: ":pid", value: Integer(session_id) }],
                        })?
                        # rest must be Bool-TYPED (1 == 1), not a bare `True` tag — the new
                        # builtin JSON renders a bare tag as the string "True", not true.
                        Output.out!({ completed_session: session_id, rest: 1 == 1 }, |p| "planned session #${(p.completed_session).to_str()} (rest) marked done")
                    }
                }
        }
    }
    # One activity, one story — but only LIVE claims block a new one. A superseded
    # skip tombstone's substitute link is display-dead already (the week hides the
    # row), so a fresh claim STEALS it: the tombstone's link is cleared and the
    # claim proceeds. Without the steal, `week` advertises the activity as
    # unplanned and then refuses the very command that acts on it. Live claimants
    # (any completion, or a substitute on a non-superseded row) refuse the claim,
    # naming the blocking session — an error that names the rule without the id
    # leaves the reader nothing but SQLite (see the activity_required note above).
    # The supersession predicate here is the De Morgan dual of the one in the
    # unplanned query and the sessions query — the three MUST agree (see the
    # NOTE above the unplanned query).
    live_claimant! : Str, I64, I64 => Try([CompletedBy(I64), SubstituteOf(I64), Free], _)
    live_claimant! = |path, activity_id, session_id| {
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT id AS id, CASE WHEN ps.completed_activity_id = :aid THEN 1 ELSE 0 END AS is_completion
                \\FROM planned_sessions ps
                \\WHERE ps.id <> :sid
                \\  AND (ps.completed_activity_id = :aid
                \\       OR (ps.substitute_activity_id = :aid
                \\           AND NOT (COALESCE(ps.status,'open') = 'skipped'
                \\                    AND EXISTS (SELECT 1 FROM planned_sessions p3
                \\                                WHERE p3.target_date = ps.target_date
                \\                                  AND (COALESCE(p3.status,'open') <> 'skipped' OR p3.id > ps.id)))))
                \\ORDER BY is_completion DESC LIMIT 1
            ,
            bindings: [{ name: ":aid", value: Integer(activity_id) }, { name: ":sid", value: Integer(session_id) }],
            rows: |cols| |stmt| {
                cid = Sqlite.i64("id")(cols)(stmt)?
                isc = Sqlite.i64("is_completion")(cols)(stmt)?
                Ok({ cid, isc })
            },
        })?
        match List.first(rows) {
            Ok(r) => if r.isc == 1 Ok(CompletedBy(r.cid)) else Ok(SubstituteOf(r.cid))
            Err(_) => Ok(Free)
        }
    }

    # Clear display-dead tombstone links so the new claim is the one story —
    # called AFTER the claim's own write, so a failure here leaves exactly the
    # pre-existing dead-link state (self-healing on the next claim), never a
    # cleared link with nothing written in its place. Reports what it released
    # so the steal is never silent.
    steal_dead_links! : Str, I64, I64 => Try([ReleasedFrom(I64), NothingReleased], _)
    steal_dead_links! = |path, activity_id, session_id| {
        holders = Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT id AS id FROM planned_sessions WHERE substitute_activity_id = :aid AND id <> :sid LIMIT 1",
            bindings: [{ name: ":aid", value: Integer(activity_id) }, { name: ":sid", value: Integer(session_id) }],
            rows: Sqlite.i64("id"),
        })?
        match List.first(holders) {
            Err(_) => Ok(NothingReleased)
            Ok(holder) => {
                _ = Sqlite.execute!({
                    path: Path.utf8(path),
                    query: "UPDATE planned_sessions SET substitute_activity_id = NULL WHERE substitute_activity_id = :aid AND id <> :sid",
                    bindings: [{ name: ":aid", value: Integer(activity_id) }, { name: ":sid", value: Integer(session_id) }],
                })?
                Ok(ReleasedFrom(holder))
            }
        }
    }

    # sub: an optional activity that REPLACED the plan (#144). A substitution is
    # not a completion — the plan still wasn't delivered as prescribed — but the
    # link keeps the week honest: "skipped, did this instead" beats prose.
    skip! : Str, Str, [NoSub, Sub(Str)] => Try({}, _)
    skip! = |session_id_str, reason, sub| {
        path = Db.open_db!({})?
        match Metrics.arg_i64(session_id_str) {
            Ok(session_id) =>
                if !(Report.row_exists!(path, "planned_sessions", session_id)?) {
                    session_not_found!(session_id)
                } else {
                    # A DONE session cannot be skipped (#148): the old behavior
                    # flipped status to skipped while KEEPING completed_activity_id,
                    # leaving a skipped row that displays a completion — falsified
                    # adherence history, and live_claimant! then contradicts the
                    # visible status. Completions are permanent evidence; if a
                    # mis-link ever needs undoing, that will be an explicit retract
                    # verb clearing status AND link together, never a skip side effect.
                    done_by = Sqlite.query_many!({
                        path: Path.utf8(path),
                        query: "SELECT COALESCE(completed_activity_id, 0) AS a FROM planned_sessions WHERE id = :pid AND COALESCE(status,'open') = 'done'",
                        bindings: [{ name: ":pid", value: Integer(session_id) }],
                        rows: Sqlite.i64("a"),
                    })?
                    match List.first(done_by) {
                        Ok(aid) =>
                            if aid > 0 {
                                Output.err_out!("session_done", "session #${I64.to_str(session_id)} is done, completed by activity ${I64.to_str(aid)} — completions are permanent evidence and cannot be skipped; if the completion is mis-linked, re-complete it: stride complete ${I64.to_str(session_id)} <activity_id>")
                            } else {
                                Output.err_out!("session_done", "session #${I64.to_str(session_id)} is done (a completed rest day) — completions are permanent evidence and cannot be skipped")

                            }
                        Err(_) =>
                        match sub {
                            NoSub => {
                                # a bare re-skip PRESERVES an existing substitute link —
                                # judgment-tier data is never silently destroyed by a
                                # wording fix. The kept link is surfaced, and passing a
                                # new activity id is the way to change it.
                                _ = Sqlite.execute!({
                                    path: Path.utf8(path),
                                    query: "UPDATE planned_sessions SET status = 'skipped', skipped_reason = :why WHERE id = :pid",
                                    bindings: [
                                        { name: ":why", value: String(reason) },
                                        { name: ":pid", value: Integer(session_id) },
                                    ],
                                })?
                                kept = Sqlite.query_many!({
                                    path: Path.utf8(path),
                                    query: "SELECT substitute_activity_id AS s FROM planned_sessions WHERE id = :pid AND substitute_activity_id IS NOT NULL",
                                    bindings: [{ name: ":pid", value: Integer(session_id) }],
                                    rows: Sqlite.i64("s"),
                                })?
                                match List.first(kept) {
                                    Ok(sub_id) =>
                                        Output.out!({ skipped_session: session_id, reason, kept_substitute: sub_id }, |o| "planned session #${I64.to_str(o.skipped_session)} skipped: ${o.reason} (kept substitute ${I64.to_str(o.kept_substitute)} — pass an activity id to change it)")
                                    Err(_) =>
                                        Output.out!({ skipped_session: session_id, reason }, |o| "planned session #${I64.to_str(o.skipped_session)} skipped: ${o.reason}")
                                }
                            }
                            Sub("none") => {
                                # the explicit release path — the only way to unlink a
                                # substitute without lying about what happened. Read the
                                # link BEFORE clearing so the output reports the released
                                # id (an integer, mirroring kept_substitute — never a bare
                                # True tag, which the builtin JSON stringifies) and stays
                                # silent when there was nothing to release.
                                had = Sqlite.query_many!({
                                    path: Path.utf8(path),
                                    query: "SELECT substitute_activity_id AS s FROM planned_sessions WHERE id = :pid AND substitute_activity_id IS NOT NULL",
                                    bindings: [{ name: ":pid", value: Integer(session_id) }],
                                    rows: Sqlite.i64("s"),
                                })?
                                _ = Sqlite.execute!({
                                    path: Path.utf8(path),
                                    query: "UPDATE planned_sessions SET status = 'skipped', skipped_reason = :why, substitute_activity_id = NULL WHERE id = :pid",
                                    bindings: [
                                        { name: ":why", value: String(reason) },
                                        { name: ":pid", value: Integer(session_id) },
                                    ],
                                })?
                                match List.first(had) {
                                    Ok(old_sub) =>
                                        Output.out!({ skipped_session: session_id, reason, released_substitute: old_sub }, |o| "planned session #${I64.to_str(o.skipped_session)} skipped: ${o.reason} (released substitute ${I64.to_str(o.released_substitute)})")
                                    Err(_) =>
                                        Output.out!({ skipped_session: session_id, reason }, |o| "planned session #${I64.to_str(o.skipped_session)} skipped: ${o.reason} (no substitute link to release)")
                                }
                            }
                            Sub(activity_id_str) =>
                                match Metrics.arg_i64(activity_id_str) {
                                    Ok(activity_id) =>
                                        if !(Report.row_exists!(path, "activities", activity_id)?) {
                                            Output.err_out!("activity_not_found", "activity ${activity_id_str} not found (run `stride activities` to list ids)")
                                        } else {
                                            match live_claimant!(path, activity_id, session_id)? {
                                                CompletedBy(cid) =>
                                                    Output.err_out!("activity_already_linked", "activity ${activity_id_str} already completed session #${I64.to_str(cid)} — completions are permanent; pick a different activity")
                                                SubstituteOf(cid) =>
                                                    Output.err_out!("activity_already_linked", "activity ${activity_id_str} substitutes session #${I64.to_str(cid)} — release it first: stride skip ${I64.to_str(cid)} \"<reason>\" none")
                                                Free => {
                                                    # write first, steal second (see complete!)
                                                    _ = Sqlite.execute!({
                                                        path: Path.utf8(path),
                                                        query: "UPDATE planned_sessions SET status = 'skipped', skipped_reason = :why, substitute_activity_id = :aid WHERE id = :pid",
                                                        bindings: [
                                                            { name: ":why", value: String(reason) },
                                                            { name: ":aid", value: Integer(activity_id) },
                                                            { name: ":pid", value: Integer(session_id) },
                                                        ],
                                                    })?
                                                    match steal_dead_links!(path, activity_id, session_id)? {
                                                        ReleasedFrom(holder) =>
                                                            Output.out!({ skipped_session: session_id, reason, substitute_activity: activity_id, released_substitute_of: holder }, |o| "planned session #${I64.to_str(o.skipped_session)} skipped: ${o.reason} (did ${I64.to_str(o.substitute_activity)} instead; released its old link on session #${I64.to_str(o.released_substitute_of)})")
                                                        NothingReleased =>
                                                            Output.out!({ skipped_session: session_id, reason, substitute_activity: activity_id }, |o| "planned session #${I64.to_str(o.skipped_session)} skipped: ${o.reason} (did ${I64.to_str(o.substitute_activity)} instead)")
                                                    }
                                                }
                                            }
                                        }
                                    Err(_) =>
                                        Output.err_out!("bad_id", "the substitute must be a numeric activity id or `none` to release: skip <session_id> \"<reason>\" [activity_id|none]")
                                }
                        }
                    }
                }
            Err(_) =>
                Output.err_out!("bad_id", "skip needs a numeric id: skip <session_id> \"<reason>\" [activity_id|none]")

        }
    }
    # weekly-planning bundle: everything the coach needs to plan a week, in one call
    plan_bundle! : {} => Try({}, _)
    plan_bundle! = |{}| {
        path = Db.open_db!({})?
        match Analyze.load_zone_config!(path) {
            Err(MissingConfig) => Output.missing_config!({})
            Err(other) => Err(other)
            Ok(zb) =>
                match Report.summary_payload!(path, zb) {
                    Err(NoDataYet) => Output.err_out!("no_data", "nothing analyzed yet — run `stride sync` (or `stride import`) then `stride analyze`")
                    Err(e) => Err(e)
                    Ok(s) => {
                anchor = (Metrics.date_str_to_days(s.as_of)).ok_or(0)
                # anchor-13, not anchor-14: the range is INCLUSIVE of both ends, so
                # `>= anchor - 14` spans fifteen days while the section header and the
                # `recent_activities_14d` field both promise fourteen. Nobody could count
                # the difference while only days with activities were rendered; showing
                # every day made the extra one visible. Narrowing the window keeps the
                # name honest — the alternative, relabelling to 15, would have meant
                # renaming the JSON field and breaking its consumers over a fencepost.
                cutoff14 = Metrics.days_to_date_str(anchor - 13)
                recent = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT a.id AS id, substr(a.start_local, 1, 10) AS date, a.sport_type AS sport, a.name AS name,
                        \\       a.moving_time AS moving_time, CAST(COALESCE(m.tss,0) AS REAL) AS tss,
                        \\       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
                        \\       COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
                        \\       COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s,
                        \\       COALESCE(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_hard_s ELSE m.z4_s + m.z5_s END, 0) AS hard_s,
                        \\       CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
                        \\       CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
                        \\       CAST(COALESCE(a.relative_effort,0) AS REAL) AS relative_effort,
                        \\       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
                        \\       CASE WHEN m.normalized_power IS NULL THEN 0 ELSE 1 END AS power_known,
                        \\       CASE WHEN m.intensity_factor IS NULL THEN 0 ELSE 1 END AS intensity_known,
                        \\       CASE WHEN a.avg_hr IS NULL THEN 0 ELSE 1 END AS hr_known,
                        \\       CASE WHEN COALESCE(m.hr_samples_total, 0) > 0 THEN 1 ELSE 0 END AS zones_known,
                        \\       COALESCE(m.load_model, '') AS load_model
                        \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                        \\WHERE a.start_local >= :cutoff
                        \\ORDER BY a.start_local DESC, a.id DESC
                    ,
                    bindings: [{ name: ":cutoff", value: String(cutoff14) }],
                    rows: |cols| |stmt| {
                        id = Sqlite.i64("id")(cols)(stmt)?
                        date = Sqlite.str("date")(cols)(stmt)?
                        sport = Sqlite.str("sport")(cols)(stmt)?
                        name = Sqlite.str("name")(cols)(stmt)?
                        moving_time = Sqlite.i64("moving_time")(cols)(stmt)?
                        tss = Sqlite.f64("tss")(cols)(stmt)?
                        intensity = Sqlite.f64("intensity")(cols)(stmt)?
                        z1_s = Sqlite.i64("z1_s")(cols)(stmt)?
                        z2_s = Sqlite.i64("z2_s")(cols)(stmt)?
                        z3_s = Sqlite.i64("z3_s")(cols)(stmt)?
                        z4_s = Sqlite.i64("z4_s")(cols)(stmt)?
                        z5_s = Sqlite.i64("z5_s")(cols)(stmt)?
                        hard_s = Sqlite.i64("hard_s")(cols)(stmt)?
                        distance_m = Sqlite.f64("distance_m")(cols)(stmt)?

                        np_w = Sqlite.f64("np_w")(cols)(stmt)?

                        relative_effort = Sqlite.f64("relative_effort")(cols)(stmt)?

                        avg_hr = Sqlite.f64("avg_hr")(cols)(stmt)?
                        power_known = Sqlite.i64("power_known")(cols)(stmt)?
                        intensity_known = Sqlite.i64("intensity_known")(cols)(stmt)?
                        hr_known = Sqlite.i64("hr_known")(cols)(stmt)?
                        zones_known = Sqlite.i64("zones_known")(cols)(stmt)?
                        load_model = Sqlite.str("load_model")(cols)(stmt)?
                        Ok({ id, date, sport, name, moving_time, tss, load_model, intensity, intensity_known: intensity_known != 0, z1_s, z2_s, z3_s, z4_s, z5_s, zones_known: zones_known != 0, hard_s, distance_m, np_w, power_known: power_known != 0, relative_effort, avg_hr, hr_known: hr_known != 0 })
                    },
                })?
                open_p = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT id AS id, COALESCE(target_date,'') AS target_date, COALESCE(session_type,'') AS session_type,
                        \\       COALESCE(detail,'') AS detail, COALESCE(rationale,'') AS rationale
                        \\FROM planned_sessions WHERE COALESCE(status, 'open') = 'open'
                        \\ORDER BY target_date, id
                    ,
                    bindings: [],
                    rows: |cols| |stmt| {
                        id = Sqlite.i64("id")(cols)(stmt)?
                        target_date = Sqlite.str("target_date")(cols)(stmt)?
                        session_type = Sqlite.str("session_type")(cols)(stmt)?
                        detail = Sqlite.str("detail")(cols)(stmt)?
                        rationale = Sqlite.str("rationale")(cols)(stmt)?
                        Ok({ id, target_date, session_type, detail, rationale })
                    },
                })?
                # ── plan history (#158): planned-vs-actual as deterministic memory.
                # EVERY session whose target_date falls in the trailing 28 days, any
                # status — open sessions appear here too (the complete record) AND in
                # open_sessions (the actionable view); the two answer different
                # questions and the id disambiguates. completed_on is the DATE OF THE
                # LINKED ACTIVITY — the fact of when the work happened — not a status-
                # change timestamp stride does not store.
                cutoff28p = Metrics.days_to_date_str(anchor - 27)
                history = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT p.id AS id, COALESCE(p.target_date,'') AS target_date,
                        \\       COALESCE(p.session_type,'') AS session_type,
                        \\       COALESCE(p.detail,'') AS detail,
                        \\       COALESCE(p.status,'open') AS status,
                        \\       COALESCE(p.skipped_reason,'') AS skipped_reason,
                        \\       COALESCE(p.completed_activity_id, 0) AS completed_activity_id,
                        \\       COALESCE(p.substitute_activity_id, 0) AS substitute_activity_id,
                        \\       COALESCE(substr(a.start_local, 1, 10), '') AS completed_on
                        \\FROM planned_sessions p
                        \\LEFT JOIN activities a ON a.id = COALESCE(p.completed_activity_id, p.substitute_activity_id)
                        \\WHERE p.target_date >= :cutoff AND p.target_date <= :today
                        \\ORDER BY p.target_date, p.id
                    ,
                    bindings: [{ name: ":cutoff", value: String(cutoff28p) }, { name: ":today", value: String(s.as_of) }],
                    rows: |cols| |stmt| {
                        id = Sqlite.i64("id")(cols)(stmt)?
                        target_date = Sqlite.str("target_date")(cols)(stmt)?
                        session_type = Sqlite.str("session_type")(cols)(stmt)?
                        detail = Sqlite.str("detail")(cols)(stmt)?
                        status = Sqlite.str("status")(cols)(stmt)?
                        skipped_reason = Sqlite.str("skipped_reason")(cols)(stmt)?
                        completed_activity_id = Sqlite.i64("completed_activity_id")(cols)(stmt)?
                        substitute_activity_id = Sqlite.i64("substitute_activity_id")(cols)(stmt)?
                        completed_on = Sqlite.str("completed_on")(cols)(stmt)?
                        Ok({ id, target_date, session_type, detail, status, skipped_reason, completed_activity_id, substitute_activity_id, completed_on })
                    },
                })?
                # counts the coach should not re-derive: raw integers only (#154 —
                # completion_pct: 75 is data; any word about it is the coach's job).
                # substituted counts skipped sessions carrying a substitute link, so
                # skipped is the SUPERSET; unplanned = window activities NO session
                # references by EITHER link, live or tombstoned — deliberately
                # STRICTER than week's display rule, which re-classifies a ride
                # whose skip tombstone was superseded as unplanned: for adherence
                # that would double-count one ride as both substituted and
                # unplanned. Counted once here, as the substitution it was.
                adh = Sqlite.query!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT COALESCE(SUM(1),0) AS planned,
                        \\       COALESCE(SUM(CASE WHEN COALESCE(status,'open') = 'done' THEN 1 ELSE 0 END),0) AS completed,
                        \\       COALESCE(SUM(CASE WHEN COALESCE(status,'open') = 'skipped' THEN 1 ELSE 0 END),0) AS skipped,
                        \\       COALESCE(SUM(CASE WHEN COALESCE(status,'open') = 'skipped' AND substitute_activity_id IS NOT NULL THEN 1 ELSE 0 END),0) AS substituted,
                        \\       COALESCE(SUM(CASE WHEN COALESCE(status,'open') = 'open' THEN 1 ELSE 0 END),0) AS still_open
                        \\FROM planned_sessions
                        \\WHERE target_date >= :cutoff AND target_date <= :today
                    ,
                    bindings: [{ name: ":cutoff", value: String(cutoff28p) }, { name: ":today", value: String(s.as_of) }],
                    row: |cols| |stmt| {
                        planned = Sqlite.i64("planned")(cols)(stmt)?
                        completed = Sqlite.i64("completed")(cols)(stmt)?
                        skipped = Sqlite.i64("skipped")(cols)(stmt)?
                        substituted = Sqlite.i64("substituted")(cols)(stmt)?
                        still_open = Sqlite.i64("still_open")(cols)(stmt)?
                        Ok({ planned, completed, skipped, substituted, still_open })
                    },
                })?
                unplanned_n = Sqlite.query!({
                    path: Path.utf8(path),
                    query:
                        \\SELECT COUNT(*) AS n FROM activities a
                        \\WHERE substr(a.start_local, 1, 10) >= :cutoff AND substr(a.start_local, 1, 10) <= :today
                        \\  AND a.id NOT IN (SELECT completed_activity_id FROM planned_sessions WHERE completed_activity_id IS NOT NULL)
                        \\  AND a.id NOT IN (SELECT substitute_activity_id FROM planned_sessions WHERE substitute_activity_id IS NOT NULL)
                    ,
                    bindings: [{ name: ":cutoff", value: String(cutoff28p) }, { name: ":today", value: String(s.as_of) }],
                    row: Sqlite.i64("n"),
                })?
                completion_pct = if adh.planned > 0 (((adh.completed).to_f64() / (adh.planned).to_f64()) * 100.0).round_to_i64_try().ok_or(0) else 0
                if Output.json_mode!({}) {
                    Output.emit_ok!({
                        summary: s,
                        recent_activities_14d: recent,
                        open_sessions: open_p,
                        plan_history_28d: history,
                        adherence_28d: {
                            planned: adh.planned,
                            completed: adh.completed,
                            skipped: adh.skipped,
                            substituted: adh.substituted,
                            still_open: adh.still_open,
                            # raw ratio of the two counts above; 0 with planned 0 —
                            # planned is the discriminator, per the ambiguous-zero rule
                            completion_pct,
                            unplanned_activities: unplanned_n,
                        },
                    })
                } else {
                    Stdout.line!(Render.summary_screen(s))?
                    Stdout.line!("")?
                    # one descriptive line of plan memory (#158) — raw counts only
                    Stdout.line!("28d PLAN: ${I64.to_str(adh.planned)} planned · ${I64.to_str(adh.completed)} done · ${I64.to_str(adh.skipped)} skipped (${I64.to_str(adh.substituted)} substituted) · ${I64.to_str(unplanned_n)} unplanned activities")?
                    Stdout.line!("")?
                    Stdout.line!("OPEN PLAN")?
                    Stdout.line!(Render.render_table(
                        ["id", "date", "type", "detail"],
                        List.map(open_p, |p| [(p.id).to_str(), p.target_date, p.session_type, p.detail]),
                    ))?
                    Stdout.line!("")?
                    Stdout.line!("RECENT 14 DAYS")?
                    # This table is a DATE RANGE, so a day with nothing on it is information:
                    # it was a rest day, planned or not. Rendering only the days that HAVE
                    # activities made the reader diff dates to notice a gap — an explicit row
                    # says it outright. Human table only: the JSON payload stays a list of
                    # real activities and never gains pseudo-rows with no id.
                    # 14 DAYS, matching the `>= anchor - 13` cutoff above — not 14 rows: a
                    # day with two activities contributes two. The walk and the query have
                    # to span the same days, or the table shows one the query never
                    # returned (always blank) or hides one it did.
                    # Week boundaries get a full-width rule. The table runs newest-first, so
                    # the boundary falls just ABOVE each Sunday — never above the first row,
                    # which needs no divider.
                    recent_headers = ["date", "sport", "name", "time", "load", "hard"]
                    # A full-width horizontal rule, drawn by render_table in the table's own
                    # border glyphs so it lines up with the header rule. It must not be a
                    # glyph in every cell: `progress` uses `···` to mean a GAP in time, so
                    # reusing it here made a boundary between two CONSECUTIVE days read as
                    # missing days.
                    week_div = Render.rule
                    recent_display = List.join(List.map(Render.indices(14), |i| {
                        d = anchor - (i).to_i64_wrap()
                        ds = Metrics.days_to_date_str(d)
                        on_day = List.keep_if(recent, |a| a.date == ds)
                        day_rows =
                            if List.is_empty(on_day) {
                                # header-driven like the divider: the label sits in whichever
                                # column is NAMED "name" and every other cell is a dash, so a
                                # new column widens this row instead of leaving it short. The
                                # activity rows below stay positional by necessity — each cell
                                # is a different field, which no header list can express.
                                [List.map(recent_headers, |h|
                                    if h == "date" {
                                        ds
                                    } else if h == "name" {
                                        "(no activity)"
                                    } else {
                                        "-"
                                    })]
                            } else {
                                List.map(on_day, |a| [a.date, a.sport, a.name, Render.mins(a.moving_time), Render.fmt0(a.tss), Render.mins(a.hard_s)])
                            }
                        if i > 0 and Metrics.day_of_week(d) == "Sun" {
                            List.prepend(day_rows, week_div)
                        } else {
                            day_rows
                        }
                    }))
                    Stdout.line!(Render.render_table(recent_headers, recent_display))
                }
                    }
                }
        }
    }

}
