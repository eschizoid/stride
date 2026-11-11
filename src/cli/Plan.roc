import Db
import Output
import Strava
import Report
import Sql
import Streams
import pf.Stdout
import pf.Path
import Analyze
import Metrics
import Render
import core.Sports

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
						# the one body lives in Report.latest_activity! - rate wants
						# only the id, complete wants the day beside it. Matched as a
						# VALUE, never `?`: the arms below are this function's whole
						# error vocabulary, and `?` is a function-level early return
						# that lands on run_command!'s catch-all instead.
						match Report.latest_activity!(path) {
							Ok(r) => Ok(r.id)
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
							Sql.execute!({
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
							# an RPE target's stored result reads the rating
							refresh_target_results_for!(path, activity_id)?
							Output.out!({ rated: activity_id, rpe }, |p| "activity ${I64.to_str(p.rated)} rated ${Render.fmt0(p.rpe)}/10 — run `stride analyze` to rescore")
						}
				}
			}
		}
	}
	# An activity `a` no planned session claims, as completion or as a live
	# substitute: a substitute on a skipped session stops claiming once a later
	# row or a non-skipped row holds that date. The supersession predicate is
	# mirrored in live_claimant! and (positively) in plan_view!'s sessions
	# query; all three must agree, or `week` and `review` offer an activity the
	# claim commands then refuse. Claims are not week-relative, so the predicate
	# carries no date window: with one, a substitute linked from another week
	# would read as unclaimed and still be refused.
	unclaimed_sql : Str
	unclaimed_sql =
		\\NOT EXISTS (SELECT 1 FROM planned_sessions ps
		\\       WHERE ps.completed_activity_id = a.id
		\\          OR (ps.substitute_activity_id = a.id
		\\              AND (COALESCE(ps.status,'open') <> 'skipped'
		\\                   OR NOT EXISTS (SELECT 1 FROM planned_sessions p3
		\\                                  WHERE p3.target_date = ps.target_date
		\\                                    AND (COALESCE(p3.status,'open') <> 'skipped' OR p3.id > ps.id)))))

	plan_view! : [ThisWeek, AllTime] => Try({}, _)
	plan_view! = |scope| {
		path = Db.open_db!({})?
		# default view is the CURRENT training week (Mon-Sun containing today) so `week`
		# is "this week at a glance", not the whole history spilling into next week. The
		# Monday offset is rem(days+3,7) — the same convention as Metrics.day_of_week.
		today = Db.local_today_days!(path)
		mon = today - (today + 3) % (7)
		# default `week` is the LIVE current-week log. Re-planning a date leaves skipped
		# tombstones (skip-then-add), so hide a skipped row that something SUPERSEDES —
		# a live open/done session on that date, or a LATER row on that date. The second
		# arm covers a day that ends up wholly skipped: without it every draft of that
		# day would list as a near-duplicate row. A genuinely missed day still shows its
		# one final tombstone. `week all` shows the full log unfiltered.
		# The scope filter is a BOUND :all flag, never string interpolation: splicing a
		# compile-time-constant "" into a query string crashes the compiler's backend in
		# str_concat (roc#10595). The date literals below are always non-empty, so they
		# interpolate safely.
		scope_all =
			match scope {
				AllTime => 1
				ThisWeek => 0
			}
		# `week all` must mean ALL: the older-sessions count and the note pointing at the
		# JSON are both lies if the query silently truncates. SQLite treats a negative
		# LIMIT as unbounded, so this stays a BOUND value rather than an interpolated
		# clause (see the :all note above).
		row_limit =
			match scope {
				AllTime => -1
				ThisWeek => 100
			}
		rows = Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT id AS id, COALESCE(CAST(created_at AS TEXT),'') AS created_at, COALESCE(CAST(target_date AS TEXT),'') AS target_date,
				\\       COALESCE(CAST(session_type AS TEXT),'') AS session_type, COALESCE(CAST(detail AS TEXT),'') AS detail,
				\\       COALESCE(CAST(rationale AS TEXT),'') AS rationale, COALESCE(completed_activity_id,0) AS completed_activity_id,
				\\       COALESCE(superseded_activity_id,0) AS superseded_activity_id,
				\\       COALESCE(CAST(status AS TEXT),'open') AS status, COALESCE(CAST(skipped_reason AS TEXT),'') AS skipped_reason,
				\\       COALESCE(substitute_activity_id,0) AS substitute_activity_id,
				\\       COALESCE(target_reps, 0) AS target_reps, COALESCE(target_dur_s, 0) AS target_dur_s, CAST(COALESCE(target_watts, 0) AS REAL) AS target_watts,
				\\       COALESCE(CAST(target_literal AS TEXT), '') AS target_literal,
				\\       COALESCE(CAST((SELECT substr(a.start_local,1,10) FROM activities a WHERE a.id = planned_sessions.completed_activity_id) AS TEXT), '') AS done_date,
				\\       CAST(COALESCE((SELECT dl.tss FROM daily_load dl WHERE dl.day = planned_sessions.target_date), 0) AS REAL) AS day_tss,
				\\       CASE WHEN EXISTS (SELECT 1 FROM daily_load dl WHERE dl.day = planned_sessions.target_date) THEN 1 ELSE 0 END AS day_load_known
				\\FROM planned_sessions
				\\WHERE (:all = 1 OR (target_date >= :mon AND target_date <= :sun AND id IN (SELECT id FROM plan_current)))
				\\ORDER BY target_date DESC, id DESC LIMIT :lim
			,
			bindings: [{ name: ":all", value: Integer(scope_all) }, { name: ":lim", value: Integer(row_limit) }, { name: ":mon", value: String(Metrics.days_to_date_str(mon)) }, { name: ":sun", value: String(Metrics.days_to_date_str(mon + 6)) }],
			rows: |cols| |stmt| {
				id = Sql.i64("id")(cols)(stmt)?
				created_at = Sql.str("created_at")(cols)(stmt)?
				target_date = Sql.str("target_date")(cols)(stmt)?
				session_type = Sql.str("session_type")(cols)(stmt)?
				detail = Sql.str("detail")(cols)(stmt)?
				rationale = Sql.str("rationale")(cols)(stmt)?
				completed_activity_id = Sql.i64("completed_activity_id")(cols)(stmt)?
				superseded_activity_id = Sql.i64("superseded_activity_id")(cols)(stmt)?
				status = Sql.str("status")(cols)(stmt)?
				skipped_reason = Sql.str("skipped_reason")(cols)(stmt)?
				substitute_activity_id = Sql.i64("substitute_activity_id")(cols)(stmt)?
				done_date = Sql.str("done_date")(cols)(stmt)?
				day_tss = Sql.f64("day_tss")(cols)(stmt)?
				day_load_known = Sql.i64("day_load_known")(cols)(stmt)?
				treps = Sql.i64("target_reps")(cols)(stmt)?
				tdur = Sql.i64("target_dur_s")(cols)(stmt)?
				twatts = Sql.f64("target_watts")(cols)(stmt)?
				tlit = Sql.str("target_literal")(cols)(stmt)?
				tgt = Metrics.stored_target(tlit, treps, tdur, twatts)
				Ok({ id, created_at, target_date, session_type, detail, rationale, completed_activity_id, superseded_activity_id, status, skipped_reason, substitute_activity_id, done_date, day_tss, day_load_known, tgt })
			},
		})?
		# newest-first from SQL, flipped to calendar order for display. `Render.reverse_list`
		# (fold + prepend, linear) rather than fold + `List.concat([x], acc)`, which copies
		# the whole accumulator every step and is quadratic over `week all`'s full log.
		ordered = Render.reverse_list(rows)
		dow = |date_str|
			match Metrics.date_str_to_days(date_str) {
				Ok(d) => Metrics.day_of_week(d)
				Err(_) => ""
			}
		# enrich ONCE with the day-of-week; both output modes consume the same rows
		# (constructed explicitly — Roc's `&` can only update fields, not add one)
		enriched = List.map(
			ordered,
			|p| {
				id: p.id,
				created_at: p.created_at,
				target_date: p.target_date,
				day: dow(p.target_date),
				session_type: p.session_type,
				detail: p.detail,
				rationale: p.rationale,
				completed_activity_id: p.completed_activity_id,
				# ...and what a re-completion erased, 0 when nothing was. Published on the row,
				# so an erased completion stays on record after `complete` has printed it once.
				superseded_activity_id: p.superseded_activity_id,
				# 0 on session rows — only unplanned rows carry a bare activity_id
				activity_id: 0.I64,
				status: p.status,
				skipped_reason: p.skipped_reason,
				substitute_activity_id: p.substitute_activity_id,
				done_date: p.done_date,
				# the structured target, in its canonical literal; "" for a prose-only session
				target_kind: p.tgt.kind,
				target_literal: Metrics.target_literal(p.tgt),
				# A session completed by an activity from ANOTHER day would otherwise render
				# exactly like one completed on time, so the plan would silently imply the
				# work happened on the date it was prescribed for. Show the real day when
				# they differ.
				#
				# An open REST row whose date has passed with no load on it reads `rested`:
				# rest is the one type whose prescription is the absence of evidence, so a
				# zero-load day past its date IS the session having happened, and rendering
				# it like a missed workout tells the athlete they owe something they don't
				# . Display-only — `status` stays `open`, the lifecycle is untouched.
				# The same-day threshold (>= 1.0 load counts as trained) is the one the
				# summary table uses to print a day as rest. A rest day WITH load stays
				# `open`: training through a rest day is a plan deviation, not a completion.
				# day_load_known is what separates a measured zero from an absent row:
				# daily_load covers every day up to the last analyze, so a date past that
				# coverage has no row, and its COALESCEd 0 is "the engine has not looked",
				# not "the athlete rested" — the athlete may have trained hard on it. An
				# unknown day stays `open` (the ADR 0009 discipline, applied to a view).
				status_shown: if p.status == "done" and p.done_date != "" and p.done_date != p.target_date {
					# Full date, year included: `week all` spans years, so a bare month-day
					# would be ambiguous exactly where the log is longest. The wider cell
					# costs a line of wrapping in the detail column; that is the cheaper loss.
					"done (${dow(p.done_date)} ${p.done_date})"
				} else if p.status == "open" and p.session_type == "rest" and p.day_load_known == 1 and p.day_tss < 1.0 and (
					match Metrics.date_str_to_days(p.target_date) {
						Ok(d) => d < today
						Err(_) => False
					}
				) {
					"rested"
				} else {
					p.status
				},
			},
		)
		# Plan beside actual: every activity this week that no session claims, as
		# completion or as substitute, gets a row of its own, so the week shows what
		# happened next to what was planned. The row is recomputed on every read and
		# means "no plan day claims this activity yet", not "the athlete went off-plan":
		# `stride complete <id> <activity>` or `stride skip <id> <reason> <activity>`
		# links it, and the row is gone on the next read. So the table and
		# `status_shown` read `unlinked`, while `status` keeps the v3 value `unplanned`
		# that JSON consumers match on. ThisWeek only: `week all` is the SESSION log,
		# and every unclaimed activity in the history would bury it.
		# The exclusion is unclaimed_sql, shared with `review`.
		unplanned = Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT a.id AS aid, COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS adate, COALESCE(CAST(a.sport_type AS TEXT),'') AS sport,
				\\       COALESCE(CAST(a.name AS TEXT),'') AS aname, COALESCE(a.moving_time,0) AS mt,
				\\       CAST(COALESCE(m.tss,0) AS REAL) AS tss
				\\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
				\\WHERE :all = 0
				\\  AND a.start_local >= '${Metrics.days_to_date_str(mon)}'
				\\  AND a.start_local < '${Metrics.days_to_date_str(mon + 7)}'
				\\  AND ${unclaimed_sql}
				\\-- the flag is DEFENSIVE here: this order is discarded downstream by a
				\\-- List.sort_with over (day, rank, activity_id), a strict total order, so no
				\\-- database can make this clause observable. Kept in case that sort changes.
				\\ORDER BY ${Metrics.rank_ts_sql("a.start_local", Asc)}
			,
			bindings: [{ name: ":all", value: Integer(scope_all) }],
			rows: |cols| |stmt| {
				aid = Sql.i64("aid")(cols)(stmt)?
				adate = Sql.str("adate")(cols)(stmt)?
				sport = Sql.str("sport")(cols)(stmt)?
				aname = Sql.str("aname")(cols)(stmt)?
				mt = Sql.i64("mt")(cols)(stmt)?
				tss = Sql.f64("tss")(cols)(stmt)?
				Ok({ aid, adate, sport, aname, mt, tss })
			},
		})?
		# `day_key` answers 0 for a date it cannot parse, and 0 is a real day number, so
		# without a guard an unreadable unplanned activity would sort to the epoch and
		# list FIRST, above the week, carrying `day: ""`, at exit 0. The guard runs here
		# because this is the one place the activity id is still in hand, and a refusal
		# must name the row it refuses. Planned sessions need no guard: `week add`
		# rejects a non-canonical target_date on the write path.
		#
		# WHOLE TABLE, not the `unplanned` rows: the window clause is NULL-false on both
		# comparisons, so a NULL-dated activity never enters that list, and whether a
		# non-NULL unreadable value can fall inside a week window depends on the
		# calendar. Only the table-wide sweep sees every such row on every week. It is
		# the same sweep `rate`, `compare`, `summary`, `plan` and `stats` use; `season`
		# guards inline over a differently-grouped query.
		_ = Report.guard_activity_dates!(path)?
		unplanned_rows = List.map(
			unplanned,
			|u| {
				# bind first, then interpolate — `${if … else ""}` splices a compile-time
				# "" into str_concat, a heap trap. Fixed upstream in roc#10595
				# and our pin now carries the fix, so this is style rather than survival;
				# kept because non-empty-by-construction is the clearer rule either way.
				load_part = if (u.tss >= 1.0) ", ${Render.fmt0(u.tss)} load" else " "
				{
					id: 0.I64,
					created_at: "",
					target_date: u.adate,
					day: dow(u.adate),
					session_type: Str.with_ascii_lowercased(u.sport),
					detail: Str.trim_end("${u.aname} — ${Render.mins(u.mt)}${load_part}"),
					rationale: "",
					completed_activity_id: 0.I64,
					# an unplanned row was never completed through a session, so nothing on it could
					# have been superseded
					superseded_activity_id: 0.I64,
					activity_id: u.aid,
					status: "unplanned",
					skipped_reason: "",
					substitute_activity_id: 0.I64,
					done_date: "",
					target_kind: "",
					target_literal: "",
					status_shown: "unlinked",
				}
			},
		)
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
				keyed = List.map(
					List.concat(enriched, unplanned_rows),
					|r| {
						row: r,
						day: day_key(r.target_date),
						rank: if (r.status == "unplanned") 1.I64 else 0.I64,
						ord: if (r.id != 0) r.id else r.activity_id,
					},
				)
				sorted = List.sort_with(
					keyed,
					|x, y| {
						d = x.day.order_relative_to(y.day)
						if (d != Same) d else {
							rk = x.rank.order_relative_to(y.rank)
							if (rk != Same) rk else x.ord.order_relative_to(y.ord)
						}
					},
				)
				List.map(sorted, |k| k.row)
			}

		# `week all` splits the log into sections: a single slab answers "whatever
		# happened" when the question at hand is usually "what's coming". Partitioned by
		# WEEK rather than by today, so no row can land in two sections — an open session
		# later this week belongs to `this week`, not to `upcoming`. Sections are
		# presentation only; the JSON payload stays one flat array.
		# Two id columns, because they are two different things and the table was the only
		# place either was visible. `id` is the SESSION — the handle every command takes
		# (`complete`, `skip`, `relabel`). `activity` is the Strava activity linked to it,
		# which exists only once the session is done; an open row has nothing to show yet,
		# so it reads `-` like every other unavailable value.
		plan_headers = ["day", "date", "type", "status", "detail", "id", "activity"]
		plan_cells = |p| [
			p.day,
			p.target_date,
			p.session_type,
			p.status_shown,
			p.detail,
			if (p.id == 0) "-" else (p.id).to_str(),
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
		Output.out!(
			with_actuals,
			|rows_enriched|
				match scope {
					ThisWeek => Render.render_table(plan_headers, List.map(rows_enriched, plan_cells))
					AllTime => {
						# Parse each target_date ONCE and carry the result alongside its row:
						# every section below tests the same boundaries, so filtering on the
						# date string re-parsed it four times per row. Keyed here rather than
						# folded into `enriched` so the JSON payload keeps its shape.
						# `dated` matters as much as the number. `week add` REJECTS a
						# non-canonical target_date on the write path, so an unparseable one
						# can only arrive by hand-editing the db. Collapsing
						# it to day 0 would file a typo under "older sessions" and quietly
						# claim it was in the past — it is undated, which is a different fact.
						keyed = List.map(
							rows_enriched,
							|p|
								match Metrics.date_str_to_days(p.target_date) {
									Ok(n) => { row: p, n, dated: True }
									Err(_) => { row: p, n: 0, dated: False }
								},
						)
						pick = |pred| List.map(List.keep_if(keyed, pred), |k| k.row)
						# The rule is DATE ONLY, no status filter, deliberately on both counts:
						# partitioning by week keeps a row out of two sections at once, and dropping the
						# status test keeps a future-dated skipped row visible — skipping next Tuesday in
						# advance is normal, and an open-only filter would leave that row in no section
						# and outside the hidden count.
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
						noun = if (older + undated == 1) "session" else "sessions"
						older_note =
							if older == 0 and undated == 0 {
								""
							} else {
								"\n\n(${hidden} ${noun} not shown — STRIDE_FORMAT=json stride week all has every row)"
							}
						"${Str.join_with([section("upcoming", upcoming), section("this week", current), section("last week", history)], "\n\n")}${older_note}"
					}
				},
		)
	}
	plan_add! : Str, Str, Str, Str, [NoTarget, Target(Str)] => Try({}, _)
	plan_add! = |target_date, session_type, detail, rationale, tgt| {
		# Reject a bad date at the door, BEFORE the db is even opened. planned_sessions is
		# judgment tier — nothing here can be re-derived from Strava — so a typo that lands
		# in the table stays until someone edits SQL by hand. It would also belong to no
		# training week, matching no completion or adherence query, and would surface only
		# as a number in `week all`'s undated count.
		if !(Metrics.is_canonical_date(target_date)) {
			Output.err_out!("bad_date", "week add needs a calendar date written YYYY-MM-DD — got '${target_date}'")
		} else {
			# the target literal is refused at the door too (ADR 0014 §1): a target that
			# half-parses is one the athlete and the arithmetic disagree about
			match tgt {
				NoTarget => plan_add_checked!(target_date, session_type, detail, rationale, NoT)
				Target(lit) =>
					match Metrics.parse_any_target(lit) {
						Ok(t) => plan_add_checked!(target_date, session_type, detail, rationale, T(t))
						Err(BadTarget) => Output.err_out!("bad_target", target_grammar(lit))
					}
			}
		}
	}
	# the one sentence naming every target form, for each surface that refuses one
	target_grammar : Str -> Str
	target_grammar = |lit|
		"a target is <reps>x<rep>@<signal>: power 3x12:00@230W, heart rate 1x60:00@HR125-147, HR zone 1x90:00@Z2, session rating 1x45:00@RPE6, or pace 5x4:00@4:10/km, 3x10:00@6:45/mi, 10x100m@1:40/100m, 6x500m@1:55/500m — got '${lit}' (reps 1-99, a timed rep at least 0:30; power keeps mm:ss, the others also take h:mm:ss; only a pace rep may be a distance)"
	plan_add_checked! : Str, Str, Str, Str, [NoT, T(Metrics.Target)] => Try({}, _)
	plan_add_checked! = |target_date, session_type, detail, rationale, pt| {
		path = Db.open_db!({})?
		# a zone target means the athlete's zones, so it needs them configured, like analyze
		is_zone =
			match pt {
				T(t) => t.kind == "zone"
				NoT => Bool.False
			}
		zones_ok =
			if is_zone {
				match Analyze.load_zone_config!(path) {
					Ok(_) => Ok(Bool.True)
					Err(MissingConfig) => Ok(Bool.False)
					Err(other) => Err(other)
				}
			} else {
				Ok(Bool.True)
			}
		if !(zones_ok?) {
			Output.missing_config!({})
		} else {
			# guard: one open planned session per date — skip or complete the old one first
			existing = Sql.query!({
				path: Path.utf8(path),
				query: "SELECT COALESCE(MAX(id), 0) AS id FROM planned_sessions WHERE target_date = :date AND COALESCE(status, 'open') = 'open'",
				bindings: [{ name: ":date", value: String(target_date) }],
				row: Sql.i64("id"),
			})?
			if (existing > 0)
			# re-planning a date REVISES its open session in place. Editing a future plan
			# is not a "skip" (skip = a session that was going to happen and didn't), so
			# revising keeps one row per date instead of stacking a skipped tombstone every
			# time the week is re-planned — the root cause of the plan graveyard.
				revise_planned_session!(path, existing, target_date, session_type, detail, rationale, pt)
			else
				insert_planned_session!(path, target_date, session_type, detail, rationale, pt)
		}
	}
	# The four target columns of a row. The literal carries every kind; the three
	# power columns hold a power target's numbers and stay NULL for any other kind,
	# so the readers that mean power (the projection, the window's curve) need no
	# kind test to keep a heart-rate or pace target out.
	target_bindings : [NoT, T(Metrics.Target)] -> List(Sql.Binding)
	target_bindings = |pt| {
		t =
			match pt {
				T(x) => x
				NoT => Metrics.no_target
			}
		power = t.kind == "power"
		[
			{ name: ":treps", value: if (power) Integer(t.reps) else Null },
			{ name: ":tdur", value: if (power) Integer(t.dur_s) else Null },
			{ name: ":twatts", value: if (power) Real(t.watts) else Null },
			{ name: ":tlit", value: if (t.kind == "") Null else String(Metrics.target_literal(t)) },
		]
	}
	# a revise REPLACES the prescription wholesale — type, detail, rationale and target
	# together, so omitting the target on a re-plan CLEARS it rather than silently
	# keeping numbers the new prose no longer describes (ADR 0014 §5)
	revise_planned_session! : Str, I64, Str, Str, Str, Str, [NoT, T(Metrics.Target)] => Try({}, _)
	revise_planned_session! = |path, id, target_date, session_type, detail, rationale, pt| {
		Sql.execute!({
			path: Path.utf8(path),
			query: "UPDATE planned_sessions SET session_type = :type, detail = :detail, rationale = :rationale, created_at = :at, target_reps = :treps, target_dur_s = :tdur, target_watts = :twatts, target_literal = :tlit WHERE id = :id",
			bindings: List.concat(
				[
					{ name: ":type", value: String(session_type) },
					{ name: ":detail", value: String(detail) },
					{ name: ":rationale", value: String(rationale) },
					{ name: ":at", value: String(Metrics.epoch_to_iso(Db.now_secs!({}))) },
					{ name: ":id", value: Integer(id) },
				],
				target_bindings(pt),
			),
		})?
		Output.out!(plan_echo(id, target_date, session_type, pt), |p| "revised #${(p.id).to_str()}: ${p.session_type} on ${p.target_date}${Render.target_note(pt)}")
	}
	# the ADR 0009 impossible-zero shape for the echo: reps 0 cannot be a real target,
	# so the magnitudes ride at 0 behind target_known, and a magnitude another kind
	# carries rides at 0 (or "") behind target_kind
	plan_echo : I64, Str, Str, [NoT, T(Metrics.Target)] -> { id : I64, target_date : Str, session_type : Str, target_known : Bool, target_kind : Str, target_literal : Str, target_reps : I64, target_dur_s : I64, target_dist_m : F64, target_watts : F64, target_hr_lo : I64, target_hr_hi : I64, target_zone : I64, target_pace_s : F64, target_pace_unit : Str, target_rpe : I64 }
	plan_echo = |id, target_date, session_type, pt| {
		t =
			match pt {
				T(x) => x
				NoT => Metrics.no_target
			}
		{ id, target_date, session_type, target_known: t.kind != "", target_kind: t.kind, target_literal: Metrics.target_literal(t), target_reps: t.reps, target_dur_s: t.dur_s, target_dist_m: t.dist_m, target_watts: t.watts, target_hr_lo: t.hr_lo, target_hr_hi: t.hr_hi, target_zone: t.zone, target_pace_s: t.pace_s, target_pace_unit: t.pace_unit, target_rpe: t.rpe }
	}
	insert_planned_session! : Str, Str, Str, Str, Str, [NoT, T(Metrics.Target)] => Try({}, _)
	insert_planned_session! = |path, target_date, session_type, detail, rationale, pt| {
		Sql.execute!({
			path: Path.utf8(path),
			query: \\INSERT INTO planned_sessions (created_at, target_date, session_type, detail, rationale, status, target_reps, target_dur_s, target_watts, target_literal)
				\\VALUES (:at, :date, :type, :detail, :rationale, 'open', :treps, :tdur, :twatts, :tlit)
			,
			bindings: List.concat(
				[
					{ name: ":at", value: String(Metrics.epoch_to_iso(Db.now_secs!({}))) },
					{ name: ":date", value: String(target_date) },
					{ name: ":type", value: String(session_type) },
					{ name: ":detail", value: String(detail) },
					{ name: ":rationale", value: String(rationale) },
				],
				target_bindings(pt),
			),
		})?
		new_id = Sql.query!({
			path: Path.utf8(path),
			query: "SELECT MAX(id) AS id FROM planned_sessions",
			bindings: [],
			row: Sql.i64("id"),
		})?
		Output.out!(plan_echo(new_id, target_date, session_type, pt), |p| "planned #${(p.id).to_str()}: ${p.session_type} on ${p.target_date}${Render.target_note(pt)}")
	}
	# ONE not-found message for every command that resolves a planned session by id —
	# complete, complete-rest, skip and relabel — so the four cannot drift apart. Adding a
	# fifth means calling this, not writing a fifth sentence.
	session_not_found! : I64 => Try({}, _)
	session_not_found! = |session_id|
		Output.err_out!("session_not_found", "no planned session #${(session_id).to_str()} — `stride plan` lists open ones, `stride week all` the whole log")

	# ADR 0014 §3 on every signal (ADR 0019): the recorded target beside what the
	# linked activity did on THAT target's signal — arithmetic on two records, each
	# side gated by its own _known flag (ADR 0009) so an absent side is stated, never
	# invented. The power fields keep their meaning: detected power work against
	# target watts. The exec_* block answers for the target's own signal, whatever
	# its kind:
	#   power  exec_known is detected_known
	#   hr     seconds under, inside and over the band, and the mean of the stream's
	#          valid (35-220 bpm) samples
	#   zone   seconds below, inside and above the zone, from the zone split analyze
	#          stored under the zones in force for that sport
	#   pace   the ACTUAL pace, always: over the detector's work-rep windows when it
	#          found pace reps (distance from the stream, since the detector's own
	#          signal is grade-adjusted), else over the whole moving portion
	#          (distance over moving time), as seconds per the target's unit
	#   rpe    the session's stored rating; rpe_known says the target is an RPE
	#          one and a rating exists
	# exec_reason names why exec_known is false. Field names are measurements, never
	# verdicts (ADR 0012).
	TargetMatch : { target_known : Bool, target_kind : Str, target_literal : Str, target_reps : I64, target_dur_s : I64, target_dist_m : F64, target_watts : F64, target_hr_lo : I64, target_hr_hi : I64, target_zone : I64, target_pace_s : F64, target_pace_unit : Str, target_rpe : I64, detected_known : Bool, detected_reps : I64, detected_mean_dur_s : I64, detected_mean_watts : F64, reps_delta : I64, watts_pct : F64, exec_known : Bool, exec_reason : Str, hr_under_s : I64, hr_in_s : I64, hr_over_s : I64, hr_mean : F64, zone_below_s : I64, zone_in_s : I64, zone_above_s : I64, pace_basis : Str, pace_actual_s : F64, pace_pct : F64, pace_reps : I64, pace_reps_delta : I64, rpe_actual : F64, rpe_known : Bool }
	target_match! : Str, I64, I64 => Try(TargetMatch, _)
	target_match! = |path, session_id, activity_id| {
		tgt = Sql.query!({
			path: Path.utf8(path),
			# `tgd`, not `td`: relabel! reads a TEXT `td` in this same file, and
			# blob-safety joins (file, alias) — a shared name would put this INTEGER
			# projection in the TEXT rule's population
			query: "SELECT COALESCE(target_reps, 0) AS tgr, COALESCE(target_dur_s, 0) AS tgd, CAST(COALESCE(target_watts, 0) AS REAL) AS tgw, COALESCE(CAST(target_literal AS TEXT), '') AS tgl FROM planned_sessions WHERE id = :id",
			bindings: [{ name: ":id", value: Integer(session_id) }],
			row: |cols| |stmt| {
				tr = Sql.i64("tgr")(cols)(stmt)?
				td = Sql.i64("tgd")(cols)(stmt)?
				tw = Sql.f64("tgw")(cols)(stmt)?
				tl = Sql.str("tgl")(cols)(stmt)?
				Ok({ tr, td, tw, tl })
			},
		})?
		t = Metrics.stored_target(tgt.tl, tgt.tr, tgt.td, tgt.tw)
		seg! = |signal|
			Sql.query!({
				path: Path.utf8(path),
				query: "SELECT COUNT(*) AS dr, CAST(COALESCE(AVG(dur_s), 0) AS INTEGER) AS dd, CAST(COALESCE(AVG(avg_signal), 0) AS REAL) AS dw FROM activity_segments WHERE activity_id = :aid AND kind = 'work' AND signal = :sig",
				bindings: [{ name: ":aid", value: Integer(activity_id) }, { name: ":sig", value: String(signal) }],
				row: |cols| |stmt| {
					dr = Sql.i64("dr")(cols)(stmt)?
					dd = Sql.i64("dd")(cols)(stmt)?
					dw = Sql.f64("dw")(cols)(stmt)?
					Ok({ dr, dd, dw })
				},
			})
		det = seg!("power")?
		power = t.kind == "power"
		detected_known = det.dr > 0
		both = power and detected_known
		ex = exec_for!(path, activity_id, t, detected_known)?
		Ok({
			target_known: t.kind != "",
			target_kind: t.kind,
			target_literal: Metrics.target_literal(t),
			target_reps: t.reps,
			target_dur_s: t.dur_s,
			target_dist_m: t.dist_m,
			target_watts: t.watts,
			target_hr_lo: t.hr_lo,
			target_hr_hi: t.hr_hi,
			target_zone: t.zone,
			target_pace_s: t.pace_s,
			target_pace_unit: t.pace_unit,
			target_rpe: t.rpe,
			detected_known,
			detected_reps: det.dr,
			detected_mean_dur_s: det.dd,
			detected_mean_watts: det.dw,
			reps_delta: if (both) det.dr - t.reps else 0,
			watts_pct: if (both and t.watts > 0.0) det.dw / t.watts * 100.0 else 0.0,
			exec_known: ex.known,
			exec_reason: ex.reason,
			hr_under_s: ex.hr.under_s,
			hr_in_s: ex.hr.in_s,
			hr_over_s: ex.hr.over_s,
			hr_mean: ex.hr_mean,
			zone_below_s: ex.zone.below_s,
			zone_in_s: ex.zone.in_s,
			zone_above_s: ex.zone.above_s,
			pace_basis: ex.pace.basis,
			pace_actual_s: ex.pace.actual_s,
			pace_pct: if (ex.pace.actual_s > 0.0) t.pace_s / ex.pace.actual_s * 100.0 else 0.0,
			pace_reps: ex.pace.reps,
			pace_reps_delta: if (ex.pace.basis == "detected") ex.pace.reps - t.reps else 0,
			rpe_actual: ex.rpe,
			rpe_known: t.kind == "rpe" and ex.known,
		})
	}

	# the fields the rendered target clause reads, out of a TargetMatch
	note_fields : TargetMatch -> { target_kind : Str, target_literal : Str, target_pace_unit : Str, target_rpe : I64, detected_known : Bool, detected_reps : I64, detected_mean_dur_s : I64, detected_mean_watts : F64, exec_known : Bool, exec_reason : Str, hr_under_s : I64, hr_in_s : I64, hr_over_s : I64, hr_mean : F64, zone_below_s : I64, zone_in_s : I64, zone_above_s : I64, pace_basis : Str, pace_actual_s : F64, pace_reps : I64, rpe_actual : F64 }
	note_fields = |tm| { target_kind: tm.target_kind, target_literal: tm.target_literal, target_pace_unit: tm.target_pace_unit, target_rpe: tm.target_rpe, detected_known: tm.detected_known, detected_reps: tm.detected_reps, detected_mean_dur_s: tm.detected_mean_dur_s, detected_mean_watts: tm.detected_mean_watts, exec_known: tm.exec_known, exec_reason: tm.exec_reason, hr_under_s: tm.hr_under_s, hr_in_s: tm.hr_in_s, hr_over_s: tm.hr_over_s, hr_mean: tm.hr_mean, zone_below_s: tm.zone_below_s, zone_in_s: tm.zone_in_s, zone_above_s: tm.zone_above_s, pace_basis: tm.pace_basis, pace_actual_s: tm.pace_actual_s, pace_reps: tm.pace_reps, rpe_actual: tm.rpe_actual }

	# The session's target result as text, beside the row it describes, for readers
	# that cannot run the scoring (the window). It is a snapshot taken when `complete`
	# links the activity and again when `rate` changes the activity's rating; a
	# session completed before its activity was analyzed keeps the result it had
	# then until it is completed again.
	store_target_result! : Str, I64, Str => Try({}, _)
	store_target_result! = |path, session_id, text| {
		_ = Sql.execute!({
			path: Path.utf8(path),
			query: "UPDATE planned_sessions SET target_result = :t WHERE id = :pid",
			bindings: [{ name: ":t", value: String(text) }, { name: ":pid", value: Integer(session_id) }],
		})?
		Ok({})
	}

	# every done session the activity completes gets its stored result recomputed
	refresh_target_results_for! : Str, I64 => Try({}, _)
	refresh_target_results_for! = |path, activity_id| {
		ids = Sql.query_many!({
			path: Path.utf8(path),
			query: "SELECT id AS sid FROM planned_sessions WHERE completed_activity_id = :aid AND status = 'done'",
			bindings: [{ name: ":aid", value: Integer(activity_id) }],
			rows: |cols| |stmt| Sql.i64("sid")(cols)(stmt),
		})?
		_ = List.map_try!(
			ids,
			|sid| {
				tm = target_match!(path, sid, activity_id)?
				store_target_result!(path, sid, Render.target_result_text(note_fields(tm)))
			},
		)?
		Ok({})
	}

	# the execution of one target on its own signal; every magnitude another kind
	# would carry stays at 0 or ""
	exec_for! : Str, I64, Metrics.Target, Bool => Try({ known : Bool, reason : Str, hr : { under_s : I64, in_s : I64, over_s : I64 }, hr_mean : F64, zone : { below_s : I64, in_s : I64, above_s : I64 }, pace : { basis : Str, actual_s : F64, reps : I64 }, rpe : F64 }, _)
	exec_for! = |path, activity_id, t, power_detected| {
		none = { known: Bool.False, reason: "", hr: { under_s: 0, in_s: 0, over_s: 0 }, hr_mean: 0.0, zone: { below_s: 0, in_s: 0, above_s: 0 }, pace: { basis: "", actual_s: 0.0, reps: 0 }, rpe: 0.0 }
		if t.kind == "" {
			Ok({ ..none, reason: "no_target" })
		} else if t.kind == "power" {
			Ok(if (power_detected) { ..none, known: Bool.True } else { ..none, reason: "no_power_intervals" })
		} else if t.kind == "rpe" {
			rated = Sql.query_many!({
				path: Path.utf8(path),
				query: "SELECT CAST(rpe AS REAL) AS rpe FROM ratings WHERE activity_id = :id",
				bindings: [{ name: ":id", value: Integer(activity_id) }],
				rows: Sql.f64("rpe"),
			})?
			match List.first(rated) {
				Ok(r) => Ok({ ..none, known: Bool.True, rpe: r })
				Err(_) => Ok({ ..none, reason: "no_rating" })
			}
		} else if t.kind == "hr" {
			s = stream_of!(path, activity_id)?
			hr_pairs = List.keep_if(Streams.stream_pairs(s.time, s.heartrate), |p| Metrics.valid_hr(p.v))
			if List.is_empty(hr_pairs) {
				Ok({ ..none, reason: "no_hr_stream" })
			} else {
				band = Metrics.hr_band_seconds(hr_pairs, t.hr_lo, t.hr_hi)
				mean = List.fold(hr_pairs, 0.0, |a, p| a + p.v) / (List.len(hr_pairs)).to_f64()
				Ok({ ..none, known: Bool.True, hr: band, hr_mean: mean })
			}
		} else if t.kind == "zone" {
			zs = Sql.query_many!({
				path: Path.utf8(path),
				query: "SELECT COALESCE(z1_s, 0) AS z1, COALESCE(z2_s, 0) AS z2, COALESCE(z3_s, 0) AS z3, COALESCE(z4_s, 0) AS z4, COALESCE(z5_s, 0) AS z5 FROM activity_metrics WHERE activity_id = :id AND COALESCE(hr_samples_total, 0) > 0",
				bindings: [{ name: ":id", value: Integer(activity_id) }],
				rows: |cols| |stmt| {
					z1 = Sql.i64("z1")(cols)(stmt)?
					z2 = Sql.i64("z2")(cols)(stmt)?
					z3 = Sql.i64("z3")(cols)(stmt)?
					z4 = Sql.i64("z4")(cols)(stmt)?
					z5 = Sql.i64("z5")(cols)(stmt)?
					Ok([z1, z2, z3, z4, z5])
				},
			})?
			match List.first(zs) {
				Err(_) => Ok({ ..none, reason: "no_hr_zones" })
				Ok(z) => {
					n = (t.zone - 1).to_u64_wrap()
					below = List.sum(List.take_first(z, n))
					inside = List.get(z, n).ok_or(0)
					above = List.sum(List.drop_first(z, n + 1))
					Ok({ ..none, known: Bool.True, zone: { below_s: below, in_s: inside, above_s: above } })
				}
			}
		} else {
			acts = Sql.query_many!({
				path: Path.utf8(path),
				query: "SELECT COALESCE(CAST(sport_type AS TEXT), '') AS sp, CAST(COALESCE(distance, 0) AS REAL) AS dist, COALESCE(moving_time, 0) AS mt FROM activities WHERE id = :id",
				bindings: [{ name: ":id", value: Integer(activity_id) }],
				rows: |cols| |stmt| {
					sp = Sql.str("sp")(cols)(stmt)?
					dist = Sql.f64("dist")(cols)(stmt)?
					mt = Sql.i64("mt")(cols)(stmt)?
					Ok({ sp, dist, mt })
				},
			})?
			a = List.first(acts).ok_or({ sp: "", dist: 0.0, mt: 0 })
			if !(List.contains(Sports.pace_unit_families(t.pace_unit), Sports.canonical(a.sp))) {
				Ok({ ..none, reason: "pace_unit_mismatch" })
			} else {
				# the detector's work reps are found on grade-adjusted speed, so their
				# own average is not the pace that was run; their ACTUAL pace is the
				# distance the stream covered inside their windows, over their time
				windows = Sql.query_many!({
					path: Path.utf8(path),
					query: "SELECT COALESCE(start_s, 0) AS ws, COALESCE(dur_s, 0) AS wd FROM activity_segments WHERE activity_id = :aid AND kind = 'work' AND signal = 'pace' ORDER BY ordinal",
					bindings: [{ name: ":aid", value: Integer(activity_id) }],
					rows: |cols| |stmt| {
						ws = Sql.i64("ws")(cols)(stmt)?
						wd = Sql.i64("wd")(cols)(stmt)?
						Ok({ start_s: ws, dur_s: wd })
					},
				})?
				rep_speed =
					if List.is_empty(windows) {
						0.0
					} else {
						s = stream_of!(path, activity_id)?
						Metrics.windows_speed(Streams.stream_pairs(s.time, s.distance), windows)
					}
				if rep_speed > 0.0 {
					Ok({ ..none, known: Bool.True, pace: { basis: "detected", actual_s: Metrics.pace_s_per_unit(rep_speed, t.pace_unit), reps: List.len(windows).to_i64_wrap() } })
				} else if a.dist > 0.0 and a.mt > 0 {
					Ok({ ..none, known: Bool.True, pace: { basis: "whole", actual_s: Metrics.pace_s_per_unit(a.dist / (a.mt).to_f64(), t.pace_unit), reps: 0 } })
				} else {
					Ok({ ..none, reason: "no_distance" })
				}
			}
		}
	}
	# the activity's stored streams, decoded; all absent when it has none
	stream_of! : Str, I64 => Try(Streams.StreamsResp, _)
	stream_of! = |path, activity_id| {
		raws = Sql.query_many!({
			path: Path.utf8(path),
			query: "SELECT COALESCE(CAST(raw_json AS TEXT), '') AS raw FROM streams WHERE activity_id = :id",
			bindings: [{ name: ":id", value: Integer(activity_id) }],
			rows: Sql.str("raw"),
		})?
		raw = List.first(raws).ok_or("")
		Ok(if (raw == "") Streams.empty_streams else (Streams.decode_streams(NotNull(raw))).streams)
	}
	# `complete latest` is pure argument RESOLUTION in front of complete! - it
	# resolves the two ids and hands them over as strings, so every guarantee
	# of the completion path (claimant checks, the overwrite report, permanence)
	# is the same code on the same inputs, reached a shorter way.
	# The session is the open one on the activity's own day: plan_add_checked!
	# enforces one open session per date at write time, so that is 0 or 1 rows -
	# a lookup, never a ranking.
	complete_latest! : {} => Try({}, _)
	complete_latest! = |{}| {
		path = Db.open_db!({})?
		match Report.latest_activity!(path) {
			# an empty database is a first-run state, not a fault: it gets the same
			# named refusal `rate latest` gives, never the catch-all
			Err(NoActivities) => Output.err_out!("no_activities", "nothing to complete yet — `stride sync` or `stride import` first")
			Err(other) => Err(other)
			Ok(latest) => {
				# MAX(id) is the tie-break for a hand-edited database holding more
				# than one open session on the day - the same one `week add` uses.
				# plan_add_checked! is the only INSERT path and it refuses the second.
				open_id = Sql.query!({
					path: Path.utf8(path),
					query: "SELECT COALESCE(MAX(id), 0) AS id FROM planned_sessions WHERE target_date = :date AND COALESCE(status, 'open') = 'open'",
					bindings: [{ name: ":date", value: String(latest.day) }],
					row: Sql.i64("id"),
				})?
				if (open_id == 0)
					Output.err_out!("no_open_session", "no open planned session on ${latest.day}, the day of activity ${I64.to_str(latest.id)} — `stride week` lists what is open, or complete it by id")
				else
					complete!(I64.to_str(open_id), I64.to_str(latest.id))
			}
		}
	}

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
						# a completion is permanent evidence with no release path,
						# so the message names that fact and the fix, and never
						# suggests a release that would turn the row skipped.
							Output.err_out!("activity_already_linked", "activity ${I64.to_str(activity_id)} already completed session #${I64.to_str(cid)} — completions are permanent; pick a different activity")
						SubstituteOf(cid) =>
							Output.err_out!("activity_already_linked", "activity ${I64.to_str(activity_id)} substitutes session #${I64.to_str(cid)} — release it first: stride skip ${I64.to_str(cid)} \"<reason>\" none")
						Free => {
							# WHAT THIS REPLACES, read before the write: `complete` on an
							# already-done session overwrites `completed_activity_id`, and without this
							# read its payload would be indistinguishable from a first-time completion, so
							# a typo'd session id would report success while overwriting real history.
							# NOT refused: `skip`'s own message names re-completing as the documented repair
							# for a mis-linked completion, so refusing would falsify the only repair path
							# stride documents. The bug is SILENTLY, not overwrites.
							# BOTH judgment-tier links, because the UPDATE destroys both: reading only
							# `completed_activity_id` answered `replaced_activity: 0` — an affirmative
							# "nothing was replaced" — on a call that had just erased the record that the
							# athlete substituted this activity for the session.
							prior = Sql.query!({
								path: Path.utf8(path),
								query: "SELECT COALESCE(completed_activity_id, 0) AS prior, COALESCE(substitute_activity_id, 0) AS sub FROM planned_sessions WHERE id = :pid",
								bindings: [{ name: ":pid", value: Integer(session_id) }],
								row: |cols| |stmt| {
									p = Sql.i64("prior")(cols)(stmt)?
									s = Sql.i64("sub")(cols)(stmt)?
									Ok({ p, s })
								},
							})?
							# write first, steal second: a failure between the two
							# leaves only a dead tombstone link (self-healing), never
							# a released link with nothing written in its place
							_ = Sql.execute!({
								path: Path.utf8(path),
								# `superseded_activity_id` is written in the SAME statement, from the column's
								# own prior value, so it can never disagree with what was erased — computing it
								# in Roc reintroduces the read-then-write gap.
								# `NOT IN (0, :aid)`, the same clause `replaced_activity` uses: 0 because an
								# unset completion reads as 0 through COALESCE, and recording it would claim a
								# completion was erased when there was none; `:aid` because re-completing with
								# the SAME activity erases nothing, and recording it would overwrite a genuine
								# erased id with "this activity replaced itself".
								# `ELSE superseded_activity_id`, not NULL: a no-op re-run must leave the record
								# standing, which is the whole point.
								query: "UPDATE planned_sessions SET superseded_activity_id = CASE WHEN COALESCE(completed_activity_id, 0) NOT IN (0, :aid) THEN completed_activity_id ELSE superseded_activity_id END, completed_activity_id = :aid, status = 'done', substitute_activity_id = NULL WHERE id = :pid",
								bindings: [
									{ name: ":aid", value: Integer(activity_id) },
									{ name: ":pid", value: Integer(session_id) },
								],
							})?
							# `replaced_activity` and `dropped_substitute` on EVERY arm, 0 when nothing was
							# destroyed: both answer a question a consumer must ask on every completion, so
							# absence would be indistinguishable from a consumer that forgot to ask. 0 is
							# safe for the same reason `ftp_used > 0` is — no activity has id 0.
							# `released_substitute_of` stays OPTIONAL because it reports an incidental side
							# effect on a DIFFERENT session, meaningful only when it happened.
							#
							# `dropped_substitute`, NOT `released_substitute`: `skip` OMITS that key when
							# nothing was released (pinned by a `!contains`), so a consumer that correctly
							# learned `has("released_substitute")` there would read "a substitute was
							# released" on every completion: one name cannot carry two absence contracts.
							replaced = if (prior.p != activity_id) prior.p else 0
							# ...and `sub != activity_id` IS load-bearing: re-completing with
							# the activity that was already the substitute is a promotion,
							# not a loss, and reporting it as released would name a link the
							# caller still holds.
							released = if (prior.s != activity_id) prior.s else 0
							# ...and the note NAMES THE REPAIR while the id is still on screen — the pattern
							# `skip`'s refusal already uses. The erased id also survives in
							# `superseded_activity_id`, written in the same UPDATE, so the record
							# outlives the line.
							#
							# The remedy is EXACTLY invertible on this row: `replaced_activity` and
							# `dropped_substitute` are mutually exclusive in every CLI-reachable state, since
							# every write that sets `completed_activity_id` NULLs `substitute_activity_id` in
							# the same statement, and `skip`'s Sub arm refuses a `done` row. SECOND leg:
							# `skip`'s guard keys on `status = 'done'`, so the invariant also needs
							# `completed_activity_id != 0 => status = 'done'` — true only because this UPDATE
							# is the sole writer and sets both in one statement. Any future writer inherits
							# that obligation, and the e2e asserts the pair count is 0.
							# "this session's completion", not "it": the ReleasedFrom arm also clears a
							# substitute on a DIFFERENT session, and the remedy does not bring that back.
							replaced_note = if (replaced != 0) " (replacing activity ${I64.to_str(replaced)}, whose completion of this session is now gone — `stride complete ${I64.to_str(session_id)} ${I64.to_str(replaced)}` puts this session's completion back)" else ""
							released_note = if (released != 0) " (dropping substitute activity ${I64.to_str(released)}, which no longer stands in for this session)" else ""
							tm = target_match!(path, session_id, activity_id)?
							tm_note = Render.target_match_note(note_fields(tm))
							store_target_result!(path, session_id, Render.target_result_text(note_fields(tm)))?
							match steal_dead_links!(path, activity_id, session_id)? {
								ReleasedFrom(holder) =>
									Output.out!({ completed_session: session_id, activity: activity_id, replaced_activity: replaced, dropped_substitute: released, released_substitute_of: holder, target_known: tm.target_known, target_kind: tm.target_kind, target_literal: tm.target_literal, target_reps: tm.target_reps, target_dur_s: tm.target_dur_s, target_dist_m: tm.target_dist_m, target_watts: tm.target_watts, target_hr_lo: tm.target_hr_lo, target_hr_hi: tm.target_hr_hi, target_zone: tm.target_zone, target_pace_s: tm.target_pace_s, target_pace_unit: tm.target_pace_unit, target_rpe: tm.target_rpe, detected_known: tm.detected_known, detected_reps: tm.detected_reps, detected_mean_dur_s: tm.detected_mean_dur_s, detected_mean_watts: tm.detected_mean_watts, reps_delta: tm.reps_delta, watts_pct: tm.watts_pct, exec_known: tm.exec_known, exec_reason: tm.exec_reason, hr_under_s: tm.hr_under_s, hr_in_s: tm.hr_in_s, hr_over_s: tm.hr_over_s, hr_mean: tm.hr_mean, zone_below_s: tm.zone_below_s, zone_in_s: tm.zone_in_s, zone_above_s: tm.zone_above_s, pace_basis: tm.pace_basis, pace_actual_s: tm.pace_actual_s, pace_pct: tm.pace_pct, pace_reps: tm.pace_reps, pace_reps_delta: tm.pace_reps_delta, rpe_actual: tm.rpe_actual, rpe_known: tm.rpe_known }, |o| "planned session #${I64.to_str(o.completed_session)} completed by activity ${I64.to_str(o.activity)}${replaced_note}${released_note}${tm_note} (released its old substitute link on session #${I64.to_str(o.released_substitute_of)})")
								NothingReleased =>
									Output.out!({ completed_session: session_id, activity: activity_id, replaced_activity: replaced, dropped_substitute: released, target_known: tm.target_known, target_kind: tm.target_kind, target_literal: tm.target_literal, target_reps: tm.target_reps, target_dur_s: tm.target_dur_s, target_dist_m: tm.target_dist_m, target_watts: tm.target_watts, target_hr_lo: tm.target_hr_lo, target_hr_hi: tm.target_hr_hi, target_zone: tm.target_zone, target_pace_s: tm.target_pace_s, target_pace_unit: tm.target_pace_unit, target_rpe: tm.target_rpe, detected_known: tm.detected_known, detected_reps: tm.detected_reps, detected_mean_dur_s: tm.detected_mean_dur_s, detected_mean_watts: tm.detected_mean_watts, reps_delta: tm.reps_delta, watts_pct: tm.watts_pct, exec_known: tm.exec_known, exec_reason: tm.exec_reason, hr_under_s: tm.hr_under_s, hr_in_s: tm.hr_in_s, hr_over_s: tm.hr_over_s, hr_mean: tm.hr_mean, zone_below_s: tm.zone_below_s, zone_in_s: tm.zone_in_s, zone_above_s: tm.zone_above_s, pace_basis: tm.pace_basis, pace_actual_s: tm.pace_actual_s, pace_pct: tm.pace_pct, pace_reps: tm.pace_reps, pace_reps_delta: tm.pace_reps_delta, rpe_actual: tm.rpe_actual, rpe_known: tm.rpe_known }, |o| "planned session #${I64.to_str(o.completed_session)} completed by activity ${I64.to_str(o.activity)}${replaced_note}${released_note}${tm_note}")
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
		Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT a.id AS id, COALESCE(CAST(a.start_local AS TEXT), '') AS start,
				\\       COALESCE(CAST(a.sport_type AS TEXT), '') AS sport, COALESCE(CAST(a.name AS TEXT), '') AS name
				\\FROM activities a
				\\JOIN planned_sessions p ON p.id = :pid
				\\WHERE a.start_local >= date(p.target_date, '-1 day')
				\\  AND a.start_local <  date(p.target_date, '+2 day')
				\\ORDER BY ${Metrics.rank_ts_sql("a.start_local", Desc)}, a.id DESC
				\\LIMIT 5
			,
			bindings: [{ name: ":pid", value: Integer(session_id) }],
			rows: |cols| |stmt| {
				id = Sql.i64("id")(cols)(stmt)?
				start = Sql.str("start")(cols)(stmt)?
				sport = Sql.str("sport")(cols)(stmt)?
				name = Sql.str("name")(cols)(stmt)?
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
				if (!(Report.row_exists!(path, "planned_sessions", session_id)?))
					session_not_found!(session_id)
				else {
					session_type = Sql.query!({
						path: Path.utf8(path),
						query: "SELECT COALESCE(CAST(session_type AS TEXT), '') AS t FROM planned_sessions WHERE id = :pid",
						bindings: [{ name: ":pid", value: Integer(session_id) }],
						row: Sql.str("t"),
					})?
					if session_type != "rest" {
						# Naming the rule is not enough: the id lives in the database, and
						# a reader without it has no way to find it short of opening
						# SQLite. So list the activities actually near this session's
						# date — the answer is almost always one of them.
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
						# THIS arm is `complete` too, and complete.json is one contract for both:
						# `replaced_activity` added to the two-argument form only left this payload
						# failing its own schema, and nothing catches it — schema-check and the e2e
						# conformance loop both select `mutates == false`, and `complete` mutates, so it is
						# validated by neither. The e2e check below is that missing oracle.
						# A bare rest completion links no activity, so `replaced_activity` is honestly 0
						# — but the same UPDATE NULLs `substitute_activity_id`, so `dropped_substitute`
						# must be read before the write on this arm too.
						# `0.I64`, not a bare `0`: Roc infers an unconstrained record literal as
						# fractional, and the builtin JSON renders `0.0`, a float under an integer key
						# that the validator's integer test (floor($v) == $v) accepts.
						released = Sql.query!({
							path: Path.utf8(path),
							query: "SELECT COALESCE(substitute_activity_id, 0) AS sub FROM planned_sessions WHERE id = :pid",
							bindings: [{ name: ":pid", value: Integer(session_id) }],
							row: Sql.i64("sub"),
						})?
						Sql.execute!({
							path: Path.utf8(path),
							query: "UPDATE planned_sessions SET status = 'done', substitute_activity_id = NULL WHERE id = :pid",
							bindings: [{ name: ":pid", value: Integer(session_id) }],
						})?
						released_note = if (released != 0) " (dropping substitute activity ${I64.to_str(released)}, which no longer stands in for this session)" else ""
						# rest must be Bool-TYPED (1 == 1), not a bare `True` tag — the new
						# builtin JSON renders a bare tag as the string "True", not true.
						Output.out!({ completed_session: session_id, rest: 1 == 1, replaced_activity: 0.I64, dropped_substitute: released }, |p| "planned session #${(p.completed_session).to_str()} (rest) marked done${released_note}")
					}
				}
		}
	}
	# One activity, one story — but only LIVE claims block a new one. A superseded
	# skip tombstone's substitute link is display-dead already (the week hides the
	# row), so a fresh claim STEALS it: the tombstone's link is cleared and the
	# claim proceeds. Without the steal, `week` advertises the activity as
	# unlinked and then refuses the very command that acts on it. Live claimants
	# (any completion, or a substitute on a non-superseded row) refuse the claim,
	# naming the blocking session — an error that names the rule without the id
	# leaves the reader nothing but SQLite (see the activity_required note above).
	# The supersession predicate here is the De Morgan dual of the one in the
	# unplanned query and the sessions query — the three MUST agree (see the
	# NOTE above the unplanned query).
	live_claimant! = |path, activity_id, session_id| {
		rows = Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT id AS id, CASE WHEN ps.completed_activity_id = :aid THEN 1 ELSE 0 END AS is_completion
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
				cid = Sql.i64("id")(cols)(stmt)?
				isc = Sql.i64("is_completion")(cols)(stmt)?
				Ok({ cid, isc })
			},
		})?
		match List.first(rows) {
			Ok(r) => if (r.isc == 1) Ok(CompletedBy(r.cid)) else Ok(SubstituteOf(r.cid))
			Err(_) => Ok(Free)
		}
	}

	# Clear display-dead tombstone links so the new claim is the one story —
	# called AFTER the claim's own write, so a failure here leaves exactly the
	# pre-existing dead-link state (self-healing on the next claim), never a
	# cleared link with nothing written in its place. Reports what it released
	# so the steal is never silent.
	steal_dead_links! = |path, activity_id, session_id| {
		holders = Sql.query_many!({
			path: Path.utf8(path),
			query: "SELECT id AS id FROM planned_sessions WHERE substitute_activity_id = :aid AND id <> :sid LIMIT 1",
			bindings: [{ name: ":aid", value: Integer(activity_id) }, { name: ":sid", value: Integer(session_id) }],
			rows: Sql.i64("id"),
		})?
		match List.first(holders) {
			Err(_) => Ok(NothingReleased)
			Ok(holder) => {
				_ = Sql.execute!({
					path: Path.utf8(path),
					query: "UPDATE planned_sessions SET substitute_activity_id = NULL WHERE substitute_activity_id = :aid AND id <> :sid",
					bindings: [{ name: ":aid", value: Integer(activity_id) }, { name: ":sid", value: Integer(session_id) }],
				})?
				Ok(ReleasedFrom(holder))
			}
		}
	}

	# sub: an optional activity that REPLACED the plan. A substitution is
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
					# A DONE session cannot be skipped: flipping status to skipped
					# while KEEPING completed_activity_id would leave a skipped row that
					# displays a completion — falsified adherence history — and
					# live_claimant! would contradict the visible status. Completions are
					# permanent evidence; undoing a mis-link takes an explicit verb that
					# clears status AND link together, never a skip side effect.
					done_by = Sql.query_many!({
						path: Path.utf8(path),
						query: "SELECT COALESCE(completed_activity_id, 0) AS a FROM planned_sessions WHERE id = :pid AND COALESCE(status,'open') = 'done'",
						bindings: [{ name: ":pid", value: Integer(session_id) }],
						rows: Sql.i64("a"),
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
									_ = Sql.execute!({
										path: Path.utf8(path),
										query: "UPDATE planned_sessions SET status = 'skipped', skipped_reason = :why WHERE id = :pid",
										bindings: [
											{ name: ":why", value: String(reason) },
											{ name: ":pid", value: Integer(session_id) },
										],
									})?
									kept = Sql.query_many!({
										path: Path.utf8(path),
										query: "SELECT substitute_activity_id AS s FROM planned_sessions WHERE id = :pid AND substitute_activity_id IS NOT NULL",
										bindings: [{ name: ":pid", value: Integer(session_id) }],
										rows: Sql.i64("s"),
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
									had = Sql.query_many!({
										path: Path.utf8(path),
										query: "SELECT substitute_activity_id AS s FROM planned_sessions WHERE id = :pid AND substitute_activity_id IS NOT NULL",
										bindings: [{ name: ":pid", value: Integer(session_id) }],
										rows: Sql.i64("s"),
									})?
									_ = Sql.execute!({
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
														_ = Sql.execute!({
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
																Output.out!({ skipped_session: session_id, reason, substitute_activity_id: activity_id, released_substitute_of: holder }, |o| "planned session #${I64.to_str(o.skipped_session)} skipped: ${o.reason} (did ${I64.to_str(o.substitute_activity_id)} instead; released its old link on session #${I64.to_str(o.released_substitute_of)})")
															NothingReleased =>
																Output.out!({ skipped_session: session_id, reason, substitute_activity_id: activity_id }, |o| "planned session #${I64.to_str(o.skipped_session)} skipped: ${o.reason} (did ${I64.to_str(o.substitute_activity_id)} instead)")
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
	# label-only edit of an existing session, ANY status. `week add` revises an
	# OPEN date in place, but a done session's label was frozen: the real day-swap case
	# left a threshold ride labeled "endurance / long easy ride", and the only fixes were
	# a duplicate row plus a skip tombstone, or hand-run SQL against the judgment tier.
	# Cosmetic by construction: the UPDATE names session_type/detail/rationale and
	# nothing else — status, all three activity link columns (completed, substitute,
	# superseded), created_at and every metric are untouched, so a relabel can never
	# trigger invalidation (`analyze` after one reports computed: 0, pinned by e2e).
	relabel! : Str, Str, Str, [KeepRationale, SetRationale(Str)] => Try({}, _)
	relabel! = |session_id_str, session_type, detail, rat| {
		path = Db.open_db!({})?
		match Metrics.arg_i64(session_id_str) {
			Err(_) =>
				Output.err_out!("bad_id", "relabel needs a numeric id: relabel <session_id> <type> \"<detail>\" [\"<rationale>\"]")
			Ok(session_id) =>
				if !(Report.row_exists!(path, "planned_sessions", session_id)?) {
					session_not_found!(session_id)
				} else {
					# a Null binding keeps the stored rationale via COALESCE — one UPDATE
					# either way, and the keep path provably writes nothing new to it
					rat_val = match rat {
						SetRationale(r) => String(r)
						KeepRationale => Null
					}
					Sql.execute!({
						path: Path.utf8(path),
						query: "UPDATE planned_sessions SET session_type = :type, detail = :detail, rationale = COALESCE(:rationale, rationale) WHERE id = :id",
						bindings: [
							{ name: ":type", value: String(session_type) },
							{ name: ":detail", value: String(detail) },
							{ name: ":rationale", value: rat_val },
							{ name: ":id", value: Integer(session_id) },
						],
					})?
					target_date = Sql.query!({
						path: Path.utf8(path),
						query: "SELECT CAST(target_date AS TEXT) AS td FROM planned_sessions WHERE id = :id",
						bindings: [{ name: ":id", value: Integer(session_id) }],
						row: Sql.str("td"),
					})?
					# the echoed type is READ BACK, never the input argument: an echo of
					# the input would print "threshold" while the row still held
					# "endurance" if the UPDATE failed — the payload claiming
					# the write it is meant to be evidence for
					stored_type = Sql.query!({
						path: Path.utf8(path),
						query: "SELECT CAST(session_type AS TEXT) AS ty FROM planned_sessions WHERE id = :id",
						bindings: [{ name: ":id", value: Integer(session_id) }],
						row: Sql.str("ty"),
					})?
					status = Sql.query!({
						path: Path.utf8(path),
						query: "SELECT CAST(COALESCE(status, 'open') AS TEXT) AS st FROM planned_sessions WHERE id = :id",
						bindings: [{ name: ":id", value: Integer(session_id) }],
						row: Sql.str("st"),
					})?
					Output.out!({ id: session_id, session_type: stored_type, target_date, status }, |p| "relabeled #${(p.id).to_str()}: ${p.session_type} on ${p.target_date} (${p.status})")
				}
		}
	}
	# ── event targets (ADR 0010's projection side) ─────────────────────────
	# `event add` stores a date the athlete is training toward (judgment tier,
	# REMOVABLE — a target is not a record of training done). `events` projects
	# CTL/ATL/TSB onto each date: the same Metrics.load_step recurrence daily_load
	# runs, folded forward from the last computed row over the OPEN plan's structured
	# targets (Metrics.tss_from_target — deterministic arithmetic, no modeling).
	# Untargeted sessions contribute zero and are COUNTED, so the projection's
	# blindness is data. Whether to change the plan in response stays with the coach:
	# nothing here proposes, ranks, or solves for a plan (ADR 0010's direction rule).
	event_add! : Str, Str => Try({}, _)
	event_add! = |event_date, name| {
		path = Db.open_db!({})?
		today = Db.local_today_days!(path)
		match Metrics.date_str_to_days(event_date) {
			Err(_) => Output.err_out!("bad_date", "event add needs a calendar date written YYYY-MM-DD — got '${event_date}'")
			Ok(ev_days) =>
				if !(Metrics.is_canonical_date(event_date)) {
					Output.err_out!("bad_date", "event add needs a calendar date written YYYY-MM-DD — got '${event_date}'")
				} else if ev_days <= today {
					# a past target has nothing to project. A stored event that AGES
					# past its date renders as "Nd ago — baseline shown"; adding one
					# already-past would be recording a target that never was one
					Output.err_out!("bad_date", "'${event_date}' is not in the future — an event target is a date still ahead")
				} else {
					Sql.execute!({
						path: Path.utf8(path),
						query: "INSERT INTO events (created_at, event_date, name) VALUES (:at, :date, :name)",
						bindings: [
							{ name: ":at", value: String(Metrics.epoch_to_iso(Db.now_secs!({}))) },
							{ name: ":date", value: String(event_date) },
							{ name: ":name", value: String(name) },
						],
					})?
					new_id = Sql.query!({
						path: Path.utf8(path),
						query: "SELECT MAX(id) AS id FROM events",
						bindings: [],
						row: Sql.i64("id"),
					})?
					Output.out!({ id: new_id, event_date, name, days_away: ev_days - today }, |p| "event #${(p.id).to_str()}: ${p.name} on ${p.event_date} (in ${(p.days_away).to_str()} days)")
				}
		}
	}
	event_remove! : Str => Try({}, _)
	event_remove! = |event_id_str| {
		path = Db.open_db!({})?
		match Metrics.arg_i64(event_id_str) {
			Err(_) => Output.err_out!("bad_id", "event remove needs a numeric id: event remove <event_id>")
			Ok(event_id) =>
				if !(Report.row_exists!(path, "events", event_id)?) {
					Output.err_out!("event_not_found", "no event #${(event_id).to_str()} — `stride events` lists them")
				} else {
					Sql.execute!({
						path: Path.utf8(path),
						query: "DELETE FROM events WHERE id = :id",
						bindings: [{ name: ":id", value: Integer(event_id) }],
					})?
					Output.out!({ removed: event_id }, |p| "removed event #${(p.removed).to_str()}")
				}
		}
	}
	# ── projection inputs: what each target kind is priced against ──────────────
	# The projection's floor: the last COMPUTED day. Everything at or before it is
	# measured history; everything after is the recurrence over planned targets.
	# Never analyzed: project pure decay from zero, and SAY so — the flag is the
	# reader's licence to ignore the numbers (ADR 0009).
	projection_base! : Str, I64 => Try({ day : Str, ctl : F64, atl : F64, known : Bool }, _)
	projection_base! = |path, today| {
		base_rows = Sql.query_many!({
			path: Path.utf8(path),
			query: "SELECT COALESCE(CAST(day AS TEXT), '') AS day, CAST(COALESCE(ctl, 0) AS REAL) AS ctl, CAST(COALESCE(atl, 0) AS REAL) AS atl FROM daily_load ORDER BY day DESC LIMIT 1",
			bindings: [],
			rows: |cols| |stmt| {
				day = Sql.str("day")(cols)(stmt)?
				ctl = Sql.f64("ctl")(cols)(stmt)?
				atl = Sql.f64("atl")(cols)(stmt)?
				Ok({ day, ctl, atl })
			},
		})?
		Ok(
			match List.first(base_rows) {
				Ok(b) => { day: b.day, ctl: b.ctl, atl: b.atl, known: True }
				Err(_) => { day: Metrics.days_to_date_str(today), ctl: 0.0, atl: 0.0, known: False }
			},
		)
	}
	# Thresholds as of today, by the derivations the rest of the engine uses: the
	# ride family's FTP (a planned power target is ride power), the athlete's global
	# HR zones (a session's sport is not known until the day), and each pace
	# family's threshold speed. Absent zones are NoZones, which leaves an HR-band
	# target unpriced; an unreadable zone value is the same fault analyze reports.
	projection_inputs! : Str => Try(Metrics.ProjectionInputs, _)
	projection_inputs! = |path| {
		ftp = Db.derive_sport_ftp!(path, "Ride")?
		zones =
			(
				match Analyze.load_zone_config!(path) {
					Ok(zb) => Ok(Zones(zb))
					Err(MissingConfig) => Ok(NoZones)
					Err(other) => Err(other)
				}
			)?
		pace_thresholds = List.map_try!(Sports.pace_target_families, |family| (Db.derive_family_threshold_speed!(path, family)).map_ok(|speed| { family, speed }))?
		Ok({ ftp, zones, pace_thresholds })
	}
	# every open session's date and target, the target read back through
	# stored_target so a row from before schema v42 keeps its power numbers
	open_targets! : Str => Try(List({ date : Str, d : I64, target : Metrics.Target }), _)
	open_targets! = |path| {
		opens = Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT COALESCE(CAST(target_date AS TEXT), '') AS target_date,
				\\       COALESCE(target_reps, 0) AS treps, COALESCE(target_dur_s, 0) AS tdur,
				\\       CAST(COALESCE(target_watts, 0) AS REAL) AS twatts,
				\\       COALESCE(CAST(target_literal AS TEXT), '') AS tlit
				\\FROM planned_sessions WHERE COALESCE(status, 'open') = 'open'
				\\ORDER BY target_date, id
			,
			bindings: [],
			rows: |cols| |stmt| {
				target_date = Sql.str("target_date")(cols)(stmt)?
				treps = Sql.i64("treps")(cols)(stmt)?
				tdur = Sql.i64("tdur")(cols)(stmt)?
				twatts = Sql.f64("twatts")(cols)(stmt)?
				tlit = Sql.str("tlit")(cols)(stmt)?
				Ok({ target_date, treps, tdur, twatts, tlit })
			},
		})?
		Ok(List.keep_oks(opens, |o| (Metrics.date_str_to_days(o.target_date)).map_ok(|d| { date: o.target_date, d, target: Metrics.stored_target(o.tlit, o.treps, o.tdur, o.twatts) })))
	}
	# price each session in a window: the (day, load) pairs the walk folds, and the
	# sessions it could not price with the reason (ADR 0009: unpriced is stated,
	# never a silent zero)
	price_window : List({ date : Str, d : I64, target : Metrics.Target }), Metrics.ProjectionInputs -> { loads : List({ d : I64, tss : F64 }), unprojected : List({ date : Str, target_literal : Str, reason : Str }) }
	price_window = |sessions, inp|
		List.fold(
			sessions,
			{ loads: [], unprojected: [] },
			|acc, s|
				match Metrics.projected_load(s.target, inp) {
					Load(x) => { ..acc, loads: List.append(acc.loads, { d: s.d, tss: x }) }
					Unprojected(r) => { ..acc, unprojected: List.append(acc.unprojected, { date: s.date, target_literal: Metrics.target_literal(s.target), reason: r }) }
				},
		)

	events! : {} => Try({}, _)
	events! = |{}| {
		path = Db.open_db!({})?
		today = Db.local_today_days!(path)
		base = projection_base!(path, today)?
		base_days = (Metrics.date_str_to_days(base.day)).ok_or(today)
		inp = projection_inputs!(path)?
		ftp_known : Bool
		ftp_known = inp.ftp > 0.0
		evs = Sql.query_many!({
			path: Path.utf8(path),
			query: "SELECT id AS id, COALESCE(CAST(event_date AS TEXT), '') AS event_date, COALESCE(CAST(name AS TEXT), '') AS name FROM events ORDER BY event_date, id",
			bindings: [],
			rows: |cols| |stmt| {
				id = Sql.i64("id")(cols)(stmt)?
				event_date = Sql.str("event_date")(cols)(stmt)?
				name = Sql.str("name")(cols)(stmt)?
				Ok({ id, event_date, name })
			},
		})?
		opens = open_targets!(path)?
		projected = List.map(
			evs,
			|ev| {
				ev_days = (Metrics.date_str_to_days(ev.event_date)).ok_or(today)
				in_window = List.keep_if(opens, |o| o.d > base_days and o.d <= ev_days)
				# the shared pure walk: loads materialized first, so the walk is
				# arithmetic over (day, tss) with no per-day re-filtering
				priced = price_window(in_window, inp)
				proj = Metrics.project_walk({ ctl: base.ctl, atl: base.atl }, base_days, ev_days, priced.loads)
				{ id: ev.id, event_date: ev.event_date, name: ev.name, days_away: ev_days - today, ctl: proj.ctl, atl: proj.atl, tsb: proj.tsb, planned_in_window: List.len(in_window), sessions_projected: List.len(priced.loads), unprojected: priced.unprojected }
			},
		)
		Output.out!({ projected_from: base.day, baseline_known: base.known, ftp_known, events: projected }, |p| Render.events_screen(p))
	}

	# ── taper projection (ADR 0010) ────────────────────────────────────────
	# Bare `project <date>` maps the RECORDED open plan to its consequences on that
	# date — the same walk `events` runs, at an arbitrary horizon. With the literal,
	# the walk runs over the CALLER's hypothetical plan INSTEAD: caller input, echoed
	# back in the payload (dates verbatim, targets as parsed canonical fields), never
	# stored, so the recorded plan stays the single source of adherence truth (ADR
	# 0010). Every target kind is priced (projected_load); one the inputs cannot
	# price is listed in `unprojected` with its reason. The direction rule holds
	# whole: plan → consequences only; stride never solves for the plan that reaches
	# a target TSB, even when the caller names one — that inverse is prescription.
	project! : Str, [Recorded, Hypothetical(Str)] => Try({}, _)
	project! = |date_str, mode| {
		path = Db.open_db!({})?
		today = Db.local_today_days!(path)
		match Metrics.date_str_to_days(date_str) {
			Err(_) => Output.err_out!("bad_date", "project needs a calendar date written YYYY-MM-DD — got '${date_str}'")
			Ok(horizon) =>
				if !(Metrics.is_canonical_date(date_str)) {
					Output.err_out!("bad_date", "project needs a calendar date written YYYY-MM-DD — got '${date_str}'")
				} else {
					parsed = match mode {
						Recorded => Ok(Recorded)
						Hypothetical(lit) =>
							match Metrics.parse_plan_literal(lit) {
								Ok(pairs) => Ok(Hypo(pairs))
								Err(PairDate(bad)) => Err(BadDatePart(bad))
								Err(PairTarget(bad)) => Err(BadTargetPart(bad))
							}
					}
					match parsed {
						Err(BadDatePart(bad)) => Output.err_out!("bad_date", "each hypothetical session is <YYYY-MM-DD>=<target> — the date half of '${bad}' does not parse")
						Err(BadTargetPart(bad)) => Output.err_out!("bad_target", "each hypothetical session is <YYYY-MM-DD>=<target>; ${target_grammar(bad)}")
						Ok(plan_mode) => {
							base = projection_base!(path, today)?
							base_days = (Metrics.date_str_to_days(base.day)).ok_or(today)
							inp = projection_inputs!(path)?
							ftp_known : Bool
							ftp_known = inp.ftp > 0.0
							source = match plan_mode {
								Recorded => {
									opens = open_targets!(path)?
									in_w = List.keep_if(opens, |o| o.d > base_days and o.d <= horizon)
									{ in_w, label: "recorded", echo: [] }
								}
								Hypo(pairs) => {
									sessions = List.map(pairs, |p2| { date: p2.date, d: p2.days, target: p2.target })
									in_w = List.keep_if(sessions, |s| s.d > base_days and s.d <= horizon)
									{ in_w, label: "hypothetical", echo: List.map(pairs, |p2| { date: p2.date, target_kind: p2.target.kind, target_literal: Metrics.target_literal(p2.target), reps: p2.target.reps, dur_s: p2.target.dur_s, watts: p2.target.watts }) }
								}
							}
							priced = price_window(source.in_w, inp)
							proj = Metrics.project_walk({ ctl: base.ctl, atl: base.atl }, base_days, horizon, priced.loads)
							Output.out!(
								{
									target_date: date_str,
									days_away: horizon - today,
									projected_from: base.day,
									baseline_known: base.known,
									ftp_known,
									plan_source: source.label,
									ctl: proj.ctl,
									atl: proj.atl,
									tsb: proj.tsb,
									sessions_considered: List.len(source.in_w),
									sessions_projected: List.len(priced.loads),
									unprojected: priced.unprojected,
									hypothetical: source.echo,
								},
								|p| Render.project_screen(p),
							)
						}
					}
				}
		}
	}

	# weekly-planning bundle: everything the coach needs to plan a week, in one call
	plan_bundle! : {} => Try({}, _)
	plan_bundle! = |{}| {
		path = Db.open_db!({})?
		# Same rule as Report.summary!: the bundle's JSON stays SI, and this only reaches
		# the human branch below.
		units = Db.units!(path)?
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
						# `recent_activities_14d` field both promise fourteen.
						cutoff14 = Metrics.days_to_date_str(anchor - 13)
						recent = Sql.query_many!({
							path: Path.utf8(path),
							query: \\SELECT a.id AS id, COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS date, COALESCE(CAST(a.sport_type AS TEXT), '') AS sport, COALESCE(CAST(a.name AS TEXT), '') AS name,
								\\       a.moving_time AS moving_time, CAST(COALESCE(m.tss,0) AS REAL) AS tss,
								\\       CAST(COALESCE(m.intensity_factor,0) AS REAL) AS intensity,
								\\       COALESCE(m.z1_s,0) AS z1_s, COALESCE(m.z2_s,0) AS z2_s, COALESCE(m.z3_s,0) AS z3_s,
								\\       COALESCE(m.z4_s,0) AS z4_s, COALESCE(m.z5_s,0) AS z5_s,
								\\       COALESCE(ai.hard_s, 0) AS hard_s,
								\\       CAST(COALESCE(a.distance,0) AS REAL) AS distance_m,
								\\       CAST(COALESCE(m.normalized_power,0) AS REAL) AS np_w,
								\\       CAST(COALESCE(a.relative_effort,0) AS REAL) AS relative_effort,
								\\       CAST(COALESCE(a.avg_hr,0) AS REAL) AS avg_hr,
								\\       CASE WHEN m.normalized_power IS NULL THEN 0 ELSE 1 END AS power_known,
								\\       CASE WHEN m.intensity_factor IS NULL THEN 0 ELSE 1 END AS intensity_known,
								\\       CASE WHEN a.avg_hr IS NULL THEN 0 ELSE 1 END AS hr_known,
								\\       CASE WHEN COALESCE(m.hr_samples_total, 0) > 0 THEN 1 ELSE 0 END AS zones_known,
								\\       COALESCE(CAST(m.load_model AS TEXT), '') AS load_model
								\\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
								\\LEFT JOIN activity_intensity ai ON ai.activity_id = a.id
								\\WHERE a.start_local >= :cutoff
								\\ORDER BY ${Metrics.rank_ts_sql("a.start_local", Desc)}, a.id DESC
							,
							bindings: [{ name: ":cutoff", value: String(cutoff14) }],
							rows: |cols| |stmt| {
								id = Sql.i64("id")(cols)(stmt)?
								date = Sql.str("date")(cols)(stmt)?
								sport = Sql.str("sport")(cols)(stmt)?
								name = Sql.str("name")(cols)(stmt)?
								moving_time = Sql.i64("moving_time")(cols)(stmt)?
								tss = Sql.f64("tss")(cols)(stmt)?
								intensity = Sql.f64("intensity")(cols)(stmt)?
								z1_s = Sql.i64("z1_s")(cols)(stmt)?
								z2_s = Sql.i64("z2_s")(cols)(stmt)?
								z3_s = Sql.i64("z3_s")(cols)(stmt)?
								z4_s = Sql.i64("z4_s")(cols)(stmt)?
								z5_s = Sql.i64("z5_s")(cols)(stmt)?
								hard_s = Sql.i64("hard_s")(cols)(stmt)?
								distance_m = Sql.f64("distance_m")(cols)(stmt)?

								np_w = Sql.f64("np_w")(cols)(stmt)?

								relative_effort = Sql.f64("relative_effort")(cols)(stmt)?

								avg_hr = Sql.f64("avg_hr")(cols)(stmt)?
								power_known = Sql.i64("power_known")(cols)(stmt)?
								intensity_known = Sql.i64("intensity_known")(cols)(stmt)?
								hr_known = Sql.i64("hr_known")(cols)(stmt)?
								zones_known = Sql.i64("zones_known")(cols)(stmt)?
								load_model = Sql.str("load_model")(cols)(stmt)?
								Ok({ id, date, sport, name, moving_time, tss, load_model, intensity, intensity_known: intensity_known != 0, z1_s, z2_s, z3_s, z4_s, z5_s, zones_known: zones_known != 0, hard_s, distance_m, np_w, power_known: power_known != 0, relative_effort, avg_hr, hr_known: hr_known != 0 })
							},
						})?
						open_p = Sql.query_many!({
							path: Path.utf8(path),
							query: \\SELECT id AS id, COALESCE(CAST(target_date AS TEXT),'') AS target_date, COALESCE(CAST(session_type AS TEXT),'') AS session_type,
								\\       COALESCE(CAST(detail AS TEXT),'') AS detail, COALESCE(CAST(rationale AS TEXT),'') AS rationale,
								\\       COALESCE(target_reps, 0) AS target_reps, COALESCE(target_dur_s, 0) AS target_dur_s,
								\\       CAST(COALESCE(target_watts, 0) AS REAL) AS target_watts,
								\\       COALESCE(CAST(target_literal AS TEXT), '') AS target_literal
								\\FROM planned_sessions WHERE COALESCE(status, 'open') = 'open'
								\\ORDER BY target_date, id
							,
							bindings: [],
							rows: |cols| |stmt| {
								id = Sql.i64("id")(cols)(stmt)?
								target_date = Sql.str("target_date")(cols)(stmt)?
								session_type = Sql.str("session_type")(cols)(stmt)?
								detail = Sql.str("detail")(cols)(stmt)?
								rationale = Sql.str("rationale")(cols)(stmt)?
								reps = Sql.i64("target_reps")(cols)(stmt)?
								dur_s = Sql.i64("target_dur_s")(cols)(stmt)?
								watts = Sql.f64("target_watts")(cols)(stmt)?
								literal = Sql.str("target_literal")(cols)(stmt)?
								t = Metrics.stored_target(literal, reps, dur_s, watts)
								target_known : Bool
								target_known = t.kind != ""
								Ok({ id, target_date, session_type, detail, rationale, target_known, target_kind: t.kind, target_literal: Metrics.target_literal(t), target_reps: t.reps, target_dur_s: t.dur_s, target_dist_m: t.dist_m, target_watts: t.watts, target_hr_lo: t.hr_lo, target_hr_hi: t.hr_hi, target_zone: t.zone, target_pace_s: t.pace_s, target_pace_unit: t.pace_unit, target_rpe: t.rpe })
							},
						})?
						# ── plan history: planned-vs-actual as deterministic memory.
						# EVERY session whose target_date falls in the trailing 28 days, any
						# status — open sessions appear here too (the complete record) AND in
						# open_sessions (the actionable view); the two answer different
						# questions and the id disambiguates. completed_on is the DATE OF THE
						# LINKED ACTIVITY — the fact of when the work happened — not a status-
						# change timestamp stride does not store.
						cutoff28p = Metrics.days_to_date_str(anchor - 27)
						history = Sql.query_many!({
							path: Path.utf8(path),
							query: \\SELECT p.id AS id, COALESCE(CAST(p.target_date AS TEXT),'') AS target_date,
								\\       COALESCE(CAST(p.session_type AS TEXT),'') AS session_type,
								\\       COALESCE(CAST(p.detail AS TEXT),'') AS detail,
								\\       COALESCE(CAST(p.status AS TEXT),'open') AS status,
								\\       COALESCE(CAST(p.skipped_reason AS TEXT),'') AS skipped_reason,
								\\       COALESCE(p.completed_activity_id, 0) AS completed_activity_id,
								\\       COALESCE(p.superseded_activity_id, 0) AS superseded_activity_id,
								\\       COALESCE(p.substitute_activity_id, 0) AS substitute_activity_id,
								\\       COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS completed_on
								\\FROM planned_sessions p
								\\LEFT JOIN activities a ON a.id = COALESCE(p.completed_activity_id, p.substitute_activity_id)
								\\WHERE p.target_date >= :cutoff AND p.target_date <= :today
								\\ORDER BY p.target_date, p.id
							,
							bindings: [{ name: ":cutoff", value: String(cutoff28p) }, { name: ":today", value: String(s.as_of) }],
							rows: |cols| |stmt| {
								id = Sql.i64("id")(cols)(stmt)?
								target_date = Sql.str("target_date")(cols)(stmt)?
								session_type = Sql.str("session_type")(cols)(stmt)?
								detail = Sql.str("detail")(cols)(stmt)?
								status = Sql.str("status")(cols)(stmt)?
								skipped_reason = Sql.str("skipped_reason")(cols)(stmt)?
								completed_activity_id = Sql.i64("completed_activity_id")(cols)(stmt)?
								superseded_activity_id = Sql.i64("superseded_activity_id")(cols)(stmt)?
								substitute_activity_id = Sql.i64("substitute_activity_id")(cols)(stmt)?
								completed_on = Sql.str("completed_on")(cols)(stmt)?
								Ok({ id, target_date, session_type, detail, status, skipped_reason, completed_activity_id, superseded_activity_id, substitute_activity_id, completed_on })
							},
						})?
						# counts the coach should not re-derive: raw integers only (
						# completion_pct: 75 is data; any word about it is the coach's job).
						# substituted counts skipped sessions carrying a substitute link, so
						# skipped is the SUPERSET; unplanned = window activities NO session
						# references by EITHER link, live or tombstoned — deliberately
						# STRICTER than week's display rule, which re-classifies a ride
						# whose skip tombstone was superseded as unplanned: for adherence
						# that would double-count one ride as both substituted and
						# unplanned. Counted once here, as the substitution it was.
						#
						# rested: open REST rows whose date passed with under 1.0 load on the
						# day — rest is the one type whose prescription is the absence of
						# evidence, so these are debt the athlete does not owe. They
						# leave still_open (planned = completed + skipped + rested +
						# still_open) and completion_pct's denominator; the rows themselves
						# stay open — the reframe is read-time only. One predicate string
						# serves both columns so they cannot drift apart. A rest day WITH
						# load fails the predicate and stays in still_open: training through
						# a rest day is a deviation adherence must keep visible.
						#
						# The EXISTS clause separates a measured zero from an absent row: a
						# day daily_load has not covered is unknown, not rested. Inside this
						# query it is defence in depth — :today is s.as_of, the last day the
						# load series covers, so every date the window admits has a row —
						# but the predicate should not owe its soundness to that alignment.
						rested_sql = "COALESCE(status,'open') = 'open' AND session_type = 'rest' AND target_date < :today AND EXISTS (SELECT 1 FROM daily_load dl WHERE dl.day = planned_sessions.target_date) AND COALESCE((SELECT dl.tss FROM daily_load dl WHERE dl.day = planned_sessions.target_date), 0) < 1.0"
						adh = Sql.query!({
							path: Path.utf8(path),
							query: \\SELECT COALESCE(SUM(1),0) AS planned,
								\\       COALESCE(SUM(CASE WHEN COALESCE(status,'open') = 'done' THEN 1 ELSE 0 END),0) AS completed,
								\\       COALESCE(SUM(CASE WHEN COALESCE(status,'open') = 'skipped' THEN 1 ELSE 0 END),0) AS skipped,
								\\       COALESCE(SUM(CASE WHEN COALESCE(status,'open') = 'skipped' AND substitute_activity_id IS NOT NULL THEN 1 ELSE 0 END),0) AS substituted,
								\\       COALESCE(SUM(CASE WHEN COALESCE(status,'open') = 'open' AND NOT (${rested_sql}) THEN 1 ELSE 0 END),0) AS still_open,
								\\       COALESCE(SUM(CASE WHEN ${rested_sql} THEN 1 ELSE 0 END),0) AS rested
								\\FROM planned_sessions
								\\WHERE target_date >= :cutoff AND target_date <= :today
							,
							bindings: [{ name: ":cutoff", value: String(cutoff28p) }, { name: ":today", value: String(s.as_of) }],
							row: |cols| |stmt| {
								planned = Sql.i64("planned")(cols)(stmt)?
								completed = Sql.i64("completed")(cols)(stmt)?
								skipped = Sql.i64("skipped")(cols)(stmt)?
								substituted = Sql.i64("substituted")(cols)(stmt)?
								still_open = Sql.i64("still_open")(cols)(stmt)?
								rested = Sql.i64("rested")(cols)(stmt)?
								Ok({ planned, completed, skipped, substituted, still_open, rested })
							},
						})?
						unplanned_n = Sql.query!({
							path: Path.utf8(path),
							query: \\SELECT COUNT(*) AS n FROM activities a
								\\WHERE substr(a.start_local, 1, 10) >= :cutoff AND substr(a.start_local, 1, 10) <= :today
								\\  AND a.id NOT IN (SELECT completed_activity_id FROM planned_sessions WHERE completed_activity_id IS NOT NULL)
								\\  AND a.id NOT IN (SELECT substitute_activity_id FROM planned_sessions WHERE substitute_activity_id IS NOT NULL)
							,
							bindings: [{ name: ":cutoff", value: String(cutoff28p) }, { name: ":today", value: String(s.as_of) }],
							row: Sql.i64("n"),
						})?
						# denominator excludes rested: a rest day that passed with no load
						# required no action and got none, so it is neutral to adherence —
						# neither earned nor owed. planned 0 is still the discriminator for
						# the ambiguous 0; a window that is ALL rested also reports 0, which
						# the rested count beside it disambiguates.
						actionable = adh.planned - adh.rested
						completion_pct = if (actionable > 0) (((adh.completed).to_f64() / (actionable).to_f64()) * 100.0).round_to_i64_try().ok_or(0) else 0
						# ── data freshness ────────────────────────────────────────────
						# Without this a coach either spent a turn on `doctor` every time or planned from
						# a week of unsynced rides. Four MEASUREMENTS, no verdict (ADR 0012): what counts
						# as stale depends on the question being asked.
						#
						# awaiting_metrics reuses Analyze.pending_metrics_count! — the same pending_where
						# `analyze` selects rows with, so it cannot drift. Never FEWER than doctor's
						# `unanalyzed` (`m.activity_id IS NULL`): a changed FTP, threshold, zones, or a
						# newly arrived stream leaves scored rows due, and this counts them.
						#
						# Not `?`: pending_metrics_count! validates EVERY hr_z* key including per-sport
						# overrides, and propagating would let one unparseable override kill `plan`.
						# Reported as unknown instead — a THIRD `_known` mechanism (an Err from a
						# computation that could not run, meaning BROKEN rather than absent), said
						# plainly so a maintainer does not hunt for the column behind the flag. 0 with
						# known false, never a bare 0 that reads as "nothing to do".
						awaiting : { count : U64, known : Bool }
						awaiting = match Analyze.pending_metrics_count!(path, zb) {
							Ok(n) => { count: n, known: True }
							Err(_) => { count: 0, known: False }
						}
						awaiting_metrics = awaiting.count
						awaiting_streams = Strava.pending_streams!(path)?
						missing_sets = Report.strength_without_sets_ids!(path)?
						# Date only, lining up with summary.as_of — but mind what the gap measures:
						# rebuild_daily_load! floors the series at local today, so as_of is pinned to the
						# day analyze LAST RAN. The gap is last-activity-to-last-analyze and simply stops
						# growing on a stale install, so
						# last_sync against the real clock is the primary signal and this the secondary.
						# "" when there are no activities.
						newest_activity = Sql.query!({
							path: Path.utf8(path),
							query: "SELECT COALESCE(MAX(substr(CAST(start_local AS TEXT), 1, 10)), '') AS d FROM activities",
							bindings: [],
							row: Sql.str("d"),
						})?
						# UTC ISO rather than the raw epoch it is stored as. Note this is the
						# payload's only full timestamp and its only UTC value — every other date
						# here is a bare local YYYY-MM-DD. Deliberately not claiming they all come
						# from start_local: as_of is written by the day-walk from the clock, and
						# target_date is typed by the user through `week add`.
						#
						# "" when sync has never run, which is itself the answer on a fresh install.
						last_sync =
							match Db.config_opt!(path, "last_sync_epoch")? {
								NotFound => ""
								Found(raw) =>
									match Metrics.arg_i64(raw) {
										# Negatives are rejected rather than formatted: arg_i64 accepts them, and
										# epoch_to_iso's `% 86400` then yields "1970-01-01T00:00:0-1Z" — a confident fake
										# timestamp, worse than saying nothing (pinned by an expect on epoch_to_iso).
										# Clamping the stamp itself would assert "synced at the epoch"; unknown is the
										# honest bucket.
										Ok(e) => if (e >= 0) Metrics.epoch_to_iso(e) else ""
										# A corrupt value is not a freshness signal, and a planning
										# read should not die on a key it only wants for display.
										# `sync` is the command that DOES fail on it
										# (UnreadableConfig, Strava.roc) — that divergence is
										# deliberate. `doctor` does not report it at all.
										Err(_) => ""
									}
							}
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
									# open rest rows whose date passed with no load — resolved
									# in fact, excluded from still_open and from the pct
									# denominator; the stored rows stay open
									rested: adh.rested,
									# completed over (planned - rested); 0 with planned 0 —
									# planned is the discriminator, per the ambiguous-zero rule
									completion_pct,
									unplanned_activities: unplanned_n,
								},
								data_freshness: {
									newest_activity,
									last_sync,
									activities_awaiting_metrics: awaiting_metrics,
									# false when the count could not be computed at all, so a
									# consumer never reads an unknowable 0 as "nothing to do"
									activities_awaiting_metrics_known: awaiting.known,
									activities_awaiting_streams: awaiting_streams,
									# strength-family sessions with no stored sets, newest first:
									# the ids to hand `stride strength import`
									strength_without_sets_ids: missing_sets,
								},
							})
						} else {
							Stdout.line!(Render.summary_screen(units, s))?
							Stdout.line!("")?
							# "" when nothing is outstanding, so this prints nothing on a current
							# database rather than a row of zeros before every planning session.
							fresh_line = Render.freshness_note({
								activities_awaiting_metrics: awaiting_metrics,
								activities_awaiting_metrics_known: awaiting.known,
								activities_awaiting_streams: awaiting_streams,
							})
							if fresh_line != "" {
								Stdout.line!(fresh_line)?
								Stdout.line!("")?
							}
							if !(List.is_empty(missing_sets)) {
								Stdout.line!("STRENGTH: ${U64.to_str(List.len(missing_sets))} recent sessions have no sets (stride doctor lists them)")?
								Stdout.line!("")?
							}
							# one descriptive line of plan memory — raw counts only
							Stdout.line!("28d PLAN: ${I64.to_str(adh.planned)} planned · ${I64.to_str(adh.completed)} done · ${I64.to_str(adh.skipped)} skipped (${I64.to_str(adh.substituted)} substituted) · ${I64.to_str(unplanned_n)} unplanned activities")?
							Stdout.line!("")?
							Stdout.line!("OPEN PLAN")?
							Stdout.line!(
								Render.render_table(
									["id", "date", "type", "detail"],
									List.map(open_p, |p| [(p.id).to_str(), p.target_date, p.session_type, p.detail]),
								),
							)?
							Stdout.line!("")?
							Stdout.line!("RECENT 14 DAYS")?
							# This table is a DATE RANGE, so a day with nothing on it is information: a rest
							# day, planned or not. Human table only — the JSON stays a list of real
							# activities and never gains pseudo-rows with no id.
							# 14 DAYS, not 14 rows: a day with two activities contributes two, and the walk
							# and the query must span the same days. Week boundaries get a full-width rule,
							# falling just ABOVE each Sunday (newest-first), never above the first row.
							recent_headers = ["date", "sport", "name", "time", "load", "hard"]
							# A full-width horizontal rule, drawn by render_table in the table's own
							# border glyphs so it lines up with the header rule. It must not be a
							# glyph in every cell: `progress` uses `···` to mean a GAP in time, so
							# reusing it here made a boundary between two CONSECUTIVE days read as
							# missing days.
							week_div = Render.rule
							recent_display = List.join(
								List.map(
									Render.indices(14),
									|i| {
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
												[
													List.map(
														recent_headers,
														|h|
															if h == "date" {
																ds
															} else if h == "name" {
																"(no activity)"
															} else {
																"-"
															},
													),
												]
											} else {
												List.map(on_day, |a| [a.date, a.sport, a.name, Render.mins(a.moving_time), Render.fmt0(a.tss), Render.mins(a.hard_s)])
											}
										if i > 0 and Metrics.day_of_week(d) == "Sun" {
											List.prepend(day_rows, week_div)
										} else {
											day_rows
										}
									},
								),
							)
							Stdout.line!(Render.render_table(recent_headers, recent_display))
						}
					}
				}
		}
	}

}
