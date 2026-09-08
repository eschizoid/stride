import rr.Color
import rr.Draw
import rr.Text
import Db
import Theme
import Ui

Heat :: [].{
	# The contributions-style load calendar: one cell per day, columns are
	# Monday-started weeks, intensity is TSS against the shown window's max.
	# As many weeks as the width holds, newest at the right edge.
	cell : F32
	cell = 16.0
	gap : F32
	gap = 3.0

	# %w gives 0=Sun..6=Sat; rows run Monday-first
	row_of : I64 -> I64
	row_of = |dow| if dow == 0 (6) else dow - 1

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		model.heat_title.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		if List.is_empty(model.heat) {
			Text.from("no training history yet", model.font).size(14).draw!(frame, { pos: { x: 36.0, y: 130.0 }, color: ink_muted, align: (Top, Left) })
		} else {
			step = cell + gap
			weeks_fit = match F32.round_to_u64_try(F32.div_floor_by(win_w - 120.0, step)) {
				Ok(wk) => if wk < 4 (4.U64) else if wk > 53 (53.U64) else wk
				Err(_) => 13.U64
			}
			# the newest `weeks_fit` weeks: drop leading days until the first
			# Monday inside the kept span, so columns align
			max_days = weeks_fit * 7
			kept = if List.len(model.heat) > max_days (List.take_last(model.heat, max_days)) else model.heat
			skip_to_monday = List.fold(List.map_with_index(kept, |h, i| { h, i }), 0.U64, |acc, x|
				if acc == 0 and row_of(x.h.dow) == 0 (x.i + 1) else acc)
			days = if skip_to_monday > 0 (List.drop_first(kept, skip_to_monday - 1)) else kept
			peak = List.fold(days, 1, |a, h| if h.tss > a h.tss else a)
			gx = 96.0
			gy = 130.0
			# weekday labels
			List.for_each!([{ t: "mon", r: 0 }, { t: "wed", r: 2 }, { t: "fri", r: 4 }], |lb|
				Text.from(lb.t, model.font).size(10).draw!(frame, { pos: { x: gx - 10.0, y: gy + I64.to_f32(lb.r) * step + 3.0 }, color: ink_faint, align: (Top, Right) }))
			# cells: week advances when the row wraps past Sunday
			_ = List.fold(days, { col: 0.U64, prev_row: -1 }, |acc, h| {
				r = row_of(h.dow)
				col2 = if r <= acc.prev_row (acc.col + 1) else acc.col
				x0 = gx + U64.to_f32(col2) * step
				y0 = gy + I64.to_f32(r) * step
				# five intensity buckets on the brand blue; zero stays a socket
				a = if h.tss <= 0 (0) else {
					q = h.tss * 4 // peak
					if q >= 4 (255) else 60 + q * 48
				}
				sty = if a == 0 (Draw.filled(Theme.card)) else Draw.filled(Color.with_alpha(Theme.ctl_c, (match I64.to_u8_try(a) { Ok(v) => v
					Err(_) => 255 })))
				frame.rounded_rectangle!({ x: x0, y: y0, width: cell, height: cell, radius: 3.0, segments: 3, style: sty })
				# month tick on the first row cell of a new month (day ends -01)
				if r == 0 and Str.ends_with(h.day, "-01") {
					Text.from(Str.from_utf8_lossy(List.take_first(List.drop_first(Str.to_utf8(h.day), 5), 2)), model.font).size(10).draw!(frame, { pos: { x: x0, y: gy - 16.0 }, color: ink_faint, align: (Top, Left) })
				} else {}
				# hover: tooltip with the day's story
				if model.mouse_x >= x0 and model.mouse_x < x0 + cell and model.mouse_y >= y0 and model.mouse_y < y0 + cell {
					note = Db.note_for(model.day_notes, h.day)
					tip = "${h.day}   ${I64.to_str(h.tss)} tss   ${note}"
					tip_short = if Str.count_utf8_bytes(tip) > 70 (Str.concat(Str.from_utf8_lossy(List.take_first(Str.to_utf8(tip), 68)), "..")) else tip
					frame.rounded_rectangle!({ x: 96.0, y: gy + 7.0 * step + 18.0, width: win_w - 132.0, height: 26.0, radius: 6.0, segments: 5, style: Draw.filled(Theme.card) })
					Text.from(tip_short, model.font).size(12).draw!(frame, { pos: { x: 108.0, y: gy + 7.0 * step + 24.0 }, color: Color.white, align: (Top, Left) })
				} else {}
				{ col: col2, prev_row: r }
			})
			{}
		}
		model.heat_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
