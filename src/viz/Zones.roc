import rr.Color
import rr.Draw
import Chrome
import core.Fmt
import Db
import Labels
import Scene
import Theme
import Ui
import Weeks

Zones :: [].{
	# The weeks tab's zones mode: twelve Monday weeks of the polarized split
	# as share bars. Every bar with polarized time stands the full height of
	# the plot, its whole being 100% of that week's polarized time, stacked
	# easy at the base, then moderate, then hard. The split counts the
	# sessions the activity_intensity view marks `polarized`, classified by
	# power or pace when a session has it and by heart rate otherwise, so a
	# lifting session adds nothing. One white line crosses the plot at 80%:
	# an easy segment that reaches it holds the 80/20 split. Under each bar
	# its date, then its hours of polarized time; a week with none keeps an
	# empty stub. The card reads the newest week with polarized time as easy
	# against everything else, 81/19, in the verdict's color. The current
	# week, until the series covers all seven of its days, is judged by
	# neither: its bar is faded, "so far" sits over it, and the card reads it
	# muted. Heart-rate zone time stays in the key row's note for the week in
	# focus.

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

	# the card's reading of a week: its easy share against the rest of its
	# split, whole percents through core Fmt.shares, the rule `stride
	# review` and `stride summary` print the same split with: the easy share
	# floored as the verdict floors it, so 79.9% never reads 80 in the color
	# that means short of 80, and the two sum to 100; a dash for a week with
	# no polarized time
	tile : Db.ZoneWeek -> { value : Str, label : Str, color : Color.Rgba }
	tile = |w| {
		itot = split_s(w)
		if itot <= 0 {
			{ value: "-", label: "no polarized time", color: Theme.ink_muted }
		} else {
			e = (Fmt.shares(w.easy, w.moderate, w.hard)).easy
			{ value: "${I64.to_str(e)}/${I64.to_str(100 - e)}", label: "easy / harder, wk of ${Weeks.week_label(w.wk)}", color: verdict(w.easy, itot, w.days) }
		}
	}

	hours : I64 -> Str
	hours = Weeks.hours

	# a week's heart-rate zone hours, z1 to z5: the detail the bar leaves out
	hr_line : Db.ZoneWeek -> Str
	hr_line = |w|
		if (w.z1 + w.z2 + w.z3 + w.z4 + w.z5 <= 0) "no heart-rate zone time"
		else "hr zones z1-z5: ${Str.join_with(List.map([w.z1, w.z2, w.z3, w.z4, w.z5], Weeks.tenths_of_hour), "  ")} h"

	# the key row's note: the focused week's zone hours, or nothing with no
	# week in focus
	row_note : Ui.Model -> List(Str)
	row_note = |model| {
		wk = Weeks.focus_week(model)
		List.map(List.keep_if(model.zone_weeks, |w| w.wk == wk and wk != ""), hr_line)
	}

	title_text : Str
	title_text = "easy, moderate and hard, and the 80/20 split"

	hint_text : Str
	hint_text = "zones / load  modes      hover or click a week      TAB  career      R  reload      S  screenshot      V  record      ESC quit"

	# the three classes the bar stacks, base first, each with its color
	classes : List({ name : Str, color : Color.Rgba })
	classes = [
		{ name: "easy", color: (List.get(Theme.zone_ramp, 1)) ?? Theme.ctl_c },
		{ name: "moderate", color: (List.get(Theme.zone_ramp, 3)) ?? Theme.ink_muted },
		{ name: "hard", color: (List.get(Theme.zone_ramp, 4)) ?? Theme.alarm_c },
	]

	# the seconds a week's bar and card both count
	split_s : Db.ZoneWeek -> I64
	split_s = |w| w.easy + w.moderate + w.hard

	# the chart draws once any week holds polarized time
	# the chart's line while its twelve weeks hold no polarized time: the
	# first run while no activity exists, the analyze still owed while none
	# is scored, else the session that fills it
	empty_text : Ui.Model -> Str
	empty_text = |model| Chrome.empty_line(model, "no polarized time in the last 12 weeks - an endurance session with heart rate, power or pace fills it")

	charted : Ui.Model -> Bool
	charted = |model| List.any(model.zone_weeks, |w| split_s(w) > 0)

	# each class's height on a share bar `h` tall: easy, moderate and hard,
	# base first, together the whole bar; nothing for a week with no
	# polarized time
	segments : Db.ZoneWeek, F32 -> List(F32)
	segments = |w, h| {
		t = split_s(w)
		if t <= 0 {
			[0.0, 0.0, 0.0]
		} else {
			easy = I64.to_f32(w.easy) / I64.to_f32(t) * h
			moderate = I64.to_f32(w.moderate) / I64.to_f32(t) * h
			[easy, moderate, h - easy - moderate]
		}
	}

	# the plot's height at a window height
	plot_h : F32 -> F32
	plot_h = |win_h| Weeks.bars_bot(win_h) - Weeks.bars_top

	# the 80/20 line's height above the base on a bar `bh` tall
	mark_h : F32 -> F32
	mark_h = |bh| bh * I64.to_f32(easy_floor) / 100.0

	# the 80/20 line: one white line across every slot at 80% of the plot
	line_y : F32 -> F32
	line_y = |win_h| Weeks.bars_bot(win_h) - mark_h(plot_h(win_h))

	line_box : { w : F32, h : F32 } -> Labels.Rect
	line_box = |win| { x: Weeks.plot_left - 2.0, y: line_y(win.h) - 1.0, w: win.w - pad - Weeks.plot_left + 2.0, h: 2.0 }

	Bar : { w : Db.ZoneWeek, i : U64, cx : F32, box : Labels.Rect }

	# each week's bar on screen: its slot's centre and its body, the full
	# plot for a week with polarized time and a 3px stub for one without
	bars_of : List(Db.ZoneWeek), { w : F32, h : F32 } -> List(Bar)
	bars_of = |weeks, win| {
		n = List.len(weeks)
		bw = Weeks.bar_w(win.w, n)
		bot = Weeks.bars_bot(win.h)
		List.map_with_index(
			weeks,
			|w, i| {
				cx = Weeks.slot_cx(win.w, n, i)
				box = if (split_s(w) > 0) { x: cx - bw / 2.0, y: Weeks.bars_top, w: bw, h: plot_h(win.h) } else { x: cx - bw / 2.0, y: bot - 3.0, w: bw, h: 3.0 }
				{ w, i, cx, box }
			},
		)
	}

	bars : Ui.Model -> List(Bar)
	bars = |model| bars_of(model.zone_weeks, model.win)

	# the week the card reads: the newest with polarized time
	newest : Ui.Model -> Db.ZoneWeek
	newest = |model| List.fold(model.zone_weeks, { wk: "", days: 7, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0, easy: 0, moderate: 0, hard: 0 }, |acc, w| if (split_s(w) > 0) (w) else acc)

	# the class key on its own row over the plot: each swatch, and its name
	# 13px right of it, the next swatch 14px past the name's end
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

	# where the key row's text ends, for the focused week's note that follows it
	key_end : Scene.Measure -> F32
	key_end = |measure| List.fold(key_row(measure), pad, |_, k| k.text_x + measure(k.name, 10.0, Data))

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
		head = [fix(Scene.prepared(model.zones_title, title_text, 15.0, Prose, ink_muted), Weeks.title_x, 70.0, Left, panel)]
		chart =
			if !(charted(model)) {
				[fix(Scene.data(empty_text(model), 14.0, ink_muted), pad, 130.0, Left, panel)]
			} else {
				last = newest(model)
				t = tile(last)
				card = Weeks.card_box(win_w)
				bot = Weeks.bars_bot(win_h)
				axis = Weeks.plot_left - 6.0
				# under every bar its date, then its hours; over the running
				# week's bar, "so far"
				per_bar = List.join(
					List.map(
						bars(model),
						|b| List.join([
							[
								fix(Scene.data(Weeks.week_label(b.w.wk), 10.0, ink_faint), b.cx, Weeks.date_row(win_h), Center, panel),
								fix(Scene.data(hours(split_s(b.w)), 10.0, ink_faint), b.cx, Weeks.figure_row(win_h), Center, panel),
							],
							if (Weeks.partial(b.w.days)) [fix(Scene.data("so far", 10.0, ink_faint), b.cx, b.box.y - 14.0, Center, panel)] else [],
						]),
					),
				)
				List.join([
					[
						fix(Scene.data(t.value, 28.0, t.color), card.x + 16.0, 68.0, Left, card),
						fix(Scene.data(t.label, 11.0, ink_faint), card.x + 16.0, 102.0, Left, card),
						fix(Scene.data(hours(split_s(last)), 28.0, Theme.ctl_c), win_w - pad - 16.0, 68.0, Right, card),
						fix(Scene.data("in the split", 11.0, ink_faint), win_w - pad - 16.0, 102.0, Right, card),
						# the scale, in the gutter: the bar's top is the
						# week's whole split, and the line is labelled
						# where it crosses
						fix(Scene.data("100 %", 10.0, ink_faint), axis, Weeks.bars_top - 5.0, Right, panel),
						fix(Scene.data("${I64.to_str(easy_floor)} %", 10.0, Color.white), axis, line_y(win_h) - 5.0, Right, panel),
						fix(Scene.data("0", 10.0, ink_faint), axis, bot - 10.0, Right, panel),
					],
					# the focused week's heart-rate zone hours, beside the key
					List.map(row_note(model), |note| fix(Scene.data(note, 10.0, ink_faint), key_end(measure) + 16.0, 118.0, Left, panel)),
					Weeks.focus_texts(model, measure),
					List.map(key_row(measure), |k| fix(Scene.data(k.name, 10.0, ink_faint), k.text_x, 118.0, Left, panel)),
					per_bar,
				])
			}
		foot = [fix(Scene.prepared(model.zones_hint, hint_text, 13.0, Prose, ink_faint), pad, win_h - 30.0, Left, panel)]
		List.join([head, chart, foot, Weeks.chip_texts(model, measure)])
	}

	# what the placer keeps text off: the chrome, the card, the swatches,
	# the bars and the line
	obstacles : Ui.Model, Scene.Measure -> Labels.Obstacles
	obstacles = |model, measure| { boxes: List.concat(Chrome.boxes(model, measure), List.map(marks(model, measure), |m| m.box)), segs: [] }

	# the shapes no text may cover but its own: the pills, the mode chips,
	# the card, the class key's swatches, every bar, and the 80/20 line
	marks : Ui.Model, Scene.Measure -> List(Labels.Mark)
	marks = |model, measure|
		if charted(model) {
			List.join([
				Chrome.marks(model),
				Weeks.chip_marks,
				[{ key: "the verdict card", box: Weeks.card_box(model.win.w) }, { key: "the 80/20 line", box: line_box(model.win) }],
				List.map(key_row(measure), |k| { key: "the ${k.name} swatch", box: k.swatch }),
				List.map(bars(model), |b| { key: "the ${b.w.wk} bar", box: b.box }),
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
			frame.rounded_rectangle!({ x: card.x, y: card.y, width: card.w, height: card.h, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
			frame.line!({ start: { x: Weeks.plot_left, y: bot }, end: { x: win_w - pad, y: bot }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 70), 1) })
			List.for_each!(key_row(measure), |k| frame.rounded_rectangle!({ x: k.swatch.x, y: k.swatch.y, width: k.swatch.w, height: k.swatch.h, radius: 2.0, segments: 3, style: Draw.filled(k.color) }))
			focus = Weeks.focus_week(model)
			List.for_each!(
				bars(model),
				|b| {
					x0 = b.box.x
					bw = b.box.w
					hovered = b.w.wk == focus
					if split_s(b.w) > 0 {
						# easy at the base, hard on top, a hairline of ground between each
						_ = List.fold_try!(
							List.map2(segments(b.w, b.box.h), classes, |seg, c| { seg, c }),
							0.0,
							|yacc, s| {
								if s.seg > 1.5 {
									frame.rectangle!({ x: x0, y: bot - yacc - s.seg, width: bw, height: s.seg - 1.0, style: Draw.filled(Color.with_alpha(s.c.color, if (hovered) (255.U8) else if (Weeks.partial(b.w.days)) 120 else 235)) })
								}
								Ok(yacc + s.seg)
							},
						)
						# depth over the whole stack, so the bars sit in the panel
						frame.rectangle_gradient_v!({ x: x0, y: b.box.y, width: bw, height: b.box.h, color_top: Color.with_alpha(Theme.bg, 0), color_bottom: Color.with_alpha(Theme.bg, 90) })
					} else {
						frame.rounded_rectangle!({ x: x0, y: b.box.y, width: bw, height: b.box.h, radius: 1.5, segments: 3, style: Draw.filled(Color.with_alpha(ink_faint, 90)) })
					}
				},
			)
			# the 80/20 line over every bar
			l = line_box(model.win)
			frame.rectangle!({ x: l.x, y: l.y, width: l.w, height: l.h, style: Draw.filled(Color.with_alpha(Color.white, 220)) })
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

# the card reads easy against everything else, the two summing to 100: an
# 80/0/20 week holds at 80/20, an 81/18/1 week holds at 81/19, a 70/10/20
# week breaks at 70/30, a week still running reads muted, and a week with
# no polarized time reads a dash
expect {
	wk = |e, m, h, d| { wk: "2026-11-23", days: d, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0, easy: e, moderate: m, hard: h }
	Zones.tile(wk(8000, 0, 2000, 7)) == { value: "80/20", label: "easy / harder, wk of 11-23", color: Theme.tsb_c }
		and Zones.tile(wk(8100, 1800, 100, 7)) == { value: "81/19", label: "easy / harder, wk of 11-23", color: Theme.tsb_c }
		and Zones.tile(wk(7000, 1000, 2000, 7)) == { value: "70/30", label: "easy / harder, wk of 11-23", color: Theme.alarm_c }
		and Zones.tile(wk(9000, 900, 100, 3)) == { value: "90/10", label: "easy / harder, wk of 11-23", color: Theme.ink_muted }
		and Zones.tile(wk(0, 0, 0, 7)) == { value: "-", label: "no polarized time", color: Theme.ink_muted }
		and Zones.tile(wk(7999, 1, 2000, 7)) == { value: "79/21", label: "easy / harder, wk of 11-23", color: Theme.alarm_c }
}

# every real week is a share bar: it stands the whole plot, from the band's
# top to its base, its three segments stack to exactly its height, and its
# easy segment's share of the bar floors to the card's easy share
expect {
	bs = Zones.bars_of(Zones.real_weeks, { w: 980.0, h: 600.0 })
	h = Zones.plot_h(600.0)
	List.len(bs) == 12
		and List.all(
			bs,
			|b| {
				segs = Zones.segments(b.w, b.box.h)
				easy_h = (List.first(segs)) ?? 0.0
				stack = List.fold(segs, 0.0, |a, s| a + s)
				e = b.w.easy * 100 // Zones.split_s(b.w)
				share = easy_h / b.box.h * 100.0
				(b.box.h - h).abs() < 0.01
					and (b.box.y - Weeks.bars_top).abs() < 0.01
					and (stack - b.box.h).abs() < 0.01
					and share >= I64.to_f32(e) and share < I64.to_f32(e + 1)
					and Str.starts_with((Zones.tile(b.w)).value, "${I64.to_str(e)}/")
			},
		)
}

# the first real week reads about 82% easy by heart rate and 64% by the
# split; the bar and its card both read the split
expect {
	w = (List.first(Zones.real_weeks)) ?? { wk: "", days: 7, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0, easy: 0, moderate: 0, hard: 0 }
	by_hr = (w.z1 + w.z2) * 100 // (w.z1 + w.z2 + w.z3 + w.z4 + w.z5)
	easy_h = (List.first(Zones.segments(w, 300.0))) ?? 0.0
	by_hr == 81 and (Zones.tile(w)).value == "64/36" and (easy_h / 300.0 * 100.0 - 64.77).abs() < 0.05
}

# the 80/20 line is the verdict drawn: it crosses every size's plot at 80%
# of its height, and on every real finished week, none of which holds the
# split, and on a week that does, the easy segment reaches the line exactly
# when the card would read teal
expect {
	held = { wk: "2026-11-30", days: 7, z1: 3600, z2: 28800, z3: 1800, z4: 1800, z5: 0, easy: 29000, moderate: 3500, hard: 3500 }
	weeks = List.append(Zones.real_weeks, held)
	bs = Zones.bars_of(weeks, { w: 980.0, h: 600.0 })
	finished = List.keep_if(bs, |b| !(Weeks.partial(b.w.days)))
	reaches = |b| Weeks.bars_bot(600.0) - ((List.first(Zones.segments(b.w, b.box.h))) ?? 0.0) <= Zones.line_y(600.0)
	teal = |b| (Zones.tile(b.w)).color == Theme.tsb_c
	on_line = |win_h| ((Weeks.bars_bot(win_h) - Zones.line_y(win_h)) / Zones.plot_h(win_h) - 0.8).abs() < 0.0001
	List.len(finished) == 12
		and List.any(finished, teal)
		and List.any(finished, |b| !(teal(b)))
		and List.all(finished, |b| reaches(b) == teal(b))
		and on_line(600.0) and on_line(900.0) and on_line(1440.0)
		and ((Zones.line_box({ w: 980.0, h: 600.0 })).y + 1.0 - Zones.line_y(600.0)).abs() < 0.01
}

# a week with zone time but no polarized time, a lifting week, keeps a 3px
# stub at the base, draws no segment and earns no verdict
expect {
	lift = { wk: "2026-11-16", days: 7, z1: 1800, z2: 1200, z3: 0, z4: 0, z5: 0, easy: 0, moderate: 0, hard: 0 }
	ride = { wk: "2026-11-23", days: 7, z1: 600, z2: 3000, z3: 0, z4: 0, z5: 0, easy: 3600, moderate: 0, hard: 0 }
	bs = Zones.bars_of([lift, ride], { w: 980.0, h: 600.0 })
	stub = ((List.first(bs)) ?? { w: lift, i: 0, cx: 0.0, box: { x: 0.0, y: 0.0, w: 0.0, h: 0.0 } }).box
	List.all(Zones.segments(lift, 300.0), |s| s.abs() < 0.001)
		and (stub.h - 3.0).abs() < 0.001
		and (stub.y + stub.h - Weeks.bars_bot(600.0)).abs() < 0.001
		and Zones.verdict(lift.easy, Zones.split_s(lift), 7) == Theme.ink_muted
}

# the focus row reads a week's heart-rate zone hours, and says so when a
# week holds none
expect {
	w = (List.first(Zones.real_weeks)) ?? { wk: "", days: 7, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0, easy: 0, moderate: 0, hard: 0 }
	Zones.hr_line(w) == "hr zones z1-z5: 1.8  3.0  0.5  0.2  0.3 h" and Zones.hr_line({ ..w, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0 }) == "no heart-rate zone time"
}

# a week 81.5% easy, 16.5% moderate and 2% hard reads 81/19 on the card and
# easy 81% in the header line, the shares `stride review` prints for the
# same week ("easy 81%  moderate 17%  hard 2%", pinned in the e2e suite);
# its 17244 s read 4.8 h, the nearest tenth, as the CLI rounds hours
expect {
	w = { wk: "2026-11-16", days: 7, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0, easy: 14054, moderate: 2845, hard: 345 }
	(Zones.tile(w)).value == "81/19" and Weeks.week_line("2026-11-16", [w], []) == "wk of 2026-11-16   4.8 h, easy 81%"
}
