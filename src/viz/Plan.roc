import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Plan :: [].{
	# The command-and-progress view: today's prescription answered plainly,
	# the week's ladder with completion state, the load strip, and the coach
	# corner - the bus made visible.
	type_color : Str -> Color.Rgba
	type_color = |typ|
		if typ == "threshold" Theme.tsb_c
		else if typ == "vo2" Theme.atl_c
		else if typ == "endurance" Theme.ctl_c
		else if typ == "strength" (Color.from_hex_rgb(0xd8c27a))
		else Theme.ink_faint

	trunc : Str, U64 -> Str
	trunc = |s, n|
		# n < 3 would wrap the unsigned n - 2; nothing meaningful fits anyway
		if n < 3 s
		else if Str.count_utf8_bytes(s) > n (Str.concat(Str.from_utf8_lossy(List.take_first(Str.to_utf8(s), n - 2)), "..")) else s

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		model.plan_title.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })

		# today's card: the one answer that matters most
		frame.rounded_rectangle!({ x: 36.0, y: 100.0, width: win_w - 72.0, height: 84.0, radius: 10.0, segments: 8, style: Draw.filled(Theme.card) })
		today = List.fold(model.plan, { day: "", typ: "", detail: "no plan for today - ask the coach", rationale: "", done: Bool.False, skipped: Bool.False, today: Bool.False }, |acc, p| if p.today p else acc)
		frame.rounded_rectangle!({ x: 52.0, y: 116.0, width: 10.0, height: 52.0, radius: 4.0, segments: 4, style: Draw.filled(type_color(today.typ)) })
		Text.from("today - ${today.typ}", model.font).size(14).draw!(frame, { pos: { x: 76.0, y: 112.0 }, color: type_color(today.typ), align: (Top, Left) })
		Text.from(trunc(today.detail, 96), model.font).size(13).draw!(frame, { pos: { x: 76.0, y: 134.0 }, color: Color.white, align: (Top, Left) })
		Text.from(trunc(today.rationale, 110), model.font).size(11).draw!(frame, { pos: { x: 76.0, y: 156.0 }, color: ink_faint, align: (Top, Left) })

		# the week's ladder
		List.for_each!(List.map_with_index(model.plan, |p, i| { p, i }), |x| {
			ly = 204.0 + U64.to_f32(x.i) * 30.0
			row_col = if x.p.today (Color.with_alpha(Color.white, 14)) else Color.with_alpha(Color.white, 0)
			if x.p.today {
				frame.rectangle!({ x: 34.0, y: ly - 4.0, width: win_w - 68.0, height: 27.0, style: Draw.filled(row_col) })
			} else {}
			Text.from(x.p.day, model.font).size(12).draw!(frame, { pos: { x: 44.0, y: ly }, color: if x.p.today Color.white else ink_muted, align: (Top, Left) })
			frame.rounded_rectangle!({ x: 150.0, y: ly + 2.0, width: 92.0, height: 16.0, radius: 5.0, segments: 4, style: Draw.filled(Color.with_alpha(type_color(x.p.typ), 45)) })
			Text.from(x.p.typ, model.font).size(11).draw!(frame, { pos: { x: 196.0, y: ly + 3.0 }, color: type_color(x.p.typ), align: (Top, Center) })
			Text.from(trunc(x.p.detail, 64), model.font).size(12).draw!(frame, { pos: { x: 260.0, y: ly }, color: if x.p.today Color.white else ink_muted, align: (Top, Left) })
			status = if x.p.done "done" else if x.p.skipped "skip" else if x.p.today ">>" else ""
			scol = if x.p.done Theme.tsb_c else if x.p.skipped Theme.ink_faint else Theme.ctl_c
			Text.from(status, model.font).size(12).draw!(frame, { pos: { x: win_w - 44.0, y: ly }, color: scol, align: (Top, Right) })
		})

		# progress strip + coach corner
		# the strip speaks Monday-aligned week terms on BOTH sides - the ladder
		# above is forward-looking and cannot count done sessions
		strip = "week: ${I64.to_str(model.plan_week.done)} of ${I64.to_str(model.plan_week.total)} done      ${I64.to_str(model.week_tss.this)} tss (last ${I64.to_str(model.week_tss.last)})"
		Text.from(strip, model.font).size(13).draw!(frame, { pos: { x: 36.0, y: win_h - 84.0 }, color: ink_muted, align: (Top, Left) })
		Text.from("coach: ${model.bus_note}", model.font).size(11).draw!(frame, { pos: { x: 36.0, y: win_h - 60.0 }, color: ink_faint, align: (Top, Left) })
		model.plan_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
