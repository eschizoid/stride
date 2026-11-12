import rr.Color
import rr.Draw
import Chrome
import Days
import Db
import Labels
import Scene
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
			Ok(r) => if (r < 5) (5.U64) else r
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
	row_h = |lines| row_base + U64.to_f32(if (lines > 0) (lines - 1) else 0) * line_h

	# where the table stops on the right: the open detail panel's edge, or
	# the window's. The draw and both hit-tests read this one value; cells
	# keep 60px clear of it, and the session column draws only where twelve
	# of its glyphs fit before it (note_shown).
	table_edge : F32, Str -> F32
	table_edge = |win_w, detail_day| if (detail_day != "") (panel_edge(win_w)) else win_w - 40.0

	# the session column's monospace columns at a table edge: the span from
	# the column to the edge at ~8px per glyph, negative when the column sits
	# right of the edge. The column draws only when at least 12 fit, and its
	# budget is this same count, so its text never draws past the edge.
	note_cols : F32 -> I64
	note_cols = |edge|
		match F32.round_to_i64_try(F32.div_floor_by(edge - session_x - 10.0, 8.0)) {
			Ok(c) => c
			Err(_) => 0
		}

	note_shown : F32 -> Bool
	note_shown = |edge| note_cols(edge) >= 12

	note_budget : F32 -> U64
	note_budget = |edge| match I64.to_u64_try(note_cols(edge)) {
		Ok(b) => if (b < 12) (12.U64) else b
		Err(_) => 12
	}

	# the session column's lines for a day, through the rule the form
	# board's card and the plan card share; none when the column is hidden,
	# so a row never grows for lines nothing paints
	note_lines : List({ day : Str, note : Str }), Str, F32 -> List(Str)
	note_lines = |notes, day, edge|
		if (note_shown(edge)) (Wrap.fit(Db.note_for(notes, day), note_budget(edge), note_lines_max)) else []

	# a row's height for a day: lines counted at the FULL-width budget whether
	# or not the column is shown, so opening the detail panel narrows or hides
	# the text but moves no row (a hidden column leaves blank room under the
	# cells rather than re-flowing the page). THE rule page_for lays rows out
	# by, so an expect can pin it without a Model
	row_h_for : List({ day : Str, note : Str }), Str, F32 -> F32
	row_h_for = |notes, day, full_edge| row_h(List.len(note_lines(notes, day, full_edge)))

	# the lines the column DRAWS for a day: wrapped at the budget of `edge`
	# but cut to the line count the row was sized for (its full-width count),
	# so a narrowed column ends in "..." inside its row instead of drawing a
	# second line over the row below
	note_lines_at : List({ day : Str, note : Str }), Str, F32, F32 -> List(Str)
	note_lines_at = |notes, day, edge, full_edge|
		if (note_shown(edge)) (Wrap.fit(Db.note_for(notes, day), note_budget(edge), List.len(note_lines(notes, day, full_edge)))) else []

	# the row height for a day in a window: the window's width alone sizes
	# it, never the panel state, so the page lays out the same with the panel
	# open or closed. page_for lays rows out by this, so an expect can pin the
	# wiring, not only the rule
	row_h_at : List({ day : Str, note : Str }), Str, F32 -> F32
	row_h_at = |notes, day, win_w| row_h_for(notes, day, table_edge(win_w, ""))

	# the lines the column draws for a day in a window: wrapped at the edge
	# the panel leaves, cut to the line count row_h_at sizes the row with
	# (the full-width edge); the draw reads this, so the cut and the height
	# cannot be wired to different edges
	note_lines_in : List({ day : Str, note : Str }), Str, F32, Str -> List(Str)
	note_lines_in = |notes, day, win_w, detail_day|
		note_lines_at(notes, day, table_edge(win_w, detail_day), table_edge(win_w, ""))

	# how many leading panel blocks fit in `room` px: the first always, then
	# each next one while the stack still fits. A block that does not fit
	# ends the stack; a shorter block after it never jumps the gap, so the
	# panel shows a prefix of the day's sessions and a count of the rest
	blocks_fit : List(F32), F32 -> U64
	blocks_fit = |heights, room| {
		st = List.fold(
			heights,
			{ n: 0.U64, y: 0.0, stopped: Bool.False },
			|s, h|
				if (s.stopped) s
				else if (s.n == 0 or s.y + h <= room) ({ n: s.n + 1, y: s.y + h, stopped: Bool.False })
				else { ..s, stopped: Bool.True },
		)
		st.n
	}

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
		head = if (total < fit) total else fit
		kept_min = List.fold(
			List.map_with_index(List.repeat({}, head), |_u, k| k),
			{ n: 0.U64, acc: 0.0 },
			|st, k| {
				h = h_of(k)
				if (st.n == k and (st.acc + h <= avail or k == 0)) ({ n: k + 1, acc: st.acc + h }) else st
			},
		).n
		max_back = if (total > kept_min) (total - kept_min) else 0.U64
		back = if (cursor < 0) (0.U64) else match I64.to_u64_try(cursor) {
			Ok(c) => if (c > max_back) max_back else c
			Err(_) => 0.U64
		}
		kept = total - back
		# this page: newest first while they fit, contiguous from `kept`
		cand = if (kept < fit) kept else fit
		taken = List.fold(
			List.map_with_index(List.repeat({}, cand), |_u, k| kept - 1 - k),
			{ rows: [], acc: 0.0, n: 0.U64 },
			|st, i| {
				h = h_of(i)
				if (st.n == kept - 1 - i and (st.acc + h <= avail or st.n == 0)) ({ rows: List.append(st.rows, { i, h }), acc: st.acc + h, n: st.n + 1 }) else st
			},
		)
		oldest_first = List.fold(taken.rows, [], |acc, r| List.prepend(acc, r))
		rows = List.fold(oldest_first, { out: [], y: rows_top }, |st, r| ({ out: List.append(st.out, { i: r.i, top: st.y, h: r.h }), y: st.y + r.h })).out
		{ back, kept, rows }
	}

	# the page this model renders for a scroll - the SAME geometry the draw
	# uses, so a click lands on the row the eye sees when the caller passes
	# the cursor the frame drew with. The panel state is not an input: the
	# page is the same with the panel open or closed, and page_in's
	# signature has no field to carry it
	page_for : Ui.Model, I64 -> Page
	page_for = |model, cursor| page_in(model.days, model.day_notes, List.len(model.data), cursor, model.win.w, model.win.h)

	# the page for a series of `total` rows named by `days`, in a window of
	# the given size: heights by the window width alone, rows by its height
	page_in : List(Str), List({ day : Str, note : Str }), U64, I64, F32, F32 -> Page
	page_in = |days, notes, total, cursor, win_w, win_h| {
		h_of = |i| match List.get(days, i) {
			Ok(d) => row_h_at(notes, d, win_w)
			Err(_) => row_base
		}
		page_of(total, cursor, rows_fit(win_h), rows_avail(win_h), h_of)
	}

	# the series index of the row under a y, if any
	row_at : Page, F32 -> [Row(U64), None]
	row_at = |page, y|
		List.fold(page.rows, None, |acc, r| if (y >= r.top and y < r.top + r.h) Row(r.i) else acc)

	session_x : F32
	session_x = 680.0

	col_x : List(F32)
	col_x = [36.0, 260.0, 380.0, 490.0, 590.0, session_x]

	title_text : Str
	title_text = "data table"

	hint_text : Str
	hint_text = "arrows  scroll days      TAB  lifts      R  reload      S  screenshot      V  record      ESC quit"

	# the column headers, one per entry of col_x
	head_texts : List(Str)
	head_texts = ["day", "fitness", "fatigue", "form", "load", "session"]

	# The day-detail panel: it opens over the right half when a row is
	# clicked, and the same row again closes it. Its left edge comes from
	# the SAME edge the table clamps to, px = edge + 24 by construction, so
	# render and hit-tests cannot drift. Each activity block is a title
	# wrapped to two lines through the shared rule (a long name grows its
	# block instead of running off the card), a load line, a physiology line
	# and a zone bar. Only the blocks that fit the panel draw; the tail
	# becomes a count.
	Detail : { box : Labels.Rect, blocks : List({ ln : Db.DayLine, lines : List(Str), top : F32 }), hidden : U64, more_y : F32 }

	detail_geom : Ui.Model -> Detail
	detail_geom = |model| {
		px = panel_edge(model.win.w) + 24.0
		pw2 = model.win.w - 36.0 - px
		title_cols = Wrap.cols_for(pw2 - 36.0, 7.8)
		blocks = List.map(
			model.detail,
			|ln| {
				lines = Wrap.fit(ln.title, title_cols, 2)
				{ ln, lines, h: 92.0 + (U64.to_f32(List.len(lines)) - 1.0) * 16.0 }
			},
		)
		ph2 = 78.0 + List.fold(blocks, 0.0, |acc, b| acc + b.h)
		room = model.win.h - 150.0 - 48.0 - 20.0
		taken = List.fold(List.take_first(blocks, blocks_fit(List.map(blocks, |b| b.h), room)), { out: [], y: 148.0 }, |st, b| { out: List.append(st.out, { ln: b.ln, lines: b.lines, top: st.y }), y: st.y + b.h })
		{ box: { x: px, y: 100.0, w: pw2, h: F32.min(ph2, model.win.h - 150.0) }, blocks: taken.out, hidden: List.len(model.detail) - List.len(taken.out), more_y: taken.y }
	}

	# a block's body starts under its title's last line
	body_y : { ln : Db.DayLine, lines : List(Str), top : F32 } -> F32
	body_y = |b| b.top + (U64.to_f32(List.len(b.lines)) - 1.0) * 16.0

	# the session's TIME by zone (seconds in, proportions out), as a stacked
	# bar under the block
	zone_bar : Detail, { ln : Db.DayLine, lines : List(Str), top : F32 } -> Labels.Rect
	zone_bar = |d, b| { x: d.box.x + 18.0, y: body_y(b) + 56.0, w: d.box.w - 36.0, h: 8.0 }

	# ── every string the view writes, placed ───────────────────────────────
	# All of it is fixed: the title, the headers, the position note, every
	# cell and session line, the detail panel's text, the footer and the
	# mode chips.
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
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		fix = |it, x, y, align, region| Scene.fixed(measure, it, { x, y, align }, region)
		# master-detail: with the panel open, the whole table lives left of
		# it - no element draws underneath the card
		edge = table_edge(win_w, model.detail_day)
		head = List.join([
			[fix(Scene.prepared(model.table_title, title_text, 15.0, Prose, ink_muted), Days.title_x, 70.0, Left, panel)],
			List.keep_oks(
				List.map3(model.table_head, head_texts, col_x, |p, t, hx| { p, t, hx }),
				|h| if (h.hx < edge - 60.0) Ok(fix(Scene.prepared(h.p, h.t, 13.0, Prose, ink_faint), h.hx, 108.0, Left, panel)) else Err(Hidden),
			),
		])
		# the arrow cursor scrolls the window back through the whole series:
		# cursor N shows the page ending N days before the latest. A page
		# over data always holds its newest row, so the indicator speaks only
		# over data.
		total = List.len(model.data)
		page = page_for(model, model.cursor)
		pos =
			if total > 0 {
				first = match List.first(page.rows) {
					Ok(r) => r.i + 1
					Err(_) => page.kept
				}
				[fix(Scene.data("days ${U64.to_str(first)}-${U64.to_str(page.kept)} of ${U64.to_str(total)}", 13.0, ink_muted), edge, 70.0, Right, panel)]
			} else {
				[]
			}
		rows = List.join(
			List.map(
				page.rows,
				|row| {
					day = (List.get(model.days, row.i)) ?? ""
					r = (List.get(model.data, row.i)) ?? { ctl: 0.0, atl: 0.0, tsb: 0.0, tss: 0.0 }
					cells = [day, Db.fmt_f(r.ctl), Db.fmt_f(r.atl), Db.fmt_f(r.tsb), Db.fmt_f(r.tss)]
					List.concat(
						List.keep_oks(List.map_with_index(List.map2(cells, col_x, |c, cx| { c, cx }), |e, j| { c: e.c, cx: e.cx, j }), |e| if (e.cx < edge - 60.0) Ok(fix(Scene.data(e.c, 13.0, if (e.j == 3) Theme.tsb_c else Color.white), e.cx, row.top, Left, panel)) else Err(Hidden)),
						# the session column: the day's names, wrapped through the
						# shared rule, cut to the lines the row was sized for
						List.map_with_index(note_lines_in(model.day_notes, day, win_w, model.detail_day), |ln, li| fix(Scene.data(ln, 13.0, ink_muted), session_x, row.top + U64.to_f32(li) * line_h, Left, panel)),
					)
				},
			),
		)
		detail =
			if model.detail_day != "" {
				d = detail_geom(model)
				x = d.box.x + 18.0
				in_card = |it, y| fix(it, x, y, Left, d.box)
				List.join([
					[in_card(Scene.data(model.detail_day, 15.0, Color.white), 116.0)],
					if (List.is_empty(model.detail)) [in_card(Scene.data("loading...", 12.0, ink_muted), 148.0)] else [],
					List.join(
						List.map(
							d.blocks,
							|b| List.concat(
								List.map_with_index(b.lines, |tl, ti| in_card(Scene.data(tl, 13.0, Theme.ctl_c), b.top + U64.to_f32(ti) * 16.0)),
								[in_card(Scene.data(b.ln.stats, 12.0, Color.white), body_y(b) + 19.0), in_card(Scene.data(b.ln.extra, 11.0, ink_muted), body_y(b) + 37.0)],
							),
						),
					),
					if (d.hidden > 0) [in_card(Scene.data("+ ${U64.to_str(d.hidden)} more (enlarge the window)", 11.0, ink_faint), d.more_y)] else [],
				])
			} else {
				[]
			}
		foot = [fix(Scene.prepared(model.table_hint, hint_text, 13.0, Prose, ink_faint), 36.0, win_h - 30.0, Left, panel)]
		List.join([head, pos, rows, detail, foot, Days.chip_texts(model, measure)])
	}

	# the shapes no text may cover but its own: the pills, the mode chips,
	# and the open detail card and each of its zone bars
	marks : Ui.Model -> List(Labels.Mark)
	marks = |model| {
		card =
			if model.detail_day != "" {
				d = detail_geom(model)
				List.prepend(List.keep_oks(d.blocks, |b| if (List.fold(b.ln.zones, 0.I64, |a, z| a + z) > 0) Ok({ key: "the zone bar of '${b.ln.title}'", box: zone_bar(d, b) }) else Err(NoZones)), { key: "the detail card", box: d.box })
			} else {
				[]
			}
		List.join([Chrome.marks(model), Days.chip_marks, card])
	}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		edge = table_edge(model.win.w, model.detail_day)
		List.for_each!(
			(page_for(model, model.cursor)).rows,
			|row| {
				ry = row.top
				# the row under the mouse lifts - hover feedback to match the pointer
				if model.mouse_y >= ry and model.mouse_y < ry + row.h and model.mouse_x >= 36.0 and model.mouse_x < edge {
					frame.rectangle!({ x: 34.0, y: ry - 2.0, width: edge - 34.0, height: row.h - 1.0, style: Draw.filled(Color.with_alpha(Color.white, 10)) })
				}
				# the artifact's row separators, under the row's last line
				frame.line!({ start: { x: 36.0, y: ry + row.h - 5.0 }, end: { x: edge, y: ry + row.h - 5.0 }, stroke: Draw.stroke(Color.with_alpha(Color.white, 14), 1) })
			},
		)
		if model.detail_day != "" {
			d = detail_geom(model)
			frame.rounded_rectangle!({ x: d.box.x, y: d.box.y, width: d.box.w, height: d.box.h, radius: 10.0, segments: 8, style: Draw.filled(Theme.card) })
			List.for_each!(
				d.blocks,
				|b| {
					ztot = List.fold(b.ln.zones, 0, |a2, z| a2 + z)
					if ztot > 0 {
						bar = zone_bar(d, b)
						_ = List.fold_try!(
							List.map_with_index(b.ln.zones, |z, zi| { z, zi }),
							0.0,
							|xacc, zz| {
								seg = bar.w * I64.to_f32(zz.z) / I64.to_f32(ztot)
								zc = (List.get(Theme.zone_ramp, zz.zi)) ?? Theme.ink_faint
								if seg > 1.5 {
									# -1 leaves a hairline gap between segments; the guard
									# keeps the drawn width strictly positive
									frame.rectangle!({ x: bar.x + xacc, y: bar.y, width: seg - 1.0, height: bar.h, style: Draw.filled(zc) })
								}
								Ok(xacc + seg)
							},
						)
					}
				},
			)
		}
		Scene.draw!(frame, model, scene(model, Scene.measure_of(model)))
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
		and (
			match first {
				Ok(r) => r.i == 90 and (r.top - 134.0).abs() < 0.001
				Err(_) => Bool.False
			}
		)
		and (
			match last {
				Ok(r) => r.i == 99 and (r.top - 350.0).abs() < 0.001
				Err(_) => Bool.False
			}
		)
}

# rows of two heights: the page takes rows backward from the newest while
# their heights fit, so a tall row at the top edge is left for the next scroll
expect {
	p = Table.page_of(20, 0, 10, 100.0, |i| if (i % 2 == 0) 40.0 else 24.0)
	first = List.first(p.rows)
	last = List.last(p.rows)
	List.len(p.rows) == 3
		and (
			match first {
				Ok(r) => r.i == 17 and (r.top - 134.0).abs() < 0.001
				Err(_) => Bool.False
			}
		)
		and (
			match last {
				Ok(r) => r.i == 19 and (r.top - 198.0).abs() < 0.001
				Err(_) => Bool.False
			}
		)
}

# the scroll floor is measured in rows that fit from the oldest, not counted:
# scrolling all the way back lands a page whose top row is row 0
expect {
	p = Table.page_of(20, 999, 10, 100.0, |i| if (i % 2 == 0) 40.0 else 24.0)
	first = List.first(p.rows)
	p.back == 18 and p.kept == 2 and List.len(p.rows) == 2
		and (
			match first {
				Ok(r) => r.i == 0
				Err(_) => Bool.False
			}
		)
}

# a row taller than the whole space still draws, alone
expect {
	p = Table.page_of(5, 0, 5, 100.0, |_i| 500.0)
	List.len(p.rows) == 1 and p.kept == 5
		and (
			match List.first(p.rows) {
				Ok(r) => r.i == 4
				Err(_) => Bool.False
			}
		)
}

# hit-tests read the rows' own spans
expect {
	p = { back: 0.U64, kept: 2.U64, rows: [{ i: 0.U64, top: 134.0, h: 24.0 }, { i: 1.U64, top: 158.0, h: 40.0 }] }
	Table.row_at(p, 140.0) == Row(0) and Table.row_at(p, 190.0) == Row(1)
		and Table.row_at(p, 198.0) == None and Table.row_at(p, 100.0) == None
}

# a hidden session column keeps the row's height: with the detail panel
# open on a 1100px-wide window the column is clear of nothing and draws no
# lines, but a two-activity day stays the two lines it is at full width, so
# no row moves when the panel opens or closes. The page itself is laid out
# by page_in, whose inputs carry no panel state, so the row is 40px tall on
# the page as well as by the rule
expect {
	notes = [{ day: "2026-01-01", note: "45 min Full Body Strength with Rad Lopez + Evening Ride around the lake" }]
	hidden = Table.table_edge(1100.0, "2026-01-01")
	shown = Table.table_edge(1100.0, "")
	page = Table.page_in(["2026-01-01"], notes, 1, 0, 1100.0, 700.0)
	!(Table.note_shown(hidden)) and Table.note_shown(shown)
		and (Table.row_h_at(notes, "2026-01-01", 1100.0) - 40.0).abs() < 0.001
		and Table.note_lines_in(notes, "2026-01-01", 1100.0, "2026-01-01") == []
		and (
			match List.first(page.rows) {
				Ok(r) => (r.h - 40.0).abs() < 0.001
				Err(_) => Bool.False
			}
		)
}

# the column shows only where twelve glyphs fit, and its budget is that same
# count, so no width lets it draw past the edge. Rows keep their full-width
# height, so opening the panel on a wide window narrows the text and moves
# no row; the drawn lines are cut to that height
expect {
	notes = [{ day: "2026-01-01", note: "45 min Full Body Strength with Rad Lopez + Evening Ride around the lake" }]
	narrow = Table.session_x + 10.0 + 11.0 * 8.0
	twelve = Table.session_x + 10.0 + 12.0 * 8.0
	!(Table.note_shown(narrow)) and Table.note_shown(twelve) and Table.note_budget(twelve) == 12
		and (Table.row_h_for(notes, "2026-01-01", Table.table_edge(1100.0, "")) - 40.0).abs() < 0.001
		and (Table.row_h_for(notes, "2026-01-01", 1600.0) - 24.0).abs() < 0.001
		and List.len(Table.note_lines_at(notes, "2026-01-01", twelve, 1600.0)) == 1
		and List.len(Table.note_lines_at(notes, "2026-01-01", twelve, Table.table_edge(1100.0, ""))) == 2
}

# the wiring page_for lays rows out by: in a 1600px window the long note is
# one line, in a 1100px window two, and the panel state is not an input, so
# no row moves when it opens; the drawn lines follow the column (one at
# 1600px with the panel open, none at 1100px where the panel hides it)
expect {
	notes = [{ day: "2026-01-01", note: "45 min Full Body Strength with Rad Lopez + Evening Ride around the lake" }]
	(Table.row_h_at(notes, "2026-01-01", 1600.0) - 24.0).abs() < 0.001
		and (Table.row_h_at(notes, "2026-01-01", 1100.0) - 40.0).abs() < 0.001
		and List.len(Table.note_lines_in(notes, "2026-01-01", 1600.0, "2026-01-01")) == 1
		and List.len(Table.note_lines_in(notes, "2026-01-01", 1100.0, "2026-01-01")) == 0
}

# the panel shows a prefix of the day's blocks: once one does not fit, a
# shorter one after it does not jump the gap; the first block always draws
expect Table.blocks_fit([92.0, 92.0, 92.0, 108.0, 92.0], 382.0) == 3
expect Table.blocks_fit([500.0], 382.0) == 1
