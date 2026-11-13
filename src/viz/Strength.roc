import rr.Color
import rr.Draw
import core.Units
import Career
import Chrome
import Db
import Labels
import Scene
import Scroll
import Theme
import Trace
import Ui
import Wrap

Strength :: [].{
	# The strength view. Its headline is per lift, the heaviest weight each
	# exercise moved on each day it was trained, because that is where getting
	# stronger shows; tonnage counts volume, and it rises and falls with how
	# many sessions had their sets logged, so it is a small secondary chart
	# that always shows its coverage. Beside the lifts: the latest session's
	# sets and twelve weeks of strength sessions split by whether their sets
	# were logged.

	Dir : [Up, Flat, Down]

	# a lift moved when its latest heaviest weight differs from its first by
	# more than 2%: a plate or dumbbell step is larger than that, a rounding
	# difference between sources is smaller
	direction : List(Db.LiftPt) -> Dir
	direction = |pts|
		match (List.first(pts), List.last(pts)) {
			(Ok(a), Ok(b)) => if (b.kg > a.kg * 1.02) Up else if (b.kg < a.kg * 0.98) Down else Flat
			_ => Flat
		}

	# a month counts as measured when at least half its strength sessions have
	# sets; below that its tonnage says more about logging than lifting
	measured : Db.TonMonth -> Bool
	measured = |m| m.total > 0 and m.covered * 2 >= m.total

	month_name : Str -> Str
	month_name = |ym| {
		mm = Str.from_utf8_lossy(List.drop_first(Str.to_utf8(ym), 5))
		names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
		i = match U64.from_str(mm) {
			Ok(n) if n >= 1 and n <= 12 => n - 1
			_ => 99
		}
		(List.get(names, i)).ok_or(ym)
	}

	# a weight in the view's unit: whole pounds, the way plates and dumbbells
	# are labelled, or kilograms to one decimal
	weight_label : [Metric, Imperial], F64 -> Str
	weight_label = |mass, kg|
		match mass {
			Imperial => "${I64.to_str(F64.round_to_i64_try(kg / Units.lb_kg) ?? 0)} lb"
			Metric => Units.mass_label(Metric, kg)
		}

	# monthly volume: tonnes in kilograms, thousands of pounds in pounds
	ton_label : [Metric, Imperial], F64 -> Str
	ton_label = |mass, kg|
		match mass {
			Imperial => {
				hundreds = F64.round_to_i64_try(kg / Units.lb_kg / 100.0) ?? 0
				"${I64.to_str(hundreds // 10)}.${I64.to_str(hundreds % 10)}k lb"
			}
			Metric => Career.spine_label(Metric, F64.round_to_i64_try(kg * 10.0) ?? 0, "tonnage", Db.strength_head)
		}

	# one stored set run, the trace's set line in this view's unit
	set_text : [Metric, Imperial], Db.SetRow -> Str
	set_text = |mass, r| {
		shape = if (r.hold_s > 0) "${I64.to_str(r.sets)}x${I64.to_str(r.hold_s)}s hold" else "${I64.to_str(r.sets)}x${I64.to_str(r.reps)}"
		w = if (r.kg > 0.0) " @ ${weight_label(mass, r.kg)}" else ""
		name = (List.first(Wrap.fit(r.exercise, 28, 1))).ok_or("")
		"${name}  ${shape}${w}"
	}

	# the muted line under the shown session naming newer sessions that have
	# no sets stored
	unlogged_note : List(Db.Unlogged) -> Str
	unlogged_note = |us|
		match us {
			[] => ""
			[u] => "newer, no sets logged: ${u.day}"
			_ => "newer, no sets logged: ${Str.join_with(List.map(us, |u| u.day), ", ")}"
		}

	# the captions under the tonnage chart: the last complete month and the
	# month in progress, each with its coverage, one per fixed text row, so no
	# value label can land on another and each fits the narrow column
	tonnage_caption : [Metric, Imperial], List(Db.TonMonth) -> List(Str)
	tonnage_caption = |units, ms| {
		done = List.keep_if(ms, |m| !(m.partial))
		cur = List.keep_if(ms, |m| m.partial)
		part = |m, tail| "${month_name(m.month)} ${ton_label(units, m.kg)}${tail}, ${I64.to_str(m.covered)}/${I64.to_str(m.total)} logged"
		a = match List.last(done) {
			Ok(m) => [part(m, "")]
			Err(_) => []
		}
		b = match List.last(cur) {
			Ok(m) => [part(m, " so far")]
			Err(_) => []
		}
		List.concat(a, b)
	}

	lift_values : [Metric, Imperial], List(Db.LiftPt) -> Str
	lift_values = |units, pts|
		match (List.first(pts), List.last(pts)) {
			(Ok(a), Ok(b)) => "${weight_label(units, a.kg)} > ${weight_label(units, b.kg)}"
			_ => ""
		}

	# an F64 ratio drawn in F32 screen space, to four decimals
	f32 : F64 -> F32
	f32 = |v| I64.to_f32(F64.round_to_i64_try(v * 10000.0) ?? 0) / 10000.0

	# the vertical span a lift's sparkline scales to: its own range, but never
	# less than 15% of its heaviest weight, so the rounding between sources
	# (11.3 kg logged, 11.34 kg pasted, both 25 lb) stays a flat line instead
	# of a cliff
	spark_span : F64, F64 -> F64
	spark_span = |lo, hi| F64.max(hi - lo, F64.max(hi * 0.15, 0.001))

	row_h : F32
	row_h = 26.0

	# the lifts list starts here and scrolls (Scroll) when its rows outgrow
	# the room above the footer, less a line for the `more below` hint
	lift_top : F32
	lift_top = 108.0

	lift_room : F32 -> F32
	lift_room = |win_h| (win_h - 76.0 - lift_top - 14.0).max(row_h)

	# the last offset the lifts list may scroll to
	lifts_last : Ui.Model -> U64
	lifts_last = |model| Scroll.last_offset(List.repeat(row_h, List.len(model.strength.lifts)), lift_room(model.win.h))

	# the left column holds the lifts; its width is a share of the window so
	# the right column keeps room for a set line at the minimum width
	left_w : F32 -> F32
	left_w = |win_w| win_w * 0.55

	strength_c : Color.Rgba
	strength_c = Color.from_hex_rgb(0xd8c27a)

	dashed! : Draw.Frame, { x : F32, y : F32 }, { x : F32, y : F32 }, Color.Rgba => {}
	dashed! = |frame, a, b, c|
		List.for_each!(
			[0.0, 0.2, 0.4, 0.6, 0.8],
			|t|
				frame.line!({ start: { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t }, end: { x: a.x + (b.x - a.x) * (t + 0.1), y: a.y + (b.y - a.y) * (t + 0.1) }, stroke: Draw.stroke(c, 2) }),
		)

	title_text : Str
	title_text = "lifts - the heaviest weight each lift moved, newest on the right"

	hint_text : Str
	hint_text = "wheel or up/down  scroll      TAB  zones      R  reload      S  screenshot      V  record      ESC quit"

	# ── the layout the drawing, the scene and the gate share ───────────────
	# the lifts on screen from the scroll offset, each with its row's top,
	# and where the scrollbar and its hints sit
	shown_lifts : Ui.Model -> { rows : List({ l : Db.Lift, y : F32 }), off : U64, n_shown : U64, at : { x : F32, top : F32, bottom : F32, hint_x : F32 } }
	shown_lifts = |model| {
		heights = List.repeat(row_h, List.len(model.strength.lifts))
		room = lift_room(model.win.h)
		off = model.lifts_off.min(Scroll.last_offset(heights, room))
		n_shown = Scroll.shown(heights, off, room)
		{
			rows: List.map_with_index(List.take_first(List.drop_first(model.strength.lifts, off), n_shown), |l, i| { l, y: lift_top + U64.to_f32(i) * row_h }),
			off,
			n_shown,
			at: { x: 36.0 + left_w(model.win.w) - 6.0, top: lift_top, bottom: lift_top + room, hint_x: 36.0 },
		}
	}

	# a lift row's sparkline, last dot included, and its direction mark
	spark_box : F32 -> Labels.Rect
	spark_box = |y| { x: 206.0, y: y - 1.5, w: 122.5, h: 19.0 }

	arrow_box : F32 -> Labels.Rect
	arrow_box = |y| { x: 335.0, y: y + 3.0, w: 12.0, h: 9.0 }

	# the right column: the latest session, then the weeks, then tonnage
	right_x : F32 -> F32
	right_x = |win_w| 36.0 + left_w(win_w) + 24.0

	right_w : F32 -> F32
	right_w = |win_w| win_w - right_x(win_w) - 40.0

	# Below the latest session card sit the weeks chart and then tonnage, each
	# placed from the top of the weeks heading, which the card decides
	bars_top : F32 -> F32
	bars_top = |weeks_top| weeks_top + 22.0

	bars_h : F32
	bars_h = 56.0

	ton_top : F32 -> F32
	ton_top = |weeks_top| bars_top(weeks_top) + bars_h + 34.0

	# the tonnage chart's top and bottom, and whether the window leaves it
	# the least height it draws in
	ton_span : F32, F32 -> { top : F32, bottom : F32, drawn : Bool }
	ton_span = |win_h, weeks_top| {
		top = ton_top(weeks_top) + 22.0
		bottom = win_h - 84.0 - 22.0
		{ top, bottom, drawn: bottom - top >= ton_least }
	}

	ton_least : F32
	ton_least = 30.0

	# a session line's pitch, and the tighter one a long session falls back to
	last_pitch : F32
	last_pitch = 17.0

	tight_pitch : F32
	tight_pitch = 14.0

	# The latest session card: its lines start under the session name (and
	# under the unlogged note when it shows). The card holds seven lines at
	# least, so a short session leaves the charts where they always were.
	# A longer one grows the card down, taking height from the tonnage chart
	# until that chart is down to ton_least: at the full pitch when every
	# line fits that way, else at the tight pitch. Lines past that scroll,
	# with one hint line under them.
	last_card : F32, U64, Bool -> { top : F32, pitch : F32, room : F32, scrolls : Bool, weeks_top : F32 }
	last_card = |win_h, n, note| {
		first_y = if (note) (lift_top + 52.0) else lift_top + 40.0
		least = lift_top + 40.0 + 7.0 * last_pitch + 16.0
		at0 = ton_span(win_h, 0.0)
		most = (at0.bottom - ton_least - at0.top).max(least)
		place = |pitch| (first_y + U64.to_f32(n) * pitch + 16.0).min(most).max(least)
		fits = |pitch| U64.to_f32(n) * pitch <= place(pitch) - 16.0 - first_y
		pitch = if (fits(last_pitch)) last_pitch else tight_pitch
		weeks_top = place(pitch)
		fit = weeks_top - 16.0 - first_y
		if (fits(pitch)) { top: first_y, pitch, room: fit, scrolls: Bool.False, weeks_top }
		else { top: first_y, pitch, room: fit - 14.0, scrolls: Bool.True, weeks_top }
	}

	# the latest session's lines: one per logged exercise, or the one line
	# that says why there are none; empty when there is no session
	last_lines : Ui.Model -> List(Str)
	last_lines = |model| {
		sv = model.strength
		if (sv.last.id < 0) []
		else if (List.is_empty(sv.last.log.rows)) [Trace.no_sets_note(sv.last.log.pasted)]
		else List.map(sv.last.log.rows, |r| (List.first(Wrap.fit(set_text(sv.mass, r), 46, 1))).ok_or(""))
	}

	# what a scrolled card has cut, on the one hint line under its lines
	card_hint : U64, U64, U64 -> Str
	card_hint = |off, n_shown, total| {
		h = Scroll.hidden(off, n_shown, total)
		above = if (h.above > 0) ["${U64.to_str(h.above)} more above"] else []
		below = if (h.below > 0) ["${U64.to_str(h.below)} more below"] else []
		Str.join_with(List.concat(above, below), ", ")
	}

	# the session lines on screen from the card's scroll offset, each with
	# its top, where the card's scrollbar sits, the hint under the lines,
	# and the weeks heading's top under the card
	shown_last : Ui.Model -> { rows : List({ s : Str, y : F32 }), off : U64, n_shown : U64, total : U64, at : { x : F32, top : F32, bottom : F32, hint_x : F32 }, hint : Str, weeks_top : F32 }
	shown_last = |model| {
		lines = last_lines(model)
		total = List.len(lines)
		card = last_card(model.win.h, total, unlogged_note(model.strength.unlogged) != "")
		heights = List.repeat(card.pitch, total)
		off = model.last_off.min(Scroll.last_offset(heights, card.room))
		n_shown = Scroll.shown(heights, off, card.room)
		rx = right_x(model.win.w)
		{
			rows: List.map_with_index(List.take_first(List.drop_first(lines, off), n_shown), |s, i| { s, y: card.top + U64.to_f32(i) * card.pitch }),
			off,
			n_shown,
			total,
			at: { x: rx + right_w(model.win.w) + 8.0, top: card.top, bottom: card.top + card.room, hint_x: rx },
			hint: card_hint(off, n_shown, total),
			weeks_top: card.weeks_top,
		}
	}

	# the last offset the session card may scroll to
	last_last : Ui.Model -> U64
	last_last = |model| {
		total = List.len(last_lines(model))
		card = last_card(model.win.h, total, unlogged_note(model.strength.unlogged) != "")
		Scroll.last_offset(List.repeat(card.pitch, total), card.room)
	}

	# ── every string the view writes, placed ───────────────────────────────
	# All of it is fixed: the title, each lift's name and values, the scroll
	# hints, the latest session, the weeks chart's captions, the tonnage
	# captions and the footer.
	scene : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	scene = |model, measure| Labels.place(texts(model, measure), { boxes: Chrome.boxes(model, measure), segs: [] })

	# the view's text and the chrome's, as the gate judges them
	owned : Ui.Model, Scene.Measure -> List(Labels.Owned)
	owned = |model, measure| List.concat(Scene.owned(Chrome.placed(model, measure)), Scene.owned(scene(model, measure)))

	texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	texts = |model, measure| {
		win_w = model.win.w
		win_h = model.win.h
		panel = Labels.panel(model.win)
		# the view's own unit: config units when set, else what the stored
		# weights were entered in (Db.mass_units)
		units = model.strength.mass
		sv = model.strength
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		txt = |s, sz, x, y, c| Scene.fixed(measure, Scene.data(s, sz, c), { x, y, align: Left }, panel)
		# ── lifts, the headline
		s = shown_lifts(model)
		lifts =
			if List.is_empty(sv.lifts) {
				[txt("no lift trained on two days with its weight logged yet", 13.0, 36.0, lift_top, ink_muted)]
			} else {
				List.concat(
					List.join(List.map(s.rows, |r| [txt((List.first(Wrap.fit(r.l.exercise, 22, 1))).ok_or(r.l.exercise), 12.0, 36.0, r.y, Color.white), txt(lift_values(units, r.l.points), 12.0, 354.0, r.y, ink_muted)])),
					Scroll.hints(measure, s.at, s.off, s.n_shown, List.len(sv.lifts), panel),
				)
			}
		rx = right_x(win_w)
		rw = right_w(win_w)
		sl = shown_last(model)
		weeks_top = sl.weeks_top
		last =
			if sv.last.id < 0 {
				[txt("no strength session yet", 13.0, rx, lift_top, ink_muted)]
			} else {
				head = if (List.is_empty(sv.last.log.rows)) "last session - ${sv.last.day}" else "last logged session - ${sv.last.day}"
				note = unlogged_note(sv.unlogged)
				List.join([
					[txt(head, 13.0, rx, lift_top, Color.white), txt((List.first(Wrap.fit(sv.last.name, 46, 1))).ok_or(""), 12.0, rx, lift_top + 18.0, ink_faint)],
					if (note == "") [] else [txt((List.first(Wrap.fit(note, 46, 1))).ok_or(""), 11.0, rx, lift_top + 34.0, ink_faint)],
					List.map(sl.rows, |r| txt(r.s, 12.0, rx, r.y, ink_muted)),
					if (sl.hint == "") [] else [Scene.fixed(measure, Scene.data(sl.hint, 10.0, ink_faint), { x: rx, y: sl.at.bottom + 2.0, align: Left }, panel)],
				])
			}
		weeks =
			if List.is_empty(sv.weeks) {
				[]
			} else {
				[
					txt("12 weeks ago", 11.0, rx, bars_top(weeks_top) + bars_h + 6.0, ink_faint),
					Scene.fixed(measure, Scene.data("this week so far", 11.0, ink_faint), { x: rx + rw, y: bars_top(weeks_top) + bars_h + 6.0, align: Right }, panel),
				]
			}
		ton_bottom = win_h - 84.0
		List.join([
			[txt(title_text, 15.0, 36.0, 70.0, ink_muted)],
			lifts,
			last,
			[txt("sessions a week: with sets, without", 12.0, rx, weeks_top, ink_muted)],
			weeks,
			[txt("tonnage - volume, not strength", 12.0, rx, ton_top(weeks_top), ink_muted)],
			List.map_with_index(tonnage_caption(units, sv.tonnage), |l, i| txt(l, 11.0, rx, ton_bottom - 10.0 + U64.to_f32(i) * 15.0, ink_faint)),
			[txt(hint_text, 13.0, 36.0, win_h - 30.0, ink_faint)],
		])
	}

	# the shapes no text may cover: the pills, each lift's sparkline and
	# direction mark, both scrollbars, the weeks chart and the tonnage chart
	marks : Ui.Model -> List(Labels.Mark)
	marks = |model| {
		s = shown_lifts(model)
		h = Scroll.hidden(s.off, s.n_shown, List.len(model.strength.lifts))
		sl = shown_last(model)
		hl = Scroll.hidden(sl.off, sl.n_shown, sl.total)
		rx = right_x(model.win.w)
		rw = right_w(model.win.w)
		ton = ton_span(model.win.h, sl.weeks_top)
		List.join([
			Chrome.marks(model),
			List.join(List.map(s.rows, |r| [{ key: "the ${r.l.exercise} sparkline", box: spark_box(r.y) }, { key: "the ${r.l.exercise} direction", box: arrow_box(r.y) }])),
			if (h.above == 0 and h.below == 0) [] else [{ key: "the scrollbar", box: { x: s.at.x, y: s.at.top, w: 3.0, h: s.at.bottom - s.at.top } }],
			if (hl.above == 0 and hl.below == 0) [] else [{ key: "the session card's scrollbar", box: { x: sl.at.x, y: sl.at.top, w: 3.0, h: sl.at.bottom - sl.at.top } }],
			if (List.is_empty(model.strength.weeks)) [] else [{ key: "the weeks chart", box: { x: rx, y: bars_top(sl.weeks_top), w: rw, h: bars_h + 1.0 } }],
			if (List.is_empty(model.strength.tonnage) or !(ton.drawn)) [] else [{ key: "the tonnage chart", box: { x: rx - 3.5, y: ton.top - 3.5, w: rw + 7.0, h: ton.bottom - ton.top + 7.0 } }],
		])
	}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		win_w = model.win.w
		sv = model.strength
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		s = shown_lifts(model)
		List.for_each!(
			s.rows,
			|r| {
				y = r.y
				# sparkline
				sx = 206.0
				sw = 120.0
				kgs = List.map(r.l.points, |p| p.kg)
				lo = List.fold(kgs, 1000000.0, |a, k| F64.min(a, k))
				hi = List.fold(kgs, 0.0, |a, k| F64.max(a, k))
				n = List.len(kgs)
				px = |i| sx + (if (n <= 1) 0.0 else U64.to_f32(i) * sw / U64.to_f32(n - 1))
				py = |k| y + 15.0 - f32((k - lo) / spark_span(lo, hi)) * 14.0
				List.for_each!(
					List.map_with_index(List.drop_first(kgs, 1), |k, i| { k, i }),
					|e| {
						prev = (List.get(kgs, e.i)).ok_or(e.k)
						frame.line!({ start: { x: px(e.i), y: py(prev) }, end: { x: px(e.i + 1), y: py(e.k) }, stroke: Draw.stroke(Color.with_alpha(Theme.ctl_c, 200), 1.5) })
					},
				)
				frame.circle!({ center: { x: px(n - 1), y: py((List.last(kgs)).ok_or(0.0)) }, radius: 2.5, style: Draw.filled(Theme.ctl_c) })
				# direction mark
				ax = 336.0
				match direction(r.l.points) {
					Up => {
						frame.line!({ start: { x: ax, y: y + 11.0 }, end: { x: ax + 5.0, y: y + 4.0 }, stroke: Draw.stroke(Theme.tsb_c, 2) })
						frame.line!({ start: { x: ax + 5.0, y: y + 4.0 }, end: { x: ax + 10.0, y: y + 11.0 }, stroke: Draw.stroke(Theme.tsb_c, 2) })
					}
					Down => {
						frame.line!({ start: { x: ax, y: y + 4.0 }, end: { x: ax + 5.0, y: y + 11.0 }, stroke: Draw.stroke(Theme.alarm_c, 2) })
						frame.line!({ start: { x: ax + 5.0, y: y + 11.0 }, end: { x: ax + 10.0, y: y + 4.0 }, stroke: Draw.stroke(Theme.alarm_c, 2) })
					}
					Flat => frame.line!({ start: { x: ax, y: y + 8.0 }, end: { x: ax + 10.0, y: y + 8.0 }, stroke: Draw.stroke(ink_muted, 2) })
				}
			},
		)
		if !(List.is_empty(sv.lifts)) {
			Scroll.draw!(frame, s.at, s.off, s.n_shown, List.len(sv.lifts))
		}
		rx = right_x(win_w)
		rw = right_w(win_w)
		sl = shown_last(model)
		Scroll.draw!(frame, sl.at, sl.off, sl.n_shown, sl.total)
		n_w = List.len(sv.weeks)
		if n_w > 0 {
			gap = 4.0
			bw = (rw - gap * U64.to_f32(n_w - 1)) / U64.to_f32(n_w)
			top_n = List.fold(sv.weeks, 3, |a, w| I64.max(a, w.total))
			unit_h = bars_h / I64.to_f32(top_n)
			List.for_each!(
				List.map_with_index(sv.weeks, |w, i| { w, i }),
				|x| {
					bx = rx + U64.to_f32(x.i) * (bw + gap)
					a = if (x.i == n_w - 1) 110 else 255
					with_h = I64.to_f32(x.w.with_sets) * unit_h
					without_h = I64.to_f32(x.w.total - x.w.with_sets) * unit_h
					base = bars_top(sl.weeks_top) + bars_h
					frame.rectangle!({ x: bx, y: base - with_h, width: bw, height: with_h, style: Draw.filled(Color.with_alpha(strength_c, a)) })
					frame.rectangle!({ x: bx, y: base - with_h - without_h, width: bw, height: without_h, style: Draw.filled(Color.with_alpha(ink_faint, a)) })
					frame.rectangle!({ x: bx, y: base, width: bw, height: 1.0, style: Draw.filled(Color.with_alpha(ink_faint, 120)) })
				},
			)
		}
		# tonnage: complete measured months joined by a line, a thin month as a
		# hollow point, the month in progress joined dashed and muted
		ms = sv.tonnage
		n_m = List.len(ms)
		ton = ton_span(model.win.h, sl.weeks_top)
		if n_m > 0 and ton.drawn {
			hi = List.fold(ms, 1.0, |a, m| F64.max(a, m.kg))
			mx = |i| rx + (if (n_m <= 1) (rw / 2.0) else U64.to_f32(i) * rw / U64.to_f32(n_m - 1))
			my = |kg| ton.bottom - f32(kg / hi) * (ton.bottom - ton.top)
			List.for_each!(
				List.map_with_index(List.drop_first(ms, 1), |m, i| { m, i }),
				|e| {
					prev = (List.get(ms, e.i)).ok_or(e.m)
					a = { x: mx(e.i), y: my(prev.kg) }
					b = { x: mx(e.i + 1), y: my(e.m.kg) }
					if e.m.partial {
						dashed!(frame, a, b, Color.with_alpha(ink_muted, 160))
					} else if measured(prev) and measured(e.m) {
						frame.line!({ start: a, end: b, stroke: Draw.stroke(Color.with_alpha(strength_c, 220), 2) })
					} else {
						dashed!(frame, a, b, Color.with_alpha(ink_faint, 140))
					}
				},
			)
			List.for_each!(
				List.map_with_index(ms, |m, i| { m, i }),
				|x| {
					c = { x: mx(x.i), y: my(x.m.kg) }
					if x.m.partial or !(measured(x.m)) {
						frame.circle!({ center: c, radius: 3.5, style: Draw.filled(Color.with_alpha(ink_faint, 200)) })
						frame.circle!({ center: c, radius: 2.0, style: Draw.filled(Theme.panel) })
					} else {
						frame.circle!({ center: c, radius: 3.0, style: Draw.filled(strength_c) })
					}
				},
			)
		}
		Scene.draw!(frame, model, scene(model, Scene.measure_of(model)))
		Ok({})
	}
}

expect Strength.direction([{ day: "a", kg: 22.68 }, { day: "b", kg: 27.22 }]) == Up
expect Strength.direction([{ day: "a", kg: 11.34 }, { day: "b", kg: 11.34 }]) == Flat
expect Strength.direction([{ day: "a", kg: 12.70 }, { day: "b", kg: 9.98 }]) == Down
expect Strength.direction([]) == Flat
# half the sessions logged is the bar a month's tonnage needs
expect Strength.measured({ month: "2026-10", kg: 1.0, covered: 5, total: 10, partial: Bool.False })
expect !(Strength.measured({ month: "2026-08", kg: 1.0, covered: 3, total: 7, partial: Bool.False }))
expect Strength.month_name("2026-11") == "nov" and Strength.month_name("bad") == "bad"
# the caption names the last complete month and the month in progress, each
# with its coverage, on one fixed row
expect Strength.tonnage_caption(Metric, [{ month: "2026-10", kg: 18400.0, covered: 6, total: 10, partial: Bool.False }, { month: "2026-11", kg: 3300.0, covered: 1, total: 3, partial: Bool.True }]) == ["oct 18.4t, 6/10 logged", "nov 3.3t so far, 1/3 logged"]
expect Strength.tonnage_caption(Imperial, [{ month: "2026-10", kg: 8346.0, covered: 6, total: 10, partial: Bool.False }]) == ["oct 18.4k lb, 6/10 logged"]
expect Strength.lift_values(Imperial, [{ day: "a", kg: 22.6796185 }, { day: "b", kg: 27.2155422 }]) == "50 lb > 60 lb"
# pounds round to whole pounds; kilograms keep one decimal
expect Strength.weight_label(Imperial, 11.3398) == "25 lb" and Strength.weight_label(Metric, 11.3398) == "11.3 kg"
expect Strength.ton_label(Imperial, 8346.0) == "18.4k lb" and Strength.ton_label(Metric, 18400.0) == "18.4t"
expect Strength.set_text(Imperial, { exercise: "Curl", sets: 3, reps: 8, kg: 11.3398, hold_s: 0 }) == "Curl  3x8 @ 25 lb"
expect Strength.set_text(Imperial, { exercise: "Curl", sets: 3, reps: 0, kg: 9.0718474, hold_s: 60 }) == "Curl  3x60s hold @ 20 lb"
# the newer unlogged sessions are named on one muted line
expect Strength.unlogged_note([]) == "" and Strength.unlogged_note([{ day: "2026-11-07", name: "a" }]) == "newer, no sets logged: 2026-11-07"
expect Strength.unlogged_note([{ day: "2026-11-07", name: "a" }, { day: "2026-11-04", name: "b" }]) == "newer, no sets logged: 2026-11-07, 2026-11-04"
# at the minimum layout (the default window at the default scale) a short
# session leaves the charts where seven lines put them, and eight lines
# still fit at the full pitch, moving the charts down by one line
expect {
	six = Strength.last_card(600.0, 6, Bool.False)
	seven = Strength.last_card(600.0, 7, Bool.False)
	eight = Strength.last_card(600.0, 8, Bool.False)
	six.weeks_top == seven.weeks_top
		and !(eight.scrolls)
		and eight.pitch == Strength.last_pitch
		and eight.weeks_top == seven.weeks_top + Strength.last_pitch
}
# ten and eleven lines fit there at the tight pitch, the eleven even under
# the unlogged note, whose line pushes the card's lines down
expect {
	ten = Strength.last_card(600.0, 10, Bool.False)
	eleven = Strength.last_card(600.0, 11, Bool.True)
	!(ten.scrolls)
		and ten.pitch == Strength.tight_pitch
		and !(eleven.scrolls)
		and eleven.top > ten.top
}
# twelve lines scroll there, after the tonnage chart has given all but its
# least height; a taller window holds them at the full pitch
expect {
	twelve = Strength.last_card(600.0, 12, Bool.False)
	ton = Strength.ton_span(600.0, twelve.weeks_top)
	tall = Strength.last_card(900.0, 12, Bool.False)
	twelve.scrolls
		and (ton.bottom - ton.top - Strength.ton_least).abs() < 0.01
		and ton.drawn
		and !(tall.scrolls)
		and tall.pitch == Strength.last_pitch
}
# the hint names what the scroll has cut on each side
expect Strength.card_hint(0, 9, 12) == "3 more below" and Strength.card_hint(2, 9, 12) == "2 more above, 1 more below" and Strength.card_hint(3, 9, 12) == "3 more above" and Strength.card_hint(0, 8, 8) == ""
# a rounding difference between sources draws flat; a real step keeps its size
expect Strength.spark_span(11.3, 11.3398) > 1.6 and Strength.spark_span(9.0, 13.6) == 4.6
