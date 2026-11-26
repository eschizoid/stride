import rr.Color
import rr.Draw
import rr.Text
import core.Bus
import core.Fmt
import core.Sports
import core.Units
import Career
import Chrome
import Db
import Labels
import Scene
import Theme
import Ui

Curve :: [].{
	# ── the power view (TAB) ────────────────────────────────────────────────
	# One question at a glance: the athlete's best power at 5, 10, 20 and 60
	# minutes (5, 10 and 20 on a pace curve), this window against the
	# same-length window before it, and whether a test is due. A card under
	# the chips carries the threshold and the test line; under it a legend,
	# then one row per duration the curve has, each with the window before
	# as a grey dot and this window as a blue one on one shared scale, each
	# dot's value printed beside it, the gap between them coloured by the
	# change, and the change printed after the pair. The shapes and the
	# strings come from one layout (story), so the drawing, the label placer
	# and the gate read the same positions.
	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		measure = Scene.measure_of(model)
		List.for_each!(range_chips(model), |c| chip!(frame, model, c.box, c.on, Theme.ctl_c))
		List.for_each!(curve_chip_boxes(model), |c| chip!(frame, model, c.box, c.on, Theme.tsb_c))
		if has_records(model) {
			s = story(model, measure)
			g = s.g
			frame.rounded_rectangle!({ x: s.card.x, y: s.card.y, width: s.card.w, height: s.card.h, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
			frame.rectangle!({ x: s.card.x, y: s.card.y + 6.0, width: 4.0, height: s.card.h - 12.0, style: Draw.filled(if (s.note.due) Theme.gold_c else Theme.ink_faint) })
			List.for_each!(
				grid_vals(model.curve_family, model.units, g.lo, g.hi),
				|v| {
					x = c_xf(g, v)
					List.for_each!(
						rule_pieces(g.top - 30.0, c_bot(g) + 30.0, List.keep_if(empty_boxes(model, g, measure), |b| x >= b.x0 and x <= b.x1)),
						|seg| frame.line!({ start: { x, y: seg.a }, end: { x, y: seg.b }, stroke: Draw.stroke(Color.with_alpha(Theme.ink_faint, 30), 1) }),
					)
				},
			)
			List.for_each!(
				s.pairs,
				|p| {
					y = c_y(g, p.i)
					if p.now > 0 and p.prev > 0 {
						frame.line!({ start: { x: c_x(g, p.prev), y }, end: { x: c_x(g, p.now), y }, stroke: Draw.stroke(Color.with_alpha(change_col(model.curve_family, model.units, p.now, p.prev), 140), 4) })
					}
					List.for_each!(row_dots(g, p), |d| frame.circle!({ center: { x: d.x, y: d.y }, radius: d.r, style: Draw.filled(if (d.now) Theme.ctl_c else Theme.ink_muted) }))
				},
			)
			List.for_each!(
				s.legend,
				|e| if (e.dot) (frame.circle!({ center: { x: e.x + 8.0, y: s.legend_y + 9.0 }, radius: legend_r(e.now), style: Draw.filled(if (e.now) Theme.ctl_c else Theme.ink_muted) })) else {},
			)
		}
		Scene.draw!(frame, model, scene(model, measure))
		Ok({})
	}

	chip! : Draw.Frame, Ui.Model, Labels.Rect, Bool, Color.Rgba => {}
	chip! = |frame, model, b, on, lit| {
		hov = model.mouse_x >= b.x and model.mouse_x <= b.x + b.w and model.mouse_y >= b.y and model.mouse_y <= b.y + b.h
		style = if (on) (Draw.filled(Color.with_alpha(lit, 60))) else if (hov) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
		frame.rounded_rectangle!({ x: b.x, y: b.y, width: b.w, height: b.h, radius: 6.0, segments: 6, style })
	}

	# ── the rows: one per duration the curve has ─────────────────────────────
	# the durations the tab tells its story at, of those the curve's ladder
	# carries: the pace ladder stops at 20 minutes
	story_secs : List(I64)
	story_secs = [300, 600, 1200, 3600]

	# a row: its duration, this window's and the window before's best at it
	# (0 for none), whether the record book holds any best at it, and its
	# place top to bottom
	Pair : { secs : I64, now : I64, prev : I64, ever : Bool, i : U64 }

	pairs_of : List(Db.PrRung), List(Db.CurvePt), List(Db.CurvePt) -> List(Pair)
	pairs_of = |prs, now, prev| List.map_with_index(List.keep_if(story_secs, |s| List.any(prs, |pr| pr.secs == s)), |s, i| { secs: s, now: window_w(now, s), prev: window_w(prev, s), ever: List.any(prs, |pr| pr.secs == s and pr.w > 0), i })

	pairs : Ui.Model -> List(Pair)
	pairs = |model| pairs_of(model.prs, model.curve, model.curve_prev)

	rung_name : Pair -> Str
	rung_name = |p| "${I64.to_str(p.secs // 60)} min"

	# the window's best at one duration, in whole units; 0 when it has none
	window_w : List(Db.CurvePt), I64 -> I64
	window_w = |pts, secs|
		match List.find_first(pts, |c| c.dur_s == secs) {
			Ok(c) => F32.round_to_i64_try(c.watts) ?? 0
			Err(_) => 0
		}

	# the shared scale: from xl to xr across the rows, lo to hi in the
	# curve's own units; the rows from top, pitch apart
	CGeom : { xl : F32, xr : F32, top : F32, pitch : F32, rows : U64, lo : F32, hi : F32 }

	c_geom : List(Pair), F32, F32, F32 -> CGeom
	c_geom = |ps, win_w, top, bot| {
		span = value_span(List.join(List.map(ps, |p| [p.now, p.prev])))
		n = List.len(ps)
		{ xl: rows_left, xr: win_w - 190.0, top, pitch: if (n <= 1) 0.0 else (bot - top) / U64.to_f32(n - 1), rows: n, lo: span.lo, hi: span.hi }
	}

	# where the scale starts, right of the duration names
	rows_left : F32
	rows_left = 170.0

	c_xf : CGeom, F32 -> F32
	c_xf = |g, v| g.xl + (v - g.lo) / (g.hi - g.lo) * (g.xr - g.xl)

	c_x : CGeom, I64 -> F32
	c_x = |g, v| c_xf(g, I64.to_f32(v))

	c_y : CGeom, U64 -> F32
	c_y = |g, i| g.top + g.pitch * U64.to_f32(i)

	c_bot : CGeom -> F32
	c_bot = |g| g.top + g.pitch * U64.to_f32(if (g.rows == 0) 0 else g.rows - 1)

	# The value scale around the printed values: their spread's 15% plus 2%
	# of the highest beyond each end, so every dot sits inside the scale with
	# room for its value beside it; a single value is centred.
	value_span : List(I64) -> { lo : F32, hi : F32 }
	value_span = |vals| {
		vs = List.map(List.keep_if(vals, |v| v > 0), I64.to_f32)
		top = List.fold(vs, 1.0, F32.max)
		low = List.fold(vs, top, F32.min)
		pad = (top - low) * 0.15 + top * 0.02
		{ lo: low - pad, hi: top + pad }
	}

	# a row's dots as drawn: the window before's grey and this window's
	# blue, each at its own value on the shared scale; none for an absent best
	Dot : { x : F32, y : F32, r : F32, now : Bool }

	row_dots : CGeom, Pair -> List(Dot)
	row_dots = |g, p| {
		y = c_y(g, p.i)
		List.concat(
			if (p.prev > 0) [{ x: c_x(g, p.prev), y, r: prev_r, now: Bool.False }] else [],
			if (p.now > 0) [{ x: c_x(g, p.now), y, r: now_r, now: Bool.True }] else [],
		)
	}

	prev_r : F32
	prev_r = 6.5

	now_r : F32
	now_r = 8.5

	legend_r : Bool -> F32
	legend_r = |now| if (now) 7.0 else 5.5

	# ── what each row prints ────────────────────────────────────────────────
	# a value as it prints: watts, or the pace in the sport's own unit
	v_text : Str, [Metric, Imperial], I64 -> Str
	v_text = |curve, units, v|
		match Bus.curve_key(curve) {
			Power(_) => Db.num_unit(v, "W")
			Pace(sp) => {
				u = pace_unit_for(units, sp)
				"${Fmt.mmss(pace_secs(v, u.m))}${u.label}"
			}
		}

	# two bests read as level: within a watt on a power curve, the same
	# printed pace on a pace curve
	is_level : Str, [Metric, Imperial], I64, I64 -> Bool
	is_level = |curve, units, now, prev|
		if (is_pace(curve)) (pace_delta(curve, units, now, prev) == "")
		else now - prev <= 1 and prev - now <= 1

	# the change from the window before: signed watts or seconds of pace,
	# "level", or "" when either window has no best at that duration
	change_text : Str, [Metric, Imperial], I64, I64 -> Str
	change_text = |curve, units, now, prev|
		if (now <= 0 or prev <= 0) ""
		else if (is_level(curve, units, now, prev)) "level"
		else if (is_pace(curve)) pace_delta(curve, units, now, prev)
		else if (now > prev) "+${I64.to_str(now - prev)} W"
		else "-${I64.to_str(prev - now)} W"

	# green for a gain, red for a drop, grey for level
	change_col : Str, [Metric, Imperial], I64, I64 -> Color.Rgba
	change_col = |curve, units, now, prev| if (is_level(curve, units, now, prev)) Theme.ink_faint else if (now > prev) Theme.tsb_c else Theme.alarm_c

	# the change in pace in seconds per unit, negative when the window got
	# faster; "" when the printed paces match
	pace_delta : Str, [Metric, Imperial], I64, I64 -> Str
	pace_delta = |curve, units, now, prev|
		match Bus.curve_key(curve) {
			Power(_) => ""
			Pace(sp) => {
				m = (pace_unit_for(units, sp)).m
				d = pace_secs(now, m) - pace_secs(prev, m)
				if (d > 0) "+${I64.to_str(d)}s" else if (d < 0) "-${I64.to_str(-d)}s" else ""
			}
		}

	# What a row with no best in either window says. With a best on record
	# from before both windows, that it is older than both. With none ever,
	# what it lacked: a pace best rolls over moving seconds, walking counts
	# as moving and a pause of up to 30 seconds closes up, but a longer stop
	# ends the stretch, so a run with real stops holds no 10 or 20 minutes;
	# a power best needs that many recorded minutes in one session.
	empty_text : Str, I64, Pair -> Str
	empty_text = |curve, days, p| {
		mins = I64.to_str(p.secs // 60)
		if (p.ever) "none in the last ${I64.to_str(days * 2)} days"
		else if (is_pace(curve)) "no ${mins} minutes without stopping yet"
		else "no ${mins}-minute ${effort_noun(curve)} yet"
	}

	# a row with a best only in the window before
	gone_text : I64 -> Str
	gone_text = |days| "none in the last ${I64.to_str(days)} days"

	# a row with a best only in this window, while other rows have both
	new_text : Str
	new_text = "none before"

	empty_size : F32
	empty_size = 15.0

	# each empty row's sentence on its row, from the scale's left edge, so
	# the scale's rules can leave it clear
	EmptyBox : { x0 : F32, x1 : F32, y0 : F32, y1 : F32 }

	empty_boxes : Ui.Model, CGeom, Scene.Measure -> List(EmptyBox)
	empty_boxes = |model, g, measure|
		List.keep_oks(
			pairs(model),
			|p|
				if (p.now > 0 or p.prev > 0) Err(HasBest)
				else {
					y = c_y(g, p.i)
					Ok({ x0: g.xl - 8.0, x1: g.xl + measure(empty_text(model.curve_family, model.curve_days, p), empty_size, Prose) + 8.0, y0: y - 14.0, y1: y + 14.0 })
				},
		)

	# a vertical rule from top to bot as the pieces left between the boxes
	# it must not cross, the boxes taken top to bottom
	rule_pieces : F32, F32, List(EmptyBox) -> List({ a : F32, b : F32 })
	rule_pieces = |top, bot, boxes| {
		end = List.fold(boxes, { at: top, out: [] }, |acc, bx| { at: F32.max(acc.at, bx.y1), out: if (bx.y0 > acc.at) List.append(acc.out, { a: acc.at, b: bx.y0 }) else acc.out })
		if (bot > end.at) List.append(end.out, { a: end.at, b: bot }) else end.out
	}

	# ── the legend ──────────────────────────────────────────────────────────
	# The window before, then this window, left to right. A window before
	# with no best at any duration is said once here, with no dot, and its
	# rows draw only this window's dot.
	LegendItem : { now : Bool, dot : Bool, label : Str }

	legend_items : Str, I64, List(Pair) -> List(LegendItem)
	legend_items = |curve, days, ps|
		List.join([
			if (List.any(ps, |p| p.prev > 0)) [{ now: Bool.False, dot: Bool.True, label: prev_name(days) }] else [{ now: Bool.False, dot: Bool.False, label: "${prev_name(days)}: ${no_sessions(curve)}" }],
			if (List.any(ps, |p| p.now > 0)) [{ now: Bool.True, dot: Bool.True, label: now_name(days) }] else [],
		])

	now_name : I64 -> Str
	now_name = |days| "last ${I64.to_str(days)} days"

	prev_name : I64 -> Str
	prev_name = |days| "the ${I64.to_str(days)} days before"

	# what a window before with nothing in it lacked, named for the sport
	no_sessions : Str -> Str
	no_sessions = |curve| {
		v = effort_verb(curve)
		if (v == "ride") "no rides" else if (v == "row") "no rowing" else if (v == "run") "no runs" else if (v == "swim") "no swims" else "no sessions"
	}

	# one effort of the curve's sport as a noun: a ride, a row, a run, a
	# swim, or a session for a sport no family holds
	effort_noun : Str -> Str
	effort_noun = |curve| {
		v = effort_verb(curve)
		if (v == "go") "session" else v
	}

	# the verb for one effort of the curve's sport
	effort_verb : Str -> Str
	effort_verb = |curve| {
		fam = match Bus.curve_key(curve) {
			Power(f) => f
			Pace(sp) => Sports.canonical(sp)
		}
		if (fam == "Ride") "ride" else if (fam == "Rowing") "row" else if (fam == "Run" or fam == "Walk") "run" else if (fam == "Swim") "swim" else "go"
	}

	legend_size : F32
	legend_size = 14.0

	# each item's left edge from x0: a dotted item leaves its swatch's room
	# before its name
	legend_xs_of : List(LegendItem), Scene.Measure, F32 -> List({ now : Bool, dot : Bool, label : Str, x : F32 })
	legend_xs_of = |items, measure, x0| {
		ws = List.map(items, |it| (if (it.dot) legend_swatch_w else 0.0) + measure(it.label, legend_size, Prose))
		at = (List.fold(ws, { at: x0, xs: [] }, |acc, w| { at: acc.at + w + legend_gap, xs: List.append(acc.xs, acc.at) })).xs
		List.map2(items, at, |it, x| { now: it.now, dot: it.dot, label: it.label, x })
	}

	legend_swatch_w : F32
	legend_swatch_w = 22.0

	legend_gap : F32
	legend_gap = 28.0

	# ── the top line ────────────────────────────────────────────────────────
	# The threshold the engine scores the curve with and whether a test is
	# due, by the rule the tab has always used: a test is due when the
	# window's critical power (or speed) fit is not usable (fit_usable_for)
	# and no marked test is in force. The line names what made the fit
	# unusable: fewer than two of the window's 5, 10 and 20-minute bests to
	# fit, or bests that do not fall on one curve or leave too little or too
	# much in reserve, which is what bests from steady rather than flat-out
	# efforts give. An answer from the engine that is missing, or lacks the
	# threshold or the fit, is said as such and claims nothing else. A test
	# stays in force for the engine's 90 days and stands in for the fit; a
	# curve the engine answered with no threshold says how to get one: two
	# 20-minute bests within 60 days set the derived one, and on foot a
	# marked 5 km time trial sets it too.
	TestNote : { text : Str, due : Bool }

	top_line : Str, [Metric, Imperial], I64, Db.CurveInfo, List(I64) -> TestNote
	top_line = |curve, units, days, info, bests| {
		pace = is_pace(curve)
		verb = effort_verb(curve)
		thr_name = if (pace) "threshold pace" else "FTP"
		thr_v = F32.round_to_i64_try(if (pace) (info.thr * 1000.0) else info.thr) ?? 0
		shown = v_text(curve, units, thr_v)
		due = !(fit_usable_for(curve, info.fit)) and info.test.value <= 0.0
		if !(info.thr_known) or !(info.fit.ok) {
			{ text: "Your ${thr_name} could not be read from stride - press R to try again, or update stride", due: Bool.False }
		} else if thr_v <= 0 {
			test_way = if (pace and verb == "run") ", or run 5 km as fast as you can and mark it as a test" else " to set one"
			how_first = if (pace) "without stopping" else "hard"
			{ text: "No ${thr_name} yet - ${verb} 20 minutes ${how_first} twice within 60 days${test_way}", due: Bool.True }
		} else if due {
			why =
				if (info.fit.points < 2.0) "too few hard 5 to 20-minute efforts in the ${now_name(days)} to check your ${thr_name}"
				else "${bests_named(bests)} of the ${now_name(days)} ${if_one(bests, "was", "were")} not flat out"
			how = if (pace) "as hard as you can without stopping" else "as hard as you can"
			{ text: "Test due: ${why} - ${verb} 20 minutes ${how} to update your ${thr_name} (now ${shown})", due: Bool.True }
		} else if info.from_test {
			{ text: "${thr_name} ${shown} - set by your test on ${short_day(info.test.date)}", due: Bool.False }
		} else if info.test.value > 0.0 {
			above = if (pace) "faster" else "higher"
			{ text: "${thr_name} ${shown} - from your best 20 minutes of the last 60 days, ${above} than your test on ${short_day(info.test.date)}", due: Bool.False }
		} else {
			{ text: "${thr_name} ${shown} - no test due", due: Bool.False }
		}
	}

	# one word for a single item, another for several
	if_one : List(a), Str, Str -> Str
	if_one = |xs, one, many| if (List.len(xs) == 1) one else many

	# the fit's bests named by their durations: "your 5, 10 and 20-minute
	# bests", "your 5 and 20-minute bests", "your 20-minute best"
	bests_named : List(I64) -> Str
	bests_named = |secs| {
		mins = List.map(secs, |s| I64.to_str(s // 60))
		n = List.len(mins)
		joined =
			if (n <= 1) Str.join_with(mins, "")
			else "${Str.join_with(List.take_first(mins, n - 1), ", ")} and ${(List.last(mins)) ?? ""}"
		if (n == 1) "your ${joined}-minute best" else "your ${joined}-minute bests"
	}

	# the window's bests the fit reads: this window's 5, 10 and 20-minute
	# bests that exist
	fit_bests : List(Pair) -> List(I64)
	fit_bests = |ps| List.map(List.keep_if(ps, |p| p.now > 0 and p.secs >= 300 and p.secs <= 1200), |p| p.secs)

	# "2026-08-16" -> "08-16"
	short_day : Str -> Str
	short_day = |day| Str.from_utf8_lossy(List.drop_first(Str.to_utf8(day), 5))

	note_size : F32
	note_size = 16.0

	note_pitch : F32
	note_pitch = 22.0

	# the note's words in lines no wider than w, greedily, so a long note
	# wraps inside the card at a narrow window
	wrap : Scene.Measure, Str, F32 -> List(Str)
	wrap = |measure, text, w| {
		fits = |s| measure(s, note_size, Prose) <= w
		out = List.fold(
			Str.split_on(text, " "),
			{ lines: [], cur: "" },
			|acc, word|
				if (acc.cur == "") { lines: acc.lines, cur: word }
				else if (fits("${acc.cur} ${word}")) { lines: acc.lines, cur: "${acc.cur} ${word}" }
				else { lines: List.append(acc.lines, acc.cur), cur: word },
		)
		if (out.cur == "") out.lines else List.append(out.lines, out.cur)
	}

	# ── the layout the drawing, the scene and the gate share ───────────────
	# the card from card_top, sized to the note's lines; the legend under
	# it; the rows from rows_gap under the legend down to rows_floor above
	# the window's bottom
	Story : { note : TestNote, lines : List(Str), card : Labels.Rect, legend_y : F32, legend : List({ now : Bool, dot : Bool, label : Str, x : F32 }), pairs : List(Pair), g : CGeom }

	story : Ui.Model, Scene.Measure -> Story
	story = |model, measure| {
		note = top_line(model.curve_family, model.units, model.curve_days, model.curve_info, fit_bests(pairs(model)))
		card_w = model.win.w - 76.0
		lines = wrap(measure, note.text, card_w - 2.0 * card_inset)
		card_h = 16.0 + U64.to_f32(List.len(lines)) * note_pitch
		legend_y = card_top + card_h + 22.0
		ps = pairs(model)
		{
			note,
			lines,
			card: { x: 36.0, y: card_top, w: card_w, h: card_h },
			legend_y,
			legend: legend_xs_of(legend_items(model.curve_family, model.curve_days, ps), measure, 36.0),
			pairs: ps,
			g: c_geom(ps, model.win.w, legend_y + rows_gap, model.win.h - rows_floor),
		}
	}

	card_top : F32
	card_top = 96.0

	# the note's left and right margin inside the card, past the stripe
	card_inset : F32
	card_inset = 16.0

	rows_gap : F32
	rows_gap = 90.0

	rows_floor : F32
	rows_floor = 170.0

	# where the view's body starts, under the chips: the XP rail's hover
	# band on this view begins here
	plot_top : F32
	plot_top = card_top

	# the rows with values on record or in either window: every rung at
	# zero IS the no-records state, since the loader materializes every rung
	has_records : Ui.Model -> Bool
	has_records = |model| !(List.is_empty(model.prs)) and List.fold(model.prs, 0.I64, |a, pr| a + pr.w) != 0

	range_chips : Ui.Model -> List({ box : Labels.Rect, on : Bool, p : Text.Prepared, label : Str })
	range_chips = |model|
		List.map_with_index(
			model.subs,
			|s, i| {
				on = (U64.to_i64_try(s.r) ?? -1) == model.curve_days
				{ box: { x: model.win.w - 420.0 + U64.to_f32(i) * 54.0, y: chip_top, w: 46.0, h: chip_bottom - chip_top }, on, p: s.chip, label: "${U64.to_str(s.r)}d" }
			},
		)

	curve_chip_boxes : Ui.Model -> List({ box : Labels.Rect, on : Bool, label : Str })
	curve_chip_boxes = |model|
		List.map(chips_for(model.win.w, model.curve_keys, model.curve_family), |c| { box: { x: c.x, y: chip_top, w: c.w, h: chip_bottom - chip_top }, on: c.on, label: c.label })

	# ── every string the view writes, placed ───────────────────────────────
	# Fixed text only: every string keeps its one spot, which the layout
	# above keeps apart, and the gate proves it.
	scene : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	scene = |model, measure| Labels.place(texts(model, measure), { boxes: [], segs: [] })

	# the view's text and the chrome's, as the gate judges them
	owned : Ui.Model, Scene.Measure -> List(Labels.Owned)
	owned = |model, measure| List.concat(Scene.owned(Chrome.placed(model, measure)), Scene.owned(scene(model, measure)))

	texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	texts = |model, measure| {
		win_w = model.win.w
		panel = Labels.panel(model.win)
		fix = |it, x, y, align, region| Scene.fixed(measure, it, { x, y, align }, region)
		head = [
			fix(Scene.prepared(model.curve_title, title_text(model.curve_family), 15.0, Prose, Theme.ink_muted), 36.0, 70.0, Left, panel),
			fix(Scene.prepared(model.curve_hint, hint_text, 13.0, Prose, Theme.ink_faint), 36.0, model.win.h - 30.0, Left, panel),
		]
		chips = List.concat(
			List.map(range_chips(model), |c| fix(Scene.prepared(c.p, c.label, 12.0, Data, if (c.on) Color.white else Theme.ink_muted), c.box.x + c.box.w / 2.0, 68.0, Center, c.box)),
			List.map(curve_chip_boxes(model), |c| fix(Scene.data(c.label, 12.0, if (c.on) Color.white else Theme.ink_muted), c.box.x + c.box.w / 2.0, 68.0, Center, c.box)),
		)
		body = if (has_records(model)) story_texts(model, measure) else [fix(Scene.data(empty_note(model.curve_family, model.est_power), 14.0, Theme.ink_muted), 36.0, 110.0, Left, panel)]
		# a chip click re-fetches the curve in the background; while that is
		# in flight a note at the legend row's right says so, so a click that
		# takes a beat reads as working
		loading = if (model.reloading) [fix(Scene.data(loading_note, 11.0, Theme.ink_muted), win_w - 40.0, (story(model, measure)).legend_y, Right, panel)] else []
		List.join([head, chips, body, loading])
	}

	story_texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	story_texts = |model, measure| {
		s = story(model, measure)
		g = s.g
		curve = model.curve_family
		units = model.units
		panel = Labels.panel(model.win)
		fix = |it, x, y, align| Scene.fixed(measure, it, { x, y, align }, panel)
		note = List.map_with_index(s.lines, |l, k| Scene.fixed(measure, Scene.prose(l, note_size, if (s.note.due) Theme.gold_c else Theme.ink_muted), { x: s.card.x + card_inset, y: s.card.y + 9.0 + U64.to_f32(k) * note_pitch, align: Left }, s.card))
		legend = List.map(s.legend, |e| fix(Scene.prose(e.label, legend_size, Theme.ink_muted), if (e.dot) (e.x + legend_swatch_w) else e.x, s.legend_y, Left))
		grid = List.map(
			grid_vals(curve, units, g.lo, g.hi),
			|v| fix(Scene.data(axis_text(curve, units, F32.round_to_i64_try(v) ?? 0), 11.0, Theme.ink_faint), c_xf(g, v), c_bot(g) + 36.0, Center),
		)
		any_prev = List.any(s.pairs, |p| p.prev > 0)
		rows = List.join(
			List.map(
				s.pairs,
				|p| {
					y = c_y(g, p.i)
					name = [fix(Scene.prose(rung_name(p), 18.0, Theme.ink_muted), 60.0, y - 10.0, Left)]
					now_right = p.now >= p.prev
					now_txt = v_text(curve, units, p.now)
					prev_txt = v_text(curve, units, p.prev)
					now_lbl = if (p.now > 0) [fix(Scene.data(now_txt, 16.0, Theme.ctl_c), if (now_right) (c_x(g, p.now) + 16.0) else c_x(g, p.now) - 16.0, y - 8.0, if (now_right) Left else Right)] else []
					prev_left = now_right and p.now > 0
					prev_lbl = if (p.prev > 0) [fix(Scene.data(prev_txt, 14.0, Theme.ink_muted), if (prev_left) (c_x(g, p.prev) - 14.0) else c_x(g, p.prev) + 14.0, y - 7.0, if (prev_left) Right else Left)] else []
					# the row's change sits just past its right-hand value
					right_end =
						if (p.now > 0 and now_right) (c_x(g, p.now) + 16.0 + measure(now_txt, 16.0, Data))
						else c_x(g, p.prev) + 14.0 + measure(prev_txt, 14.0, Data)
					end_x = right_end + 28.0
					tail =
						if (p.now <= 0 and p.prev <= 0) [fix(Scene.prose(empty_text(curve, model.curve_days, p), empty_size, Theme.ink_faint), g.xl, y - 8.0, Left)]
						else if (p.now <= 0) [fix(Scene.prose(gone_text(model.curve_days), 15.0, Theme.ink_faint), end_x, y - 8.0, Left)]
						else if (p.prev <= 0 and any_prev) [fix(Scene.prose(new_text, 15.0, Theme.ink_faint), end_x, y - 8.0, Left)]
						else if (p.prev <= 0) []
						else [fix(Scene.data(change_text(curve, units, p.now, p.prev), 17.0, change_col(curve, units, p.now, p.prev)), end_x, y - 9.0, Left)]
					List.join([name, now_lbl, prev_lbl, tail])
				},
			),
		)
		List.join([note, legend, grid, rows])
	}

	# the shapes no text may cover but its own: the pills and the XP rail,
	# the range and curve chips, and with records on file the card, every
	# dot and the legend's dots
	marks : Ui.Model, Scene.Measure -> List(Labels.Mark)
	marks = |model, measure| {
		chips = List.concat(
			List.map(range_chips(model), |c| { key: "the ${c.label} chip", box: c.box }),
			List.map(curve_chip_boxes(model), |c| { key: "the ${c.label} chip", box: c.box }),
		)
		shapes = List.concat(Chrome.marks(model), chips)
		if has_records(model) {
			s = story(model, measure)
			dot = |key, x, y, r| { key, box: { x: x - r, y: y - r, w: 2.0 * r, h: 2.0 * r } }
			dots = List.join(List.map(s.pairs, |p| List.map(row_dots(s.g, p), |d| dot("the ${rung_name(p)} ${if (d.now) "this-window" else "window-before"} dot", d.x, d.y, d.r))))
			swatches = List.keep_oks(s.legend, |e| if (e.dot) (Ok(dot("the ${e.label} swatch", e.x + 8.0, s.legend_y + 9.0, legend_r(e.now)))) else Err(NoDot))
			List.join([shapes, [{ key: "the test card", box: s.card }], dots, swatches])
		} else {
			shapes
		}
	}

	hint_text : Str
	hint_text = "1/2/3 or chips  window      R  reload      S  screenshot      V  record      ESC quit"

	loading_note : Str
	loading_note = "loading..."

	# ── the chip row ────────────────────────────────────────────────────────
	# The range chips fill the top right from chip_top to chip_bottom. Left of
	# them, right-aligned, sit the curves the athlete has on record in one
	# fixed order (chip_order), as many as fit beside the title, the one on
	# screen always among them. Power mode lists the power families, then
	# each pace sport whose family has no power curve; pace mode the
	# reverse. Right of the range chips, a power and a pace chip switch
	# between the two curves of the sport on screen, shown only when the
	# sport on screen has a curve of the other kind: a ride has no pace
	# curve, so a bike curve shows no pace chip. Click and hover tests in
	# main.roc test the same chip band.
	chip_top : F32
	chip_top = 64.0

	chip_bottom : F32
	chip_bottom = 86.0

	Chip : { key : Str, label : Str, x : F32, w : F32, on : Bool }

	# a chip's width: chip_w, or wide enough for a longer label at the chip
	# face's size (chip_char_w per character, generous against the 12 px
	# data face's advance), with room either side
	chip_w : F32
	chip_w = 52.0

	chip_char_w : F32
	chip_char_w = 7.5

	chip_w_for : Str -> F32
	chip_w_for = |label| F32.max(chip_w, U64.to_f32(Str.count_utf8_bytes(label)) * chip_char_w + 16.0)

	# the air between two sport chips
	chip_gap : F32
	chip_gap = 6.0

	# the title shares the chip row, so the chips start where its text ends:
	# its left inset, its width at the title's size (title_char_w per
	# character, generous against the size-15 prose face's average advance)
	# and a gap
	title_char_w : F32
	title_char_w = 9.0

	title_reserve_for : Str -> F32
	title_reserve_for = |title| 36.0 + U64.to_f32(Str.count_utf8_bytes(title)) * title_char_w + 12.0

	# the chip row for the curve on screen, laid out against its own title
	chips_for : F32, Db.CurveKeys, Str -> List(Chip)
	chips_for = |win_w, keys, cur| curve_chips(win_w, keys, cur, title_reserve_for(title_text(cur)))

	# the same sport's curve of the other kind: a power family's most-used
	# pace sport, or a pace sport's power family; '' when it has none
	counterpart : Db.CurveKeys, Str -> Str
	counterpart = |keys, cur|
		match Bus.curve_key(cur) {
			Power(fam) => (List.first(List.keep_if(keys.pace, |k| pace_family(k) == fam))).ok_or("")
			Pace(sp) => if (List.contains(keys.power, Sports.canonical(sp))) Sports.canonical(sp) else ""
		}

	# the family a pace key's sport belongs to; '' for a power key
	pace_family : Str -> Str
	pace_family = |k|
		match Bus.curve_key(k) {
			Pace(sp) => Sports.canonical(sp)
			Power(_) => ""
		}

	# the sport chips in one fixed order on every page: bike, row, run, then
	# any other sport in the order it arrived
	chip_order : List(Str) -> List(Str)
	chip_order = |ks| {
		rank = |k| {
			fam = match Bus.curve_key(k) {
				Power(f) => f
				Pace(sp) => Sports.canonical(sp)
			}
			if (fam == "Ride") 0.U64 else if (fam == "Rowing") 1 else if (fam == "Run") 2 else 3
		}
		ranked = List.map_with_index(ks, |k, i| { k, i, r: rank(k) })
		List.map(List.sort_with(ranked, |a, b| if (a.r < b.r) Before else if (a.r > b.r) After else if (a.i < b.i) Before else if (a.i > b.i) After else Same), |e| e.k)
	}

	curve_chips : F32, Db.CurveKeys, Str, F32 -> List(Chip)
	curve_chips = |win_w, keys, cur, title_reserve| {
		chip0 = win_w - 420.0
		pace_on = is_pace(cur)
		other = counterpart(keys, cur)
		modes =
			if (other == "") []
			else [
				{ key: if (pace_on) other else cur, label: "power", x: chip0 + 176.0, w: chip_w, on: !pace_on },
				{ key: if (pace_on) cur else other, label: "pace", x: chip0 + 234.0, w: chip_w, on: pace_on },
			]
		mode_keys = chip_order(
			if (pace_on) List.concat(keys.pace, List.keep_if(keys.power, |k| counterpart(keys, k) == ""))
			else List.concat(keys.power, List.keep_if(keys.pace, |k| counterpart(keys, k) == "")),
		)
		# the sport chips that fit between the title and the range chips, in
		# order, the one on screen always among them, laid out right-aligned
		# 14 px short of the first range chip
		right = chip0 - 14.0
		span = |ks| List.fold(ks, 0.0, |a, k| a + chip_w_for(chip_label(k)) + chip_gap) - chip_gap
		fits = |ks| span(ks) <= right - title_reserve
		# the longest leading run of ks that fits with tail after it
		lead = |ks, tail| (List.fold(ks, { out: [], open: Bool.True }, |acc, k| if (acc.open and fits(List.concat(List.append(acc.out, k), tail))) { out: List.append(acc.out, k), open: Bool.True } else { out: acc.out, open: Bool.False })).out
		first_n = lead(mode_keys, [])
		shown =
			if (List.contains(first_n, cur) or !(List.contains(mode_keys, cur)) or !(fits([cur]))) first_n
			else List.append(lead(first_n, [cur]), cur)
		placed = List.fold(
			shown,
			{ at: right - span(shown), out: [] },
			|acc, k| {
				w = chip_w_for(chip_label(k))
				{ at: acc.at + w + chip_gap, out: List.append(acc.out, { key: k, label: chip_label(k), x: acc.at, w, on: k == cur }) }
			},
		)
		List.concat(placed.out, modes)
	}

	# the key under x on the chip row, or '' between and beside the chips
	chip_at : List(Chip), F32 -> Str
	chip_at = |chips, x|
		match List.find_first(chips, |c| x >= c.x and x <= c.x + c.w) {
			Ok(c) => c.key
			Err(_) => ""
		}

	# ── the signal a curve key draws. A family head draws power in watts; a
	# pace key draws speed, carried through the rows in millimetres per
	# second and read aloud as pace in the sport's own unit, so the dot
	# further right is the faster one either way.
	is_pace : Str -> Bool
	is_pace = |curve|
		match Bus.curve_key(curve) {
			Pace(_) => Bool.True
			Power(_) => Bool.False
		}

	# the metres a pace curve reads its pace over, and how that reads aloud:
	# rowing per 500m, swimming per 100m, the foot sports per kilometre or
	# per mile as the athlete's units say
	pace_unit_for : [Metric, Imperial], Str -> { m : F64, label : Str }
	pace_unit_for = |units, sport| {
		fam = Sports.canonical(sport)
		label = Sports.pace_label_for(units, fam)
		if (fam == "Rowing" or fam == "Swim") ({ m: I64.to_f64(Sports.pace_unit(fam).dist_m), label }) else { m: Units.split_len(units), label }
	}

	# a speed in millimetres per second as the pace it is, in seconds per
	# unit; 0 for no speed
	pace_secs : I64, F64 -> I64
	pace_secs = |mmps, unit_m| if (mmps <= 0) 0 else (F64.round_to_i64_try(unit_m * 1000.0 / I64.to_f64(mmps)) ?? 0)

	# what the key is called on screen: a chip's short label, a family's own
	# word, and a sport outside every family in plain words
	# (Career.sport_word)
	chip_label : Str -> Str
	chip_label = |curve|
		match Bus.curve_key(curve) {
			Power(fam) =>
				if (fam == "Ride") "bike"
				else match List.first(List.keep_if(Sports.families, |f| List.first(f.sports) == Ok(fam))) {
					Ok(f) => (List.first(f.words)).ok_or(Career.sport_word(fam))
					Err(_) => Career.sport_word(fam)
				}
			Pace(sp) =>
				if (sp == "TrailRun") "trail"
				else if (sp == "VirtualRun") "v-run"
				else if (sp == "OpenWaterSwim") "open"
				else if (sp == "VirtualRow") "v-row"
				else match List.first(List.keep_if(Sports.families, |f| List.first(f.sports) == Ok(sp))) {
					Ok(f) => (List.first(f.words)).ok_or(Career.sport_word(sp))
					Err(_) => Career.sport_word(sp)
				}
		}

	# the view's title line, the sport in plain words
	title_text : Str -> Str
	title_text = |curve|
		match Bus.curve_key(curve) {
			Pace(sp) => "your best ${Career.sport_word(sp)} pace"
			Power(fam) => "your best ${Career.sport_word(fam)} power"
		}

	# what the view says when the chosen curve has no data on record: the
	# choice is kept, and the note says which kind of effort is missing. A
	# power family whose sessions carry only Strava's estimated watts says
	# that instead, in the words `doctor` and `power-curve` use (core
	# Sports.estimated_power_only): it has rides, just no power meter.
	empty_note : Str, List(Str) -> Str
	empty_note = |curve, estimated|
		match Bus.curve_key(curve) {
			Pace(sp) => "no ${Career.sport_word(sp)} pace on record yet"
			Power(fam) => if (List.contains(estimated, fam)) "${Career.sport_word(fam)}: ${Sports.estimated_power_only}" else "no ${Career.sport_word(fam)} power on record yet"
		}

	# a scale label: plain watts, or the pace without its unit
	axis_text : Str, [Metric, Imperial], I64 -> Str
	axis_text = |curve, units, v|
		match Bus.curve_key(curve) {
			Power(_) => I64.to_str(v)
			Pace(sp) => Fmt.mmss(pace_secs(v, (pace_unit_for(units, sp)).m))
		}

	# the power rule spacing: the smallest of the round steps that leaves at
	# most six rules between lo and hi
	power_step : F32, F32 -> F32
	power_step = |lo, hi| List.fold([1000.0, 500.0, 250.0, 200.0, 100.0, 50.0, 25.0, 20.0, 10.0, 5.0], 1000.0, |best, s| if ((hi - lo) / s <= 6.0) s else best)

	# The scale's rules strictly between lo and hi. A power scale rules every
	# power_step watts. A pace scale rules round paces in its own unit, every
	# 5, 10, 15, 20 or 30 seconds or every 1, 2 or 5 minutes - the smallest
	# step that leaves at most six rules - placed at the speed each pace is.
	grid_vals : Str, [Metric, Imperial], F32, F32 -> List(F32)
	grid_vals = |curve, units, lo, hi|
		match Bus.curve_key(curve) {
			Power(_) => {
				step = power_step(lo, hi)
				first = F32.div_floor_by(lo, step) + 1.0
				n = F32.round_to_u64_try((hi - lo) / step + 1.0) ?? 0
				List.keep_if(List.map_with_index(List.repeat({}, n), |_u, k| (first + U64.to_f32(k)) * step), |v| v > lo and v < hi)
			}
			Pace(sp) => {
				m = (pace_unit_for(units, sp)).m
				speed_of = |p| I64.to_f32(F64.round_to_i64_try(m * 1000.0 / I64.to_f64(p)) ?? 0)
				fast = pace_secs(F32.round_to_i64_try(hi) ?? 0, m)
				slow = pace_secs(F32.round_to_i64_try(lo) ?? 0, m)
				if (fast <= 0 or slow <= fast) []
				else {
					step = List.fold([300, 120, 60, 30, 20, 15, 10, 5], 600, |best, s| if ((slow - fast) // s <= 6) s else best)
					first = (fast + step - 1) // step
					count = slow // step - first + 1
					paces = if (count <= 0) [] else List.map_with_index(List.repeat({}, I64.to_u64_wrap(count)), |_u, k| (first + U64.to_i64_wrap(k)) * step)
					List.keep_if(List.map(paces, speed_of), |v| v > lo and v < hi)
				}
			}
		}

	# ── whether the window's fit is usable, the test-due rule's half ───────
	# A CP fit is usable when r2 is at or above fit_r2_min and W' sits inside
	# a physiologically plausible band. A fit through steady class bests
	# rather than maximal ones returns a W' of a few kJ, far below any
	# rider's anaerobic capacity.
	fit_r2_min : F32
	fit_r2_min = 0.9

	w_prime_lo : F32
	w_prime_lo = 5000.0

	w_prime_hi : F32
	w_prime_hi = 40000.0

	fit_usable : Db.Fit -> Bool
	fit_usable = |fit| fit.ok and fit.r2 >= fit_r2_min and fit.w_prime >= w_prime_lo and fit.w_prime <= w_prime_hi

	# A critical-speed fit is usable on the same terms: r2 at the floor and
	# D' inside a plausible band. D' is the distance an athlete can cover
	# above critical speed, and its scale is the sport's: tens of metres in
	# the water, low hundreds on the erg, up to several hundred on foot, so
	# each family gets its own band.
	d_prime_band : Str -> { lo : F32, hi : F32 }
	d_prime_band = |sport| {
		fam = Sports.canonical(sport)
		if (fam == "Swim") ({ lo: 5.0, hi: 100.0 })
		else if (fam == "Rowing") ({ lo: 10.0, hi: 300.0 })
		else { lo: 10.0, hi: 600.0 }
	}

	fit_usable_for : Str, Db.Fit -> Bool
	fit_usable_for = |curve, fit|
		match Bus.curve_key(curve) {
			Pace(sp) => {
				band = d_prime_band(sp)
				fit.ok and fit.r2 >= fit_r2_min and fit.w_prime >= band.lo and fit.w_prime <= band.hi
			}
			Power(_) => fit_usable(fit)
		}

	# the focus row's curve_short: the view folds no rungs, so always -1
	# (NULL), the value that has always meant nothing to fold
	focus_short : I64
	focus_short = -1
}

# ── the rows ────────────────────────────────────────────────────────────────
# a row for each story duration the curve's ladder carries: four on a power
# ladder, three on the pace ladder, which stops at 20 minutes; a window
# with no best at a duration reads 0 there, a best rounds to whole units,
# and a row knows whether the record book holds any best at its duration
expect {
	pt = |d, w| { dur_s: d, watts: w }
	power = [5, 15, 30, 60, 300, 600, 1200, 3600]
	pace = [300, 600, 1200]
	prs = |secs| List.map(secs, |s| { secs: s, w: if (s == 3600) 0 else 300 })
	p = Curve.pairs_of(prs(power), [pt(300, 262.4), pt(1200, 254.6)], [pt(300, 274.0), pt(3600, 230.0)])
	List.map(p, |r| r.secs) == [300, 600, 1200, 3600]
		and List.map(p, |r| r.now) == [262, 0, 255, 0]
		and List.map(p, |r| r.prev) == [274, 0, 0, 230]
		and List.map(p, |r| r.ever) == [Bool.True, Bool.True, Bool.True, Bool.False]
		and List.map(p, |r| r.i) == [0, 1, 2, 3]
		and List.map(Curve.pairs_of(prs(pace), [], []), |r| r.secs) == [300, 600, 1200]
		and List.map(p, Curve.rung_name) == ["5 min", "10 min", "20 min", "60 min"]
}

# every dot sits at its own value on the shared scale, the window before's
# grey and smaller, this window's blue; an absent best draws no dot
expect {
	g = { xl: 170.0, xr: 1000.0, top: 300.0, pitch: 50.0, rows: 4, lo: 200.0, hi: 300.0 }
	both = Curve.row_dots(g, { secs: 300, now: 262, prev: 274, ever: Bool.False, i: 1 })
	near = |a, b| (a - b).abs() < 0.01
	match both {
		[prev, now] =>
			near(prev.x, 170.0 + 0.74 * 830.0) and near(prev.y, 350.0) and prev.r == Curve.prev_r and !prev.now
				and near(now.x, 170.0 + 0.62 * 830.0) and near(now.y, 350.0) and now.r == Curve.now_r and now.now
				and Curve.now_r > Curve.prev_r
				and List.len(Curve.row_dots(g, { secs: 600, now: 0, prev: 274, ever: Bool.False, i: 2 })) == 1
				and Curve.row_dots(g, { secs: 600, now: 0, prev: 0, ever: Bool.False, i: 2 }) == []
		_ => Bool.False
	}
}

# the scale leaves room on both sides of the printed values, ignores an
# absent best, and centres a single value
expect {
	s = Curve.value_span([262, 0, 274, 233])
	one = Curve.value_span([250])
	s.lo < 233.0 and s.hi > 274.0 and (one.hi - 250.0 - (250.0 - one.lo)).abs() < 0.001 and one.lo < 250.0
}

# the change: a drop prints its watts with a minus in red, a gain with a
# plus in green, a pair within a watt either way reads level in grey, and
# a row missing either best prints none; on a pace curve the change is in
# seconds of pace, a faster window is a gain, and the same printed pace is
# level
expect Curve.change_text("Ride", Metric, 262, 274) == "-12 W" and Curve.change_col("Ride", Metric, 262, 274) == Theme.alarm_c
expect Curve.change_text("Ride", Metric, 274, 262) == "+12 W" and Curve.change_col("Ride", Metric, 274, 262) == Theme.tsb_c
expect Curve.change_text("Ride", Metric, 256, 254) == "+2 W" and Curve.change_col("Ride", Metric, 256, 254) == Theme.tsb_c
expect Curve.change_text("Ride", Metric, 255, 254) == "level" and Curve.change_text("Ride", Metric, 254, 255) == "level" and Curve.change_text("Ride", Metric, 254, 254) == "level"
expect Curve.change_col("Ride", Metric, 255, 254) == Theme.ink_faint and Curve.change_col("Ride", Metric, 254, 255) == Theme.ink_faint
expect Curve.change_text("Ride", Metric, 0, 254) == "" and Curve.change_text("Ride", Metric, 254, 0) == ""
expect Curve.change_text("pace:Run", Metric, 4000, 3846) == "-10s" and Curve.change_col("pace:Run", Metric, 4000, 3846) == Theme.tsb_c
expect Curve.change_text("pace:Run", Metric, 3846, 4000) == "+10s" and Curve.change_col("pace:Run", Metric, 3846, 4000) == Theme.alarm_c
expect Curve.change_text("pace:Run", Metric, 4000, 4001) == "level" and Curve.change_col("pace:Run", Metric, 4000, 4001) == Theme.ink_faint

# a row with no best in either window says what it lacked: on a pace curve
# that many minutes without a stop, on a power curve a session that long
expect Curve.empty_text("pace:Run", 90, { secs: 1200, now: 0, prev: 0, ever: Bool.False, i: 2 }) == "no 20 minutes without stopping yet"
expect Curve.empty_text("pace:Rowing", 90, { secs: 600, now: 0, prev: 0, ever: Bool.False, i: 1 }) == "no 10 minutes without stopping yet"
expect Curve.empty_text("Ride", 90, { secs: 3600, now: 0, prev: 0, ever: Bool.False, i: 3 }) == "no 60-minute ride yet" and Curve.empty_text("Rowing", 90, { secs: 3600, now: 0, prev: 0, ever: Bool.False, i: 3 }) == "no 60-minute row yet"
# a row with a best on record from before both windows says it is older
# than both, never that there has been none
expect Curve.empty_text("Ride", 90, { secs: 3600, now: 0, prev: 0, ever: Bool.True, i: 3 }) == "none in the last 180 days" and Curve.empty_text("pace:Run", 30, { secs: 1200, now: 0, prev: 0, ever: Bool.True, i: 2 }) == "none in the last 60 days"
expect Curve.gone_text(90) == "none in the last 90 days" and Curve.new_text == "none before"

# a scale rule leaves a gap around each empty row's sentence and runs
# whole when there is none
expect Curve.rule_pieces(100.0, 400.0, [{ x0: 0.0, x1: 10.0, y0: 190.0, y1: 210.0 }]) == [{ a: 100.0, b: 190.0 }, { a: 210.0, b: 400.0 }]
expect Curve.rule_pieces(100.0, 400.0, []) == [{ a: 100.0, b: 400.0 }]
expect Curve.rule_pieces(100.0, 400.0, [{ x0: 0.0, x1: 10.0, y0: 190.0, y1: 210.0 }, { x0: 0.0, x1: 10.0, y0: 380.0, y1: 420.0 }]) == [{ a: 100.0, b: 190.0 }, { a: 210.0, b: 380.0 }]

# ── the legend ──────────────────────────────────────────────────────────────
# the window before, then this window; an empty window before is said once,
# with no dot, named for the sport
expect {
	with_prev = [{ secs: 300, now: 262, prev: 274, ever: Bool.False, i: 0 }]
	no_prev = [{ secs: 300, now: 262, prev: 0, ever: Bool.False, i: 0 }, { secs: 600, now: 0, prev: 0, ever: Bool.False, i: 1 }]
	Curve.legend_items("Ride", 90, with_prev) == [{ now: Bool.False, dot: Bool.True, label: "the 90 days before" }, { now: Bool.True, dot: Bool.True, label: "last 90 days" }]
		and Curve.legend_items("Ride", 90, no_prev) == [{ now: Bool.False, dot: Bool.False, label: "the 90 days before: no rides" }, { now: Bool.True, dot: Bool.True, label: "last 90 days" }]
		and Curve.legend_items("pace:Run", 30, no_prev) == [{ now: Bool.False, dot: Bool.False, label: "the 30 days before: no runs" }, { now: Bool.True, dot: Bool.True, label: "last 30 days" }]
		and Curve.no_sessions("Rowing") == "no rowing" and Curve.no_sessions("pace:VirtualRow") == "no rowing" and Curve.no_sessions("pace:Swim") == "no swims"
}

# ── the top line ────────────────────────────────────────────────────────────
# each due line names the condition that fired and nothing else: steady
# bests that fit no curve, named by the durations the window has, or too
# few bests to fit; none carries a day count of its own. An answer that
# lacks the fit says it could not be read, and asks for no test
expect {
	weak = { cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }
	none = { value: 0.0, kind: "none", date: "none" }
	info = { fit: weak, test: none, thr: 241.0, thr_known: Bool.True, from_test: Bool.False }
	all3 = [300, 600, 1200]
	due = Curve.top_line("Ride", Metric, 90, info, all3)
	due == { text: "Test due: your 5, 10 and 20-minute bests of the last 90 days were not flat out - ride 20 minutes as hard as you can to update your FTP (now 241 W)", due: Bool.True }
		and !(Str.contains(due.text, " ago"))
		and Curve.top_line("Ride", Metric, 90, { ..info, fit: { ..weak, r2: 0.95, w_prime: 60000.0 } }, all3) == due
		and (Curve.top_line("Ride", Metric, 90, info, [300, 1200])).text == "Test due: your 5 and 20-minute bests of the last 90 days were not flat out - ride 20 minutes as hard as you can to update your FTP (now 241 W)"
		and Curve.top_line("Ride", Metric, 90, { ..info, fit: { cp: 0.0, w_prime: 0.0, r2: 0.0, points: 1.0, ok: Bool.True } }, [1200]) == { text: "Test due: too few hard 5 to 20-minute efforts in the last 90 days to check your FTP - ride 20 minutes as hard as you can to update your FTP (now 241 W)", due: Bool.True }
		and Curve.top_line("Ride", Metric, 90, { ..info, fit: { ..weak, ok: Bool.False } }, all3) == { text: "Your FTP could not be read from stride - press R to try again, or update stride", due: Bool.False }
		and (Curve.top_line("Rowing", Metric, 30, { ..info, thr: 121.0 }, all3)).text == "Test due: your 5, 10 and 20-minute bests of the last 30 days were not flat out - row 20 minutes as hard as you can to update your FTP (now 121 W)"
}
expect Curve.bests_named([300, 600, 1200]) == "your 5, 10 and 20-minute bests" and Curve.bests_named([600, 1200]) == "your 10 and 20-minute bests" and Curve.bests_named([1200]) == "your 20-minute best"
expect Curve.fit_bests([{ secs: 300, now: 262, prev: 0, ever: Bool.True, i: 0 }, { secs: 600, now: 0, prev: 271, ever: Bool.True, i: 1 }, { secs: 1200, now: 254, prev: 0, ever: Bool.True, i: 2 }, { secs: 3600, now: 233, prev: 0, ever: Bool.True, i: 3 }]) == [300, 1200]

# the top line over what the loader really reads: a failed call (no text)
# and an answer from a stride that predates the threshold fields both say
# the threshold could not be read and claim nothing else, never "No FTP
# yet"; an answer with a threshold of 0 is the engine saying there is none;
# an answer with one is printed, credited to the test only when its source
# says the test set it
expect {
	head = "{\"schema_version\":3,\"data\":{\"window_days\":90,\"sport\":\"Ride\",\"points\":[],\"cp\":252.9,\"w_prime\":2980.0,\"fit_r2\":0.84,\"fit_points\":3,\"test_known\":false,\"test_value\":0,\"test_kind\":\"\",\"test_date\":\"\""
	old = Db.parse_fit("${head}}}", Bool.False)
	failed = Db.parse_fit("", Bool.False)
	none = Db.parse_fit("${head},\"ftp_w\":0,\"ftp_source\":\"derived\"}}", Bool.False)
	derived = Db.parse_fit("${head},\"ftp_w\":241,\"ftp_source\":\"derived\"}}", Bool.False)
	unread = "Your FTP could not be read from stride - press R to try again, or update stride"
	line = |info| (Curve.top_line("Ride", Metric, 90, info, [300, 600, 1200])).text
	!old.thr_known and !failed.thr_known and none.thr_known and derived.thr_known
		and line(failed) == unread
		and line(old) == unread
		and line(none) == "No FTP yet - ride 20 minutes hard twice within 60 days to set one"
		and line(derived) == "Test due: your 5, 10 and 20-minute bests of the last 90 days were not flat out - ride 20 minutes as hard as you can to update your FTP (now 241 W)"
}
expect {
	tested = Db.parse_fit("{\"data\":{\"cp\":250.0,\"w_prime\":15000.0,\"fit_r2\":0.95,\"fit_points\":3,\"test_known\":true,\"test_value\":246.5,\"test_kind\":\"cp3-12\",\"test_date\":\"2026-10-27\",\"ftp_w\":247,\"ftp_source\":\"test\"}}", Bool.False)
	under = Db.parse_fit("{\"data\":{\"cp\":250.0,\"w_prime\":15000.0,\"fit_r2\":0.95,\"fit_points\":3,\"test_known\":true,\"test_value\":217.0,\"test_kind\":\"ftp20\",\"test_date\":\"2026-11-14\",\"ftp_w\":241,\"ftp_source\":\"derived\"}}", Bool.False)
	run = Db.parse_fit("{\"data\":{\"cs\":3.4,\"d_prime\":200.0,\"fit_r2\":0.95,\"fit_points\":3,\"test_known\":false,\"test_value\":0,\"test_kind\":\"\",\"test_date\":\"\",\"threshold_speed\":3.5,\"threshold_source\":\"derived\"}}", Bool.True)
	(Curve.top_line("Ride", Metric, 90, tested, [300, 600, 1200])).text == "FTP 247 W - set by your test on 10-27"
		and (Curve.top_line("Ride", Metric, 90, under, [300, 600, 1200])).text == "FTP 241 W - from your best 20 minutes of the last 60 days, higher than your test on 11-14"
		and run.thr_known and (run.thr - 3.5).abs() < 0.001 and (Curve.top_line("pace:Run", Metric, 90, run, [300, 600, 1200])).text == "threshold pace ${Curve.v_text("pace:Run", Metric, 3500)} - no test due"
}

# a test is credited only when it set the threshold the engine scores
# with: in force and at least the derivation, the line names the test;
# in force but under the 60-day derivation, it names the derivation and
# says the test is lower, both orders; a usable fit with no test says no
# test is due and never asks for flat-out efforts
expect {
	weak = { cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }
	good = { cp: 250.0, w_prime: 15000.0, r2: 0.95, points: 3.0, ok: Bool.True }
	none = { value: 0.0, kind: "none", date: "none" }
	all3 = [300, 600, 1200]
	low = Curve.top_line("Ride", Metric, 90, { fit: weak, test: { value: 217.0, kind: "ftp20", date: "2026-11-14" }, thr: 241.0, thr_known: Bool.True, from_test: Bool.False }, all3)
	high = Curve.top_line("Ride", Metric, 90, { fit: weak, test: { value: 246.5, kind: "cp3-12", date: "2026-10-27" }, thr: 246.5, thr_known: Bool.True, from_test: Bool.True }, all3)
	usable = Curve.top_line("Ride", Metric, 90, { fit: good, test: none, thr: 241.0, thr_known: Bool.True, from_test: Bool.False }, all3)
	low == { text: "FTP 241 W - from your best 20 minutes of the last 60 days, higher than your test on 11-14", due: Bool.False }
		and !(Str.contains(low.text, "set by your test"))
		and high == { text: "FTP 247 W - set by your test on 10-27", due: Bool.False }
		and usable == { text: "FTP 241 W - no test due", due: Bool.False }
		and !(Str.contains(usable.text, "flat out"))
		and (Curve.top_line("pace:Run", Metric, 90, { fit: weak, test: { value: 3.2, kind: "5k", date: "2026-11-02" }, thr: 3.5, thr_known: Bool.True, from_test: Bool.False }, all3)).text == "threshold pace ${Curve.v_text("pace:Run", Metric, 3500)} - from your best 20 minutes of the last 60 days, faster than your test on 11-02"
}

# a curve with no threshold says how to get one, in the sport's own verb,
# and on foot names the 5 km time trial too
expect {
	none = { value: 0.0, kind: "none", date: "none" }
	info = { fit: { cp: 0.0, w_prime: 0.0, r2: 0.0, points: 0.0, ok: Bool.True }, test: none, thr: 0.0, thr_known: Bool.True, from_test: Bool.False }
	Curve.top_line("Ride", Metric, 90, info, []) == { text: "No FTP yet - ride 20 minutes hard twice within 60 days to set one", due: Bool.True }
		and (Curve.top_line("Rowing", Metric, 90, info, [])).text == "No FTP yet - row 20 minutes hard twice within 60 days to set one"
		and (Curve.top_line("pace:Run", Imperial, 90, info, [])).text == "No threshold pace yet - run 20 minutes without stopping twice within 60 days, or run 5 km as fast as you can and mark it as a test"
		and (Curve.top_line("pace:TrailRun", Metric, 90, info, [])).text == "No threshold pace yet - run 20 minutes without stopping twice within 60 days, or run 5 km as fast as you can and mark it as a test"
		and (Curve.top_line("pace:Rowing", Metric, 90, info, [])).text == "No threshold pace yet - row 20 minutes without stopping twice within 60 days to set one"
}

# a pace curve's due line asks for the effort without stopping and reads
# the threshold as a pace in the sport's unit
expect {
	info = { fit: { cp: 3.4, w_prime: 2000.0, r2: 0.95, points: 3.0, ok: Bool.True }, test: { value: 0.0, kind: "none", date: "none" }, thr: 3.5, thr_known: Bool.True, from_test: Bool.False }
	(Curve.top_line("pace:Run", Metric, 60, info, [300, 600, 1200])).text == "Test due: your 5, 10 and 20-minute bests of the last 60 days were not flat out - run 20 minutes as hard as you can without stopping to update your threshold pace (now ${Curve.v_text("pace:Run", Metric, 3500)})" and Curve.pace_secs(3500, 1000.0) == 286
}

# a long note wraps greedily at word breaks, a word wider than the line
# keeps a line of its own, and a note that fits stays one line
expect {
	m = |s, size, _face| U64.to_f32(Str.count_utf8_bytes(s)) * size / 16.0
	Curve.wrap(m, "aa bb cc dd", 5.0) == ["aa bb", "cc dd"]
		and Curve.wrap(m, "aa bbbbbbb cc", 5.0) == ["aa", "bbbbbbb", "cc"]
		and Curve.wrap(m, "aa bb", 20.0) == ["aa bb"]
}

# the focus row's curve_short: the view folds nothing
expect Curve.focus_short == -1

# ── the chips ──────────────────────────────────────────────────────────────
# the sport chips keep one order on every page: bike, row, run, then the
# rest in arrival order
expect Curve.chip_order(["pace:Run", "Rowing", "Ride", "pace:Swim", "Walk"]) == ["Ride", "Rowing", "pace:Run", "pace:Swim", "Walk"]
expect List.map(Curve.curve_chips(1400.0, { power: ["Rowing", "Ride"], pace: ["pace:Rowing", "pace:Run"] }, "pace:Run", 340.0), |c| c.label) == ["bike", "row", "run"]
expect List.map(Curve.curve_chips(1400.0, { power: ["Rowing", "Ride"], pace: ["pace:Rowing", "pace:Run"] }, "Rowing", 340.0), |c| c.label) == ["bike", "row", "run", "power", "pace"]

# the curve chips: right-aligned against the range chips in the fixed
# order, as many as fit beside the title, the one on screen always among
# them and lit. Power mode lists the power families, then the pace sports
# with no power family; pace mode the reverse. The power and pace pair
# appears only when the sport on screen has a curve of the other kind, so
# a ride, which has no pace curve, shows none.
expect {
	keys = { power: ["Ride", "Rowing", "Run"], pace: ["pace:Rowing", "pace:Run", "pace:Swim", "pace:TrailRun", "pace:Walk"] }
	bike = Curve.curve_chips(1400.0, keys, "Ride", 340.0)
	row = Curve.curve_chips(1400.0, keys, "Rowing", 340.0)
	narrow = Curve.curve_chips(980.0, keys, "pace:TrailRun", 340.0)
	labels = |cs| List.map(cs, |c| c.label)
	labels(bike) == ["bike", "row", "run", "swim", "walk"]
		and List.map(List.keep_if(bike, |c| c.on), |c| c.label) == ["bike"]
		and labels(row) == ["bike", "row", "run", "swim", "walk", "power", "pace"]
		and Curve.chip_at(row, 1400.0 - 420.0 + 234.0 + 10.0) == "pace:Rowing"
		and Curve.chip_at(row, 1400.0 - 420.0 + 176.0 + 10.0) == "Rowing"
		and Curve.chip_at(bike, 1400.0 - 420.0 + 234.0 + 10.0) == ""
		and labels(narrow) == ["bike", "row", "trail", "power", "pace"]
		and List.map(List.keep_if(narrow, |c| c.on), |c| c.key) == ["pace:TrailRun", "pace:TrailRun"]
		and List.map(List.keep_if(narrow, |c| c.label == "power"), |c| c.key) == ["Run"]
		and List.all(narrow, |c| c.x >= 340.0)
		and Curve.chip_at(bike, 1400.0 - 420.0 - 2.0) == ""
}
# a pace sport's counterpart is its family's power curve, and a power
# family's is its most-used pace sport; a ride and a pool swim have none
expect {
	keys = { power: ["Ride", "Run"], pace: ["pace:TrailRun", "pace:Run", "pace:Swim"] }
	Curve.counterpart(keys, "Run") == "pace:TrailRun" and Curve.counterpart(keys, "pace:Run") == "Run" and Curve.counterpart(keys, "Ride") == "" and Curve.counterpart(keys, "pace:Swim") == ""
}
# one kind of curve on record: no power and pace pair
expect List.map(Curve.curve_chips(1400.0, { power: [], pace: ["pace:Swim", "pace:OpenWaterSwim"] }, "pace:Swim", 340.0), |c| c.label) == ["swim", "open"]
# the chips' last right edge sits 14 px left of the first range chip
expect {
	cs = Curve.curve_chips(1400.0, { power: ["Ride", "Rowing"], pace: [] }, "Ride", 340.0)
	match List.last(cs) {
		Ok(c) => c.x + c.w == 1400.0 - 420.0 - 14.0
		Err(_) => Bool.False
	}
}
# the longest title a pace curve takes, at the minimum width with three
# curves on record: no chip starts inside the title's text
expect {
	keys = { power: [], pace: ["pace:OpenWaterSwim", "pace:Swim", "pace:Run"] }
	title = Curve.title_text("pace:OpenWaterSwim")
	title == "your best open water swim pace"
		and List.all(Curve.chips_for(980.0, keys, "pace:OpenWaterSwim"), |c| c.x >= 36.0 + U64.to_f32(Str.count_utf8_bytes(title)) * Curve.title_char_w)
}
expect Curve.chip_bottom - Curve.chip_top == 22.0

# ── words and units ────────────────────────────────────────────────────────
# a sport reads in plain words: a family by its activity, a sport outside
# every family split into its words, on the title, the empty note and an
# empty row
expect Curve.title_text("Ride") == "your best cycling power" and Curve.title_text("Rowing") == "your best rowing power" and Curve.title_text("pace:TrailRun") == "your best trail run pace" and Curve.title_text("StandUpPaddling") == "your best stand up paddling power"
expect Curve.empty_note("Rowing", []) == "no rowing power on record yet" and Curve.empty_note("Ride", []) == "no cycling power on record yet" and Curve.empty_note("pace:Swim", []) == "no swimming pace on record yet" and Curve.empty_note("StandUpPaddling", []) == "no stand up paddling power on record yet"
# a ride family whose only watts are estimated reads the words `stride
# doctor` and `stride power-curve` print for the same sessions (pinned in
# the e2e suite), never "no power"
expect Curve.empty_note("Ride", ["Ride"]) == "cycling: estimated power only (no power meter)" and Curve.empty_note("Rowing", ["Ride"]) == "no rowing power on record yet"
expect Curve.chip_label("StandUpPaddling") == "stand up paddling" and Curve.chip_label("pace:Hike") == "hiking" and Curve.chip_label("pace:Rowing") == "row" and Curve.chip_label("pace:Run") == "run"
expect Curve.empty_text("StandUpPaddling", 90, { secs: 3600, now: 0, prev: 0, ever: Bool.False, i: 3 }) == "no 60-minute session yet"
# a chip widens to hold a long label and still ends 14 px short of the
# range chips; a click anywhere on it names its curve
expect {
	cs = Curve.curve_chips(1400.0, { power: ["Ride", "StandUpPaddling"], pace: [] }, "StandUpPaddling", 340.0)
	match cs {
		[bike, sup] => (bike.w - Curve.chip_w).abs() < 0.01 and sup.w > 120.0 and (sup.x + sup.w - (1400.0 - 420.0 - 14.0)).abs() < 0.01 and (sup.x - (bike.x + bike.w + Curve.chip_gap)).abs() < 0.01 and Curve.chip_at(cs, sup.x + sup.w - 2.0) == "StandUpPaddling"
		_ => Bool.False
	}
}
expect Curve.chip_label("Ride") == "bike" and Curve.chip_label("Run") == "run" and Curve.chip_label("WeightTraining") == "strength" and Curve.chip_label("Kayaking") == "kayaking" and Curve.chip_label("pace:OpenWaterSwim") == "open"
# speed reads as pace in the sport's own unit, the foot sports in the
# athlete's units; power reads in watts
expect Curve.v_text("pace:Run", Metric, 4000) == "4:10/km" and Curve.v_text("pace:Run", Imperial, 4000) == "6:42/mi" and Curve.v_text("pace:Swim", Imperial, 1000) == "1:40/100m" and Curve.v_text("pace:VirtualRow", Metric, 4000) == "2:05/500m"
expect Curve.v_text("Ride", Metric, 1234) == "1,234 W" and Curve.v_text("Ride", Metric, 262) == "262 W" and Curve.axis_text("Ride", Metric, 300) == "300" and Curve.axis_text("pace:Run", Metric, 4000) == "4:10"
expect Curve.power_step(200.0, 350.0) == 25.0 and Curve.power_step(0.0, 540.0) == 100.0 and Curve.power_step(240.0, 260.0) == 5.0
expect List.len(Curve.grid_vals("Ride", Metric, 0.0, 540.0)) == 5
expect List.map(Curve.grid_vals("pace:Run", Metric, 3465.0, 4689.0), |v| Curve.axis_text("pace:Run", Metric, F32.round_to_i64_try(v) ?? 0)) == ["3:45", "4:00", "4:15", "4:30", "4:45"]
expect List.map(Curve.grid_vals("pace:Swim", Metric, 1200.0, 1500.0), |v| Curve.axis_text("pace:Swim", Metric, F32.round_to_i64_try(v) ?? 0)) == ["1:10", "1:15", "1:20"]

# ── whether the fit is usable ──────────────────────────────────────────────
# a fit is usable at the r2 floor with a W' inside the band, and not a hair
# below either edge; an unanswered fit never is
expect Curve.fit_usable({ cp: 250.0, w_prime: 15000.0, r2: 0.9, points: 3.0, ok: Bool.True })
expect !Curve.fit_usable({ cp: 250.0, w_prime: 15000.0, r2: 0.89, points: 3.0, ok: Bool.True })
expect !Curve.fit_usable({ cp: 253.0, w_prime: 2980.0, r2: 0.95, points: 3.0, ok: Bool.True })
expect !Curve.fit_usable({ cp: 250.0, w_prime: 40001.0, r2: 0.95, points: 3.0, ok: Bool.True })
expect Curve.fit_usable({ cp: 250.0, w_prime: 5000.0, r2: 0.95, points: 3.0, ok: Bool.True })
expect !Curve.fit_usable({ cp: 250.0, w_prime: 15000.0, r2: 0.95, points: 3.0, ok: Bool.False })
# a CS fit is usable at the r2 floor with D' inside its band
expect Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 200.0, r2: 0.95, points: 3.0, ok: Bool.True }) and !Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 2000.0, r2: 0.95, points: 3.0, ok: Bool.True }) and !Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 200.0, r2: 0.85, points: 3.0, ok: Bool.True })
# the D' band is the sport's own: a 150 m D' is a plausible run fit and an
# implausible swim one, and an open-water swim takes the pool's band
expect Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 150.0, r2: 0.95, points: 3.0, ok: Bool.True }) and !Curve.fit_usable_for("pace:Swim", { cp: 1.2, w_prime: 150.0, r2: 0.95, points: 3.0, ok: Bool.True }) and Curve.fit_usable_for("pace:OpenWaterSwim", { cp: 1.2, w_prime: 30.0, r2: 0.95, points: 3.0, ok: Bool.True })
expect Curve.d_prime_band("Rowing") == { lo: 10.0, hi: 300.0 } and Curve.d_prime_band("VirtualRow") == { lo: 10.0, hi: 300.0 } and Curve.d_prime_band("TrailRun") == { lo: 10.0, hi: 600.0 }
