import rr.Color
import rr.Draw
import rr.Text
import Db
import Theme
import Ui
import Wrap

Table :: [].{
	# The artifact's accessibility table, native: as many recent days as the
	# window height holds, as numbers, with the day's session names beside
	# them. Cells draw as immediate text, and the page is laid out afresh
	# each frame from a few dozen short strings: cheap, and it keeps a
	# static view out of the Model.

	# where the open detail panel begins, minus breathing room: the panel
	# draws from it, and table_edge reads it while the panel is open
	panel_edge : F32 -> F32
	panel_edge = |win_w| {
		pw2 = F32.min(480.0, win_w / 2.0 - 36.0)
		win_w - 36.0 - pw2 - 24.0
	}

	# how many rows this window height holds at the base height: the ceiling
	# on a page, before any row grows. Never below 5, so the scroll floor
	# has rows to work with in a tiny window; the height gate decides how
	# many of them actually draw.
	rows_fit : F32 -> U64
	rows_fit = |win_h| {
		match F32.round_to_u64_try(F32.div_floor_by(rows_avail(win_h), row_base)) {
			Ok(r) => if r < 5 (5.U64) else r
			Err(_) => 5.U64
		}
	}

	# the pixels between the header and the hint that rows may fill
	rows_avail : F32 -> F32
	rows_avail = |win_h| win_h - rows_top - 70.0

	rows_top : F32
	rows_top = 134.0

	row_base : F32
	row_base = 24.0

	line_h : F32
	line_h = 16.0

	# a note wraps to at most this many lines; past it the shared rule cuts
	note_lines_max : U64
	note_lines_max = 2

	# a row is one line of cells; a session note that wraps to a second
	# line grows the row by line_h. Lines are capped at note_lines_max,
	# so a row is never taller than that many lines.
	row_h : U64 -> F32
	row_h = |lines| row_base + U64.to_f32(if lines > 0 (lines - 1) else 0) * line_h

	# where the table stops on the right: the open detail panel's edge, or
	# the window's. The draw and both hit-tests read this one value; cells
	# and the session column keep 60px clear of it.
	table_edge : F32, Str -> F32
	table_edge = |win_w, detail_day| if detail_day != "" (panel_edge(win_w)) else win_w - 40.0

	# the session column's monospace columns at a table edge: the span from
	# the column to the edge at ~8px per glyph, negative when the column sits
	# right of the edge. The column draws only when at least 12 fit, so the
	# budget and the visibility are one measurement rather than a floor and a
	# clearance that could disagree about how much room is enough.
	note_cols : F32 -> I64
	note_cols = |edge|
		match F32.round_to_i64_try(F32.div_floor_by(edge - session_x - 10.0, 8.0)) { Ok(c) => c
			Err(_) => 0 }

	note_shown : F32 -> Bool
	note_shown = |edge| note_cols(edge) >= 12

	note_budget : F32 -> U64
	note_budget = |edge| match I64.to_u64_try(note_cols(edge)) { Ok(b) => if b < 12 (12.U64) else b
		Err(_) => 12 }

	# the session column's lines for a day, through the rule the form
	# board's card and the plan card share; none when the column is hidden,
	# so a row never grows for lines nothing paints
	note_lines : List({ day : Str, note : Str }), Str, F32 -> List(Str)
	note_lines = |notes, day, edge|
		if note_shown(edge) (Wrap.fit(Db.note_for(notes, day), note_budget(edge), note_lines_max)) else []

	# a row's height for a day: lines counted at the FULL-width budget while
	# the column is shown at `edge`, so opening the detail panel narrows the
	# text but moves no row; a hidden column makes every row one line. THE
	# rule page_for lays rows out by, so an expect can pin it without a Model
	row_h_for : List({ day : Str, note : Str }), Str, F32, F32 -> F32
	row_h_for = |notes, day, edge, full_edge|
		if note_shown(edge) (row_h(List.len(note_lines(notes, day, full_edge)))) else row_base

	# THE table-window math: one implementation, used by render, row clicks
	# and hover alike: one geometry. The click feeds it the pre-click state
	# of the frame, the hover the post-click state, the draw the committed model.
	#
	# cursor counts days back from the newest. A page is the newest rows that
	# fit above the hint, oldest at the top: it ends before index `kept` (the series
	# minus the scroll) and takes rows backward from there while their
	# heights fit `avail` and their count fits `fit`. Rows have different
	# heights, so the scroll floor is not a count: the last page must still
	# reach row 0, so `max_back` is the series minus the rows that fit from
	# row 0 forward. A row taller than the whole space still draws alone.
	# `h_of` is a row's height by series index; a short series clamps to no
	# scroll.
	Page : { back : U64, kept : U64, rows : List({ i : U64, top : F32, h : F32 }) }

	page_of : U64, I64, U64, F32, (U64 -> F32) -> Page
	page_of = |total, cursor, fit, avail, h_of| {
		# the scroll floor: rows that fit from the oldest forward
		head = if total < fit total else fit
		kept_min = List.fold(List.map_with_index(List.repeat({}, head), |_u, k| k), { n: 0.U64, acc: 0.0 }, |st, k| {
			h = h_of(k)
			if st.n == k and (st.acc + h <= avail or k == 0) ({ n: k + 1, acc: st.acc + h }) else st
		}).n
		max_back = if total > kept_min (total - kept_min) else 0.U64
		back = if cursor < 0 (0.U64) else match I64.to_u64_try(cursor) {
			Ok(c) => if c > max_back max_back else c
			Err(_) => 0.U64
		}
		kept = total - back
		# this page: newest first while they fit, contiguous from `kept`
		cand = if kept < fit kept else fit
		taken = List.fold(List.map_with_index(List.repeat({}, cand), |_u, k| kept - 1 - k), { rows: [], acc: 0.0, n: 0.U64 }, |st, i| {
			h = h_of(i)
			if st.n == kept - 1 - i and (st.acc + h <= avail or st.n == 0) ({ rows: List.append(st.rows, { i, h }), acc: st.acc + h, n: st.n + 1 }) else st
		})
		oldest_first = List.fold(taken.rows, [], |acc, r| List.prepend(acc, r))
		rows = List.fold(oldest_first, { out: [], y: rows_top }, |st, r| ({ out: List.append(st.out, { i: r.i, top: st.y, h: r.h }), y: st.y + r.h })).out
		{ back, kept, rows }
	}

	# the page this model renders for a scroll and panel state - the SAME
	# geometry the draw uses, so a click lands on the row the eye sees when
	# the caller passes the state the frame drew with
	page_for : Ui.Model, I64, Str -> Page
	page_for = |model, cursor, detail_day| {
		edge = table_edge(model.win.w, detail_day)
		h_of = |i| match List.get(model.days, i) {
			Ok(d) => row_h_for(model.day_notes, d, edge, table_edge(model.win.w, ""))
			Err(_) => row_base
		}
		page_of(List.len(model.data), cursor, rows_fit(model.win.h), rows_avail(model.win.h), h_of)
	}

	# the series index of the row under a y, if any
	row_at : Page, F32 -> [Row(U64), None]
	row_at = |page, y|
		List.fold(page.rows, None, |acc, r| if y >= r.top and y < r.top + r.h Row(r.i) else acc)

	session_x : F32
	session_x = 680.0

	col_x : List(F32)
	col_x = [36.0, 260.0, 380.0, 490.0, 590.0, session_x]

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		# master-detail: with the panel open, the whole table lives left of it -
		# no element draws underneath the card
		edge = table_edge(win_w, model.detail_day)
		model.table_title.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		List.for_each!(List.map_with_index(model.table_head, |h, i| { h, i }), |x| {
			hx = match List.get(col_x, x.i) { Ok(v) => v
				Err(_) => 36.0 }
			if hx < edge - 60.0 {
				x.h.draw!(frame, { pos: { x: hx, y: 108.0 }, color: ink_faint, align: (Top, Left) })
			}
		})
		# the arrow cursor scrolls the window back through the whole series:
		# cursor N shows the page ending N days before the latest
		total = List.len(model.data)
		page = page_for(model, model.cursor, model.detail_day)
		kept = page.kept
		# no rows, no arithmetic on them — the indicator only speaks over data
		if total > 0 {
			# a page over data always holds its newest row, so the arm below is
			# only the match being total
			first = match List.first(page.rows) { Ok(r) => r.i + 1
				Err(_) => kept }
			pos_note = "days ${U64.to_str(first)}-${U64.to_str(kept)} of ${U64.to_str(total)}"
			Text.from(pos_note, model.font).size(13).draw!(frame, { pos: { x: edge, y: 70.0 }, color: ink_muted, align: (Top, Right) })
		}
		List.for_each!(page.rows, |row| {
			ry = row.top
			# the row under the mouse lifts - hover feedback to match the pointer
			row_right = edge
			if model.mouse_y >= ry and model.mouse_y < ry + row.h and model.mouse_x >= 36.0 and model.mouse_x < row_right {
				frame.rectangle!({ x: 34.0, y: ry - 2.0, width: row_right - 34.0, height: row.h - 1.0, style: Draw.filled(Color.with_alpha(Color.white, 10)) })
			}
			day = match List.get(model.days, row.i) { Ok(d) => d
				Err(_) => "" }
			r = match List.get(model.data, row.i) { Ok(p) => p
				Err(_) => { ctl: 0.0, atl: 0.0, tsb: 0.0, tss: 0.0 } }
			cells = [day, Db.fmt_f(r.ctl), Db.fmt_f(r.atl), Db.fmt_f(r.tsb), Db.fmt_f(r.tss)]
			# the artifact's row separators, under the row's last line
			frame.line!({ start: { x: 36.0, y: ry + row.h - 5.0 }, end: { x: edge, y: ry + row.h - 5.0 }, stroke: Draw.stroke(Color.with_alpha(Color.white, 14), 1) })
			List.for_each!(List.map_with_index(cells, |c, j| { c, j }), |cell| {
				cx = match List.get(col_x, cell.j) { Ok(v) => v
					Err(_) => 36.0 }
				col = if cell.j == 3 (Theme.tsb_c) else Color.white
				if cx < edge - 60.0 {
					Text.from(cell.c, model.font).size(13).draw!(frame, { pos: { x: cx, y: ry }, color: col, align: (Top, Left) })
				}
			})
			# the session column: the day's names, wrapped through the shared
			# rule; the row is already as tall as these lines need
			if note_shown(edge) {
				List.for_each!(List.map_with_index(note_lines(model.day_notes, day, edge), |ln, li| { ln, li }), |x|
					Text.from(x.ln, model.font).size(13).draw!(frame, { pos: { x: session_x, y: ry + U64.to_f32(x.li) * line_h }, color: Theme.ink_muted, align: (Top, Left) }))
			}
		})
		# the day-detail panel: opens over the right half when a row is clicked,
		# same row again closes it. Db delivers structured { title, stats } rows.
		if model.detail_day != "" {
			# derived from the SAME edge the table clamps to - px = edge + 24 by
			# construction, so render and hit-tests cannot drift
			px = panel_edge(win_w) + 24.0
			pw2 = win_w - 36.0 - px
			ph2 = 78.0 + List.fold(model.detail, 0.0, |acc, ln| acc + 92.0 + U64.to_f32(List.len(Wrap.fit(ln.title, Wrap.cols_for(pw2 - 36.0, 7.8), 2)) - 1) * 16.0)
			ph2c = if ph2 > win_h - 150.0 (win_h - 150.0) else ph2
			frame.rounded_rectangle!({ x: px, y: 100.0, width: pw2, height: ph2c, radius: 10.0, segments: 8, style: Draw.filled(Theme.card) })
			Text.from(model.detail_day, model.font).size(15).draw!(frame, { pos: { x: px + 18.0, y: 116.0 }, color: Color.white, align: (Top, Left) })
			if List.is_empty(model.detail) {
				Text.from("loading...", model.font).size(12).draw!(frame, { pos: { x: px + 18.0, y: 148.0 }, color: ink_muted, align: (Top, Left) })
			}
			# each activity block: title (wrapped to two lines through the shared
			# rule, so a long name grows its block instead of running off the
			# card), load line, physiology line, zone bar. Only the blocks that
			# fit the panel draw; the tail becomes a count
			title_cols = Wrap.cols_for(pw2 - 36.0, 7.8)
			blocks = List.map(model.detail, |ln| {
				lines = Wrap.fit(ln.title, title_cols, 2)
				{ ln, lines, h: 92.0 + U64.to_f32(List.len(lines) - 1) * 16.0 }
			})
			room = win_h - 150.0 - 48.0 - 20.0
			taken = List.fold(blocks, { out: [], y: 148.0 }, |st, b|
				if List.is_empty(st.out) or st.y + b.h - 148.0 <= room ({ out: List.append(st.out, { b, top: st.y }), y: st.y + b.h }) else st)
			shown = taken.out
			List.for_each!(shown, |x| {
				ly = x.top
				List.for_each!(List.map_with_index(x.b.lines, |tl, ti| { tl, ti }), |t|
					Text.from(t.tl, model.font).size(13).draw!(frame, { pos: { x: px + 18.0, y: ly + U64.to_f32(t.ti) * 16.0 }, color: Theme.ctl_c, align: (Top, Left) }))
				body_y = ly + U64.to_f32(List.len(x.b.lines) - 1) * 16.0
				Text.from(x.b.ln.stats, model.font).size(12).draw!(frame, { pos: { x: px + 18.0, y: body_y + 19.0 }, color: Color.white, align: (Top, Left) })
				Text.from(x.b.ln.extra, model.font).size(11).draw!(frame, { pos: { x: px + 18.0, y: body_y + 37.0 }, color: ink_muted, align: (Top, Left) })
				# the session's TIME by zone (seconds in, proportions out), as a
				# stacked bar in the intensity ramp
				ztot = List.fold(x.b.ln.zones, 0, |a2, z| a2 + z)
				if ztot > 0 {
					bw2 = pw2 - 36.0
					_ = List.fold_try!(List.map_with_index(x.b.ln.zones, |z, zi| { z, zi }), 0.0, |xacc, zz| {
						seg = bw2 * I64.to_f32(zz.z) / I64.to_f32(ztot)
						zc = match List.get(Theme.zone_ramp, zz.zi) { Ok(c2) => c2
							Err(_) => Theme.ink_faint }
						if seg > 1.5 {
							# -1 leaves a hairline gap between segments; the guard
							# keeps the drawn width strictly positive
							frame.rectangle!({ x: px + 18.0 + xacc, y: body_y + 56.0, width: seg - 1.0, height: 8.0, style: Draw.filled(zc) })
						}
						Ok(xacc + seg)
					})
				}
			})
			hidden = List.len(model.detail) - List.len(shown)
			if hidden > 0 {
				Text.from("+ ${U64.to_str(hidden)} more (enlarge the window)", model.font).size(11).draw!(frame, { pos: { x: px + 18.0, y: taken.y }, color: ink_faint, align: (Top, Left) })
			}
		}
		model.table_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}

expect (Table.row_h(1) - 24.0).abs() < 0.001
expect (Table.row_h(2) - 40.0).abs() < 0.001
expect (Table.row_h(0) - 24.0).abs() < 0.001
expect Table.rows_fit(600.0) == 16
expect Table.rows_fit(100.0) == 5

# uniform rows: a full page of `fit` rows ending at the newest, oldest on top
expect {
	p = Table.page_of(100, 0, 10, 240.0, |_i| 24.0)
	first = List.first(p.rows)
	last = List.last(p.rows)
	p.back == 0 and p.kept == 100 and List.len(p.rows) == 10
	and (match first { Ok(r) => r.i == 90 and (r.top - 134.0).abs() < 0.001
		Err(_) => Bool.False })
	and (match last { Ok(r) => r.i == 99 and (r.top - 350.0).abs() < 0.001
		Err(_) => Bool.False })
}

# rows of two heights: the page takes rows backward from the newest while
# their heights fit, so a tall row at the top edge is left for the next scroll
expect {
	p = Table.page_of(20, 0, 10, 100.0, |i| if i % 2 == 0 40.0 else 24.0)
	first = List.first(p.rows)
	last = List.last(p.rows)
	List.len(p.rows) == 3
	and (match first { Ok(r) => r.i == 17 and (r.top - 134.0).abs() < 0.001
		Err(_) => Bool.False })
	and (match last { Ok(r) => r.i == 19 and (r.top - 198.0).abs() < 0.001
		Err(_) => Bool.False })
}

# the scroll floor is measured in rows that fit from the oldest, not counted:
# scrolling all the way back lands a page whose top row is row 0
expect {
	p = Table.page_of(20, 999, 10, 100.0, |i| if i % 2 == 0 40.0 else 24.0)
	first = List.first(p.rows)
	p.back == 18 and p.kept == 2 and List.len(p.rows) == 2
	and (match first { Ok(r) => r.i == 0
		Err(_) => Bool.False })
}

# a row taller than the whole space still draws, alone
expect {
	p = Table.page_of(5, 0, 5, 100.0, |_i| 500.0)
	List.len(p.rows) == 1 and p.kept == 5
	and (match List.first(p.rows) { Ok(r) => r.i == 4
		Err(_) => Bool.False })
}

# hit-tests read the rows' own spans
expect {
	p = { back: 0.U64, kept: 2.U64, rows: [{ i: 0.U64, top: 134.0, h: 24.0 }, { i: 1.U64, top: 158.0, h: 40.0 }] }
	Table.row_at(p, 140.0) == Row(0) and Table.row_at(p, 190.0) == Row(1)
	and Table.row_at(p, 198.0) == None and Table.row_at(p, 100.0) == None
}

# a hidden session column adds no height: with the detail panel open on a
# 1100px-wide window the column is clear of nothing, so a two-activity day
# is one line; at full width the same day wraps and the row grows
expect {
	notes = [{ day: "2026-01-01", note: "45 min Full Body Strength with Rad Lopez + Evening Ride around the lake" }]
	hidden = Table.table_edge(1100.0, "2026-01-01")
	shown = Table.table_edge(1100.0, "")
	!(Table.note_shown(hidden)) and Table.note_shown(shown)
	and (Table.row_h_for(notes, "2026-01-01", hidden, shown) - 24.0).abs() < 0.001
	and (Table.row_h_for(notes, "2026-01-01", shown, shown) - 40.0).abs() < 0.001
	and Table.note_lines(notes, "2026-01-01", hidden) == []
}

# the column shows only where 12 glyphs fit: at the edge where the old 60px
# clearance still showed it the budget was its floor, and the note overdrew
# the panel. Rows keep their full-width height while the column is shown, so
# opening the panel on a wide window narrows the text and moves no row
expect {
	notes = [{ day: "2026-01-01", note: "45 min Full Body Strength with Rad Lopez + Evening Ride around the lake" }]
	narrow = Table.session_x + 10.0 + 11.0 * 8.0
	twelve = Table.session_x + 10.0 + 12.0 * 8.0
	!(Table.note_shown(narrow)) and Table.note_shown(twelve) and Table.note_budget(twelve) == 12
	and (Table.row_h_for(notes, "2026-01-01", twelve, Table.table_edge(1100.0, "")) - 40.0).abs() < 0.001
	and (Table.row_h_for(notes, "2026-01-01", twelve, 1600.0) - 24.0).abs() < 0.001
	and List.len(Table.note_lines(notes, "2026-01-01", twelve)) == 2
}
