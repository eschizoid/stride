import rr.Sqlite
import rr.Cmd

Db :: [].{
	CurvePt : { dur_s : I64, watts : F32 }
	DayLine : { title : Str, stats : Str, extra : Str, zones : List(I64) }

	# the brand atlases carry ASCII; human-authored text (plan details, session
	# names, rationales) arrives with em-dashes, arrows and checkmarks that
	# would render as '?'. One gate maps them to ASCII at load time.
	ascii_safe : Str -> Str
	ascii_safe = |s|
		Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(s, "—", "-"), "–", "-"), "→", "->"), "←", "<-"), "✓", "ok"), "≤", "<="), "≥", ">="), "·", "-")
	Seg : { kind : Str, start_s : I64, dur_s : I64 }
	Fit : { cp : F32, w_prime : F32, r2 : F32, points : F32, ok : Bool }

	Point : { ctl : F32, atl : F32, tsb : F32, tss : F32 }
	# integer tenths -> "41.9" / "-8.9"
	fmt1 : I64 -> Str
	fmt1 = |t| {
		sign = if t < 0 "-" else ""
		a = if t < 0 0 - t else t
		"${sign}${I64.to_str(a // 10)}.${I64.to_str(a % 10)}"
	}

	# F32 -> "41.9", through the same integer-tenths door as fmt1
	# A COUNT, not a magnitude: fmt_f would render 3 bests as "3.0".
	fmt_i : F32 -> Str
	fmt_i = |v| match F32.round_to_i64_try(v) {
		Ok(n) => I64.to_str(n)
		Err(_) => "?"
	}

	fmt_f : F32 -> Str
	fmt_f = |v| match F32.round_to_i64_try(v * 10.0) {
		Ok(t) => fmt1(t)
		Err(_) => "?"
	}

	Loaded : { data : List(Point), days : List(Str), last : { c : I64, a : I64, t : I64 }, err : Str }

	load_series! : Sqlite.Db => Loaded
	load_series! = |db| {
		# day is the engine-written PRIMARY KEY in canonical YYYY-MM-DD; for
		# ISO-8601 text, lexical order IS date order, and the bare column keeps
		# the primary-key index usable — wrapping it in date() would forfeit both.
		# The numeric columns are never NULL on the engine's write path (analyze
		# binds all five on every INSERT OR REPLACE), so a NULL is corruption:
		# the decode fails into the visible error state rather than plotting 0s.
		q = "SELECT CAST(day AS TEXT) AS day, CAST(ROUND(ctl*10) AS INTEGER) AS c10, CAST(ROUND(atl*10) AS INTEGER) AS a10, CAST(ROUND(tsb*10) AS INTEGER) AS t10, CAST(ROUND(tss*10) AS INTEGER) AS s10 FROM (SELECT day, ctl, atl, tsb, tss FROM daily_load ORDER BY day DESC LIMIT 90) ORDER BY day ASC"
		match Sqlite.query!({ db, query: q, bindings: [] }) {
			Err(_) => { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "daily_load query failed - analyzed yet?" }
			Ok(rows) => {
				decoded = List.map_try(rows, |r| {
					d = r.str("day") ? |_| "bad day"
					c = r.i64("c10") ? |_| "bad ctl"
					a = r.i64("a10") ? |_| "bad atl"
					t = r.i64("t10") ? |_| "bad tsb"
					s = r.i64("s10") ? |_| "bad tss"
					Ok({ d, c, a, t, s })
				})
				match decoded {
					Err(why) => { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: why }
					Ok(raw) => {
						data = List.map(raw, |r| { ctl: I64.to_f32(r.c) / 10.0, atl: I64.to_f32(r.a) / 10.0, tsb: I64.to_f32(r.t) / 10.0, tss: I64.to_f32(r.s) / 10.0 })
						days = List.map(raw, |r| r.d)
						last = match List.last(raw) {
							Ok(l) => { c: l.c, a: l.a, t: l.t }
							Err(_) => { c: 0, a: 0, t: 0 }
						}
						{ data, days, last, err: "" }
					}
				}
			}
		}
	}

	Event : { day : Str, name : Str, ahead : I64, err : Str }

	# "today" is the series' own last day (MAX(day) rides the PK index), so the
	# marker and the plot share one clock; the wall clock only answers when
	# daily_load is empty. Stride's time-mode config can shift its current day
	# away from localtime, and daily_load is built against stride's day.
	# days the wall clock is past MAX(day) — 0 when analyze ran today or the
	# table is empty (NULL diff decodes as Err and lands on the 0 default)
	load_stale! : Sqlite.Db => I64
	load_stale! = |db|
		match Sqlite.query!({ db, query: "SELECT CAST(julianday(date('now','localtime')) - julianday(MAX(day)) AS INTEGER) AS st FROM daily_load", bindings: [] }) {
			Err(_) => 0
			Ok(rows) => match List.first(rows) {
				Err(_) => 0
				Ok(r) => match r.i64("st") { Ok(x) => if x > 0 x else 0
					Err(_) => 0 }
			}
		}

	# the most recent PAST event, for the "ridden" tile — same series clock
	Ridden : { day : Str, name : Str, ago : I64, err : Str }
	load_ridden! : Sqlite.Db => Ridden
	load_ridden! = |db|
		match Sqlite.query!({ db, query: "WITH anchor AS (SELECT COALESCE(MAX(day), date('now','localtime')) AS today FROM daily_load) SELECT CAST(event_date AS TEXT) AS event_date, CAST(name AS TEXT) AS name, CAST(julianday(today) - julianday(event_date) AS INTEGER) AS ago FROM events, anchor WHERE event_date < today ORDER BY event_date DESC LIMIT 1", bindings: [] }) {
			Err(_) => { day: "", name: "", ago: -1, err: "events query failed" }
			Ok(rows) => match List.first(rows) {
				# no past event is a normal state, not an error
				Err(_) => { day: "", name: "", ago: -1, err: "" }
				Ok(r) => {
					d = match r.str("event_date") { Ok(x) => x
						Err(_) => "" }
					nm = match r.str("name") { Ok(x) => x
						Err(_) => "" }
					ag = match r.i64("ago") { Ok(x) => x
						Err(_) => -1 }
					# a row that exists but will not decode is corruption — surface it,
					# same rule as load_event!
					if d == "" or nm == "" or ag < 0 {
						{ day: "", name: "", ago: -1, err: "event record unreadable" }
					} else {
						{ day: d, name: nm, ago: ag, err: "" }
					}
				}
			}
		}

	load_event! : Sqlite.Db => Event
	load_event! = |db|
		match Sqlite.query!({ db, query: "WITH anchor AS (SELECT COALESCE(MAX(day), date('now','localtime')) AS today FROM daily_load) SELECT CAST(event_date AS TEXT) AS event_date, CAST(name AS TEXT) AS name, CAST(julianday(event_date) - julianday(today) AS INTEGER) AS ahead FROM events, anchor WHERE event_date >= today ORDER BY event_date ASC LIMIT 1", bindings: [] }) {
			Err(_) => { day: "", name: "", ahead: 0, err: "events query failed" }
			Ok(rows) => match List.first(rows) {
				# no rows is the normal no-upcoming-event state, not an error
				Err(_) => { day: "", name: "", ahead: 0, err: "" }
				Ok(r) => {
					# a row that exists but does not decode is corruption, and the
					# board's rule is that corruption surfaces — same as load_series!
					decoded = match r.str("event_date") {
						Ok(d) => match r.str("name") {
							Ok(nm) => match r.i64("ahead") {
								Ok(ah) => { day: d, name: nm, ahead: ah, err: "" }
								Err(_) => { day: "", name: "", ahead: 0, err: "event record unreadable" }
							}
							Err(_) => { day: "", name: "", ahead: 0, err: "event record unreadable" }
						}
						Err(_) => { day: "", name: "", ahead: 0, err: "event record unreadable" }
					}
					decoded
				}
			}
		}


	# The power-duration curve. POINTS come from the stored per-activity bests
	# (activity_metrics.best_*_w), maxed over the window — CAST(ROUND(..)) because a
	# bare CAST truncates and would draw the whole ladder a watt low.
	load_curve! : Sqlite.Db, I64 => List(CurvePt)
	load_curve! = |db, days| {
		q = "WITH w AS (SELECT m.* FROM activity_metrics m JOIN activities a ON a.id = m.activity_id WHERE a.sport_family = 'Ride' AND a.start_local >= date('now', '-' || :d || ' days')) SELECT 5 AS d, CAST(ROUND(MAX(best_5s_w)) AS INTEGER) AS p FROM w UNION ALL SELECT 15, CAST(ROUND(MAX(best_15s_w)) AS INTEGER) FROM w UNION ALL SELECT 30, CAST(ROUND(MAX(best_30s_w)) AS INTEGER) FROM w UNION ALL SELECT 60, CAST(ROUND(MAX(best_60s_w)) AS INTEGER) FROM w UNION ALL SELECT 300, CAST(ROUND(MAX(best_300s_w)) AS INTEGER) FROM w UNION ALL SELECT 600, CAST(ROUND(MAX(best_600s_w)) AS INTEGER) FROM w UNION ALL SELECT 1200, CAST(ROUND(MAX(best_20min_w)) AS INTEGER) FROM w"
		match Sqlite.query!({ db, query: q, bindings: [{ name: ":d", value: Integer(days) }] }) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(rows, |r| {
					d = r.i64("d") ? |_| "bad d"
					p = r.i64("p") ? |_| "bad p"

					Ok({ dur_s: d, watts: I64.to_f32(p) })
				})
		}
	}

	# The most recent activity that HAS detected work blocks — the only kind this
	# view can say anything about. Its id anchors both loaders below.
	# one line per day: what was actually done, for tooltips and the table.
	# Joined against the series by DAY STRING, so a day with no activity is
	# simply absent and reads as rest.
	load_day_notes! : Sqlite.Db => List({ day : Str, note : Str })
	load_day_notes! = |db|
		match Sqlite.query!({ db, query: "SELECT CAST(substr(start_local, 1, 10) AS TEXT) AS day, CAST(group_concat(name, ' + ') AS TEXT) AS note FROM activities WHERE start_local >= date(COALESCE((SELECT MAX(day) FROM daily_load), date('now', 'localtime')), '-400 days') GROUP BY day", bindings: [] }) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(rows, |r| {
					dy = r.str("day") ? |_| "bad day"
					nt = r.str("note") ? |_| "bad note"
					Ok({ day: dy, note: ascii_safe(nt) })
				})
		}

	# ── the coach-window bus (ADR 0015: pixels for the human, state for the
	# coach, the database as the bus). The window owns these two tables:
	# directives flow coach → window and are consumed on read; focus flows
	# window → coach as a single upserted row. Either side creates the tables,
	# so writes can precede the window's first launch.
	ensure_bus! : Sqlite.Db => {}
	ensure_bus! = |db| {
		# every-second callers take this read-only fast path; the DDL below runs
		# only while the objects are actually missing — IF NOT EXISTS still
		# contends for the schema write lock, a plain sqlite_master read never does
		present = match Sqlite.query!({ db, query: "SELECT count(*) AS c FROM sqlite_master WHERE name IN ('viz_directives', 'viz_focus', 'viz_directives_pending')", bindings: [] }) {
			Err(_) => 0
			Ok(rows) => match List.first(rows) {
				Err(_) => 0
				Ok(r) => match r.i64("c") { Ok(c) => c
					Err(_) => 0 }
			}
		}
		if present == 3 {} else ensure_bus_ddl!(db)
	}

	ensure_bus_ddl! : Sqlite.Db => {}
	ensure_bus_ddl! = |db| {
		_ = Sqlite.execute!({ db, query: "CREATE TABLE IF NOT EXISTS viz_directives (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL DEFAULT (datetime('now')), view INTEGER, range INTEGER, cursor_day TEXT, trace_day TEXT, consumed INTEGER NOT NULL DEFAULT 0)", bindings: [] })
		# the poll runs every second forever: a partial index keeps the
		# pending-lookup flat no matter how much consumed history accrues
		_ = Sqlite.execute!({ db, query: "CREATE INDEX IF NOT EXISTS viz_directives_pending ON viz_directives (id) WHERE consumed = 0", bindings: [] })
		_ = Sqlite.execute!({ db, query: "CREATE TABLE IF NOT EXISTS viz_focus (id INTEGER PRIMARY KEY CHECK (id = 1), updated_at TEXT NOT NULL, view INTEGER NOT NULL, range INTEGER NOT NULL, cursor_day TEXT, trace_day TEXT)", bindings: [] })
		{}
	}

	Directive : { id : I64, view : I64, range : I64, cursor_day : Str, trace_day : Str }

	# newest unconsumed directive, consumed AS READ — a directive the window
	# crashes on is dropped, never replayed against a stale model. -1/"" mean
	# "field not set" (SQL NULL): the coach steers only what it names.
	poll_directive! : Sqlite.Db => [Some(Directive), None]
	poll_directive! = |db| {
		ensure_bus!(db)
		match Sqlite.query!({ db, query: "SELECT id, COALESCE(view, -1) AS v, COALESCE(range, -1) AS rg, CAST(COALESCE(cursor_day, '') AS TEXT) AS cd, CAST(COALESCE(trace_day, '') AS TEXT) AS td FROM viz_directives WHERE consumed = 0 ORDER BY id DESC LIMIT 1", bindings: [] }) {
			Err(_) => None
			Ok(rows) => match List.first(rows) {
				Err(_) => None
				Ok(r) => {
					id = match r.i64("id") { Ok(x) => x
						Err(_) => -1 }
					v = match r.i64("v") { Ok(x) => x
						Err(_) => -1 }
					rg = match r.i64("rg") { Ok(x) => x
						Err(_) => -1 }
					cd = match r.str("cd") { Ok(x) => x
						Err(_) => "" }
					td = match r.str("td") { Ok(x) => x
						Err(_) => "" }
					if id < 0 None
					else {
						_ = Sqlite.execute!({ db, query: "UPDATE viz_directives SET consumed = 1 WHERE id <= :id AND consumed = 0", bindings: [{ name: ":id", value: Integer(id) }] })
						Some({ id, view: v, range: rg, cursor_day: cd, trace_day: td })
					}
				}
			}
		}
	}

	# the window's answer: what the human is looking at, one row, upserted
	write_focus! : Sqlite.Db, { view : I64, range : I64, cursor_day : Str, trace_day : Str } => Try({}, [WriteFailed])
	write_focus! = |db, f| {
		ensure_bus!(db)
		res = Sqlite.execute!({ db, query: "INSERT INTO viz_focus (id, updated_at, view, range, cursor_day, trace_day) VALUES (1, datetime('now'), :v, :rg, NULLIF(:cd, ''), NULLIF(:td, '')) ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, view = excluded.view, range = excluded.range, cursor_day = excluded.cursor_day, trace_day = excluded.trace_day", bindings: [{ name: ":v", value: Integer(f.view) }, { name: ":rg", value: Integer(f.range) }, { name: ":cd", value: String(f.cursor_day) }, { name: ":td", value: String(f.trace_day) }] })
		match res {
			Ok(_) => Ok({})
			Err(_) => Err(WriteFailed)
		}
	}

	# the Monday-aligned CURRENT week's completion count - the progress strip's
	# numerator and denominator (the display ladder below is forward-looking
	# and cannot count done sessions meaningfully)
	load_plan_week! : Sqlite.Db => { done : I64, total : I64 }
	load_plan_week! = |db|
		match Sqlite.query!({ db, query: "WITH anchor AS (SELECT date(date('now', 'localtime'), '-6 days', 'weekday 1') AS mon) SELECT CAST(SUM(CASE WHEN COALESCE(status,'') = 'done' THEN 1 ELSE 0 END) AS INTEGER) AS dn, COUNT(*) AS tot FROM plan_current, anchor WHERE target_date >= mon AND target_date < date(mon, '+7 days')", bindings: [] }) {
			Err(_) => { done: 0, total: 0 }
			Ok(rows) => match List.first(rows) {
				Err(_) => { done: 0, total: 0 }
				Ok(r) => {
					dn = match r.i64("dn") { Ok(x) => x
						Err(_) => 0 }
					tot = match r.i64("tot") { Ok(x) => x
						Err(_) => 0 }
					{ done: dn, total: tot }
				}
			}
		}

	# the prescribed days ahead of the WALL-CLOCK today - prescriptions are
	# calendar items the athlete reads on the real day, so the plan view is
	# the one place the series clock does not rule (PMC reads keep it).
	PlanRow : { day : Str, typ : Str, detail : Str, rationale : Str, done : Bool, skipped : Bool, today : Bool }
	load_plan! : Sqlite.Db => List(PlanRow)
	load_plan! = |db|
		match Sqlite.query!({ db, query: "WITH anchor AS (SELECT date('now', 'localtime') AS today) SELECT CAST(target_date AS TEXT) AS d, CAST(COALESCE(session_type, '') AS TEXT) AS t, CAST(COALESCE(detail, '') AS TEXT) AS dt, CAST(COALESCE(rationale, '') AS TEXT) AS ra, (COALESCE(status, '') = 'done') AS dn, (COALESCE(status, '') = 'skipped') AS sk, (target_date = (SELECT today FROM anchor)) AS td FROM plan_current, anchor WHERE target_date >= (SELECT today FROM anchor) AND target_date <= date((SELECT today FROM anchor), '+6 days') ORDER BY target_date, id", bindings: [] }) {
			Err(_) => []
			Ok(rows) =>
				List.map(rows, |r| match decode_plan_row(r) {
					Ok(row) => row
					Err(_) => { day: "?", typ: "?", detail: "plan record unreadable", rationale: "", done: Bool.False, skipped: Bool.False, today: Bool.False }
				})
		}

	decode_plan_row : Sqlite.Row -> Try(PlanRow, [BadRow])
	decode_plan_row = |r| {
		day = r.str("d") ? |_| BadRow
		typ = r.str("t") ? |_| BadRow
		detail = r.str("dt") ? |_| BadRow
		rationale = r.str("ra") ? |_| BadRow
		dn = r.i64("dn") ? |_| BadRow
		sk = r.i64("sk") ? |_| BadRow
		td = r.i64("td") ? |_| BadRow
		Ok({ day, typ, detail: ascii_safe(detail), rationale: ascii_safe(rationale), done: dn == 1, skipped: sk == 1, today: td == 1 })
	}

	# this week's load beside last week's, MONDAY-ALIGNED to agree with the
	# engine's Metrics.weekly_rollup - the progress strip's two numbers
	load_week_tss! : Sqlite.Db => { this : I64, last : I64 }
	load_week_tss! = |db|
		match Sqlite.query!({ db, query: "WITH anchor AS (SELECT mon FROM week_bounds) SELECT CAST(ROUND(SUM(CASE WHEN day >= mon THEN tss ELSE 0 END)) AS INTEGER) AS tw, CAST(ROUND(SUM(CASE WHEN day >= date(mon, '-7 days') AND day < mon THEN tss ELSE 0 END)) AS INTEGER) AS lw FROM daily_load, anchor", bindings: [] }) {
			Err(_) => { this: 0, last: 0 }
			Ok(rows) => match List.first(rows) {
				Err(_) => { this: 0, last: 0 }
				Ok(r) => {
					tw = match r.i64("tw") { Ok(x) => x
						Err(_) => 0 }
					lw = match r.i64("lw") { Ok(x) => x
						Err(_) => 0 }
					{ this: tw, last: lw }
				}
			}
		}

	# the coach corner: the newest directive (consumed or not), timestamped
	load_bus_note! : Sqlite.Db => Str
	load_bus_note! = |db| {
		ensure_bus!(db)
		match Sqlite.query!({ db, query: "SELECT CAST(strftime('%m-%d %H:%M', created_at, 'localtime') AS TEXT) AS at, CAST(COALESCE(view, -1) AS INTEGER) AS v, CAST(COALESCE(range, -1) AS INTEGER) AS rg, CAST(COALESCE(cursor_day, '') AS TEXT) AS cd FROM viz_directives ORDER BY id DESC LIMIT 1", bindings: [] }) {
			Err(_) => "no directives yet"
			Ok(rows) => match List.first(rows) {
				Err(_) => "no directives yet"
				Ok(r) => {
					at = match r.str("at") { Ok(x) => x
						Err(_) => "" }
					v = match r.i64("v") { Ok(x) => x
						Err(_) => -1 }
					rg = match r.i64("rg") { Ok(x) => x
						Err(_) => -1 }
					cd = match r.str("cd") { Ok(x) => x
						Err(_) => "" }
					vn = if v == 0 "form" else if v == 1 "curve" else if v == 2 "trace" else if v == 3 "table" else if v == 4 "plan" else if v == 5 "heat" else ""
					rgp = if rg > 0 "${I64.to_str(rg)}d" else ""
					joined = Str.join_with(List.keep_if([vn, rgp], |s2| s2 != ""), " / ")
					parts = if joined == "" "steer" else joined
					if cd != "" "${at}  ->  ${parts} @ ${cd}" else "${at}  ->  ${parts}"
				}
			}
		}
	}

	# up to a year of (day, load, weekday) for the heatmap grid, oldest first;
	# %w is 0=Sunday..6=Saturday, the view maps it to Monday-first rows
	HeatDay : { day : Str, tss : I64, dow : I64 }
	load_heat! : Sqlite.Db => List(HeatDay)
	load_heat! = |db|
		match Sqlite.query!({ db, query: "SELECT CAST(day AS TEXT) AS d, CAST(ROUND(COALESCE(tss, 0)) AS INTEGER) AS t, CAST(strftime('%w', day) AS INTEGER) AS w FROM (SELECT day, tss FROM daily_load ORDER BY day DESC LIMIT 366) ORDER BY day ASC", bindings: [] }) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(rows, |r| {
					dy = r.str("d") ? |_| "bad"
					ts = r.i64("t") ? |_| "bad"
					w = r.i64("w") ? |_| "bad"
					Ok({ day: dy, tss: ts, dow: w })
				})
		}

	# every event day - the grid rings the ones inside its historical window
	# (the series ends at MAX(day), so future dates simply never match a cell)
	load_event_days! : Sqlite.Db => List(Str)
	load_event_days! = |db|
		match Sqlite.query!({ db, query: "SELECT DISTINCT CAST(event_date AS TEXT) AS d FROM events", bindings: [] }) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(rows, |r| {
					d = r.str("d") ? |_| "bad"
					Ok(d)
				})
		}

	# a day's note from load_day_notes!, or the honest default
	note_for : List({ day : Str, note : Str }), Str -> Str
	note_for = |notes, dy|
		List.fold(notes, "rest day", |acc, x| if x.day == dy x.note else acc)

	# one day's full story for the detail panel: each activity with its type,
	# duration, distance and load - pre-formatted lines, coach-legible
	decode_activity_row : Sqlite.Row -> Try(DayLine, [BadRow])
	decode_activity_row = |r| {
		nm = r.str("name") ? |_| BadRow
		sp = r.str("sport") ? |_| BadRow
		secs = r.i64("secs") ? |_| BadRow
		km = r.str("km") ? |_| BadRow
		tss = r.i64("tss") ? |_| BadRow
		np = r.i64("np") ? |_| BadRow
		if100 = r.i64("if100") ? |_| BadRow
		hr = r.i64("hr") ? |_| BadRow
		rpe = r.str("rpe") ? |_| BadRow
		z1 = r.i64("z1") ? |_| BadRow
		z2 = r.i64("z2") ? |_| BadRow
		z3 = r.i64("z3") ? |_| BadRow
		z4 = r.i64("z4") ? |_| BadRow
		z5 = r.i64("z5") ? |_| BadRow
		mins = secs // 60
		stats = if np > 0 "${I64.to_str(mins)}min  ${km}km  ${I64.to_str(tss)} tss  ${I64.to_str(np)}w np" else "${I64.to_str(mins)}min  ${km}km  ${I64.to_str(tss)} tss"
		# if100 is intensity_factor * 100 rounded: 98 -> "IF 0.98", 105 -> "IF 1.05"
		if_frac = if100 % 100
		if_pad = if if_frac < 10 "0${I64.to_str(if_frac)}" else I64.to_str(if_frac)
		p1 = if if100 > 0 "IF ${I64.to_str(if100 // 100)}.${if_pad}" else ""
		p2 = if hr > 0 "${I64.to_str(hr)} bpm avg" else ""
		p3 = if rpe != "0.0" and rpe != "0" "rpe ${rpe}" else "unrated"
		extra = Str.join_with(List.keep_if([p1, p2, p3], |s| s != ""), "   ")
		Ok({ title: ascii_safe("${nm} [${sp}]"), stats, extra, zones: [z1, z2, z3, z4, z5] })
	}

	load_day_detail! : Sqlite.Db, Str => List(DayLine)
	load_day_detail! = |db, day|
		match Sqlite.query!({ db, query: "SELECT CAST(a.name AS TEXT) AS name, CAST(a.sport_type AS TEXT) AS sport, CAST(COALESCE(a.moving_time, 0) AS INTEGER) AS secs, CAST(ROUND(COALESCE(a.distance, 0) / 1000.0, 1) AS TEXT) AS km, CAST(ROUND(COALESCE(m.tss, 0)) AS INTEGER) AS tss, CAST(ROUND(COALESCE(m.normalized_power, 0)) AS INTEGER) AS np, CAST(ROUND(COALESCE(m.intensity_factor, 0) * 100) AS INTEGER) AS if100, CAST(ROUND(COALESCE(a.avg_hr, 0)) AS INTEGER) AS hr, CAST(ROUND(COALESCE(r.rpe, 0), 1) AS TEXT) AS rpe, CAST(COALESCE(m.z1_s, 0) AS INTEGER) AS z1, CAST(COALESCE(m.z2_s, 0) AS INTEGER) AS z2, CAST(COALESCE(m.z3_s, 0) AS INTEGER) AS z3, CAST(COALESCE(m.z4_s, 0) AS INTEGER) AS z4, CAST(COALESCE(m.z5_s, 0) AS INTEGER) AS z5 FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id LEFT JOIN ratings r ON r.activity_id = a.id WHERE a.start_local >= :d AND a.start_local < date(:d, '+1 day') ORDER BY a.start_local", bindings: [{ name: ":d", value: String(day) }] }) {
			Err(_) => [{ title: "detail query failed", stats: "", extra: "", zones: [] }]
			Ok(rows) =>
				if List.is_empty(rows) [{ title: "rest day - no activities", stats: "", extra: "", zones: [] }]
				else
					# corruption surfaces PER ROW: an unreadable activity renders as
					# its own error line while its neighbors still show
					List.map(rows, |r| match decode_activity_row(r) {
						Ok(line) => line
						Err(_) => { title: "activity record unreadable", stats: "", extra: "", zones: [] }
					})
		}

	# the last dozen structured sessions, newest first — the trace picker's menu
	load_trace_ids! : Sqlite.Db => List({ id : I64, day : Str })
	load_trace_ids! = |db|
		match Sqlite.query!({ db, query: "SELECT a.id AS id, CAST(substr(a.start_local, 1, 10) AS TEXT) AS day FROM activity_segments s JOIN activities a ON a.id = s.activity_id WHERE s.kind = 'work' GROUP BY a.id ORDER BY a.start_local DESC LIMIT 12", bindings: [] }) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(rows, |r| {
					i = r.i64("id") ? |_| "bad id"
					d = r.str("day") ? |_| "bad day"
					Ok({ id: i, day: d })
				})
		}

	load_trace_id! : Sqlite.Db => I64
	load_trace_id! = |db|
		match Sqlite.query!({ db, query: "SELECT a.id AS id FROM activity_segments s JOIN activities a ON a.id = s.activity_id WHERE s.kind = 'work' GROUP BY a.id ORDER BY a.start_local DESC LIMIT 1", bindings: [] }) {
			Err(_) => 0
			Ok(rows) => match List.first(rows) {
				Err(_) => 0
				Ok(r) => match r.i64("id") { Ok(v) => v
					Err(_) => 0 }
			}
		}

	# The power trace, DOWNSAMPLED in SQL to ~800 points. A 45-minute ride carries
	# ~2700 samples against ~830 pixels of plot, so drawing them all costs three
	# line segments per pixel and shows nothing more. json_each reads the stored
	# stream directly — SQLite has JSON1, and this platform has no JSON decoder.
	load_trace! : Sqlite.Db, I64 => List(F32)
	load_trace! = |db, aid| {
		# json_each's key column IS the array index for a JSON array, and for an
		# array it is an INTEGER value (objects yield text keys), so MAX(i) and
		# ORDER BY i are numeric — no window function, nothing left unspecified.
		q = "WITH w AS (SELECT json_each.key AS i, CAST(json_each.value AS INTEGER) AS v FROM streams, json_each(json_extract(streams.raw_json,'$.watts.data')) WHERE streams.activity_id = :aid), n AS (SELECT MAX(i)+1 AS c FROM w) SELECT v FROM w, n WHERE i % (MAX(n.c/800,1)) = 0 ORDER BY i"
		match Sqlite.query!({ db, query: q, bindings: [{ name: ":aid", value: Integer(aid) }] }) {
			Err(_) => []
			Ok(rows) => List.keep_oks(rows, |r| {
				v = r.i64("v") ? |_| "bad v"
				Ok(I64.to_f32(v))
			})
		}
	}

	# The detector's blocks for the same activity, in seconds from the start.
	load_segs! : Sqlite.Db, I64 => List(Seg)
	load_segs! = |db, aid| {
		q = "SELECT CAST(kind AS TEXT) AS kind, start_s, dur_s FROM activity_segments WHERE activity_id = :aid ORDER BY ordinal"
		match Sqlite.query!({ db, query: q, bindings: [{ name: ":aid", value: Integer(aid) }] }) {
			Err(_) => []
			Ok(rows) => List.keep_oks(rows, |r| {
				k = r.str("kind") ? |_| "bad kind"
				s = r.i64("start_s") ? |_| "bad start"
				d = r.i64("dur_s") ? |_| "bad dur"
				Ok({ kind: k, start_s: s, dur_s: d })
			})
		}
	}

	# The session's own duration, from the stream's last timestamp. BOTH axes in the
	# trace view divide by this: the segments are in seconds and the trace is a
	# uniform downsample of the same session, so sharing one denominator is what
	# keeps the shading aligned with the line. Deriving it from the SEGMENTS instead
	# would stretch partial coverage across the full width — on the reference
	# activity the two agree to one second in 2700, which is sub-pixel and would have
	# hidden the bug.
	load_dur! : Sqlite.Db, I64 => F32
	load_dur! = |db, aid|
		match Sqlite.query!({ db, query: "SELECT CAST(json_extract(raw_json,'$.time.data[#-1]') AS INTEGER) AS t FROM streams WHERE activity_id = :aid", bindings: [{ name: ":aid", value: Integer(aid) }] }) {
			Err(_) => 1.0
			Ok(rows) => match List.first(rows) {
				Err(_) => 1.0
				Ok(r) => match r.i64("t") { Ok(v) => if v > 0 (I64.to_f32(v)) else 1.0
					Err(_) => 1.0 }
			}
		}

	# CP / W' / r2 come from the ENGINE, not from a second regression here: the fit
	# is Metrics.hyperbolic_fit's job and a copy would drift from it. Each field is
	# extracted independently so JSON key ORDER cannot silently break the parse; an
	# empty field means the shell or the command failed, and the view says so rather
	# than drawing a fit of zeros.
	load_fit! : I64 => Fit
	load_fit! = |days| {
		script = "J=$(stride power-curve ${I64.to_str(days)} Ride --json 2>/dev/null); for k in cp w_prime fit_r2 fit_points; do printf '%s ' \"$(printf '%s' \"$J\" | sed -n \"s/.*\\\"$k\\\":\\([-0-9.eE]*\\).*/\\1/p\" | head -1)\"; done"
		out = match Cmd.run_utf8!(Cmd.with_args(Cmd.new("sh"), ["-c", script])) {
			Ok(o) => Str.trim(o.stdout)
			Err(_) => ""
		}
		parts = Str.split_on(out, " ")
		num = |i| match List.get(parts, i) {
			Ok(s) => match F32.from_str(s) { Ok(v) => v
				Err(_) => -1.0 }
			Err(_) => -1.0
		}
		cp = num(0)
		wp = num(1)
		r2 = num(2)
		fp = num(3)
		{ cp, w_prime: wp, r2, points: fp, ok: cp >= 0.0 and wp >= 0.0 and r2 >= 0.0 and fp >= 0.0 }
	}

	find_idx = |days, target|
		List.fold(
			List.map_with_index(days, |d, i| { day: d, index: i }),
			{ found: Bool.False, idx: 0.U64 },
			|acc, x| if x.day == target ({ found: Bool.True, idx: x.index }) else acc,
		)
}
