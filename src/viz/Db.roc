import core.Bus
import core.Fmt
import core.Series
import core.Sports
import core.Route
import core.Units
import rr.Sqlite
import rr.Cmd
import Geo
import Motion
import Tiles

Db :: [].{
	CurvePt : { dur_s : I64, watts : F32 }
	DayLine : { title : Str, stats : Str, extra : Str, zones : List(I64) }

	# the brand atlases carry ASCII; human-authored text (plan details, session
	# names, rationales) arrives with em-dashes, arrows, checkmarks and
	# ellipses that would render as '?'. One gate maps them to ASCII at load
	# time. The window's OWN literals must not rely on it either: a glyph the
	# atlas lacks draws as '?' wherever it is written, so a literal carries
	# three dots, never the single ellipsis character.
	ascii_safe : Str -> Str
	ascii_safe = |s|
		Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(Str.replace_each(s, "—", "-"), "–", "-"), "→", "->"), "←", "<-"), "✓", "ok"), "≤", "<="), "≥", ">="), "·", "-"), "…", "...")

	# the ellipsis and the em dash are the two glyphs human-authored text
	# carries most often; both map, each to the ASCII a reader expects of it
	expect ascii_safe("wait… — done") == "wait... - done"
	Seg : { kind : Str, start_s : I64, dur_s : I64 }
	Fit : { cp : F32, w_prime : F32, r2 : F32, points : F32, ok : Bool }
	# a marked test in force for the curve's family (ADR 0020): its threshold
	# in the fit's own units (watts, or a speed in m/s), 0 when none is
	TestAnchor : { value : F32, kind : Str, date : Str }

	# what the power tab's top line reads: the window's fit, a marked test
	# in force, and the family's threshold today as the engine scores with
	# it (0: none), with whether that test set it
	CurveInfo : { fit : Fit, test : TestAnchor, thr : F32, from_test : Bool }

	Point : { ctl : F32, atl : F32, tsb : F32, tss : F32 }
	# integer tenths -> "41.9" / "-8.9"; the rule lives in core.Fmt so the CLI
	# and the window cannot drift on the zero-crossing sign
	fmt1 : I64 -> Str
	fmt1 = |t| Fmt.tenths(t)

	# F32 -> "41.9", through the same integer-tenths door as fmt1
	# The window's one rule for a whole number a person reads: thousands
	# grouped with commas (13,201), and a unit, when it has one, one space
	# after the number (447 h). Axis tick labels and dates keep their short
	# forms, and nothing published on the bus or written to a capture's
	# status row passes through here.
	grouped : I64 -> Str
	grouped = |n| {
		# the sign comes off the string, not the number: negating I64.min
		# overflows, its text does not
		txt = I64.to_str(n)
		digits = Str.to_utf8(Str.drop_prefix(txt, "-"))
		len = List.len(digits)
		out = List.join(List.map_with_index(digits, |d, i| if (i > 0 and (len - i) % 3 == 0) [',', d] else [d]))
		"${if (n < 0) "-" else ""}${Str.from_utf8_lossy(out)}"
	}

	num_unit : I64, Str -> Str
	num_unit = |n, unit| "${grouped(n)} ${unit}"

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
		match db.query!(q, []) {
			Err(_) => { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "daily_load query failed - analyzed yet?" }
			Ok(rows) => {
				decoded = List.map_try(
					rows,
					|r| {
						d = r.str("day") ? |_| "bad day"
						c = r.i64("c10") ? |_| "bad ctl"
						a = r.i64("a10") ? |_| "bad atl"
						t = r.i64("t10") ? |_| "bad tsb"
						s = r.i64("s10") ? |_| "bad tss"
						Ok({ d, c, a, t, s })
					},
				)
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
	# days the wall clock is past the series (0 when analyze ran today or the
	# table is empty; the clock view clamps at 0, and a missing row reads 0)
	load_stale! : Sqlite.Db => I64
	load_stale! = |db|
		match db.query!("SELECT stale_days AS st FROM series_clock", []) {
			Err(_) => 0
			Ok(rows) => match List.first(rows) {
				Err(_) => 0
				Ok(r) => match r.i64("st") {
					Ok(x) => if (x > 0) x else 0
					Err(_) => 0
				}
			}
		}

	# the most recent PAST event, for the "ridden" tile — same series clock
	Ridden : { day : Str, name : Str, ago : I64, err : Str }
	load_ridden! : Sqlite.Db => Ridden
	load_ridden! = |db|
		match db.query!("WITH anchor AS (SELECT today FROM series_clock) SELECT CAST(event_date AS TEXT) AS event_date, CAST(name AS TEXT) AS name, CAST(julianday(today) - julianday(event_date) AS INTEGER) AS ago FROM events, anchor WHERE event_date < today ORDER BY event_date DESC LIMIT 1", []) {
			Err(_) => { day: "", name: "", ago: -1, err: "events query failed" }
			Ok(rows) => match List.first(rows) {
				# no past event is a normal state, not an error
				Err(_) => { day: "", name: "", ago: -1, err: "" }
				Ok(r) => {
					d = match r.str("event_date") {
						Ok(x) => x
						Err(_) => ""
					}
					nm = match r.str("name") {
						Ok(x) => x
						Err(_) => ""
					}
					ag = match r.i64("ago") {
						Ok(x) => x
						Err(_) => -1
					}
					# a row that exists but will not decode is corruption — surface it,
					# same rule as load_event!
					if d == "" or nm == "" or ag < 0 {
						{ day: "", name: "", ago: -1, err: "event record unreadable" }
					} else {
						# the gate every drawn human-authored string passes: an
						# em-dash in an event name would render as unmapped glyphs do
						{ day: d, name: ascii_safe(nm), ago: ag, err: "" }
					}
				}
			}
		}

	load_event! : Sqlite.Db => Event
	load_event! = |db|
		match db.query!("WITH anchor AS (SELECT today FROM series_clock) SELECT CAST(event_date AS TEXT) AS event_date, CAST(name AS TEXT) AS name, CAST(julianday(event_date) - julianday(today) AS INTEGER) AS ahead FROM events, anchor WHERE event_date >= today ORDER BY event_date ASC LIMIT 1", []) {
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
								Ok(ah) => { day: d, name: ascii_safe(nm), ahead: ah, err: "" }
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

	# The ladder a curve key reads. A family head reads the power ladder by
	# family, in watts; a pace key reads the speed ladder by exact sport
	# type, in millimetres per second, so both curves travel through the
	# same integer rungs. The view and column names are this module's own
	# literals, so splicing them is safe; the key itself is always bound.
	Ladder : { view : Str, rungs : Str, val : Str, keycol : Str, key : Str }

	ladder_of : Str -> Ladder
	ladder_of = |curve|
		match Bus.curve_key(curve) {
			Pace(sp) => { view: "activity_pace_ladder", rungs: "pace_ladder_rungs", val: "speed * 1000.0", keycol: "sport_type", key: sp }
			Power(fam) => { view: "activity_power_ladder", rungs: "power_ladder_rungs", val: "watts", keycol: "sport_family", key: fam }
		}

	expect ladder_of("pace:Run").view == "activity_pace_ladder" and ladder_of("pace:Run").key == "Run" and ladder_of("pace:Run").keycol == "sport_type"
	expect ladder_of("Rowing").view == "activity_power_ladder" and ladder_of("Rowing").keycol == "sport_family"

	# The curve: the window's best per rung off the key's ladder view, and
	# the same over the window before it, [2N days ago, N days ago), which
	# each row's change is measured from. CAST(ROUND(..)) because a bare CAST
	# truncates and would print the whole row a unit low. A rung with no
	# effort in a window emits no row there, which the view reads as no
	# best. today_mod is the athlete's today as a sqlite modifier
	# (today_mod!), which the windows' days count back from.
	load_curve! : Sqlite.Db, I64, Str, Str => List(CurvePt)
	load_curve! = |db, days, today_mod, curve| {
		lad = ladder_of(curve)
		q = "SELECT secs AS d, CAST(ROUND(MAX(${lad.val})) AS INTEGER) AS p FROM ${lad.view} WHERE ${lad.keycol} = :fam AND start_local >= date('now', '${today_mod}', '-' || :d || ' days') GROUP BY secs ORDER BY secs"
		curve_rows(db.query!(q, [{ name: ":d", value: Integer(days) }, { name: ":fam", value: String(lad.key) }]))
	}

	load_curve_prev! : Sqlite.Db, I64, Str, Str => List(CurvePt)
	load_curve_prev! = |db, days, today_mod, curve| {
		lad = ladder_of(curve)
		q = "SELECT secs AS d, CAST(ROUND(MAX(${lad.val})) AS INTEGER) AS p FROM ${lad.view} WHERE ${lad.keycol} = :fam AND start_local >= date('now', '${today_mod}', '-' || :d2 || ' days') AND start_local < date('now', '${today_mod}', '-' || :d || ' days') GROUP BY secs ORDER BY secs"
		curve_rows(db.query!(q, [{ name: ":d", value: Integer(days) }, { name: ":d2", value: Integer(days * 2) }, { name: ":fam", value: String(lad.key) }]))
	}

	# a curve query's rows as points, the rows it cannot read left out
	curve_rows = |res|
		match res {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						d = r.i64("d") ? |_| BadRow
						p = r.i64("p") ? |_| BadRow
						Ok({ dur_s: d, watts: I64.to_f32(p) })
					},
				)
		}

	# The curves the athlete has data for, most-used first: every family
	# with power on record, then every pace sport with speed on record. A
	# family's or sport's place in its list is its count of ladder rows, so
	# the one trained most leads. Rides are absent from the pace list: a
	# ride's speed follows the terrain, not the effort.
	CurveKeys : { power : List(Str), pace : List(Str) }
	load_curve_keys! : Sqlite.Db => CurveKeys
	load_curve_keys! = |db| {
		read! = |q|
			match db.query!(q, []) {
				Err(_) => []
				Ok(rows) => List.keep_oks(rows, |r| r.str("k"))
			}
		power = read!("SELECT CAST(sport_family AS TEXT) AS k FROM activity_power_ladder WHERE sport_family IS NOT NULL GROUP BY sport_family ORDER BY COUNT(*) DESC, sport_family")
		pace = List.keep_if(read!("SELECT CAST(sport_type AS TEXT) AS k FROM activity_pace_ladder WHERE sport_type IS NOT NULL GROUP BY sport_type ORDER BY COUNT(*) DESC, sport_type"), |s| List.contains(Bus.pace_sport_types, s))
		{ power, pace: List.map(pace, Bus.pace_key) }
	}

	# the family the athlete trained most in the last 90 days, by moving
	# time, among every activity; '' when there is none
	load_top_family! : Sqlite.Db, Str => Str
	load_top_family! = |db, today_mod|
		match db.query!("SELECT CAST(COALESCE(sport_family, sport_type, '') AS TEXT) AS f FROM activities WHERE start_local >= date('now', '${today_mod}', '-90 days') GROUP BY COALESCE(sport_family, sport_type) ORDER BY SUM(COALESCE(moving_time, 0)) DESC LIMIT 1", []) {
			Err(_) => ""
			Ok(rows) => match List.first(rows) {
				Ok(r) => r.str("f") ?? ""
				Err(_) => ""
			}
		}

	# the curve the window opens on: the most-trained family's power curve
	# when it has one, else its most-used pace sport, else the first curve
	# on record of either kind, else the ride power curve (which draws its
	# own empty note)
	default_curve : CurveKeys, Str -> Str
	default_curve = |keys, top|
		if (List.contains(keys.power, top)) top
		else match List.first(List.keep_if(keys.pace, |k| Sports.canonical(Str.drop_prefix(k, Bus.pace_prefix)) == top)) {
			Ok(k) => k
			Err(_) => match List.first(keys.power) {
				Ok(k) => k
				Err(_) => (List.first(keys.pace)).ok_or("Ride")
			}
		}

	expect default_curve({ power: ["Ride", "Rowing"], pace: ["pace:Rowing", "pace:Run"] }, "Rowing") == "Rowing"
	expect default_curve({ power: ["Ride"], pace: ["pace:TrailRun", "pace:Run"] }, "Run") == "pace:TrailRun"
	expect default_curve({ power: [], pace: ["pace:Swim"] }, "WeightTraining") == "pace:Swim"
	expect default_curve({ power: ["Ride"], pace: [] }, "Swim") == "Ride"
	expect default_curve({ power: [], pace: [] }, "") == "Ride"

	# The most recent activity that HAS detected work blocks — the only kind this
	# view can say anything about. Its id anchors both loaders below.
	# one line per day: what was actually done, for tooltips and the table.
	# Joined against the series by DAY STRING, so a day with no activity is
	# simply absent and reads as rest.
	load_day_notes! : Sqlite.Db => List({ day : Str, note : Str })
	load_day_notes! = |db|
		match db.query!("SELECT CAST(substr(start_local, 1, 10) AS TEXT) AS day, CAST(group_concat(name, ' + ') AS TEXT) AS note FROM activities WHERE start_local >= (SELECT date(today, '-400 days') FROM series_clock) GROUP BY day", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						dy = r.str("day") ? |_| "bad day"
						nt = r.str("note") ? |_| "bad note"
						Ok({ day: dy, note: ascii_safe(nt) })
					},
				)
		}

	# ── the coach-window bus (ADR 0015: pixels for the human, state for the
	# coach, the database as the bus). The window owns these two tables:
	# directives flow coach → window and are consumed on read; focus flows
	# window → coach as a single upserted row. Either side creates the tables,
	# so writes can precede the window's first launch.
	ensure_bus! : Sqlite.Db => {}
	ensure_bus! = |db| {
		# every-second callers take this read-only fast path; the DDL runs only
		# while the objects are actually missing — IF NOT EXISTS still contends
		# for the schema write lock, a plain sqlite_master read never does. The
		# sentinel and its target are core.Bus's, beside the statement list
		# they prove ran.
		present = match db.query!(Bus.sentinel_sql, []) {
			Err(_) => 0
			Ok(rows) => match List.first(rows) {
				Err(_) => 0
				Ok(r) => match r.i64("c") {
					Ok(c) => c
					Err(_) => 0
				}
			}
		}
		if (present == Bus.sentinel_present) {} else ensure_bus_ddl!(db)
	}

	# the migration is core.Bus's statement list, executed in order; an ALTER
	# on a column that already exists fails and the _ discards that, by design
	ensure_bus_ddl! : Sqlite.Db => {}
	ensure_bus_ddl! = |db|
		List.for_each!(
			Bus.ddl,
			|q| {
				_ = db.execute!(q, [])
			},
		)

	# the window's half of capability discovery: what an agent may put
	# on the bus is a fact about THIS binary, so this binary states it. The
	# three tables are rewritten wholesale on every model load - they always
	# describe the build that last ran - and the CLI serves them read-only,
	# treating their absence as "the window never ran against this database".
	publish_caps! : Sqlite.Db, List({ id : I64, name : Str }), List({ name : Str, kind : Str, accepts : Str }) => {}
	publish_caps! = |db, views, fields| {
		_ = db.execute!("CREATE TABLE IF NOT EXISTS viz_capabilities (key TEXT PRIMARY KEY, value TEXT NOT NULL)", [])
		_ = db.execute!("BEGIN IMMEDIATE", [])
		_ = db.execute!("CREATE TABLE IF NOT EXISTS viz_views (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", [])
		_ = db.execute!("CREATE TABLE IF NOT EXISTS viz_fields (field TEXT PRIMARY KEY, kind TEXT NOT NULL, accepts TEXT NOT NULL)", [])
		_ = db.execute!("DELETE FROM viz_capabilities", [])
		_ = db.execute!("DELETE FROM viz_views", [])
		_ = db.execute!("DELETE FROM viz_fields", [])
		_ = db.execute!("INSERT INTO viz_capabilities (key, value) VALUES ('protocol', '1'), ('staleness_seconds', '${(stale_secs).to_str()}'), ('focus_staleness_seconds', '${(focus_stale_secs).to_str()}'), ('published_at', datetime('now'))", [])
		List.for_each!(
			views,
			|v| {
				_ = db.execute!("INSERT INTO viz_views (id, name) VALUES (:i, :n)", [{ name: ":i", value: Integer(v.id) }, { name: ":n", value: String(v.name) }])
			},
		)
		List.for_each!(
			fields,
			|f| {
				_ = db.execute!("INSERT INTO viz_fields (field, kind, accepts) VALUES (:f, :k, :a)", [{ name: ":f", value: String(f.name) }, { name: ":k", value: String(f.kind) }, { name: ":a", value: String(f.accepts) }])
			},
		)
		_ = db.execute!("COMMIT", [])
	}

	# the bus's constants are core.Bus's, stated once for both binaries: the
	# window enforces and publishes them, the CLI's headless tick enforces the
	# same, so the published contract cannot drift from either enforcement
	stale_secs : I64
	stale_secs = Bus.stale_secs

	focus_stale_secs : I64
	focus_stale_secs = Bus.focus_stale_secs

	focus_beat_secs : I64
	focus_beat_secs = Bus.focus_beat_secs

	# -1 in an id field and "" in a day field mean "not set" (SQL NULL). An id
	# names one session exactly; a day names whichever session on that day
	# sorts first, and when both are given the id is the one that counts.
	Directive : { id : I64, view : I64, range : I64, cursor_day : Str, trace_day : Str, ghost_day : Str, trace_id : I64, ghost_id : I64, capture : Str, family : Str, short : I64 }

	# the newest fresh unconsumed directive. Rows past the freshness window are
	# consumed as read (marked stale), and rows older than the winner are
	# consumed as superseded — but the WINNING row is left PENDING here, and
	# the frame that applies it writes its terminal outcome through
	# mark_directive!. So a window that crashes between reading a directive and
	# applying it leaves that directive retryable within the freshness window,
	# not dropped. -1/"" mean "field not set" (SQL NULL): the coach steers only
	# what it names.
	poll_directive! : Sqlite.Db => [Some(Directive), None]
	poll_directive! = |db| {
		ensure_bus!(db)
		# a read gates the writes below: a zero-row UPDATE still takes the
		# write lock, and this path runs every second forever
		has_pending = match db.query!(Bus.has_pending_sql, []) {
			Err(_) => Bool.False
			Ok(prows) => match List.first(prows) {
				Err(_) => Bool.False
				Ok(pr) => (
					match pr.i64("e") {
						Ok(e9) => e9
						Err(_) => 0
					}
				) == 1
			}
		}
		if (!has_pending) None
		else {
			# a directive written while no window was open must not seize the one
			# that eventually launches: anything past the freshness window closes
			# as stale, applied by nobody. The SELECT below refuses stale rows
			# independently, so one slipping past this sweep is labeled late but
			# never applied.
			_ = db.execute!(Bus.stale_sweep_sql, [])
			match db.query!(Bus.winner_sql, []) {
				Err(_) => None
				Ok(rows) => match List.first(rows) {
					Err(_) => None
					Ok(r) => {
						id = match r.i64("id") {
							Ok(x) => x
							Err(_) => -1
						}
						v = match r.i64("v") {
							Ok(x) => x
							Err(_) => -1
						}
						rg = match r.i64("rg") {
							Ok(x) => x
							Err(_) => -1
						}
						cd = match r.str("cd") {
							Ok(x) => x
							Err(_) => ""
						}
						td = match r.str("td") {
							Ok(x) => x
							Err(_) => ""
						}
						gd = match r.str("gd") {
							Ok(x) => x
							Err(_) => ""
						}
						ti = match r.i64("ti") {
							Ok(x) => x
							Err(_) => -1
						}
						gi = match r.i64("gi") {
							Ok(x) => x
							Err(_) => -1
						}
						cp = match r.str("cp") {
							Ok(x) => x
							Err(_) => ""
						}
						fm = match r.str("fm") {
							Ok(x) => x
							Err(_) => ""
						}
						sh = match r.i64("sh") {
							Ok(x) => x
							Err(_) => -1
						}
						if (id < 0) None
						else {
							# older unconsumed rows are closed as superseded; the
							# winning row stays PENDING until the frame that applies
							# it reports back - a crash between read and apply
							# leaves it retryable instead of silently lost
							_ = db.execute!(Bus.supersede_sql, [{ name: ":id", value: Integer(id) }])
							Some({ id, view: v, range: rg, cursor_day: cd, trace_day: td, ghost_day: gd, trace_id: ti, ghost_id: gi, capture: cp, family: fm, short: sh })
						}
					}
				}
			}
		}
	}

	# the directive's terminal outcome, written by the frame that applied it.
	# error carries which fields were refused ('' = all honoured); result the
	# file a capture produced ('' when it asked for none, or failed).
	mark_directive! : Sqlite.Db, I64, Str, Str => {}
	mark_directive! = |db, id, refused, result| {
		st = Bus.mark_status(refused)
		_ = db.execute!(Bus.mark_sql, [{ name: ":st", value: String(st) }, { name: ":e", value: String(refused) }, { name: ":r", value: String(result) }, { name: ":id", value: Integer(id) }])
	}

	# the window's answer: what the human is looking at, one row, upserted
	Focus : { view : I64, range : I64, cursor_day : Str, trace_day : Str, ghost_day : Str, trace_id : I64, ghost_id : I64, detail_day : Str, sport : Str, family : Str, curve_family : Str, curve_short : I64, map_id : I64 }

	# every placeholder the upsert names, bound from the row
	focus_bindings : Focus -> List({ name : Str, value : Sqlite.Value })
	focus_bindings = |f| [{ name: ":v", value: Integer(f.view) }, { name: ":rg", value: Integer(f.range) }, { name: ":cd", value: String(f.cursor_day) }, { name: ":td", value: String(f.trace_day) }, { name: ":gd", value: String(f.ghost_day) }, { name: ":ti", value: Integer(f.trace_id) }, { name: ":gi", value: Integer(f.ghost_id) }, { name: ":dd", value: String(f.detail_day) }, { name: ":sp", value: String(f.sport) }, { name: ":fm", value: String(f.family) }, { name: ":cf", value: String(f.curve_family) }, { name: ":cs", value: Integer(f.curve_short) }, { name: ":mi", value: Integer(f.map_id) }]

	write_focus! : Sqlite.Db, Focus => Try({}, [WriteFailed])
	write_focus! = |db, f| {
		ensure_bus!(db)
		res = db.execute!(Bus.focus_upsert_sql, focus_bindings(f))
		match res {
			Ok(_) => Ok({})
			Err(_) => Err(WriteFailed)
		}
	}

	# the window's last word on quitting: no row means "nobody is looking",
	# which a coach can read without judging an age. Only the ESC path can
	# reach this - the OS close button and a crash leave the last row behind,
	# and the focus staleness window is what retires those.
	clear_focus! : Sqlite.Db => Try({}, [WriteFailed])
	clear_focus! = |db|
		match db.execute!(Bus.focus_clear_sql, []) {
			Ok(_) => Ok({})
			Err(_) => Err(WriteFailed)
		}

	# "today" for the calendar questions below (the plan strip's week, the
	# plan rows' today flag): the athlete's civil day, resolved the way the
	# CLI resolves it - config `timezone` (IANA, through the system tz db, so
	# DST-correct) first, then `utc_offset_minutes`, then UTC. The machine
	# clock's zone is not consulted, so the window and `stride week` name the
	# same Monday on a laptop set to another zone. The value is a sqlite
	# modifier, "<minutes east of UTC> minutes", applied to 'now'.
	today_mod! : Cmd.Runner, Sqlite.Db => Str
	today_mod! = |runner, db| "${I64.to_str(local_offset_minutes!(runner, db))} minutes"

	local_offset_minutes! : Cmd.Runner, Sqlite.Db => I64
	local_offset_minutes! = |runner, db| {
		# the CLI reads the offset as a plain integer (an optional minus, then
		# digits) and treats anything else as unreadable, which scores as 0
		fixed = match plain_int(config_value!(db, "utc_offset_minutes")) {
			Ok(n) => n
			Err(_) => 0
		}
		tz = config_value!(db, "timezone")
		if (tz == "") fixed
		else match zone_offset_now!(runner, tz) {
			Ok(off) => off
			# an unknown zone falls back to the fixed offset, as the CLI does
			Err(_) => fixed
		}
	}

	# a config value as stored, untrimmed as the CLI reads it, or "" when the
	# key is absent or unreadable; the keys are compile-time constants
	config_value! : Sqlite.Db, Str => Str
	config_value! = |db, key|
		match db.query!("SELECT CAST(value AS TEXT) AS v FROM config WHERE key = '${key}';", []) {
			Ok(rows) => match List.first(rows) {
				Ok(r) => match r.str("v") {
					Ok(v) => v
					Err(_) => ""
				}
				Err(_) => ""
			}
			Err(_) => ""
		}

	# the zone's offset right now, through the shell the CLI uses: the system
	# tz db has the DST rules, and `date +%z` under TZ reports the offset in
	# force. The zone name travels as a positional argument, so a hostile
	# string cannot break out of the quoting.
	# the window's working directory, the base the platform resolves its
	# relative capture directory against; `fallback` when `sh` cannot say
	working_dir! : Cmd.Runner, Str => Str
	working_dir! = |runner, fallback|
		match runner.run_utf8!(Cmd.with_args(Cmd.new("sh"), ["-c", "pwd -P"])) {
			Ok(out) => {
				here = Str.trim(out.stdout)
				if (Str.starts_with(here, "/")) here else fallback
			}
			Err(_) => fallback
		}

	zone_offset_now! : Cmd.Runner, Str => Try(I64, [BadTz])
	zone_offset_now! = |runner, tz| {
		cmd = "if [ -f \"/usr/share/zoneinfo/$1\" ]; then TZ=\"$1\" date +%z; else echo INVALID; fi"
		match runner.run_utf8!(Cmd.with_args(Cmd.new("sh"), ["-c", cmd, "sh", tz])) {
			Ok(out) => parse_utc_offset(out.stdout)
			Err(_) => Err(BadTz)
		}
	}

	# a plain integer: an optional minus, then digits only, the rule the CLI
	# reads config integers by, so "+330" and " 5" are unreadable on both sides
	plain_int : Str -> Try(I64, [NotAnInt])
	plain_int = |s| {
		bytes = Str.to_utf8(s)
		digits = if (Str.starts_with(s, "-")) List.drop_first(bytes, 1) else bytes
		if (!(List.is_empty(digits)) and List.all(digits, |b| b >= 48 and b <= 57)) (I64.from_str(s).map_err(|_| NotAnInt)) else Err(NotAnInt)
	}

	# "+HHMM" / "-HHMM", what `date +%z` prints, to minutes east of UTC
	parse_utc_offset : Str -> Try(I64, [BadTz])
	parse_utc_offset = |raw|
		match Str.trim(raw).to_utf8() {
			[sign, h1, h2, m1, m2] => {
				digit = |b| if (b >= 48 and b <= 57) Ok(b.to_i64() - 48) else Err(BadTz)
				hh = (digit(h1)? * 10) + digit(h2)?
				mm = (digit(m1)? * 10) + digit(m2)?
				mag = (hh * 60) + mm
				if (sign == 45) Ok(-mag) else if (sign == 43) Ok(mag) else Err(BadTz)
			}
			_ => Err(BadTz)
		}

	# The Monday-aligned CURRENT week's completion count, the quest strip's
	# numerator and denominator. The week is TODAY's, the anchor the engine's
	# `week` command uses (today minus its Monday offset), not week_bounds',
	# which is the week of the last analyzed day. The two differ by a week
	# when analyze has not run since Monday; a plan count is a calendar
	# question, so it stays on the calendar. load_week_tss! reads week_bounds
	# because load is a series question.
	load_plan_week_at! : Sqlite.Db, Str => { done : I64, total : I64 }
	load_plan_week_at! = |db, today_mod|
		match db.query!("WITH anchor AS (SELECT date(date('now', '${today_mod}'), '-6 days', 'weekday 1') AS mon) SELECT CAST(SUM(CASE WHEN COALESCE(status,'') = 'done' THEN 1 ELSE 0 END) AS INTEGER) AS dn, COUNT(*) AS tot FROM plan_current, anchor WHERE target_date >= mon AND target_date < date(mon, '+7 days')", []) {
			Err(_) => { done: 0, total: 0 }
			Ok(rows) => match List.first(rows) {
				Err(_) => { done: 0, total: 0 }
				Ok(r) => {
					dn = match r.i64("dn") {
						Ok(x) => x
						Err(_) => 0
					}
					tot = match r.i64("tot") {
						Ok(x) => x
						Err(_) => 0
					}
					{ done: dn, total: tot }
				}
			}
		}

	# One plan_current row, with what the athlete did about it. `wi` is the
	# day's offset from this week's Monday (0..6 inside the week, 7+ for the
	# days ahead the ladder also lists). `act_*` describe the activity a done
	# session links; `sub_*` the substitute a skipped one names. The target and
	# the detected work reps are the two structured records `stride complete`
	# compares (target_match!), read the same way: power work segments of the
	# linked activity. `day_load_known` separates a measured zero-load day from
	# a day daily_load has not covered yet.
	PlanRow : {
		day : Str,
		wi : I64,
		typ : Str,
		detail : Str,
		rationale : Str,
		status : Str,
		reason : Str,
		today : Bool,
		past : Bool,
		done_day : Str,
		act_name : Str,
		act_secs : I64,
		act_load : I64,
		sub_id : I64,
		sub_name : Str,
		tgt_reps : I64,
		tgt_dur_s : I64,
		tgt_watts : F64,
		# the target as the engine stores it, any signal; '' when none
		tgt_lit : Str,
		# that target's result on its own signal as `complete` stored it; '' when
		# the session was completed without one
		tgt_res : Str,
		det_reps : I64,
		det_dur_s : I64,
		det_watts : F64,
		day_load_known : Bool,
		day_load : F64,
	}

	# The current Mon-Sun week, plus the six days ahead of the athlete's civil
	# today (today_mod!), so a day late in the week still shows what comes
	# next. Prescriptions are calendar items read on the real day, so this
	# view runs on the civil clock, not the series clock the PMC reads keep.
	# The Monday is the one load_plan_week_at! and the engine's `week` use.
	load_plan_at! : Sqlite.Db, Str => List(PlanRow)
	load_plan_at! = |db, today_mod|
		match db.query!("WITH anchor AS (SELECT date('now', '${today_mod}') AS today, date(date('now', '${today_mod}'), '-6 days', 'weekday 1') AS mon), seg AS (SELECT activity_id, COUNT(*) AS n, AVG(dur_s) AS du, AVG(avg_signal) AS w FROM activity_segments WHERE kind = 'work' AND signal = 'power' AND activity_id IN (SELECT pc.completed_activity_id FROM plan_current pc, anchor an WHERE pc.target_date >= an.mon AND pc.target_date <= date(an.today, '+6 days')) GROUP BY activity_id) SELECT CAST(p.target_date AS TEXT) AS d, CAST(julianday(p.target_date) - julianday(a.mon) AS INTEGER) AS wi, CAST(COALESCE(p.session_type, '') AS TEXT) AS t, CAST(COALESCE(p.detail, '') AS TEXT) AS dt, CAST(COALESCE(p.rationale, '') AS TEXT) AS ra, CAST(COALESCE(p.status, 'open') AS TEXT) AS pst, CAST(COALESCE(p.skipped_reason, '') AS TEXT) AS prs, (p.target_date = a.today) AS td, (p.target_date < a.today) AS pps, CAST(COALESCE(substr(ca.start_local, 1, 10), '') AS TEXT) AS cdd, CAST(COALESCE(ca.name, '') AS TEXT) AS can, CAST(COALESCE(ca.moving_time, 0) AS INTEGER) AS cam, CAST(ROUND(COALESCE(cm.tss, 0)) AS INTEGER) AS cal, CAST(COALESCE(sa.id, 0) AS INTEGER) AS sid, CAST(COALESCE(sa.name, '') AS TEXT) AS snm, CAST(COALESCE(p.target_reps, 0) AS INTEGER) AS ptr, CAST(COALESCE(p.target_dur_s, 0) AS INTEGER) AS ptd, CAST(COALESCE(p.target_watts, 0) AS REAL) AS ptw, CAST(COALESCE(p.target_literal, '') AS TEXT) AS ptl, CAST(COALESCE(p.target_result, '') AS TEXT) AS ptx, CAST(COALESCE(sg.n, 0) AS INTEGER) AS sgn, CAST(COALESCE(sg.du, 0) AS INTEGER) AS sgd, CAST(COALESCE(sg.w, 0) AS REAL) AS sgw, (dl.day IS NOT NULL) AS dlk, CAST(COALESCE(dl.tss, 0) AS REAL) AS dlt FROM plan_current p CROSS JOIN anchor a LEFT JOIN activities ca ON ca.id = p.completed_activity_id AND COALESCE(p.status, '') = 'done' LEFT JOIN activity_metrics cm ON cm.activity_id = ca.id LEFT JOIN seg sg ON sg.activity_id = ca.id LEFT JOIN activities sa ON sa.id = p.substitute_activity_id AND COALESCE(p.status, '') = 'skipped' LEFT JOIN daily_load dl ON dl.day = p.target_date WHERE p.target_date >= a.mon AND p.target_date <= date(a.today, '+6 days') ORDER BY p.target_date, p.id", []) {
			Err(_) => []
			Ok(rows) =>
				List.map(
					rows,
					|r| match decode_plan_row(r) {
						Ok(row) => row
						Err(_) => { day: "?", wi: -1, typ: "?", detail: "plan record unreadable", rationale: "", status: "open", reason: "", today: Bool.False, past: Bool.False, done_day: "", act_name: "", act_secs: 0, act_load: 0, sub_id: 0, sub_name: "", tgt_reps: 0, tgt_dur_s: 0, tgt_watts: 0.0, tgt_lit: "", tgt_res: "", det_reps: 0, det_dur_s: 0, det_watts: 0.0, day_load_known: Bool.False, day_load: 0.0 }
					},
				)
		}

	decode_plan_row : Sqlite.Row -> Try(PlanRow, [BadRow])
	decode_plan_row = |r| {
		day = r.str("d") ? |_| BadRow
		wi = r.i64("wi") ? |_| BadRow
		typ = r.str("t") ? |_| BadRow
		detail = r.str("dt") ? |_| BadRow
		rationale = r.str("ra") ? |_| BadRow
		status = r.str("pst") ? |_| BadRow
		reason = r.str("prs") ? |_| BadRow
		td = r.i64("td") ? |_| BadRow
		ps = r.i64("pps") ? |_| BadRow
		done_day = r.str("cdd") ? |_| BadRow
		act_name = r.str("can") ? |_| BadRow
		act_secs = r.i64("cam") ? |_| BadRow
		act_load = r.i64("cal") ? |_| BadRow
		sub_id = r.i64("sid") ? |_| BadRow
		sub_name = r.str("snm") ? |_| BadRow
		tgt_reps = r.i64("ptr") ? |_| BadRow
		tgt_dur_s = r.i64("ptd") ? |_| BadRow
		tgt_watts = r.f64("ptw") ? |_| BadRow
		tgt_lit = r.str("ptl") ? |_| BadRow
		tgt_res = r.str("ptx") ? |_| BadRow
		det_reps = r.i64("sgn") ? |_| BadRow
		det_dur_s = r.i64("sgd") ? |_| BadRow
		det_watts = r.f64("sgw") ? |_| BadRow
		dlk = r.i64("dlk") ? |_| BadRow
		day_load = r.f64("dlt") ? |_| BadRow
		Ok({ day, wi, typ, detail: ascii_safe(detail), rationale: ascii_safe(rationale), status, reason: ascii_safe(reason), today: td == 1, past: ps == 1, done_day, act_name: ascii_safe(act_name), act_secs, act_load, sub_id, sub_name: ascii_safe(sub_name), tgt_reps, tgt_dur_s, tgt_watts, tgt_lit, tgt_res: ascii_safe(tgt_res), det_reps, det_dur_s, det_watts, day_load_known: dlk == 1, day_load })
	}

	# this week's load beside last week's, MONDAY-ALIGNED to agree with the
	# engine's Metrics.weekly_rollup - the progress strip's two numbers
	load_week_tss! : Sqlite.Db => { this : I64, last : I64 }
	load_week_tss! = |db|
		match db.query!("WITH anchor AS (SELECT mon FROM week_bounds) SELECT CAST(ROUND(SUM(CASE WHEN day >= mon THEN tss ELSE 0 END)) AS INTEGER) AS tw, CAST(ROUND(SUM(CASE WHEN day >= date(mon, '-7 days') AND day < mon THEN tss ELSE 0 END)) AS INTEGER) AS lw FROM daily_load, anchor", []) {
			Err(_) => { this: 0, last: 0 }
			Ok(rows) => match List.first(rows) {
				Err(_) => { this: 0, last: 0 }
				Ok(r) => {
					tw = match r.i64("tw") {
						Ok(x) => x
						Err(_) => 0
					}
					lw = match r.i64("lw") {
						Ok(x) => x
						Err(_) => 0
					}
					{ this: tw, last: lw }
				}
			}
		}

	# The coach corner's state: no directive has ever been written, the
	# newest one described, or a read of the bus that failed. Only the first
	# draws nothing; a failed read is not an empty table.
	BusNote : [NoDirective, Note(Str), Unreadable]

	# the newest-row read the corner makes, over any row type: a failed query
	# is Unreadable, no row is NoDirective, a row is its description
	bus_note_from : Try(List(r), e), (r -> Str) -> BusNote
	bus_note_from = |res, describe|
		match res {
			Err(_) => Unreadable
			Ok(rows) => match List.first(rows) {
				Err(_) => NoDirective
				Ok(r) => Note(describe(r))
			}
		}

	# one directive told as the corner tells it: when it was written, the
	# view and range it asked for, and the day it put the cursor on. View -1
	# and range -1 are absent fields; a view the window does not draw is
	# named as ignored.
	directive_text : { at : Str, view : I64, range : I64, cursor_day : Str } -> Str
	directive_text = |d| {
		v = d.view
		vn = if (v == 0) "form" else if (v == 1) "power" else if (v == 2) "trace" else if (v == 3) "table" else if (v == 4) "plan" else if (v == 5) "heat" else if (v == 6) "zones" else if (v == 7) "ramp" else if (v == 8) "career" else if (v == 9) "lifts" else if (v == 10) "map" else if (v == 11) "map heat" else if (v == 12) "map play" else if (v >= 0) "view ${I64.to_str(v)} (ignored)" else ""
		rgp = if (d.range > 0) "${I64.to_str(d.range)}d" else ""
		joined = Str.join_with(List.keep_if([vn, rgp], |s2| s2 != ""), " / ")
		parts = if (joined == "") "steer" else joined
		if (d.cursor_day != "") "${d.at}  ->  ${parts} @ ${d.cursor_day}" else "${d.at}  ->  ${parts}"
	}

	# the coach corner: the newest directive (consumed or not), timestamped
	load_bus_note! : Sqlite.Db => BusNote
	load_bus_note! = |db| {
		ensure_bus!(db)
		bus_note_from(
			db.query!("SELECT CAST(strftime('%m-%d %H:%M', created_at, 'localtime') AS TEXT) AS at, CAST(COALESCE(view, -1) AS INTEGER) AS v, CAST(COALESCE(range, -1) AS INTEGER) AS rg, CAST(COALESCE(cursor_day, '') AS TEXT) AS cd FROM viz_directives ORDER BY id DESC LIMIT 1", []),
			|r| {
				at = match r.str("at") {
					Ok(x) => x
					Err(_) => ""
				}
				view = match r.i64("v") {
					Ok(x) => x
					Err(_) => -1
				}
				range = match r.i64("rg") {
					Ok(x) => x
					Err(_) => -1
				}
				cursor_day = match r.str("cd") {
					Ok(x) => x
					Err(_) => ""
				}
				directive_text({ at, view, range, cursor_day })
			},
		)
	}

	# a year of (day, load, weekday) for the heatmap grid, oldest first, plus
	# up to six spare days the view may shed aligning its first column to Monday;
	# %w is 0=Sunday..6=Saturday, the view maps it to Monday-first rows
	HeatDay : { day : Str, tss : I64, dow : I64 }
	load_heat! : Sqlite.Db => List(HeatDay)
	load_heat! = |db|
		match db.query!("SELECT CAST(day AS TEXT) AS d, CAST(ROUND(COALESCE(tss, 0)) AS INTEGER) AS t, CAST(strftime('%w', day) AS INTEGER) AS w FROM (SELECT day, tss FROM daily_load ORDER BY day DESC LIMIT 372) ORDER BY day ASC", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						dy = r.str("d") ? |_| "bad"
						ts = r.i64("t") ? |_| "bad"
						w = r.i64("w") ? |_| "bad"
						Ok({ day: dy, tss: ts, dow: w })
					},
				)
		}

	# twelve Monday weeks of zone seconds and intensity classes, oldest first,
	# off the activity_intensity view - the shared per-activity intensity
	# classification (pi_* split when present, HR zones otherwise) - with the
	# week anchor from week_bounds and empty weeks materialized as zero rows.
	# Zone seconds cover every activity; easy/moderate/hard cover only the
	# activities the view marks `polarized`, the population every share reads.
	# `days` is how many of the week's seven days the series covers, through
	# series_clock's today: 7 for every finished week, fewer for the current one.
	ZoneWeek : { wk : Str, days : I64, z1 : I64, z2 : I64, z3 : I64, z4 : I64, z5 : I64, easy : I64, moderate : I64, hard : I64 }
	load_zone_weeks! : Sqlite.Db => List(ZoneWeek)
	load_zone_weeks! = |db|
		match db.query!("WITH mondays(wk) AS (SELECT date(mon, '-77 days') FROM week_bounds UNION ALL SELECT date(wk, '+7 days') FROM mondays WHERE wk < (SELECT mon FROM week_bounds)), agg AS (SELECT date(day, '-6 days', 'weekday 1') AS awk, SUM(z1_s) AS z1, SUM(z2_s) AS z2, SUM(z3_s) AS z3, SUM(z4_s) AS z4, SUM(z5_s) AS z5, SUM(CASE WHEN polarized = 1 THEN easy_s ELSE 0 END) AS easy, SUM(CASE WHEN polarized = 1 THEN moderate_s ELSE 0 END) AS moderate, SUM(CASE WHEN polarized = 1 THEN hard_s ELSE 0 END) AS hard FROM activity_intensity WHERE day >= (SELECT date(mon, '-77 days') FROM week_bounds) GROUP BY awk) SELECT CAST(m.wk AS TEXT) AS wk, CAST(MIN(7, MAX(0, julianday((SELECT today FROM series_clock)) - julianday(m.wk) + 1)) AS INTEGER) AS dys, CAST(COALESCE(a.z1, 0) AS INTEGER) AS z1, CAST(COALESCE(a.z2, 0) AS INTEGER) AS z2, CAST(COALESCE(a.z3, 0) AS INTEGER) AS z3, CAST(COALESCE(a.z4, 0) AS INTEGER) AS z4, CAST(COALESCE(a.z5, 0) AS INTEGER) AS z5, CAST(COALESCE(a.easy, 0) AS INTEGER) AS easy, CAST(COALESCE(a.moderate, 0) AS INTEGER) AS moderate, CAST(COALESCE(a.hard, 0) AS INTEGER) AS hard FROM mondays m LEFT JOIN agg a ON a.awk = m.wk ORDER BY m.wk ASC", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						wk = r.str("wk") ? |_| "bad"
						dy7 = r.i64("dys") ? |_| "bad"
						z1 = r.i64("z1") ? |_| "bad"
						z2 = r.i64("z2") ? |_| "bad"
						z3 = r.i64("z3") ? |_| "bad"
						z4 = r.i64("z4") ? |_| "bad"
						z5 = r.i64("z5") ? |_| "bad"
						ez = r.i64("easy") ? |_| "bad"
						mo = r.i64("moderate") ? |_| "bad"
						hd = r.i64("hard") ? |_| "bad"
						Ok({ wk, days: dy7, z1, z2, z3, z4, z5, easy: ez, moderate: mo, hard: hd })
					},
				)
		}

	# twelve Monday weeks off the weekly_ramp view - the ONE definition of
	# weekly ramp - in tenths (F64 has no narrowing; SQL rounds to integers).
	# `days` counts the week's days the series covers, the way ZoneWeek does.
	# `ctl_start` is the CTL the week started from, unrounded: the load mode
	# draws each week's change from it, and the focus line reads the hold
	# level (core.Load.hold) off it.
	RampWeek : { wk : Str, days : I64, tss : I64, ctl10 : I64, ramp10 : I64, ctl_start : F64 }

	# The CTL a week started from. The view's ramp is its end-of-week CTL less
	# the previous week's, so the start is the end less the ramp; but a week
	# that begins on or before the first day of history has no previous week,
	# and the view reports its ramp as zero there. The engine walks daily_load
	# from zero, so such a week started at zero.
	week_start_ctl : Bool, F64, F64 -> F64
	week_start_ctl = |before_history, ctl_end, ramp| if (before_history) 0.0 else ctl_end - ramp

	load_ramp_weeks! : Sqlite.Db => List(RampWeek)
	load_ramp_weeks! = |db|
		match db.query!("SELECT CAST(wk AS TEXT) AS wk, CAST(MIN(7, MAX(0, julianday((SELECT today FROM series_clock)) - julianday(wk) + 1)) AS INTEGER) AS dys, CAST(ROUND(tss) AS INTEGER) AS tss, CAST(ROUND(ctl_end * 10) AS INTEGER) AS ctl10, CAST(ROUND(ramp * 10) AS INTEGER) AS ramp10, CAST(ctl_end AS REAL) AS ce, CAST(ramp AS REAL) AS rp, CAST(wk <= COALESCE((SELECT MIN(day) FROM daily_load), '') AS INTEGER) AS pre FROM weekly_ramp ORDER BY wk ASC", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						wk = r.str("wk") ? |_| "bad"
						ts = r.i64("tss") ? |_| "bad"
						c10 = r.i64("ctl10") ? |_| "bad"
						r10 = r.i64("ramp10") ? |_| "bad"
						dy = r.i64("dys") ? |_| "bad"
						ce = r.f64("ce") ? |_| "bad"
						rp = r.f64("rp") ? |_| "bad"
						pre = r.i64("pre") ? |_| "bad"
						Ok({ wk, days: dy, tss: ts, ctl10: c10, ramp10: r10, ctl_start: week_start_ctl(pre != 0, ce, rp) })
					},
				)
		}

	# The career, assembled from the three v32 views: per-sport totals, the
	# calendar-month load spine, and the month-close ride FTP. Months come from
	# monthly_load's rows only - a month with no training produces no bar, and
	# an ftp of 0 means "not measured that month": the line breaks rather than
	# inventing a value. partial marks the month still in progress.
	CareerMonth : { month : Str, load : I64, ftp10 : I64, partial : Bool }
	# the spine family: whichever family has the most months of threshold data,
	# with the kind that says how to read and label it. An athlete who only
	# runs gets pace, one who only rides gets power, and the arc means the same
	# thing either way because the stored value is a SPEED in both.
	SpineFam : { fam : Str, kind : Str, months : I64 }
	# one family's whole arc, ready to draw. Every page F cycles is loaded at
	# launch (Career.cycle_fams names them: the threshold families widest
	# first, then the families with sessions and no threshold, whose kind
	# matches no threshold row and so reads 0 every month), so switching
	# between them is a memory read rather than a task round-trip - the same
	# reason the trace picker caches its sessions.
	CareerSpine : { fam : Str, kind : Str, rows : List(CareerMonth) }
	CareerSport : { sport : Str, sessions : I64, hours10 : I64, dist_m : F64 }
	# Strength has its own tab, which reads lifts rather than monthly tonnage,
	# so the career spine leaves the tonnage kind out.
	load_spine_fams! : Sqlite.Db => List(SpineFam)
	load_spine_fams! = |db|
		match db.query!("SELECT CAST(fam AS TEXT) AS f, CAST(kind AS TEXT) AS k, COUNT(*) AS n FROM monthly_threshold WHERE kind <> 'tonnage' GROUP BY fam, kind ORDER BY n DESC, fam", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						f = r.str("f") ? |_| "bad"
						k = r.str("k") ? |_| "bad"
						n = r.i64("n") ? |_| "bad"
						Ok({ fam: f, kind: k, months: n })
					},
				)
		}

	# every family's arc, from two reads however many families there are:
	# monthly_load (the ground, shared by every spine) and monthly_threshold
	# (every family's month-close value) are each read once, and the per-family
	# rows are assembled in memory. SQLite page-caches the threshold view across
	# repeated reads, so this is fewer round-trips, not less work - the window
	# opens in the same time either way. ftp10 is the spine value in tenths -
	# watts for a power family, m/s for a pace one, kg for tonnage; 0 means the
	# family had no scored session that month, and the renderer breaks the line
	# rather than inventing a value. Families keep the input order (widest
	# career first, as load_spine_fams! sorts them); rows run month-ascending.
	load_career_spines! : Sqlite.Db, List(SpineFam), Str => List(CareerSpine)
	load_career_spines! = |db, fams, today_mod| {
		base = load_monthly_base_at!(db, today_mod)
		thr = load_all_thresholds!(db)
		List.map(
			fams,
			|f| {
				rows = List.map(
					base,
					|b| {
						ftp10 = List.fold(thr, 0, |acc, x| if (x.fam == f.fam and x.kind == f.kind and x.month == b.month) x.ftp10 else acc)
						{ month: b.month, load: b.load, ftp10, partial: b.partial }
					},
				)
				{ fam: f.fam, kind: f.kind, rows }
			},
		)
	}

	# the spine ground, shared by every family: one row per month with its
	# total load and whether it is the still-open current month (partial). Read
	# once; the per-family arcs all stand on it.
	# the open month is the athlete's current month (today_mod!), not UTC's
	load_monthly_base_at! : Sqlite.Db, Str => List({ month : Str, load : I64, partial : Bool })
	load_monthly_base_at! = |db, today_mod|
		match db.query!("SELECT CAST(month AS TEXT) AS m, CAST(ROUND(load) AS INTEGER) AS ld, CASE WHEN month = strftime('%Y-%m', 'now', '${today_mod}') THEN 1 ELSE 0 END AS pt FROM monthly_load ORDER BY month ASC", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						m = r.str("m") ? |_| "bad"
						ld = r.i64("ld") ? |_| "bad"
						pt = r.i64("pt") ? |_| "bad"
						Ok({ month: m, load: ld, partial: pt == 1 })
					},
				)
		}

	# the months a marked threshold test (ADR 0020) sets a family's spine from,
	# with the threshold signal it sets (power or pace): power and pace tests
	# only, since a heart-rate test moves no spine. An engine older than the
	# tests table answers with an error, read as none.
	load_test_months! : Sqlite.Db => List({ fam : Str, month : Str, kind : Str, signal : Str })
	load_test_months! = |db|
		match db.query!("SELECT CAST(a.sport_family AS TEXT) AS f, substr(CAST(a.start_local AS TEXT), 1, 7) AS m, CAST(t.kind AS TEXT) AS k, CAST(t.signal AS TEXT) AS sg FROM threshold_tests t JOIN activities a ON a.id = t.activity_id WHERE t.signal <> 'hr' ORDER BY a.start_local", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						f = r.str("f") ? |_| "bad"
						m = r.str("m") ? |_| "bad"
						k = r.str("k") ? |_| "bad"
						sg = r.str("sg") ? |_| "bad"
						Ok({ fam: f, month: m, kind: k, signal: sg })
					},
				)
		}

	# every family's month-close threshold in tenths, every kind, in ONE read
	# of the expensive monthly_threshold view. A family can carry two kinds (a
	# run with a power meter has both a power and a pace threshold), so a row
	# names its kind. A month/family/kind with no threshold has no row here,
	# and the assembler above scores it 0.
	load_all_thresholds! : Sqlite.Db => List({ fam : Str, kind : Str, month : Str, ftp10 : I64 })
	load_all_thresholds! = |db|
		match db.query!("SELECT CAST(fam AS TEXT) AS f, CAST(kind AS TEXT) AS k, CAST(month AS TEXT) AS m, CAST(ROUND(value * 10) AS INTEGER) AS f10 FROM monthly_threshold", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						f = r.str("f") ? |_| "bad"
						k = r.str("k") ? |_| "bad"
						m = r.str("m") ? |_| "bad"
						f10 = r.i64("f10") ? |_| "bad"
						Ok({ fam: f, kind: k, month: m, ftp10: f10 })
					},
				)
		}

	# the athlete's unit preference from config, resolved by the shared rule in
	# core.Units. Absent, unreadable, or a failed read all land on Metric, the
	# storage unit - the same honest floor every loader here takes, and a
	# display preference must never be the reason a view fails.
	units! : Sqlite.Db => [Metric, Imperial]
	units! = |db|
		match db.query!("SELECT CAST(value AS TEXT) AS v FROM config WHERE key = 'units'", []) {
			Err(_) => Metric
			Ok(rows) =>
				match List.first(rows) {
					Err(_) => Metric
					Ok(r) =>
						match r.str("v") {
							Ok(v) => Units.units_of(v)
							Err(_) => Metric
						}
				}
		}

	# distance leaves SQL in METRES: rounding to a display unit here would bake
	# the athlete's setting into the loader, and the renderer is the last moment
	load_career_sports! : Sqlite.Db => List(CareerSport)
	load_career_sports! = |db|
		match db.query!("SELECT CAST(sport AS TEXT) AS s, sessions AS n, CAST(ROUND(secs / 360.0) AS INTEGER) AS h10, CAST(COALESCE(meters, 0) AS REAL) AS m FROM career_totals ORDER BY sessions DESC, sport", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						s = r.str("s") ? |_| "bad"
						n = r.i64("n") ? |_| "bad"
						h10 = r.i64("h10") ? |_| "bad"
						m = r.f64("m") ? |_| "bad"
						Ok({ sport: s, sessions: n, hours10: h10, dist_m: m })
					},
				)
		}

	# one family's own month: the load it carried and how many sessions built
	# it. `monthly_load` pools every sport, which is what the career ground
	# should be, but it cannot answer what the SELECTED family did - and a
	# spine whose family has no threshold data (strength before any sets are
	# pasted) would otherwise put nothing of its own on screen. Grouped on the
	# stored `sport_family` falling back to `sport_type`, the same expression
	# monthly_threshold groups on: a trigger canonicalizes the column on
	# insert, and the COALESCE covers a row written before it existed.
	FamMonth : { fam : Str, month : Str, load : I64, sessions : I64 }
	load_fam_months! : Sqlite.Db => List(FamMonth)
	load_fam_months! = |db|
		match db.query!("SELECT CAST(fam AS TEXT) AS f, CAST(month AS TEXT) AS m, load AS ld, sessions AS n FROM monthly_family_load ORDER BY f, m", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						f = r.str("f") ? |_| "bad"
						m = r.str("m") ? |_| "bad"
						ld = r.i64("ld") ? |_| "bad"
						n = r.i64("n") ? |_| "bad"
						Ok({ fam: f, month: m, load: ld, sessions: n })
					},
				)
		}

	# every record on the key's ladder: the best-ever value per duration
	# rung. The rung list is the ladder's own rungs view - every rung the
	# ladder has, whether or not any session recorded one - and the record
	# per rung joins onto it from the unpivot, so a rung added to the schema
	# reaches the record book with no edit in this file. A rung no session
	# has recorded keeps its row at w 0, which tells the view which rows a
	# curve has and whether a row has ever had a best. The query runs once
	# per load (launch, R and a chip), never per frame.
	PrRung : { secs : I64, w : I64 }
	load_prs! : Sqlite.Db, Str => List(PrRung)
	load_prs! = |db, curve| {
		lad = ladder_of(curve)
		match db.query!("WITH best AS (SELECT rung, MAX(${lad.val}) AS v FROM ${lad.view} WHERE ${lad.keycol} = :fam GROUP BY rung) SELECT CAST(r.secs AS INTEGER) AS secs, CAST(COALESCE(ROUND(b.v), 0) AS INTEGER) AS w FROM ${lad.rungs} r LEFT JOIN best b ON b.rung = r.rung ORDER BY r.secs ASC", [{ name: ":fam", value: String(lad.key) }]) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						sc = r.i64("secs") ? |_| "bad"
						w9 = r.i64("w") ? |_| "bad"
						Ok({ secs: sc, w: w9 })
					},
				)
		}
	}

	# event days inside the heat window only - the grid spans at most 372 days
	# back from MAX(day), so anything outside that range could never ring a cell
	load_event_days! : Sqlite.Db => List(Str)
	load_event_days! = |db|
		match db.query!("WITH anchor AS (SELECT today FROM series_clock) SELECT DISTINCT CAST(event_date AS TEXT) AS d FROM events, anchor WHERE event_date >= date(today, '-372 days') AND event_date <= today", []) {
			Err(_) => []
			Ok(rows) =>
				List.keep_oks(
					rows,
					|r| {
						d = r.str("d") ? |_| "bad"
						Ok(d)
					},
				)
		}

	# a day's note from load_day_notes!, or the honest default
	note_for : List({ day : Str, note : Str }), Str -> Str
	note_for = |notes, dy|
		List.fold(notes, "rest day", |acc, x| if (x.day == dy) x.note else acc)

	# a session's numbers line in the detail panel: minutes, distance, its
	# load, and normalized power when a meter measured it. The load is the
	# session's under whichever model scored it (power or HR TSS, session-RPE
	# for a rated lift), so the line names it load, never TSS.
	stats_line : { mins : I64, dist : Str, load : I64, np : I64 } -> Str
	stats_line = |s| {
		head = "${num_unit(s.mins, "min")}  ${s.dist}  ${num_unit(s.load, "load")}"
		if (s.np > 0) "${head}  ${num_unit(s.np, "w")} np" else head
	}

	# one day's full story for the detail panel: each activity with its type,
	# duration, distance and load - pre-formatted lines, coach-legible, in the
	# athlete's own units (distance arrives in SI metres and converts here)
	decode_activity_row : [Metric, Imperial], Sqlite.Row -> Try(DayLine, [BadRow])
	decode_activity_row = |units, r| {
		nm = r.str("name") ? |_| BadRow
		sp = r.str("sport") ? |_| BadRow
		secs = r.i64("secs") ? |_| BadRow
		dist_m = r.f64("dist_m") ? |_| BadRow
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
		dk = Fmt.tenths((Units.dist_value(units, dist_m) * 10.0).round_to_i64_try().ok_or(0))
		du = Units.dist_unit(units)
		stats = stats_line({ mins, dist: "${dk}${du}", load: tss, np })
		# if100 is intensity_factor * 100 rounded: 98 -> "IF 0.98", 105 -> "IF 1.05"
		p1 = if (if100 > 0) "IF ${Fmt.hundredths(if100)}" else ""
		p2 = if (hr > 0) "${I64.to_str(hr)} bpm avg" else ""
		p3 = if (rpe != "0.0" and rpe != "0") "rpe ${rpe}" else "unrated"
		extra = Str.join_with(List.keep_if([p1, p2, p3], |s| s != ""), "   ")
		Ok({ title: ascii_safe("${nm} [${sp}]"), stats, extra, zones: [z1, z2, z3, z4, z5] })
	}

	load_day_detail! : Sqlite.Db, [Metric, Imperial], Str => List(DayLine)
	load_day_detail! = |db, units, day|
		match db.query!("SELECT CAST(a.name AS TEXT) AS name, CAST(a.sport_type AS TEXT) AS sport, CAST(COALESCE(a.moving_time, 0) AS INTEGER) AS secs, CAST(COALESCE(a.distance, 0) AS REAL) AS dist_m, CAST(ROUND(COALESCE(m.tss, 0)) AS INTEGER) AS tss, CAST(ROUND(COALESCE(m.normalized_power, 0)) AS INTEGER) AS np, CAST(ROUND(COALESCE(m.intensity_factor, 0) * 100) AS INTEGER) AS if100, CAST(ROUND(COALESCE(a.avg_hr, 0)) AS INTEGER) AS hr, CAST(ROUND(COALESCE(r.rpe, 0), 1) AS TEXT) AS rpe, CAST(COALESCE(m.z1_s, 0) AS INTEGER) AS z1, CAST(COALESCE(m.z2_s, 0) AS INTEGER) AS z2, CAST(COALESCE(m.z3_s, 0) AS INTEGER) AS z3, CAST(COALESCE(m.z4_s, 0) AS INTEGER) AS z4, CAST(COALESCE(m.z5_s, 0) AS INTEGER) AS z5 FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id LEFT JOIN ratings r ON r.activity_id = a.id WHERE a.start_local >= :d AND a.start_local < date(:d, '+1 day') ORDER BY a.start_local", [{ name: ":d", value: String(day) }]) {
			Err(_) => [{ title: "detail query failed", stats: "", extra: "", zones: [] }]
			Ok(rows) =>
				if (List.is_empty(rows)) [{ title: "rest day - no activities", stats: "", extra: "", zones: [] }]
				else
				# corruption surfaces PER ROW: an unreadable activity renders as
				# its own error line while its neighbors still show
					List.map(
						rows,
						|r| match decode_activity_row(units, r) {
							Ok(line) => line
							Err(_) => { title: "activity record unreadable", stats: "", extra: "", zones: [] }
						},
					)
		}

	# How many sessions the picker offers. The bound is about how far back a
	# comparison can reach: a season's worth of sessions is what makes "the
	# same workout in the spring" a question the window can answer at all.
	# Every one is downsampled in the boot task, three queries per session,
	# so the bound is also that task's cost — linear in the count.
	trace_menu_limit : I64
	trace_menu_limit = 120

	# The sessions the picker offers, newest first. The gate is "carries a
	# stream this window can plot", NOT "has detected work blocks": the
	# detector finds no structure in a large share of real sessions, and a
	# ride held at one effort is still a ride worth looking at. Gating on
	# blocks would also hide any sport whose sessions rarely trip the detector.
	#
	# `chan` is decided per ROW by which stream that session actually carries,
	# preferring power, rather than guessed from the sport. Sports do not
	# divide cleanly: strength work carries heart rate and never watts, but a
	# run may carry either, and picking by sport draws an empty plot for
	# whichever sessions the guess gets wrong. `sport` still rides along, for
	# the picker's filter rather than for the channel.
	# A pace-family session carrying a distance stream plots PACE - what a
	# runner actually reads - even when it also carries heart rate; power
	# still outranks everything (a meter is the most direct measurement on
	# the chart). The family gate keeps rides off the pace channel: a ride's
	# distance stream is real but nobody reads a ride in min/km.
	# the families whose trace is pace when no power stream exists: every
	# family a pace target can be written for (Sports.pace_target_families),
	# as an SQL list, so adding a pace family there adds its trace here
	pace_trace_fams_sql : Str
	pace_trace_fams_sql = Str.join_with(List.map(Sports.pace_target_families, |f| "'${f}'"), ",")

	expect pace_trace_fams_sql == "'Run','Walk','Swim','Rowing'"

	trace_menu_from : Str
	trace_menu_from = "SELECT a.id AS id, CAST(substr(a.start_local, 1, 10) AS TEXT) AS day, CAST(COALESCE(a.name,'') AS TEXT) AS name, CAST(COALESCE(a.sport_family,'') AS TEXT) AS sport, CASE WHEN json_extract(st.raw_json,'$.watts.data') IS NOT NULL THEN '$.watts.data' WHEN a.sport_family IN (${pace_trace_fams_sql}) AND json_extract(st.raw_json,'$.distance.data') IS NOT NULL AND json_extract(st.raw_json,'$.time.data') IS NOT NULL THEN 'pace' ELSE '$.heartrate.data' END AS chan FROM activities a JOIN streams st ON st.activity_id = a.id WHERE json_extract(st.raw_json,'$.watts.data') IS NOT NULL OR json_extract(st.raw_json,'$.heartrate.data') IS NOT NULL OR (a.sport_family IN (${pace_trace_fams_sql}) AND json_extract(st.raw_json,'$.distance.data') IS NOT NULL AND json_extract(st.raw_json,'$.time.data') IS NOT NULL)"

	trace_menu_q : Str
	trace_menu_q = "${trace_menu_from} ORDER BY a.start_local DESC LIMIT :lim"

	# one session's picker row, by the menu's own rule, whatever its age
	trace_one_q : Str
	trace_one_q = "SELECT id, day, name, sport, chan FROM (${trace_menu_from}) WHERE id = :id"

	# The cap runs AFTER the ascii_safe gate, because the gate can grow what
	# it maps (an arrow becomes "->"): capping first would let a gated name
	# outgrow the bound the cap exists to hold. A capped name is MARKED -
	# Strava names are unbounded free text, the header draws the name
	# right-aligned on the same line as the subtitle, so an uncapped name
	# overruns it at narrow widths, and a bare cut reads as a complete name
	# that is wrong. ".." rather than an ellipsis glyph because the brand
	# atlases carry ASCII. The count is BYTES, taking 48 so the bound
	# survives the worst input: a cut landing mid-sequence becomes a 3-byte
	# replacement character, and 48 + 3 + 2 marker bytes still sits inside
	# the 52-byte budget. A glyph a byte count over-counts is cut harder
	# than its display width requires - the bound holds for every input,
	# which is the property the layout needs.
	cap_name : Str -> Str
	cap_name = |s|
		if (Str.count_utf8_bytes(s) > 52) (Str.concat(Str.from_utf8_lossy(List.take_first(Str.to_utf8(s), 48)), "..")) else s

	expect {
		cap_name("short") == "short"
			# 52 exactly passes untouched: the cap marks only what it shortens
			and cap_name(Str.repeat("a", 52)) == Str.repeat("a", 52)
			and cap_name(Str.repeat("a", 53)) == Str.concat(Str.repeat("a", 48), "..")
			# the marker fits INSIDE the bound rather than pushing past it
			and Str.count_utf8_bytes(cap_name(Str.repeat("a", 200))) == 50
			# and the bound holds when the cut lands mid-sequence: the partial
			# character becomes a 3-byte replacement, not an overrun
			and Str.count_utf8_bytes(cap_name(Str.concat("a", Str.repeat("é", 26)))) <= 52
	}

	watts_chan : Str
	watts_chan = "$.watts.data"

	hr_chan : Str
	hr_chan = "$.heartrate.data"

	# NOT a json path: the pace channel reads two arrays (time + distance)
	# and differences them, so the loader branches on this sentinel instead
	# of binding it into json_extract.
	pace_chan : Str
	pace_chan = "pace"

	# The y axis names what the chosen channel counts, so the label cannot
	# disagree with the samples underneath it. Pace speaks the sport's own
	# unit - per 100 m for a swim, per 500 m on the erg, the athlete's
	# kilometre or mile on foot - and the samples stay SI m/s, only the label
	# converts.
	trace_unit : Str, [Metric, Imperial], Str -> Str
	trace_unit = |chan, units, sport|
		if (chan == hr_chan) ("bpm")
		else if (chan == pace_chan) (if (fixed_pace_fam(sport)) (Str.concat("min", Sports.pace_unit(Sports.canonical(sport)).label)) else Units.pace_unit(units))
		else "W"

	# a family paced over a fixed distance in every unit culture (Sports
	# pace_label_for): the swim's 100 m and the erg's 500 m
	fixed_pace_fam : Str -> Bool
	fixed_pace_fam = |sport| {
		fam = Sports.canonical(sport)
		fam == "Swim" or fam == "Rowing"
	}

	swim_pace_unit : Str
	swim_pace_unit = Str.concat("min", Sports.pace_unit("Swim").label)

	# a split is one pace unit's distance: 100 m for a swim, 500 m on the
	# erg, the athlete's kilometre or mile on foot
	split_len_for : [Metric, Imperial], Str -> F64
	split_len_for = |units, sport|
		if (fixed_pace_fam(sport)) (I64.to_f64(Sports.pace_unit(Sports.canonical(sport)).dist_m)) else Units.split_len(units)

	expect split_len_for(Imperial, "Swim") == 100.0 and split_len_for(Metric, "VirtualRow") == 500.0 and split_len_for(Imperial, "TrailRun") == 1609.344

	expect trace_unit(watts_chan, Metric, "Ride") == "W"
	expect trace_unit(hr_chan, Imperial, "Run") == "bpm"
	expect trace_unit(pace_chan, Metric, "Run") == Units.pace_unit(Metric)
	expect trace_unit(pace_chan, Imperial, "TrailRun") == Units.pace_unit(Imperial)
	expect trace_unit(pace_chan, Imperial, "OpenWaterSwim") == "min/100m" and trace_unit(pace_chan, Metric, "Swim") == swim_pace_unit
	expect trace_unit(pace_chan, Imperial, "Rowing") == "min/500m"

	# the channel said as a word - for prose (the subtitle, a ghost refusal)
	# where a unit string would beg the units question prose does not have
	chan_name : Str -> Str
	chan_name = |chan|
		if (chan == hr_chan) ("heart rate") else if (chan == pace_chan) ("pace") else "power"

	expect chan_name(watts_chan) == "power"
	expect chan_name(hr_chan) == "heart rate"
	expect chan_name(pace_chan) == "pace"

	load_trace_ids! : Sqlite.Db => List({ id : I64, day : Str, name : Str, sport : Str, chan : Str })
	load_trace_ids! = |db|
		match db.query!(trace_menu_q, [{ name: ":lim", value: Integer(trace_menu_limit) }]) {
			Err(_) => []
			Ok(rows) => List.keep_oks(rows, trace_row)
		}

	trace_row : Sqlite.Row -> Try({ id : I64, day : Str, name : Str, sport : Str, chan : Str }, Str)
	trace_row = |r| {
		i = r.i64("id") ? |_| "bad id"
		d = r.str("day") ? |_| "bad day"
		nm = r.str("name") ? |_| "bad name"
		sp = r.str("sport") ? |_| "bad sport"
		ch = r.str("chan") ? |_| "bad chan"
		# names pass the ascii_safe gate - the brand atlases carry
		# ASCII, and an unmapped glyph draws as '?'. Gate first,
		# THEN cap: the gate can grow what it maps
		Ok({ id: i, day: d, name: cap_name(ascii_safe(nm)), sport: sp, chan: ch })
	}

	# the picker row of one session, for a session the map opens that the
	# picker does not hold; NoTrace when its stream carries nothing the trace
	# can plot, or the read fails
	load_trace_one! : Sqlite.Db, I64 => Try({ id : I64, day : Str, name : Str, sport : Str, chan : Str }, [NoTrace])
	load_trace_one! = |db, id|
		match db.query!(trace_one_q, [{ name: ":id", value: Integer(id) }]) {
			Ok(rows) =>
				match List.first(List.keep_oks(rows, trace_row)) {
					Ok(row) => Ok(row)
					Err(_) => Err(NoTrace)
				}
			Err(_) => Err(NoTrace)
		}

	# One session's trace, DOWNSAMPLED in SQL to ~800 points. A 45-minute ride
	# carries ~2700 samples against ~830 pixels of plot, so drawing them all costs
	# three line segments per pixel and shows nothing more. json_each reads the
	# stored stream directly — SQLite has JSON1, and this platform has no JSON
	# decoder. `chan` is one of watts_chan / hr_chan, picked per picker row by
	# trace_menu_q's CASE, and BOUND rather than spliced — json_extract takes
	# its path as an ordinary expression.
	#
	# The sample count is read first, by its own query, and the keep-every-kth
	# step is bound into the second. A single statement that derives the count
	# from the same json_each it filters (a CTE read twice, or a correlated
	# MAX) lets the bundled SQLite re-run json_extract over the whole stream
	# document once per sample, which is quadratic in the session's length:
	# a 4-hour ride then holds the boot task for minutes. Two statements keep
	# both reads linear.
	load_trace! : Sqlite.Db, I64, Str => List(F32)
	load_trace! = |db, aid, chan| {
		if chan == pace_chan {
			load_trace_pace!(db, aid)
		} else {
			count = match db.query!("SELECT COALESCE(json_array_length(raw_json, :chan), 0) AS c FROM streams WHERE activity_id = :aid", [{ name: ":aid", value: Integer(aid) }, { name: ":chan", value: String(chan) }]) {
				Ok(rows) =>
					match List.first(rows) {
						Ok(r) => r.i64("c") ?? 0
						Err(_) => 0
					}
				Err(_) => 0
			}
			q = "SELECT CAST(j.value AS INTEGER) AS v FROM streams, json_each(json_extract(streams.raw_json, :chan)) AS j WHERE streams.activity_id = :aid AND j.key % :k = 0 ORDER BY j.key"
			match db.query!(q, [{ name: ":aid", value: Integer(aid) }, { name: ":chan", value: String(chan) }, { name: ":k", value: Integer(trace_step(count)) }]) {
				Err(_) => []
				Ok(rows) => List.keep_oks(
					rows,
					|r| {
						v = r.i64("v") ? |_| "bad v"
						Ok(I64.to_f32(v))
					},
				)
			}
		}
	}

	# keep every kth sample so a trace draws about trace_points of them; a
	# stream at or under that length keeps every sample
	trace_points : I64
	trace_points = 800

	trace_step : I64 -> I64
	trace_step = |count| if (count <= trace_points) 1 else count // trace_points

	# The pace channel's samples: (time, distance) pairs read together,
	# differenced to per-second SPEED by the same core.Series discipline the
	# engine scores with (gaps over max_fill_gap are pauses and emit
	# nothing), then bucket-MEANED down to ~800 points. Meaning the bucket
	# instead of picking every kth sample matters here and not on watts/HR:
	# 1 Hz GPS speed jitters by whole m/s, and a picked sample aliases the
	# jitter into the line where a mean draws the pace the athlete held.
	# One json_each per query, zipped in Roc - the single-table shape is the
	# one load_trace! has always run, so the pace channel adds no new query
	# shape to the platform. Positional zip is correct because both arrays
	# come from the same stream document: Strava emits them index-aligned,
	# and a length mismatch truncates to the shorter side.
	load_stream_arr! : Sqlite.Db, I64, Str => List(F64)
	load_stream_arr! = |db, aid, path| {
		q = "SELECT CAST(json_each.value AS REAL) AS v FROM streams, json_each(json_extract(streams.raw_json, :p)) WHERE streams.activity_id = :aid ORDER BY json_each.key"
		match db.query!(q, [{ name: ":aid", value: Integer(aid) }, { name: ":p", value: String(path) }]) {
			Err(_) => []
			Ok(rows) => List.keep_oks(
				rows,
				|r| {
					v = r.f64("v") ? |_| "bad v"
					Ok(v)
				},
			)
		}
	}

	# the (elapsed_second, cumulative_metres) pairs both pace consumers read
	load_dist_pairs! : Sqlite.Db, I64 => List({ t : I64, v : F64 })
	load_dist_pairs! = |db, aid| {
		times = load_stream_arr!(db, aid, "$.time.data")
		dists = load_stream_arr!(db, aid, "$.distance.data")
		List.map2(times, dists, |tt, dv| { t: (tt).round_to_i64_try().ok_or(0), v: dv })
	}

	load_trace_pace! : Sqlite.Db, I64 => List(F32)
	load_trace_pace! = |db, aid| {
		speeds = List.map(Series.speed_1s(load_dist_pairs!(db, aid)), |p| p.v)
		bucket_mean(speeds, 800)
	}

	# the same rows the CLI's activity screen prints, computed by the same
	# core.Series body; the split length comes from the caller, who owns the
	# athlete's units. Altitude and HR pass empty - the panel beside a trace
	# says distance and pace, and the trace itself already tells the effort.
	# A strength session's stored sets, in the order strength_sets keeps them
	# (one row per run of identical sets, as either adapter writes it), and
	# whether its description holds text that yielded no rows: the fact
	# `stride strength` counts as pasted_unparsed, distinct from never pasted.
	SetRow : { exercise : Str, sets : I64, reps : I64, kg : F64, hold_s : I64 }
	StrengthLog : { rows : List(SetRow), pasted : Bool }
	load_sets! : Sqlite.Db, I64 => StrengthLog
	load_sets! = |db, aid| {
		rows = match db.query!("SELECT CAST(exercise AS TEXT) AS sx, CAST(COALESCE(sets, 0) AS INTEGER) AS sn, CAST(COALESCE(reps, 0) AS INTEGER) AS sr, CAST(COALESCE(weight_kg, 0) AS REAL) AS skg, CAST(COALESCE(hold_s, 0) AS INTEGER) AS shs FROM strength_sets WHERE activity_id = :a ORDER BY ordinal", [{ name: ":a", value: Integer(aid) }]) {
			Err(_) => []
			Ok(rs) =>
				List.keep_oks(
					rs,
					|r| {
						ex = r.str("sx") ? |_| "bad sx"
						sn = r.i64("sn") ? |_| "bad sn"
						sr = r.i64("sr") ? |_| "bad sr"
						kg = r.f64("skg") ? |_| "bad skg"
						hs = r.i64("shs") ? |_| "bad shs"
						Ok({ exercise: ascii_safe(ex), sets: sn, reps: sr, kg, hold_s: hs })
					},
				)
		}
		pasted = match db.query!("SELECT (COALESCE(CAST(description AS TEXT), '') <> '') AS pz FROM strength_notes WHERE activity_id = :a", [{ name: ":a", value: Integer(aid) }]) {
			Ok(rs) => match List.first(rs) {
				Ok(r) => (r.i64("pz") ?? 0) == 1
				Err(_) => Bool.False
			}
			Err(_) => Bool.False
		}
		{ rows, pasted }
	}

	# ── the strength view's data. The strength family is Sports' own, under
	# its head sport type, the same head activity_family_month files every
	# strength session under, so Workout and WeightTraining read as one.
	LiftPt : { day : Str, kg : F64 }
	Lift : { exercise : Str, points : List(LiftPt) }
	StrengthWeek : { mon : Str, total : I64, with_sets : I64 }
	TonMonth : { month : Str, kg : F64, covered : I64, total : I64, partial : Bool }
	LastLift : { id : I64, day : Str, name : Str, log : StrengthLog }
	Unlogged : { day : Str, name : Str }
	StrengthView : { lifts : List(Lift), last : LastLift, unlogged : List(Unlogged), weeks : List(StrengthWeek), tonnage : List(TonMonth), mass : [Metric, Imperial] }

	empty_strength_view : StrengthView
	empty_strength_view = { lifts: [], last: { id: -1, day: "", name: "", log: { rows: [], pasted: Bool.False } }, unlogged: [], weeks: [], tonnage: [], mass: Metric }

	# Which session the strength view shows: the newest one with sets stored,
	# and every newer session that has none, so a class taken without logging
	# never hides the last lifting the athlete did record. Sessions arrive
	# newest first; with none logged the newest is shown with its absence.
	RecentLift : { id : I64, day : Str, name : Str, has_sets : Bool }
	pick_last : List(RecentLift) -> { shown : [Shown(RecentLift), NoneYet], newer : List(Unlogged) }
	pick_last = |recent| {
		newer = List.map(List.take_first(recent, (List.find_first_index(recent, |r| r.has_sets)).ok_or(0)), |r| { day: r.day, name: r.name })
		shown = match List.find_first(recent, |r| r.has_sets) {
			Ok(r) => Shown(r)
			Err(_) =>
				match List.first(recent) {
					Ok(r) => Shown(r)
					Err(_) => NoneYet
				}
		}
		{ shown, newer }
	}

	# The unit the strength view weighs in. A set `units` config decides it.
	# Unset, the stored weights decide: an athlete who loads plates and
	# dumbbells in pounds stores whole pounds (25 lb is 11.34 kg), one who
	# loads in kilograms stores whole or half kilograms, and the larger group
	# wins, pounds on a tie.
	mass_units : Str, List(F64) -> [Metric, Imperial]
	mass_units = |config, kgs|
		if config != "" {
			Units.units_of(config)
		} else {
			whole = |v| (v - I64.to_f64((F64.round_to_i64_try(v)) ?? 0)).abs() < 0.06
			lb_n = List.len(List.keep_if(kgs, |k| k > 0.0 and whole(k / Units.lb_kg)))
			kg_n = List.len(List.keep_if(kgs, |k| k > 0.0 and whole(k * 2.0)))
			if (lb_n >= kg_n) Imperial else Metric
		}

	strength_head : Str
	strength_head = (List.first(Sports.family("strength"))).ok_or("WeightTraining")

	# rows of (exercise, day, heaviest weight that day), ordered by exercise
	# then day, folded into one Lift per exercise. A lift needs two days to
	# show a direction, so a single-day lift is left out; the most-trained
	# lift (most days) comes first.
	lifts_from_rows : List({ exercise : Str, day : Str, kg : F64 }) -> List(Lift)
	lifts_from_rows = |rows| {
		by_lift = List.fold(
			rows,
			[],
			|acc, r|
				match List.last(acc) {
					Ok(l) if l.exercise == r.exercise => List.append(List.take_first(acc, List.len(acc) - 1), { ..l, points: List.append(l.points, { day: r.day, kg: r.kg }) })
					_ => List.append(acc, { exercise: r.exercise, points: [{ day: r.day, kg: r.kg }] })
				},
		)
		List.sort_with(
			List.keep_if(by_lift, |l| List.len(l.points) >= 2),
			|a, b| {
				na = List.len(a.points)
				nb = List.len(b.points)
				if (na >= nb) Before else After
			},
		)
	}

	load_strength_view! : Sqlite.Db, Str => StrengthView
	load_strength_view! = |db, today_mod| {
		head = strength_head
		lift_rows = match db.query!("SELECT CAST(s.exercise AS TEXT) AS lx, CAST(substr(a.start_local, 1, 10) AS TEXT) AS ld, CAST(MAX(s.weight_kg) AS REAL) AS lkg FROM strength_sets s JOIN activities a ON a.id = s.activity_id WHERE s.weight_kg > 0 AND s.reps > 0 GROUP BY s.exercise, substr(a.start_local, 1, 10) ORDER BY s.exercise, substr(a.start_local, 1, 10)", []) {
			Err(_) => []
			Ok(rs) =>
				List.keep_oks(
					rs,
					|r| {
						ex = r.str("lx") ? |_| "bad lx"
						d = r.str("ld") ? |_| "bad ld"
						kg = r.f64("lkg") ? |_| "bad lkg"
						Ok({ exercise: ascii_safe(ex), day: d, kg })
					},
				)
		}
		recent = match db.query!("SELECT a.id AS sid, CAST(substr(a.start_local, 1, 10) AS TEXT) AS sd, CAST(COALESCE(a.name, '') AS TEXT) AS sn, EXISTS (SELECT 1 FROM strength_sets s WHERE s.activity_id = a.id) AS shs FROM activities a JOIN activity_family_month fm ON fm.activity_id = a.id WHERE fm.fam = :h ORDER BY a.start_local DESC LIMIT 30", [{ name: ":h", value: String(head) }]) {
			Err(_) => []
			Ok(rs) =>
				List.keep_oks(
					rs,
					|r| {
						sid = r.i64("sid") ? |_| "bad sid"
						sd = r.str("sd") ? |_| "bad sd"
						sn = r.str("sn") ? |_| "bad sn"
						hs = r.i64("shs") ? |_| "bad shs"
						Ok({ id: sid, day: sd, name: ascii_safe(sn), has_sets: hs == 1 })
					},
				)
		}
		picked = pick_last(recent)
		last = match picked.shown {
			Shown(r) => { id: r.id, day: r.day, name: r.name, log: load_sets!(db, r.id) }
			NoneYet => empty_strength_view.last
		}
		config_units = match db.query!("SELECT CAST(value AS TEXT) AS v FROM config WHERE key = 'units'", []) {
			Ok(rs) => (List.first(rs)).map_ok(|r| r.str("v") ?? "").ok_or("")
			Err(_) => ""
		}
		kgs = match db.query!("SELECT CAST(weight_kg AS REAL) AS w FROM strength_sets WHERE weight_kg > 0", []) {
			Ok(rs) => List.keep_oks(rs, |r| r.f64("w"))
			Err(_) => []
		}
		weeks = match db.query!("WITH RECURSIVE w(mon, k) AS (SELECT date(date('now', '${today_mod}'), '-6 days', 'weekday 1'), 0 UNION ALL SELECT date(mon, '-7 days'), k + 1 FROM w WHERE k < 11), s AS (SELECT date(substr(a.start_local, 1, 10), '-6 days', 'weekday 1') AS m, CASE WHEN EXISTS (SELECT 1 FROM strength_sets ss WHERE ss.activity_id = a.id) THEN 1 ELSE 0 END AS ws FROM activities a JOIN activity_family_month fm ON fm.activity_id = a.id WHERE fm.fam = :h) SELECT CAST(w.mon AS TEXT) AS wm, CAST(COUNT(s.m) AS INTEGER) AS wn, CAST(COALESCE(SUM(s.ws), 0) AS INTEGER) AS wws FROM w LEFT JOIN s ON s.m = w.mon GROUP BY w.mon ORDER BY w.mon", [{ name: ":h", value: String(head) }]) {
			Err(_) => []
			Ok(rs) =>
				List.keep_oks(
					rs,
					|r| {
						m = r.str("wm") ? |_| "bad wm"
						n = r.i64("wn") ? |_| "bad wn"
						ws = r.i64("wws") ? |_| "bad wws"
						Ok({ mon: m, total: n, with_sets: ws })
					},
				)
		}
		tonnage = match db.query!("SELECT CAST(c.month AS TEXT) AS tm, CAST(c.covered AS INTEGER) AS tc, CAST(c.total AS INTEGER) AS tt, CAST(COALESCE((SELECT SUM(s.sets * s.reps * s.weight_kg) FROM strength_sets s JOIN activity_family_month f2 ON f2.activity_id = s.activity_id WHERE f2.fam = c.fam AND f2.month = c.month), 0) AS REAL) AS tkg, (c.month = strftime('%Y-%m', date('now', '${today_mod}'))) AS tp FROM strength_coverage c ORDER BY c.month", []) {
			Err(_) => []
			Ok(rs) =>
				List.keep_oks(
					rs,
					|r| {
						m = r.str("tm") ? |_| "bad tm"
						cv = r.i64("tc") ? |_| "bad tc"
						tt = r.i64("tt") ? |_| "bad tt"
						kg = r.f64("tkg") ? |_| "bad tkg"
						pt = r.i64("tp") ? |_| "bad tp"
						Ok({ month: m, kg, covered: cv, total: tt, partial: pt == 1 })
					},
				)
		}
		{ lifts: lifts_from_rows(lift_rows), last, unlogged: picked.newer, weeks, tonnage: List.take_last(tonnage, 12), mass: mass_units(config_units, kgs) }
	}

	load_splits! : Sqlite.Db, I64, F64 => List(Series.Split)
	load_splits! = |db, aid, split_m|
		Series.splits(load_dist_pairs!(db, aid), [], [], split_m)

	# mean each consecutive bucket so n values become at most `cap` - the
	# downsample that keeps a noisy series' LEVEL instead of sampling its
	# jitter. Pure, so the property is pinned here rather than eyeballed.
	bucket_mean : List(F64), U64 -> List(F32)
	bucket_mean = |xs, cap| {
		n = List.len(xs)
		if n == 0 or cap == 0 {
			[]
		} else {
			size = (n + cap - 1) // cap
			walked = List.fold(
				xs,
				{ out: [], acc: 0.0.F64, m: 0.U64 },
				|st, x|
					if st.m + 1 == size {
						{ out: List.append(st.out, mean_mm(st.acc + x, size)), acc: 0.0.F64, m: 0.U64 }
					} else {
						{ out: st.out, acc: st.acc + x, m: st.m + 1 }
					},
			)
			if (walked.m > 0) (List.append(walked.out, mean_mm(walked.acc, walked.m))) else walked.out
		}
	}

	# F64 reaches F32 through a millimetre-per-second integer - this
	# toolchain has no direct narrowing, and mm/s sits far beneath what a
	# 1 Hz GPS speed actually carries
	mean_mm : F64, U64 -> F32
	mean_mm = |s, m|
		I64.to_f32(((s / (m).to_f64()) * 1000.0).round_to_i64_try().ok_or(0)) / 1000.0

	expect bucket_mean([1.0, 3.0, 5.0, 7.0], 2) == [2.0, 6.0]
	expect bucket_mean([1.0, 2.0], 800) == [1.0, 2.0]
	expect bucket_mean([], 800) == []
	# a partial tail bucket is meaned over ITS OWN length, not the full size
	expect bucket_mean([2.0, 4.0, 9.0], 2) == [3.0, 9.0]

	# The detector's blocks for the same activity, in seconds from the start.
	load_segs! : Sqlite.Db, I64 => List(Seg)
	load_segs! = |db, aid| {
		q = "SELECT CAST(kind AS TEXT) AS kind, start_s, dur_s FROM activity_segments WHERE activity_id = :aid ORDER BY ordinal"
		match db.query!(q, [{ name: ":aid", value: Integer(aid) }]) {
			Err(_) => []
			Ok(rows) => List.keep_oks(
				rows,
				|r| {
					k = r.str("kind") ? |_| "bad kind"
					s = r.i64("start_s") ? |_| "bad start"
					d = r.i64("dur_s") ? |_| "bad dur"
					Ok({ kind: k, start_s: s, dur_s: d })
				},
			)
		}
	}

	# The session's own duration, from the stream's last timestamp. BOTH axes in the
	# trace view divide by this: the segments are in seconds and the trace is a
	# uniform downsample of the same session, so sharing one denominator is what
	# keeps the shading aligned with the line. Deriving it from the SEGMENTS instead
	# would stretch partial coverage across the full width; on a fully covered
	# session the two agree to within a second, so only partial coverage shows
	# the difference.
	load_dur! : Sqlite.Db, I64 => F32
	load_dur! = |db, aid|
		match db.query!("SELECT CAST(json_extract(raw_json,'$.time.data[#-1]') AS INTEGER) AS t FROM streams WHERE activity_id = :aid", [{ name: ":aid", value: Integer(aid) }]) {
			Err(_) => 1.0
			Ok(rows) => match List.first(rows) {
				Err(_) => 1.0
				Ok(r) => match r.i64("t") {
					Ok(v) => if (v > 0) (I64.to_f32(v)) else 1.0
					Err(_) => 1.0
				}
			}
		}

	# The number that follows `"<key>":` in a JSON object, as text. A scan for
	# one key rather than a parse of the whole document, and one key at a time,
	# so key ORDER cannot silently break it. "" when the key is absent, which
	# the caller reads as "the engine did not answer" rather than as a zero.
	# the string value that follows a key, up to its closing quote, and "" for a
	# key the document does not carry or whose value is not a string. The
	# engine's values here are test kinds and dates, which hold no escapes.
	json_string : Str, Str -> Str
	json_string = |doc, key|
		match Str.split_on(doc, "\"${key}\":\"") {
			[_, rest, ..] =>
				match Str.split_on(rest, "\"") {
					[v, ..] => v
					_ => ""
				}

			_ => ""
		}

	json_number : Str, Str -> Str
	json_number = |doc, key|
		match Str.split_on(doc, "\"${key}\":") {
			[_, rest, ..] => {
				# the run of numeric bytes that opens the remainder; `done`
				# freezes the accumulator at the first byte that cannot be part
				# of a JSON number, so a later digit elsewhere is never joined on
				taken = List.fold(
					Str.to_utf8(rest),
					{ out: [], done: Bool.False },
					|acc, b|
						if acc.done {
							acc
						} else if (b >= '0' and b <= '9') or b == '-' or b == '+' or b == '.' or b == 'e' or b == 'E' {
							{ ..acc, out: List.append(acc.out, b) }
						} else {
							{ ..acc, done: Bool.True }
						},
				)
				match Str.from_utf8(taken.out) {
					Ok(s) => s
					Err(_) => ""
				}
			}
			_ => ""
		}

	# CP / W' / r2 come from the ENGINE, not from a second regression here: the
	# fit is Metrics.hyperbolic_fit's job and a copy would drift from it. The
	# engine binary is run directly, with no shell between: the window names
	# `stride` in its grants, so no interpreter is handed an argument here. A
	# field that does not parse is -1, and the view says the fit
	# is unavailable rather than drawing a fit of zeros.
	# The last day the written plan reaches beyond the series - the latest open
	# session after series_clock's today - capped at the next event, or ""
	# when nothing is planned ahead. Past that day a projection is the decay
	# of an unwritten plan, so the board projects no further than this.
	load_plan_horizon! : Sqlite.Db => Str
	load_plan_horizon! = |db|
		match db.query!("SELECT CAST(COALESCE(MIN(MAX(target_date), COALESCE((SELECT MIN(event_date) FROM events WHERE event_date >= (SELECT today FROM series_clock)), '9999-12-31')), '') AS TEXT) AS hz FROM planned_sessions WHERE COALESCE(status, 'open') = 'open' AND target_date > (SELECT today FROM series_clock)", []) {
			Err(_) => ""
			Ok(rows) => match List.first(rows) {
				Ok(r) => r.str("hz") ?? ""
				Err(_) => ""
			}
		}

	# `stride project <date>` read for the board: the engine's own walk over
	# the recorded plan, so the window shows exactly the numbers the command
	# returns. `considered` is the open sessions in the window, `projected`
	# the ones whose target the engine priced into a load, and `days` the
	# payload's series, the walk day by day to the plan's last day.
	Projection : { ok : Bool, ctl : F32, tsb : F32, considered : I64, projected : I64, days : List(ProjDay) }

	# one projected day: its date, state and priced load, and whether every
	# session on it was priced
	ProjDay : { day : Str, ctl : F32, atl : F32, tsb : F32, tss : F32, known : Bool }

	no_projection : Projection
	no_projection = { ok: Bool.False, ctl: 0.0, tsb: 0.0, considered: 0, projected: 0, days: [] }

	# The series array is cut out before the top-level keys are read: its
	# rows carry `ctl`, `atl` and `tsb` too, and a key scan reads the first
	# match. Its rows hold no nested array, so the first `]` closes it. A row
	# missing a field fails the whole series, and the board then draws none.
	parse_projection : Str -> Projection
	parse_projection = |out| {
		cut = match Str.split_on(out, "\"series\":[") {
			[head, rest] =>
				match Str.split_first(rest, "]") {
					Ok({ before, after }) => { top: "${head}${after}", rows: before }
					Err(_) => { top: out, rows: "" }
				}

			_ => { top: out, rows: "" }
		}
		num = |key| F32.from_str(json_number(cut.top, key))
		int = |key| I64.from_str(json_number(cut.top, key))
		days = List.map_try(
			List.keep_if(Str.split_on(cut.rows, "},{"), |r| r != ""),
			|r| {
				f = |key| F32.from_str(json_number(r, key))
				Ok({ day: json_string(r, "date"), ctl: f("ctl")?, atl: f("atl")?, tsb: f("tsb")?, tss: f("load")?, known: Str.contains(r, "\"load_known\":true") })
			},
		)
		match (num("ctl"), num("tsb"), int("sessions_considered"), int("sessions_projected"), days) {
			(Ok(c), Ok(t), Ok(sc), Ok(sp), Ok(ds)) => if (Str.contains(cut.top, "\"baseline_known\":true")) { ok: Bool.True, ctl: c, tsb: t, considered: sc, projected: sp, days: ds } else no_projection
			_ => no_projection
		}
	}

	load_projection! : Cmd.Runner, Str => Projection
	load_projection! = |runner, day| {
		out = match runner.run_utf8!(Cmd.with_args(Cmd.new("stride"), ["project", day, "--json"])) {
			Ok(o) => if (o.exit_code == 0) o.stdout else ""
			Err(_) => ""
		}
		parse_projection(out)
	}

	# the engine's fit for a curve key: CP and W' from `stride power-curve`
	# for a family, critical speed (m/s) and D' (m) from `stride pace-curve`
	# for a pace sport, carried in the same four fields; the test in force;
	# and the family's threshold today as the engine scores with it (FTP in
	# watts, or a threshold speed in m/s), with whether the test set it
	load_fit! : Cmd.Runner, I64, Str => { fit : Fit, test : TestAnchor, thr : F32, from_test : Bool }
	load_fit! = |runner, days, curve| {
		args = match Bus.curve_key(curve) {
			Pace(sp) => ["pace-curve", I64.to_str(days), sp, "--json"]
			Power(fam) => ["power-curve", I64.to_str(days), fam, "--json"]
		}
		pace = Str.starts_with(curve, Bus.pace_prefix)
		threshold_key = if (pace) "cs" else "cp"
		reserve_key = if (pace) "d_prime" else "w_prime"
		out = match runner.run_utf8!(Cmd.with_args(Cmd.new("stride"), args)) {
			Ok(o) => if (o.exit_code == 0) o.stdout else ""
			Err(_) => ""
		}
		num = |key| match F32.from_str(json_number(out, key)) {
			Ok(v) => v
			Err(_) => -1.0
		}
		cp = num(threshold_key)
		wp = num(reserve_key)
		r2 = num("fit_r2")
		fp = num("fit_points")
		tv = num("test_value")
		thr = num(if (pace) "threshold_speed" else "ftp_w")
		{
			fit: { cp, w_prime: wp, r2, points: fp, ok: cp >= 0.0 and wp >= 0.0 and r2 >= 0.0 and fp >= 0.0 },
			test: { value: if (tv > 0.0) tv else 0.0, kind: json_string(out, "test_kind"), date: json_string(out, "test_date") },
			thr: if (thr > 0.0) thr else 0.0,
			from_test: json_string(out, if (pace) "threshold_source" else "ftp_source") == "test",
		}
	}

	find_idx = |days, target|
		List.fold(
			List.map_with_index(days, |d, i| { day: d, index: i }),
			{ found: Bool.False, idx: 0.U64 },
			|acc, x| if (x.day == target) ({ found: Bool.True, idx: x.index }) else acc,
		)

	# ── the map view's data ────────────────────────────────────────────────
	# one session's route as the map draws it, in metres from the map's
	# origin, in the style its kind names (Map.style), with its extent for
	# culling. `pts` keeps no two points closer than two metres, `far` none
	# closer than forty, for the zooms where forty metres is a few pixels: a
	# full backfill holds millions of points, and every repaint walks the
	# list it draws. A route with times keeps each kept point's seconds since
	# its start in `ts` and `fts`, aligned with `pts` and `far`, for
	# playback; one without times keeps none. `bands` and `fbands` hold each
	# segment's speed band for the two lists (Motion.banded), empty until
	# playback first shows the map (with_bands), so the routes and the heat
	# never pay for them. `session` is the session the route belongs to, as
	# a click on the route names it (RouteSession).
	MapLine : { kind : U8, pts : List(Geo.Pt), ts : List(F32), far : List(Geo.Pt), fts : List(F32), bands : List(U8), fbands : List(U8), box : Geo.Bounds, session : RouteSession }

	# A route's session as the map's card states it: the activity id; its
	# start in seconds since 1970, read from Strava's local start, the only
	# start an activity row stores, and the key the most recent of several
	# routes under one click wins by; its name, day and sport type; its
	# distance in metres and moving time in seconds; and its average watts,
	# 0 when none were recorded or Strava marked them estimated
	# (device_watts 0). Analyze reads an unmarked row's watts as measured
	# and scores nothing from an estimate, and so does the card.
	RouteSession : { id : I64, start : I64, name : Str, day : Str, sport : Str, dist_m : F64, moving_s : I64, watts : I64 }

	no_session : RouteSession
	no_session = { id: -1, start: 0, name: "", day: "", sport: "", dist_m: 0.0, moving_s: 0, watts: 0 }

	# every route, all relative to one origin, and that origin in projected
	# metres, which places the street map's tiles; the routes' extent, which
	# the map opens on; where the routes gather, for when that extent is too
	# wide to show (Geo.opening); and why a read failed, empty when none did
	MapData : { routes : List(MapLine), origin : { x : F64, y : F64 }, fit : Geo.Bounds, focus : Geo.Focus, err : Str }

	no_map : MapData
	no_map = { routes: [], origin: { x: 0.0, y: 0.0 }, fit: Geo.no_box, focus: { box: Geo.no_box, anchor: { x: 0.0, y: 0.0 } }, err: "" }

	route_kind : U8
	route_kind = 9

	# the spacing, in metres, of a map line's near and far point lists
	near_step : F32
	near_step = 2.0

	far_step : F32
	far_step = 40.0

	# the projected line of a list of coordinates, with each one's seconds
	# since the start when the route has times and none when it has not;
	# fewer than two points draw nothing, so they make no line
	map_line : { x : F64, y : F64 }, U8, List({ lat : F64, lng : F64 }), List(F32) -> Try(MapLine, [TooShort])
	map_line = |origin, kind, coords, times|
		if List.len(coords) < 2 {
			Err(TooShort)
		} else if List.is_empty(times) {
			pts = Geo.thin(List.map(coords, |c| Geo.rel(origin, c.lat, c.lng)), near_step)
			Ok({ kind, pts, ts: [], far: Geo.thin(pts, far_step), fts: [], bands: [], fbands: [], box: Geo.box_of(pts), session: no_session })
		} else {
			near = Geo.thin_timed(List.map(coords, |c| Geo.rel(origin, c.lat, c.lng)), times, near_step)
			far = Geo.thin_timed(near.pts, near.ts, far_step)
			Ok({ kind, pts: near.pts, ts: near.ts, far: far.pts, fts: far.ts, bands: [], fbands: [], box: Geo.box_of(near.pts), session: no_session })
		}

	# every route's speed bands for both of its lists, each measured against
	# the route's moving speed over its far list; a route without times
	# keeps none
	with_bands : MapData -> MapData
	with_bands = |m| {
		..m,
		routes: List.map(
			m.routes,
			|l|
				if List.is_empty(l.ts) {
					l
				} else {
					ref = Motion.moving_speed(l.far, l.fts)
					{ ..l, bands: Motion.banded(l.pts, l.ts, ref), fbands: Motion.banded(l.far, l.fts, ref) }
				},
		),
	}

	# a failed read, named for the athlete
	query_err : Str, [SqliteErr(_, Str), ResultTooLarge, MultipleStatements] -> Str
	query_err = |what, e|
		match e {
			SqliteErr(_, msg) => "could not read ${what}: ${msg}"
			ResultTooLarge => "could not read ${what}: one page is larger than the window reads at once"
			MultipleStatements => "could not read ${what}"
		}

	# The window's SQLite binding refuses a query whose result passes a byte
	# budget rather than returning part of it, and one stored route answer
	# runs to hundreds of kilobytes, so routes are read in pages keyed by
	# id. A page of routes is decoded by the engine's own rule (core.Route)
	# as it lands, keeping the coordinates and their times, beside the
	# session each belongs to (route_session). A route whose session row is
	# missing keeps its id and reads empty.
	route_page_size : I64
	route_page_size = 16

	Track : { coords : List({ lat : F64, lng : F64 }), times : List(F32), session : RouteSession }

	route_page_sql : Str
	route_page_sql = "SELECT r.activity_id AS id, CAST(r.raw_json AS TEXT) AS j, CAST(COALESCE(strftime('%s', a.start_local), 0) AS INTEGER) AS t, CAST(COALESCE(a.name, '') AS TEXT) AS nm, CAST(COALESCE(substr(a.start_local, 1, 10), '') AS TEXT) AS dy, CAST(COALESCE(a.sport_type, '') AS TEXT) AS sp, CAST(COALESCE(a.distance, 0) AS REAL) AS dm, CAST(COALESCE(a.moving_time, 0) AS INTEGER) AS mt, CAST(CASE WHEN COALESCE(a.device_watts, 1) <> 0 THEN ROUND(COALESCE(a.avg_watts, 0)) ELSE 0 END AS INTEGER) AS w FROM routes r LEFT JOIN activities a ON a.id = r.activity_id WHERE r.raw_json IS NOT NULL AND r.raw_json <> '{}' AND r.activity_id > :a ORDER BY r.activity_id LIMIT :n"

	# a route row's session; its names pass the same gate and cap the trace
	# picker's do, since the brand atlases carry ASCII
	route_session : I64, Sqlite.Row -> RouteSession
	route_session = |id, r| {
		id,
		start: r.i64("t") ?? 0,
		name: cap_name(ascii_safe(r.str("nm") ?? "")),
		day: r.str("dy") ?? "",
		sport: r.str("sp") ?? "",
		dist_m: r.f64("dm") ?? 0.0,
		moving_s: r.i64("mt") ?? 0,
		watts: r.i64("w") ?? 0,
	}

	route_pages! : Sqlite.Db, I64, List(Track) => Try(List(Track), Str)
	route_pages! = |db, after, acc|
		match db.query!(route_page_sql, [{ name: ":a", value: Integer(after) }, { name: ":n", value: Integer(route_page_size) }]) {
			Err(e) => Err(query_err("the routes", e))
			Ok(rs) =>
				match List.last(rs) {
					Err(_) => Ok(acc)
					Ok(last) => {
						tracks = List.keep_oks(
							rs,
							|r| {
								b = r.str("j") ? |_| BadBody
								id = r.i64("id") ? |_| BadId
								match Route.decode_route(b) {
									Points(ps) => Ok({ coords: List.map(ps, |p| { lat: p.lat, lng: p.lng }), times: List.map(ps, |p| I64.to_f32(p.t)), session: route_session(id, r) })
									_ => Err(NoGps)
								}
							},
						)
						match last.i64("id") {
							Ok(id) => route_pages!(db, id, List.concat(acc, tracks))
							Err(_) => Err("could not read the routes: a route row has no id")
						}
					}
				}
		}

	# A database without the routes table holds no route yet, and draws the
	# empty-map note. Any other failed read is named on the map. The origin
	# is the first route point: anything near the data keeps the F32 metres
	# small. A route is unwrapped across the antimeridian before it is
	# projected.
	load_map! : Sqlite.Db => MapData
	load_map! = |db| {
		has_routes = match db.query!("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'routes'", []) {
			Ok(rs) => (List.first(rs)).map_ok(|r| r.i64("n") ?? 0).ok_or(0) > 0
			Err(_) => Bool.False
		}
		tracks = if (has_routes) route_pages!(db, -9223372036854775807, []) else Ok([])
		ts = List.map(tracks ?? [], |tr| { ..tr, coords: Geo.unwrap(tr.coords) })
		origin = match List.first(ts) {
			Ok(tr) =>
				match List.first(tr.coords) {
					Ok(c) => Geo.merc(c.lat, c.lng)
					Err(_) => { x: 0.0, y: 0.0 }
				}
			Err(_) => { x: 0.0, y: 0.0 }
		}
		routes = List.keep_oks(ts, |tr| map_line(origin, route_kind, tr.coords, tr.times).map_ok(|l| { ..l, session: tr.session }))
		err = match tracks {
			Err(e) => e
			Ok(_) => ""
		}
		{
			routes,
			origin,
			fit: List.fold(routes, Geo.no_box, |b, l| Geo.union(b, l.box)),
			focus: Geo.focus(List.keep_oks(routes, |l| (List.first(l.pts)).map_ok(|p| { start: p, box: l.box }))),
			err,
		}
	}

	# ── the street map's tile cache ────────────────────────────────────────
	# Every tile the window fetches is kept raw in map_tiles, keyed by its
	# zoom, column and row alone, beside the planet build it came from, when
	# it was fetched and when it was last used, both in seconds since 1970;
	# Tiles says why the build is not part of the key, and how the table is
	# held to its budget (Tiles.evicted), which every store enforces. The
	# window is the table's one reader and writer. It creates the table
	# before its first write, and a database without it reads as holding no
	# tile. Like the other mirror tables it holds nothing that cannot be
	# fetched again.
	tiles_ddl : Str
	tiles_ddl = "CREATE TABLE IF NOT EXISTS map_tiles (z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, build TEXT NOT NULL, fetched INTEGER NOT NULL, used INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY (z, x, y))"

	tile_read_sql : Str
	tile_read_sql = "SELECT data AS d, CAST(strftime('%s', 'now') AS INTEGER) - fetched AS age FROM map_tiles WHERE z = :z AND x = :x AND y = :y"

	tile_store_sql : Str
	tile_store_sql = "INSERT INTO map_tiles (z, x, y, build, fetched, used, data) VALUES (:z, :x, :y, :b, CAST(strftime('%s', 'now') AS INTEGER), CAST(strftime('%s', 'now') AS INTEGER), :d) ON CONFLICT (z, x, y) DO UPDATE SET build = excluded.build, fetched = excluded.fetched, used = excluded.used, data = excluded.data"

	# a read marks the tile used, but writes only when its mark is older
	# than Tiles.touch_secs, so panning over cached ground rarely writes
	tile_touch_sql : Str
	tile_touch_sql = "UPDATE map_tiles SET used = CAST(strftime('%s', 'now') AS INTEGER) WHERE z = :z AND x = :x AND y = :y AND used < CAST(strftime('%s', 'now') AS INTEGER) - :t"

	# every stored tile's size and last use; length() of a blob is read from
	# the row's header, never from the bytes
	tile_sizes_sql : Str
	tile_sizes_sql = "SELECT z AS z, x AS x, y AS y, length(data) AS n, used AS u FROM map_tiles"

	tile_drop_sql : Str
	tile_drop_sql = "DELETE FROM map_tiles WHERE z = :z AND x = :x AND y = :y"

	tile_bindings : Tiles.Key -> List({ name : Str, value : Sqlite.Value })
	tile_bindings = |k| [{ name: ":z", value: Integer(U64.to_i64_wrap(k.z)) }, { name: ":x", value: Integer(U64.to_i64_wrap(k.x)) }, { name: ":y", value: Integer(U64.to_i64_wrap(k.y)) }]

	# a cached tile's bytes and its age in seconds; a tile stored with no
	# bytes, as a 204 answer is, reads back as no bytes. A tile found is
	# marked used.
	read_tile! : Sqlite.Db, Tiles.Key => Try({ data : List(U8), age : I64 }, [Absent])
	read_tile! = |db, k| {
		found = match db.query!(tile_read_sql, tile_bindings(k)) {
			Ok(rs) =>
				match List.first(rs) {
					Ok(r) =>
						match (r.nullable_bytes("d"), r.i64("age")) {
							(Ok(NotNull(d)), Ok(a)) => Ok({ data: d, age: a })
							(Ok(Null), Ok(a)) => Ok({ data: [], age: a })
							_ => Err(Absent)
						}
					Err(_) => Err(Absent)
				}
			Err(_) => Err(Absent)
		}
		match found {
			Ok(_) => {
				_ = db.execute!(tile_touch_sql, List.append(tile_bindings(k), { name: ":t", value: Integer(Tiles.touch_secs) }))
				found
			}
			Err(_) => found
		}
	}

	# the table's columns as SQLite reports them
	tile_columns_sql : Str
	tile_columns_sql = "SELECT CAST(name AS TEXT) AS c FROM pragma_table_info('map_tiles')"

	# What brings a map_tiles of an older shape up to tiles_ddl's: a table
	# made before the cache recorded last use lacks `used`, and CREATE TABLE
	# IF NOT EXISTS leaves an existing table as it is, so the column is
	# added, every row reading as never used and so the first to go. The
	# cached tiles are kept: the column is the only difference.
	tiles_upgrade : List(Str) -> List(Str)
	tiles_upgrade = |columns| if (List.contains(columns, "used")) [] else ["ALTER TABLE map_tiles ADD COLUMN used INTEGER NOT NULL DEFAULT 0"]

	# the cache's failures, named for the athlete
	cache_err : Str, [SqliteErr(_, Str), ResultTooLarge, MultipleStatements, RowsReturnedUseQueryInstead] -> Str
	cache_err = |what, e|
		match e {
			SqliteErr(_, msg) => "could not ${what}: ${msg}"
			_ => "could not ${what}"
		}

	# The table made and brought to the current shape (tiles_upgrade).
	ensure_tiles! : Sqlite.Db => Try({}, Str)
	ensure_tiles! = |db| {
		_ = db.execute!(tiles_ddl, []).map_err(|e| cache_err("make the street-map cache", e))?
		columns = match db.query!(tile_columns_sql, []) {
			Ok(rs) => List.keep_oks(rs, |r| r.str("c"))
			Err(e) => return Err(cache_err("read the street-map cache's shape", e))
		}
		var $out = Ok({})
		for sql in tiles_upgrade(columns) {
			match db.execute!(sql, []) {
				Ok(_) => {}
				Err(e) => {
					$out = Err(cache_err("update the street-map cache", e))
				}
			}
		}
		$out
	}

	# A tile stored, then the table held to its budget. A failure of either
	# is answered by name, for the map to show; its caller still draws the
	# tile, and a trim that fails leaves the table to the next store.
	store_tile! : Sqlite.Db, Tiles.Key, Str, List(U8) => Try({}, Str)
	store_tile! = |db, k, build, data| {
		ensure_tiles!(db)?
		_ = db.execute!(tile_store_sql, List.concat(tile_bindings(k), [{ name: ":b", value: String(build) }, { name: ":d", value: Bytes(data) }])).map_err(|e| cache_err("keep a street-map tile", e))?
		trim_tiles!(db, Tiles.cache_budget)
	}

	trim_tiles! : Sqlite.Db, U64 => Try({}, Str)
	trim_tiles! = |db, budget|
		match db.query!(tile_sizes_sql, []) {
			Ok(rs) => {
				rows = List.keep_oks(
					rs,
					|r| {
						z = r.i64("z")?
						x = r.i64("x")?
						y = r.i64("y")?
						n = r.i64("n")?
						u = r.i64("u")?
						Ok({ key: { z: I64.to_u64_wrap(z), x: I64.to_u64_wrap(x), y: I64.to_u64_wrap(y) }, bytes: I64.to_u64_wrap(n), used: u })
					},
				)
				var $out = Ok({})
				for k in Tiles.evicted(rows, budget) {
					match db.execute!(tile_drop_sql, tile_bindings(k)) {
						Ok(_) => {}
						Err(e) => {
							$out = Err(cache_err("trim the street-map cache", e))
						}
					}
				}
				$out
			}
			Err(e) => Err(cache_err("trim the street-map cache", e))
		}
}
# the tile cache's statements and their bindings agree: every placeholder
# each statement names is bound under its own name, the store binds the
# build and the bytes beside the key and sets the last use, the touch binds
# its interval, the key is the table's whole primary key, and the sizes
# read back carry every column the trim decodes
expect {
	names = List.map(Db.tile_bindings({ z: 14, x: 4203, y: 6088 }), |b| b.name)
	store = List.concat(names, [":b", ":d"])
	touch = List.append(names, ":t")
	placeholders = |sql| List.count_if(Str.to_utf8(sql), |c| c == ':')
	names == [":z", ":x", ":y"] and placeholders(Db.tile_read_sql) == 3 and placeholders(Db.tile_store_sql) == 5 and placeholders(Db.tile_touch_sql) == 4 and placeholders(Db.tile_drop_sql) == 3
		and List.all(names, |nm| Str.contains(Db.tile_read_sql, nm) and Str.contains(Db.tile_drop_sql, nm)) and List.all(store, |nm| Str.contains(Db.tile_store_sql, nm)) and List.all(touch, |nm| Str.contains(Db.tile_touch_sql, nm))
		and Str.contains(Db.tiles_ddl, "PRIMARY KEY (z, x, y)") and Str.contains(Db.tile_store_sql, "ON CONFLICT (z, x, y)") and Str.contains(Db.tile_store_sql, "used = excluded.used")
		and List.all(["AS z", "AS x", "AS y", "AS n", "AS u"], |a| Str.contains(Db.tile_sizes_sql, a))
}

expect Db.parse_utc_offset("-0500") == Ok(-300)
expect Db.parse_utc_offset("+0530") == Ok(330)
expect Db.parse_utc_offset("+0000") == Ok(0)
expect Db.parse_utc_offset("INVALID") == Err(BadTz)
expect Db.plain_int("330") == Ok(330)
expect Db.plain_int("-360") == Ok(-360)
expect Db.plain_int("+330") == Err(NotAnInt)
expect Db.plain_int(" 5") == Err(NotAnInt)
expect Db.plain_int("") == Err(NotAnInt)

# the upsert and its bindings agree: every placeholder the SQL names is
# bound under its own name (a named parameter left unbound binds NULL without
# an error, and two bindings of one name leave the other NULL), there
# are no more bindings than placeholders, and every column the INSERT
# names is carried into the row on conflict
expect {
	blank = { view: 0, range: 0, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, detail_day: "", sport: "", family: "", curve_family: "", curve_short: -1, map_id: -1 }
	sql = Bus.focus_upsert_sql
	names = List.map(Db.focus_bindings(blank), |b| b.name)
	colons = List.count_if(Str.to_utf8(sql), |c| c == ':')
	cols = ["view", "range", "cursor_day", "trace_day", "ghost_day", "trace_id", "ghost_id", "detail_day", "sport", "family", "curve_family", "curve_short", "map_id"]
	bound = List.all(names, |nm| Str.contains(sql, Str.concat(nm, ",")) or Str.contains(sql, Str.concat(nm, ")")))
	inserted = List.all(cols, |c| Str.contains(sql, " ${c},") or Str.contains(sql, " ${c})"))
	carried = List.all(cols, |c| Str.contains(sql, "${c} = excluded.${c}"))
	distinct = List.len(List.fold(names, [], |acc, nm| if (List.contains(acc, nm)) acc else List.append(acc, nm))) == List.len(names)
	bound and distinct and colons == List.len(names) and inserted and carried
}
# the engine's power-curve JSON, read one key at a time: the value that
# follows the key, stopping at the byte that ends the number, and "" for a
# key the document does not carry
expect Db.json_number("{\"cp\":243.5,\"w_prime\":21000.0}", "cp") == "243.5"
expect Db.json_number("{\"cp\":243.5,\"w_prime\":21000.0}", "w_prime") == "21000.0"
expect Db.json_number("{\"fit_r2\":-1.25e-3}", "fit_r2") == "-1.25e-3"
expect Db.json_number("{\"cp\":243.5}", "fit_points") == ""
# a key whose value is not a number yields "", never the text beside it
expect Db.json_number("{\"model\":\"power_stream\",\"cp\":9}", "model") == ""
# ...and its string twin: the text between the quotes, "" for an absent key
# or a value that is not a string
expect Db.json_string("{\"test_kind\":\"cp3-12\",\"test_date\":\"2026-11-11\"}", "test_date") == "2026-11-11"
expect Db.json_string("{\"test_kind\":\"\",\"x\":1}", "test_kind") == ""
expect Db.json_string("{\"cp\":243.5}", "cp") == "" and Db.json_string("{\"cp\":243.5}", "test_kind") == ""

# the engine's payload, as `stride project` prints it; a baseline it could
# not measure, or output that is not the payload, projects nothing
expect {
	p = Db.parse_projection("{\"schema_version\":3,\"data\":{\"atl\":40.5,\"baseline_known\":true,\"ctl\":47.92,\"days_away\":4,\"ftp_known\":true,\"hypothetical\":[],\"plan_source\":\"recorded\",\"projected_from\":\"2026-11-04\",\"sessions_considered\":4,\"sessions_projected\":1,\"target_date\":\"2026-11-08\",\"tsb\":7.42}}")
	p.ok and (p.ctl - 47.92).abs() < 0.001 and (p.tsb - 7.42).abs() < 0.001 and p.considered == 4 and p.projected == 1
}
expect !(Db.parse_projection("{\"schema_version\":3,\"data\":{\"atl\":0,\"baseline_known\":false,\"ctl\":0,\"sessions_considered\":0,\"sessions_projected\":0,\"tsb\":0}}").ok)
expect !(Db.parse_projection("").ok)

# the series is read row by row, each row's own fields and flag, and the
# top-level numbers stay the payload's own although every row carries the
# same keys and the series sorts before `tsb`
expect {
	p = Db.parse_projection("{\"schema_version\":3,\"data\":{\"atl\":53.2,\"baseline_known\":true,\"ctl\":54.2,\"days_away\":3,\"ftp_known\":true,\"hypothetical\":[],\"plan_source\":\"recorded\",\"projected_from\":\"2026-11-25\",\"series\":[{\"atl\":55.35,\"ctl\":53.21,\"date\":\"2026-11-26\",\"load\":6.67,\"load_known\":true,\"tsb\":-2.14},{\"atl\":49.1,\"ctl\":52.0,\"date\":\"2026-11-27\",\"load\":0,\"load_known\":false,\"tsb\":2.9},{\"atl\":53.2,\"ctl\":54.2,\"date\":\"2026-11-28\",\"load\":81.5,\"load_known\":true,\"tsb\":1.0}],\"sessions_considered\":3,\"sessions_projected\":2,\"target_date\":\"2026-11-28\",\"tsb\":1.0,\"unprojected\":[{\"date\":\"2026-11-27\",\"reason\":\"no_target\",\"target_literal\":\"\"}]}}")
	near = |a, b| (a - b).abs() < 0.001
	p.ok
		and near(p.ctl, 54.2)
		and near(p.tsb, 1.0)
		and p.considered == 3
		and p.projected == 2
		and List.map(p.days, |d| d.day) == ["2026-11-26", "2026-11-27", "2026-11-28"]
		and List.map(p.days, |d| d.known) == [Bool.True, Bool.False, Bool.True]
		and List.all(List.map2(p.days, [{ c: 53.21, a: 55.35, t: -2.14, l: 6.67 }, { c: 52.0, a: 49.1, t: 2.9, l: 0.0 }, { c: 54.2, a: 53.2, t: 1.0, l: 81.5 }], |d, w| near(d.ctl, w.c) and near(d.atl, w.a) and near(d.tsb, w.t) and near(d.tss, w.l)), |ok| ok)
}

# an empty series parses to no days; a row that lost a field drops the
# whole projection rather than drawing a day of zeros
expect {
	p = Db.parse_projection("{\"data\":{\"atl\":40.5,\"baseline_known\":true,\"ctl\":47.92,\"series\":[],\"sessions_considered\":0,\"sessions_projected\":0,\"tsb\":7.42}}")
	p.ok and List.is_empty(p.days) and (p.tsb - 7.42).abs() < 0.001
}
expect !(Db.parse_projection("{\"data\":{\"atl\":40.5,\"baseline_known\":true,\"ctl\":47.92,\"series\":[{\"atl\":1.0,\"date\":\"2026-11-26\",\"load\":0,\"load_known\":true,\"tsb\":1.0}],\"sessions_considered\":1,\"sessions_projected\":1,\"tsb\":7.42}}").ok)

# thousands group in threes from the right, a sign stays in front, and a
# unit sits one space after the number
expect Db.grouped(0) == "0" and Db.grouped(999) == "999" and Db.grouped(1000) == "1,000" and Db.grouped(13201) == "13,201" and Db.grouped(1000000) == "1,000,000"
expect Db.grouped(-1234) == "-1,234" and Db.grouped(-999) == "-999" and Db.grouped(-9_223_372_036_854_775_807 - 1) == "-9,223,372,036,854,775,808"
expect Db.num_unit(447, "h") == "447 h" and Db.num_unit(13201, "mi") == "13,201 mi"
expect Db.trace_step(0) == 1 and Db.trace_step(800) == 1 and Db.trace_step(1599) == 1 and Db.trace_step(1600) == 2 and Db.trace_step(14349) == 17

# lifts fold per exercise in day order; a one-day lift shows no direction and
# is left out; the lift trained on the most days leads
expect {
	ls = Db.lifts_from_rows([{ exercise: "Curl", day: "2026-10-01", kg: 9.0 }, { exercise: "Curl", day: "2026-10-08", kg: 11.0 }, { exercise: "Press", day: "2026-10-01", kg: 20.0 }, { exercise: "Row", day: "2026-09-01", kg: 13.0 }, { exercise: "Row", day: "2026-09-08", kg: 13.0 }, { exercise: "Row", day: "2026-10-08", kg: 15.0 }])
	List.map(ls, |l| l.exercise) == ["Row", "Curl"] and List.map(ls, |l| List.len(l.points)) == [3, 2]
}
expect Db.strength_head == "WeightTraining"
# the newest session with sets is shown, and the newer unlogged ones are
# named; with nothing logged the newest is shown as it is
expect {
	r = |id, d, hs| { id, day: d, name: "s${I64.to_str(id)}", has_sets: hs }
	p = Db.pick_last([r(3, "2026-11-07", Bool.False), r(2, "2026-11-04", Bool.False), r(1, "2026-11-01", Bool.True)])
	p.shown == Shown(r(1, "2026-11-01", Bool.True)) and List.map(p.newer, |u| u.day) == ["2026-11-07", "2026-11-04"]
}
expect {
	r = |id, d, hs| { id, day: d, name: "s", has_sets: hs }
	p = Db.pick_last([r(2, "2026-11-07", Bool.True), r(1, "2026-11-01", Bool.True)])
	p.shown == Shown(r(2, "2026-11-07", Bool.True)) and List.is_empty(p.newer)
}
expect {
	p = Db.pick_last([{ id: 5, day: "2026-11-07", name: "s", has_sets: Bool.False }])
	p.shown == Shown({ id: 5, day: "2026-11-07", name: "s", has_sets: Bool.False }) and List.is_empty(p.newer)
}
expect Db.pick_last([]).shown == NoneYet
# a set units config decides; unset, whole-pound weights win, and whole or
# half kilograms lose to them only when they are the larger group
expect Db.mass_units("metric", [11.34, 22.68]) == Metric and Db.mass_units("imperial", [10.0, 20.0]) == Imperial
expect Db.mass_units("", [11.3398, 22.6796, 15.9, 10.0]) == Imperial
expect Db.mass_units("", [10.0, 20.0, 12.5, 11.3398]) == Metric

# a single coordinate makes no line. Fifty points 0.0001 degrees of latitude
# apart, about fifteen projected metres each, keep every point in the near
# list and every third, with the last, in the far list, and the box holds
# them all
expect {
	o = Geo.merc(41.88, -87.63)
	coords = List.map_with_index(List.repeat(0, 50), |_, i| { lat: 41.88 + U64.to_f64(i) * 0.0001, lng: -87.63 })
	short = match Db.map_line(o, 1, [{ lat: 41.88, lng: -87.63 }], []) {
		Ok(_) => Bool.False
		Err(TooShort) => Bool.True
	}
	match Db.map_line(o, 1, coords, []) {
		Ok(l) => short and List.len(l.pts) == 50 and List.len(l.far) == 18 and l.box.y1 > 700.0 and l.box.y0.abs() < 0.001
		Err(_) => Bool.False
	}
}

# a route's line keeps each kept point's time beside it, in both lists, and
# no speed bands; with_bands then bands each list segment by segment (a
# steady route at its own speed throughout), and a line with no times keeps
# no times and gets no bands
expect {
	o = Geo.merc(41.88, -87.63)
	coords = List.map_with_index(List.repeat(0, 50), |_, i| { lat: 41.88 + U64.to_f64(i) * 0.0001, lng: -87.63 })
	times = List.map_with_index(coords, |_, i| U64.to_f32(i) * 3.0)
	match (Db.map_line(o, Db.route_kind, coords, times), Db.map_line(o, 1, coords, [])) {
		(Ok(r), Ok(w)) => {
			b = Db.with_bands({ ..Db.no_map, routes: [r, w] })
			rb = (List.first(b.routes)) ?? w
			wb = (List.last(b.routes)) ?? r
			r.ts == times and List.len(r.fts) == List.len(r.far) and List.first(r.fts) == Ok(0.0) and List.last(r.fts) == Ok(147.0) and List.get(r.fts, 1) == Ok(9.0) and List.is_empty(r.bands) and List.is_empty(r.fbands)
				and rb.bands == List.repeat(2, List.len(r.pts) - 1) and rb.fbands == List.repeat(2, List.len(r.far) - 1) and rb.pts == r.pts
				and List.is_empty(w.ts) and List.is_empty(w.fts) and List.is_empty(wb.bands) and List.is_empty(wb.fbands)
		}
		_ => Bool.False
	}
}

# a map_tiles made before last use was recorded gains the column, its rows
# kept, and one of the current shape is left as it is; the column added is
# the one the store and the trim read
expect {
	old = ["z", "x", "y", "build", "fetched", "data"]
	up = Db.tiles_upgrade(old)
	up == ["ALTER TABLE map_tiles ADD COLUMN used INTEGER NOT NULL DEFAULT 0"] and Db.tiles_upgrade(List.append(old, "used")) == []
		and Str.contains(Db.tiles_ddl, "used INTEGER NOT NULL") and Str.contains(Db.tile_sizes_sql, "used AS u")
}

# the coach corner's read: a failed query is not an empty table, no row is
# no directive, and a row is told by its description
expect Db.bus_note_from(Err(Locked), |r| r) == Unreadable
expect Db.bus_note_from(Ok([]), |r| r) == NoDirective
expect Db.bus_note_from(Ok(["newest", "older"]), |r| r) == Note("newest")

# a directive names its view, range and cursor day; an absent field drops
# out, a view the window does not draw is named as ignored, and a directive
# naming nothing is a bare steer
expect Db.directive_text({ at: "11-12 08:14", view: 4, range: 30, cursor_day: "" }) == "11-12 08:14  ->  plan / 30d"
expect Db.directive_text({ at: "11-12 08:14", view: 0, range: -1, cursor_day: "2026-11-10" }) == "11-12 08:14  ->  form @ 2026-11-10"
expect Db.directive_text({ at: "11-12 08:14", view: 42, range: -1, cursor_day: "" }) == "11-12 08:14  ->  view 42 (ignored)"
expect Db.directive_text({ at: "11-12 08:14", view: -1, range: -1, cursor_day: "" }) == "11-12 08:14  ->  steer"

# a session's numbers line names its load as load, and adds normalized
# power only when a meter measured it
expect Db.stats_line({ mins: 62, dist: "42.1km", load: 85, np: 230 }) == "62 min  42.1km  85 load  230 w np"
expect Db.stats_line({ mins: 45, dist: "0.0km", load: 1250, np: 0 }) == "45 min  0.0km  1,250 load"
