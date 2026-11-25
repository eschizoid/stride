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
	# The weeks tab's load mode: twelve Monday weeks of load as gradient
	# bars, each wearing a chip with the CTL it gained: value as text, verdict
	# as color, so the plot keeps one y-scale. Two scales on one plot cannot
	# both be read honestly. Each bar carries a hold tick at the load that
	# would have left CTL where the week started (core.Load.hold): a bar
	# over its tick gained fitness and one under it lost fitness, whatever
	# its height beside the other weeks. The current week, until the series
	# covers all seven of its days, is judged by neither: its bar and chip are
	# muted, the chip says "so far", and its tick is held to the days it has
	# had, since a partial week's load is not a low one.

	pad : F32
	pad = 36.0
	danger : F32
	danger = 6.0

	# the verdict a week's ramp earns, and the color that says it. Zero is
	# grey with the sheds: a flat week is not a build. A week still running
	# earns none and reads muted.
	verdict : F32, I64 -> Color.Rgba
	verdict = |rv, days| if (Weeks.partial(days)) (Theme.ink_muted) else if (rv > danger) (Theme.alarm_c) else if (rv > 0.0) (Theme.tsb_c) else Theme.ink_faint

	# the bar's opacity: the focused week brightest, a week still running
	# muted, every finished week the same
	bar_alpha : Bool, I64 -> U8
	bar_alpha = |focused, days| if (focused) (250.U8) else if (Weeks.partial(days)) 110 else 220

	# the load that holds CTL over the days the week has had
	hold : Db.RampWeek -> F64
	hold = |w| Load.hold(w.ctl_start, w.days)

	title_text : Str
	title_text = "weekly load, and how fast fitness climbs"

	hint_text : Str
	hint_text = "zones / load  modes      hover or click a week      TAB  career      R  reload      S  screenshot      V  record      ESC quit"

	key_text : Str
	key_text = "chips: the ctl each week gained     teal builds     red past +6/wk     grey holds or sheds"

	# the second key line, beside the tick's swatch
	tick_text : Str
	tick_text = "tick: the load that holds ctl, its start value per day; a bar over its tick gained"

	# the tick key's swatch, on its own row clear of every chip
	tick_swatch : Labels.Rect
	tick_swatch = { x: pad, y: 122.0, w: 14.0, h: 2.0 }

	# the chart draws once any week holds load
	charted : Ui.Model -> Bool
	charted = |model| !(List.is_empty(model.ramp_weeks)) and List.fold(model.ramp_weeks, 0.I64, |a, w| a + w.tss) != 0

	# the scale's top: the heaviest week or the highest hold, so every tick
	# lands on the plot
	top_of : List(Db.RampWeek) -> F64
	top_of = |weeks| List.fold(weeks, 1.0, |a, w| F64.max(a, F64.max(I64.to_f64(w.tss), hold(w))))

	Bar : { w : Db.RampWeek, i : U64, cx : F32, top : F32, tick : F32, box : Labels.Rect }

	# each week's bar on screen: its slot's centre, its top, the height of
	# its hold tick, and its body (a 3px stub for a week with no load), on
	# the one scale the heaviest week or highest hold sets
	bars_of : List(Db.RampWeek), { w : F32, h : F32 } -> List(Bar)
	bars_of = |weeks, win| {
		n = List.len(weeks)
		slot = (win.w - pad * 2.0) / U64.to_f32(n)
		bw = F32.min(74.0, slot * 0.60)
		bot = Weeks.bars_bot(win.h)
		top = top_of(weeks)
		List.map_with_index(
			weeks,
			|w, i| {
				cx = pad + (U64.to_f32(i) + 0.5) * slot
				bh = F64.to_f32_wrap(I64.to_f64(w.tss) / top) * (bot - Weeks.bars_top)
				tick = bot - F64.to_f32_wrap(hold(w) / top) * (bot - Weeks.bars_top)
				{ w, i, cx, top: bot - bh, tick, box: if (bh > 3.0) { x: cx - bw / 2.0, y: bot - bh, w: bw, h: bh } else { x: cx - bw / 2.0, y: bot - 3.0, w: bw, h: 3.0 } }
			},
		)
	}

	bars : Ui.Model -> List(Bar)
	bars = |model| bars_of(model.ramp_weeks, model.win)

	# a week holds a tick once it started with fitness to hold
	ticked : Bar -> Bool
	ticked = |b| hold(b.w) > 0.0

	# the tick: a little wider than its bar, so it reads over a short bar
	tick_box : Bar -> Labels.Rect
	tick_box = |b| { x: b.box.x - 5.0, y: b.tick - 1.0, w: b.box.w + 10.0, h: 2.0 }

	# the chip rides above the bar and its tick, whichever stands higher
	chip_box : Bar -> Labels.Rect
	chip_box = |b| Weeks.cap_box(b.cx, if (ticked(b)) (F32.min(b.top, b.tick - 3.0)) else b.top)

	newest : Ui.Model -> Db.RampWeek
	newest = |model| (List.last(model.ramp_weeks)) ?? blank

	blank : Db.RampWeek
	blank = { wk: "", days: 7, tss: 0, ctl10: 0, ramp10: 0, ctl_start: 0.0 }

	# ── every string the view writes, placed ───────────────────────────────
	# Fixed text but the scale's top value, which a tall first week's chip
	# may cover: it drops then, and the focus line reads any week's load.
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
				bot = Weeks.bars_bot(win_h)
				per_bar = List.join(
					List.map(
						bars(model),
						|b| {
							cb = chip_box(b)
							vc = verdict(I64.to_f32(b.w.ramp10) / 10.0, b.w.days)
							List.join([
								[fix(Scene.data(Fmt.tenths_signed(b.w.ramp10), 11.0, vc), b.cx, cb.y + 4.0, Center, cb)],
								if (Weeks.partial(b.w.days)) [fix(Scene.data("so far", 10.0, ink_faint), b.cx, cb.y - 14.0, Center, panel)] else [],
								if (b.i % 2 == 0) [fix(Scene.data(Weeks.week_label(b.w.wk), 10.0, ink_faint), b.cx, bot + 10.0, Center, panel)] else [],
							])
						},
					),
				)
				List.concat(
					[
						fix(Scene.data(Fmt.tenths(last.ctl10), 28.0, Theme.ctl_c), card.x + 16.0, 68.0, Left, card),
						fix(Scene.data("ctl now", 11.0, ink_faint), card.x + 16.0, 102.0, Left, card),
						fix(Scene.data(Fmt.tenths_signed(last.ramp10), 28.0, verdict(I64.to_f32(last.ramp10) / 10.0, last.days)), win_w - pad - 16.0, 68.0, Right, card),
						fix(Scene.data(if (Weeks.partial(last.days)) "ctl per week so far" else "ctl per week", 11.0, ink_faint), win_w - pad - 16.0, 102.0, Right, card),
						Scene.free(measure, Scene.data("${I64.to_str(F64.round_to_i64_try(top) ?? 0)} load", 10.0, ink_faint), [{ x: pad, y: Weeks.bars_top - 14.0, align: Left }], 1, panel),
						fix(Scene.data("0", 10.0, ink_faint), pad, bot - 12.0, Left, panel),
						Weeks.focus_text(model, measure, key_text),
						fix(Scene.data(tick_text, 10.0, ink_faint), tick_swatch.x + tick_swatch.w + 6.0, 117.0, Left, panel),
					],
					per_bar,
				)
			}
		foot = [fix(Scene.prepared(model.ramp_hint, hint_text, 13.0, Prose, ink_faint), pad, win_h - 30.0, Left, panel)]
		List.join([head, chart, foot, Weeks.chip_texts(model, measure)])
	}

	# what the scale's top value keeps off: the chrome, the card, the bars,
	# their ticks and their chips
	obstacles : Ui.Model, Scene.Measure -> Labels.Obstacles
	obstacles = |model, measure| { boxes: List.concat(Chrome.boxes(model, measure), List.map(marks(model), |m| m.box)), segs: [] }

	# the shapes no text may cover but its own: the pills, the mode chips,
	# the card, the tick key's swatch, and every bar, tick and chip
	marks : Ui.Model -> List(Labels.Mark)
	marks = |model|
		if charted(model) {
			List.join([
				Chrome.marks(model),
				Weeks.chip_marks,
				[{ key: "the ctl card", box: Weeks.card_box(model.win.w) }, { key: "the tick swatch", box: tick_swatch }],
				List.join(
					List.map(
						bars(model),
						|b| List.join([
							[{ key: "the ${b.w.wk} bar", box: b.box }, { key: "the ${b.w.wk} chip", box: chip_box(b) }],
							if (ticked(b)) [{ key: "the ${b.w.wk} hold tick", box: tick_box(b) }] else [],
						]),
					),
				),
			])
		} else {
			List.concat(Chrome.marks(model), Weeks.chip_marks)
		}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		ink_faint = Theme.ink_faint
		if charted(model) {
			win_w = model.win.w
			bot = Weeks.bars_bot(model.win.h)
			card = Weeks.card_box(win_w)
			frame.rounded_rectangle!({ x: card.x, y: card.y, width: card.w, height: card.h, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
			frame.line!({ start: { x: pad, y: bot }, end: { x: win_w - pad, y: bot }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 70), 1) })
			frame.rectangle!({ x: tick_swatch.x, y: tick_swatch.y, width: tick_swatch.w, height: tick_swatch.h, style: Draw.filled(Color.with_alpha(Color.white, 220)) })
			focus = Weeks.focus_week(model)
			List.for_each!(
				bars(model),
				|b| {
					vc = verdict(I64.to_f32(b.w.ramp10) / 10.0, b.w.days)
					hovered = b.w.wk == focus
					body = bar_alpha(hovered, b.w.days)
					if b.box.h > 3.0 {
						frame.rounded_rectangle!({ x: b.box.x, y: b.box.y, width: b.box.w, height: b.box.h, radius: 7.0, segments: 5, style: Draw.filled(Color.with_alpha(Theme.ctl_c, body)) })
						# depth: the bar darkens toward its base, below the rounded cap
						frame.rectangle_gradient_v!({ x: b.box.x, y: b.box.y + 8.0, width: b.box.w, height: b.box.h - 8.0, color_top: Color.with_alpha(Theme.bg, 0), color_bottom: Color.with_alpha(Theme.bg, 120) })
					} else {
						frame.rounded_rectangle!({ x: b.box.x, y: b.box.y, width: b.box.w, height: b.box.h, radius: 1.5, segments: 3, style: Draw.filled(Color.with_alpha(ink_faint, 90)) })
					}
					# the hold tick over the bar, muted with a week still running
					if ticked(b) {
						t = tick_box(b)
						frame.rectangle!({ x: t.x, y: t.y, width: t.w, height: t.h, style: Draw.filled(Color.with_alpha(Color.white, if (Weeks.partial(b.w.days)) (150.U8) else 220)) })
					}
					# the ramp chip rides above its bar and tick, never above the panel
					cb = chip_box(b)
					frame.rounded_rectangle!({ x: cb.x, y: cb.y, width: cb.w, height: cb.h, radius: 6.0, segments: 5, style: Draw.filled(Color.with_alpha(vc, if (hovered) (70.U8) else 42)) })
				},
			)
		}
		Scene.draw!(frame, model, scene(model, Scene.measure_of(model)))
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

# a finished week's ramp is judged; a week still running is muted whatever
# its ramp, and so is its bar
expect Ramp.verdict(7.0, 7) == Theme.alarm_c and Ramp.verdict(1.0, 7) == Theme.tsb_c and Ramp.verdict(0.0, 7) == Theme.ink_faint
expect Ramp.verdict(7.0, 3) == Theme.ink_muted and Ramp.verdict(-1.9, 6) == Theme.ink_muted
expect Ramp.bar_alpha(False, 3) < Ramp.bar_alpha(False, 7) and Ramp.bar_alpha(True, 3) == Ramp.bar_alpha(True, 7)

# on the screen, every real week whose chip reads a gain stands over its
# tick and every one whose chip reads a loss stands under it, the running
# week included
expect {
	bs = Ramp.bars_of(Ramp.real_weeks, { w: 980.0, h: 600.0 })
	List.len(bs) == 12 and List.all(bs, |b| b.w.ramp10 == 0 or (b.w.ramp10 > 0) == (b.top < b.tick))
}

# two weeks of one height carry opposite chips, and their ticks say why:
# the September week started lower and cleared its hold, the October one
# started higher and fell short
expect {
	bs = Ramp.bars_of(Ramp.real_weeks, { w: 980.0, h: 600.0 })
	sep = (List.get(bs, 0)) ?? { w: Ramp.blank, i: 0, cx: 0.0, top: 0.0, tick: 0.0, box: { x: 0.0, y: 0.0, w: 0.0, h: 0.0 } }
	oct = (List.get(bs, 5)) ?? sep
	(sep.top - oct.top).abs() < 2.0 and sep.w.ramp10 > 0 and oct.w.ramp10 < 0 and sep.top < sep.tick and oct.top > oct.tick
}

# the running week's tick is held to its three days: lower than a full
# week's hold from the same start, by four sevenths
expect {
	run = (List.last(Ramp.real_weeks)) ?? Ramp.blank
	(Ramp.hold(run) - 51.6078 * 3.0).abs() < 0.001 and (Ramp.hold({ ..run, days: 7 }) - Ramp.hold(run) - 51.6078 * 4.0).abs() < 0.001
}

# the scale tops out at the higher of the heaviest week and the highest
# hold, so a rest week after a block still draws its tick on the plot
expect {
	rest = [{ wk: "2026-11-16", days: 7, tss: 100, ctl10: 450, ramp10: -50, ctl_start: 50.0 }]
	bs = Ramp.bars_of(rest, { w: 980.0, h: 600.0 })
	(Ramp.top_of(rest) - 350.0).abs() < 0.001 and List.all(bs, |b| (b.tick - Weeks.bars_top).abs() < 0.5 and b.top > b.tick)
}

# the chip clears the tick when the tick stands over the bar
expect {
	bs = Ramp.bars_of(Ramp.real_weeks, { w: 980.0, h: 600.0 })
	List.all(bs, |b| (Ramp.chip_box(b)).y + (Ramp.chip_box(b)).h <= F32.min(b.top, (Ramp.tick_box(b)).y))
}

# a new athlete's first week, whose history starts mid-week, started from
# zero CTL whatever end-of-week CTL and ramp the view reports for it, so it
# holds at zero and draws no tick; a later week reads its start as its end
# less its ramp
expect {
	first = { wk: "2026-11-02", days: 7, tss: 160, ctl10: 21, ramp10: 0, ctl_start: Db.week_start_ctl(Bool.True, 2.07, 0.0) }
	bs = Ramp.bars_of([first], { w: 980.0, h: 600.0 })
	Ramp.hold(first).abs() < 0.000001 and List.len(bs) == 1 and List.all(bs, |b| !(Ramp.ticked(b))) and (Db.week_start_ctl(Bool.False, 51.61, -2.17) - 53.78).abs() < 0.001
}
