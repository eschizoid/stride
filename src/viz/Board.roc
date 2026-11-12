import rr.Color
import rr.Draw
import rr.Text
import Chrome
import Db
import Hud
import Labels
import Scene
import Theme
import Ui
import Wrap

Board :: [].{
	lo_of : List(Db.Point) -> F32
	lo_of = |pts| List.fold(pts, 0.0, |acc, p| F32.min(acc, p.tsb)) - 6.0
	hi_of : List(Db.Point) -> F32
	hi_of = |pts| List.fold(pts, 1.0, |acc, p| F32.max(acc, F32.max(p.ctl, p.atl))) + 8.0

	# the line-end labels' top edges: each wants its own height; taken top
	# to bottom, one starting less than `gap` below the label above it
	# starts `gap` below instead, so labels `gap` tall never overlap. The
	# result keeps the input's order
	end_tops : List(F32), F32 -> List(F32)
	end_tops = |wants, gap| {
		by_y = List.sort_with(List.map_with_index(wants, |y, i| { i, y }), |a, b| if (a.y < b.y) Before else if (a.y > b.y) After else if (a.i < b.i) Before else After)
		placed = List.fold(
			by_y,
			[],
			|acc, w| {
				y = match List.last(acc) {
					Ok(p) => F32.max(w.y, p.y + gap)
					Err(_) => w.y
				}
				List.append(acc, { i: w.i, y })
			},
		)
		List.map_with_index(
			wants,
			|y, i| match List.find_first(placed, |p| p.i == i) {
				Ok(p) => p.y
				Err(_) => y
			},
		)
	}

	# the KPI tile row: four cards on a fixed grid from the left edge, each
	# card tile_w wide and its text drawn 12px inside it. The event tile's
	# text sits in the fourth card by the same rule as the three numbers.
	tile_x : U64 -> F32
	tile_x = |i| 30.0 + U64.to_f32(i) * 234.0
	tile_text_x : U64 -> F32
	tile_text_x = |i| tile_x(i) + 12.0
	tile_w : F32
	tile_w = 222.0

	tile_top : F32
	tile_top = 88.0

	tile_box : U64 -> Labels.Rect
	tile_box = |i| { x: tile_x(i), y: tile_top, w: tile_w, h: tile_h }

	# the width a line of the event tile may take: the card less 12px each side
	ev_room : F32
	ev_room = tile_w - 24.0

	# the event name cut to one line of `cols` columns through the shared
	# rule, so a long name ends in "..."
	ev_title : Str, U64 -> Str
	ev_title = |name, cols| match List.first(Wrap.fit(name, cols, 1)) {
		Ok(l) => l
		Err(_) => ""
	}

	# the event tile's line for a name and a suffix, cut to ev_room by the
	# font's pure measure, which reads the same glyph metrics the host draws
	# from. The heading face is proportional, so no fixed advance holds for
	# every name: the cut shortens two columns at a time from the name's
	# length, capped at 64, until the line fits, and yields the narrowest
	# try when none does, so an overflow is visible rather than silent
	ev_line : Text.Font, Str, Str, F32 -> Str
	ev_line = |font, name, suffix, size| {
		n = U64.min(Str.count_utf8_bytes(name), 64)
		fits = |line| font.measure({ text: line, size, spacing: Text.default_spacing }).width <= ev_room
		steps = List.map_with_index(List.repeat({}, n / 2 + 1), |_, i| n - 2 * i)
		res = List.fold(
			steps,
			{ line: "", done: Bool.False },
			|st, cols|
				if (st.done) st
				else {
					line = "${ev_title(name, cols)}${suffix}"
					{ line, done: fits(line) }
				},
		)
		res.line
	}

	# the KPI band's height above the plot: the tiles and the header row. The
	# board's plot and its pointer hit-test both start this far below pad_t.
	band_h : F32
	band_h = 72.0

	tile_h : F32
	tile_h = 78.0

	# the event name in at most two lines of ev_room: words packed greedily
	# by the font's measure into the first line, the rest into the second.
	# ev_line cuts a word wider than a line, and a second line that does not
	# fit, so either ends in "..." and can break mid-word
	ev_lines : Text.Font, Str, F32 -> List(Str)
	ev_lines = |font, name, size| {
		fits = |line| font.measure({ text: line, size, spacing: Text.default_spacing }).width <= ev_room
		st = List.fold(
			Str.split_on(name, " "),
			{ line: "", rest: [], full: Bool.False },
			|acc, w|
				if (acc.full) { ..acc, rest: List.append(acc.rest, w) }
				else {
					cand = if (acc.line == "") w else "${acc.line} ${w}"
					if (fits(cand)) { ..acc, line: cand }
					else if (acc.line == "") { ..acc, line: w, full: Bool.True }
					else { ..acc, rest: [w], full: Bool.True }
				},
		)
		first = if (fits(st.line)) st.line else ev_line(font, st.line, "", size)
		if (List.is_empty(st.rest)) [first] else [first, ev_line(font, Str.join_with(st.rest, " "), "", size)]
	}

	# the event name in one line at 14, or two at 12 when it needs them
	ev_name : Text.Font, Str -> { lines : List(Str), size : F32 }
	ev_name = |font, name| {
		l14 = ev_lines(font, name, 14.0)
		if (List.len(l14) <= 1) { lines: l14, size: 14.0 } else { lines: ev_lines(font, name, 12.0), size: 12.0 }
	}

	# the board's projection, as two tile lines: where it ends (the event
	# when the written plan reaches it, else the plan's last day) with the
	# projected fitness and form, then how many of the window's sessions
	# carry a load the engine could price - the rest add none, so this count
	# is how blind the projection is
	proj_lines : Str, Str, Db.Projection -> List(Str)
	proj_lines = |horizon, event_day, p| {
		mmdd = Str.from_utf8_lossy(List.drop_first(Str.to_utf8(horizon), 5))
		head = if (horizon == event_day) "at event" else "plan to ${mmdd}"
		if (!p.ok or horizon == "") []
		else ["${head}: fit ${Db.fmt_f(p.ctl)}, form ${Db.fmt_f(p.tsb)}", "${I64.to_str(p.projected)} of ${I64.to_str(p.considered)} sessions carry load"]
	}

	clamp_idx : F32, U64 -> U64
	clamp_idx = |raw, hi_idx|
		if (raw <= 0.0) (0.U64)
		else match F32.round_to_u64_try(raw) {
			Ok(i) => if (i >= hi_idx) (hi_idx) else i
			Err(_) => hi_idx
		}

	# ── the board's strings: the window prepares each at load from these,
	# and the scene measures the same strings ───────────────────────────────
	hint_text : Str
	hint_text = "1/2/3 range   TAB view   hover or arrows to read a day   R reload   S screenshot   V record   G glow   ESC quit"

	empty_text : Str
	empty_text = "no data yet - sync and analyze first, then reopen"

	zero_text : Str
	zero_text = "fresh above"

	# the subtitle beside the legend: the range and the series' last day
	sub_text : U64, Str -> Str
	sub_text = |r, as_of| "last ${U64.to_str(r)} days, as of ${as_of}"

	as_of : List(Str) -> Str
	as_of = |days| (List.last(days)) ?? "no data"

	stale_text : List(Str) -> Str
	stale_text = |days|
		match List.last(days) {
			Ok(ld) => "data as of ${ld} - analyze to refresh"
			Err(_) => ""
		}

	# a series' value on a day: 0 fitness, 1 fatigue, 2 form
	value_of : Db.Point, U8 -> F32
	value_of = |p, sel| if (sel == 0) p.ctl else if (sel == 1) p.atl else p.tsb

	last_point : List(Db.Point) -> Db.Point
	last_point = |data| (List.last(data)) ?? { ctl: 0.0, atl: 0.0, tsb: 0.0, tss: 0.0 }

	sel_color : U8 -> Color.Rgba
	sel_color = |sel| if (sel == 0) Theme.ctl_c else if (sel == 1) Theme.atl_c else Theme.tsb_c

	# a KPI tile's number and caption, and a line's end label
	kpi_value : List(Db.Point), U8 -> Str
	kpi_value = |data, sel| Db.fmt_f(value_of(last_point(data), sel))

	kpi_caption : U8 -> Str
	kpi_caption = |sel| if (sel == 0) "fitness - 42-day load avg" else if (sel == 1) "fatigue - 7-day load avg" else "form - fitness minus fatigue"

	end_text : List(Db.Point), U8 -> Str
	end_text = |data, sel| "${if (sel == 0) "CTL" else if (sel == 1) "ATL" else "TSB"} ${kpi_value(data, sel)}"

	y_text : I64 -> Str
	y_text = |v| I64.to_str(v)

	# ── the layout the drawing, the scene and the gate share ───────────────
	# the range shown: its points and days, how many points the range cut
	# from the front of the series, the value span, and the plot on screen
	Geom : { data : List(Db.Point), days : List(Str), n : U64, off : U64, lo : F32, hi : F32, left : F32, top : F32, pw : F32, ph : F32 }

	geom : Ui.Model -> Geom
	geom = |model| {
		take = U64.min(model.range, List.len(model.data))
		data = List.take_last(model.data, take)
		top = Theme.pad_t + band_h
		{ data, days: List.take_last(model.days, take), n: List.len(data), off: List.len(model.data) - List.len(data), lo: lo_of(data), hi: hi_of(data), left: Theme.pad_l, top, pw: model.win.w - Theme.pad_l - Theme.pad_r, ph: model.win.h - top - Theme.pad_b }
	}

	# the plot draws once the series holds two days and no error stands
	plotted : Ui.Model -> Bool
	plotted = |model| !(model.has_error) and List.len(model.data) >= 2

	x_at : Geom, U64 -> F32
	x_at = |g, i| if (g.n <= 1) g.left else g.left + g.pw * U64.to_f32(i) / U64.to_f32(g.n - 1)

	y_at : Geom, F32 -> F32
	y_at = |g, v| g.top + g.ph * (1.0 - (v - g.lo) / (g.hi - g.lo))

	plot_box : Geom -> Labels.Rect
	plot_box = |g| { x: g.left, y: g.top, w: g.pw, h: g.ph }

	# daily load as a rug in its OWN scale along the bottom band, never on
	# the fitness/form axis: load peaks well above 50 and would rocket off
	# the top if it shared the axis. One bar per day with load, centred on
	# its day and clipped to the plot, so the first and last days draw half
	# a bar rather than reach under the axis labels and the line-end values.
	bars : Geom -> List({ day : Str, box : Labels.Rect })
	bars = |g| {
		bw = F32.max(1.5, g.pw / U64.to_f32(g.n) - 1.4)
		tss_max = F32.max(1.0, List.fold(g.data, 1.0, |acc, p| F32.max(acc, p.tss)))
		base = g.top + g.ph
		band = g.ph * rug_share
		List.keep_oks(
			List.map_with_index(g.data, |p, i| { p, i }),
			|e|
				if e.p.tss > 0.0 {
					bh = (e.p.tss / tss_max) * band
					x0 = F32.max(g.left, x_at(g, e.i) - bw / 2.0)
					x1 = F32.min(g.left + g.pw, x_at(g, e.i) + bw / 2.0)
					Ok({ day: (List.get(g.days, e.i)) ?? "", box: { x: x0, y: base - bh, w: x1 - x0, h: bh } })
				} else {
					Err(Rest)
				},
		)
	}

	# the three series as segments, for labels to keep clear of
	series_segs : Geom -> List(Labels.Seg)
	series_segs = |g|
		List.join(
			List.map(
				[0.U8, 1, 2],
				|sel| List.keep_oks(
					List.map_with_index(g.data, |p, i| { p, i }),
					|e| match List.get(g.data, e.i + 1) {
						Ok(nx) => Ok({ x0: x_at(g, e.i), y0: y_at(g, value_of(e.p, sel)), x1: x_at(g, e.i + 1), y1: y_at(g, value_of(nx, sel)) })
						Err(_) => Err(End)
					},
				),
			),
		)

	# which range is live: three chips, the active one filled
	range_chips : Ui.Model -> List({ box : Labels.Rect, on : Bool, r : U64, p : Text.Prepared })
	range_chips = |model| List.map_with_index(model.subs, |s, i| { box: { x: model.win.w - 420.0 + U64.to_f32(i) * 54.0, y: 64.0, w: 46.0, h: 22.0 }, on: s.r == model.range, r: s.r, p: s.chip })

	# the form verdict, worn as a status chip: the same TSB the teal line
	# ends on, said in a word - cooked / building / steady / primed /
	# coasting - so the board answers "how am I?" before any axis does
	verdict_box : F32 -> Labels.Rect
	verdict_box = |win_w| { x: win_w - 40.0 - 92.0, y: 64.0, w: 92.0, h: 22.0 }

	# the zero rule's caption spots: along the rule just above it, at its
	# right end, its left end, then stepping inward from the right; then
	# just past the rule's right end; then, when the rule runs inside the
	# load rug, the same row lifted in three steps to just above the
	# tallest bar, which no bar reaches. The placer takes the first spot
	# clear of every load bar and label and, among those, one no series
	# crosses.
	zero_spots : Geom -> List(Scene.Anchor)
	zero_spots = |g| {
		zy = y_at(g, 0.0)
		right = g.left + g.pw - 6.0
		along = |y| List.concat([{ x: right, y, align: Right }, { x: g.left + 6.0, y, align: Left }], List.map([1, 2, 3, 4, 5], |k| { x: right - g.pw * U64.to_f32(k) / 6.0, y, align: Right }))
		lift = F32.max(0.0, zy - 16.0 - (g.top + g.ph * (1.0 - rug_share) - 13.0))
		raised = if (lift > 0.0) List.join(List.map([1, 2, 3], |j| along(zy - 16.0 - lift * U64.to_f32(j) / 3.0))) else []
		List.join([along(zy - 16.0), [{ x: g.left + g.pw + 8.0, y: zy - 6.0, align: Left }], raised])
	}

	# the share of the plot's height the load rug's tallest bar takes
	rug_share : F32
	rug_share = 0.22

	# the series index the crosshair reads: the pointer while it is inside
	# the plot, else the arrow cursor counting days back from the latest
	hovered : Ui.Model, Geom -> Try(U64, [NoHover])
	hovered = |model, g| {
		hi_idx = g.n - 1
		mouse_sel = model.mouse_in and model.mouse_x >= g.left and model.mouse_x <= g.left + g.pw
		cur_back = if (model.cursor < 0) (0.U64) else match I64.to_u64_try(model.cursor) {
			Ok(c) => if (c > hi_idx) (hi_idx) else c
			Err(_) => 0.U64
		}
		if mouse_sel {
			Ok(clamp_idx((model.mouse_x - g.left) / g.pw * U64.to_f32(hi_idx), hi_idx))
		} else if model.cursor >= 0 {
			Ok(hi_idx - cur_back)
		} else {
			Err(NoHover)
		}
	}

	# the crosshair's card: date header, a colored row per series, then
	# what was actually done that day, wrapped by the shared rule at a 6.7px
	# glyph budget, up to four lines and cut past them; flipped left when
	# the cursor nears the right edge
	tip_card : Ui.Model, Geom, U64, Db.Point, Scene.Measure -> { box : Labels.Rect, lines : List(Labels.Label(Scene.Item)) }
	tip_card = |model, g, i, hp, measure| {
		hx = x_at(g, i)
		day = (List.get(g.days, i)) ?? ""
		tip_w = 240.0
		note_lines = Wrap.fit(Db.note_for(model.day_notes, day), Wrap.cols_for(tip_w - 20.0, 6.7), 4)
		tip_h = 107.0 + U64.to_f32(List.len(note_lines)) * 14.0 + 9.0
		tip_x = if (hx + 14.0 + tip_w > g.left + g.pw) (hx - 14.0 - tip_w) else hx + 14.0
		tip_y = g.top + 8.0
		box = { x: tip_x, y: tip_y, w: tip_w, h: tip_h }
		fix = |it, x, y, align| Scene.fixed(measure, it, { x, y, align }, box)
		rows = [
			{ lbl: "Fitness", v: Db.fmt_f(hp.ctl), c: Theme.ctl_c },
			{ lbl: "Fatigue", v: Db.fmt_f(hp.atl), c: Theme.atl_c },
			{ lbl: "Form", v: Db.fmt_f(hp.tsb), c: Theme.tsb_c },
			{ lbl: "Load", v: Db.fmt_f(hp.tss), c: Theme.ink_muted },
		]
		row_lines = List.join(
			List.map_with_index(
				rows,
				|r, ri| {
					ry = tip_y + 28.0 + U64.to_f32(ri) * 19.0
					[fix(Scene.data(r.lbl, 12.0, r.c), tip_x + 10.0, ry, Left), fix(Scene.data(r.v, 12.0, Color.white), tip_x + tip_w - 10.0, ry, Right)]
				},
			),
		)
		notes = List.map_with_index(note_lines, |ln, li| fix(Scene.data(ln, 11.0, Theme.ink_faint), tip_x + 10.0, tip_y + 107.0 + U64.to_f32(li) * 14.0, Left))
		{ box, lines: List.join([[fix(Scene.data(day, 12.0, Color.white), tip_x + 10.0, tip_y + 8.0, Left)], row_lines, notes]) }
	}

	# ── every string the view writes, placed ───────────────────────────────
	# Fixed text first: the chips, the tiles and the event tile, the
	# subtitle, the axes, the footer. Then the kept labels in priority order:
	# the line-end values (the tiles carry the same numbers), the event
	# warning and the zero rule's caption, each trying its spots and never
	# dropped. Last the event marker's name, which the event tile also
	# carries, so it may drop.
	scene : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	scene = |model, measure| Labels.place(texts(model, measure), obstacles(model, measure))

	# the view's text and the chrome's, as the gate judges them
	owned : Ui.Model, Scene.Measure -> List(Labels.Owned)
	owned = |model, measure| List.concat(Scene.owned(Chrome.placed(model, measure)), Scene.owned(scene(model, measure)))

	prio_end : U64
	prio_end = 1

	prio_warn : U64
	prio_warn = 2

	prio_zero : U64
	prio_zero = 3

	prio_event : U64
	prio_event = 4

	texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	texts = |model, measure| {
		win_w = model.win.w
		win_h = model.win.h
		panel = Labels.panel(model.win)
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		fix = |it, x, y, align, region| Scene.fixed(measure, it, { x, y, align }, region)
		g = geom(model)
		verdict = match List.last(model.data) {
			Ok(lp) => {
				band = Hud.form_band(lp.tsb)
				[fix(Scene.data(band.label, 12.0, band.c), win_w - 106.0, 69.0, Left, verdict_box(win_w))]
			}
			Err(_) => []
		}
		tiles = List.join(
			List.map_with_index(
				model.kpis,
				|k, i| [
					fix(Scene.prepared(k.v, kpi_value(model.data, k.sel), 27.0, Data, sel_color(k.sel)), tile_text_x(i), 94.0, Left, tile_box(i)),
					fix(Scene.prepared(k.cap, kpi_caption(k.sel), 11.0, Prose, ink_faint), tile_text_x(i), 127.0, Left, tile_box(i)),
				],
			),
		)
		# the event tile: the name in one line, or two smaller ones, then the
		# date line, then the projection's two lines; a recent ridden event
		# takes the projection's place when there is no projection to show
		ev_box = tile_box(3)
		ev_x = tile_text_x(3)
		name_n = List.len(model.ev_tile_name)
		ev_tile = List.join([
			List.map_with_index(model.ev_tile_name, |t, i| fix(Scene.txt(t, Prose, ink_muted), ev_x, (if (name_n > 1) 93.0 else 96.0) + U64.to_f32(i) * 15.0, Left, ev_box)),
			[fix(Scene.txt(model.ev_tile_sub, Prose, ink_faint), ev_x, 124.0, Left, ev_box)],
			List.map_with_index(model.ev_tile_proj, |t, i| fix(Scene.txt(t, Prose, ink_faint), ev_x, 140.0 + U64.to_f32(i) * 13.0, Left, ev_box)),
			if (model.ridden_found and List.is_empty(model.ev_tile_proj)) [fix(Scene.txt(model.ridden_note, Prose, ink_faint), ev_x, 140.0, Left, ev_box)] else [],
		])
		chips = List.map(range_chips(model), |c| fix(Scene.prepared(c.p, "${U64.to_str(c.r)}d", 12.0, Data, if (c.on) Color.white else ink_muted), c.box.x + c.box.w / 2.0, 68.0, Center, c.box))
		# the subtitle clears the legend's third label, "form"
		sub = List.keep_oks(model.subs, |s| if (s.r == model.range) Ok(fix(Scene.prepared(s.p, sub_text(s.r, as_of(model.days)), 15.0, Prose, ink_muted), 330.0, 70.0, Left, panel)) else Err(Other))
		# an event the database could not read says so inside the plot's top
		# corner, right first: the header rows belong to the pills and chips
		warn =
			if model.ev_warn_found {
				[Scene.kept(measure, Scene.txt(model.ev_warn, Prose, Theme.atl_c), [{ x: g.left + g.pw - 6.0, y: g.top + 4.0, align: Right }, { x: g.left + 6.0, y: g.top + 4.0, align: Left }], prio_warn, panel)]
			} else {
				[]
			}
		# bottom-right status corner, mirroring the hint line
		stale = if (model.stale_found) [fix(Scene.prepared(model.stale, stale_text(model.days), 13.0, Prose, ink_faint), win_w - 40.0, win_h - 30.0, Right, panel)] else []
		body =
			if model.has_error {
				[fix(Scene.txt(model.status, Prose, Theme.atl_c), 36.0, g.top + 20.0, Left, panel)]
			} else if List.len(model.data) < 2 {
				[fix(Scene.prepared(model.empty, empty_text, 16.0, Prose, ink_muted), 36.0, g.top + 20.0, Left, panel)]
			} else {
				List.append(plot_texts(model, measure, g), fix(Scene.prepared(model.hint, hint_text, 13.0, Prose, ink_faint), 34.0, win_h - 30.0, Left, panel))
			}
		List.join([verdict, tiles, ev_tile, chips, sub, warn, stale, body])
	}

	plot_texts : Ui.Model, Scene.Measure, Geom -> List(Labels.Label(Scene.Item))
	plot_texts = |model, measure, g| {
		panel = Labels.panel(model.win)
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		fix = |it, x, y, align| Scene.fixed(measure, it, { x, y, align }, panel)
		# only the gridlines the computed range contains: the prepared set
		# spans -30..100, which covers the common PMC window; a value outside
		# it plots fine but gets no gridline
		ylabels = List.keep_oks(model.ylabels, |yl| if (yl.v >= g.lo and yl.v <= g.hi) Ok(fix(Scene.prepared(yl.p, y_text(F32.round_to_i64_try(yl.v) ?? 0), 12.0, Data, ink_faint), 30.0, y_at(g, yl.v) - 8.0, Left)) else Err(Off))
		# six date labels under the plot
		dates = List.keep_oks(
			[0.U64, 1, 2, 3, 4, 5],
			|k| {
				di = k * (g.n - 1) // 5
				match List.get(g.days, di) {
					Ok(d) => Ok(fix(Scene.data(Str.drop_first_bytes(d, 5) ?? d, 11.0, ink_faint), x_at(g, di), g.top + g.ph + 8.0, Center))
					Err(_) => Err(NoDay)
				}
			},
		)
		# the current values at the line ends, spread so none overlaps the
		# next
		last = last_point(g.data)
		tops = end_tops(List.map(model.ends, |e| y_at(g, value_of(last, e.sel)) - 7.0), 15.0)
		ex2 = g.left + g.pw + 8.0
		ends = List.map2(model.ends, tops, |e, top| Scene.kept(measure, Scene.prepared(e.p, end_text(model.data, e.sel), 13.0, Data, sel_color(e.sel)), [{ x: ex2, y: top, align: Left }], prio_end, panel))
		zero = Scene.kept(measure, Scene.prepared(model.zero_note, zero_text, 11.0, Prose, ink_faint), zero_spots(g), prio_zero, panel)
		# the event marker's name beside its dashed line, left first. ev_idx
		# indexes the full series, so it shifts by the days the range cut.
		event =
			if model.ev_found and model.ev_idx >= g.off {
				ex = x_at(g, model.ev_idx - g.off)
				[Scene.free(measure, Scene.txt(model.ev_label, Prose, ink_muted), [{ x: ex - 6.0, y: g.top + 4.0, align: Right }, { x: ex + 6.0, y: g.top + 4.0, align: Left }], prio_event, plot_box(g))]
			} else {
				[]
			}
		List.join([ylabels, dates, ends, [zero], event])
	}

	# what the board's labels keep off: the chrome, the chips, the tiles and
	# the load bars, and the three series lines
	obstacles : Ui.Model, Scene.Measure -> Labels.Obstacles
	obstacles = |model, measure| {
		shapes = List.join([Chrome.boxes(model, measure), List.map(range_chips(model), |c| c.box), [verdict_box(model.win.w)], List.map([0, 1, 2, 3], tile_box)])
		if plotted(model) {
			g = geom(model)
			{ boxes: List.concat(shapes, List.map(bars(g), |b| b.box)), segs: series_segs(g) }
		} else {
			{ boxes: shapes, segs: [] }
		}
	}

	# the shapes no text may cover but its own: the pills, the chips, the
	# tiles and every load bar
	marks : Ui.Model -> List(Labels.Mark)
	marks = |model| {
		shapes = List.join([
			Chrome.marks(model),
			List.map(range_chips(model), |c| { key: "the ${U64.to_str(c.r)}d chip", box: c.box }),
			if (List.is_empty(model.data)) [] else [{ key: "the form chip", box: verdict_box(model.win.w) }],
			List.map([0, 1, 2, 3], |i| { key: "tile ${U64.to_str(i + 1)}", box: tile_box(i) }),
		])
		if (plotted(model)) List.concat(shapes, List.map(bars(geom(model)), |b| { key: "the load bar on ${b.day}", box: b.box })) else shapes
	}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		measure = Scene.measure_of(model)
		ink_muted = Theme.ink_muted
		ctl_c = Theme.ctl_c
		atl_c = Theme.atl_c
		tsb_c = Theme.tsb_c
		_ = match List.last(model.data) {
			Ok(lp) => {
				band = Hud.form_band(lp.tsb)
				vb = verdict_box(model.win.w)
				frame.rounded_rectangle!({ x: vb.x, y: vb.y, width: vb.w, height: vb.h, radius: 7.0, segments: 6, style: Draw.filled(Theme.card) })
				frame.circle!({ center: { x: vb.x + 14.0, y: vb.y + 11.0 }, radius: 4.0, style: Draw.filled(band.c) })
			}
			Err(_) => {}
		}
		# the artifact's tile cards: a lifted rounded panel behind each number
		List.for_each!(
			[0, 1, 2, 3],
			|i| {
				b = tile_box(i)
				frame.rounded_rectangle!({ x: b.x, y: b.y, width: b.w, height: b.h, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
			},
		)
		List.for_each!(
			range_chips(model),
			|c| {
				# hovered chips lift a shade, matching the pointer's promise
				hov = model.mouse_x >= c.box.x and model.mouse_x <= c.box.x + c.box.w and model.mouse_y >= c.box.y and model.mouse_y <= c.box.y + c.box.h
				style = if (c.on) (Draw.filled(Color.with_alpha(ctl_c, 60))) else if (hov) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
				frame.rounded_rectangle!({ x: c.box.x, y: c.box.y, width: c.box.w, height: c.box.h, radius: 6.0, segments: 6, style })
			},
		)
		if plotted(model) {
			g = geom(model)
			n = g.n
			x_max = g.left + g.pw
			List.for_each!(
				model.ylabels,
				|yl|
					if yl.v >= g.lo and yl.v <= g.hi {
						gy = y_at(g, yl.v)
						frame.line!({ start: { x: g.left, y: gy }, end: { x: x_max, y: gy }, stroke: Draw.stroke(Color.with_alpha(Color.white, 18), 1) })
					},
			)
			# dotted, as the artifact draws it: 4px dash, 6px gap
			zy = y_at(g, 0.0)
			List.for_each!(
				List.map_with_index(List.repeat({}, 84), |_u, k| k),
				|k| {
					dx = g.left + U64.to_f32(k) * 10.0
					if dx + 4.0 <= x_max {
						frame.line!({ start: { x: dx, y: zy }, end: { x: dx + 4.0, y: zy }, stroke: Draw.stroke(Color.with_alpha(Color.white, 55), 1) })
					}
				},
			)
			List.for_each!(bars(g), |b| frame.rectangle!({ x: b.box.x, y: b.box.y, width: b.box.w, height: b.box.h, style: Draw.filled(Color.with_alpha(ink_muted, 55)) }))
			# soft fill under fitness
			List.for_each!(
				List.map_with_index(g.data, |p, i| { i, v: p.ctl }),
				|cur|
					match List.get(g.data, cur.i + 1) {
						Ok(_) => frame.rectangle!({ x: x_at(g, cur.i), y: y_at(g, cur.v), width: (g.pw / U64.to_f32(n - 1)) + 1.0, height: zy - y_at(g, cur.v), style: Draw.filled(Color.with_alpha(ctl_c, 12)) })
						Err(_) => {}
					},
			)
			# the event marker: a dashed vertical, its name in the scene
			if model.ev_found and model.ev_idx >= g.off {
				ex = x_at(g, model.ev_idx - g.off)
				List.for_each!(
					List.map_with_index(List.repeat({}, 40), |_u, k| k),
					|k| {
						y0 = g.top + U64.to_f32(k) * 12.0
						if y0 + 6.0 <= g.top + g.ph {
							frame.line!({ start: { x: ex, y: y0 }, end: { x: ex, y: y0 + 6.0 }, stroke: Draw.stroke(Color.with_alpha(Color.white, 70), 1) })
						}
					},
				)
			}
			# the draw-in: for half a second after arriving on this view, each
			# series sweeps left to right - segments beyond the eased progress
			# fraction simply wait their turn
			age_in = model.tick - model.view_anim
			sweep = if (model.view_anim == 0 or age_in >= 30) (1.0) else {
				p = U64.to_f32(age_in) / 30.0
				1.0 - (1.0 - p) * (1.0 - p)
			}
			draw_line! = |sel, col| {
				limit = sweep * U64.to_f32(n - 1)
				List.for_each!(
					List.map_with_index(g.data, |p, i| { i, v: value_of(p, sel) }),
					|cur|
						if U64.to_f32(cur.i) < limit {
							match List.get(g.data, cur.i + 1) {
								Ok(nxt) => frame.line!({ start: { x: x_at(g, cur.i), y: y_at(g, cur.v) }, end: { x: x_at(g, cur.i + 1), y: y_at(g, value_of(nxt, sel)) }, stroke: Draw.stroke(col, 2) })
								Err(_) => {}
							}
						},
				)
			}
			draw_line!(2, tsb_c)
			draw_line!(1, atl_c)
			draw_line!(0, ctl_c)
		}
		Scene.draw!(frame, model, scene(model, measure))
		# hover OR arrow-cursor: the selected day gets a crosshair and dots,
		# and its values print in a card over everything
		if plotted(model) {
			g = geom(model)
			match hovered(model, g) {
				Ok(i) => {
					hx = x_at(g, i)
					frame.line!({ start: { x: hx, y: g.top }, end: { x: hx, y: g.top + g.ph }, stroke: Draw.stroke(Color.with_alpha(Color.white, 60), 1) })
					match List.get(g.data, i) {
						Ok(hp) => {
							frame.circle!({ center: { x: hx, y: y_at(g, hp.ctl) }, radius: 3.5, style: Draw.filled(ctl_c) })
							frame.circle!({ center: { x: hx, y: y_at(g, hp.atl) }, radius: 3.5, style: Draw.filled(atl_c) })
							frame.circle!({ center: { x: hx, y: y_at(g, hp.tsb) }, radius: 3.5, style: Draw.filled(tsb_c) })
							card = tip_card(model, g, i, hp, measure)
							frame.rounded_rectangle!({ x: card.box.x, y: card.box.y, width: card.box.w, height: card.box.h, radius: 6.0, segments: 6, style: Draw.filled(Theme.card) })
							Scene.draw!(frame, model, Labels.place(card.lines, { boxes: [], segs: [] }))
						}
						Err(_) => {}
					}
				}
				Err(_) => {}
			}
		}
		Ok({})
	}
}

# every tile's text sits 12px inside its own card, and the event tile's room
# ends 12px before the card does
expect List.all([0.U64, 1, 2, 3], |i| Board.tile_text_x(i) - Board.tile_x(i) == 12.0)
expect Board.ev_room + 24.0 == Board.tile_w
expect Board.ev_title("Tour de Chi (62/100/150mi options)", 28) == "Tour de Chi (62/100/150mi..."
expect Board.ev_title("no event planned", 28) == "no event planned"

# the line is cut by the font's own measure: on the stub font (one unit per
# glyph per unit of size, one unit between) a size-10 line holds eighteen
# glyphs in ev_room, so a long name ends in "...", a short name passes whole,
# a suffix survives the cut, and one long word is cut inside the room
expect Board.ev_line(Text.font_stub, "Tour de Chi (62/100/150mi options)", "", 10.0) == "Tour de Chi..."
expect Board.ev_line(Text.font_stub, "no event planned", "", 10.0) == "no event planned"
expect Board.ev_line(Text.font_stub, "Tour de Chi (62/100/150mi options)", " done, 3d ago", 10.0) == "T... done, 3d ago"
expect {
	word = Board.ev_line(Text.font_stub, "Supercalifragilisticexpialidocious", "", 10.0)
	Str.ends_with(word, "...") and Text.font_stub.measure({ text: word, size: 10.0, spacing: Text.default_spacing }).width <= Board.ev_room
}

# end labels: two that want nearly the same height are pushed apart by the
# gap, the upper one keeping its place; labels already apart stay put; the
# answer keeps the order the labels came in
expect Board.end_tops([100.0, 98.0, 200.0], 15.0) == [113.0, 98.0, 200.0]
expect Board.end_tops([50.0, 100.0, 150.0], 15.0) == [50.0, 100.0, 150.0]
expect Board.end_tops([100.0, 100.0, 100.0], 15.0) == [100.0, 115.0, 130.0]

# a name that fits stays one line; a longer one packs whole words into two
# lines, each within ev_room, and only overflow past the second ends in "..."
expect Board.ev_lines(Text.font_stub, "no event planned", 10.0) == ["no event planned"]
expect {
	ls = Board.ev_lines(Text.font_stub, "Tour de Chi (62/100/150mi options)", 10.0)
	List.len(ls) == 2 and List.all(ls, |l| Text.font_stub.measure({ text: l, size: 10.0, spacing: Text.default_spacing }).width <= Board.ev_room)
}
expect Str.ends_with(Str.join_with(Board.ev_lines(Text.font_stub, "one two three four five six seven eight nine ten eleven twelve thirteen", 10.0), " "), "...")

# the projection names where it ends - the event only when the plan reaches
# it - and how many of the window's sessions carry load
expect Board.proj_lines("2026-11-08", "2027-06-26", { ok: Bool.True, ctl: 46.0, tsb: 14.3, considered: 4, projected: 1 }) == ["plan to 11-08: fit 46.0, form 14.3", "1 of 4 sessions carry load"]
expect Board.proj_lines("2027-06-26", "2027-06-26", { ok: Bool.True, ctl: 52.5, tsb: -3.2, considered: 40, projected: 12 }) == ["at event: fit 52.5, form -3.2", "12 of 40 sessions carry load"]
expect Board.proj_lines("2026-11-08", "2027-06-26", { ok: Bool.False, ctl: 0.0, tsb: 0.0, considered: 0, projected: 0 }) == []
expect Board.proj_lines("", "", { ok: Bool.True, ctl: 1.0, tsb: 1.0, considered: 1, projected: 1 }) == []

# the zero rule's caption keeps the right end of the rule unless a series
# crosses it there and the left end is clear; a series along the whole rule
# sends it past the rule's right end; a load bar under the right end sends
# it left, and with both ends under bars it steps inward to the first clear
# spot
expect {
	g = { data: [], days: [], n: 30, off: 0, lo: -10.0, hi: 70.0, left: 64.0, top: 182.0, pw: 830.0, ph: 362.0 }
	caption = { w: 55.0, h: 11.0, spots: List.map(Board.zero_spots(g), |a| { x: Labels.left_of(a.x, 55.0, a.align), y: a.y }), prio: 0, keep: Bool.True, region: { x: 16.0, y: 16.0, w: 948.0, h: 568.0 }, item: {} }
	at = |obs| List.map(Labels.place([caption], obs), |p| p.box.x)
	zy = Board.y_at(g, 0.0)
	right_x = 64.0 + 830.0 - 6.0 - 55.0
	across_right = { x0: right_x, y0: zy - 10.0, x1: 894.0, y1: zy - 10.0 }
	bar = |x| { x, y: zy - 30.0, w: 26.0, h: 400.0 }
	at({ boxes: [], segs: [] }) == [right_x]
		and at({ boxes: [], segs: [across_right] }) == [70.0]
		and at({ boxes: [], segs: [{ x0: 64.0, y0: zy - 10.0, x1: 894.0, y1: zy - 10.0 }] }) == [902.0]
		and at({ boxes: [bar(870.0)], segs: [] }) == [70.0]
		and at({ boxes: [bar(870.0), bar(80.0)], segs: [] }) == [64.0 + 830.0 - 6.0 - 830.0 / 6.0 - 55.0]
}
