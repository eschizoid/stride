import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Prs :: [].{
	# The record book: one row per duration rung, a dot where its best-ever
	# landed on the calendar. Fresh records glow; ancient ones fade - the
	# question this view answers is "when did I last get faster".
	pad : F32
	pad = 36.0
	label_w : F32
	label_w = 96.0

	# days between two YYYY-MM-DD strings, coarse (month=30d) - pixel math,
	# not bookkeeping; a day or two of drift is invisible at this scale
	day_num : Str -> F32
	day_num = |dy| {
		b = Str.to_utf8(dy)
		digit = |idx| match List.get(b, idx) { Ok(c) => I64.to_f32(U8.to_i64(c) - 48)
			Err(_) => 0.0 }
		y = digit(0) * 1000.0 + digit(1) * 100.0 + digit(2) * 10.0 + digit(3)
		mo = digit(5) * 10.0 + digit(6)
		d = digit(8) * 10.0 + digit(9)
		y * 365.0 + mo * 30.0 + d
	}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		model.prs_title.draw!(frame, { pos: { x: pad, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		have = List.fold(model.prs, 0.I64, |a, pr| if pr.day != "" (a + 1) else a)
		if List.is_empty(model.prs) or have == 0 {
			Text.from("no power records yet", model.font).size(14).draw!(frame, { pos: { x: pad, y: 130.0 }, color: ink_muted, align: (Top, Left) })
		} else {
			n = List.len(model.prs)
			top = 120.0
			bot = win_h - 96.0
			row_h = (bot - top) / U64.to_f32(n)
			x_lo = pad + label_w
			x_hi = win_w - pad - 90.0
			set_prs = List.keep_if(model.prs, |pr| pr.day != "")
			d_lo = List.fold(set_prs, 9999999.0, |a, pr| F32.min(a, day_num(pr.day)))
			d_hi = List.fold(set_prs, 0.0, |a, pr| F32.max(a, day_num(pr.day)))
			span = F32.max(d_hi - d_lo, 30.0)
			# "fresh" means fresh against the SERIES clock, not the newest record
			# - a May record must not glow teal in September. The heat series is
			# day-ascending, so its last row carries MAX(day).
			d_now = match List.last(model.heat) { Ok(hd) => day_num(hd.day)
				Err(_) => d_hi }

			px_of = |dy| x_lo + (day_num(dy) - d_lo) / span * (x_hi - x_lo)
			# edge dates, so the axis means something
			lo_day = List.fold(set_prs, "", |a, pr| if a == "" or day_num(pr.day) < day_num(a) (pr.day) else a)
			hi_day = List.fold(set_prs, "", |a, pr| if day_num(pr.day) > day_num(a) (pr.day) else a)
			Text.from(lo_day, model.font).size(10).draw!(frame, { pos: { x: x_lo, y: bot + 10.0 }, color: ink_faint, align: (Top, Left) })
			Text.from(hi_day, model.font).size(10).draw!(frame, { pos: { x: x_hi, y: bot + 10.0 }, color: ink_faint, align: (Top, Right) })
			List.for_each!(List.map_with_index(model.prs, |pr, i| { pr, i }), |x| {
				cy = top + (U64.to_f32(x.i) + 0.5) * row_h
				Text.from(x.pr.rung, model.font).size(12).draw!(frame, { pos: { x: pad + label_w - 14.0, y: cy - 7.0 }, color: ink_muted, align: (Top, Right) })
				frame.line!({ start: { x: x_lo, y: cy }, end: { x: x_hi, y: cy }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 40), 1) })
				if x.pr.day == "" {
					Text.from("-", model.font).size(12).draw!(frame, { pos: { x: x_hi + 14.0, y: cy - 7.0 }, color: ink_faint, align: (Top, Left) })
				} else {
					dx = px_of(x.pr.day)
					# recency against the series clock (d_now): within ~90 days
					# glows teal, within ~a year rides the brand blue, older fades
					age = d_now - day_num(x.pr.day)
					dc = if age <= 90.0 (Theme.tsb_c) else if age <= 365.0 (Theme.ctl_c) else ink_faint
					frame.circle!({ center: { x: dx, y: cy }, radius: 5.0, style: Draw.filled(dc) })
					# lowercase w is this window's unit style throughout (the day
					# panel writes "282w np"); uppercase would be the odd one out
					Text.from("${I64.to_str(x.pr.w)}w", model.font).size(12).draw!(frame, { pos: { x: x_hi + 14.0, y: cy - 7.0 }, color: Color.white, align: (Top, Left) })
					# hover the ROW - label and watts included, the y-band is the
					# whole hit target
					if model.mouse_y >= cy - row_h / 2.0 and model.mouse_y < cy + row_h / 2.0 and model.mouse_x >= pad and model.mouse_x <= win_w - pad {
						Text.from("set ${x.pr.day}", model.font).size(11).draw!(frame, { pos: { x: dx, y: cy - 22.0 }, color: ink_muted, align: (Top, Center) })
					} else {}
				}
			})
			{}
		}
		model.prs_hint.draw!(frame, { pos: { x: pad, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
