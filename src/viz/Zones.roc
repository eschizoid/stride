import rr.Color
import rr.Draw
import Chrome
import Db
import Labels
import Scene
import Theme
import Ui
import Weeks

Zones :: [].{
	# The weeks tab's zones mode: twelve Monday weeks of the polarized split
	# as stacked bars, easy at the base, then moderate, then hard. The bar is
	# drawn from the population and measure its cap reads (the sessions the
	# activity_intensity view marks `polarized`, classified by power or pace
	# when a session has it and by heart rate otherwise), so the cap's easy
	# share is the easy segment's share of its bar. A mark at 80% of each
	# bar's height is the 80/20 line: an easy segment that reaches it holds
	# the line, and the cap says so in teal; one that falls short breaks it,
	# in alarm. A week with no polarized time draws no segments and no cap.
	# The current week, until the series covers all seven of its days, is
	# judged by neither: its bar and cap are muted and the cap says "so far",
	# since a partial week is not a finished one. Heart-rate zone time stays
	# in the week's focus line.

	pad : F32
	pad = 36.0

	# the polarized-training floor: the easy share a full week must reach
	easy_floor : I64
	easy_floor = 80

	# absence is not a failed verdict, and neither is a week still running:
	# both read muted, never in the color that means "you broke the rule"
	verdict : I64, I64, I64 -> Color.Rgba
	verdict = |easy, itot, days|
		if (itot <= 0 or Weeks.partial(days)) (Theme.ink_muted)
		else if (easy * 100 // itot >= easy_floor) (Theme.tsb_c)
		else Theme.alarm_c

	hours : I64 -> Str
	hours = |secs| {
		h10 = secs * 10 // 3600
		"${Db.grouped(h10 // 10)}.${I64.to_str(h10 % 10)} h"
	}

	zones_note : List(Str) -> Str
	zones_note = |overrides|
		if (List.is_empty(overrides)) "one set of HR zones for every sport"
		else "own HR zones: ${Str.join_with(overrides, ", ")}; every other sport uses the global zones"

	# a week's heart-rate zone hours, z1 to z5: the detail the bar leaves out
	hr_line : Db.ZoneWeek -> Str
	hr_line = |w|
		if (w.z1 + w.z2 + w.z3 + w.z4 + w.z5 <= 0) "no heart-rate zone time"
		else "hr zones z1-z5: ${Str.join_with(List.map([w.z1, w.z2, w.z3, w.z4, w.z5], Weeks.tenths_of_hour), "  ")} h"

	# the key row's note: the focused week's zone hours, else the zones note
	row_note : Ui.Model -> Str
	row_note = |model| {
		wk = Weeks.focus_week(model)
		match List.first(List.keep_if(model.zone_weeks, |w| w.wk == wk)) {
			Ok(w) => hr_line(w)
			Err(_) => zones_note(model.zone_overrides)
		}
	}

	title_text : Str
	title_text = "easy, moderate and hard, and the 80/20 split"

	hint_text : Str
	hint_text = "zones / load  modes      hover or click a week      TAB  career      R  reload      S  screenshot      V  record      ESC quit"

	key_text : Str
	key_text = "caps: easy share     teal holds 80/20     red breaks it     tick: 80% of the bar     muted: still running"

	# the three classes the bar stacks, base first, each with its color
	classes : List({ name : Str, color : Color.Rgba })
	classes = [
		{ name: "easy", color: (List.get(Theme.zone_ramp, 1)) ?? Theme.ctl_c },
		{ name: "moderate", color: (List.get(Theme.zone_ramp, 3)) ?? Theme.ink_muted },
		{ name: "hard", color: (List.get(Theme.zone_ramp, 4)) ?? Theme.alarm_c },
	]

	# the seconds a week's bar and cap both count
	split_s : Db.ZoneWeek -> I64
	split_s = |w| w.easy + w.moderate + w.hard

	# the chart draws once any week holds polarized time
	charted : Ui.Model -> Bool
	charted = |model| List.any(model.zone_weeks, |w| split_s(w) > 0)

	# each class's height on a bar `h` tall at the tallest week's `peak`
	# seconds: easy, moderate and hard, base first
	segments : Db.ZoneWeek, I64, F32 -> List(F32)
	segments = |w, peak, h| List.map([w.easy, w.moderate, w.hard], |s| I64.to_f32(s) / I64.to_f32(peak) * h)

	# the 80/20 mark's height above the base on a bar `bh` tall
	mark_h : F32 -> F32
	mark_h = |bh| bh * I64.to_f32(easy_floor) / 100.0

	Bar : { w : Db.ZoneWeek, i : U64, cx : F32, top : F32, bh : F32, box : Labels.Rect }

	# each week's bar on screen: its slot's centre, its top-left corner and
	# size, scaled to the week with the most polarized time
	bars_of : List(Db.ZoneWeek), { w : F32, h : F32 } -> List(Bar)
	bars_of = |weeks, win| {
		n = List.len(weeks)
		slot = (win.w - pad * 2.0) / U64.to_f32(n)
		bw = F32.min(74.0, slot * 0.60)
		bot = Weeks.bars_bot(win.h)
		peak = peak_of(weeks)
		List.map_with_index(
			weeks,
			|w, i| {
				cx = pad + (U64.to_f32(i) + 0.5) * slot
				bh = I64.to_f32(split_s(w)) / I64.to_f32(peak) * (bot - Weeks.bars_top)
				{ w, i, cx, top: bot - bh, bh, box: { x: cx - bw / 2.0, y: bot - F32.max(bh, 3.0), w: bw, h: F32.max(bh, 3.0) } }
			},
		)
	}

	bars : Ui.Model -> List(Bar)
	bars = |model| bars_of(model.zone_weeks, model.win)

	peak_of : List(Db.ZoneWeek) -> I64
	peak_of = |weeks| List.fold(weeks, 1.I64, |a, w| if (split_s(w) > a) split_s(w) else a)

	# the 80/20 mark across a bar, a little wider than the bar
	mark_box : Bar -> Labels.Rect
	mark_box = |b| { x: b.box.x - 5.0, y: b.top + b.bh - mark_h(b.bh) - 1.0, w: b.box.w + 10.0, h: 2.0 }

	# the week the verdict card reads: the newest with polarized time
	newest : Ui.Model -> Db.ZoneWeek
	newest = |model| List.fold(model.zone_weeks, { wk: "", days: 7, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0, easy: 0, moderate: 0, hard: 0 }, |acc, w| if (split_s(w) > 0) (w) else acc)

	# the class key on its own row clear of every cap: each swatch, and its
	# name 13px right of it, the next swatch 14px past the name's end
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

	# where the key row's text ends, for the zones note that follows it
	key_end : Scene.Measure -> F32
	key_end = |measure| List.fold(key_row(measure), pad, |_, k| k.text_x + measure(k.name, 10.0, Data))

	# ── every string the view writes, placed ───────────────────────────────
	# Fixed text but the scale's top value, which a tall first week's cap
	# may cover: it drops then, and the focus line reads any week's hours.
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
		head = [fix(Scene.prepared(model.zones_title, title_text, 15.0, Prose, ink_muted), Weeks.title_x, 70.0, Left, panel)]
		chart =
			if !(charted(model)) {
				[fix(Scene.data("no polarized time yet", 14.0, ink_muted), pad, 130.0, Left, panel)]
			} else {
				# this week's verdict, in the form board's KPI card style
				last = newest(model)
				li = split_s(last)
				lc = verdict(last.easy, li, last.days)
				card = Weeks.card_box(win_w)
				wk_lbl = if (last.wk == "") ("no training yet") else if (Weeks.partial(last.days)) "easy so far, wk of ${Weeks.week_label(last.wk)}" else "easy, wk of ${Weeks.week_label(last.wk)}"
				peak = peak_of(model.zone_weeks)
				bot = Weeks.bars_bot(win_h)
				per_bar = List.join(
					List.map(
						bars(model),
						|b| {
							bt = split_s(b.w)
							cap =
								if bt > 0 {
									cb = Weeks.cap_box(b.cx, b.top)
									vc = verdict(b.w.easy, bt, b.w.days)
									List.concat(
										[fix(Scene.data("${I64.to_str(b.w.easy * 100 // bt)}%", 11.0, vc), b.cx, cb.y + 4.0, Center, cb)],
										if (Weeks.partial(b.w.days)) [fix(Scene.data("so far", 10.0, ink_faint), b.cx, cb.y - 14.0, Center, panel)] else [],
									)
								} else {
									[]
								}
							List.concat(cap, if (b.i % 2 == 0) [fix(Scene.data(Weeks.week_label(b.w.wk), 10.0, ink_faint), b.cx, bot + 10.0, Center, panel)] else [])
						},
					),
				)
				List.join([
					[
						fix(Scene.data(if (li > 0) ("${I64.to_str(last.easy * 100 // li)}%") else "-", 28.0, lc), card.x + 16.0, 68.0, Left, card),
						fix(Scene.data(wk_lbl, 11.0, ink_faint), card.x + 16.0, 102.0, Left, card),
						fix(Scene.data(hours(li), 28.0, Theme.ctl_c), win_w - pad - 16.0, 68.0, Right, card),
						fix(Scene.data("in the split", 11.0, ink_faint), win_w - pad - 16.0, 102.0, Right, card),
						Scene.free(measure, Scene.data(hours(peak), 10.0, ink_faint), [{ x: pad, y: Weeks.bars_top - 14.0, align: Left }], 1, panel),
						fix(Scene.data("0", 10.0, ink_faint), pad, bot - 12.0, Left, panel),
						Weeks.focus_text(model, measure, key_text),
						# the focused week's heart-rate zone hours, else which
						# zones classify a session with no power or pace: beside
						# the class key, or under the week labels when a long list
						# of sports would run under the card. A sport without its
						# own bounds is classified by the global ones, so a
						# swimmer's lower heart rate can read as easier than it is
						Scene.kept(measure, Scene.data(row_note(model), 10.0, ink_faint), [{ x: key_end(measure) + 16.0, y: 118.0, align: Left }, { x: pad, y: bot + 28.0, align: Left }], 2, panel),
					],
					List.map(key_row(measure), |k| fix(Scene.data(k.name, 10.0, ink_faint), k.text_x, 118.0, Left, panel)),
					per_bar,
				])
			}
		foot = [fix(Scene.prepared(model.zones_hint, hint_text, 13.0, Prose, ink_faint), pad, win_h - 30.0, Left, panel)]
		List.join([head, chart, foot, Weeks.chip_texts(model, measure)])
	}

	# what the scale's top value keeps off: the chrome, the card, the bars
	# and their caps
	obstacles : Ui.Model, Scene.Measure -> Labels.Obstacles
	obstacles = |model, measure| { boxes: List.concat(Chrome.boxes(model, measure), List.map(marks(model, measure), |m| m.box)), segs: [] }

	# the shapes no text may cover but its own: the pills, the mode chips,
	# the card, the class key's swatches, and every bar, 80/20 mark and cap
	marks : Ui.Model, Scene.Measure -> List(Labels.Mark)
	marks = |model, measure|
		if charted(model) {
			List.join([
				Chrome.marks(model),
				Weeks.chip_marks,
				[{ key: "the verdict card", box: Weeks.card_box(model.win.w) }],
				List.map(key_row(measure), |k| { key: "the ${k.name} swatch", box: k.swatch }),
				List.join(
					List.map(
						bars(model),
						|b| List.concat(
							[{ key: "the ${b.w.wk} bar", box: b.box }],
							if (split_s(b.w) > 0) [{ key: "the ${b.w.wk} cap", box: Weeks.cap_box(b.cx, b.top) }, { key: "the ${b.w.wk} 80/20 mark", box: mark_box(b) }] else [],
						),
					),
				),
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
			bars_h = bot - Weeks.bars_top
			peak = peak_of(model.zone_weeks)
			card = Weeks.card_box(win_w)
			frame.rounded_rectangle!({ x: card.x, y: card.y, width: card.w, height: card.h, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
			frame.line!({ start: { x: pad, y: bot }, end: { x: win_w - pad, y: bot }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 70), 1) })
			# the class key rides its own row, clear of every cap
			List.for_each!(key_row(measure), |k| frame.rounded_rectangle!({ x: k.swatch.x, y: k.swatch.y, width: k.swatch.w, height: k.swatch.h, radius: 2.0, segments: 3, style: Draw.filled(k.color) }))
			focus = Weeks.focus_week(model)
			List.for_each!(
				bars(model),
				|b| {
					x0 = b.box.x
					bw = b.box.w
					bt = split_s(b.w)
					hovered = b.w.wk == focus
					# easy at the base, hard on top, a hairline of ground between each
					_ = List.fold_try!(
						List.map2(segments(b.w, peak, bars_h), classes, |seg, c| { seg, c }),
						0.0,
						|yacc, s| {
							if s.seg > 1.5 {
								frame.rectangle!({ x: x0, y: bot - yacc - s.seg, width: bw, height: s.seg - 1.0, style: Draw.filled(Color.with_alpha(s.c.color, if (hovered) (255.U8) else if (Weeks.partial(b.w.days)) 120 else 235)) })
							}
							Ok(yacc + s.seg)
						},
					)
					# depth over the whole stack, so the bars sit in the panel
					if b.bh > 8.0 {
						frame.rectangle_gradient_v!({ x: x0, y: b.top, width: bw, height: b.bh, color_top: Color.with_alpha(Theme.bg, 0), color_bottom: Color.with_alpha(Theme.bg, 90) })
					}
					if (b.bh > 3.0) {} else {
						frame.rounded_rectangle!({ x: x0, y: bot - 3.0, width: bw, height: 3.0, radius: 1.5, segments: 3, style: Draw.filled(Color.with_alpha(ink_faint, 90)) })
					}
					if bt > 0 {
						# the 80/20 mark, then the cap: this week's easy share,
						# in its verdict color
						m = mark_box(b)
						frame.rectangle!({ x: m.x, y: m.y, width: m.w, height: m.h, style: Draw.filled(Color.with_alpha(Color.white, if (Weeks.partial(b.w.days)) (150.U8) else 220)) })
						cb = Weeks.cap_box(b.cx, b.top)
						vc = verdict(b.w.easy, bt, b.w.days)
						frame.rounded_rectangle!({ x: cb.x, y: cb.y, width: cb.w, height: cb.h, radius: 6.0, segments: 5, style: Draw.filled(Color.with_alpha(vc, if (hovered) (70.U8) else 42)) })
					}
				},
			)
		}
		Scene.draw!(frame, model, scene(model, measure))
		Ok({})
	}

	# twelve Monday weeks of a real athlete's zone and polarized seconds, the
	# newest three days into its week. In the first, a ride and a Power Zone
	# class are hard by power while heart rate stayed in Z2, and a lifting
	# session counts zone time but no polarized time.
	real_weeks : List(Db.ZoneWeek)
	real_weeks = [
		{ wk: "2026-09-07", days: 7, z1: 6494, z2: 10744, z3: 1964, z4: 796, z5: 1084, easy: 11577, moderate: 2272, hard: 4026 },
		{ wk: "2026-09-14", days: 7, z1: 4486, z2: 6593, z3: 6970, z4: 1657, z5: 487, easy: 6436, moderate: 4281, hard: 6689 },
		{ wk: "2026-09-21", days: 7, z1: 10259, z2: 16515, z3: 4077, z4: 1058, z5: 0, easy: 19702, moderate: 4610, hard: 4176 },
		{ wk: "2026-09-28", days: 7, z1: 13406, z2: 7900, z3: 1709, z4: 3579, z5: 625, easy: 15588, moderate: 3923, hard: 4580 },
		{ wk: "2026-10-05", days: 7, z1: 9391, z2: 8810, z3: 714, z4: 146, z5: 0, easy: 14969, moderate: 3575, hard: 504 },
		{ wk: "2026-10-12", days: 7, z1: 8371, z2: 10767, z3: 2022, z4: 1065, z5: 102, easy: 10532, moderate: 2667, hard: 2487 },
		{ wk: "2026-10-19", days: 7, z1: 14204, z2: 8179, z3: 3980, z4: 3761, z5: 0, easy: 17105, moderate: 4528, hard: 4920 },
		{ wk: "2026-10-26", days: 7, z1: 4818, z2: 3228, z3: 1851, z4: 1715, z5: 184, easy: 4093, moderate: 1327, hard: 3030 },
		{ wk: "2026-11-02", days: 7, z1: 13188, z2: 8494, z3: 2785, z4: 1554, z5: 0, easy: 16529, moderate: 6848, hard: 2601 },
		{ wk: "2026-11-09", days: 7, z1: 15365, z2: 18176, z3: 1550, z4: 1719, z5: 1169, easy: 19980, moderate: 7315, hard: 3155 },
		{ wk: "2026-11-16", days: 7, z1: 8460, z2: 5513, z3: 1696, z4: 1029, z5: 0, easy: 10218, moderate: 2496, hard: 3894 },
		{ wk: "2026-11-23", days: 3, z1: 7553, z2: 16616, z3: 341, z4: 14, z5: 0, easy: 20061, moderate: 4153, hard: 254 },
	]
}

# a full week at the floor holds 80/20, one point under breaks it, and a
# week still running is muted whatever its share
expect Zones.easy_floor == 80
expect Zones.verdict(80, 100, 7) == Theme.tsb_c
expect Zones.verdict(79, 100, 7) == Theme.alarm_c
expect Zones.verdict(39, 100, 3) == Theme.ink_muted
expect Zones.verdict(95, 100, 6) == Theme.ink_muted
expect Zones.verdict(0, 0, 7) == Theme.ink_muted

# every sport on the global zones says so; per-sport bounds are named
expect Zones.zones_note([]) == "one set of HR zones for every sport"
expect Zones.zones_note(["ride", "swim"]) == "own HR zones: ride, swim; every other sport uses the global zones"

# on every real week the cap's percentage is the easy segment's share of
# its bar, and the segments stack to the bar's height
expect {
	bs = Zones.bars_of(Zones.real_weeks, { w: 980.0, h: 600.0 })
	peak = Zones.peak_of(Zones.real_weeks)
	List.len(bs) == 12
		and List.all(
			bs,
			|b| {
				segs = Zones.segments(b.w, peak, Weeks.bars_bot(600.0) - Weeks.bars_top)
				easy_h = (List.first(segs)) ?? 0.0
				stack = List.fold(segs, 0.0, |a, s| a + s)
				cap = b.w.easy * 100 // Zones.split_s(b.w)
				share = easy_h / b.bh * 100.0
				(stack - b.bh).abs() < 0.01 and share >= I64.to_f32(cap) and share < I64.to_f32(cap + 1)
			},
		)
}

# the first real week reads about 82% easy by heart rate and 64% by the
# split; the bar and its cap now both read the split
expect {
	w = (List.first(Zones.real_weeks)) ?? { wk: "", days: 7, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0, easy: 0, moderate: 0, hard: 0 }
	by_hr = (w.z1 + w.z2) * 100 // (w.z1 + w.z2 + w.z3 + w.z4 + w.z5)
	b = (List.first(Zones.bars_of(Zones.real_weeks, { w: 980.0, h: 600.0 }))) ?? { w, i: 0, cx: 0.0, top: 0.0, bh: 0.0, box: { x: 0.0, y: 0.0, w: 0.0, h: 0.0 } }
	easy_h = (List.first(Zones.segments(w, Zones.peak_of(Zones.real_weeks), Weeks.bars_bot(600.0) - Weeks.bars_top))) ?? 0.0
	by_hr == 81 and w.easy * 100 // Zones.split_s(w) == 64 and (easy_h / b.bh * 100.0 - 64.77).abs() < 0.05
}

# the 80/20 mark is the verdict drawn: on every real finished week, none of
# which holds the line, and on a week that does, the easy segment reaches
# the mark exactly when the cap is teal
expect {
	held = { wk: "2026-11-30", days: 7, z1: 3600, z2: 28800, z3: 1800, z4: 1800, z5: 0, easy: 29000, moderate: 3500, hard: 3500 }
	weeks = List.append(Zones.real_weeks, held)
	peak = Zones.peak_of(weeks)
	h = Weeks.bars_bot(600.0) - Weeks.bars_top
	bs = Zones.bars_of(weeks, { w: 980.0, h: 600.0 })
	finished = List.keep_if(bs, |b| !(Weeks.partial(b.w.days)))
	reaches = |b| ((List.first(Zones.segments(b.w, peak, h))) ?? 0.0) >= Zones.mark_h(b.bh)
	teal = |b| Zones.verdict(b.w.easy, Zones.split_s(b.w), 7) == Theme.tsb_c
	List.len(finished) == 12
		and List.any(finished, teal)
		and List.any(finished, |b| !(teal(b)))
		and List.all(finished, |b| reaches(b) == teal(b))
		and List.all(bs, |b| ((Zones.mark_box(b)).y + 1.0 - (Weeks.bars_bot(600.0) - Zones.mark_h(b.bh))).abs() < 0.01)
}

# a week with zone time but no polarized time, a lifting week, draws no
# segment and earns no verdict
expect {
	lift = { wk: "2026-11-16", days: 7, z1: 1800, z2: 1200, z3: 0, z4: 0, z5: 0, easy: 0, moderate: 0, hard: 0 }
	ride = { wk: "2026-11-23", days: 7, z1: 600, z2: 3000, z3: 0, z4: 0, z5: 0, easy: 3600, moderate: 0, hard: 0 }
	bs = Zones.bars_of([lift, ride], { w: 980.0, h: 600.0 })
	segs = Zones.segments(lift, Zones.peak_of([lift, ride]), 300.0)
	List.all(segs, |s| s.abs() < 0.001) and ((List.first(bs)) ?? { w: lift, i: 0, cx: 0.0, top: 0.0, bh: 1.0, box: { x: 0.0, y: 0.0, w: 0.0, h: 0.0 } }).bh.abs() < 0.001 and Zones.verdict(lift.easy, Zones.split_s(lift), 7) == Theme.ink_muted
}

# the focus row reads a week's heart-rate zone hours, and says so when a
# week holds none
expect {
	w = (List.first(Zones.real_weeks)) ?? { wk: "", days: 7, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0, easy: 0, moderate: 0, hard: 0 }
	Zones.hr_line(w) == "hr zones z1-z5: 1.8  2.9  0.5  0.2  0.3 h" and Zones.hr_line({ ..w, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0 }) == "no heart-rate zone time"
}
