import rr.Text
import core.Series
import core.Sports
import Board
import Career
import Chrome
import Curve
import Db
import DisplayScale
import Heat
import Hud
import Labels
import Plan
import Ramp
import Scene
import Strength
import Table
import Theme
import Trace
import Ui
import Zones

Gate :: [].{
	# ── the label gate ──────────────────────────────────────────────────────
	# A headless layout pass of every view over fixture athletes at the
	# minimum, default and wide window sizes. Every scene's placed text, the
	# chrome's included, must hold no two overlapping boxes and no box
	# outside its region (Labels.check), and on every view no text may cover
	# a shape but the one it is written inside (Labels.covers); the boot
	# splash and the XP rail's sheet run the first check alone. The athletes
	# come from the sport families in core.Sports, one per family plus a
	# mixed one carrying a single session of a sport no family holds, and
	# every pace family is also drawn in imperial units. Text is measured
	# with headless fonts carrying the shipped faces' advances, so the gate
	# needs no font file.

	# the data face's metrics as the window loads them: JetBrains Mono's
	# advance is 600 of 1320 units of line height, and the 24 px atlas
	# truncates each advance to whole pixels, 10 at that size, for every glyph
	data_font : Text.Font
	data_font = { ..Text.font_stub, metrics: { base_size: 24.0, line_spacing: 0.0, fallback_index: 0, glyphs: [{ codepoint: 0, advance_x: 10.0, offset_x: 0.0, offset_y: 0.0, width: 10.0, height: 24.0 }] } }

	# the prose face's metrics as the window loads them: Quicksand Medium's
	# advances for the printable ASCII range, scaled to its 24 px atlas (1250
	# units of line height) and truncated the way the atlas truncates them; a
	# code point outside the range measures as the widest glyph
	prose_font : Text.Font
	prose_font = {
		..Text.font_stub,
		metrics: {
			base_size: 24.0,
			line_spacing: 0.0,
			fallback_index: 0,
			glyphs: List.prepend(
				List.map_with_index(quicksand_advances, |a, i| { codepoint: 32 + U64.to_u32_wrap(i), advance_x: a, offset_x: 0.0, offset_y: 0.0, width: a, height: 24.0 }),
				{ codepoint: 0, advance_x: 18.0, offset_x: 0.0, offset_y: 0.0, width: 18.0, height: 24.0 },
			),
		},
	}

	quicksand_advances : List(F32)
	quicksand_advances = [5, 3, 7, 12, 10, 14, 12, 3, 7, 7, 5, 10, 3, 7, 3, 9, 11, 6, 10, 9, 9, 10, 10, 9, 10, 10, 3, 3, 10, 9, 10, 9, 18, 12, 12, 12, 13, 10, 10, 13, 13, 4, 11, 13, 10, 15, 13, 14, 11, 15, 12, 10, 11, 13, 12, 18, 11, 10, 12, 7, 9, 7, 9, 12, 4, 11, 11, 9, 11, 10, 6, 11, 10, 3, 5, 10, 4, 17, 10, 11, 11, 11, 7, 8, 6, 10, 9, 14, 9, 10, 9, 8, 3, 8, 8]

	measure : Scene.Measure
	measure = Scene.measure_with(data_font, prose_font)

	# the window's logical sizes: the minimum, the default window at the
	# default scale and at 100%, and a wide display, each once
	sizes : List({ w : F32, h : F32 })
	sizes = {
		at = |pct, w, h| {
			l = DisplayScale.layout(pct, { w, h })
			{ w: l.w, h: l.h }
		}
		all = [
			at(100, I32.to_f32(DisplayScale.min_width), I32.to_f32(DisplayScale.min_height)),
			at(DisplayScale.default_percent, I32.to_f32(Theme.win_w), I32.to_f32(Theme.win_h)),
			at(100, I32.to_f32(Theme.win_w), I32.to_f32(Theme.win_h)),
			at(100, 2560.0, 1440.0),
		]
		# the default window at the default scale is the minimum layout, so a
		# size listed twice is laid out once
		List.fold(all, [], |acc, sz| if (List.any(acc, |a| (a.w - sz.w).abs() < 0.5 and (a.h - sz.h).abs() < 0.5)) acc else List.append(acc, sz))
	}

	# ── the athletes ────────────────────────────────────────────────────────
	Athlete : { name : Str, units : [Metric, Imperial], sports : List({ sport : Str, sessions : I64 }) }

	# every family's head, in the families table's order
	heads : List(Str)
	heads = List.keep_oks(Sports.families, |f| List.first(f.sports))

	# a strength-like sport no family holds: the mixed athlete's one-off
	rare : Str
	rare = (List.first(List.keep_if(Sports.strength_like, |s| Sports.members(s) == [s]))) ?? "Crossfit"

	athletes : List(Athlete)
	athletes = {
		solo = |h, units, tag| { name: "${h}${tag}", units, sports: [{ sport: h, sessions: 140 }] }
		List.join([
			List.map(heads, |h| solo(h, Metric, " only")),
			List.map(List.keep_if(heads, |h| List.contains(Sports.pace_target_families, h)), |h| solo(h, Imperial, " only, imperial")),
			[{ name: "mixed with one ${rare}", units: Metric, sports: List.append(List.map_with_index(heads, |h, i| { sport: h, sessions: 300 - 40 * U64.to_i64_wrap(i) }), { sport: rare, sessions: 1 }) }],
		])
	}

	athlete_heads : Athlete -> List(Str)
	athlete_heads = |a| List.keep_if(heads, |h| List.any(a.sports, |s| s.sport == h))

	# the curves an athlete has: a power curve for every endurance family, a
	# pace curve for every family a pace unit fits
	curve_keys_of : Athlete -> Db.CurveKeys
	curve_keys_of = |a| {
		hs = athlete_heads(a)
		{ power: List.keep_if(hs, |h| Sports.class(h) == Endurance), pace: List.map(List.keep_if(hs, |h| List.contains(Sports.pace_target_families, h)), |h| "pace:${h}") }
	}

	# ── the calendar the fixtures live on: the last days up to the as-of day,
	# and the months of the career ───────────────────────────────────────────
	today : Str
	today = "2026-11-12"

	# 2026-09-01 is a Tuesday; dow counts Monday as 1
	heat_days : List(Db.HeatDay)
	heat_days = {
		days = List.join([
			List.map(seq(30), |d| "2026-09-${two(d)}"),
			List.map(seq(31), |d| "2026-10-${two(d)}"),
			List.map(seq(12), |d| "2026-11-${two(d)}"),
		])
		List.map_with_index(days, |day, i| { day, tss: if (i % 7 == 3) 0 else 40 + U64.to_i64_wrap(i % 5) * 20, dow: U64.to_i64_wrap((i + 1) % 7) + 1 })
	}

	# 1 through n
	seq : I64 -> List(I64)
	seq = |n| List.map_with_index(List.repeat({}, I64.to_u64_wrap(n)), |_u, i| U64.to_i64_wrap(i) + 1)

	two : I64 -> Str
	two = |n| if (n < 10) "0${I64.to_str(n)}" else I64.to_str(n)

	months : List(Str)
	months = List.join(List.map([2024, 2025, 2026], |y| List.keep_oks(seq(12), |m| if (y == 2026 and m > 11) Err(Future) else Ok("${I64.to_str(y)}-${two(m)}"))))

	# ── the power view's fixtures ───────────────────────────────────────────
	power_rungs : List({ rung : Str, secs : I64, share : F32 })
	power_rungs = [{ rung: "5s", secs: 5, share: 3.2 }, { rung: "15s", secs: 15, share: 2.2 }, { rung: "30s", secs: 30, share: 1.7 }, { rung: "1min", secs: 60, share: 1.35 }, { rung: "5min", secs: 300, share: 1.1 }, { rung: "10min", secs: 600, share: 1.03 }, { rung: "20min", secs: 1200, share: 1.0 }, { rung: "60min", secs: 3600, share: 0.92 }]

	pace_rungs : List({ rung : Str, secs : I64, share : F32 })
	pace_rungs = [{ rung: "5min", secs: 300, share: 1.06 }, { rung: "10min", secs: 600, share: 1.03 }, { rung: "20min", secs: 1200, share: 1.0 }]

	# a 20-minute value for a curve key: 250 W on a power curve; on a pace
	# curve the speed of a plausible pace over the family's own distance
	base_of : Str -> F32
	base_of = |key|
		if Str.starts_with(key, "pace:") {
			fam = Sports.canonical(Str.drop_prefix(key, "pace:"))
			dist = Sports.pace_unit(fam).dist_m
			secs = if (dist >= 1000) 300 else if (dist >= 500) 115 else 95
			I64.to_f32(dist) * 1000.0 / I64.to_f32(secs)
		} else {
			250.0
		}

	round_i : F32 -> I64
	round_i = |v| F32.round_to_i64_try(v) ?? 0

	# One power view per curve key, range and short-rung choice. The range
	# picks the story: 30 days set records this week with a usable fit, 60
	# days fell back from the window before with flat short rungs and no
	# usable fit, 90 days moved both ways with a marked test standing in.
	curve_model : Ui.Model, Athlete, Str, I64, Bool -> Ui.Model
	curve_model = |base, a, key, days, show_short| {
		pace = Str.starts_with(key, "pace:")
		ladder = if (pace) pace_rungs else power_rungs
		b = base_of(key)
		n = List.len(ladder)
		rec = |r| r.share * b
		prs = List.map_with_index(ladder, |r, i| { rung: r.rung, secs: r.secs, w: round_i(rec(r)), day: if (days == 30 and i + 2 >= n) "2026-11-10" else "2026-05-04" })
		now_share = |i| if (days == 30) (if (i + 2 >= n) 1.0 else 0.9) else if (days == 60) (if (i < 4) 0.86 - 0.01 * U64.to_f32(i) else 0.85) else if (i % 2 == 0) 0.93 else 0.97
		prev_share = |i| if (days == 30) 0.88 else if (days == 60) 0.95 else if (i % 3 == 0) 0.99 else 0.94
		pt = |r, share, day, ago| { dur_s: r.secs, watts: I64.to_f32(round_i(rec(r) * share)), aid: 1000 + r.secs, name: "fixture ${r.rung} session", day, ago }
		curve = List.map_with_index(ladder, |r, i| pt(r, now_share(i), if (days == 30 and i + 2 >= n) "2026-11-10" else "2026-10-20", if (days == 30) 2 else days * 2 // 3))
		prev = List.map_with_index(ladder, |r, i| pt(r, prev_share(i), "2026-08-01", days + 10))
		r20 = rec({ rung: "20min", secs: 1200, share: 1.0 })
		fit =
			if days == 30 {
				band = Curve.d_prime_band(Str.drop_prefix(key, "pace:"))
				{ cp: if (pace) r20 * 0.96 / 1000.0 else r20 * 0.96, w_prime: if (pace) (band.lo + band.hi) / 2.0 else 15000.0, r2: 0.95, points: 4.0, ok: Bool.True }
			} else {
				{ cp: if (pace) r20 * 0.9 / 1000.0 else r20 * 0.9, w_prime: if (pace) 2.0 else 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }
			}
		test = if (days == 90) { value: if (pace) r20 * 0.95 / 1000.0 else r20 * 0.95, kind: "cp3-12", date: "2026-10-27" } else { value: 0.0, kind: "none", date: "none" }
		keys = curve_keys_of(a)
		fam = Sports.canonical(Str.drop_prefix(key, "pace:"))
		# a pace target in the unit the athlete reads the family's pace in
		pu = Curve.pace_unit_for(a.units, fam)
		unit = pu.label
		pace_s = round_i(F64.to_f32_wrap(pu.m) * 1000.0 / b)
		{
			..base,
			view: 1,
			units: a.units,
			curve_family: key,
			curve_keys: keys,
			curve_days: days,
			show_short,
			prs,
			curve,
			curve_prev: prev,
			fit_cp: Curve.anchor_line(key, fit, test),
			curve_info: { fit, test, thr: if (pace) r20 * 0.95 / 1000.0 else r20 * 0.95, best20_age: if (days == 60) -1 else 13 },
			plan_targets: [
				{ day: "2026-11-14", typ: "threshold", reps: 2, dur_s: 1200, watts: round_i(r20 * 0.98) },
				{ day: "2026-11-15", typ: "threshold", reps: 3, dur_s: 1200, watts: round_i(r20 * 0.99) },
				{ day: "2026-11-18", typ: "vo2", reps: 5, dur_s: 300, watts: round_i(r20 * 1.08) },
			],
			pace_targets: [
				{ day: "2026-11-14", typ: "threshold", reps: 3, dur_s: 600, dist_m: 0, pace_s, unit },
				{ day: "2026-11-16", typ: "intervals", reps: 6, dur_s: 0, dist_m: 400, pace_s: pace_s - 5, unit },
			],
		}
	}

	curve_models : List({ name : Str, model : Ui.Model })
	curve_models =
		List.join(
			List.map(
				athletes,
				|a| {
					keys = curve_keys_of(a)
					List.join(
						List.map(
							sizes,
							|sz| {
								base = athlete_model(a, sz)
								List.join(
									List.map(
										List.concat(keys.power, keys.pace),
										|key| List.join(List.map([30, 60, 90], |days| List.map([Bool.False, Bool.True], |sh| { name: "${a.name} power ${key} ${I64.to_str(days)}d short=${if (sh) "shown" else "folded"} at ${size_name(sz)}", model: curve_model(base, a, key, days, sh) }))),
									),
								)
							},
						),
					)
				},
			),
		)

	size_name : { w : F32, h : F32 } -> Str
	size_name = |sz| "${I64.to_str(round_i(sz.w))}x${I64.to_str(round_i(sz.h))}"

	# ── the career view's fixtures ──────────────────────────────────────────
	# a family's month-close threshold in tenths: a climb out of a valley to
	# a peak, a two-month gap with no session, and a last month that is the
	# peak again on every other family
	spine_rows : Str, Str, U64 -> List(Db.CareerMonth)
	spine_rows = |fam, kind, k| {
		base = if (kind == "power") 2500.0 else if (kind == "tonnage") 60000.0 else base_of("pace:${fam}") / 100.0
		n = List.len(months)
		List.map_with_index(
			months,
			|m, i| {
				t = U64.to_f32(i) / U64.to_f32(n - 1)
				shape = if (t < 0.3) 1.0 - t else if (t < 0.85) 0.7 + (t - 0.3) * 0.7 else 1.08 - (t - 0.85) * (if (k % 2 == 0) -0.4 else 0.6)
				gap = i == 9 or i == 10
				{ month: m, load: 900 + U64.to_i64_wrap((i * 37) % 600), ftp10: if (gap) 0 else round_i(base * shape), partial: i + 1 == n }
			},
		)
	}

	career_model : Ui.Model, Athlete -> Ui.Model
	career_model = |base, a| {
		hs = athlete_heads(a)
		keys = curve_keys_of(a)
		spines = List.join(
			List.map_with_index(
				hs,
				|h, k| List.join([
					if (List.contains(keys.power, h)) [{ fam: h, kind: "power", rows: spine_rows(h, "power", k) }] else [],
					if (List.contains(keys.pace, "pace:${h}")) [{ fam: h, kind: "pace", rows: spine_rows(h, "pace", k) }] else [],
					if (Sports.class(h) == StrengthLike) [{ fam: h, kind: "tonnage", rows: spine_rows(h, "tonnage", k) }] else [],
				]),
			),
		)
		{
			..base,
			view: 8,
			career_spines: spines,
			career_tests: List.map(keys.power, |h| { fam: h, month: "2026-03", kind: "cp3-12", signal: "power" }),
			career_fam_months: List.join(List.map(hs, |h| List.map_with_index(months, |m, i| { fam: h, month: m, load: 300 + U64.to_i64_wrap((i * 13) % 200), sessions: if (i == 9 or i == 10) 0 else 6 }))),
		}
	}

	career_models : List({ name : Str, model : Ui.Model })
	career_models =
		List.join(
			List.map(
				athletes,
				|a| List.join(
					List.map(
						sizes,
						|sz| {
							m = career_model(athlete_model(a, sz), a)
							List.map_with_index(m.career_spines, |s, i| { name: "${a.name} career ${s.fam} ${s.kind} at ${size_name(sz)}", model: { ..m, spine_idx: i } })
						},
					),
				),
			),
		)

	# ── the model every fixture starts from ─────────────────────────────────
	athlete_model : Athlete, { w : F32, h : F32 } -> Ui.Model
	athlete_model = |a, sz| {
		p = Text.Prepared.stub
		{
			..empty_model(sz),
			units: a.units,
			heat: heat_days,
			career_sports: List.map(a.sports, |s| { sport: s.sport, sessions: s.sessions, hours10: s.sessions * 12, dist_m: if (Sports.class(s.sport) == StrengthLike) 0.0 else I64.to_f64(s.sessions) * 30000.0 }),
			subs: [{ p, r: 30, chip: p }, { p, r: 60, chip: p }, { p, r: 90, chip: p }],
		}
	}

	empty_model : { w : F32, h : F32 } -> Ui.Model
	empty_model = |sz| {
		p = Text.Prepared.stub
		t = { p, s: "", size: 13.0 }
		{
			title: p,
			subs: [],
			leg_fit: p,
			leg_fat: p,
			leg_form: p,
			ylabels: [],
			ends: [],
			ev_label: t,
			ev_found: Bool.False,
			ev_idx: 0,
			ev_warn: t,
			ev_warn_found: Bool.False,
			stale: p,
			stale_found: Bool.False,
			view: 0,
			curve: [],
			curve_prev: [],
			curve_lbls: [],
			fit_lbl: p,
			curve_title: p,
			curve_hint: p,
			trace_hint: p,
			table_hint: p,
			table_title: p,
			table_head: [],
			kpis: [],
			ev_tile_name: [],
			ev_tile_proj: [],
			ev_tile_sub: t,
			zero_note: p,
			ridden_found: Bool.False,
			ridden_note: t,
			curve_empty: p,
			trace: [],
			segs: [],
			trace_dur: 1.0,
			trace_ids: [],
			trace_sel: 0,
			trace_gen: 0,
			trace_refetch: Bool.False,
			trace_loading: Bool.False,
			ghost_loading: Bool.False,
			trace_day: "",
			trace_unit: "W",
			units: Metric,
			trace_splits: [],
			trace_sets: { rows: [], pasted: Bool.False },
			trace_sport: "",
			ghost: [],
			ghost_dur: 1.0,
			ghost_sel: -1,
			ghost_gen: 0,
			ghost_day: "",
			trace_zoom: 1.0,
			lifts_off: 0,
			week_off: 0,
			trace_pan: 0.0,
			trace_cache: [],
			curve_days: 90,
			curve_family: "Ride",
			show_short: Bool.False,
			curve_keys: { power: [], pace: [] },
			pace_targets: [],
			fit_cp: 0.0,
			curve_info: { fit: { cp: 0.0, w_prime: 0.0, r2: 0.0, points: 0.0, ok: Bool.False }, test: { value: 0.0, kind: "none", date: "none" }, thr: 0.0, best20_age: -1 },
			plan_targets: [],
			cp_lbl: p,
			data: [],
			days: [],
			day_notes: [],
			stride_dir: "",
			cwd: "",
			tick: 0,
			last_active: 0,
			view_anim: 0,
			last_focus: { view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, detail_day: "", sport: "", family: "", curve_family: "", curve_short: -1 },
			quitting: Bool.False,
			quit_tick: 0,
			focus_cleared: Bool.False,
			quit_mark_pending: -1,
			status: t,
			has_error: Bool.False,
			booting: Bool.False,
			reloading: Bool.False,
			logo: NoLogo,
			font: data_font,
			prose: prose_font,
			hint: p,
			empty: p,
			range: 90,
			mouse_x: -1.0,
			mouse_y: -1.0,
			win: sz,
			ui_percent: DisplayScale.default_percent,
			ui_scale: 1.0,
			detail_day: "",
			detail: [],
			plan: [],
			week_tss: { this: 0, last: 0 },
			plan_week: { done: 0, total: 0 },
			bus_note: "",
			plan_title: p,
			plan_hint: p,
			nav: List.map([0.U8, 1, 2, 4, 9, 6, 8], |v| { p, v }),
			heat: [],
			strength: Db.empty_strength_view,
			heat_events: [],
			heat_title: p,
			heat_hint: p,
			zone_weeks: [],
			zone_overrides: [],
			career_spines: [],
			career_tests: [],
			career_sports: [],
			career_fam_months: [],
			spine_idx: 0,
			zones_title: p,
			zones_hint: p,
			ramp_weeks: [],
			ramp_title: p,
			ramp_hint: p,
			week_cursor: "",
			prs: [],
			rec_status: Idle,
			pending_capture: NoCapture,
			rec_path: "",
			last_directive: { id: -1, refused: "", result: "" },
			glow: Unbuilt,
			glow_on: Bool.False,
			mouse_in: Bool.False,
			cursor: -1,
		}
	}

	# every fixture's failures under a view's judge, each named by its
	# fixture: empty is a clean gate. roc test reports only that an expect
	# failed, so `dbg` this list inside the expect to read what failed.
	failures : (Ui.Model -> List(Str)), List({ name : Str, model : Ui.Model }) -> List(Str)
	failures = |judge, fixtures| List.join(List.map(fixtures, |f| List.map(judge(f.model), |e| "${f.name}: ${e}")))

	# one scene's failures: two texts that overlap, a text outside its
	# region, and a text over a shape it must keep off
	judge : List(Labels.Owned), List(Labels.Mark) -> List(Str)
	judge = |texts, marks| List.concat(Labels.check(texts), Labels.covers(texts, marks))

	# a prepared copy the gate stands in for: the string and size it was
	# prepared from, which is all the scene measures
	txt : Str, F32 -> Ui.Txt
	txt = |s, size| { p: Text.Prepared.stub, s, size }

	# ── the form board's fixtures ───────────────────────────────────────────
	# the days up to the as-of day, as many as the window's series reads
	series_days : List(Str)
	series_days = List.join([
		List.map(seq(17), |d| "2026-08-${two(d + 14)}"),
		List.map(seq(30), |d| "2026-09-${two(d)}"),
		List.map(seq(31), |d| "2026-10-${two(d)}"),
		List.map(seq(12), |d| "2026-11-${two(d)}"),
	])

	# Two shapes of series, alternating by athlete. A steady one holds form
	# within a few points of zero, so the zero rule sits at the top of the
	# load rug, and its biggest day is the day before the last, a bar that
	# reaches the rule's right end. A building one walks a weekly rhythm
	# through the fitness and fatigue averages with a harder last week,
	# so fatigue runs well above fitness. `k` scales the load, so each
	# athlete's plot differs.
	board_series : U64 -> List(Db.Point)
	board_series = |k| {
		scale = 0.6 + 0.15 * U64.to_f32(k % 7)
		n = List.len(series_days)
		if k % 2 == 0 {
			lean = [-6.0, -2.0, 3.0, 8.0, 4.0, -1.0, -4.0]
			week = [0.0, 55.0, 80.0, 40.0, 90.0, 0.0, 120.0]
			List.map_with_index(
				series_days,
				|_d, i| {
					ctl = (50.0 + U64.to_f32(i % 10) * 0.4) * scale
					d = (List.get(lean, i % 7)) ?? 0.0
					{ ctl, atl: ctl + d, tsb: 0.0 - d, tss: if (i + 2 == n) 150.0 * scale else ((List.get(week, i % 7)) ?? 0.0) * scale }
				},
			)
		} else {
			week = [0.0, 60.0, 85.0, 45.0, 95.0, 0.0, 150.0]
			walk = List.fold(
				List.map_with_index(series_days, |_d, i| i),
				{ ctl: 40.0, atl: 40.0, out: [] },
				|acc, i| {
					t = ((List.get(week, i % 7)) ?? 0.0) * scale * (if (i + 7 >= n) 1.6 else 1.0)
					ctl = acc.ctl + (t - acc.ctl) / 42.0
					atl = acc.atl + (t - acc.atl) / 7.0
					{ ctl, atl, out: List.append(acc.out, { ctl, atl, tsb: acc.ctl - acc.atl, tss: t }) }
				},
			)
			walk.out
		}
	}

	# One board per athlete, range and event state. `ev` picks the event
	# tile's story: 0 an event ahead with a two-line name and a projection,
	# 1 an event today marked on the plot, a recent ridden event and an
	# event record the database could not read.
	board_model : Ui.Model, Athlete, U64, U64, U64 -> Ui.Model
	board_model = |base, a, k, range, ev| {
		data = board_series(k)
		event = "${(List.first(athlete_heads(a))) ?? "Ride"} championship, the long course with every hill"
		name = Board.ev_name(prose_font, event)
		p = Text.Prepared.stub
		{
			..base,
			view: 0,
			range,
			data,
			days: series_days,
			ylabels: List.map([-30, -20, -10, 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100], |v| { p, v: I64.to_f32(v) }),
			ends: List.map([0.U8, 1, 2], |sel| { p, sel }),
			kpis: List.map([0.U8, 1, 2], |sel| { v: p, cap: p, sel }),
			ev_tile_name: List.map(name.lines, |l| txt(l, name.size)),
			ev_tile_sub: txt(if (ev == 0) "in 226d, 2027-06-26" else "today, 2026-11-12", 11.0),
			ev_tile_proj: if (ev == 0) List.map(Board.proj_lines("2026-11-22", "2027-06-26", { ok: Bool.True, ctl: 54.2, tsb: -9.8, considered: 10, projected: 8 }), |l| txt(l, 10.0)) else [],
			ridden_found: ev == 1,
			ridden_note: txt(Board.ev_line(prose_font, event, " done, 3d ago", 10.0), 10.0),
			ev_label: txt(event, 13.0),
			ev_found: ev == 1,
			ev_idx: List.len(series_days) - 1,
			ev_warn: txt("event record unreadable", 13.0),
			ev_warn_found: ev == 1,
			stale_found: Bool.True,
		}
	}

	board_models : List({ name : Str, model : Ui.Model })
	board_models = {
		per_athlete = List.join(
			List.map_with_index(
				athletes,
				|a, k| List.join(
					List.map(
						sizes,
						|sz| {
							base = athlete_model(a, sz)
							List.join(List.map([30.U64, 60, 90], |r| List.map([0.U64, 1], |ev| { name: "${a.name} form ${U64.to_str(r)}d event=${U64.to_str(ev)} at ${size_name(sz)}", model: board_model(base, a, k, r, ev) })))
						},
					),
				),
			),
		)
		# the two boards with no plot: an error loading the series, and a
		# series too short to draw
		bare = List.join(
			List.map(
				sizes,
				|sz| {
					base = empty_model(sz)
					[
						{ name: "form with a load error at ${size_name(sz)}", model: { ..base, view: 0, has_error: Bool.True, status: txt("daily_load query failed - analyzed yet?", 16.0) } },
						{ name: "form with no data at ${size_name(sz)}", model: { ..base, view: 0 } },
					]
				},
			),
		)
		List.concat(per_athlete, bare)
	}

	# ── the session trace's fixtures ────────────────────────────────────────
	# the channel a session plots: power on a ride, pace where a pace unit
	# fits the family, heart rate otherwise
	chan_of : Str -> Str
	chan_of = |sport| {
		fam = Sports.canonical(sport)
		if (Sports.class(fam) == Endurance and !(List.contains(Sports.pace_target_families, fam))) Db.watts_chan else if (List.contains(Sports.pace_target_families, fam)) Db.pace_chan else Db.hr_chan
	}

	# a rise and fall over 100 samples, 0 at either end and 1 at the middle
	tri : U64 -> F32
	tri = |i| {
		t = U64.to_f32(i % 100) / 50.0
		if (t <= 1.0) t else 2.0 - t
	}

	# a session's samples in its channel's own unit: watts, metres per
	# second at the family's plausible pace, or heart rate
	samples_of : Str -> List(F32)
	samples_of = |sport| {
		chan = chan_of(sport)
		at = |i|
			if chan == Db.watts_chan {
				150.0 + 120.0 * tri(i)
			} else if chan == Db.pace_chan {
				base_of("pace:${Sports.canonical(sport)}") / 1000.0 * (0.85 + 0.3 * tri(i))
			} else {
				100.0 + 60.0 * tri(i)
			}
		List.map_with_index(List.repeat({}, 800), |_u, i| at(i))
	}

	# splits at the session's split length, more than the panel holds
	splits_of : [Metric, Imperial], Str -> List(Series.Split)
	splits_of = |units, sport| {
		len = Db.split_len_for(units, sport)
		speed = F32.to_f64(base_of("pace:${Sports.canonical(sport)}")) / 1000.0
		List.map(seq(20), |n| { n, distance_m: len, elapsed_s: F64.round_to_i64_try(len / speed) ?? 0 + n % 3, elev_gain_m: 0.0, elev_known: Bool.False, avg_hr: 0.0, hr_known: Bool.False })
	}

	# stored sets, more than the panel holds, with the long exercise names a
	# pasted log carries and a hold among them
	set_rows : List(Db.SetRow)
	set_rows =
		List.map(
			seq(20),
			|n| {
				names = ["Wide Grip Chest Press", "Dumbbell Pass Through to Push Up", "Tall Kneeling Dumbbell Overhead Press", "Reverse Grip Tricep Kickback", "Plank"]
				name = (List.get(names, I64.to_u64_wrap(n % 5))) ?? "Curl"
				if (name == "Plank") { exercise: name, sets: 3, reps: 0, kg: 0.0, hold_s: 60 } else { exercise: name, sets: 3, reps: 8 + n % 9, kg: 11.3398 + I64.to_f64(n % 4) * 2.268, hold_s: 0 }
			},
		)

	# the athlete's picker: one session per sport, the newest first
	picker_of : Athlete -> List({ id : I64, day : Str, name : Str, sport : Str, chan : Str })
	picker_of = |a| List.map_with_index(a.sports, |s, i| { id: 500 + U64.to_i64_wrap(i), day: "2026-11-${two(12 - U64.to_i64_wrap(i))}", name: "Evening ${s.sport} session on the lakefront", sport: s.sport, chan: chan_of(s.sport) })

	# One trace per athlete, session and camera. `moved` 0 is the session at
	# home with every sport offered; 1 zooms and pans it, filters the picker
	# to its sport and lays the athlete's next session over it as a ghost.
	trace_model : Ui.Model, Athlete, U64, U64 -> Ui.Model
	trace_model = |base, a, sel, moved| {
		ids = picker_of(a)
		entry = (List.get(ids, sel)) ?? { id: 0, day: "", name: "", sport: "Ride", chan: Db.watts_chan }
		ghost = (List.get(ids, (sel + 1) % List.len(ids))) ?? entry
		unit = Db.trace_unit(entry.chan, a.units, entry.sport)
		{
			..base,
			view: 2,
			trace_ids: ids,
			trace_sel: sel,
			trace_day: entry.day,
			trace: samples_of(entry.sport),
			trace_dur: 3600.0,
			trace_unit: unit,
			segs: if (entry.chan == Db.hr_chan) [] else [{ kind: "work", start_s: 600, dur_s: 480 }, { kind: "recovery", start_s: 1080, dur_s: 240 }, { kind: "work", start_s: 1320, dur_s: 480 }, { kind: "work", start_s: 2040, dur_s: 480 }],
			trace_splits: if (entry.chan == Db.pace_chan) splits_of(a.units, entry.sport) else [],
			trace_sets: { rows: if (Trace.strength_session(entry.sport)) set_rows else [], pasted: Bool.False },
			trace_sport: if (moved == 1) entry.sport else "",
			trace_zoom: if (moved == 1) 2.5 else 1.0,
			trace_pan: if (moved == 1) 0.2 else 0.0,
			ghost: if (moved == 1 and ghost.chan == entry.chan) List.map(samples_of(ghost.sport), |v| v * 0.9) else [],
			ghost_dur: 3000.0,
			ghost_day: if (moved == 1 and ghost.chan == entry.chan) ghost.day else "",
		}
	}

	trace_models : List({ name : Str, model : Ui.Model })
	trace_models = {
		sessions = List.join(
			List.map(
				athletes,
				|a| List.join(
					List.map(
						sizes,
						|sz| {
							base = athlete_model(a, sz)
							List.join(List.map_with_index(a.sports, |s, sel| List.map([0.U64, 1], |moved| { name: "${a.name} trace ${s.sport} ${if (moved == 1) "zoomed with a ghost" else "at home"} at ${size_name(sz)}", model: trace_model(base, a, sel, moved) })))
						},
					),
				),
			),
		)
		# the blank plots: a fetch in flight, a stream with nothing to plot,
		# and an athlete with no session at all
		blank = List.join(
			List.map(
				sizes,
				|sz| {
					a = (List.first(athletes)) ?? { name: "", units: Metric, sports: [] }
					m = trace_model(athlete_model(a, sz), a, 0, 0)
					[
						{ name: "trace loading at ${size_name(sz)}", model: { ..m, trace: [], trace_loading: Bool.True } },
						{ name: "trace with no samples at ${size_name(sz)}", model: { ..m, trace: [] } },
						{ name: "trace with no sessions at ${size_name(sz)}", model: { ..m, trace: [], trace_ids: [] } },
					]
				},
			),
		)
		List.concat(sessions, blank)
	}

	# ── the day tab's fixtures ──────────────────────────────────────────────
	# the athlete's sport for a session slot, cycling through its families
	sport_at : Athlete, U64 -> Str
	sport_at = |a, i| {
		hs = athlete_heads(a)
		(List.get(hs, i % U64.max(1, List.len(hs)))) ?? "Ride"
	}

	# a session's target in its own signal and the result `complete` stored
	# for it: watts on a power family, a pace in the family's unit, an RPE on
	# strength work
	with_target : Db.PlanRow, [Metric, Imperial], Str -> Db.PlanRow
	with_target = |p, units, sport| {
		fam = Sports.canonical(sport)
		label = (Curve.pace_unit_for(units, fam)).label
		if List.contains(Sports.pace_target_families, fam) {
			{ ..p, tgt_lit: "5x4:00@4:10${label}", tgt_res: "whole session at 4:14${label}" }
		} else if Sports.class(fam) == Endurance {
			{ ..p, tgt_reps: 2, tgt_dur_s: 900, tgt_watts: 225.0, det_reps: 2, det_dur_s: 905, det_watts: 228.0 }
		} else {
			{ ..p, tgt_lit: "1x45:00@RPE6", tgt_res: "rated 7.0" }
		}
	}

	long_detail : Str
	long_detail = "Warm up 15 min easy, then 3 x 12 min at threshold with 4 min easy between, keeping the effort steady and the cadence high; cool down 10 min, and if the legs are heavy from the weekend cut the third rep and finish with 20 min easy instead"

	long_rationale : Str
	long_rationale = "Fatigue is high after the weekend block, so the threshold work stays short and the long day moves to Saturday, two easy days after it"

	# A planned week from Monday 11-09 to the Wednesday after the as-of
	# Thursday: past sessions done, skipped with and without a substitute
	# and several a day, more of them than the widest window's ladder holds,
	# a rest day rested, today's session open with a long prescription
	# beside one already done, and the days ahead open with prescriptions
	# long enough to wrap.
	plan_rows : Athlete -> List(Db.PlanRow)
	plan_rows = |a| {
		at = |day, wi, typ, i| { ..Plan.blank_row, day, wi, typ, detail: "${sport_at(a, i)}: ${typ} as written, 60 min", today: Bool.False, past: wi < 3, day_load_known: Bool.True, day_load: 60.0 }
		done = |p, i| with_target({ ..p, status: "done", act_name: "Morning ${sport_at(a, i)} on the river loop", act_secs: 3720, act_load: 64 }, a.units, sport_at(a, i))
		ahead = |p| { ..p, detail: long_detail, rationale: long_rationale }
		# a past day's extra sessions, each done
		more = |day, wi| List.map(seq(5), |n| done(at(day, wi, if (n % 2 == 0) "endurance" else "strength", I64.to_u64_wrap(n)), I64.to_u64_wrap(n)))
		List.join([
			[
				done(at("2026-11-09", 0, "endurance", 0), 0),
				done(at("2026-11-09", 0, "strength", 1), 1),
				{ ..at("2026-11-09", 0, "vo2", 2), status: "skipped", reason: "the pool was closed for a meet" },
			],
			more("2026-11-09", 0),
			[
				done(at("2026-11-10", 1, "threshold", 3), 3),
				{ ..at("2026-11-10", 1, "threshold", 4), status: "skipped", reason: "sick", sub_id: 7, sub_name: "Easy ${sport_at(a, 4)} with the club" },
			],
			more("2026-11-10", 1),
			[
				{ ..at("2026-11-11", 2, "rest", 0), day_load: 0.0 },
				{ ..done(at("2026-11-11", 2, "endurance", 5), 5), done_day: "2026-11-12" },
				{ ..at("2026-11-11", 2, "strength", 2), status: "skipped", reason: "travel day, the hotel gym was closed" },
			],
			more("2026-11-11", 2),
			[
				done(at("2026-11-12", 3, "strength", 6), 6),
				{ ..ahead(at("2026-11-12", 3, "threshold", 0)), today: Bool.True, past: Bool.False },
				ahead(at("2026-11-13", 4, "vo2", 1)),
				ahead(at("2026-11-14", 5, "endurance", 2)),
				{ ..at("2026-11-15", 6, "rest", 0), past: Bool.False, day_load_known: Bool.False },
				ahead(at("2026-11-16", 7, "strength", 3)),
				ahead(at("2026-11-17", 8, "threshold", 4)),
				ahead(at("2026-11-18", 9, "endurance", 5)),
			],
		])
	}

	plan_models : List({ name : Str, model : Ui.Model })
	plan_models =
		List.join(
			List.map(
				athletes,
				|a| List.join(
					List.map(
						sizes,
						|sz| {
							base = { ..athlete_model(a, sz), view: 4, plan: plan_rows(a), week_tss: { this: 412, last: 1385 }, bus_note: "11-12 08:14 plan / 30d", plan_week: { done: 4, total: 6 } }
							[
								{ name: "${a.name} week at ${size_name(sz)}", model: base },
								{ name: "${a.name} week scrolled with the quest complete at ${size_name(sz)}", model: { ..base, week_off: 4, plan_week: { done: 6, total: 6 } } },
							]
						},
					),
				),
			),
		)

	# a day's sessions, named as the activity list names them, two on some
	# days and long enough to wrap the session column
	day_notes_of : Athlete -> List({ day : Str, note : Str })
	day_notes_of = |a| List.map_with_index(series_days, |day, i| { day, note: if (i % 3 == 0) "45 min ${sport_at(a, i)} with the Saturday group + Evening ${sport_at(a, i + 1)} around the lake" else "Morning ${sport_at(a, i)}" })

	# the open day's activities: three blocks with long titles and their
	# load, physiology and zone lines
	detail_lines : Athlete -> List(Db.DayLine)
	detail_lines = |a| {
		du = Str.drop_prefix((Curve.pace_unit_for(a.units, "Run")).label, "/")
		List.map([0, 1, 2], |i| { title: "Evening ${sport_at(a, i)} along the lakefront path and back through the park [${sport_at(a, i)}]", stats: "62 min  42.1${du}  85 tss  230 w np", extra: "IF 0.84   142 bpm avg   rpe 6.0", zones: [600, 1500, 900, 420, 60] })
	}

	table_models : List({ name : Str, model : Ui.Model })
	table_models =
		List.join(
			List.map_with_index(
				athletes,
				|a, k| List.join(
					List.map(
						sizes,
						|sz| {
							base = { ..athlete_model(a, sz), view: 3, data: board_series(k), days: series_days, day_notes: day_notes_of(a), table_head: List.map(Table.head_texts, |_t| Text.Prepared.stub) }
							[
								{ name: "${a.name} log at ${size_name(sz)}", model: base },
								{ name: "${a.name} log scrolled with a day open at ${size_name(sz)}", model: { ..base, cursor: 30, detail_day: "2026-10-13", detail: detail_lines(a) } },
								{ name: "${a.name} log with a day loading at ${size_name(sz)}", model: { ..base, detail_day: "2026-11-12", detail: [] } },
							]
						},
					),
				),
			),
		)

	# 2025-10-01, a Wednesday, through the as-of day: more weeks than the
	# widest window holds
	year_days : List(Db.HeatDay)
	year_days = {
		spans = [{ y: 2025, m: 10, n: 31 }, { y: 2025, m: 11, n: 30 }, { y: 2025, m: 12, n: 31 }, { y: 2026, m: 1, n: 31 }, { y: 2026, m: 2, n: 28 }, { y: 2026, m: 3, n: 31 }, { y: 2026, m: 4, n: 30 }, { y: 2026, m: 5, n: 31 }, { y: 2026, m: 6, n: 30 }, { y: 2026, m: 7, n: 31 }, { y: 2026, m: 8, n: 31 }, { y: 2026, m: 9, n: 30 }, { y: 2026, m: 10, n: 31 }, { y: 2026, m: 11, n: 12 }]
		days = List.join(List.map(spans, |mo| List.map(seq(mo.n), |d| "${I64.to_str(mo.y)}-${two(mo.m)}-${two(d)}")))
		List.map_with_index(days, |day, i| { day, tss: if (i % 7 == 4) 0 else 30 + U64.to_i64_wrap(i % 9) * 15, dow: U64.to_i64_wrap((i + 3) % 7) })
	}

	heat_models : List({ name : Str, model : Ui.Model })
	heat_models = {
		per_athlete = List.join(
			List.map(
				athletes,
				|a| List.join(
					List.map(
						sizes,
						|sz| {
							base = { ..athlete_model(a, sz), view: 5, heat: year_days }
							[
								{ name: "${a.name} year at ${size_name(sz)}", model: base },
								{ name: "${a.name} year with event days at ${size_name(sz)}", model: { ..base, heat_events: ["2026-06-27", "2026-11-08"] } },
							]
						},
					),
				),
			),
		)
		empty = List.map(sizes, |sz| { name: "year with no history at ${size_name(sz)}", model: { ..empty_model(sz), view: 5 } })
		List.concat(per_athlete, empty)
	}

	# ── the weeks tab's fixtures ────────────────────────────────────────────
	# the Mondays the weeks tab charts, up to the as-of week, which is still
	# running
	week_starts : List(Str)
	week_starts = ["2026-08-24", "2026-08-31", "2026-09-07", "2026-09-14", "2026-09-21", "2026-09-28", "2026-10-05", "2026-10-12", "2026-10-19", "2026-10-26", "2026-11-02", "2026-11-09"]

	# a week's share of the athlete's usual volume: the first week the
	# biggest, so its cap or chip rises to the scale's top value, a rest
	# week in the middle and the running week partial
	week_share : U64 -> I64
	week_share = |i| (List.get([140, 90, 100, 110, 60, 0, 105, 115, 120, 95, 100, 40], i)) ?? 100

	zone_weeks_of : U64 -> List(Db.ZoneWeek)
	zone_weeks_of = |k|
		List.map_with_index(
			week_starts,
			|wk, i| {
				s = week_share(i) * (60 + 15 * U64.to_i64_wrap(k % 5))
				z = { z1: s * 25, z2: s * 40, z3: s * 18, z4: s * 12, z5: s * 5 }
				easy = z.z1 + z.z2 - (if (i % 3 == 1) s * 30 else 0)
				{ wk, days: if (i == 11) 4 else 7, z1: z.z1, z2: z.z2, z3: z.z3, z4: z.z4, z5: z.z5, easy, moderate: z.z3 + (if (i % 3 == 1) s * 30 else 0), hard: z.z4 + z.z5 }
			},
		)

	ramp_weeks_of : U64 -> List(Db.RampWeek)
	ramp_weeks_of = |k|
		List.map_with_index(
			week_starts,
			|wk, i| {
				tss = week_share(i) * (4 + U64.to_i64_wrap(k % 4))
				{ wk, days: if (i == 11) 4 else 7, tss, ctl10: 480 + U64.to_i64_wrap(i) * 7, ramp10: (List.get([75, -12, 18, 31, 0, -19, 42, 64, 25, 8, 12, -5], i)) ?? 0 }
			},
		)

	# ── the lifts tab's fixtures ────────────────────────────────────────────
	# lifts, more rows than the widest window holds, each trained on several
	# days, rising, flat or falling, some named past the column's cut
	lifts : List(Db.Lift)
	lifts =
		List.map(
			seq(50),
			|n| {
				names = ["Back Squat", "Romanian Deadlift", "Tall Kneeling Dumbbell Overhead Press", "Dumbbell Pass Through to Push Up", "Pull Up", "Reverse Grip Tricep Kickback", "Bench Press"]
				name = (List.get(names, I64.to_u64_wrap(n % 7))) ?? "Curl"
				step = I64.to_f64(n % 3) - 1.0
				{ exercise: "${name} ${I64.to_str(n)}", points: List.map(seq(5), |d| { day: "2026-10-${two(d * 5)}", kg: 20.0 + I64.to_f64(n % 9) * 5.0 + step * I64.to_f64(d) * 2.5 }) }
			},
		)

	# the strength view for an athlete who lifts, in a mass unit: the
	# latest session's sets with newer unlogged sessions above them, the
	# weeks of sessions and the months of tonnage, the last in progress
	strength_of : [Metric, Imperial] -> Db.StrengthView
	strength_of = |mass| {
		lifts,
		last: { id: 9, day: "2026-11-09", name: "Afternoon Workout - full body with the Tuesday group at the gym downtown", log: { rows: set_rows, pasted: Bool.False } },
		unlogged: [{ day: "2026-11-12", name: "Morning Workout" }, { day: "2026-11-11", name: "Yoga" }],
		weeks: List.map_with_index(week_starts, |mon, i| { mon, total: 2 + U64.to_i64_wrap(i % 3), with_sets: 1 + U64.to_i64_wrap(i % 2) }),
		tonnage: List.map_with_index(List.take_last(months, 12), |month, i| { month, kg: 9000.0 + U64.to_f64(i % 5) * 2500.0, covered: 3 + U64.to_i64_wrap(i % 4), total: 8, partial: i == 11 }),
		mass,
	}

	lifts_models : List({ name : Str, model : Ui.Model })
	lifts_models =
		List.join(
			List.map(
				athletes,
				|a| List.join(
					List.map(
						sizes,
						|sz| {
							base = { ..athlete_model(a, sz), view: 9 }
							if List.any(athlete_heads(a), |h| Sports.class(h) == StrengthLike) {
								[
									{ name: "${a.name} lifts at ${size_name(sz)}", model: { ..base, strength: strength_of(Metric) } },
									{ name: "${a.name} lifts in pounds, scrolled at ${size_name(sz)}", model: { ..base, strength: strength_of(Imperial), lifts_off: 10 } },
								]
							} else {
								[{ name: "${a.name} lifts with no lifting at ${size_name(sz)}", model: base }]
							}
						},
					),
				),
			),
		)
	# ── the boot splash's fixtures: its words at every size, at each dot
	# count, with and without the note a slow load earns ─────────────────
	splash_models : List({ name : Str, model : Ui.Model, slow : Str })
	splash_models =
		List.join(
			List.map(
				sizes,
				|sz| List.join(
					List.map(
						[10.U64, 40, 70],
						|tick| List.map(["", "still loading after 25 s - R retries, ESC quits"], |slow| { name: "splash at tick ${U64.to_str(tick)}${if (slow == "") "" else " running slow"} at ${size_name(sz)}", model: { ..empty_model(sz), booting: Bool.True, tick }, slow }),
					),
				),
			),
		)

	weeks_models : U8 -> List({ name : Str, model : Ui.Model })
	weeks_models = |view|
		List.join(
			List.map_with_index(
				athletes,
				|a, k| List.join(
					List.map(
						sizes,
						|sz| {
							base = { ..athlete_model(a, sz), view, zone_weeks: zone_weeks_of(k), ramp_weeks: ramp_weeks_of(k) }
							mode = if (view == 6) "zones" else "load"
							[
								{ name: "${a.name} ${mode} at ${size_name(sz)}", model: base },
								{ name: "${a.name} ${mode} on a picked week with per-sport zones at ${size_name(sz)}", model: { ..base, week_cursor: "2026-11-09", zone_overrides: athlete_heads(a) } },
								{ name: "${a.name} ${mode} with no history at ${size_name(sz)}", model: { ..base, zone_weeks: [], ramp_weeks: [] } },
							]
						},
					),
				),
			),
		)
}

# the gate's measure is the window's: the data face advances 10 of 24 px
# per code point, and the prose face reads its own advances
expect (Gate.measure("abcd", 24.0, Data) - (4.0 * 10.0 + 3.0 * Text.default_spacing)).abs() < 0.01
expect (Gate.measure("Stride", 24.0, Prose) - (10.0 + 6.0 + 7.0 + 3.0 + 11.0 + 10.0 + 5.0 * Text.default_spacing)).abs() < 0.01

# the fixtures cover every family, a pace family in imperial units, and a
# mixed athlete with a one-off sport outside every family
expect List.len(Gate.athletes) == List.len(Sports.families) + List.len(Sports.pace_target_families) + 1
expect !(List.contains(List.join(List.map(Sports.families, |f| f.sports)), Gate.rare))

# the power view's gate: every curve, range and short-rung choice of every
# athlete at every size; no text over a chip, a tile, a dot, a planned ring
# or a legend swatch
expect Gate.failures(|m| Gate.judge(Curve.owned(m, Gate.measure), Curve.marks(m, Gate.measure)), Gate.curve_models) == []

# the career view's gate: every spine of every athlete at every size; no
# text over a chip, a card, a dot, a load bar, a legend swatch or the strip
expect Gate.failures(|m| Gate.judge(Career.owned(m, Gate.measure), Career.marks(m, Gate.measure)), Gate.career_models) == []

# the form board's gate: every athlete's board at every range, with an
# event ahead and with the event-day story, at every size, and the two
# boards with no plot; no text over a chip, a tile or a load bar
expect Gate.failures(|m| Gate.judge(Board.owned(m, Gate.measure), Board.marks(m)), Gate.board_models) == []

# the session trace's gate: every session of every athlete at home and
# zoomed with a ghost, and the three blank plots, at every size
expect Gate.failures(|m| Gate.judge(Trace.owned(m, Gate.measure), Trace.marks(m)), Gate.trace_models) == []

# the day tab's gates: the week with its card, ladder, scroll hints and
# quest, the log with a day open and loading, and the year with and without
# event days, for every athlete at every size
expect Gate.failures(|m| Gate.judge(Plan.owned(m, Gate.measure), Plan.marks(m)), Gate.plan_models) == []
expect Gate.failures(|m| Gate.judge(Table.owned(m, Gate.measure), Table.marks(m)), Gate.table_models) == []
expect Gate.failures(|m| Gate.judge(Heat.owned(m, Gate.measure), Heat.marks(m)), Gate.heat_models) == []

# the weeks tab's gates: zones and load for every athlete at every size,
# with no week picked, on a picked week with per-sport zones, and with no
# history
expect Gate.failures(|m| Gate.judge(Zones.owned(m, Gate.measure), Zones.marks(m)), Gate.weeks_models(6)) == []
expect Gate.failures(|m| Gate.judge(Ramp.owned(m, Gate.measure), Ramp.marks(m)), Gate.weeks_models(7)) == []

# the lifts tab's gate: every athlete who lifts, in kilograms and scrolled
# in pounds, and every athlete who does not, at every size
expect Gate.failures(|m| Gate.judge(Strength.owned(m, Gate.measure), Strength.marks(m)), Gate.lifts_models) == []

# the boot splash's gate: its words at every size and dot count, slow or not
expect List.join(List.map(Gate.splash_models, |f| List.map(Labels.check(Scene.owned(Chrome.splash(f.model, Gate.measure, f.slow))), |e| "${f.name}: ${e}"))) == []

# the XP rail's sheet holds its lines inside its card for every athlete at
# every size
expect List.join(List.map(Gate.board_models, |f| List.map(Labels.check(Scene.owned(Labels.place((Hud.sheet(f.model, Gate.measure)).lines, { boxes: [], segs: [] }))), |e| "${f.name}: ${e}"))) == []
