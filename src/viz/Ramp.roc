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
	# The weeks tab's load mode: twelve Monday weeks, each bar the CTL that
	# week gained, its end (now, for the running week) less its start,
	# drawn from a zero line named "holds fitness": a gain grows up, a loss
	# grows down, every bar on one scale in CTL points, so equal changes
	# stand equal. Bar and chip share the verdict's color: muted for a week
	# that held or lost fitness, blue for one that gained, red for one that
	# gained more than ramp_limit. The chip sits at the bar's end and reads
	# the change; the week's load sits under its date. The running week is
	# an outline, still filling in, with "so far" over it. A week before the
	# athlete's history, with no load and no CTL yet, draws nothing.

	pad : F32
	pad = 36.0

	# the CTL a week may gain, in whole points, before it climbs too fast:
	# past it a week's bar and chip turn red, and the key says so
	ramp_limit : I64
	ramp_limit = 6

	# the verdict a week's change earns, in tenths of CTL, as its bar's and
	# chip's color: a flat week is not a build, so it reads muted with the
	# weeks that lost fitness
	verdict : I64 -> Color.Rgba
	verdict = |d10| if (d10 > ramp_limit * 10) (Theme.alarm_c) else if (d10 > 0) (Theme.ctl_c) else Theme.ink_muted

	# the bar's opacity: the focused week brightest, every other the same
	bar_alpha : Bool -> U8
	bar_alpha = |focused| if (focused) (250.U8) else 220

	# the CTL a week gained, in tenths, rounded once from the unrounded
	# difference: the view's ramp, the number the card and the CLI print;
	# for a week that began from zero CTL, before history, its whole end
	delta10 : Db.RampWeek -> I64
	delta10 = |w| if (w.ctl_start <= 0.0) w.ctl10 else w.ramp10

	# the change as the chip and the card both write it, signed
	change_text : Db.RampWeek -> Str
	change_text = |w| Fmt.tenths_signed(delta10(w))

	# the card's caption names the span its change covers: a calendar week,
	# Monday on, in the words core.Load gives every span (`stride summary`
	# names its rolling week the same way), so two different spans never
	# share one label
	card_span : Db.RampWeek -> Str
	card_span = |w| "ctl ${Load.week_span(w.wk, Weeks.partial(w.days))}"

	# a week before the athlete's history: no load and no CTL yet
	before_history : Db.RampWeek -> Bool
	before_history = |w| w.tss == 0 and w.ctl10 == 0 and w.ctl_start <= 0.0

	# the narrowest the scale may span, in CTL points, so a flat history
	# does not stretch a tenth of a point across the plot
	min_span : I64
	min_span = 4

	# The scale in whole CTL points, from the lowest change of any week
	# shown to the highest, rounded outward and always holding zero; when
	# that spans less than min_span, the side the larger change sits on
	# grows to it, gains taking a tie and a flat history.
	scale_of : List(Db.RampWeek) -> { hi : I64, lo : I64 }
	scale_of = |weeks| {
		shown = List.keep_if(weeks, |w| !(before_history(w)))
		hi10 = List.fold(shown, 0, |a, w| if (delta10(w) > a) delta10(w) else a)
		lo10 = List.fold(shown, 0, |a, w| if (delta10(w) < a) delta10(w) else a)
		hi = (hi10 + 9) // 10
		lo = 0 - ((9 - lo10) // 10)
		short = min_span - (hi - lo)
		if (short <= 0) { hi, lo } else if (hi >= 0 - lo) { hi: hi + short, lo } else { hi, lo: lo - short }
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
	# the chart's line while its twelve weeks hold no load: the first run
	# while no activity exists, the analyze still owed while none is scored,
	# else the session that puts load on them
	empty_text : Ui.Model -> Str
	empty_text = |model| Chrome.empty_line(model, "no load in the last 12 weeks - a session stride analyze scores fills it, then press R")

	charted : Ui.Model -> Bool
	charted = |model| !(List.is_empty(model.ramp_weeks)) and List.fold(model.ramp_weeks, 0.I64, |a, w| a + w.tss) != 0

	# the plot starts under the band's top, leaving the running week's
	# "so far" room under the card
	plot_top : F32
	plot_top = Weeks.bars_top + 16.0

	plot_h : F32 -> F32
	plot_h = |win_h| Weeks.bars_bot(win_h) - plot_top

	# the room past a bar's end at either edge of the plot, for its chip
	chip_room : F32
	chip_room = 28.0

	# pixels per CTL point on a scale
	unit : F32, { hi : I64, lo : I64 } -> F32
	unit = |win_h, s| (plot_h(win_h) - 2.0 * chip_room) / I64.to_f32(s.hi - s.lo)

	# where a change of `pts` CTL points stands on a scale; zero is the line
	y_at : F32, { hi : I64, lo : I64 }, F32 -> F32
	y_at = |win_h, s, pts| plot_top + chip_room + (I64.to_f32(s.hi) - pts) * unit(win_h, s)

	# the zero line, where a week held fitness
	line_y : F32, { hi : I64, lo : I64 } -> F32
	line_y = |win_h, s| y_at(win_h, s, 0.0)

	line_box : { w : F32, h : F32 }, { hi : I64, lo : I64 } -> Labels.Rect
	line_box = |win, s| { x: Weeks.plot_left - 2.0, y: line_y(win.h, s) - 1.0, w: win.w - pad - Weeks.plot_left + 2.0, h: 2.0 }

	# the zero line's name, in the gutter just over its 0
	line_label : Str
	line_label = "holds fitness"

	# a week's bar with what it draws: nothing for a week before history,
	# else its body from the zero line (a 3px stub across it for no change),
	# drawn as an outline while the week runs
	Bar : { w : Db.RampWeek, i : U64, cx : F32, box : Labels.Rect, drawn : Bool, outlined : Bool }

	bars_of : List(Db.RampWeek), { w : F32, h : F32 } -> List(Bar)
	bars_of = |weeks, win| {
		n = List.len(weeks)
		bw = Weeks.bar_w(win.w, n)
		s = scale_of(weeks)
		zero = line_y(win.h, s)
		List.map_with_index(
			weeks,
			|w, i| {
				cx = Weeks.slot_cx(win.w, n, i)
				d = delta10(w)
				bh = I64.to_f32(if (d < 0) 0 - d else d) / 10.0 * unit(win.h, s)
				box = if (bh <= 3.0) { x: cx - bw / 2.0, y: zero - 1.5, w: bw, h: 3.0 } else if (d > 0) { x: cx - bw / 2.0, y: zero - bh, w: bw, h: bh } else { x: cx - bw / 2.0, y: zero, w: bw, h: bh }
				{ w, i, cx, box, drawn: !(before_history(w)), outlined: Weeks.partial(w.days) }
			},
		)
	}

	bars : Ui.Model -> List(Bar)
	bars = |model| bars_of(model.ramp_weeks, model.win)

	drawn_bars : Ui.Model -> List(Bar)
	drawn_bars = |model| List.keep_if(bars(model), |b| b.drawn)

	# a bar grows down when its week lost fitness
	down : Bar -> Bool
	down = |b| delta10(b.w) < 0

	# what a bar and its chip both read: the change, signed, and its color
	look : Bar -> { text : Str, color : Color.Rgba }
	look = |b| { text: change_text(b.w), color: verdict(delta10(b.w)) }

	# a bar's chip, 54 wide over its slot's centre, at the bar's end: over
	# a gain or no change, under a loss
	chip_box : Bar -> Labels.Rect
	chip_box = |b| if (down(b)) { x: b.cx - 27.0, y: b.box.y + b.box.h + 4.0, w: 54.0, h: 20.0 } else { x: b.cx - 27.0, y: b.box.y - 24.0, w: 54.0, h: 20.0 }

	# where "so far" sits over the running week: over its chip on a gain,
	# over the bar's top at the line on a loss
	so_far_y : Bar -> F32
	so_far_y = |b| if (down(b)) (b.box.y - 14.0) else (chip_box(b)).y - 14.0

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
				[fix(Scene.data(empty_text(model), 14.0, ink_muted), pad, 130.0, Left, panel)]
			} else {
				# where fitness stands and how fast it is moving
				last = newest(model)
				card = Weeks.card_box(win_w)
				s = scale_of(model.ramp_weeks)
				ly = line_y(win_h, s)
				axis = Weeks.plot_left - 6.0
				# under every week its date and load; on each drawn bar its
				# chip, and "so far" over the running week
				per_bar = List.join(
					List.map(
						bars(model),
						|b| {
							cb = chip_box(b)
							l = look(b)
							List.join([
								[
									fix(Scene.data(Weeks.week_label(b.w.wk), 10.0, ink_faint), b.cx, Weeks.date_row(win_h), Center, panel),
									fix(Scene.data(Db.grouped(b.w.tss), 10.0, ink_faint), b.cx, Weeks.figure_row(win_h), Center, panel),
								],
								if (b.drawn) [fix(Scene.data(l.text, 11.0, l.color), b.cx, cb.y + 4.0, Center, cb)] else [],
								if (b.drawn and b.outlined) [fix(Scene.data("so far", 10.0, ink_faint), b.cx, so_far_y(b), Center, panel)] else [],
							])
						},
					),
				)
				# the scale, in the gutter, in CTL points: its top and its
				# bottom where they differ from zero, and the zero line named
				# over its 0
				ends = List.join([
					if (s.hi > 0) [fix(Scene.data("+${I64.to_str(s.hi)}", 10.0, ink_faint), axis, y_at(win_h, s, I64.to_f32(s.hi)) - 5.0, Right, panel)] else [],
					if (s.lo < 0) [fix(Scene.data(I64.to_str(s.lo), 10.0, ink_faint), axis, y_at(win_h, s, I64.to_f32(s.lo)) - 5.0, Right, panel)] else [],
				])
				List.join([
					[
						fix(Scene.data(Fmt.tenths(last.ctl10), 28.0, Theme.ctl_c), card.x + 16.0, 68.0, Left, card),
						fix(Scene.data("ctl now", 11.0, ink_faint), card.x + 16.0, 102.0, Left, card),
						fix(Scene.data(change_text(last), 28.0, verdict(delta10(last))), win_w - pad - 16.0, 68.0, Right, card),
						fix(Scene.data(card_span(last), 11.0, ink_faint), win_w - pad - 16.0, 102.0, Right, card),
						Scene.kept(measure, Scene.data(line_label, 10.0, Color.white), [{ x: axis, y: ly - 18.0, align: Right }, { x: axis, y: ly + 8.0, align: Right }], 1, panel),
						fix(Scene.data("0", 10.0, Color.white), axis, ly - 5.0, Right, panel),
					],
					ends,
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
	# the card, the key's swatches, the line, and every drawn bar and chip
	marks : Ui.Model, Scene.Measure -> List(Labels.Mark)
	marks = |model, measure|
		if charted(model) {
			List.join([
				Chrome.marks(model),
				Weeks.chip_marks,
				[{ key: "the ctl card", box: Weeks.card_box(model.win.w) }, { key: "the holds-fitness line", box: line_box(model.win, scale_of(model.ramp_weeks)) }],
				List.map(key_row(measure), |k| { key: "the ${k.name} swatch", box: k.swatch }),
				List.join(List.map(drawn_bars(model), |b| [{ key: "the ${b.w.wk} bar", box: b.box }, { key: "the ${b.w.wk} chip", box: chip_box(b) }])),
			])
		} else {
			List.concat(Chrome.marks(model), Weeks.chip_marks)
		}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		ink_faint = Theme.ink_faint
		measure = Scene.measure_of(model)
		if charted(model) {
			card = Weeks.card_box(model.win.w)
			frame.rounded_rectangle!({ x: card.x, y: card.y, width: card.w, height: card.h, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
			List.for_each!(key_row(measure), |k| frame.rounded_rectangle!({ x: k.swatch.x, y: k.swatch.y, width: k.swatch.w, height: k.swatch.h, radius: 2.0, segments: 3, style: Draw.filled(k.color) }))
			focus = Weeks.focus_week(model)
			List.for_each!(
				drawn_bars(model),
				|b| {
					vc = (look(b)).color
					hovered = b.w.wk == focus
					if b.outlined {
						# the running week is still filling in: an outline, lightly filled
						frame.rounded_rectangle!({ x: b.box.x, y: b.box.y, width: b.box.w, height: b.box.h, radius: 4.0, segments: 4, style: Draw.filled_and_outlined(Color.with_alpha(vc, if (hovered) (80.U8) else 36), Color.with_alpha(vc, 230), 2.0) })
					} else if b.box.h > 3.0 {
						frame.rounded_rectangle!({ x: b.box.x, y: b.box.y, width: b.box.w, height: b.box.h, radius: 4.0, segments: 4, style: Draw.filled(Color.with_alpha(vc, bar_alpha(hovered))) })
						# depth: the bar darkens toward the zero line it grows from
						if down(b) {
							frame.rectangle_gradient_v!({ x: b.box.x, y: b.box.y, width: b.box.w, height: b.box.h - 4.0, color_top: Color.with_alpha(Theme.bg, 110), color_bottom: Color.with_alpha(Theme.bg, 0) })
						} else {
							frame.rectangle_gradient_v!({ x: b.box.x, y: b.box.y + 4.0, width: b.box.w, height: b.box.h - 4.0, color_top: Color.with_alpha(Theme.bg, 0), color_bottom: Color.with_alpha(Theme.bg, 110) })
						}
					} else {
						frame.rounded_rectangle!({ x: b.box.x, y: b.box.y, width: b.box.w, height: b.box.h, radius: 1.5, segments: 3, style: Draw.filled(Color.with_alpha(ink_faint, 90)) })
					}
					cb = chip_box(b)
					frame.rounded_rectangle!({ x: cb.x, y: cb.y, width: cb.w, height: cb.h, radius: 6.0, segments: 5, style: Draw.filled(Color.with_alpha(vc, if (hovered) (70.U8) else 42)) })
				},
			)
			# the holds-fitness line over every bar
			l = line_box(model.win, scale_of(model.ramp_weeks))
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
# week or one that lost fitness is muted; the key's swatches are those
# three colors, the red one named for the limit
expect Ramp.ramp_limit == 6
expect Ramp.verdict(61) == Theme.alarm_c and Ramp.verdict(60) == Theme.ctl_c and Ramp.verdict(1) == Theme.ctl_c
expect Ramp.verdict(0) == Theme.ink_muted and Ramp.verdict(-19) == Theme.ink_muted
expect List.map(Ramp.classes, |c| c.name) == ["loses fitness", "builds fitness", "past +6 ctl a week"] and List.map(Ramp.classes, |c| c.color) == [Theme.ink_muted, Theme.ctl_c, Theme.alarm_c]

# a week's change is rounded once, from the unrounded difference: the
# first real week rose 0.866 from 42.27 to an end stored as 43.1, and its
# chip and the card both read +0.9; a rise of 6.01, from 49.04 to an end
# stored as 55.1, reads +6.0 in blue, not past the limit; every real week
# reads the view's ramp; and a first week that began before history counts
# its whole CTL
expect {
	win = { w: 980.0, h: 600.0 }
	sep = (List.first(Ramp.real_weeks)) ?? Ramp.blank
	six = { wk: "2026-11-16", days: 7, tss: 600, ctl10: 551, ramp10: 60, ctl_start: 49.04 }
	first = { wk: "2026-09-21", days: 7, tss: 513, ctl10: 113, ramp10: 0, ctl_start: Db.week_start_ctl(Bool.True, 11.3, 0.0) }
	reads = |w, text, color| Ramp.change_text(w) == text and List.all(Ramp.bars_of([w], win), |b| Ramp.look(b) == { text, color })
	reads(sep, "+0.9", Theme.ctl_c)
		and reads(six, "+6.0", Theme.ctl_c)
		and List.all(Ramp.real_weeks, |w| Ramp.delta10(w) == w.ramp10)
		and Ramp.delta10(first) == 113
}

# equal changes stand equal: a finished week and a running week three days
# in, each +3.9, draw one height, and a -2.0 week draws 20/39 of it, down
expect {
	a = { wk: "2026-11-09", days: 7, tss: 531, ctl10: 539, ramp10: 39, ctl_start: 50.0 }
	b = { wk: "2026-11-16", days: 3, tss: 210, ctl10: 600, ramp10: 39, ctl_start: 56.1 }
	c = { wk: "2026-11-23", days: 7, tss: 200, ctl10: 580, ramp10: -20, ctl_start: 60.0 }
	match Ramp.bars_of([a, b, c], { w: 980.0, h: 600.0 }) {
		[ba, bb, bc] => (ba.box.h - bb.box.h).abs() < 0.01 and (bc.box.h - ba.box.h * 20.0 / 39.0).abs() < 0.01 and Ramp.down(bc) and !(Ramp.down(ba))
		_ => Bool.False
	}
}

# a bar and its chip never disagree: on every real week and on weeks that
# gain, lose, hold flat and climb past the limit, a bar grows from the zero
# line the way its chip's sign reads, its chip sits at that end and both
# wear the verdict's color; every drawn bar and chip stays inside the band
expect {
	win = { w: 980.0, h: 600.0 }
	mixed = [
		{ wk: "2026-10-26", days: 7, tss: 600, ctl10: 600, ramp10: 72, ctl_start: 52.8 },
		{ wk: "2026-11-02", days: 7, tss: 300, ctl10: 580, ramp10: -20, ctl_start: 60.0 },
		{ wk: "2026-11-09", days: 7, tss: 350, ctl10: 580, ramp10: 0, ctl_start: 58.0 },
		{ wk: "2026-11-16", days: 4, tss: 150, ctl10: 570, ramp10: -10, ctl_start: 58.0 },
	]
	agree = |weeks| {
		s = Ramp.scale_of(weeks)
		zero = Ramp.line_y(win.h, s)
		List.all(
			Ramp.bars_of(weeks, win),
			|b| {
				l = Ramp.look(b)
				c = Ramp.chip_box(b)
				d = Ramp.delta10(b.w)
				grows = if (d > 0) ((b.box.y + b.box.h - zero).abs() < 0.01) else if (d < 0) ((b.box.y - zero).abs() < 0.01) else (b.box.y + 1.5 - zero).abs() < 0.01
				ends = if (Ramp.down(b)) (c.y >= b.box.y + b.box.h) else c.y + c.h <= b.box.y
				grows and ends and Str.starts_with(l.text, "-") == (d < 0) and l.color == Ramp.verdict(d) and c.y >= Ramp.plot_top - 0.01 and c.y + c.h <= Weeks.bars_bot(win.h) + 0.01
			},
		)
	}
	agree(Ramp.real_weeks) and agree(mixed)
}

# the scale spans the lowest change to the highest, rounded outward to
# whole points and holding zero: gains alone set no room below the line,
# losses alone none above it, both set each side, and a span short of four
# points grows on the side of the larger change, gains taking a tie and a
# flat history
expect {
	wk = |d10| { wk: "2026-11-16", days: 7, tss: 300, ctl10: 500 + d10, ramp10: d10, ctl_start: 50.0 }
	Ramp.scale_of([wk(9), wk(40)]) == { hi: 4, lo: 0 }
		and Ramp.scale_of([wk(-5), wk(-22)]) == { hi: 0, lo: -4 }
		and Ramp.scale_of([wk(40), wk(-22), wk(11)]) == { hi: 4, lo: -3 }
		and Ramp.scale_of([wk(0), wk(0)]) == { hi: 4, lo: 0 }
		and Ramp.scale_of([wk(3), wk(-2)]) == { hi: 3, lo: -1 }
		and Ramp.scale_of([wk(113), wk(-5)]) == { hi: 12, lo: -1 }
}

# with gains alone the zero line sits at the plot's foot, a chip's room
# over its base; with losses alone at its head
expect {
	wk = |d10| { wk: "2026-11-16", days: 7, tss: 300, ctl10: 500 + d10, ramp10: d10, ctl_start: 50.0 }
	(Ramp.line_y(600.0, Ramp.scale_of([wk(40)])) - (Weeks.bars_bot(600.0) - Ramp.chip_room)).abs() < 0.01
		and (Ramp.line_y(600.0, Ramp.scale_of([wk(-40)])) - (Ramp.plot_top + Ramp.chip_room)).abs() < 0.01
}

# a week before the athlete's history, with no load and no CTL yet, draws
# nothing and leaves the scale alone; the first week of history counts
# its whole CTL as its change; the running week, and only it, is an
# outline
expect {
	pre = { wk: "2026-09-07", days: 7, tss: 0, ctl10: 0, ramp10: 0, ctl_start: 0.0 }
	first = { wk: "2026-09-21", days: 7, tss: 513, ctl10: 113, ramp10: 0, ctl_start: 0.0 }
	run = { wk: "2026-09-28", days: 3, tss: 200, ctl10: 150, ramp10: 37, ctl_start: 11.3 }
	match Ramp.bars_of([pre, pre, first, run], { w: 980.0, h: 600.0 }) {
		[a, b, c, d] => !(a.drawn) and !(b.drawn) and c.drawn and d.drawn and !(c.outlined) and d.outlined and !(a.outlined) and Ramp.scale_of([pre, first, run]) == Ramp.scale_of([first, run])
		_ => Bool.False
	}
}

# the card reads the change to a tenth, the precision `stride summary`
# prints its ramp with, and names the calendar week it covers, never the
# bare "per week" the summary's rolling seven days could also claim
expect {
	running = { wk: "2026-11-23", days: 3, tss: 210, ctl10: 559, ramp10: 39, ctl_start: 52.0 }
	done = { ..running, wk: "2026-11-16", days: 7 }
	Ramp.change_text(running) == "+3.9" and Ramp.card_span(running) == "ctl since Monday 11-23" and Ramp.card_span(done) == "ctl in the week of 11-16"
}
