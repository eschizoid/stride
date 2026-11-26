import rr.Text
import core.Load
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
import Geo
import Labels
import Map
import MapNames
import Mvt
import Plan
import Ramp
import Scene
import Strength
import Table
import Theme
import Tiles
import Trace
import Ui
import Weeks
import Zones

Gate :: [].{
	# ── the label gate ──────────────────────────────────────────────────────
	# A headless layout pass of every view over fixture athletes at the
	# minimum, default and wide window sizes. Every scene's placed text, the
	# chrome's included, must hold no two overlapping boxes and no box
	# outside its region (Labels.check); on every view no text may cover a
	# shape but the one it is written inside (Labels.covers), and no text may
	# call a load TSS (wording); the boot splash and the XP rail's sheet run
	# the first check alone. The athletes come from the sport families in
	# core.Sports, one per family plus a mixed one carrying a single session
	# of a sport no family holds, and every pace family is also drawn in
	# imperial units. Text is measured with headless fonts carrying the
	# shipped faces' advances, so the gate needs no font file.

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

	# the platform's built-in face, which the window draws both faces in when
	# the brand fonts cannot be read: a 10 px atlas whose glyphs carry no
	# advance, so each measures its width, here for the printable ASCII
	# range as Draw.default_font reports it; a code point outside the range
	# measures as the platform's fallback glyph, the space
	builtin_font : Text.Font
	builtin_font = {
		..Text.font_stub,
		metrics: {
			base_size: 10.0,
			line_spacing: 0.0,
			fallback_index: 0,
			glyphs: List.map_with_index(builtin_widths, |w, i| { codepoint: 32 + U64.to_u32_wrap(i), advance_x: 0.0, offset_x: 0.0, offset_y: 0.0, width: w, height: 10.0 }),
		},
	}

	builtin_widths : List(F32)
	builtin_widths = [3, 1, 4, 6, 5, 7, 6, 2, 3, 3, 5, 5, 2, 4, 1, 7, 5, 2, 5, 5, 5, 5, 5, 5, 5, 5, 1, 1, 3, 4, 3, 6, 7, 6, 6, 6, 6, 6, 6, 6, 6, 3, 5, 6, 5, 7, 6, 6, 6, 6, 6, 6, 7, 6, 7, 7, 6, 6, 6, 2, 7, 2, 3, 5, 2, 5, 5, 5, 5, 5, 4, 5, 5, 1, 2, 5, 2, 5, 5, 5, 5, 5, 5, 5, 4, 5, 5, 5, 5, 5, 5, 3, 1, 3, 4]

	builtin_measure : Scene.Measure
	builtin_measure = Scene.measure_with(builtin_font, builtin_font)

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

	# the first fixture athlete, the one a single-board expect reads
	first_athlete : Athlete
	first_athlete = (List.first(athletes)) ?? { name: "none", units: Metric, sports: [] }

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

	# One power view per curve key and range. The range picks the story: 30
	# days gained on the window before with a usable fit, so no test is due;
	# 60 days fell back from the window before with a fit through steady
	# efforts, so a test is due; 90 days moved both ways with a marked test
	# in force.
	curve_model : Ui.Model, Athlete, Str, I64 -> Ui.Model
	curve_model = |base, a, key, days| {
		pace = Str.starts_with(key, "pace:")
		ladder = if (pace) pace_rungs else power_rungs
		b = base_of(key)
		n = List.len(ladder)
		rec = |r| r.share * b
		prs = List.map(ladder, |r| { secs: r.secs, w: round_i(rec(r)) })
		now_share = |i| if (days == 30) (if (i + 2 >= n) 1.0 else 0.9) else if (days == 60) (if (i < 4) 0.86 - 0.01 * U64.to_f32(i) else 0.85) else if (i % 2 == 0) 0.93 else 0.97
		prev_share = |i| if (days == 30) 0.88 else if (days == 60) 0.95 else if (i % 3 == 0) 0.99 else 0.94
		pt = |r, share| { dur_s: r.secs, watts: I64.to_f32(round_i(rec(r) * share)) }
		curve = List.map_with_index(ladder, |r, i| pt(r, now_share(i)))
		prev = List.map_with_index(ladder, |r, i| pt(r, prev_share(i)))
		r20 = rec({ rung: "20min", secs: 1200, share: 1.0 })
		fit =
			if days == 30 {
				band = Curve.d_prime_band(Str.drop_prefix(key, "pace:"))
				{ cp: if (pace) r20 * 0.96 / 1000.0 else r20 * 0.96, w_prime: if (pace) (band.lo + band.hi) / 2.0 else 15000.0, r2: 0.95, points: 4.0, ok: Bool.True }
			} else {
				{ cp: if (pace) r20 * 0.9 / 1000.0 else r20 * 0.9, w_prime: if (pace) 2.0 else 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }
			}
		test = if (days == 90) { value: if (pace) r20 * 0.95 / 1000.0 else r20 * 0.95, kind: "cp3-12", date: "2026-10-27" } else { value: 0.0, kind: "none", date: "none" }
		{
			..base,
			view: 1,
			units: a.units,
			curve_family: key,
			curve_keys: curve_keys_of(a),
			est_power: [],
			curve_days: days,
			prs,
			curve,
			curve_prev: prev,
			curve_info: { fit, test, thr: if (pace) r20 * 0.95 / 1000.0 else r20 * 0.95, thr_known: Bool.True, from_test: days == 90 },
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
								List.join(List.map(List.concat(keys.power, keys.pace), |key| List.map([30, 60, 90], |days| { name: "${a.name} power ${key} ${I64.to_str(days)}d at ${size_name(sz)}", model: curve_model(base, a, key, days) })))
							},
						),
					)
				},
			),
		)

	# Power curves of sports outside every family under long Strava names,
	# beside a ride and a row, at every range and size: their chip widens to
	# hold the name in plain words and the title carries it too
	long_sports : List(Str)
	long_sports = ["StandUpPaddling", "HighIntensityIntervalTraining"]

	long_models : List({ name : Str, model : Ui.Model })
	long_models = {
		a = { name: "long names", units: Metric, sports: [{ sport: "Ride", sessions: 100 }, { sport: "Rowing", sessions: 80 }] }
		List.join(
			List.map(
				sizes,
				|sz| List.join(
					List.map(
						long_sports,
						|key| List.map([30, 60, 90], |days| { name: "${a.name} power ${key} ${I64.to_str(days)}d at ${size_name(sz)}", model: { ..curve_model(athlete_model(a, sz), a, key, days), curve_keys: { power: List.concat(["Ride", "Rowing"], long_sports), pace: ["pace:Rowing"] } } }),
					),
				),
			),
		)
	}

	# The rows' and the card's other strings, on every 90-day fixture. "new
	# athlete": no threshold yet, nothing in the window before, and no best
	# ever past 5 minutes, so the card says how to get a threshold (on foot,
	# both ways), the legend names the empty window before, and every longer
	# row says what it lacks. "mixed rows": the first row level within a
	# watt, the second with a best only in the window before and the third
	# only in this one. "too few for a fit": the engine found too few bests
	# to fit and no test is in force, so the card asks for one, and the rows
	# from 20 minutes have bests only from before both windows. "test under
	# the derivation": the test in force is lower than the 60-day derivation,
	# so the card credits the derivation. "threshold unread": the engine's
	# answer lacked the threshold, so the card says it could not be read.
	story_models : List({ name : Str, model : Ui.Model })
	story_models =
		List.join(
			List.map(
				List.keep_if(List.concat(curve_models, long_models), |c| c.model.curve_days == 90),
				|c| {
					m = c.model
					keep5 = |pts| List.keep_if(pts, |p| p.dur_s <= 300)
					prev5 = match List.find_first(m.curve_prev, |q| q.dur_s == 300) {
						Ok(q) => q.watts
						Err(_) => 0.0
					}
					level = List.map(m.curve, |p| if (p.dur_s == 300 and prev5 > 0.0) { ..p, watts: prev5 + 1.0 } else p)
					[
						{ name: "${c.name} new athlete", model: { ..m, prs: List.map(m.prs, |pr| if (pr.secs <= 300) pr else { ..pr, w: 0 }), curve: keep5(m.curve), curve_prev: [], curve_info: { ..m.curve_info, thr: 0.0, test: { value: 0.0, kind: "none", date: "none" }, from_test: Bool.False } } },
						{ name: "${c.name} mixed rows", model: { ..m, curve: List.keep_if(level, |p| p.dur_s != 600), curve_prev: List.keep_if(m.curve_prev, |p| p.dur_s != 1200) } },
						{ name: "${c.name} too few for a fit", model: { ..m, curve: List.keep_if(m.curve, |p| p.dur_s < 1200), curve_prev: List.keep_if(m.curve_prev, |p| p.dur_s < 1200), curve_info: { ..m.curve_info, fit: { cp: 0.0, w_prime: 0.0, r2: 0.0, points: 1.0, ok: Bool.True }, test: { value: 0.0, kind: "none", date: "none" }, from_test: Bool.False } } },
						{ name: "${c.name} test under the derivation", model: { ..m, curve_info: { ..m.curve_info, test: { ..m.curve_info.test, value: m.curve_info.thr * 0.9 }, from_test: Bool.False } } },
						{ name: "${c.name} threshold unread", model: { ..m, curve_info: { ..m.curve_info, thr_known: Bool.False } } },
					]
				},
			),
		)
	size_name : { w : F32, h : F32 } -> Str
	size_name = |sz| "${I64.to_str(round_i(sz.w))}x${I64.to_str(round_i(sz.h))}"

	# ── the career view's fixtures ──────────────────────────────────────────
	# a family's month-close threshold at its kind's resolution (watts and kg
	# in tenths, pace in mm/s): a climb out of a valley to a peak, a two-month
	# gap with no session, and a last month that is the peak again on every
	# other family
	spine_rows : Str, Str, U64 -> List(Db.CareerMonth)
	spine_rows = |fam, kind, k| {
		base = if (kind == "power") 2500.0 else if (kind == "tonnage") 60000.0 else base_of("pace:${fam}")
		n = List.len(months)
		List.map_with_index(
			months,
			|m, i| {
				t = U64.to_f32(i) / U64.to_f32(n - 1)
				shape = if (t < 0.3) 1.0 - t else if (t < 0.85) 0.7 + (t - 0.3) * 0.7 else 1.08 - (t - 0.85) * (if (k % 2 == 0) -0.4 else 0.6)
				gap = i == 9 or i == 10
				{ month: m, load: 900 + U64.to_i64_wrap((i * 37) % 600), spine_v: if (gap) 0 else round_i(base * shape), partial: i + 1 == n }
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
			career_spines: career_pages(spines, base.career_sports),
			career_tests: List.map(keys.power, |h| { fam: h, month: "2026-03", kind: "cp3-12", signal: "power" }),
			career_fam_months: List.join(List.map(hs, |h| List.map_with_index(months, |m, i| { fam: h, month: m, load: 300 + U64.to_i64_wrap((i * 13) % 200), sessions: if (i == 9 or i == 10) 0 else 6 }))),
		}
	}

	# the pages the window's loader makes of a set of trends: each trend as
	# given, then a page for every family with sessions and no trend
	# (Career.cycle_fams), on the fixture months with no threshold in any
	career_pages : List(Db.CareerSpine), List(Db.CareerSport) -> List(Db.CareerSpine)
	career_pages = |spines, sports|
		List.map(
			Career.cycle_fams(List.map(spines, |s| { fam: s.fam, kind: s.kind, months: 0 }), sports),
			|f| match List.find_first(spines, |s| s.fam == f.fam and s.kind == f.kind) {
				Ok(s) => s
				Err(_) => { fam: f.fam, kind: f.kind, rows: List.map(spine_rows(f.fam, "power", 0), |r| { ..r, spine_v: 0 }) }
			},
		)

	# the athlete the window met with runs and no running threshold: short
	# run/walk sessions beside a family with a power trend
	short_runner : Athlete
	short_runner = { name: "short runs beside rides", units: Metric, sports: [{ sport: "Ride", sessions: 300 }, { sport: "Rowing", sessions: 120 }, { sport: "Run", sessions: 20 }] }

	# an athlete whose sports sit in no family and carry long Strava names,
	# beside a ride trend: stand-up paddling with a power trend, the rest
	# pages without one, each named on its cards and in its heading
	long_names : Athlete
	long_names = { name: "long sport names beside rides", units: Metric, sports: [{ sport: "Ride", sessions: 300 }, { sport: "HighIntensityIntervalTraining", sessions: 60 }, { sport: "StandUpPaddling", sessions: 40 }, { sport: "BackcountrySki", sessions: 30 }, { sport: "EBikeRide", sessions: 20 }] }

	# the athlete after a first sync: one ride
	one_ride : Athlete
	one_ride = { name: "one ride", units: Metric, sports: [{ sport: "Ride", sessions: 1 }] }

	career_models : List({ name : Str, model : Ui.Model })
	career_models = {
		pages = |name, m| List.map_with_index(m.career_spines, |s, i| { name: "${name} ${s.fam} ${s.kind}", model: { ..m, spine_idx: i } })
		List.join(
			List.map(
				sizes,
				|sz| List.join([
					List.join(
						List.map(
							athletes,
							|a| {
								m = career_model(athlete_model(a, sz), a)
								List.concat(
									pages("${a.name} career at ${size_name(sz)}", m),
									# no threshold anywhere: every family is a page without a trend
									pages("${a.name} career with no threshold at ${size_name(sz)}", { ..m, career_spines: career_pages([], m.career_sports), career_tests: [] }),
								)
							},
						),
					),
					{
						m = career_model(athlete_model(short_runner, sz), short_runner)
						pages("${short_runner.name} career at ${size_name(sz)}", { ..m, career_spines: career_pages(List.keep_if(m.career_spines, |s| s.fam != "Run"), m.career_sports) })
					},
					{
						m = career_model(athlete_model(long_names, sz), long_names)
						# stand-up paddling carries power, so it draws a trend
						trends = List.append(List.keep_if(m.career_spines, |s| s.kind != Career.no_trend), { fam: "StandUpPaddling", kind: "power", rows: spine_rows("StandUpPaddling", "power", 1) })
						pages("${long_names.name} career at ${size_name(sz)}", { ..m, career_spines: career_pages(trends, m.career_sports) })
					},
					# a first ride: one month on record, beside the streak and the
					# level its hours earn
					{
						m = career_model(athlete_model(one_ride, sz), one_ride)
						pages("${one_ride.name} career at ${size_name(sz)}", { ..m, career_spines: List.map(m.career_spines, |s| { ..s, rows: List.take_last(s.rows, 1) }) })
					},
					# an empty database: no page at all
					[{ name: "empty career at ${size_name(sz)}", model: { ..empty_model(sz), view: 8 } }],
				]),
			),
		)
	}

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
			curve_title: p,
			curve_hint: p,
			trace_hint: p,
			table_hint: p,
			table_title: p,
			table_head: [],
			kpis: [],
			ev_tile_name: [],
			ev_tile_proj: [],
			proj: [],
			proj_key: t,
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
			last_off: 0,
			week_off: 0,
			trace_pan: 0.0,
			trace_cache: [],
			curve_days: 90,
			curve_family: "Ride",
			curve_keys: { power: [], pace: [] },
			est_power: [],
			curve_info: { fit: { cp: 0.0, w_prime: 0.0, r2: 0.0, points: 0.0, ok: Bool.False }, test: { value: 0.0, kind: "none", date: "none" }, thr: 0.0, thr_known: Bool.False, from_test: Bool.False },
			data: [],
			days: [],
			day_notes: [],
			stride_dir: "",
			cwd: "",
			tick: 0,
			last_active: 0,
			view_anim: 0,
			last_focus: { view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, detail_day: "", sport: "", family: "", curve_family: "", curve_short: -1, map_id: -1 },
			quitting: Bool.False,
			quit_tick: 0,
			focus_cleared: Bool.False,
			quit_mark_pending: -1,
			status: t,
			has_error: Bool.False,
			booting: Bool.False,
			reloading: Bool.False,
			logo: NoLogo,
			flame: NoFlame,
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
			bus_note: NoDirective,
			plan_title: p,
			plan_hint: p,
			nav: List.map(Chrome.nav_views, |v| { p, v }),
			heat: [],
			strength: Db.empty_strength_view,
			heat_events: [],
			heat_title: p,
			heat_hint: p,
			zone_weeks: [],
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
			map: Db.no_map,
			map_load: Loaded,
			map_gen: 0,
			map_stale: Bool.False,
			map_cam: Map.unpainted,
			map_moved: Bool.False,
			map_drag: Idle,
			map_card: Closed,
			map_rt: NoTarget,
			map_paint: Bool.False,
			map_painted: Map.unpainted,
			map_painted_view: 0,
			map_heat: Unbuilt,
			map_play: { secs: 0.0, paused: Bool.False },
			map_speed: Unbuilt,
			map_marks: Stale,
			map_tiles: [],
			map_source: Unasked,
			map_planned: { cam: Map.unpainted, tick: 0 },
			map_plan_due: Bool.True,
			map_cache_err: "",
			mouse_in: Bool.False,
			cursor: -1,
			cursor_ahead: 0,
		}
	}

	# every fixture's failures under a view's judge, each named by its
	# fixture: empty is a clean gate. roc test reports only that an expect
	# failed, so `dbg` this list inside the expect to read what failed.
	failures : (Ui.Model -> List(Str)), List({ name : Str, model : Ui.Model }) -> List(Str)
	failures = |rule, fixtures| List.join(List.map(fixtures, |f| List.map(rule(f.model), |e| "${f.name}: ${e}")))

	# one scene's failures: two texts that overlap, a text outside its
	# region, a text over a shape it must keep off, and a text that names a
	# load TSS
	judge : List(Labels.Owned), List(Labels.Mark) -> List(Str)
	judge = |texts, marks| List.join([Labels.check(texts), Labels.covers(texts, marks), wording(texts)])

	# Every load the window shows is the engine's mixed model: TSS for a
	# session scored by power or HR, session-RPE load for a rated lift, and
	# a day's or a week's total blends both. No window string calls one TSS.
	# A text fails when "tss" stands as a word in it, in any case; a word
	# that merely holds those letters passes.
	wording : List(Labels.Owned) -> List(Str)
	wording = |texts| List.keep_oks(texts, |t| if (names_tss(t.key)) Ok("${t.key} names a load TSS; the window says load") else Err(Clean))

	names_tss : Str -> Bool
	names_tss = |s| {
		folded = List.map(Str.to_utf8(s), |b| if (b >= 'A' and b <= 'Z') b + 32 else if ((b >= 'a' and b <= 'z') or (b >= '0' and b <= '9')) b else ' ')
		List.contains(Str.split_on(Str.from_utf8_lossy(folded), " "), "tss")
	}

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

	# the projection a board continues into: twenty planned days after the
	# series' last, walked by the engine's step from its last point over a
	# weekly plan with a rest day nothing prices, a day whose session only
	# partly prices and a heavy day, so the dashed lines rise and fall and
	# the hollow bars run to the rug's top
	proj_days : List(Str)
	proj_days = List.concat(List.map(seq(18), |d| "2026-11-${two(d + 12)}"), List.map(seq(2), |d| "2026-12-${two(d)}"))

	board_proj : U64, List(Db.Point) -> List(Db.ProjDay)
	board_proj = |k, data| {
		scale = 0.6 + 0.15 * U64.to_f32(k % 7)
		plan = [70.0, 0.0, 40.0, 95.0, 0.0, 210.0, 55.0]
		last = (List.last(data)) ?? { ctl: 0.0, atl: 0.0, tsb: 0.0, tss: 0.0 }
		walk = List.fold(
			List.map_with_index(proj_days, |d, i| { d, i }),
			{ ctl: last.ctl, atl: last.atl, out: [] },
			|acc, e| {
				t = ((List.get(plan, e.i % 7)) ?? 0.0) * scale
				s = Load.step({ ctl_prev: F32.to_f64(acc.ctl), atl_prev: F32.to_f64(acc.atl), tss: F32.to_f64(t) })
				ctl = F64.to_f32_wrap(s.ctl)
				atl = F64.to_f32_wrap(s.atl)
				{ ctl, atl, out: List.append(acc.out, { day: e.d, ctl, atl, tsb: ctl - atl, tss: t, known: e.i % 7 != 1 and e.i % 7 != 2 }) }
			},
		)
		walk.out
	}

	# One board per athlete, range and event state. `ev` picks the event
	# tile's story: 0 an event ahead with a two-line name and a projection,
	# 1 an event today marked on the plot, a recent ridden event and an
	# event record the database could not read, 2 an event the projection
	# reaches, marked on its last day.
	# The event name is fitted in `face`, as the window fits it in the face
	# it draws with. Each measured day carries the athlete's session note,
	# so a day card opened on it is as tall as its note makes it.
	board_model : Ui.Model, Athlete, U64, U64, U64 -> Ui.Model
	board_model = |base, a, k, range, ev| board_model_in(prose_font, base, a, k, range, ev)

	board_model_in : Text.Font, Ui.Model, Athlete, U64, U64, U64 -> Ui.Model
	board_model_in = |face, base, a, k, range, ev| {
		data = board_series(k)
		proj = if (ev == 1) [] else board_proj(k, data)
		event = "${(List.first(athlete_heads(a))) ?? "Ride"} championship, the long course with every hill"
		name = Board.ev_name(face, event)
		p = Text.Prepared.stub
		projection = { ok: Bool.True, ctl: 54.2, tsb: -9.8, considered: 20, projected: 14, days: proj }
		{
			..base,
			view: 0,
			range,
			data,
			days: series_days,
			day_notes: day_notes_of(a),
			ylabels: List.map([-30, -20, -10, 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100], |v| { p, v: I64.to_f32(v) }),
			ends: List.map([0.U8, 1, 2], |sel| { p, sel }),
			kpis: List.map([0.U8, 1, 2], |sel| { v: p, cap: p, sel }),
			ev_tile_name: List.map(name.lines, |l| txt(l, name.size)),
			ev_tile_sub: txt(if (ev == 0) "in 226d, 2027-06-26" else if (ev == 2) "in 20d, 2026-12-02" else "today, 2026-11-12", 11.0),
			ev_tile_proj: if (ev == 0) List.map(Board.proj_lines("2026-12-02", "2027-06-26", projection), |l| txt(l, 10.0)) else if (ev == 2) List.map(Board.proj_lines("2026-12-02", "2026-12-02", projection), |l| txt(l, 10.0)) else [],
			proj,
			proj_key: txt(Board.proj_key_text(projection.considered, projection.projected), 11.0),
			ridden_found: ev == 1,
			ridden_note: txt(Board.ev_line(face, event, " done, 3d ago", 10.0), 10.0),
			ev_label: txt(event, 13.0),
			ev_found: ev != 0,
			ev_idx: if (ev == 2) List.len(series_days) + List.len(proj) - 1 else List.len(series_days) - 1,
			ev_warn: txt("event record unreadable", 13.0),
			ev_warn_found: ev == 1,
			stale_found: Bool.True,
		}
	}

	board_models : List({ name : Str, model : Ui.Model })
	board_models = board_models_in(prose_font)

	# every board fixture, its event names fitted in `face`
	board_models_in : Text.Font -> List({ name : Str, model : Ui.Model })
	board_models_in = |face| {
		per_athlete = List.join(
			List.map_with_index(
				athletes,
				|a, k| List.join(
					List.map(
						sizes,
						|sz| {
							base = athlete_model(a, sz)
							List.join(List.map([30.U64, 60, 90], |r| List.map([0.U64, 1, 2], |ev| { name: "${a.name} form ${U64.to_str(r)}d event=${U64.to_str(ev)} at ${size_name(sz)}", model: board_model_in(face, base, a, k, r, ev) })))
						},
					),
				),
			),
		)
		# the three boards with no plot: an error loading the series, an
		# empty database, and a series one day long
		bare = List.join(
			List.map(
				sizes,
				|sz| {
					base = empty_model(sz)
					[
						{ name: "form with a load error at ${size_name(sz)}", model: { ..base, view: 0, has_error: Bool.True, status: txt("daily_load query failed - analyzed yet?", 16.0) } },
						{ name: "form with no data at ${size_name(sz)}", model: { ..base, view: 0 } },
						{ name: "form with one day at ${size_name(sz)}", model: { ..base, view: 0, data: [{ ctl: 1.0, atl: 7.0, tsb: -6.0, tss: 50.0 }], days: ["2026-11-26"] } },
					]
				},
			),
		)
		List.concat(per_athlete, bare)
	}

	# the day card the cursor opens over every day a board with a projection
	# draws: each measured day counted back from the latest, and each
	# projected day counted on past it. Its lines clear one another and stay
	# inside the card, and the card stays inside the plot and clear of the
	# projection key along the plot's top. A measured day's header is the
	# day and its note is on the card; a projected day's header says
	# projected and no line says what was done.
	card_failures : List({ name : Str, model : Ui.Model }), Scene.Measure -> List(Str)
	card_failures = |boards, face_measure|
		List.join(
			List.map(
				List.keep_if(boards, |f| !(List.is_empty(Board.shown_proj(f.model)))),
				|f| {
					g = Board.geom(f.model)
					plot = Board.plot_box(g)
					key = List.keep_if(Board.owned(f.model, face_measure), |o| Str.starts_with(o.key, "'dashed: projected"))
					cursors = List.concat(
						List.map_with_index(List.repeat({}, g.meas), |_u, b| { back: U64.to_i64_wrap(b), ahead: 0, at: "day -${U64.to_str(b)}" }),
						List.map_with_index(List.repeat({}, List.len(Board.shown_proj(f.model))), |_u, k| { back: 0, ahead: k + 1, at: "day +${U64.to_str(k + 1)}" }),
					)
					if List.is_empty(key) {
						["${f.name}: the board placed no projection key"]
					} else {
						List.join(
							List.map(
								cursors,
								|c| {
									mk = { ..f.model, cursor: c.back, cursor_ahead: c.ahead }
									at = "${f.name} ${c.at}"
									match Board.hovered(mk, g) {
										Err(_) => ["${at}: no day under the cursor"]
										Ok(i) => {
											hp = (List.get(g.data, i)) ?? { ctl: 0.0, atl: 0.0, tsb: 0.0, tss: 0.0 }
											day = (List.get(g.days, i)) ?? ""
											card = Board.tip_card(mk, g, i, hp, face_measure)
											owned = Scene.owned(Labels.place(card.lines, { boxes: [], segs: [] }))
											texts = List.map(owned, |o| o.key)
											b = card.box
											inside = b.x >= plot.x and b.y >= plot.y and b.x + b.w <= plot.x + plot.w and b.y + b.h <= plot.y + plot.h
											note = Db.note_for(mk.day_notes, day)
											says =
												if c.ahead > 0 {
													List.join([
														if (List.contains(texts, "'${day} projected'")) [] else ["the card does not say projected"],
														if (List.any(texts, |t| t == "'rest day'" or t == "'${note}'")) ["the card says what was done on a day still to come"] else [],
													])
												} else {
													List.join([
														if (List.contains(texts, "'${day}'")) [] else ["the card does not name its day"],
														if (List.any(texts, |t| t != "''" and Str.starts_with("'${note}'", Str.drop_suffix(t, "'")))) [] else ["the card does not carry the day's note"],
													])
												}
											List.map(
												List.join([
													Labels.check(owned),
													if (inside) [] else ["the card leaves the plot"],
													if (List.any(key, |o| Labels.intersects(o.box, b))) ["the card covers the projection key"] else [],
													says,
												]),
												|e| "${at}: ${e}",
											)
										}
									}
								},
							),
						)
					}
				},
			),
		)

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
							base = { ..athlete_model(a, sz), view: 4, plan: plan_rows(a), week_tss: { this: 412, last: 1385 }, bus_note: Note("11-12 08:14 plan / 30d"), plan_week: { done: 4, total: 6 } }
							[
								{ name: "${a.name} week at ${size_name(sz)}", model: base },
								{ name: "${a.name} week scrolled with the quest complete at ${size_name(sz)}", model: { ..base, week_off: 4, plan_week: { done: 6, total: 6 } } },
								{ name: "${a.name} week no coach has steered at ${size_name(sz)}", model: { ..base, bus_note: NoDirective } },
								{ name: "${a.name} week with the bus unreadable at ${size_name(sz)}", model: { ..base, bus_note: Unreadable } },
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
		List.map([0, 1, 2], |i| { title: "Evening ${sport_at(a, i)} along the lakefront path and back through the park [${sport_at(a, i)}]", stats: Db.stats_line({ mins: 62, dist: "42.1${du}", load: 85, np: 230 }), extra: "IF 0.84   142 bpm avg   rpe 6.0", zones: [600, 1500, 900, 420, 60] })
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

	# ── the map view's fixtures ────────────────────────────────────────────
	# the session the fixture routes belong to: a ride its meter measured,
	# named as long as the trace picker's cap lets a name be
	route_session : Db.RouteSession
	route_session = { id: 1, start: 1794738080, name: Db.cap_name(Str.repeat("W", 60)), day: "2026-11-15", sport: "Ride", dist_m: 160934.4, moving_s: 35940, watts: 1234 }

	# a route, in metres from the origin
	map_fixture : Db.MapData
	map_fixture = {
		route = [{ x: 0.0, y: 0.0 }, { x: 1200.0, y: 400.0 }, { x: 2600.0, y: -300.0 }]
		{
			routes: [{ kind: Db.route_kind, pts: route, ts: [0.0, 300.0, 600.0], far: route, fts: [0.0, 300.0, 600.0], bands: [2, 3], fbands: [], box: Geo.box_of(route), session: route_session }],
			origin: Geo.merc(41.88, -87.63),
			fit: Geo.box_of(route),
			focus: Geo.focus([{ start: { x: 0.0, y: 0.0 }, box: Geo.box_of(route) }]),
			err: "",
		}
	}

	# the same home route with one more standing in for Madrid, 9,389 km east
	# and 250 km south of a home near Chicago in projected metres
	madrid_fixture : Db.MapData
	madrid_fixture = {
		home = [{ x: 0.0, y: 0.0 }, { x: 1200.0, y: 400.0 }, { x: 2600.0, y: -300.0 }]
		away = [{ x: 9389000.0, y: -250000.0 }, { x: 9390000.0, y: -249500.0 }]
		lines = [{ kind: Db.route_kind, pts: home, ts: [0.0, 300.0, 600.0], far: home, fts: [0.0, 300.0, 600.0], bands: [2, 2], fbands: [2, 2], box: Geo.box_of(home), session: route_session }, { kind: Db.route_kind, pts: away, ts: [0.0, 400.0], far: away, fts: [0.0, 400.0], bands: [2], fbands: [2], box: Geo.box_of(away), session: { ..route_session, id: 2, start: route_session.start - 86400 } }]
		{
			routes: lines,
			origin: Geo.merc(41.88, -87.63),
			fit: List.fold(lines, Geo.no_box, |b, l| Geo.union(b, l.box)),
			focus: Geo.focus(List.keep_oks(lines, |l| (List.first(l.pts)).map_ok(|p| { start: p, box: l.box }))),
			err: "",
		}
	}

	# A tile of names, in tile units: a place of every kind, among them a
	# long name, and a street of every kind, level, upright, slanting, and
	# one bent too often to name. Drawn on every cell of a view, each name
	# repeats a tile apart, so the placer meets crowds of every kind.
	names_tile : Mvt.Tile
	names_tile = {
		place = |kind, rank, text, x, y| { kind, rank, text, pts: [{ x, y }] }
		street = |kind, text, pts| { kind, rank: 0, text, pts }
		zig = List.map_with_index(List.repeat({}, 41), |_, i| { x: U64.to_f32(i) * 100.0, y: if (i % 2 == 0) 3800.0 else 3900.0 })
		{
			fills: [],
			lines: [],
			names: [
				place(0, 1, "Chicago", 2048.0, 2048.0),
				place(1, 3, "Oak Park", 1000.0, 1200.0),
				place(2, 0, "Riverside", 3000.0, 800.0),
				place(3, 0, "Pilsen", 800.0, 3000.0),
				place(4, 0, "Ukrainian Village", 3100.0, 3200.0),
				place(4, 0, "Village of Fox River Grove Heights", 2600.0, 2500.0),
				street(5, "Dan Ryan Expressway", [{ x: 3500.0, y: 0.0 }, { x: 3500.0, y: 4096.0 }]),
				street(6, "West Cermak Road", [{ x: 0.0, y: 1500.0 }, { x: 4096.0, y: 1500.0 }]),
				street(6, "South Ashland Avenue", [{ x: 1500.0, y: 0.0 }, { x: 1500.0, y: 4096.0 }]),
				street(7, "North Milwaukee Avenue", [{ x: 0.0, y: 4096.0 }, { x: 2048.0, y: 2048.0 }, { x: 4096.0, y: 0.0 }]),
				street(8, "West 18th Street", [{ x: 0.0, y: 2600.0 }, { x: 4096.0, y: 2600.0 }]),
				street(8, "Lake Shore Drive", zig),
			],
		}
	}

	# the model with the fixture route's card up, opened at a point on screen
	with_card : Ui.Model, F32, F32 -> Ui.Model
	with_card = |m, sx, sy| { ..m, map_card: Open({ id: route_session.id, at: Geo.to_world(Map.cam(m), Map.rect(m.win), sx, sy), state: Ready }) }

	# the map with its names drawn on every tile, at the camera given, or at
	# the opening when it is Map.unpainted
	with_names : Ui.Model, Geo.Cam -> Ui.Model
	with_names = |m, c| {
		moved = if (c.mpp > 0.0) { ..m, map_moved: Bool.True, map_cam: c } else m
		with_tiles(moved, Drawn(names_tile), Known("t"))
	}

	# the model with every tile its view shows in one state, and the source
	# in another
	with_tiles : Ui.Model, [Fetching, Waiting, Drawn(Mvt.Tile), Failed(U64)], Tiles.Source -> Ui.Model
	with_tiles = |m, st, src| { ..m, map_source: src, map_tiles: List.map(Map.cells(m, Map.cam(m)), |c| { key: c.key, state: st, refresh: Done, used: 0 }) }

	# the map with routes and no tiles yet, while the tiles are fetched;
	# with its tiles drawn; with a tile of names drawn on every cell, at
	# the opening, wide, at street level, in playback with its clock, with
	# a note in the map's corner, and with a route's card up at the map's
	# middle, its top left corner, its right edge and its bottom right
	# corner, where the card is held inside the map; with its tiles failed
	# and the source unreachable, offline; in playback with a cache it
	# cannot write, whose message is longer than the map is wide; with a
	# route an ocean from the rest, in heat, in playback with its clock and
	# with no route to play, with no route at all, while it loads, and with
	# a read that failed whose message is longer than the map is wide, for
	# every athlete at every size
	map_models : List({ name : Str, model : Ui.Model })
	map_models =
		List.join(
			List.map(
				athletes,
				|a| List.join(
					List.map(
						sizes,
						|sz| {
							base = { ..athlete_model(a, sz), view: 10, map: map_fixture }
							[
								{ name: "${a.name} map at ${size_name(sz)}", model: base },
								{ name: "${a.name} map with its tiles at ${size_name(sz)}", model: with_tiles(base, Drawn(Mvt.empty), Known("t")) },
								{ name: "${a.name} map with its names at ${size_name(sz)}", model: with_names(base, Map.unpainted) },
								{ name: "${a.name} map with its names wide at ${size_name(sz)}", model: with_names(base, { ..Map.cam(base), mpp: 150.0 }) },
								{ name: "${a.name} map with its names at street level at ${size_name(sz)}", model: with_names(base, { ..Map.cam(base), mpp: 1.0 }) },
								{ name: "${a.name} map playback with its names at ${size_name(sz)}", model: with_names({ ..base, view: 12, map_play: { secs: 125.0, paused: Bool.False } }, Map.unpainted) },
								{ name: "${a.name} map with its names and a cache it cannot write at ${size_name(sz)}", model: with_names({ ..base, map_cache_err: Str.repeat("could not keep a street-map tile: ", 6) }, Map.unpainted) },
								{ name: "${a.name} map with its names and a card at the middle at ${size_name(sz)}", model: with_names(with_card(base, Map.rect(base.win).x + Map.rect(base.win).w / 2.0, Map.rect(base.win).y + Map.rect(base.win).h / 2.0), Map.unpainted) },
								{ name: "${a.name} map with its names and a card at the top left at ${size_name(sz)}", model: with_names(with_card(base, Map.rect(base.win).x + 1.0, Map.rect(base.win).y + 1.0), Map.unpainted) },
								{ name: "${a.name} map with its names and a card at the right edge at ${size_name(sz)}", model: with_names(with_card(base, Map.rect(base.win).x + Map.rect(base.win).w - 1.0, Map.rect(base.win).y + Map.rect(base.win).h / 2.0), Map.unpainted) },
								{ name: "${a.name} map with its names and a card at the bottom right at ${size_name(sz)}", model: with_names(with_card(base, Map.rect(base.win).x + Map.rect(base.win).w - 1.0, Map.rect(base.win).y + Map.rect(base.win).h - 1.0), Map.unpainted) },
								{ name: "${a.name} map offline at ${size_name(sz)}", model: with_tiles(base, Failed(0), Unreachable(0)) },
								{ name: "${a.name} map with a cache it cannot write at ${size_name(sz)}", model: { ..base, view: 12, map_cache_err: Str.repeat("could not keep a street-map tile: ", 6) } },
								{ name: "${a.name} map without routes at ${size_name(sz)}", model: { ..base, map: Db.no_map } },
								{ name: "${a.name} map with a route an ocean away at ${size_name(sz)}", model: { ..base, map: madrid_fixture } },
								{ name: "${a.name} map heat at ${size_name(sz)}", model: { ..base, view: 11 } },
								{ name: "${a.name} map playback at ${size_name(sz)}", model: { ..base, view: 12, map_play: { secs: 125.0, paused: Bool.False } } },
								{ name: "${a.name} map playback with no routes at ${size_name(sz)}", model: { ..base, view: 12, map: Db.no_map } },
								{ name: "${a.name} map loading at ${size_name(sz)}", model: { ..base, map: Db.no_map, map_load: Loading } },
								{ name: "${a.name} map with a failed read at ${size_name(sz)}", model: { ..base, map: { ..Db.no_map, err: Str.repeat("could not read the routes: ", 8) } } },
							]
						},
					),
				),
			),
		)

	# the map's card at the default window for every athlete: up for a
	# route of each family's longest sport type and of a sport no family
	# holds, its name as long as the cap lets one be, with a measured power
	# and without, in every state, anchored at the map's middle, at each of
	# its corners and past each of its edges, where a pan leaves a clicked
	# point; and in heat and play at the middle
	card_models : List({ name : Str, model : Ui.Model })
	card_models = {
		sports = List.append(List.map(Sports.families, |fam| List.fold(fam.sports, "", |w, s| if (Str.count_utf8_bytes(s) > Str.count_utf8_bytes(w)) s else w)), rare)
		states = [{ n: "ready", st: Ready }, { n: "opening", st: Opening }, { n: "without a trace", st: NoTrace }]
		List.join(
			List.map(
				athletes,
				|a| {
					base = { ..athlete_model(a, default_size), view: 10, map: map_fixture }
					r = Map.rect(base.win)
					c = Map.cam(base)
					spots = [{ n: "middle", x: r.x + r.w / 2.0, y: r.y + r.h / 2.0 }, { n: "top left", x: r.x + 1.0, y: r.y + 1.0 }, { n: "top right", x: r.x + r.w - 1.0, y: r.y + 1.0 }, { n: "bottom left", x: r.x + 1.0, y: r.y + r.h - 1.0 }, { n: "bottom right", x: r.x + r.w - 1.0, y: r.y + r.h - 1.0 }, { n: "left of the map", x: r.x - 300.0, y: r.y + r.h / 2.0 }, { n: "right of the map", x: r.x + r.w + 300.0, y: r.y + r.h / 2.0 }, { n: "above the map", x: r.x + r.w / 2.0, y: r.y - 300.0 }, { n: "below the map", x: r.x + r.w / 2.0, y: r.y + r.h + 300.0 }]
					up = |sport, watts, st, sx, sy, v| {
						s = { ..route_session, sport, watts }
						{ ..base, view: v, map: { ..map_fixture, routes: List.map(map_fixture.routes, |l| { ..l, session: s }) }, map_card: Open({ id: s.id, at: Geo.to_world(c, r, sx, sy), state: st }) }
					}
					per_sport = List.join(
						List.map(
							sports,
							|sp| List.join(
								List.map(
									states,
									|s0| List.join(
										List.map(
											spots,
											|p0| [
												{ name: "${a.name} card for a ${sp} ${s0.n} at the ${p0.n}", model: up(sp, 0, s0.st, p0.x, p0.y, 10) },
												{ name: "${a.name} card for a ${sp} with power ${s0.n} at the ${p0.n}", model: up(sp, 1234, s0.st, p0.x, p0.y, 10) },
											],
										),
									),
								),
							),
						),
					)
					modes = List.map([11, 12], |v| { name: "${a.name} card in view ${U8.to_str(v)}", model: up("Ride", 1234, Ready, r.x + r.w / 2.0, r.y + r.h / 2.0, v) })
					List.concat(per_sport, modes)
				},
			),
		)
	}

	# a card's failures: a line outside the card or over another, the card
	# outside the map, or no card where one is up
	card_judge : Ui.Model, Scene.Measure -> List(Str)
	card_judge = |m, ms|
		match Map.card(m, ms) {
			Ok(cd) => List.concat(Labels.check(Scene.owned(Labels.place(cd.lines, { boxes: [], segs: [] }))), if (Labels.inside(cd.box, Map.rect(m.win))) [] else ["the card leaves the map"])
			Err(_) => ["no card is up"]
		}

	# the hover card's failures over the cells it is read from: the year's
	# first day, which has no session note, and its last week, whose days
	# carry short and long ones. A line outside the card, over another, or
	# naming a load TSS fails, and so does a hovered cell with no card.
	tip_judge : Ui.Model, Scene.Measure -> List(Str)
	tip_judge = |m, ms| {
		cells = (Heat.layout(m)).cells
		hovered = List.concat(List.take_first(cells, 1), List.take_last(cells, 7))
		List.join(
			List.map(
				hovered,
				|c| match Heat.tip({ ..m, mouse_x: c.x + 1.0, mouse_y: c.y + 1.0 }, ms) {
					Ok(t) => List.map(judge(Scene.owned(Labels.place(t.lines, { boxes: [], segs: [] })), []), |e| "${c.h.day}: ${e}")
					Err(_) => ["${c.h.day}: no card is up"]
				},
			),
		)
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
							base = { ..athlete_model(a, sz), view: 5, heat: year_days, day_notes: day_notes_of(a) }
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
	# biggest, a rest week in the middle and the running week partial
	week_share : U64 -> I64
	week_share = |i| (List.get([140, 90, 100, 110, 60, 0, 105, 115, 120, 95, 100, 40], i)) ?? 100

	# a lifting week (zone time and no polarized time) sits beside the
	# empty rest week, so one fixture draws a week with no segments
	zone_weeks_of : U64 -> List(Db.ZoneWeek)
	zone_weeks_of = |k|
		List.map_with_index(
			week_starts,
			|wk, i| {
				s = week_share(i) * (60 + 15 * U64.to_i64_wrap(k % 5))
				z = { z1: s * 25, z2: s * 40, z3: s * 18, z4: s * 12, z5: s * 5 }
				lifting = i == 4
				easy = if (lifting) 0 else z.z1 + z.z2 - (if (i % 3 == 1) s * 30 else 0)
				moderate = if (lifting) 0 else z.z3 + (if (i % 3 == 1) s * 30 else 0)
				{ wk, days: if (i == 11) 4 else 7, z1: z.z1, z2: z.z2, z3: z.z3, z4: z.z4, z5: z.z5, easy, moderate, hard: if (lifting) 0 else z.z4 + z.z5 }
			},
		)

	# each week starts from the CTL its ramp left the week before, except
	# that the running week starts unrounded, 0.06 under, so its end and
	# start rounded apart read a tenth more than its ramp; and for every
	# other athlete the rest week reads a start far above its end, which
	# only the focus line's hold reads: a bar draws the ramp
	ramp_weeks_of : U64 -> List(Db.RampWeek)
	ramp_weeks_of = |k|
		List.map_with_index(
			week_starts,
			|wk, i| {
				tss = week_share(i) * (4 + U64.to_i64_wrap(k % 4))
				ctl10 = 480 + U64.to_i64_wrap(i) * 7
				ramp10 = (List.get([75, -12, 18, 31, 0, -19, 42, 64, 25, 8, 12, -5], i)) ?? 0
				ctl_start = if (i == 5 and k % 2 == 1) 150.0 else if (i == 11) I64.to_f64(ctl10 - ramp10) / 10.0 - 0.06 else I64.to_f64(ctl10 - ramp10) / 10.0
				{ wk, days: if (i == 11) 4 else 7, tss, ctl10, ramp10, ctl_start }
			},
		)

	# the load mode's edges: two weeks before the athlete's history, with no
	# load and no CTL yet, a first week of history that counts its whole
	# CTL as its change, and a running week two days in that has lost
	# fitness so far
	edge_ramp : List(Db.RampWeek) -> List(Db.RampWeek)
	edge_ramp = |weeks|
		List.map_with_index(
			weeks,
			|w, i|
				if i < 2 {
					{ ..w, tss: 0, ctl10: 0, ramp10: 0, ctl_start: 0.0 }
				} else if i == 2 {
					{ ..w, ctl10: 113, ramp10: 0, ctl_start: 0.0 }
				} else if i == 11 {
					{ ..w, days: 2, ramp10: -8, ctl_start: I64.to_f64(w.ctl10 + 8) / 10.0 }
				} else {
					w
				},
		)

	# the load weeks with every change turned to a gain, or to a loss, each
	# week's start read back from its end
	signed_ramp : List(Db.RampWeek), I64 -> List(Db.RampWeek)
	signed_ramp = |weeks, sign| List.map(
		weeks,
		|w| {
			r = sign * (if (w.ramp10 < 0) 0 - w.ramp10 else w.ramp10)
			{ ..w, ramp10: r, ctl_start: I64.to_f64(w.ctl10 - r) / 10.0 }
		},
	)

	# the running week two days in, in the zones mode
	edge_zones : List(Db.ZoneWeek) -> List(Db.ZoneWeek)
	edge_zones = |weeks| List.map_with_index(weeks, |w, i| if (i == 11) { ..w, days: 2 } else w)

	# Whether a weeks scene reads every week the same way under its bar:
	# one date and one figure centred on each column, on the date and the
	# figure rows, nothing else on the figure row, and "so far" over each
	# running week's column alone, its foot within 8 px over `under`, the
	# top of what the column draws highest.
	week_rows : List(Labels.Placed(Scene.Item)), List({ cx : F32, date : Str, under : F32, running : Bool }), F32 -> Bool
	week_rows = |placed, cols, win_h| {
		centred = |p, cx| (p.box.x + p.box.w / 2.0 - cx).abs() < 0.5
		on_row = |p, y| (p.box.y - y).abs() < 0.01
		so_far = List.keep_if(placed, |p| p.item.text == "so far")
		figures = List.keep_if(placed, |p| on_row(p, Weeks.figure_row(win_h)))
		!(List.is_empty(cols))
			and List.all(cols, |c| List.count_if(placed, |p| p.item.text == c.date and centred(p, c.cx) and on_row(p, Weeks.date_row(win_h))) == 1)
			and List.len(figures) == List.len(cols)
			and List.all(cols, |c| List.count_if(figures, |p| centred(p, c.cx)) == 1)
			and List.len(so_far) == List.count_if(cols, |c| c.running)
			and List.all(so_far, |p| List.any(cols, |c| c.running and centred(p, c.cx) and p.box.y + p.box.h <= c.under and p.box.y + p.box.h >= c.under - 8.0))
	}

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
									{ name: "${a.name} lifts in pounds, scrolled at ${size_name(sz)}", model: { ..base, strength: strength_of(Imperial), lifts_off: 10, last_off: 4 } },
								]
							} else {
								[{ name: "${a.name} lifts with no lifting at ${size_name(sz)}", model: base }]
							}
						},
					),
				),
			),
		)

	# the default window at the default scale, in logical units
	default_size : { w : F32, h : F32 }
	default_size = {
		l = DisplayScale.layout(DisplayScale.default_percent, { w: I32.to_f32(Theme.win_w), h: I32.to_f32(Theme.win_h) })
		{ w: l.w, h: l.h }
	}

	# the lifts view for a lifter whose latest session logs the first `n`
	# of set_rows, with no unlogged session above it
	session_model : U64, { w : F32, h : F32 } -> Ui.Model
	session_model = |n, sz| {
		lifter = { name: "lifter", units: Imperial, sports: [{ sport: "WeightTraining", sessions: 140 }] }
		sv = strength_of(Imperial)
		last = { ..sv.last, log: { rows: List.take_first(set_rows, n), pasted: Bool.False } }
		{ ..athlete_model(lifter, sz), view: 9, strength: { ..sv, last, unlogged: [] } }
	}

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
								{ name: "${a.name} ${mode} on a picked week at ${size_name(sz)}", model: { ..base, week_cursor: "2026-11-09" } },
								{ name: "${a.name} ${mode} with no history at ${size_name(sz)}", model: { ..base, zone_weeks: [], ramp_weeks: [] } },
								{ name: "${a.name} ${mode} at its edges at ${size_name(sz)}", model: { ..base, zone_weeks: edge_zones(base.zone_weeks), ramp_weeks: edge_ramp(base.ramp_weeks) } },
								{ name: "${a.name} ${mode} with gains alone at ${size_name(sz)}", model: { ..base, ramp_weeks: signed_ramp(base.ramp_weeks, 1) } },
								{ name: "${a.name} ${mode} with losses alone at ${size_name(sz)}", model: { ..base, ramp_weeks: signed_ramp(base.ramp_weeks, -1) } },
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

# the power view's gate: every curve and range of every athlete, sports
# under long Strava names, and the rows' and the card's other strings, at
# every size, in the brand faces and in the built-in face; no text over a
# chip, the test card, a dot or a legend dot
expect Gate.failures(|m| Gate.judge(Curve.owned(m, Gate.measure), Curve.marks(m, Gate.measure)), List.join([Gate.curve_models, Gate.long_models, Gate.story_models])) == []
expect Gate.failures(|m| Gate.judge(Curve.owned(m, Gate.builtin_measure), Curve.marks(m, Gate.builtin_measure)), List.join([Gate.curve_models, Gate.long_models, Gate.story_models])) == []

# the gate above judges the strings it claims to: a card whose line wraps
# at the minimum window and none at the wide one, a run's two ways to a
# threshold, both test-due lines (bests not flat out, too few to fit), a
# threshold that could not be read, a test that set the threshold and one
# under the derivation, a usable fit, the empty window before, an empty row
# that never had a best on a power and a pace curve and one whose best is
# older than both windows, a level row, a row only the window before has
# and one only this window has, and both long sport names in plain words
# are all on screen somewhere
expect {
	models = List.join([Gate.curve_models, Gate.long_models, Gate.story_models])
	texts = |f| List.map(Curve.scene(f.model, Gate.measure), |p| p.item.text)
	all = List.join(List.map(models, texts))
	lines_at = |sz| List.map(List.keep_if(models, |f| Str.contains(f.name, "at ${sz}")), |f| List.len((Curve.story(f.model, Gate.measure)).lines))
	shows = |s| List.any(all, |t| Str.starts_with(t, s))
	shows("No threshold pace yet - run 20 minutes")
		and List.any(lines_at("980x600"), |n| n >= 2)
		and List.all(lines_at("2560x1440"), |n| n == 1)
		and shows("Test due: your 5, 10 and 20-minute bests of the last 60 days were not flat out") and shows("Test due: too few hard 5 to 20-minute efforts in the last 90 days")
		and List.any(all, |t| Str.contains(t, "set by your test on 10-27"))
		and List.any(all, |t| Str.ends_with(t, "- no test due"))
		and shows("the 90 days before: no runs")
		and shows("no 20 minutes without stopping yet")
		and shows("no 60-minute ride yet")
		and List.contains(all, "level")
		and List.contains(all, "none in the last 90 days")
		and List.contains(all, "none before")
		and shows("no 60-minute session yet")
		and shows("Your FTP could not be read from stride")
		and List.contains(all, "none in the last 180 days")
		and List.any(all, |t| Str.contains(t, "from your best 20 minutes of the last 60 days, higher than your test on 10-27"))
		and List.any(all, |t| Str.contains(t, "stand up paddling"))
		and List.any(all, |t| Str.contains(t, "high intensity interval training"))
}

# the career view's gate: every page of every athlete at every size, the
# pages without a trend among them; no text over a chip, a card, a dot, a
# load bar, a legend swatch or the strip
expect Gate.failures(|m| Gate.judge(Career.owned(m, Gate.measure), Career.marks(m, Gate.measure)), Gate.career_models) == []

# the same gate in the built-in face, which the window falls back to when
# the brand fonts cannot be read: the window then places the kind chips by
# that face too, so the models carry it as their font
expect Gate.failures(|m| Gate.judge(Career.owned(m, Gate.builtin_measure), Career.marks(m, Gate.builtin_measure)), List.map(Gate.career_models, |e| { ..e, model: { ..e.model, font: Gate.builtin_font } })) == []

# the career fixtures carry pages without a trend: the short runner's
# running page at every size, and a database with no threshold at all,
# where every page is one
expect {
	none = List.keep_if(Gate.career_models, |e| (Career.spine_at(e.model.career_spines, e.model.spine_idx)).kind == Career.no_trend)
	runs = List.keep_if(none, |e| Str.starts_with(e.name, Gate.short_runner.name) and Str.ends_with(e.name, " Run none"))
	List.len(runs) == List.len(Gate.sizes) and List.any(none, |e| Str.contains(e.name, "with no threshold"))
}

# the short runner's running page says why it draws no line and what would
# draw one, in both faces; the rides page beside it draws its trend and
# none of those words
expect {
	at = |fam| List.keep_if(Gate.career_models, |e| Str.starts_with(e.name, Gate.short_runner.name) and (Career.spine_at(e.model.career_spines, e.model.spine_idx)).fam == fam)
	says = |e, measure, t| List.any(Career.owned(e.model, measure), |o| o.key == "'${t}'")
	words = ["No running trend yet", "stride test <activity_id> 5k"]
	List.all(
		[Gate.measure, Gate.builtin_measure],
		|measure| List.all(at("Run"), |e| List.all(words, |t| says(e, measure, t)))
			and List.all(at("Ride"), |e| !(List.any(words, |t| says(e, measure, t)))),
	)
		and !(List.is_empty(at("Ride")))
}

# a first run in both faces: the empty board and the empty career name
# `stride setup` and the key that loads what it wrote; a board one day long
# and a career one ride long say the history is short, not that it is empty
expect {
	says = |owned, t| List.any(owned, |o| o.key == "'${t}'")
	boards = |name| List.keep_if(Gate.board_models, |f| Str.starts_with(f.name, name))
	careers = |name| List.keep_if(Gate.career_models, |e| Str.starts_with(e.name, name))
	faces = [{ measure: Gate.measure, font: Gate.data_font }, { measure: Gate.builtin_measure, font: Gate.builtin_font }]
	List.all(
		faces,
		|f| {
			board = |m| Board.owned({ ..m, font: f.font }, f.measure)
			career = |m| Career.owned({ ..m, font: f.font }, f.measure)
			List.all(boards("form with no data"), |e| says(board(e.model), Board.empty_text))
				and List.all(boards("form with one day"), |e| says(board(e.model), Board.one_day_text) and !(says(board(e.model), Board.empty_text)))
				and List.all(careers("empty career"), |e| says(career(e.model), Career.empty_text))
				and List.all(careers("one ride career"), |e| says(career(e.model), Career.one_month_text) and !(says(career(e.model), Career.empty_text)))
		},
	)
		and List.len(boards("form with one day")) == List.len(Gate.sizes)
		and List.len(careers("one ride career")) == List.len(Gate.sizes)
		and List.all([Board.empty_text, Career.empty_text], |t| Str.contains(t, "stride setup") and Str.contains(t, "press R"))
}

# the form board's gate: every athlete's board at every range, with an
# event ahead and a projection, with the event-day story, and with an event
# the projection reaches, at every size, and the two boards with no plot,
# in the brand faces and in the built-in face; no text over a chip, a
# tile, a load bar or a planned load bar
expect Gate.failures(|m| Gate.judge(Board.owned(m, Gate.measure), Board.marks(m)), Gate.board_models) == []
expect Gate.failures(|m| Gate.judge(Board.owned(m, Gate.builtin_measure), Board.marks(m)), Gate.board_models_in(Gate.builtin_font)) == []

# the projection fixtures draw what the gate claims: every board with an
# event ahead or one the projection reaches carries twenty projected days,
# hollow bars among its load bars, and the projection's key on the plot
expect List.all(
	List.keep_if(Gate.board_models, |f| Str.contains(f.name, "event=0") or Str.contains(f.name, "event=2")),
	|f| {
		keys = List.map(Board.marks(f.model), |m| m.key)
		texts = List.map(Board.owned(f.model, Gate.measure), |o| o.key)
		List.len(f.model.proj) == 20
			and List.any(keys, |k| Str.starts_with(k, "the planned load bar on 2026-12-"))
			and List.any(texts, |t| Str.starts_with(t, "'dashed: projected"))
	},
)

# a board with a projection plots the range's measured days and then the
# projected ones, its lines ending on the plan's last day at the plot's
# right edge and the line-end values reading that day; a hollow bar marks
# each projected day the plan priced a load onto, no bar lies past the
# plan's last day, and a day priced nothing draws none
expect {
	m = Gate.board_model(Gate.athlete_model(Gate.first_athlete, Gate.default_size), Gate.first_athlete, 0, 30, 0)
	g = Board.geom(m)
	bs = Board.bars(g)
	planned = List.keep_if(bs, |b| b.planned)
	last = (List.last(m.proj)) ?? { day: "", ctl: 0.0, atl: 0.0, tsb: 0.0, tss: 0.0, known: Bool.False }
	g.meas == 30
		and g.n == 50
		and List.last(g.days) == Ok("2026-12-02")
		and (Board.x_at(g, g.n - 1) - (g.left + g.pw)).abs() < 0.01
		and Board.end_text(g.data, 0) == "CTL ${Db.fmt_f(last.ctl)}"
		and List.map(planned, |b| b.day) == List.keep_oks(m.proj, |d| if (d.tss > 0.0) Ok(d.day) else Err(Rest))
		and List.len(planned) == 14
		and List.all(bs, |b| b.box.x + b.box.w <= g.left + g.pw + 0.01)
		and List.all(List.keep_if(bs, |b| !(b.planned)), |b| !(List.contains(Gate.proj_days, b.day)))
}

# the board's arrow cursor counts back from the latest measured day, and
# the pointer reads every day the board draws, the projected end included,
# whose card says it is projected and reads the plan's load
expect {
	a = Gate.first_athlete
	m = Gate.board_model(Gate.athlete_model(a, Gate.default_size), a, 0, 30, 0)
	g = Board.geom(m)
	at_right = { ..m, mouse_in: Bool.True, mouse_x: g.left + g.pw, mouse_y: g.top + 10.0 }
	card = Board.tip_card(at_right, g, g.n - 1, (List.last(g.data)) ?? { ctl: 0.0, atl: 0.0, tsb: 0.0, tss: 0.0 }, Gate.measure)
	texts = List.map(Scene.owned(Labels.place(card.lines, { boxes: [], segs: [] })), |o| o.key)
	Board.hovered({ ..m, cursor: 0 }, g) == Ok(29)
		and Board.hovered({ ..m, cursor: 3 }, g) == Ok(26)
		and Board.hovered(at_right, g) == Ok(49)
		and List.contains(texts, "'2026-12-02 projected'")
		and List.contains(texts, "'Planned load'")
}

# the arrow cursor walks on past the latest measured day into each
# projected day the board draws, and past the last of them turns off; a
# directive's day finds a measured day by days back and a projected one by
# days ahead on the board, and is refused with its reason otherwise: a
# projected day on the table, a day past the projection, before the
# series, after it with no plan projected, or no date at all. Focus reads
# a projected cursor's day, held to the last drawn; the table holds the
# latest measured day in place of a projected one; a parked cursor holds
# the crosshair while the pointer rests inside the plot
expect {
	a = Gate.first_athlete
	m = Gate.board_model(Gate.athlete_model(a, Gate.default_size), a, 0, 30, 0)
	g = Board.geom(m)
	walk = List.fold(List.repeat({}, 20), [{ back: 0, ahead: 0 }], |acc, _u| List.append(acc, Board.step((List.last(acc)) ?? { back: -1, ahead: 0 }, Newer, 20)))
	at = |c| Board.hovered({ ..m, cursor: c.back, cursor_ahead: c.ahead }, g)
	short = { ..m, data: List.take_first(m.data, 1), days: List.take_first(m.days, 1) }
	unplanned = { ..m, proj: [] }
	List.len(Board.shown_proj(m)) == 20
		and List.map(walk, at) == List.map_with_index(List.repeat({}, 21), |_u, i| Ok(29 + i))
		and Board.step({ back: 0, ahead: 20 }, Newer, 20) == { back: -1, ahead: 0 }
		and Board.step({ back: 0, ahead: 1 }, Older, 20) == { back: 0, ahead: 0 }
		and at({ back: 0, ahead: 25 }) == Ok(49)
		and Board.hovered({ ..m, cursor: 0, cursor_ahead: 5, mouse_in: Bool.True, mouse_x: g.left, mouse_y: g.top + 10.0 }, g) == Ok(34)
		and Board.hovered({ ..m, mouse_in: Bool.True, mouse_x: g.left, mouse_y: g.top + 10.0 }, g) == Ok(0)
		and Board.cursor_at(m, "2026-11-12", 0) == Ok({ back: 0, ahead: 0 })
		and Board.cursor_at(m, "2026-11-09", 0) == Ok({ back: 3, ahead: 0 })
		and Board.cursor_at(m, "2026-11-09", 3) == Ok({ back: 3, ahead: 0 })
		and Board.cursor_at(m, "2026-11-13", 0) == Ok({ back: 0, ahead: 1 })
		and Board.cursor_at(m, "2026-12-02", 0) == Ok({ back: 0, ahead: 20 })
		and Board.cursor_at(m, "2026-11-13", 3) == Err("a projected day, and this view draws no projection")
		and Board.cursor_at(m, "2026-12-03", 0) == Err("past the projection's last day, 2026-12-02")
		and Board.cursor_at(m, "2026-08-01", 0) == Err("before the series, which starts 2026-08-15")
		and Board.cursor_at(unplanned, "2026-11-13", 0) == Err("after the last measured day, 2026-11-12, and no plan is projected")
		and Board.cursor_at(short, "2026-11-13", 0) == Err("after the last measured day, 2026-08-15, and no plan is projected")
		and Board.cursor_at(m, "2026-13-45x", 0) == Err("not a YYYY-MM-DD date")
		and Board.held({ back: 0, ahead: 5 }, 3) == { back: 0, ahead: 0 }
		and Board.held({ back: 0, ahead: 5 }, 0) == { back: 0, ahead: 5 }
		and Board.held({ back: 4, ahead: 0 }, 3) == { back: 4, ahead: 0 }
		and Board.held({ back: -1, ahead: 0 }, 3) == { back: -1, ahead: 0 }
		and Board.ahead_day(m, 1) == "2026-11-13"
		and Board.ahead_day(m, 99) == "2026-12-02"
		and Board.ahead_day(m, 0) == ""
		and Board.ahead_day(short, 1) == ""
}

# the arrow keys' steps: older from off lands on the latest measured day,
# newer from a measured day walks toward it and from it on into the
# projected days, and a board with none turns off there
expect {
	today = { back: 0, ahead: 0 }
	Board.step({ back: -1, ahead: 0 }, Older, 3) == today
		and Board.step(today, Older, 3) == { back: 1, ahead: 0 }
		and Board.step({ back: 2, ahead: 0 }, Newer, 3) == { back: 1, ahead: 0 }
		and Board.step(today, Newer, 3) == { back: 0, ahead: 1 }
		and Board.step({ back: 0, ahead: 2 }, Newer, 3) == { back: 0, ahead: 3 }
		and Board.step({ back: 0, ahead: 3 }, Newer, 3) == { back: -1, ahead: 0 }
		and Board.step({ back: 0, ahead: 2 }, Older, 3) == { back: 0, ahead: 1 }
		and Board.step(today, Newer, 0) == { back: -1, ahead: 0 }
		and Board.step({ back: -1, ahead: 0 }, Newer, 3) == { back: -1, ahead: 0 }
}

# the day card the cursor opens over every measured and projected day of
# every board that draws a projection, judged as Gate.card_failures states,
# in the brand faces and in the built-in face
expect Gate.card_failures(Gate.board_models, Gate.measure) == []
expect Gate.card_failures(Gate.board_models_in(Gate.builtin_font), Gate.builtin_measure) == []

# the event the projection reaches is marked on the projection's last day
expect {
	a = Gate.first_athlete
	m = Gate.board_model(Gate.athlete_model(a, Gate.default_size), a, 0, 60, 2)
	g = Board.geom(m)
	m.ev_found and (Board.x_at(g, m.ev_idx - g.off) - (g.left + g.pw)).abs() < 0.01
}

# a series too short to plot draws no projection after it
expect {
	a = Gate.first_athlete
	m = Gate.board_model(Gate.athlete_model(a, Gate.default_size), a, 0, 30, 0)
	g = Board.geom({ ..m, data: List.take_first(m.data, 1), days: List.take_first(m.days, 1) })
	g.n == 1 and g.meas == 1
}

# the session trace's gate: every session of every athlete at home and
# zoomed with a ghost, and the three blank plots, at every size
expect Gate.failures(|m| Gate.judge(Trace.owned(m, Gate.measure), Trace.marks(m)), Gate.trace_models) == []

# the day tab's gates: the week with its card, ladder, scroll hints and
# quest, the log with a day open and loading, and the year with and without
# event days, for every athlete at every size
expect Gate.failures(|m| Gate.judge(Plan.owned(m, Gate.measure), Plan.marks(m)), Gate.plan_models) == []
expect Gate.failures(|m| Gate.judge(Table.owned(m, Gate.measure), Table.marks(m)), Gate.table_models) == []
expect Gate.failures(|m| Gate.judge(Heat.owned(m, Gate.measure), Heat.marks(m)), Gate.heat_models) == []

# the same three in the built-in face the window falls back to without the
# brand fonts, and the heat tab's hover card in both faces
expect Gate.failures(|m| Gate.judge(Plan.owned(m, Gate.builtin_measure), Plan.marks(m)), Gate.plan_models) == []
expect Gate.failures(|m| Gate.judge(Table.owned(m, Gate.builtin_measure), Table.marks(m)), Gate.table_models) == []
expect Gate.failures(|m| Gate.judge(Heat.owned(m, Gate.builtin_measure), Heat.marks(m)), Gate.heat_models) == []
expect Gate.failures(|m| Gate.tip_judge(m, Gate.measure), Gate.heat_models) == []
expect Gate.failures(|m| Gate.tip_judge(m, Gate.builtin_measure), Gate.heat_models) == []

# the coach corner draws nothing until a directive exists, the directive
# once one does, and says so when the bus cannot be read
expect {
	m = { ..Gate.empty_model({ w: 1280.0, h: 800.0 }), view: 4 }
	coach = |note| List.keep_if(List.map(Plan.owned({ ..m, bus_note: note }, Gate.measure), |t| t.key), |k| Str.starts_with(k, "'coach:"))
	coach(NoDirective) == [] and coach(Note("11-12 08:14  ->  plan / 30d")) == ["'coach: 11-12 08:14  ->  plan / 30d'"] and coach(Unreadable) == ["'coach: directives unreadable'"]
}

# the wording rule: "tss" as a word fails in any case and beside any
# punctuation; a word holding those letters, and the word load, pass
expect Gate.names_tss("74 tss this week") and Gate.names_tss("'85 TSS'") and Gate.names_tss("load (Tss)") and Gate.names_tss("tss")
expect !(Gate.names_tss("74 load this week")) and !(Gate.names_tss("rtss 40")) and !(Gate.names_tss("stress")) and !(Gate.names_tss("tssb"))
expect Gate.wording([{ key: "'62 min  85 tss'", box: { x: 0.0, y: 0.0, w: 1.0, h: 1.0 }, region: { x: 0.0, y: 0.0, w: 1.0, h: 1.0 } }]) == ["'62 min  85 tss' names a load TSS; the window says load"]

# the map's gate, over every map fixture
expect Gate.failures(|m| Gate.judge(Map.owned(m, Gate.measure), Map.marks(m, Gate.measure)), Gate.map_models) == []

# the weeks tab's gates: zones and load for every athlete at every size,
# with no week picked, on a picked week, with no history, and at the load
# mode's edges, in the brand faces and in the built-in face
expect Gate.failures(|m| Gate.judge(Zones.owned(m, Gate.measure), Zones.marks(m, Gate.measure)), Gate.weeks_models(6)) == []
expect Gate.failures(|m| Gate.judge(Zones.owned(m, Gate.builtin_measure), Zones.marks(m, Gate.builtin_measure)), Gate.weeks_models(6)) == []
expect Gate.failures(|m| Gate.judge(Ramp.owned(m, Gate.measure), Ramp.marks(m, Gate.measure)), Gate.weeks_models(7)) == []
expect Gate.failures(|m| Gate.judge(Ramp.owned(m, Gate.builtin_measure), Ramp.marks(m, Gate.builtin_measure)), Gate.weeks_models(7)) == []

# wherever the zones chart draws, every week with polarized time is a share
# bar the plot's full height, the lifting week keeps its stub, and one
# 80/20 line crosses them
expect List.all(
	List.keep_if(Gate.weeks_models(6), |e| !(List.is_empty(e.model.zone_weeks))),
	|e| {
		bs = Zones.bars(e.model)
		ks = List.map(Zones.marks(e.model, Gate.measure), |m| m.key)
		List.all(bs, |b| if (Zones.split_s(b.w) > 0) ((b.box.h - Zones.plot_h(e.model.win.h)).abs() < 0.01) else (b.box.h - 3.0).abs() < 0.01)
			and List.any(bs, |b| b.w.wk == "2026-09-21" and Zones.split_s(b.w) == 0)
			and List.count_if(ks, |k| k == "the 80/20 line") == 1
	},
)

# both modes read every week the same way under its bar, its date and
# then its figure, and put "so far" over the running week alone: over its
# bar in zones; in load over its chip on a gain, and over the bar's top at
# the line on a loss
expect List.all(
	List.keep_if(Gate.weeks_models(6), |e| !(List.is_empty(e.model.zone_weeks))),
	|e| Gate.week_rows(Zones.scene(e.model, Gate.measure), List.map(Zones.bars(e.model), |b| { cx: b.cx, date: Weeks.week_label(b.w.wk), under: b.box.y, running: Weeks.partial(b.w.days) }), e.model.win.h),
)
expect List.all(
	List.keep_if(Gate.weeks_models(7), |e| !(List.is_empty(e.model.ramp_weeks))),
	|e| Gate.week_rows(Ramp.scene(e.model, Gate.measure), List.map(Ramp.bars(e.model), |b| { cx: b.cx, date: Weeks.week_label(b.w.wk), under: if (Ramp.down(b)) b.box.y else (Ramp.chip_box(b)).y, running: b.drawn and b.outlined }), e.model.win.h),
)

# wherever the load chart draws, one zero line crosses it and no chip
# touches it, and in both faces the line reads its 0 centred where it
# crosses, its one name, "holds fitness", just over the 0 or, where the
# scale's top crowds it, just under, both whole in the gutter and clear of
# every bar
expect List.all(
	List.keep_if(Gate.weeks_models(7), |e| !(List.is_empty(e.model.ramp_weeks))),
	|e| {
		line = Ramp.line_box(e.model.win, Ramp.scale_of(e.model.ramp_weeks))
		ly = line.y + 1.0
		ks = List.map(Ramp.marks(e.model, Gate.measure), |m| m.key)
		in_gutter = |p| p.box.x >= (Labels.panel(e.model.win)).x and p.box.x + p.box.w <= Weeks.plot_left - 2.0 and List.all(Ramp.drawn_bars(e.model), |b| !(Labels.intersects(p.box, b.box)))
		named = |measure| {
			placed = Ramp.scene(e.model, measure)
			names = List.keep_if(placed, |p| p.item.text == Ramp.line_label)
			zeros = List.keep_if(placed, |p| p.item.text == "0" and p.box.x + p.box.w <= Weeks.plot_left)
			List.len(names) == 1
				and List.len(zeros) == 1
				and List.all(zeros, |v| in_gutter(v) and (v.box.y + v.box.h / 2.0 - ly).abs() < 1.0)
				and List.all(names, |n| in_gutter(n) and List.all(zeros, |v| (n.box.y + n.box.h <= v.box.y and n.box.y + n.box.h >= v.box.y - 6.0) or (n.box.y >= v.box.y + v.box.h and n.box.y <= v.box.y + v.box.h + 6.0)))
		}
		List.count_if(ks, |k| k == "the holds-fitness line") == 1
			and List.all(Ramp.drawn_bars(e.model), |b| !(Labels.intersects(Ramp.chip_box(b), line)))
			and named(Gate.measure)
			and named(Gate.builtin_measure)
	},
)

# wherever the load chart draws, the card's change and the newest week's
# chip read one number, in one color
expect List.all(
	List.keep_if(Gate.weeks_models(7), |e| !(List.is_empty(e.model.ramp_weeks)) and Ramp.charted(e.model)),
	|e| {
		placed = Ramp.scene(e.model, Gate.measure)
		last = Ramp.newest(e.model)
		card = List.keep_if(placed, |p| p.item.size == 28.0 and p.box.x > (Weeks.card_box(e.model.win.w)).x + 100.0)
		chips = List.keep_if(placed, |p| p.item.size == 11.0 and List.any(List.take_last(Ramp.drawn_bars(e.model), 1), |b| b.w.wk == last.wk and (p.box.x + p.box.w / 2.0 - b.cx).abs() < 0.5))
		List.len(card) == 1 and List.all(card, |c| List.all(chips, |k| k.item.text == c.item.text and k.item.color == c.item.color) and c.item.text == Ramp.change_text(last))
	},
)

# at the edges the weeks before history draw no bar and no chip, the first
# week of history stands as its whole CTL, and the running week, down so
# far, is an outline under the line; with gains alone the line sits at the
# plot's foot and with losses alone at its head, the scale's far end
# labelled in the gutter and its near end not
expect {
	pick = |tag| List.keep_if(Gate.weeks_models(7), |e| Str.contains(e.name, tag))
	# the plot's gutter reads the line's name, its 0 and the scale's far end alone
	ends_read = |e, far| {
		texts = List.map(List.keep_if(Ramp.scene(e.model, Gate.measure), |p| p.box.x + p.box.w <= Weeks.plot_left and p.box.y >= Ramp.plot_top - 12.0), |p| p.item.text)
		List.len(texts) == 3 and List.contains(texts, far(Ramp.scale_of(e.model.ramp_weeks)))
	}
	List.len(pick("at its edges")) > 0
		and List.all(
			pick("at its edges"),
			|e| {
				ks = List.map(Ramp.marks(e.model, Gate.measure), |m| m.key)
				placed = Ramp.scene(e.model, Gate.measure)
				bs = Ramp.bars(e.model)
				ly = Ramp.line_y(e.model.win.h, Ramp.scale_of(e.model.ramp_weeks))
				pre = List.take_first(bs, 2)
				List.all(pre, |b| !(b.drawn) and !(List.contains(ks, "the ${b.w.wk} bar")) and !(List.contains(ks, "the ${b.w.wk} chip")))
					and List.all(pre, |b| List.count_if(placed, |p| (p.box.x + p.box.w / 2.0 - b.cx).abs() < 0.5) == 2)
					and List.any(bs, |b| b.w.wk == "2026-09-07" and b.drawn and (ly - b.box.y - Ramp.unit(e.model.win.h, Ramp.scale_of(e.model.ramp_weeks)) * 11.3).abs() < 0.01)
					and List.all(List.take_last(bs, 1), |b| b.drawn and b.outlined and Ramp.down(b) and ((b.box.y - ly).abs() < 0.01 or (b.box.y + 1.5 - ly).abs() < 0.01))
			},
		)
		and List.len(pick("gains alone")) > 0
		and List.all(pick("gains alone"), |e| (Ramp.line_y(e.model.win.h, Ramp.scale_of(e.model.ramp_weeks)) - (Weeks.bars_bot(e.model.win.h) - Ramp.chip_room)).abs() < 0.01 and ends_read(e, |s| "+${I64.to_str(s.hi)}"))
		and List.len(pick("losses alone")) > 0
		and List.all(pick("losses alone"), |e| (Ramp.line_y(e.model.win.h, Ramp.scale_of(e.model.ramp_weeks)) - (Ramp.plot_top + Ramp.chip_room)).abs() < 0.01 and ends_read(e, |s| I64.to_str(s.lo)))
}

# the lifts tab's gate: every athlete who lifts, in kilograms, and in pounds
# with the lifts list and the session card both asked to scroll, each
# clamped to what its size lets it scroll; and every athlete who does not;
# all at every size
expect Gate.failures(|m| Gate.judge(Strength.owned(m, Gate.measure), Strength.marks(m)), Gate.lifts_models) == []

# the default window at the default scale lays out at the minimum size,
# and its session card shows every exercise of an eight- or eleven-exercise
# session unscrolled; twelve scroll there, the hint under them counting
# the rest, and a full-scale window shows all twelve
expect {
	full = { w: I32.to_f32(Theme.win_w), h: I32.to_f32(Theme.win_h) }
	eight = Strength.shown_last(Gate.session_model(8, Gate.default_size))
	eleven = Strength.shown_last(Gate.session_model(11, Gate.default_size))
	twelve = Strength.shown_last(Gate.session_model(12, Gate.default_size))
	roomy = Strength.shown_last(Gate.session_model(12, full))
	List.len(eight.rows) == 8
		and List.len(eleven.rows) == 11
		and List.len(twelve.rows) < 12
		and twelve.hint == "${U64.to_str(12 - List.len(twelve.rows))} more below"
		and List.len(roomy.rows) == 12
}

# at the default window a scrolled session card starts at its offset, at
# the card's top, and its hint counts what it cut on both sides; the rows
# it shows and the hint line under them stay card_gap above the weeks
# heading
expect {
	long = Gate.session_model(20, Gate.default_size)
	lines = Strength.last_lines(long)
	at4 = Strength.shown_last({ ..long, last_off: 4 })
	card = Strength.last_card(long.win.h, at4.total, Bool.False)
	first = (List.first(at4.rows)).ok_or({ s: "", y: 0.0 })
	at4.off == 4
		and first.s == (List.get(lines, 4)).ok_or("absent")
		and first.y == at4.at.top
		and at4.n_shown + 4 < at4.total
		and at4.hint == "4 more above, ${U64.to_str(at4.total - 4 - at4.n_shown)} more below"
		and card.top + U64.to_f32(at4.n_shown) * card.pitch + Strength.hint_h + Strength.card_gap <= at4.weeks_top
}

# an offset past the card's end clamps to its last offset, which cuts
# nothing below
expect {
	long = Gate.session_model(20, Gate.default_size)
	last = Strength.last_last(long)
	at99 = Strength.shown_last({ ..long, last_off: 99 })
	last > 0
		and at99.off == last
		and at99.hint == "${U64.to_str(last)} more above"
}

# a wheel over a session card that scrolls moves the card; over a card
# with nothing to scroll, over the weeks and tonnage charts below the card,
# and over the lifts list it moves the lifts list
expect {
	long = Gate.session_model(20, Gate.default_size)
	short = Gate.session_model(8, Gate.default_size)
	sl = Strength.shown_last(long)
	rx = Strength.right_x(long.win.w)
	ton = Strength.ton_span(long.win.h, sl.weeks_top)
	card_y = sl.at.top + 5.0
	Strength.wheels_card(long, rx + 10.0, card_y)
		and !(Strength.wheels_card(short, rx + 10.0, card_y))
		and !(Strength.wheels_card(long, rx + 10.0, Strength.bars_top(sl.weeks_top) + 10.0))
		and !(Strength.wheels_card(long, rx + 10.0, ton.top + 5.0))
		and !(Strength.wheels_card(long, 50.0, card_y))
}

# the boot splash's gate: its words at every size and dot count, slow or not
expect List.join(List.map(Gate.splash_models, |f| List.map(Labels.check(Scene.owned(Chrome.splash(f.model, Gate.measure, f.slow))), |e| "${f.name}: ${e}"))) == []

# the XP rail's sheet holds its lines inside its card for every athlete at
# every size
expect List.join(List.map(Gate.board_models, |f| List.map(Labels.check(Scene.owned(Labels.place((Hud.sheet(f.model, Gate.measure)).lines, { boxes: [], segs: [] }))), |e| "${f.name}: ${e}"))) == []

# a route an ocean from the rest leaves the map opening on the rest: every
# point of the home route lies inside the map at every size
expect List.all(
	Gate.sizes,
	|sz| {
		m = { ..Gate.empty_model(sz), view: 10, map: Gate.madrid_fixture }
		r = Map.rect(m.win)
		c = Map.cam(m)
		List.all(
			[{ x: 0.0, y: 0.0 }, { x: 1200.0, y: 400.0 }, { x: 2600.0, y: -300.0 }],
			|p| {
				s = Geo.to_screen(c, r, p)
				s.x >= r.x and s.x <= r.x + r.w and s.y >= r.y and s.y <= r.y + r.h
			},
		)
	},
)

# the street map's note: on its way while the view's tiles are fetched, gone
# once they draw, there-is-none once they failed with the source
# unreachable, and gone in playback
expect List.all(
	Gate.sizes,
	|sz| {
		base = { ..Gate.empty_model(sz), view: 10, map: Gate.map_fixture }
		Map.base_note(base) == Map.fetching_text
			and Map.base_note(Gate.with_tiles(base, Fetching, Known("t"))) == Map.fetching_text
			and Map.base_note(Gate.with_tiles(base, Waiting, Asking)) == Map.fetching_text
			and Map.base_note(Gate.with_tiles(base, Drawn(Mvt.empty), Known("t"))) == ""
			and Map.base_note(Gate.with_tiles(base, Failed(0), Unreachable(0))) == Map.no_base_text
			and Map.base_note(Gate.with_tiles(base, Waiting, Unreachable(0))) == Map.no_base_text
			and Map.base_note({ ..base, view: 12 }) == ""
	},
)

# a view's capture waits for its tiles: not while one is fetched, and once
# each is drawn or nothing more is coming
expect List.all(
	Gate.sizes,
	|sz| {
		base = { ..Gate.empty_model(sz), view: 10, map: Gate.map_fixture }
		!(Map.tiles_settled(base)) and !(Map.tiles_settled(Gate.with_tiles(base, Fetching, Known("t"))))
			and Map.tiles_settled(Gate.with_tiles(base, Drawn(Mvt.empty), Known("t"))) and Map.tiles_settled(Gate.with_tiles(base, Failed(0), Unreachable(0)))
			and Map.tiles_settled({ ..base, map: Db.no_map })
	},
)

# the built-in face measures as Draw.default_font does: the play title at
# 15 px is 412.5 px wide in both
expect (Gate.builtin_measure("playback - every session at once, an hour in 30 seconds", 15.0, Prose) - 412.5).abs() < 0.01 and Gate.size_name(Gate.default_size) == "980x600"

# every map mode at the size the window opens, judged in the built-in face
# the window falls back to without its brand fonts, which runs wider: the
# title and every note still keep apart
expect Gate.failures(|m| Gate.judge(Map.owned(m, Gate.builtin_measure), Map.marks(m, Gate.builtin_measure)), List.keep_if(Gate.map_models, |e| Str.ends_with(e.name, " at ${Gate.size_name(Gate.default_size)}"))) == []

# the map's card holds its lines inside it and apart, and stays inside the
# map, at the default window in the brand faces and in the built-in face
# the window falls back to without them
expect Gate.failures(|m| Gate.card_judge(m, Gate.measure), Gate.card_models) == []
expect Gate.failures(|m| Gate.card_judge(m, Gate.builtin_measure), Gate.card_models) == []

# the name models hold names in both faces, and the gate above judges them,
# each placed name being among the boxes the view owns: the opening and
# playback name places and streets, a street turned among them; the wide
# view names its cities and towns alone; street level names streets, turned
# ones among them, and no city; and the bent road is named nowhere. The
# models with a card up, which takes room from the names, are judged by the
# check below.
expect List.all(
	[Gate.measure, Gate.builtin_measure],
	|measure| List.all(
		List.keep_if(Gate.map_models, |e| Str.contains(e.name, "with its names") and !(Str.contains(e.name, "and a card")) and Str.ends_with(e.name, " at ${Gate.size_name(Gate.default_size)}")),
		|e| {
			ns = List.map(Map.names(e.model, Map.cam(e.model), measure), |p| { text: p.item.item.text, turned: p.item.angle != 0.0 })
			keys = List.map(Map.owned(e.model, measure), |o| o.key)
			named = |t| List.any(ns, |n| n.text == t)
			turned = List.any(ns, |n| n.turned)
			shape =
				if Str.contains(e.name, "wide") {
					!(List.is_empty(ns)) and List.all(ns, |n| n.text == "Chicago" or n.text == "Oak Park")
				} else if Str.contains(e.name, "street level") {
					turned and !(named("Chicago")) and List.any(ns, |n| Str.ends_with(n.text, "Street") or Str.ends_with(n.text, "Road") or Str.ends_with(n.text, "Avenue"))
				} else {
					turned and (named("Chicago") or named("Pilsen") or named("Ukrainian Village")) and List.any(ns, |n| Str.ends_with(n.text, "Road") or Str.ends_with(n.text, "Avenue") or Str.ends_with(n.text, "Street"))
				}
			shape and !(named("Lake Shore Drive")) and List.all(ns, |n| List.contains(keys, "'${n.text}'"))
		},
	),
)

# the room a card takes from the names, which repaints the picture when it
# changes: none with no card, the same for a card whose name is its widest
# line from opening to ready, and another for a card that grows when its
# last line outgrows the name, or that opens somewhere else
expect {
	base = { ..Gate.empty_model(Gate.default_size), view: 10, map: Gate.map_fixture }
	r = Map.rect(base.win)
	mid = { x: r.x + r.w / 2.0, y: r.y + r.h / 2.0 }
	up = |st, x| { ..Gate.with_card(base, x, mid.y), map_card: Map.with_state((Gate.with_card(base, x, mid.y)).map_card, st) }
	short = |m| { ..m, map: { ..m.map, routes: List.map(m.map.routes, |l| { ..l, session: { ..l.session, name: "Loop" } }) } }
	key = |m| Map.card_key(m, Gate.measure)
	key(base) == ""
		and key(up(Opening, mid.x)) == key(up(Ready, mid.x)) and key(up(Ready, mid.x)) != ""
		and key(short(up(Opening, mid.x))) != key(short(up(Ready, mid.x)))
		and key(Gate.with_card(base, mid.x, mid.y - 60.0)) != key(up(Ready, mid.x))
}

# the highlighted route, drawn straight to the screen, is cut to the map:
# close in, where the route runs far past the map's edges, every point it
# draws lies inside the map, and some of the route was cut away
expect {
	base = { ..Gate.empty_model(Gate.default_size), view: 10, map: Gate.map_fixture, map_moved: Bool.True, map_cam: { cx: 0.0, cy: 0.0, mpp: 1.0 } }
	r = Map.rect(base.win)
	m = Gate.with_card(base, r.x + r.w / 2.0, r.y + r.h / 2.0)
	c = Map.cam(m)
	match List.first(Gate.map_fixture.routes) {
		Ok(l) => {
			parts = Map.picked_parts(m, c, l)
			whole = Geo.strip(c, r, l.pts, 1.0)
			inside = |p| p.x >= r.x - 0.01 and p.x <= r.x + r.w + 0.01 and p.y >= r.y - 0.01 and p.y <= r.y + r.h + 0.01
			!(List.is_empty(parts)) and List.all(List.join(parts), inside) and List.any(whole, |p| !(inside(p)))
		}
		Err(_) => Bool.False
	}
}

# a card up over a map of names, at the middle and held inside the map at
# its edges, is judged with them, in both faces at every size: the view's
# text, the names and the card's lines hold no two boxes overlapping and
# none outside its region, and no name covers the card
expect List.all(
	[Gate.measure, Gate.builtin_measure],
	|measure| List.all(
		List.keep_if(Gate.map_models, |e| Str.contains(e.name, "with its names and a card")),
		|e| {
			ns = Map.names(e.model, Map.cam(e.model), measure)
			match Map.card(e.model, measure) {
				Ok(cd) => {
					lines = Scene.owned(Labels.place(cd.lines, { boxes: [], segs: [] }))
					!(List.is_empty(ns)) and Labels.check(List.concat(Map.owned(e.model, measure), lines)) == [] and Labels.covers(MapNames.owned(ns), [{ key: "the card", box: cd.box }]) == []
				}
				Err(_) => Bool.False
			}
		},
	),
)

# no name of a name model is drawn over its route: the fixture's route on
# screen, taken from the fixture itself, meets no placed name's turned box
expect List.all(
	List.keep_if(Gate.map_models, |e| Str.contains(e.name, "with its names")),
	|e| {
		c = Map.cam(e.model)
		r = Map.rect(e.model.win)
		route = List.map(Gate.map_fixture.routes, |l| Geo.strip(c, r, l.pts, 1.0))
		g = MapNames.grid(r, route, |p| p)
		List.all(
			Map.names(e.model, c, Gate.measure),
			|p| !(MapNames.blocked(g, { x: p.box.x + p.box.w / 2.0, y: p.box.y + p.box.h / 2.0 }, p.item.w, p.item.item.size, p.item.angle)),
		)
	},
)

# a cache the window cannot write is named on the map in place of the
# playback clock, and a map whose cache works names nothing
expect List.all(
	Gate.sizes,
	|sz| {
		base = { ..Gate.empty_model(sz), view: 12, map: Gate.map_fixture }
		said = |m| List.map(Map.owned(m, Gate.measure), |o| o.key)
		failing = said({ ..base, map_cache_err: "could not keep a street-map tile: disk I/O error" })
		List.contains(failing, "'could not keep a street-map tile: disk I/O error'") and !(List.any(failing, |k| Str.contains(k, "into each session")))
			and !(List.any(said(base), |k| Str.contains(k, "could not")))
	},
)

# on the map a click on a route opens its card, a click on the card or
# Enter opens its session, Esc and a click that picks nothing close it, a
# card waiting on its session or with no trace opens nothing, and a card
# whose route is no longer loaded closes and opens nothing; off the map
# the card is left as it is, neither up nor named in the focus row
expect {
	base = { ..Gate.empty_model(Gate.default_size), view: 10, map: Gate.map_fixture }
	r = Map.rect(base.win)
	c = Map.cam(base)
	on = Geo.to_screen(c, r, { x: 1200.0, y: 400.0 })
	off = { x: r.x + 5.0, y: r.y + r.h - 5.0 }
	keys = { enter: Bool.False, esc: Bool.False }
	id_of = |cd|
		match cd {
			Open(o) => o.id
			Closed => -1
		}
	opened = Map.act(base, Ok(on), keys, Gate.measure)
	up = { ..base, map_card: opened.card }
	inside = match Map.card(up, Gate.measure) {
		Ok(cd) => { x: cd.box.x + cd.box.w / 2.0, y: cd.box.y + cd.box.h / 2.0 }
		Err(_) => off
	}
	held = |st| { ..up, map_card: Map.with_state(up.map_card, st) }
	gone = { ..up, map_card: Open({ id: 99, at: { x: 0.0, y: 0.0 }, state: Ready }) }
	id_of(opened.card) == 1 and opened.open == -1
		and (Map.act(up, Ok(inside), keys, Gate.measure)).open == 1
		and (Map.act(up, Err(NoClick), { ..keys, enter: Bool.True }, Gate.measure)).open == 1
		and id_of((Map.act(up, Err(NoClick), { ..keys, esc: Bool.True }, Gate.measure)).card) == -1
		and id_of((Map.act(up, Ok(off), keys, Gate.measure)).card) == -1
		and (Map.act(held(Opening), Err(NoClick), { ..keys, enter: Bool.True }, Gate.measure)).open == -1
		and (Map.act(held(NoTrace), Ok(inside), keys, Gate.measure)).open == -1
		and (Map.act(gone, Err(NoClick), { ..keys, enter: Bool.True }, Gate.measure)).open == -1 and id_of((Map.act(gone, Err(NoClick), keys, Gate.measure)).card) == -1
		and id_of((Map.act({ ..up, view: 2 }, Ok(on), keys, Gate.measure)).card) == 1
		and Map.card_up(up) and Map.card_up({ ..up, view: 12 }) and !(Map.card_up({ ..up, view: 2 })) and !(Map.card_up(base))
		and Map.map_focus(up) == 1 and Map.map_focus({ ..up, view: 2 }) == -1 and Map.map_focus(base) == -1
		and Map.waiting_on(held(Opening).map_card) == 1 and Map.waiting_on(up.map_card) == -1
}

# the long-named sports are in the career gate at every size: stand-up
# paddling as a power trend, the other three as pages without one
expect {
	long = List.keep_if(Gate.career_models, |e| Str.starts_with(e.name, Gate.long_names.name))
	cur = |e| Career.spine_at(e.model.career_spines, e.model.spine_idx)
	List.len(List.keep_if(long, |e| (cur(e)).kind == Career.no_trend)) == 3 * List.len(Gate.sizes)
		and List.len(List.keep_if(long, |e| (cur(e)).fam == "StandUpPaddling" and (cur(e)).kind == "power")) == List.len(Gate.sizes)
}

# a trend page of a sport outside every family names it in plain words in
# its heading, and no text on any of the athlete's pages, in either face,
# carries a raw Strava spelling
expect {
	long = List.keep_if(Gate.career_models, |e| Str.starts_with(e.name, Gate.long_names.name))
	sup = List.keep_if(long, |e| (Career.spine_at(e.model.career_spines, e.model.spine_idx)).fam == "StandUpPaddling")
	raw = ["standuppaddling", "StandUpPaddling", "highintensityintervaltraining", "HighIntensityIntervalTraining", "backcountryski", "BackcountrySki", "ebikeride", "EBikeRide"]
	!(List.is_empty(sup))
		and List.all(sup, |e| Career.subtitle(e.model) == "career - stand up paddling threshold watts   F  next sport")
		and List.all(
			[Gate.measure, Gate.builtin_measure],
			|measure| List.all(long, |e| List.all(Career.owned(e.model, measure), |o| !(List.any(raw, |r| Str.contains(o.key, r))))),
		)
}
