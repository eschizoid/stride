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

	# greedy word wrap: every line at most n bytes, words never split (a word
	# longer than n gets its own overlong line - the ASCII details this view
	# renders never produce one). The full prescription is the point of this
	# view, so text wraps instead of truncating.
	wrap : Str, U64 -> List(Str)
	wrap = |s, n| {
		words = Str.split_on(s, " ")
		folded = List.fold(words, { lines: [], cur: "" }, |acc, w|
			if acc.cur == "" { lines: acc.lines, cur: w }
			else if Str.count_utf8_bytes(acc.cur) + 1 + Str.count_utf8_bytes(w) <= n { lines: acc.lines, cur: "${acc.cur} ${w}" }
			else { lines: List.append(acc.lines, acc.cur), cur: w })
		if folded.cur == "" folded.lines else List.append(folded.lines, folded.cur)
	}

	# monospace columns that fit a span of pixels at the given glyph advance;
	# floors at 24 so a tiny window still wraps instead of over-packing
	cols_for : F32, F32 -> U64
	cols_for = |px, adv|
		match F32.to_u64_try((px / adv).max(24.0)) { Ok(c) => c
			Err(_) => 24 }

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		model.plan_title.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })

		# today's card: the one answer that matters most, in full - the card
		# grows with the wrapped prescription instead of truncating it
		today = List.fold(model.plan, { day: "", typ: "", detail: "no plan for today - ask the coach", rationale: "", done: Bool.False, skipped: Bool.False, today: Bool.False }, |acc, p| if p.today p else acc)
		card_cols = cols_for(win_w - 160.0, 7.8)
		# the card is bounded even though coach-written details are not: past
		# these caps the tail collapses to an ellipsis line, so a pathological
		# prescription can never push the ladder past the overflow floor
		cap = |lines, k| if List.len(lines) > k (List.append(List.take_first(lines, k - 1), "…")) else lines
		dlines = cap(wrap(today.detail, card_cols), 6)
		rlines = cap(wrap(today.rationale, card_cols + 8), 3)
		nd = U64.to_f32(List.len(dlines))
		nr = U64.to_f32(List.len(rlines))
		card_h = 46.0 + nd * 19.0 + nr * 16.0 + 14.0
		frame.rounded_rectangle!({ x: 36.0, y: 100.0, width: win_w - 72.0, height: card_h, radius: 10.0, segments: 8, style: Draw.filled(Theme.card) })
		frame.rounded_rectangle!({ x: 52.0, y: 116.0, width: 10.0, height: card_h - 32.0, radius: 4.0, segments: 4, style: Draw.filled(type_color(today.typ)) })
		Text.from("today - ${today.typ}", model.font).size(14).draw!(frame, { pos: { x: 76.0, y: 112.0 }, color: type_color(today.typ), align: (Top, Left) })
		List.for_each!(List.map_with_index(dlines, |ln, i| { ln, i }), |d|
			Text.from(d.ln, model.font).size(13).draw!(frame, { pos: { x: 76.0, y: 134.0 + U64.to_f32(d.i) * 19.0 }, color: Color.white, align: (Top, Left) }))
		List.for_each!(List.map_with_index(rlines, |ln, i| { ln, i }), |r|
			Text.from(r.ln, model.font).size(11).draw!(frame, { pos: { x: 76.0, y: 134.0 + nd * 19.0 + 4.0 + U64.to_f32(r.i) * 16.0 }, color: ink_faint, align: (Top, Left) }))

		# the week's ladder: rows grow to hold their whole prescription. An
		# overflow guard stops above the progress strip and says how many rows
		# it hid - a clipped ladder must say so, not shed rows silently.
		row_cols = cols_for(win_w - 340.0, 7.2)
		ladder_top = 100.0 + card_h + 20.0
		floor_y = win_h - 130.0
		end = List.fold_try!(List.map_with_index(model.plan, |p, i| { p, i }), { y: ladder_top, hidden: 0.U64 }, |acc, x| {
			lines = wrap(x.p.detail, row_cols)
			row_h = (U64.to_f32(List.len(lines)) * 18.0 + 12.0).max(30.0)
			if acc.hidden > 0 or acc.y + row_h > floor_y Ok({ y: acc.y, hidden: acc.hidden + 1 })
			else {
				ly = acc.y
				if x.p.today {
					frame.rectangle!({ x: 34.0, y: ly - 4.0, width: win_w - 68.0, height: row_h - 3.0, style: Draw.filled(Color.with_alpha(Color.white, 14)) })
				} else {}
				Text.from(x.p.day, model.font).size(12).draw!(frame, { pos: { x: 44.0, y: ly }, color: if x.p.today Color.white else ink_muted, align: (Top, Left) })
				frame.rounded_rectangle!({ x: 150.0, y: ly + 2.0, width: 92.0, height: 16.0, radius: 5.0, segments: 4, style: Draw.filled(Color.with_alpha(type_color(x.p.typ), 45)) })
				Text.from(x.p.typ, model.font).size(11).draw!(frame, { pos: { x: 196.0, y: ly + 3.0 }, color: type_color(x.p.typ), align: (Top, Center) })
				List.for_each!(List.map_with_index(lines, |ln, i| { ln, i }), |d|
					Text.from(d.ln, model.font).size(12).draw!(frame, { pos: { x: 260.0, y: ly + U64.to_f32(d.i) * 18.0 }, color: if x.p.today Color.white else ink_muted, align: (Top, Left) }))
				status = if x.p.done "done" else if x.p.skipped "skip" else if x.p.today ">>" else ""
				scol = if x.p.done Theme.tsb_c else if x.p.skipped Theme.ink_faint else Theme.ctl_c
				Text.from(status, model.font).size(12).draw!(frame, { pos: { x: win_w - 44.0, y: ly }, color: scol, align: (Top, Right) })
				Ok({ y: ly + row_h, hidden: acc.hidden })
			}
		})?
		if end.hidden > 0 {
			Text.from("… ${U64.to_str(end.hidden)} more - grow the window", model.font).size(11).draw!(frame, { pos: { x: 260.0, y: (end.y).min(floor_y) }, color: ink_faint, align: (Top, Left) })
		} else {}

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
