import rr.Color
import rr.Draw
import rr.Text
import core.Units
import Career
import Db
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

	ton_label : [Metric, Imperial], F64 -> Str
	ton_label = |units, kg| Career.spine_label(units, F64.round_to_i64_try(kg * 10.0) ?? 0, "tonnage", Db.strength_head)

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
			(Ok(a), Ok(b)) => "${Units.mass_label(units, a.kg)} > ${Units.mass_label(units, b.kg)}"
			_ => ""
		}

	# an F64 ratio drawn in F32 screen space, to four decimals
	f32 : F64 -> F32
	f32 = |v| I64.to_f32(F64.round_to_i64_try(v * 10000.0) ?? 0) / 10000.0

	row_h : F32
	row_h = 26.0

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

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		units = model.units
		sv = model.strength
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		txt! = |s, sz, x, y, c| Text.from(s, model.font).size(sz).draw!(frame, { pos: { x, y }, color: c, align: (Top, Left) })
		txt!("strength - the heaviest weight each lift moved, newest on the right", 15, 36.0, 70.0, ink_muted)

		# ── lifts, the headline
		lift_top = 108.0
		fit_n = match F32.round_to_u64_try(F32.div_floor_by(win_h - 76.0 - lift_top, row_h)) {
			Ok(n) => n
			Err(_) => 0
		}
		if List.is_empty(sv.lifts) {
			txt!("no lift trained on two days with its weight logged yet", 13, 36.0, lift_top, ink_muted)
		} else {
			List.for_each!(
				List.map_with_index(List.take_first(sv.lifts, fit_n), |l, i| { l, i }),
				|x| {
					y = lift_top + U64.to_f32(x.i) * row_h
					name = (List.first(Wrap.fit(x.l.exercise, 22, 1))).ok_or(x.l.exercise)
					txt!(name, 12, 36.0, y, Color.white)
					# sparkline
					sx = 206.0
					sw = 120.0
					kgs = List.map(x.l.points, |p| p.kg)
					lo = List.fold(kgs, 1000000.0, |a, k| F64.min(a, k))
					hi = List.fold(kgs, 0.0, |a, k| F64.max(a, k))
					n = List.len(kgs)
					px = |i| sx + (if (n <= 1) 0.0 else U64.to_f32(i) * sw / U64.to_f32(n - 1))
					py = |k| if (hi - lo < 0.001) y + 8.0 else y + 15.0 - f32((k - lo) / (hi - lo)) * 14.0
					List.for_each!(
						List.map_with_index(List.drop_first(kgs, 1), |k, i| { k, i }),
						|s| {
							prev = (List.get(kgs, s.i)).ok_or(s.k)
							frame.line!({ start: { x: px(s.i), y: py(prev) }, end: { x: px(s.i + 1), y: py(s.k) }, stroke: Draw.stroke(Color.with_alpha(Theme.ctl_c, 200), 1.5) })
						},
					)
					last_k = (List.last(kgs)).ok_or(0.0)
					frame.circle!({ center: { x: px(n - 1), y: py(last_k) }, radius: 2.5, style: Draw.filled(Theme.ctl_c) })
					# direction mark
					ax = 336.0
					match direction(x.l.points) {
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
					txt!(lift_values(units, x.l.points), 12, 354.0, y, ink_muted)
				},
			)
			hidden = List.len(sv.lifts) - U64.min(List.len(sv.lifts), fit_n)
			if hidden > 0 {
				txt!("... ${U64.to_str(hidden)} more - grow the window", 12, 36.0, lift_top + U64.to_f32(fit_n) * row_h, ink_faint)
			}
		}

		# ── right column: the latest session, then the weeks, then tonnage
		rx = 36.0 + left_w(win_w) + 24.0
		rw = win_w - rx - 40.0
		if sv.last.id < 0 {
			txt!("no strength session yet", 13, rx, lift_top, ink_muted)
		} else {
			txt!("last session - ${sv.last.day}", 13, rx, lift_top, Color.white)
			txt!((List.first(Wrap.fit(sv.last.name, 46, 1))).ok_or(""), 12, rx, lift_top + 18.0, ink_faint)
			lines = if (List.is_empty(sv.last.log.rows)) [Trace.no_sets_note(sv.last.log.pasted)] else List.map(List.take_first(sv.last.log.rows, 7), |r| (List.first(Wrap.fit(Trace.set_line(units, r), 46, 1))).ok_or(""))
			List.for_each!(List.map_with_index(lines, |l, i| { l, i }), |x| txt!(x.l, 12, rx, lift_top + 40.0 + U64.to_f32(x.i) * 17.0, ink_muted))
		}

		wk_top = lift_top + 40.0 + 7.0 * 17.0 + 16.0
		txt!("sessions a week: with sets, without", 12, rx, wk_top, ink_muted)
		bars_top = wk_top + 22.0
		bars_h = 56.0
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
					current = x.i == n_w - 1
					a = if (current) 110 else 255
					with_h = I64.to_f32(x.w.with_sets) * unit_h
					without_h = I64.to_f32(x.w.total - x.w.with_sets) * unit_h
					base = bars_top + bars_h
					frame.rectangle!({ x: bx, y: base - with_h, width: bw, height: with_h, style: Draw.filled(Color.with_alpha(strength_c, a)) })
					frame.rectangle!({ x: bx, y: base - with_h - without_h, width: bw, height: without_h, style: Draw.filled(Color.with_alpha(ink_faint, a)) })
					frame.rectangle!({ x: bx, y: base, width: bw, height: 1.0, style: Draw.filled(Color.with_alpha(ink_faint, 120)) })
				},
			)
			txt!("12 weeks ago", 11, rx, bars_top + bars_h + 6.0, ink_faint)
			Text.from("this week so far", model.font).size(11).draw!(frame, { pos: { x: rx + rw, y: bars_top + bars_h + 6.0 }, color: ink_faint, align: (Top, Right) })
		}

		# tonnage: complete measured months joined by a line, a thin month as a
		# hollow point, the month in progress joined dashed and muted
		ton_top = bars_top + bars_h + 34.0
		ton_bottom = win_h - 84.0
		txt!("tonnage - volume, not strength", 12, rx, ton_top, ink_muted)
		chart_top = ton_top + 22.0
		chart_bottom = ton_bottom - 22.0
		ms = sv.tonnage
		n_m = List.len(ms)
		if n_m > 0 and chart_bottom - chart_top >= 30.0 {
			hi = List.fold(ms, 1.0, |a, m| F64.max(a, m.kg))
			mx = |i| rx + (if (n_m <= 1) (rw / 2.0) else U64.to_f32(i) * rw / U64.to_f32(n_m - 1))
			my = |kg| chart_bottom - f32(kg / hi) * (chart_bottom - chart_top)
			List.for_each!(
				List.map_with_index(List.drop_first(ms, 1), |m, i| { m, i }),
				|s| {
					prev = (List.get(ms, s.i)).ok_or(s.m)
					a = { x: mx(s.i), y: my(prev.kg) }
					b = { x: mx(s.i + 1), y: my(s.m.kg) }
					if s.m.partial {
						dashed!(frame, a, b, Color.with_alpha(ink_muted, 160))
					} else if measured(prev) and measured(s.m) {
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
		List.for_each!(List.map_with_index(tonnage_caption(units, ms), |l, i| { l, i }), |x| txt!(x.l, 11, rx, ton_bottom - 10.0 + U64.to_f32(x.i) * 15.0, ink_faint))
		txt!("TAB  zones      R  reload      S  screenshot      V  record      ESC quit", 13, 36.0, win_h - 30.0, ink_faint)
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
expect Strength.lift_values(Imperial, [{ day: "a", kg: 22.6796185 }, { day: "b", kg: 27.2155422 }]) == "50.0 lb > 60.0 lb"
