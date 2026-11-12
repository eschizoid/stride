import rr.Color
import rr.Draw
import core.Fmt
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
	# both be read honestly. The current week, until the series covers all
	# seven of its days, is judged by neither: its bar and chip are muted and
	# the chip says "so far", since a partial week's load is not a low one.

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

	title_text : Str
	title_text = "weekly load, and how fast fitness climbs"

	hint_text : Str
	hint_text = "zones / load  modes      hover or click a week      TAB  career      R  reload      S  screenshot      V  record      ESC quit"

	key_text : Str
	key_text = "chips: the ctl each week gained     teal builds     red past +6/wk     grey holds or sheds"

	# the chart draws once any week holds load
	charted : Ui.Model -> Bool
	charted = |model| !(List.is_empty(model.ramp_weeks)) and List.fold(model.ramp_weeks, 0.I64, |a, w| a + w.tss) != 0

	# each week's bar on screen: its slot's centre, its top, and its body
	# (a 3px stub for a week with no load), scaled to the heaviest week
	bars : Ui.Model -> List({ w : Db.RampWeek, i : U64, cx : F32, top : F32, box : Labels.Rect })
	bars = |model| {
		n = List.len(model.ramp_weeks)
		slot = (model.win.w - pad * 2.0) / U64.to_f32(n)
		bw = F32.min(74.0, slot * 0.60)
		bot = Weeks.bars_bot(model.win.h)
		peak = List.fold(model.ramp_weeks, 1.I64, |a, w| if (w.tss > a) (w.tss) else a)
		List.map_with_index(
			model.ramp_weeks,
			|w, i| {
				cx = pad + (U64.to_f32(i) + 0.5) * slot
				bh = I64.to_f32(w.tss) / I64.to_f32(peak) * (bot - Weeks.bars_top)
				{ w, i, cx, top: bot - bh, box: if (bh > 3.0) { x: cx - bw / 2.0, y: bot - bh, w: bw, h: bh } else { x: cx - bw / 2.0, y: bot - 3.0, w: bw, h: 3.0 } }
			},
		)
	}

	newest : Ui.Model -> Db.RampWeek
	newest = |model| (List.last(model.ramp_weeks)) ?? { wk: "", days: 7, tss: 0, ctl10: 0, ramp10: 0 }

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
				peak = List.fold(model.ramp_weeks, 1.I64, |a, w| if (w.tss > a) (w.tss) else a)
				bot = Weeks.bars_bot(win_h)
				per_bar = List.join(
					List.map(
						bars(model),
						|b| {
							cb = Weeks.cap_box(b.cx, b.top)
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
						Scene.free(measure, Scene.data("${I64.to_str(peak)} tss", 10.0, ink_faint), [{ x: pad, y: Weeks.bars_top - 14.0, align: Left }], 1, panel),
						fix(Scene.data("0", 10.0, ink_faint), pad, bot - 12.0, Left, panel),
						Weeks.focus_text(model, measure, key_text),
					],
					per_bar,
				)
			}
		foot = [fix(Scene.prepared(model.ramp_hint, hint_text, 13.0, Prose, ink_faint), pad, win_h - 30.0, Left, panel)]
		List.join([head, chart, foot, Weeks.chip_texts(model, measure)])
	}

	# what the scale's top value keeps off: the chrome, the card, the bars
	# and their chips
	obstacles : Ui.Model, Scene.Measure -> Labels.Obstacles
	obstacles = |model, measure| { boxes: List.concat(Chrome.boxes(model, measure), List.map(marks(model), |m| m.box)), segs: [] }

	# the shapes no text may cover but its own: the pills, the mode chips,
	# the card, and every bar and chip
	marks : Ui.Model -> List(Labels.Mark)
	marks = |model|
		if charted(model) {
			List.join([
				Chrome.marks(model),
				Weeks.chip_marks,
				[{ key: "the ctl card", box: Weeks.card_box(model.win.w) }],
				List.join(List.map(bars(model), |b| [{ key: "the ${b.w.wk} bar", box: b.box }, { key: "the ${b.w.wk} chip", box: Weeks.cap_box(b.cx, b.top) }])),
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
					# the ramp chip rides above its bar, never above the panel
					cb = Weeks.cap_box(b.cx, b.top)
					frame.rounded_rectangle!({ x: cb.x, y: cb.y, width: cb.w, height: cb.h, radius: 6.0, segments: 5, style: Draw.filled(Color.with_alpha(vc, if (hovered) (70.U8) else 42)) })
				},
			)
		}
		Scene.draw!(frame, model, scene(model, Scene.measure_of(model)))
		Ok({})
	}
}

# a finished week's ramp is judged; a week still running is muted whatever
# its ramp, and so is its bar
expect Ramp.verdict(7.0, 7) == Theme.alarm_c and Ramp.verdict(1.0, 7) == Theme.tsb_c and Ramp.verdict(0.0, 7) == Theme.ink_faint
expect Ramp.verdict(7.0, 3) == Theme.ink_muted and Ramp.verdict(-1.9, 6) == Theme.ink_muted
expect Ramp.bar_alpha(False, 3) < Ramp.bar_alpha(False, 7) and Ramp.bar_alpha(True, 3) == Ramp.bar_alpha(True, 7)
