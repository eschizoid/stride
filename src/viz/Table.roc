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
	# THE table-window math: one implementation, used by render, row clicks
	# and hover alike, so hit-tests can never drift from what draws. cursor
	# counts days back from the newest; a short series clamps to no scroll.
	window_of : U64, I64 -> { back : U64, kept : U64, rows : U64 }
	window_of = |total, cursor| {
		max_back = if total > 14 (total - 14) else 0.U64
		back = if cursor < 0 (0.U64) else match I64.to_u64_try(cursor) {
			Ok(c) => if c > max_back max_back else c
			Err(_) => 0.U64
		}
		kept = total - back
		{ back, kept, rows: if kept > 14 (14.U64) else kept }
	}

	col_x : List(F32)
	col_x = [36.0, 260.0, 380.0, 490.0, 590.0, 680.0]

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
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
		w = window_of(total, model.cursor)
		kept = w.kept
		rows = List.take_last(List.take_first(model.data, kept), 14)
		days = List.take_last(List.take_first(model.days, kept), 14)
		# no rows, no arithmetic on them — the indicator only speaks over data
		if total > 0 {
			pos_note = "days ${U64.to_str(if kept > 14 (kept - 13) else 1)}-${U64.to_str(kept)} of ${U64.to_str(total)}"
			Text.from(pos_note, model.font).size(13).draw!(frame, { pos: { x: model.win.w - 34.0, y: 70.0 }, color: ink_muted, align: (Top, Right) })
		} else {}
		List.for_each!(List.map_with_index(rows, |r, i| { r, i }), |x| {
			ry = 134.0 + U64.to_f32(x.i) * 24.0
			# the row under the mouse lifts - hover feedback to match the pointer
			row_right = if model.detail_day != "" (win_w / 2.0) else win_w - 40.0
			if model.mouse_y >= ry and model.mouse_y < ry + 24.0 and model.mouse_x >= 36.0 and model.mouse_x <= row_right {
				frame.rectangle!({ x: 34.0, y: ry - 2.0, width: row_right - 34.0, height: 23.0, style: Draw.filled(Color.with_alpha(Color.white, 10)) })
			} else {}
			day = match List.get(days, x.i) { Ok(d) => d
				Err(_) => "" }
			note = Db.note_for(model.day_notes, day)
			short = if Str.count_utf8_bytes(note) > 30 (Str.concat(Str.from_utf8_lossy(List.take_first(Str.to_utf8(note), 28)), "..")) else note
			cells = [day, Db.fmt_f(x.r.ctl), Db.fmt_f(x.r.atl), Db.fmt_f(x.r.tsb), Db.fmt_f(x.r.tss), short]
			# the artifact's row separators
			frame.line!({ start: { x: 36.0, y: ry + 19.0 }, end: { x: win_w - 40.0, y: ry + 19.0 }, stroke: Draw.stroke(Color.with_alpha(Color.white, 14), 1) })
			List.for_each!(List.map_with_index(cells, |c, j| { c, j }), |cell| {
				cx = match List.get(col_x, cell.j) { Ok(v) => v
					Err(_) => 36.0 }
				col = if cell.j == 3 (Theme.tsb_c) else if cell.j == 5 (Theme.ink_muted) else Color.white
				Text.from(cell.c, model.font).size(13).draw!(frame, { pos: { x: cx, y: ry }, color: col, align: (Top, Left) })
			})
		})
		# the day-detail panel: opens over the right half when a row is clicked,
		# same row again closes it. Db delivers structured { title, stats } rows.
		if model.detail_day != "" {
			px = win_w / 2.0
			pw2 = win_w - 36.0 - px
			frame.rounded_rectangle!({ x: px, y: 100.0, width: pw2, height: win_h - 150.0, radius: 10.0, segments: 8, style: Draw.filled(Theme.card) })
			Text.from(model.detail_day, model.font).size(15).draw!(frame, { pos: { x: px + 18.0, y: 116.0 }, color: Color.white, align: (Top, Left) })
			if List.is_empty(model.detail) {
				Text.from("loading...", model.font).size(12).draw!(frame, { pos: { x: px + 18.0, y: 148.0 }, color: ink_muted, align: (Top, Left) })
			} else {}
			# only the lines that fit the panel draw; the tail becomes a count
			fit = match F32.round_to_u64_try(F32.div_floor_by(win_h - 150.0 - 48.0 - 20.0, 44.0)) {
				Ok(f) => if f == 0 (1.U64) else f
				Err(_) => 1.U64
			}
			shown = List.take_first(model.detail, fit)
			List.for_each!(List.map_with_index(shown, |ln, li| { ln, li }), |x| {
				ly = 148.0 + U64.to_f32(x.li) * 44.0
				Text.from(x.ln.title, model.font).size(13).draw!(frame, { pos: { x: px + 18.0, y: ly }, color: Theme.ctl_c, align: (Top, Left) })
				Text.from(x.ln.stats, model.font).size(12).draw!(frame, { pos: { x: px + 18.0, y: ly + 18.0 }, color: ink_muted, align: (Top, Left) })
			})
			hidden = List.len(model.detail) - List.len(shown)
			if hidden > 0 {
				Text.from("+ ${U64.to_str(hidden)} more (enlarge the window)", model.font).size(11).draw!(frame, { pos: { x: px + 18.0, y: 148.0 + U64.to_f32(List.len(shown)) * 44.0 }, color: ink_faint, align: (Top, Left) })
			} else {}
		} else {}
		model.table_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
