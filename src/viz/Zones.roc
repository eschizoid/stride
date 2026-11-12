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
	# The weeks tab's zones mode: twelve Monday weeks of time in zone as
	# stacked bars. Every week with classified time wears a cap holding its
	# easy share: teal at or above the 80/20 line, alarm below. The current
	# week, until the series covers all seven of its days, is judged by
	# neither: its bar and cap are muted and the cap says "so far", since a
	# partial week is not a finished one.

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

	title_text : Str
	title_text = "time in zone, and the 80/20 split"

	hint_text : Str
	hint_text = "zones / load  modes      hover or click a week      TAB  career      R  reload      S  screenshot      V  record      ESC quit"

	key_text : Str
	key_text = "caps: the week's easy share     teal holds 80/20     red breaks it     muted: week still running"

	tot : Db.ZoneWeek -> I64
	tot = |w| w.z1 + w.z2 + w.z3 + w.z4 + w.z5

	# the chart draws once any week holds time in zone
	charted : Ui.Model -> Bool
	charted = |model| !(List.is_empty(model.zone_weeks)) and List.fold(model.zone_weeks, 0.I64, |a, w| a + tot(w)) != 0

	# each week's bar on screen: its slot's centre, its top-left corner and
	# size, scaled to the tallest week
	bars : Ui.Model -> List({ w : Db.ZoneWeek, i : U64, cx : F32, top : F32, box : Labels.Rect })
	bars = |model| {
		n = List.len(model.zone_weeks)
		slot = (model.win.w - pad * 2.0) / U64.to_f32(n)
		bw = F32.min(74.0, slot * 0.60)
		bot = Weeks.bars_bot(model.win.h)
		peak = List.fold(model.zone_weeks, 1.I64, |a, w| if (tot(w) > a) tot(w) else a)
		List.map_with_index(
			model.zone_weeks,
			|w, i| {
				cx = pad + (U64.to_f32(i) + 0.5) * slot
				bh = I64.to_f32(tot(w)) / I64.to_f32(peak) * (bot - Weeks.bars_top)
				{ w, i, cx, top: bot - bh, box: { x: cx - bw / 2.0, y: bot - F32.max(bh, 3.0), w: bw, h: F32.max(bh, 3.0) } }
			},
		)
	}

	# the week the verdict card reads: the newest with classified time
	newest : Ui.Model -> Db.ZoneWeek
	newest = |model| List.fold(model.zone_weeks, { wk: "", days: 7, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0, easy: 0, moderate: 0, hard: 0 }, |acc, w| if (w.easy + w.moderate + w.hard > 0) (w) else acc)

	# the zone key's swatch for zone zi, on its own row clear of every cap
	key_swatch : U64 -> Labels.Rect
	key_swatch = |zi| { x: pad + U64.to_f32(zi) * 42.0, y: 120.0, w: 9.0, h: 9.0 }

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
				[fix(Scene.data("no zone history yet", 14.0, ink_muted), pad, 130.0, Left, panel)]
			} else {
				# this week's verdict, in the form board's KPI card style
				last = newest(model)
				li = last.easy + last.moderate + last.hard
				lc = verdict(last.easy, li, last.days)
				card = Weeks.card_box(win_w)
				wk_lbl = if (last.wk == "") ("no training yet") else if (Weeks.partial(last.days)) "easy so far, wk of ${Weeks.week_label(last.wk)}" else "easy, wk of ${Weeks.week_label(last.wk)}"
				peak = List.fold(model.zone_weeks, 1.I64, |a, w| if (tot(w) > a) tot(w) else a)
				bot = Weeks.bars_bot(win_h)
				per_bar = List.join(
					List.map(
						bars(model),
						|b| {
							itot = b.w.easy + b.w.moderate + b.w.hard
							cap =
								if itot > 0 {
									cb = Weeks.cap_box(b.cx, b.top)
									vc = verdict(b.w.easy, itot, b.w.days)
									List.concat(
										[fix(Scene.data("${I64.to_str(b.w.easy * 100 // itot)}%", 11.0, vc), b.cx, cb.y + 4.0, Center, cb)],
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
						fix(Scene.data(hours(tot(last)), 28.0, Theme.ctl_c), win_w - pad - 16.0, 68.0, Right, card),
						fix(Scene.data("in zones", 11.0, ink_faint), win_w - pad - 16.0, 102.0, Right, card),
						Scene.free(measure, Scene.data(hours(peak), 10.0, ink_faint), [{ x: pad, y: Weeks.bars_top - 14.0, align: Left }], 1, panel),
						fix(Scene.data("0", 10.0, ink_faint), pad, bot - 12.0, Left, panel),
						Weeks.focus_text(model, measure, key_text),
						# which zones the bars were split by, beside the zone key, or
						# under the week labels when a long list of sports would run
						# under the card: a sport without its own bounds is classified
						# by the global ones, so a swimmer's lower heart rate can read
						# as easier than it is
						Scene.kept(measure, Scene.data(zones_note(model.zone_overrides), 10.0, ink_faint), [{ x: pad + 5.0 * 42.0 + 16.0, y: 118.0, align: Left }, { x: pad, y: bot + 28.0, align: Left }], 2, panel),
					],
					List.map([0, 1, 2, 3, 4], |zi| fix(Scene.data("z${U64.to_str(zi + 1)}", 10.0, ink_faint), (key_swatch(zi)).x + 13.0, 118.0, Left, panel)),
					per_bar,
				])
			}
		foot = [fix(Scene.prepared(model.zones_hint, hint_text, 13.0, Prose, ink_faint), pad, win_h - 30.0, Left, panel)]
		List.join([head, chart, foot, Weeks.chip_texts(model, measure)])
	}

	# what the scale's top value keeps off: the chrome, the card, the bars
	# and their caps
	obstacles : Ui.Model, Scene.Measure -> Labels.Obstacles
	obstacles = |model, measure| { boxes: List.concat(Chrome.boxes(model, measure), List.map(marks(model), |m| m.box)), segs: [] }

	# the shapes no text may cover but its own: the pills, the mode chips,
	# the card, the zone key's swatches, and every bar and cap
	marks : Ui.Model -> List(Labels.Mark)
	marks = |model|
		if charted(model) {
			List.join([
				Chrome.marks(model),
				Weeks.chip_marks,
				[{ key: "the verdict card", box: Weeks.card_box(model.win.w) }],
				List.map([0, 1, 2, 3, 4], |zi| { key: "the z${U64.to_str(zi + 1)} swatch", box: key_swatch(zi) }),
				List.join(
					List.map(
						bars(model),
						|b| List.concat(
							[{ key: "the ${b.w.wk} bar", box: b.box }],
							if (b.w.easy + b.w.moderate + b.w.hard > 0) [{ key: "the ${b.w.wk} cap", box: Weeks.cap_box(b.cx, b.top) }] else [],
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
		if charted(model) {
			win_w = model.win.w
			bot = Weeks.bars_bot(model.win.h)
			bars_h = bot - Weeks.bars_top
			peak = List.fold(model.zone_weeks, 1.I64, |a, w| if (tot(w) > a) tot(w) else a)
			card = Weeks.card_box(win_w)
			frame.rounded_rectangle!({ x: card.x, y: card.y, width: card.w, height: card.h, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
			frame.line!({ start: { x: pad, y: bot }, end: { x: win_w - pad, y: bot }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 70), 1) })
			# the zone key rides its own row, clear of every cap
			List.for_each!(
				[0, 1, 2, 3, 4],
				|zi| {
					s = key_swatch(zi)
					frame.rounded_rectangle!({ x: s.x, y: s.y, width: s.w, height: s.h, radius: 2.0, segments: 3, style: Draw.filled((List.get(Theme.zone_ramp, zi)) ?? ink_faint) })
				},
			)
			focus = Weeks.focus_week(model)
			List.for_each!(
				bars(model),
				|b| {
					x0 = b.box.x
					bw = b.box.w
					itot = b.w.easy + b.w.moderate + b.w.hard
					bh = I64.to_f32(tot(b.w)) / I64.to_f32(peak) * bars_h
					hovered = b.w.wk == focus
					# z1 at the base, z5 on top, a hairline of ground between each
					_ = List.fold_try!(
						List.map_with_index([b.w.z1, b.w.z2, b.w.z3, b.w.z4, b.w.z5], |zs, zi| { zs, zi }),
						0.0,
						|yacc, z| {
							seg = I64.to_f32(z.zs) / I64.to_f32(peak) * bars_h
							zc = (List.get(Theme.zone_ramp, z.zi)) ?? ink_faint
							if seg > 1.5 {
								frame.rectangle!({ x: x0, y: bot - yacc - seg, width: bw, height: seg - 1.0, style: Draw.filled(Color.with_alpha(zc, if (hovered) (255.U8) else if (Weeks.partial(b.w.days)) 120 else 235)) })
							}
							Ok(yacc + seg)
						},
					)
					# depth over the whole stack, so the bars sit in the panel
					if bh > 8.0 {
						frame.rectangle_gradient_v!({ x: x0, y: bot - bh, width: bw, height: bh, color_top: Color.with_alpha(Theme.bg, 0), color_bottom: Color.with_alpha(Theme.bg, 90) })
					}
					if (bh > 3.0) {} else {
						frame.rounded_rectangle!({ x: x0, y: bot - 3.0, width: bw, height: 3.0, radius: 1.5, segments: 3, style: Draw.filled(Color.with_alpha(ink_faint, 90)) })
					}
					# the cap: this week's easy share, in its verdict color
					if itot > 0 {
						cb = Weeks.cap_box(b.cx, b.top)
						vc = verdict(b.w.easy, itot, b.w.days)
						frame.rounded_rectangle!({ x: cb.x, y: cb.y, width: cb.w, height: cb.h, radius: 6.0, segments: 5, style: Draw.filled(Color.with_alpha(vc, if (hovered) (70.U8) else 42)) })
					}
				},
			)
		}
		Scene.draw!(frame, model, scene(model, Scene.measure_of(model)))
		Ok({})
	}
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
