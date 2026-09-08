import rr.Color
import rr.Draw
import rr.Text
import Db
import Theme
import Ui

Table :: [].{
	# The artifact's accessibility table, native: the last 14 days as numbers.
	# Cells draw as immediate text — 70 short strings a frame is nothing to
	# raylib, and preparing them would double the Model for a static view.
	col_x : List(F32)
	col_x = [36.0, 300.0, 430.0, 560.0, 690.0]

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_h = Theme.win_h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		model.table_title.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		List.for_each!(List.map_with_index(model.table_head, |h, i| { h, i }), |x| {
			hx = match List.get(col_x, x.i) { Ok(v) => v
				Err(_) => 36.0 }
			x.h.draw!(frame, { pos: { x: hx, y: 108.0 }, color: ink_faint, align: (Top, Left) })
		})
		# the arrow cursor scrolls the window back through the whole series:
		# cursor N shows the 14 days ending N days before the latest
		total = List.len(model.data)
		back = if model.cursor < 0 (0.U64) else match I64.to_u64_try(model.cursor) {
			Ok(c) => if total > 14 and c > total - 14 (total - 14) else c
			Err(_) => 0.U64
		}
		kept = total - back
		rows = List.take_last(List.take_first(model.data, kept), 14)
		days = List.take_last(List.take_first(model.days, kept), 14)
		pos_note = "days ${U64.to_str(if kept > 14 (kept - 13) else 1)}-${U64.to_str(kept)} of ${U64.to_str(total)}"
		Text.from(pos_note, model.font).size(13).draw!(frame, { pos: { x: I32.to_f32(Theme.win_w) - 34.0, y: 70.0 }, color: ink_muted, align: (Top, Right) })
		List.for_each!(List.map_with_index(rows, |r, i| { r, i }), |x| {
			ry = 134.0 + U64.to_f32(x.i) * 24.0
			day = match List.get(days, x.i) { Ok(d) => d
				Err(_) => "" }
			cells = [day, Db.fmt_f(x.r.ctl), Db.fmt_f(x.r.atl), Db.fmt_f(x.r.tsb), Db.fmt_f(x.r.tss)]
			List.for_each!(List.map_with_index(cells, |c, j| { c, j }), |cell| {
				cx = match List.get(col_x, cell.j) { Ok(v) => v
					Err(_) => 36.0 }
				col = if cell.j == 3 (Theme.tsb_c) else Color.white
				Text.from(cell.c, model.font).size(13).draw!(frame, { pos: { x: cx, y: ry }, color: col, align: (Top, Left) })
			})
		})
		model.table_hint.draw!(frame, { pos: { x: 36.0, y: I32.to_f32(win_h) - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
