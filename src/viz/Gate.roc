import rr.Text
import core.Sports
import Career
import Curve
import Db
import DisplayScale
import Labels
import Scene
import Theme
import Ui

Gate :: [].{
	# ── the label gate ──────────────────────────────────────────────────────
	# A headless layout pass of each view over fixture athletes at the
	# minimum, default and wide window sizes. Every scene's placed text, the
	# chrome's included, must hold no two overlapping boxes and no box
	# outside its region (Labels.check). The athletes come from the sport
	# families in core.Sports, one per family plus a mixed one carrying a
	# single session of a sport no family holds, and every pace family is
	# also drawn in imperial units. Text is measured with headless fonts
	# carrying the shipped faces' advances, so the gate needs no font file.

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
		{
			title: p,
			subs: [],
			leg_fit: p,
			leg_fat: p,
			leg_form: p,
			ylabels: [],
			ends: [],
			ev_label: p,
			ev_found: Bool.False,
			ev_idx: 0,
			ev_warn: p,
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
			ev_tile_sub: p,
			zero_note: p,
			ridden_found: Bool.False,
			ridden_note: p,
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
			status: p,
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

	# every fixture's failures under a view's scene, each named by its
	# fixture: empty is a clean gate. roc test reports only that an expect
	# failed, so `dbg` this list inside the expect to read what overlapped.
	failures : (Ui.Model -> List(Labels.Owned)), List({ name : Str, model : Ui.Model }) -> List(Str)
	failures = |owned, fixtures| List.join(List.map(fixtures, |f| List.map(Labels.check(owned(f.model)), |e| "${f.name}: ${e}")))
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
# athlete at every size places its text with no overlap and inside its
# regions
expect Gate.failures(|m| Curve.owned(m, Gate.measure), Gate.curve_models) == []

# the career view's gate: every spine of every athlete at every size
expect Gate.failures(|m| Career.owned(m, Gate.measure), Gate.career_models) == []
