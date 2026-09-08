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
	# how many rows this window height holds: header at 134, 24px rows, and
	# 70px reserved for the hint. Never fewer than 5, so a tiny window still
	# shows something scrollable.
	# where the open detail panel begins, minus breathing room - THE boundary
	# every table element and every hit-test shares, at any window width
	panel_edge : F32 -> F32
	panel_edge = |win_w| {
		pw2 = if win_w / 2.0 < 480.0 (win_w / 2.0 - 36.0) else 480.0
		win_w - 36.0 - pw2 - 24.0
	}

	rows_fit : F32 -> U64
	rows_fit = |win_h| {
		avail = win_h - 134.0 - 70.0
		match F32.round_to_u64_try(F32.div_floor_by(avail, 24.0)) {
			Ok(r) => if r < 5 (5.U64) else r
			Err(_) => 5.U64
		}
	}

	# THE table-window math: one implementation, used by render, row clicks
	# and hover alike, so hit-tests can never drift from what draws. cursor
	# counts days back from the newest; a short series clamps to no scroll.
	# fit comes from rows_fit(win.h) at every call site.
	window_of : U64, I64, U64 -> { back : U64, kept : U64, rows : U64 }
	window_of = |total, cursor, fit| {
		max_back = if total > fit (total - fit) else 0.U64
		back = if cursor < 0 (0.U64) else match I64.to_u64_try(cursor) {
			Ok(c) => if c > max_back max_back else c
			Err(_) => 0.U64
		}
		kept = total - back
		{ back, kept, rows: if kept > fit fit else kept }
	}

	col_x : List(F32)
	col_x = [36.0, 260.0, 380.0, 490.0, 590.0, 680.0]

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		# master-detail: with the panel open, the whole table lives left of it -
		# no element draws underneath the card
		edge = if model.detail_day != "" (panel_edge(win_w)) else win_w - 40.0
		model.table_title.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		List.for_each!(List.map_with_index(model.table_head, |h, i| { h, i }), |x| {
			hx = match List.get(col_x, x.i) { Ok(v) => v
				Err(_) => 36.0 }
			if hx < edge - 60.0 {
				x.h.draw!(frame, { pos: { x: hx, y: 108.0 }, color: ink_faint, align: (Top, Left) })
			} else {}
		})
		# the arrow cursor scrolls the window back through the whole series:
		# cursor N shows the 14 days ending N days before the latest
		total = List.len(model.data)
		fit = rows_fit(win_h)
		w = window_of(total, model.cursor, fit)
		kept = w.kept
		rows = List.take_last(List.take_first(model.data, kept), fit)
		days = List.take_last(List.take_first(model.days, kept), fit)
		# no rows, no arithmetic on them — the indicator only speaks over data
		if total > 0 {
			pos_note = "days ${U64.to_str(if kept > fit (kept - fit + 1) else 1)}-${U64.to_str(kept)} of ${U64.to_str(total)}"
			Text.from(pos_note, model.font).size(13).draw!(frame, { pos: { x: model.win.w - 34.0, y: 70.0 }, color: ink_muted, align: (Top, Right) })
		} else {}
		List.for_each!(List.map_with_index(rows, |r, i| { r, i }), |x| {
			ry = 134.0 + U64.to_f32(x.i) * 24.0
			# the row under the mouse lifts - hover feedback to match the pointer
			row_right = edge
			if model.mouse_y >= ry and model.mouse_y < ry + 24.0 and model.mouse_x >= 36.0 and model.mouse_x < row_right {
				frame.rectangle!({ x: 34.0, y: ry - 2.0, width: row_right - 34.0, height: 23.0, style: Draw.filled(Color.with_alpha(Color.white, 10)) })
			} else {}
			day = match List.get(days, x.i) { Ok(d) => d
				Err(_) => "" }
			note = Db.note_for(model.day_notes, day)
			# the session column runs to the table's right edge; ~8px per mono
			# glyph at this size
			budget = match F32.round_to_u64_try(F32.div_floor_by(edge - 690.0, 8.0)) {
				Ok(b) => if b < 12 (12.U64) else b
				Err(_) => 30.U64
			}
			short = if Str.count_utf8_bytes(note) > budget (Str.concat(Str.from_utf8_lossy(List.take_first(Str.to_utf8(note), budget - 2)), "..")) else note
			cells = [day, Db.fmt_f(x.r.ctl), Db.fmt_f(x.r.atl), Db.fmt_f(x.r.tsb), Db.fmt_f(x.r.tss), short]
			# the artifact's row separators
			frame.line!({ start: { x: 36.0, y: ry + 19.0 }, end: { x: edge, y: ry + 19.0 }, stroke: Draw.stroke(Color.with_alpha(Color.white, 14), 1) })
			List.for_each!(List.map_with_index(cells, |c, j| { c, j }), |cell| {
				cx = match List.get(col_x, cell.j) { Ok(v) => v
					Err(_) => 36.0 }
				col = if cell.j == 3 (Theme.tsb_c) else if cell.j == 5 (Theme.ink_muted) else Color.white
				if cx < edge - 60.0 {
					Text.from(cell.c, model.font).size(13).draw!(frame, { pos: { x: cx, y: ry }, color: col, align: (Top, Left) })
				} else {}
			})
		})
		# the day-detail panel: opens over the right half when a row is clicked,
		# same row again closes it. Db delivers structured { title, stats } rows.
		if model.detail_day != "" {
			pw2 = if win_w / 2.0 < 480.0 (win_w / 2.0 - 36.0) else 480.0
			px = win_w - 36.0 - pw2
			# (panel_edge = px - 24, so the table ends before this card begins)
			ph2 = 78.0 + U64.to_f32(List.len(model.detail)) * 92.0
			ph2c = if ph2 > win_h - 150.0 (win_h - 150.0) else ph2
			frame.rounded_rectangle!({ x: px, y: 100.0, width: pw2, height: ph2c, radius: 10.0, segments: 8, style: Draw.filled(Theme.card) })
			Text.from(model.detail_day, model.font).size(15).draw!(frame, { pos: { x: px + 18.0, y: 116.0 }, color: Color.white, align: (Top, Left) })
			if List.is_empty(model.detail) {
				Text.from("loading...", model.font).size(12).draw!(frame, { pos: { x: px + 18.0, y: 148.0 }, color: ink_muted, align: (Top, Left) })
			} else {}
			# only the lines that fit the panel draw; the tail becomes a count
			# each activity block: title, load line, physiology line, zone bar
			line_fit = match F32.round_to_u64_try(F32.div_floor_by(win_h - 150.0 - 48.0 - 20.0, 92.0)) {
				Ok(f) => if f == 0 (1.U64) else f
				Err(_) => 1.U64
			}
			shown = List.take_first(model.detail, line_fit)
			List.for_each!(List.map_with_index(shown, |ln, li| { ln, li }), |x| {
				ly = 148.0 + U64.to_f32(x.li) * 92.0
				Text.from(x.ln.title, model.font).size(13).draw!(frame, { pos: { x: px + 18.0, y: ly }, color: Theme.ctl_c, align: (Top, Left) })
				Text.from(x.ln.stats, model.font).size(12).draw!(frame, { pos: { x: px + 18.0, y: ly + 19.0 }, color: Color.white, align: (Top, Left) })
				Text.from(x.ln.extra, model.font).size(11).draw!(frame, { pos: { x: px + 18.0, y: ly + 37.0 }, color: ink_muted, align: (Top, Left) })
				# the day's minutes by zone, as a stacked bar in the intensity ramp
				ztot = List.fold(x.ln.zones, 0, |a2, z| a2 + z)
				if ztot > 0 {
					bw2 = pw2 - 36.0
					_ = List.fold(List.map_with_index(x.ln.zones, |z, zi| { z, zi }), 0.0, |xacc, zz| {
						seg = bw2 * I64.to_f32(zz.z) / I64.to_f32(ztot)
						zc = match List.get(Theme.zone_ramp, zz.zi) { Ok(c2) => c2
							Err(_) => Theme.ink_faint }
						if seg > 0.5 {
							frame.rectangle!({ x: px + 18.0 + xacc, y: ly + 56.0, width: seg - 1.0, height: 8.0, style: Draw.filled(zc) })
						} else {}
						xacc + seg
					})
					{}
				} else {}
			})
			hidden = List.len(model.detail) - List.len(shown)
			if hidden > 0 {
				Text.from("+ ${U64.to_str(hidden)} more (enlarge the window)", model.font).size(11).draw!(frame, { pos: { x: px + 18.0, y: 148.0 + U64.to_f32(List.len(shown)) * 92.0 }, color: ink_faint, align: (Top, Left) })
			} else {}
		} else {}
		model.table_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
