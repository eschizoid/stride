import rr.Color
import rr.Draw
import core.Fmt
import core.Load
import Chrome
import Db
import Labels
import Scene
import Theme
import Ui
import Weeks

Ramp :: [].{
	# The weeks tab's load mode: twelve Monday weeks, each bar that week's
	# load as a share of its hold level, the load that would have left CTL
	# where the week started (core.Load.hold: CTL at the week's start times
	# the days the week counts, so a week still running is held to the days
	# it has had). Every bar shares one scale, so one white line at 100%
	# crosses the plot: a bar over it gained fitness and one under it lost
	# fitness. Each bar wears a chip with the CTL it gained, and bar and chip
	# share the verdict's color: muted for a week that held or lost fitness,
	# blue for one that gained, red for one that gained more than
	# ramp_limit. The week's load sits under its date.
	#
	# The scale fits the tallest bar, the running week's included, so no
	# bar is ever cut short. A week that started from zero CTL has no hold
	# to share and keeps a stub.

	pad : F32
	pad = 36.0

	# the CTL a week may gain, in whole points, before it climbs too fast:
	# past it a week's bar and chip turn red, and the key says so
	ramp_limit : I64
	ramp_limit = 6

	# the verdict a week's ramp earns, in tenths of CTL, as its bar's and
	# chip's color: a flat week is not a build, so it reads muted with the
	# weeks that lost fitness
	verdict : I64 -> Color.Rgba
	verdict = |ramp10| if (ramp10 > ramp_limit * 10) (Theme.alarm_c) else if (ramp10 > 0) (Theme.ctl_c) else Theme.ink_muted

	# the bar's opacity: the focused week brightest, a week still running
	# faded, every finished week the same
	bar_alpha : Bool, I64 -> U8
	bar_alpha = |focused, days| if (focused) (250.U8) else if (Weeks.partial(days)) 110 else 220

	# the load that holds CTL over the days the week has had
	hold : Db.RampWeek -> F64
	hold = |w| Load.hold(w.ctl_start, w.days)

	# a week has a hold to share once it started with fitness to hold
	held : Db.RampWeek -> Bool
	held = |w| hold(w) > 0.0

	# the week's load as a share of its hold, 1.0 at the line
	ratio : Db.RampWeek -> F64
	ratio = |w| if (held(w)) (I64.to_f64(w.tss) / hold(w)) else 0.0

	# the share in whole percents
	pct : Db.RampWeek -> I64
	pct = |w| F64.round_to_i64_try(ratio(w) * 100.0) ?? 0

	# the lowest the scale's top may stand, in percent, so the line never
	# sits at the top
	min_top : I64
	min_top = 120

	# the scale's top in percent: the largest share across every week shown,
	# the running week's included, rounded up to a ten from the unrounded
	# share, so the tallest bar always fits under it; at least min_top
	top_of : List(Db.RampWeek) -> I64
	top_of = |weeks| {
		m = List.fold(weeks, I64.to_f64(min_top), |a, w| F64.max(a, ratio(w) * 100.0))
		k = F64.round_to_i64_try(m / 10.0) ?? (min_top // 10)
		if (I64.to_f64(k) * 10.0 < m) (k + 1) * 10 else k * 10
	}

	title_text : Str
	title_text = "weekly load, and how fast fitness climbs"

	hint_text : Str
	hint_text = "zones / load  modes      hover or click a week      TAB  career      R  reload      S  screenshot      V  record      ESC quit"

	# the key: the verdict's three colors, each a swatch and its name
	classes : List({ name : Str, color : Color.Rgba })
	classes = [
		{ name: "loses fitness", color: verdict(0) },
		{ name: "builds fitness", color: verdict(1) },
		{ name: "past +${I64.to_str(ramp_limit)} ctl a week", color: verdict(ramp_limit * 10 + 1) },
	]

	key_row : Scene.Measure -> List({ name : Str, color : Color.Rgba, swatch : Labels.Rect, text_x : F32 })
	key_row = |measure|
		List.fold(
			classes,
			{ x: pad, row: [] },
			|acc, c| {
				w = measure(c.name, 10.0, Data)
				{ x: acc.x + 13.0 + w + 14.0, row: List.append(acc.row, { name: c.name, color: c.color, swatch: { x: acc.x, y: 120.0, w: 9.0, h: 9.0 }, text_x: acc.x + 13.0 }) }
			},
		).row

	# the chart draws once any week holds load
	charted : Ui.Model -> Bool
	charted = |model| !(List.is_empty(model.ramp_weeks)) and List.fold(model.ramp_weeks, 0.I64, |a, w| a + w.tss) != 0

	# the plot starts under the band's top, leaving the tallest bar's chip
	# and the running week's "so far" room under the card
	plot_top : F32
	plot_top = Weeks.bars_top + 16.0

	plot_h : F32 -> F32
	plot_h = |win_h| Weeks.bars_bot(win_h) - plot_top

	# where the line at 100% of hold crosses, on a scale topping at `top`
	line_y : F32, I64 -> F32
	line_y = |win_h, top| Weeks.bars_bot(win_h) - plot_h(win_h) * 100.0 / I64.to_f32(top)

	line_box : { w : F32, h : F32 }, I64 -> Labels.Rect
	line_box = |win, top| { x: Weeks.plot_left - 2.0, y: line_y(win.h, top) - 1.0, w: win.w - pad - Weeks.plot_left + 2.0, h: 2.0 }

	# the clear space a chip keeps from the line, above or below
	line_gap : F32
	line_gap = 4.0

	# the line's name and its value, stacked in the gutter: the name just
	# over the value, the value centred on the line
	line_label : Str
	line_label = "holds fitness"

	line_value : Str
	line_value = "100 %"

	Bar : { w : Db.RampWeek, i : U64, cx : F32, box : Labels.Rect }

	# each week's bar on screen: its slot's centre and its body on the
	# shared scale, a 3px stub for a week with no share
	bars_of : List(Db.RampWeek), { w : F32, h : F32 } -> List(Bar)
	bars_of = |weeks, win| {
		n = List.len(weeks)
		bw = Weeks.bar_w(win.w, n)
		bot = Weeks.bars_bot(win.h)
		top = top_of(weeks)
		List.map_with_index(
			weeks,
			|w, i| {
				cx = Weeks.slot_cx(win.w, n, i)
				bh = F64.to_f32_wrap(ratio(w) * 100.0) / I64.to_f32(top) * plot_h(win.h)
				box = if (bh > 3.0) { x: cx - bw / 2.0, y: bot - bh, w: bw, h: bh } else { x: cx - bw / 2.0, y: bot - 3.0, w: bw, h: 3.0 }
				{ w, i, cx, box }
			},
		)
	}

	bars : Ui.Model -> List(Bar)
	bars = |model| bars_of(model.ramp_weeks, model.win)

	# a bar's chip, 54 wide over its slot's centre, 10 above its bar; a chip
	# that would touch the line at `ly` rises to sit clear above it
	chip_box : Bar, F32 -> Labels.Rect
	chip_box = |b, ly| {
		y0 = b.box.y - 30.0
		y = if (y0 + 20.0 > ly - line_gap and y0 < ly + line_gap) (ly - line_gap - 20.0) else y0
		{ x: b.cx - 27.0, y, w: 54.0, h: 20.0 }
	}

	newest : Ui.Model -> Db.RampWeek
	newest = |model| (List.last(model.ramp_weeks)) ?? blank

	blank : Db.RampWeek
	blank = { wk: "", days: 7, tss: 0, ctl10: 0, ramp10: 0, ctl_start: 0.0 }

	# ── every string the view writes, placed ───────────────────────────────
	scene : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	scene = |model, measure| Labels.place(texts(model, measure), obstacles(model, measure))

	# the view's text and the chrome's, as the gate judges them
	owned : Ui.Model, Scene.Measure -> List(Labels.Owned)
	owned = |model, measure| List.concat(Scene.owned(Chrome.placed(model, measure)), Scene.owned(scene(model, measure)))

	texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	texts = |model, measure| {
		win_w = model.win.w
		win_h = model.win.h
		panel = Labels.panel(model.win)
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		fix = |it, x, y, align, region| Scene.fixed(measure, it, { x, y, align }, region)
		head = [fix(Scene.prepared(model.ramp_title, title_text, 15.0, Prose, ink_muted), Weeks.title_x, 70.0, Left, panel)]
		chart =
			if !(charted(model)) {
				[fix(Scene.data("no load history yet", 14.0, ink_muted), pad, 130.0, Left, panel)]
			} else {
				# where fitness stands and how fast it is moving
				last = newest(model)
				card = Weeks.card_box(win_w)
				top = top_of(model.ramp_weeks)
				ly = line_y(win_h, top)
				bot = Weeks.bars_bot(win_h)
				axis = Weeks.plot_left - 6.0
				# each bar's chip, its date and load under it, and "so far"
				# over the running week's chip
				per_bar = List.join(
					List.map(
						bars(model),
						|b| {
							cb = chip_box(b, ly)
							List.join([
								[
									fix(Scene.data(Fmt.tenths_signed(b.w.ramp10), 11.0, verdict(b.w.ramp10)), b.cx, cb.y + 4.0, Center, cb),
									fix(Scene.data(Weeks.week_label(b.w.wk), 10.0, ink_faint), b.cx, Weeks.date_row(win_h), Center, panel),
									fix(Scene.data(Db.grouped(b.w.tss), 10.0, ink_faint), b.cx, Weeks.figure_row(win_h), Center, panel),
								],
								if (Weeks.partial(b.w.days)) [fix(Scene.data("so far", 10.0, ink_faint), b.cx, cb.y - 14.0, Center, panel)] else [],
							])
						},
					),
				)
				List.join([
					[
						fix(Scene.data(Fmt.tenths(last.ctl10), 28.0, Theme.ctl_c), card.x + 16.0, 68.0, Left, card),
						fix(Scene.data("ctl now", 11.0, ink_faint), card.x + 16.0, 102.0, Left, card),
						fix(Scene.data(Fmt.tenths_signed(last.ramp10), 28.0, verdict(last.ramp10)), win_w - pad - 16.0, 68.0, Right, card),
						fix(Scene.data(if (Weeks.partial(last.days)) "ctl per week so far" else "ctl per week", 11.0, ink_faint), win_w - pad - 16.0, 102.0, Right, card),
						# the scale, in the gutter: its top; the line's value
						# where it crosses, as the zones mode reads its 80 %,
						# with the line's name over it; and the base, which
						# gives way to the value when a tall scale sets the
						# line near the floor
						fix(Scene.data("${I64.to_str(top)} %", 10.0, ink_faint), axis, plot_top - 5.0, Right, panel),
						fix(Scene.data(line_label, 10.0, Color.white), axis, ly - 18.0, Right, panel),
						fix(Scene.data(line_value, 10.0, Color.white), axis, ly - 5.0, Right, panel),
						Scene.free(measure, Scene.data("0", 10.0, ink_faint), [{ x: axis, y: bot - 10.0, align: Right }], 1, panel),
					],
					Weeks.focus_texts(model, measure),
					List.map(key_row(measure), |k| fix(Scene.data(k.name, 10.0, ink_faint), k.text_x, 118.0, Left, panel)),
					per_bar,
				])
			}
		foot = [fix(Scene.prepared(model.ramp_hint, hint_text, 13.0, Prose, ink_faint), pad, win_h - 30.0, Left, panel)]
		List.join([head, chart, foot, Weeks.chip_texts(model, measure)])
	}

	obstacles : Ui.Model, Scene.Measure -> Labels.Obstacles
	obstacles = |model, measure| { boxes: List.concat(Chrome.boxes(model, measure), List.map(marks(model, measure), |m| m.box)), segs: [] }

	# the shapes no text may cover but its own: the pills, the mode chips,
	# the card, the key's swatches, the line, and every bar and chip
	marks : Ui.Model, Scene.Measure -> List(Labels.Mark)
	marks = |model, measure|
		if charted(model) {
			top = top_of(model.ramp_weeks)
			ly = line_y(model.win.h, top)
			List.join([
				Chrome.marks(model),
				Weeks.chip_marks,
				[{ key: "the ctl card", box: Weeks.card_box(model.win.w) }, { key: "the holds-fitness line", box: line_box(model.win, top) }],
				List.map(key_row(measure), |k| { key: "the ${k.name} swatch", box: k.swatch }),
				List.join(List.map(bars(model), |b| [{ key: "the ${b.w.wk} bar", box: b.box }, { key: "the ${b.w.wk} chip", box: chip_box(b, ly) }])),
			])
		} else {
			List.concat(Chrome.marks(model), Weeks.chip_marks)
		}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		ink_faint = Theme.ink_faint
		measure = Scene.measure_of(model)
		if charted(model) {
			win_w = model.win.w
			bot = Weeks.bars_bot(model.win.h)
			card = Weeks.card_box(win_w)
			top = top_of(model.ramp_weeks)
			ly = line_y(model.win.h, top)
			frame.rounded_rectangle!({ x: card.x, y: card.y, width: card.w, height: card.h, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
			frame.line!({ start: { x: Weeks.plot_left, y: bot }, end: { x: win_w - pad, y: bot }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 70), 1) })
			List.for_each!(key_row(measure), |k| frame.rounded_rectangle!({ x: k.swatch.x, y: k.swatch.y, width: k.swatch.w, height: k.swatch.h, radius: 2.0, segments: 3, style: Draw.filled(k.color) }))
			focus = Weeks.focus_week(model)
			List.for_each!(
				bars(model),
				|b| {
					vc = verdict(b.w.ramp10)
					hovered = b.w.wk == focus
					if b.box.h > 3.0 {
						frame.rounded_rectangle!({ x: b.box.x, y: b.box.y, width: b.box.w, height: b.box.h, radius: 7.0, segments: 5, style: Draw.filled(Color.with_alpha(vc, bar_alpha(hovered, b.w.days))) })
						# depth: the bar darkens toward its base, below the rounded cap
						frame.rectangle_gradient_v!({ x: b.box.x, y: b.box.y + 8.0, width: b.box.w, height: b.box.h - 8.0, color_top: Color.with_alpha(Theme.bg, 0), color_bottom: Color.with_alpha(Theme.bg, 120) })
					} else {
						frame.rounded_rectangle!({ x: b.box.x, y: b.box.y, width: b.box.w, height: b.box.h, radius: 1.5, segments: 3, style: Draw.filled(Color.with_alpha(ink_faint, 90)) })
					}
					cb = chip_box(b, ly)
					frame.rounded_rectangle!({ x: cb.x, y: cb.y, width: cb.w, height: cb.h, radius: 6.0, segments: 5, style: Draw.filled(Color.with_alpha(vc, if (hovered) (70.U8) else 42)) })
				},
			)
			# the holds-fitness line over every bar
			l = line_box(model.win, top)
			frame.rectangle!({ x: l.x, y: l.y, width: l.w, height: l.h, style: Draw.filled(Color.with_alpha(Color.white, 220)) })
		}
		Scene.draw!(frame, model, scene(model, measure))
		Ok({})
	}

	# twelve Monday weeks of a real athlete's weekly_ramp rows, the newest
	# three days into its week
	real_weeks : List(Db.RampWeek)
	real_weeks = [
		{ wk: "2026-09-07", days: 7, tss: 334, ctl10: 431, ramp10: 9, ctl_start: 42.2724 },
		{ wk: "2026-09-14", days: 7, tss: 380, ctl10: 448, ramp10: 16, ctl_start: 43.1382 },
		{ wk: "2026-09-21", days: 7, tss: 477, ctl10: 484, ramp10: 36, ctl_start: 44.7666 },
		{ wk: "2026-09-28", days: 7, tss: 406, ctl10: 499, ramp10: 15, ctl_start: 48.4049 },
		{ wk: "2026-10-05", days: 7, tss: 307, ctl10: 490, ramp10: -9, ctl_start: 49.8703 },
		{ wk: "2026-10-12", days: 7, tss: 332, ctl10: 484, ramp10: -5, ctl_start: 48.9521 },
		{ wk: "2026-10-19", days: 7, tss: 433, ctl10: 505, ramp10: 21, ctl_start: 48.4228 },
		{ wk: "2026-10-26", days: 7, tss: 267, ctl10: 485, ramp10: -19, ctl_start: 50.4814 },
		{ wk: "2026-11-02", days: 7, tss: 393, ctl10: 497, ramp10: 12, ctl_start: 48.5465 },
		{ wk: "2026-11-09", days: 7, tss: 531, ctl10: 538, ramp10: 40, ctl_start: 49.7299 },
		{ wk: "2026-11-16", days: 7, tss: 278, ctl10: 516, ramp10: -22, ctl_start: 53.7752 },
		{ wk: "2026-11-23", days: 3, tss: 275, ctl10: 543, ramp10: 27, ctl_start: 51.6078 },
	]
}

# a week past the limit is red, one that gained less is blue, and a flat
# week or one that lost fitness is muted; a week still running is judged
# the same way and drawn faded
expect Ramp.ramp_limit == 6
expect Ramp.verdict(61) == Theme.alarm_c and Ramp.verdict(60) == Theme.ctl_c and Ramp.verdict(1) == Theme.ctl_c
expect Ramp.verdict(0) == Theme.ink_muted and Ramp.verdict(-19) == Theme.ink_muted
expect Ramp.bar_alpha(False, 3) < Ramp.bar_alpha(False, 7) and Ramp.bar_alpha(True, 3) == Ramp.bar_alpha(True, 7)
# the key's swatches are the verdict's three colors, the red one named for
# the limit
expect List.map(Ramp.classes, |c| c.name) == ["loses fitness", "builds fitness", "past +6 ctl a week"] and List.map(Ramp.classes, |c| c.color) == [Theme.ink_muted, Theme.ctl_c, Theme.alarm_c]

# a week's bar is its load over its hold: 531 load from CTL 49.73 over
# seven days is 153% of its 348 hold; the running week's 275 over three
# days from CTL 51.61 is 178% of its 155
expect {
	nov9 = (List.get(Ramp.real_weeks, 9)) ?? Ramp.blank
	run = (List.last(Ramp.real_weeks)) ?? Ramp.blank
	Ramp.pct(nov9) == 153 and (Ramp.hold(nov9) - 348.109).abs() < 0.001 and Ramp.pct(run) == 178 and (Ramp.hold(run) - 154.823).abs() < 0.001
}

# on the screen, every real week whose chip reads a gain stands over the
# line and every one whose chip reads a loss stands under it, the running
# week included; every bar stands at its share of its hold on the one
# scale, and the line sits at 100%
expect {
	win = { w: 980.0, h: 600.0 }
	top = Ramp.top_of(Ramp.real_weeks)
	ly = Ramp.line_y(win.h, top)
	bs = Ramp.bars_of(Ramp.real_weeks, win)
	at_hold = |b| (Weeks.bars_bot(win.h) - Ramp.plot_h(win.h) * F64.to_f32_wrap(Ramp.ratio(b.w)) * 100.0 / I64.to_f32(top) - b.box.y).abs() < 0.01
	List.len(bs) == 12
		and List.all(bs, |b| b.w.ramp10 == 0 or (b.w.ramp10 > 0) == (b.box.y < ly))
		and List.all(bs, at_hold)
		and ((Ramp.line_box(win, top)).y + 1.0 - ly).abs() < 0.01
}

# the scale fits the tallest bar, the running week's included: the real
# running week reads 178%, over every finished week's 153% at most, so the
# scale tops at 180% and every bar stands whole under it; a running week
# two days in at 198% lifts the top to 200%, and its bar is the tallest
expect {
	win = { w: 980.0, h: 600.0 }
	bs = Ramp.bars_of(Ramp.real_weeks, win)
	early = List.append(List.drop_last(Ramp.real_weeks, 1), { wk: "2026-11-23", days: 2, tss: 204, ctl10: 540, ramp10: 24, ctl_start: 51.6078 })
	es = Ramp.bars_of(early, win)
	whole = |b| b.box.y >= Ramp.plot_top - 0.01
	tallest = |xs| match List.last(xs) {
		Ok(run) => List.all(xs, |b| run.box.y <= b.box.y)
		Err(_) => Bool.False
	}
	Ramp.top_of(Ramp.real_weeks) == 180
		and List.all(bs, whole)
		and tallest(bs)
		and Ramp.top_of(early) == 200
		and List.all(es, whole)
		and tallest(es)
}

# the top rounds up from the unrounded share: a finished week at 150.29%
# of its hold tops the scale at 160%, one at 120.29% at 130%, each bar
# whole and at its share; weeks all under their holds keep the top at 120%
expect {
	win = { w: 980.0, h: 600.0 }
	at = |tss| { wk: "2026-11-16", days: 7, tss, ctl10: 520, ramp10: 20, ctl_start: 50.0 }
	shown = |w, top| List.all(Ramp.bars_of([w], win), |b| b.box.y >= Ramp.plot_top - 0.01 and (Weeks.bars_bot(win.h) - b.box.y - Ramp.plot_h(win.h) * F64.to_f32_wrap(Ramp.ratio(w)) * 100.0 / I64.to_f32(top)).abs() < 0.01)
	(Ramp.ratio(at(526)) * 100.0 - 150.2857).abs() < 0.001
		and Ramp.top_of([at(526)]) == 160
		and shown(at(526), 160)
		and Ramp.top_of([at(421)]) == 130
		and shown(at(421), 130)
		and Ramp.top_of([at(100)]) == 120
}

# a new athlete's second week, far over its tiny hold, sets a tall scale
# and stands whole at its top; the weeks beside it stand low under it
expect {
	second = { wk: "2026-11-09", days: 7, tss: 160, ctl10: 40, ramp10: 19, ctl_start: 2.07 }
	third = { wk: "2026-11-16", days: 7, tss: 120, ctl10: 60, ramp10: 20, ctl_start: 4.0 }
	bs = Ramp.bars_of([second, third], { w: 980.0, h: 600.0 })
	Ramp.top_of([second, third]) == 1110 and List.all(bs, |b| b.box.y >= Ramp.plot_top - 0.01)
}

# a chip never touches the line: beside a finished week at 160% of its
# hold, a finished week carrying anything up to that and a running week
# carrying up to eight times its hold, which lifts the scale, each keep
# their chip clear of the line by the gap, above the bar, and inside the
# band
expect {
	win = { w: 980.0, h: 600.0 }
	tall = { ..Ramp.blank, wk: "2026-09-28", ctl_start: 50.0, tss: 560 }
	clear = |k, days| {
		w = { wk: "2026-11-16", days, tss: U64.to_i64_wrap(k) * 5, ctl10: 500, ramp10: 1, ctl_start: 50.0 }
		ly = Ramp.line_y(win.h, Ramp.top_of([tall, w]))
		bs = Ramp.bars_of([tall, w], win)
		List.all(
			bs,
			|b| {
				c = Ramp.chip_box(b, ly)
				(c.y + c.h <= ly - Ramp.line_gap + 0.001 or c.y >= ly + Ramp.line_gap - 0.001)
					and c.y + c.h <= b.box.y + 0.001
					and c.y >= Weeks.bars_top - 16.0
			},
		)
	}
	List.all(List.map_with_index(List.repeat(0, 113), |_, k| clear(k, 7)), |ok| ok) and List.all(List.map_with_index(List.repeat(0, 321), |_, k| clear(k, 4)), |ok| ok)
}

# a new athlete's first week, whose history starts mid-week, started from
# zero CTL whatever end-of-week CTL and ramp the view reports for it, so it
# has no hold, keeps a stub and leaves the scale alone; a later week reads
# its start as its end less its ramp
expect {
	first = { wk: "2026-11-02", days: 7, tss: 160, ctl10: 21, ramp10: 0, ctl_start: Db.week_start_ctl(Bool.True, 2.07, 0.0) }
	bs = Ramp.bars_of([first], { w: 980.0, h: 600.0 })
	!(Ramp.held(first)) and Ramp.top_of([first]) == 120 and List.all(bs, |b| (b.box.h - 3.0).abs() < 0.001) and (Db.week_start_ctl(Bool.False, 51.61, -2.17) - 53.78).abs() < 0.001
}
