import Db
import Output
import Plan
import Report
import Sql
import pf.Path
import Metrics
import Render
import core.Sports

# ── the weekly review (#640) ────────────────────────────────────────────
#
# One Mon-Sun week in one payload: what was planned and how each session went,
# what was done without a plan, planned load beside actual load per day, the
# intensity split, a row per sport family present, strength bookkeeping, and
# fitness at both ends. It composes the definitions other commands already
# publish rather than restating them: execution is Plan.target_match! (what
# `complete` reports), planned load is Metrics.projected_load under the same
# inputs `project` prices with, intensity reads the activity_intensity view, a
# hard day is one holding a session with 5+ hard minutes (summary's rule), and
# an unclaimed activity is Plan.unclaimed_sql (what `week` lists as unlinked).
# Measurements only (ADR 0012): whether the week went well is the coach's call.
ReportReview :: [].{
	review! : Str => Try({}, _)
	review! = |date_str| {
		path = Db.open_db!({})?
		today = Db.local_today_days!(path)
		anchor =
			if date_str == "" {
				Ok(today)
			} else {
				(Metrics.date_str_to_days(date_str)).map_err(|_| BadDate)
			}
		match anchor {
			Err(_) => Output.err_out!("bad_date", "review takes a calendar date written YYYY-MM-DD, or `week` for this week — got '${date_str}'")
			Ok(day) => {
				# activity dates feed every window below; refuse an unreadable one by
				# name rather than letting it fall out of a filter
				_ = Report.guard_activity_dates!(path)?
				payload = review_payload!(path, Metrics.week_monday(day), today)?
				Output.out!(payload, |p| review_screen(p))
			}
		}
	}

	review_payload! = |path, mon, today| {
		sun = mon + 6
		mon_s = Metrics.days_to_date_str(mon)
		next_s = Metrics.days_to_date_str(mon + 7)
		inp = Plan.projection_inputs!(path)?
		sessions_raw = Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT id AS id, COALESCE(CAST(target_date AS TEXT),'') AS target_date,
				\\       COALESCE(CAST(session_type AS TEXT),'') AS session_type, COALESCE(CAST(detail AS TEXT),'') AS detail,
				\\       COALESCE(CAST(status AS TEXT),'open') AS status, COALESCE(CAST(skipped_reason AS TEXT),'') AS skipped_reason,
				\\       COALESCE(completed_activity_id,0) AS completed_activity_id, COALESCE(substitute_activity_id,0) AS substitute_activity_id,
				\\       COALESCE(target_reps, 0) AS target_reps, COALESCE(target_dur_s, 0) AS target_dur_s, CAST(COALESCE(target_watts, 0) AS REAL) AS target_watts,
				\\       COALESCE(CAST(target_literal AS TEXT), '') AS target_literal
				\\FROM planned_sessions
				\\WHERE target_date >= :mon AND target_date < :next AND id IN (SELECT id FROM plan_current)
				\\ORDER BY target_date, id
			,
			bindings: [{ name: ":mon", value: String(mon_s) }, { name: ":next", value: String(next_s) }],
			rows: |cols| |stmt| {
				id = Sql.i64("id")(cols)(stmt)?
				target_date = Sql.str("target_date")(cols)(stmt)?
				session_type = Sql.str("session_type")(cols)(stmt)?
				detail = Sql.str("detail")(cols)(stmt)?
				status = Sql.str("status")(cols)(stmt)?
				skipped_reason = Sql.str("skipped_reason")(cols)(stmt)?
				completed_activity_id = Sql.i64("completed_activity_id")(cols)(stmt)?
				substitute_activity_id = Sql.i64("substitute_activity_id")(cols)(stmt)?
				treps = Sql.i64("target_reps")(cols)(stmt)?
				tdur = Sql.i64("target_dur_s")(cols)(stmt)?
				twatts = Sql.f64("target_watts")(cols)(stmt)?
				tlit = Sql.str("target_literal")(cols)(stmt)?
				Ok({ id, target_date, session_type, detail, status, skipped_reason, completed_activity_id, substitute_activity_id, target: Metrics.stored_target(tlit, treps, tdur, twatts) })
			},
		})?
		sessions = List.map_try!(
			sessions_raw,
			|s| {
				m = Plan.target_match!(path, s.id, s.completed_activity_id)?
				# a session with no linked activity has no execution to measure, whatever
				# its target; `not_done` says so instead of a stream-absence reason
				execution = if (s.completed_activity_id == 0) { ..m, exec_known: Bool.False, exec_reason: "not_done" } else m
				priced = Metrics.projected_load(s.target, inp)
				planned_load_known : Bool
				planned_load_known = match priced {
					Load(_) => True
					Unprojected(_) => False
				}
				Ok({
					id: s.id,
					target_date: s.target_date,
					session_type: s.session_type,
					detail: s.detail,
					status: s.status,
					skipped_reason: s.skipped_reason,
					completed_activity_id: s.completed_activity_id,
					substitute_activity_id: s.substitute_activity_id,
					planned_load: match priced {
						Load(x) => x
						Unprojected(_) => 0.0
					},
					planned_load_known,
					unprojected_reason: match priced {
						Load(_) => ""
						Unprojected(r) => r
					},
					execution,
				})
			},
		)?
		acts = Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT a.id AS aid, COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS adate,
				\\       COALESCE(CAST(a.sport_type AS TEXT),'') AS sport, COALESCE(CAST(a.sport_family AS TEXT),'') AS fam,
				\\       COALESCE(CAST(a.name AS TEXT),'') AS aname, COALESCE(a.moving_time,0) AS mt,
				\\       CAST(COALESCE(m.tss,0) AS REAL) AS tss, COALESCE(CAST(m.load_model AS TEXT),'') AS lm,
				\\       CASE WHEN EXISTS (SELECT 1 FROM strength_sets ss WHERE ss.activity_id = a.id) THEN 1 ELSE 0 END AS has_sets,
				\\       CASE WHEN EXISTS (SELECT 1 FROM ratings r WHERE r.activity_id = a.id) THEN 1 ELSE 0 END AS rated,
				\\       CASE WHEN ${Plan.unclaimed_sql} THEN 1 ELSE 0 END AS unclaimed,
				\\       COALESCE(ai.polarized, 0) AS pol, COALESCE(ai.easy_s, 0) AS es, COALESCE(ai.moderate_s, 0) AS ms, COALESCE(ai.hard_s, 0) AS hs
				\\FROM activities a
				\\LEFT JOIN activity_metrics m ON m.activity_id = a.id
				\\LEFT JOIN activity_intensity ai ON ai.activity_id = a.id
				\\WHERE a.start_local >= :mon AND a.start_local < :next
				\\ORDER BY ${Metrics.rank_ts_sql("a.start_local", Asc)}, a.id
			,
			bindings: [{ name: ":mon", value: String(mon_s) }, { name: ":next", value: String(next_s) }],
			rows: |cols| |stmt| {
				aid = Sql.i64("aid")(cols)(stmt)?
				adate = Sql.str("adate")(cols)(stmt)?
				sport = Sql.str("sport")(cols)(stmt)?
				fam = Sql.str("fam")(cols)(stmt)?
				aname = Sql.str("aname")(cols)(stmt)?
				mt = Sql.i64("mt")(cols)(stmt)?
				tss = Sql.f64("tss")(cols)(stmt)?
				lm = Sql.str("lm")(cols)(stmt)?
				has_sets = Sql.i64("has_sets")(cols)(stmt)?
				rated = Sql.i64("rated")(cols)(stmt)?
				unclaimed = Sql.i64("unclaimed")(cols)(stmt)?
				pol = Sql.i64("pol")(cols)(stmt)?
				es = Sql.i64("es")(cols)(stmt)?
				ms = Sql.i64("ms")(cols)(stmt)?
				hs = Sql.i64("hs")(cols)(stmt)?
				Ok({ aid, adate, sport, fam, aname, mt, tss, lm, has_sets, rated, unclaimed, pol, es, ms, hs })
			},
		})?
		unplanned = List.map(
			List.keep_if(acts, |a| a.unclaimed == 1),
			|a| { activity_id: a.aid, date: a.adate, sport: a.sport, name: a.aname, moving_time: a.mt, load: a.tss, load_model: a.lm },
		)
		day_rows = Sql.query_many!({
			path: Path.utf8(path),
			query: "SELECT COALESCE(CAST(day AS TEXT), '') AS day, CAST(COALESCE(tss, 0) AS REAL) AS tss FROM daily_load WHERE day >= :mon AND day < :next ORDER BY day",
			bindings: [{ name: ":mon", value: String(mon_s) }, { name: ":next", value: String(next_s) }],
			rows: |cols| |stmt| {
				day = Sql.str("day")(cols)(stmt)?
				tss = Sql.f64("tss")(cols)(stmt)?
				Ok({ day, tss })
			},
		})?
		priced = List.keep_oks(
			sessions,
			|s| if (s.planned_load_known) (Metrics.date_str_to_days(s.target_date)).map_ok(|d| { d, load: s.planned_load }) else Err(Unpriced),
		)
		planned_by_day = Metrics.week_day_loads(mon, priced)
		days = List.map_with_index(
			planned_by_day,
			|planned, i| {
				ds = Metrics.days_to_date_str(mon + i.to_i64_wrap())
				actual = List.first(List.keep_if(day_rows, |r| r.day == ds))
				actual_known : Bool
				actual_known = actual.is_ok()
				{ day: ds, planned_load: planned, actual_load: (actual.map_ok(|r| r.tss)).ok_or(0.0), actual_known }
			},
		)
		easy = List.fold(acts, 0, |acc, a| if (a.pol == 1) acc + a.es else acc)
		moderate = List.fold(acts, 0, |acc, a| if (a.pol == 1) acc + a.ms else acc)
		hard = List.fold(acts, 0, |acc, a| if (a.pol == 1) acc + a.hs else acc)
		total = easy + moderate + hard
		polarization_known : Bool
		polarization_known = total > 0
		hard_day_strs = List.fold(acts, [], |acc, a| if (a.hs >= 300 and !(List.contains(acc, a.adate))) List.append(acc, a.adate) else acc)
		spacing = Metrics.median_gap_days(List.keep_oks(hard_day_strs, |d| Metrics.date_str_to_days(d)))
		spacing_known : Bool
		spacing_known = match spacing {
			Known(_) => True
			Unknown => False
		}
		sports = Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT COALESCE(CAST(a.sport_family AS TEXT),'') AS fam, COUNT(*) AS n, COALESCE(SUM(a.moving_time),0) AS mt,
				\\       CAST(COALESCE(SUM(a.distance),0) AS REAL) AS dist, CAST(COALESCE(SUM(m.tss),0) AS REAL) AS tss
				\\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
				\\WHERE a.start_local >= :mon AND a.start_local < :next
				\\GROUP BY fam ORDER BY n DESC, fam
			,
			bindings: [{ name: ":mon", value: String(mon_s) }, { name: ":next", value: String(next_s) }],
			rows: |cols| |stmt| {
				fam = Sql.str("fam")(cols)(stmt)?
				n = Sql.i64("n")(cols)(stmt)?
				mt = Sql.i64("mt")(cols)(stmt)?
				dist = Sql.f64("dist")(cols)(stmt)?
				tss = Sql.f64("tss")(cols)(stmt)?
				Ok({ family: fam, sessions: n, moving_time: mt, distance_m: dist, load: tss })
			},
		})?
		strength_fam = (List.first(Sports.family("strength"))).ok_or("")
		lifts = List.keep_if(acts, |a| a.fam == strength_fam)
		at! = |d, floor|
			Sql.query_many!({
				path: Path.utf8(path),
				query: "SELECT COALESCE(CAST(day AS TEXT), '') AS day, CAST(COALESCE(ctl, 0) AS REAL) AS ctl, CAST(COALESCE(atl, 0) AS REAL) AS atl, CAST(COALESCE(tsb, 0) AS REAL) AS tsb FROM daily_load WHERE day <= :d AND day >= :floor ORDER BY day DESC LIMIT 1",
				bindings: [{ name: ":d", value: String(Metrics.days_to_date_str(d)) }, { name: ":floor", value: String(floor) }],
				rows: |cols| |stmt| {
					day = Sql.str("day")(cols)(stmt)?
					ctl = Sql.f64("ctl")(cols)(stmt)?
					atl = Sql.f64("atl")(cols)(stmt)?
					tsb = Sql.f64("tsb")(cols)(stmt)?
					Ok({ day, ctl, atl, tsb })
				},
			})
		point = |rows, d| {
			known : Bool
			known = !(List.is_empty(rows))
			r = List.first(rows).ok_or({ day: Metrics.days_to_date_str(d), ctl: 0.0, atl: 0.0, tsb: 0.0 })
			{ day: r.day, ctl: r.ctl, atl: r.atl, tsb: r.tsb, known }
		}
		# Fitness at both ends of the week. The start is the daily_load row for the
		# Sunday before, the load carried into Monday; a week analyze has not reached
		# has none. The end is the latest row inside the week up to its last day
		# already lived: Sunday, or today in a week still running. `day` names the
		# row read, which trails today until analyze has run.
		end_day = if (today < sun) today else sun
		start_rows = at!(mon - 1, Metrics.days_to_date_str(mon - 1))?
		end_rows = at!(end_day, mon_s)?
		in_progress : Bool
		in_progress = Metrics.week_in_progress(today, mon, sun)
		Ok({
			week_start: mon_s,
			week_end: Metrics.days_to_date_str(sun),
			in_progress,
			sessions,
			unplanned,
			days,
			load: {
				planned_total: List.sum(planned_by_day),
				actual_total: List.fold(days, 0.0, |acc, d| if (d.actual_known) acc + d.actual_load else acc),
				sessions_planned: List.len(sessions).to_i64_wrap(),
				sessions_priced: List.len(priced).to_i64_wrap(),
			},
			intensity: {
				easy_s: easy,
				moderate_s: moderate,
				hard_s: hard,
				easy_pct: Report.pct_num(easy, total),
				moderate_pct: Report.pct_num(moderate, total),
				hard_pct: Report.pct_num(hard, total),
				polarization_known,
				hard_days: hard_day_strs,
				hard_spacing_median_days: match spacing {
					Known(n) => n
					Unknown => 0
				},
				hard_spacing_known: spacing_known,
			},
			sports,
			strength: {
				sessions: List.len(lifts).to_i64_wrap(),
				with_sets: List.len(List.keep_if(lifts, |a| a.has_sets == 1)).to_i64_wrap(),
				without_sets: List.len(List.keep_if(lifts, |a| a.has_sets == 0)).to_i64_wrap(),
				awaiting_rating: List.len(List.keep_if(acts, |a| Sports.class(a.sport) == StrengthLike and a.rated == 0)).to_i64_wrap(),
			},
			fitness: { start: point(start_rows, mon - 1), end: point(end_rows, end_day) },
		})
	}

	review_screen = |p| {
		head = "week ${p.week_start} .. ${p.week_end}${if (p.in_progress) " (in progress)" else ""}"
		session_lines = List.map(
			p.sessions,
			|s| {
				tgt = if (s.execution.target_literal == "") "" else "  ${s.execution.target_literal}"
				load = if (s.planned_load_known) "  plan ${Render.fmt0(s.planned_load)}" else ""
				"  ${s.target_date} ${Str.with_ascii_lowercased(s.session_type)} — ${s.status}${tgt}${load}"
			},
		)
		unplanned_lines = List.map(p.unplanned, |u| "  ${u.date} ${u.sport} — unlinked, ${Render.fmt0(u.load)} load")
		sport_lines = List.map(p.sports, |s| "  ${s.family}: ${(s.sessions).to_str()} sessions, ${Render.mins(s.moving_time)}, ${Render.fmt0(s.load)} load")
		intensity =
			if p.intensity.polarization_known {
				"intensity  easy ${(p.intensity.easy_pct).to_str()}%  moderate ${(p.intensity.moderate_pct).to_str()}%  hard ${(p.intensity.hard_pct).to_str()}%"
			} else {
				"intensity  - (no zone data in the week)"
			}
		fit = |f| if (f.known) "fitness ${Render.fmt0(f.ctl)} fatigue ${Render.fmt0(f.atl)} form ${Render.fmt0(f.tsb)} (${f.day})" else "-"
		lines = List.join([
			[head, "", "sessions"],
			if (List.is_empty(session_lines)) ["  none planned"] else session_lines,
			unplanned_lines,
			["", "load  planned ${Render.fmt0(p.load.planned_total)} (${(p.load.sessions_priced).to_str()} of ${(p.load.sessions_planned).to_str()} priced)  actual ${Render.fmt0(p.load.actual_total)}", intensity, "", "sports"],
			if (List.is_empty(sport_lines)) ["  none"] else sport_lines,
			[
				"",
				"strength  ${(p.strength.sessions).to_str()} sessions, ${(p.strength.with_sets).to_str()} with sets, ${(p.strength.awaiting_rating).to_str()} awaiting a rating",
				"start  ${fit(p.fitness.start)}",
				"end    ${fit(p.fitness.end)}",
			],
		])
		Str.join_with(lines, "\n")
	}
}
