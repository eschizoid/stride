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

	# the cards the board draws: the three numbers only once the series holds
	# a day to read them from, since a 0.0 there would stand for "nothing
	# yet"; the event card always
	tiles_shown : Ui.Model -> List(U64)
	tiles_shown = |model| if (List.is_empty(model.data)) [3] else [0, 1, 2, 3]

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

	# a board with no day to draw names the command that fills it, and R
	# loads what that command wrote: setup while no activity exists, analyze
	# while activities exist unscored (Chrome.no_scored_text). One day on
	# record is a series too short for a line, not an empty database
	empty_text : Str
	empty_text = "no data yet - run stride setup in a terminal to connect Strava, then press R"

	one_day_text : Str
	one_day_text = "one day on record so far - the chart draws from the second"

	zero_text : Str
	zero_text = "fresh above"

	# the subtitle beside the legend: the range and the series' last day
	sub_text : U64, Str -> Str
	sub_text = |r, day| "last ${U64.to_str(r)} days, as of ${day}"

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
	# the range shown: its measured days followed by the projected ones, how
	# many of them were measured, how many points the range cut from the
	# front of the series, the value span over both, and the plot on screen
	Geom : { data : List(Db.Point), days : List(Str), n : U64, meas : U64, off : U64, lo : F32, hi : F32, left : F32, top : F32, pw : F32, ph : F32 }

	# a projected day as a plotted point, its load the plan's priced load
	proj_point : Db.ProjDay -> Db.Point
	proj_point = |d| { ctl: d.ctl, atl: d.atl, tsb: d.tsb, tss: d.tss }

	geom : Ui.Model -> Geom
	geom = |model| {
		take = U64.min(model.range, List.len(model.data))
		measured = List.take_last(model.data, take)
		proj = shown_proj(model)
		data = List.concat(measured, List.map(proj, proj_point))
		days = List.concat(List.take_last(model.days, take), List.map(proj, |d| d.day))
		top = Theme.pad_t + band_h
		{ data, days, n: List.len(data), meas: take, off: List.len(model.data) - take, lo: lo_of(data), hi: hi_of(data), left: Theme.pad_l, top, pw: model.win.w - Theme.pad_l - Theme.pad_r, ph: model.win.h - top - Theme.pad_b }
	}

	# the projected days the plot draws after the measured ones: a
	# projection continues a plotted series, so a board too short to plot
	# draws none
	shown_proj : Ui.Model -> List(Db.ProjDay)
	shown_proj = |model| if (U64.min(model.range, List.len(model.data)) >= 2) model.proj else []

	# a projected day's index in the plot, when `i` is one
	proj_day : Ui.Model, Geom, U64 -> Try(Db.ProjDay, [Measured])
	proj_day = |model, g, i| if (i < g.meas) Err(Measured) else List.get(model.proj, i - g.meas).map_err(|_| Measured)

	# the day cursor as the arrow keys walk it: `back` days before the
	# latest measured day (-1 off), or `ahead` projected days after it
	Cursor : { back : I64, ahead : U64 }

	# one arrow press. Older steps a day back, and from off lands on the
	# latest measured day; Newer steps a day forward, on past the latest
	# measured day into the `projected` days the board draws, and past the
	# last of those turns the cursor off
	step : Cursor, [Older, Newer], U64 -> Cursor
	step = |c, dir, projected|
		match dir {
			Older =>
				if (c.ahead > 0) { back: 0, ahead: c.ahead - 1 }
				else if (c.back < 0) { back: 0, ahead: 0 }
				else { back: c.back + 1, ahead: 0 }
			Newer =>
				if (c.back > 0) { back: c.back - 1, ahead: 0 }
				else if (c.back == 0 and c.ahead < projected) { back: 0, ahead: c.ahead + 1 }
				else { back: -1, ahead: 0 }
		}

	# the views that draw the plan's projection: the form board alone, so a
	# cursor on a projected day exists there and nowhere else
	draws_projection : U8 -> Bool
	draws_projection = |view| view == 0

	# the cursor a view holds: a view that draws no projection holds the
	# latest measured day in place of a projected one, so the table never
	# stands on, or reports, a day it does not show
	held : Cursor, U8 -> Cursor
	held = |c, view| if (c.back < 0) { back: -1, ahead: 0 } else if (draws_projection(view)) c else { back: c.back, ahead: 0 }

	# the cursor a day names on `view`: a measured day of the series, or a
	# projected day when the view draws the projection. Any other day is
	# refused with the reason in the athlete's words: not a date, before the
	# series, past the projection's last day, after the series with no plan
	# projected, or a projected day on a view that draws no projection
	cursor_at : Ui.Model, Str, U8 -> Try(Cursor, Str)
	cursor_at = |model, day, view| {
		total = List.len(model.days)
		measured = List.keep_oks(List.map_with_index(model.days, |d, i| { d, i }), |e| if (e.d == day) (U64.to_i64_try(total - 1 - e.i)) else Err(OutOfRange))
		proj = shown_proj(model)
		projected = List.keep_oks(List.map_with_index(proj, |p, i| { p, i }), |e| if (e.p.day == day) Ok(e.i + 1) else Err(Other))
		first = (List.first(model.days)) ?? ""
		last = (List.last(model.days)) ?? ""
		match (List.last(measured), List.first(projected)) {
			(Ok(back), _) => Ok({ back, ahead: 0 })
			(_, Ok(ahead)) => if (draws_projection(view)) Ok({ back: 0, ahead }) else Err("a projected day, and this view draws no projection")
			_ =>
				if !(is_date(day)) {
					Err("not a YYYY-MM-DD date")
				} else if total == 0 {
					Err("no series is loaded")
				} else if earlier(day, first) {
					Err("before the series, which starts ${first}")
				} else if earlier(last, day) {
					match List.last(proj) {
						Ok(p) => Err("past the projection's last day, ${p.day}")
						Err(_) => Err("after the last measured day, ${last}, and no plan is projected")
					}
				} else {
					Err("a day missing from the series")
				}
		}
	}

	# a date in the canonical YYYY-MM-DD form the series stores
	is_date : Str -> Bool
	is_date = |s| {
		b = Str.to_utf8(s)
		digit = |c| c >= '0' and c <= '9'
		List.len(b) == 10 and List.all(List.map_with_index(b, |c, i| if (i == 4 or i == 7) c == '-' else digit(c)), |ok| ok)
	}

	# whether canonical date `a` falls before `b`: for YYYY-MM-DD the byte
	# order is the date order
	earlier : Str, Str -> Bool
	earlier = |a, b| {
		walk = List.fold(
			List.map2(Str.to_utf8(a), Str.to_utf8(b), |x, y| { x, y }),
			Same,
			|acc, p|
				match acc {
					Same => if (p.x < p.y) Before else if (p.x > p.y) After else Same
					_ => acc
				},
		)
		walk == Before
	}

	# the projected day `ahead` days past the latest measured one, clamped
	# to the last the board draws; "" when it draws none
	ahead_day : Ui.Model, U64 -> Str
	ahead_day = |model, ahead| {
		proj = shown_proj(model)
		n = List.len(proj)
		if ahead == 0 or n == 0 {
			""
		} else {
			match List.get(proj, U64.min(ahead, n) - 1) {
				Ok(p) => p.day
				Err(_) => ""
			}
		}
	}

	# the key under the legend: what the dashed part is, and how much of the
	# plan's load it carries
	proj_key_text : I64, I64 -> Str
	proj_key_text = |considered, projected| "dashed: projected, ${I64.to_str(projected)} of ${I64.to_str(considered)} sessions priced"

	# a line through `pts` cut into dashes `on` long with `off` between,
	# measured by distance along the whole line from its first point, so the
	# rhythm runs on through every corner; a dash a corner splits is drawn
	# as one piece on each side, and the last dash stops at the line's end
	dashes_along : List({ x : F32, y : F32 }), F32, F32 -> List({ a : { x : F32, y : F32 }, b : { x : F32, y : F32 } })
	dashes_along = |pts, on, off| {
		period = on + off
		spans = List.fold(
			List.drop_first(pts, 1),
			{ prev: List.first(pts), dist: 0.0, out: [] },
			|acc, p1|
				match acc.prev {
					Ok(p0) => {
						dx = p1.x - p0.x
						dy = p1.y - p0.y
						len = F32.sqrt(dx * dx + dy * dy)
						{ prev: Ok(p1), dist: acc.dist + len, out: List.append(acc.out, { p0, dx, dy, len, start: acc.dist }) }
					}
					Err(_) => { prev: Ok(p1), dist: acc.dist, out: acc.out }
				},
		)
		List.join(
			List.map(
				spans.out,
				|s|
					if s.len <= 0.0 {
						[]
					} else {
						at = |d| { x: s.p0.x + s.dx * (d - s.start) / s.len, y: s.p0.y + s.dy * (d - s.start) / s.len }
						k0 = F32.round_to_u64_try(F32.div_floor_by(s.start, period)) ?? 0
						k1 = F32.round_to_u64_try(F32.div_floor_by(s.start + s.len, period)) ?? 0
						List.keep_oks(
							List.map_with_index(List.repeat({}, k1 - k0 + 1), |_u, j| U64.to_f32(k0 + j) * period),
							|d0| {
								a = F32.max(d0, s.start)
								b = F32.min(d0 + on, s.start + s.len)
								if (b > a) Ok({ a: at(a), b: at(b) }) else Err(Gap)
							},
						)
					},
			),
		)
	}

	# the projected stretch of one series as the draw-in has reached it:
	# from the latest measured day through each projected day whose segment
	# starts before `limit`, the index the sweep has drawn up to; none when
	# the board draws no projection
	proj_line : Geom, U8, F32 -> List({ x : F32, y : F32 })
	proj_line = |g, sel, limit|
		if g.n <= g.meas or g.meas == 0 {
			[]
		} else {
			List.keep_oks(
				List.map_with_index(g.data, |p, i| { p, i }),
				|e| if (e.i + 1 == g.meas or (e.i >= g.meas and U64.to_f32(e.i) - 1.0 < limit)) Ok({ x: x_at(g, e.i), y: y_at(g, value_of(e.p, sel)) }) else Err(Off),
			)
		}

	# the height the projection key's two candidate rows take at the top of
	# the plot, the first at 4 px below its top and the second 18 px lower
	key_rows_h : F32
	key_rows_h = 36.0

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
	# A projected day's bar is the plan's priced load on the same scale,
	# `planned`, and a day the plan priced nothing onto draws none.
	bars : Geom -> List({ day : Str, box : Labels.Rect, planned : Bool })
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
					Ok({ day: (List.get(g.days, e.i)) ?? "", box: { x: x0, y: base - bh, w: x1 - x0, h: bh }, planned: e.i >= g.meas })
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

	# the series index the crosshair reads: the parked cursor (arrows or a
	# directive), counting days back from the latest measured day or
	# projected days on past it, held to the days the board draws; else the
	# pointer while it is inside the plot, projected days included. A pointer
	# that moves un-parks the cursor (update!), so a resting one never hides
	# the day a directive or an arrow parked on
	hovered : Ui.Model, Geom -> Try(U64, [NoHover])
	hovered = |model, g| {
		hi_idx = g.n - 1
		last_meas = if (g.meas == 0) 0 else g.meas - 1
		mouse_sel = model.mouse_in and model.mouse_x >= g.left and model.mouse_x <= g.left + g.pw
		cur_back = if (model.cursor < 0) (0.U64) else match I64.to_u64_try(model.cursor) {
			Ok(c) => if (c > last_meas) (last_meas) else c
			Err(_) => 0.U64
		}
		if model.cursor >= 0 {
			if (model.cursor_ahead > 0) Ok(U64.min(last_meas + model.cursor_ahead, hi_idx)) else Ok(last_meas - cur_back)
		} else if mouse_sel {
			Ok(clamp_idx((model.mouse_x - g.left) / g.pw * U64.to_f32(hi_idx), hi_idx))
		} else {
			Err(NoHover)
		}
	}

	# the crosshair's card: date header, a colored row per series, then
	# what was actually done that day, wrapped by the shared rule at a 6.7px
	# glyph budget, up to four lines and cut past them; flipped left when
	# the cursor nears the right edge. A projected day says so in its
	# header and reads its load as the plan's, and a day holding a session
	# the engine could not price says that rather than showing a load; it
	# carries no done line, since nothing on it has been done yet.
	tip_card : Ui.Model, Geom, U64, Db.Point, Scene.Measure -> { box : Labels.Rect, lines : List(Labels.Label(Scene.Item)) }
	tip_card = |model, g, i, hp, measure| {
		hx = x_at(g, i)
		day = (List.get(g.days, i)) ?? ""
		tip_w = 240.0
		planned = proj_day(model, g, i)
		note_lines =
			match planned {
				Ok(_) => []
				Err(_) => Wrap.fit(Db.note_for(model.day_notes, day), Wrap.cols_for(tip_w - 20.0, 6.7), 4)
			}
		tip_h = 107.0 + U64.to_f32(List.len(note_lines)) * 14.0 + 9.0
		tip_x = if (hx + 14.0 + tip_w > g.left + g.pw) (hx - 14.0 - tip_w) else hx + 14.0
		# under the projection key's two rows whenever the board draws one, for
		# a measured day as for a projected one: a card beside a measured day
		# near the projection spans the column the key starts in
		tip_y = if (g.n > g.meas) g.top + key_rows_h + 8.0 else g.top + 8.0
		box = { x: tip_x, y: tip_y, w: tip_w, h: tip_h }
		fix = |it, x, y, align| Scene.fixed(measure, it, { x, y, align }, box)
		load_row = match planned {
			Ok(pd) => { lbl: "Planned load", v: planned_load_text(pd) }
			Err(_) => { lbl: "Load", v: Db.fmt_f(hp.tss) }
		}
		head = match planned {
			Ok(_) => "${day} projected"
			Err(_) => day
		}
		rows = [
			{ lbl: "Fitness", v: Db.fmt_f(hp.ctl), c: Theme.ctl_c },
			{ lbl: "Fatigue", v: Db.fmt_f(hp.atl), c: Theme.atl_c },
			{ lbl: "Form", v: Db.fmt_f(hp.tsb), c: Theme.tsb_c },
			{ lbl: load_row.lbl, v: load_row.v, c: Theme.ink_muted },
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
		{ box, lines: List.join([[fix(Scene.data(head, 12.0, Color.white), tip_x + 10.0, tip_y + 8.0, Left)], row_lines, notes]) }
	}

	# a projected day's load as the card reads it: the priced load, with
	# "+ unpriced" when a session on the day carries none, or only
	# "unpriced" when nothing on it was priced
	planned_load_text : Db.ProjDay -> Str
	planned_load_text = |pd|
		if pd.known {
			Db.fmt_f(pd.tss)
		} else if pd.tss > 0.0 {
			"${Db.fmt_f(pd.tss)} + unpriced"
		} else {
			"unpriced"
		}

	# ── every string the view writes, placed ───────────────────────────────
	# Fixed text first: the chips, the tiles and the event tile, the
	# subtitle, the axes, the stale note. Then the kept labels in priority
	# order: the line-end values, the event warning, the zero rule's caption
	# and the projection's key, each trying its spots and never dropped.
	# Last the labels that may drop: the event marker's name, which the
	# event tile also carries, and the key hint, which yields its row to
	# the stale note when a face is too wide for both.
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

	prio_key : U64
	prio_key = 4

	prio_event : U64
	prio_event = 5

	prio_hint : U64
	prio_hint = 6

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
				if (List.is_empty(model.data)) [] else model.kpis,
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
		# the subtitle clears the legend's third label, "form", and names the
		# series' last day, so a board with no day carries none
		sub = List.keep_oks(model.subs, |s| if (s.r == model.range and !(List.is_empty(model.days))) Ok(fix(Scene.prepared(s.p, sub_text(s.r, as_of(model.days)), 15.0, Prose, ink_muted), 330.0, 70.0, Left, panel)) else Err(Other))
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
			} else if Chrome.unscored(model) {
				[fix(Scene.prose(Chrome.no_scored_text, 16.0, ink_muted), 36.0, g.top + 20.0, Left, panel)]
			} else if List.is_empty(model.data) {
				[fix(Scene.prepared(model.empty, empty_text, 16.0, Prose, ink_muted), 36.0, g.top + 20.0, Left, panel)]
			} else if List.len(model.data) < 2 {
				[fix(Scene.prose(one_day_text, 16.0, ink_muted), 36.0, g.top + 20.0, Left, panel)]
			} else {
				# the key hint shares the footer row with the stale note, and gives
				# it the row in a face too wide for both
				List.append(plot_texts(model, measure, g), Scene.free(measure, Scene.prepared(model.hint, hint_text, 13.0, Prose, ink_faint), [{ x: 34.0, y: win_h - 30.0, align: Left }], prio_hint, panel))
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
		# six date labels under the plot, spread evenly over its days; a series
		# shorter than six days has fewer distinct days than labels, and each
		# day is labelled once
		date_idx = List.fold(
			[0.U64, 1, 2, 3, 4, 5],
			[],
			|acc, k| {
				di = k * (g.n - 1) // 5
				if (List.contains(acc, di)) acc else List.append(acc, di)
			},
		)
		dates = List.keep_oks(
			date_idx,
			|di| {
				match List.get(g.days, di) {
					Ok(d) => Ok(fix(Scene.data(Str.drop_first_bytes(d, 5) ?? d, 11.0, ink_faint), x_at(g, di), g.top + g.ph + 8.0, Center))
					Err(_) => Err(NoDay)
				}
			},
		)
		# the values the lines end on, spread so none overlaps the next: the
		# projection's last day when the board draws one, else the latest
		# measured day. Each starts just past the plot and, in a face too
		# wide for that, ends on the panel's edge instead
		last = last_point(g.data)
		tops = end_tops(List.map(model.ends, |e| y_at(g, value_of(last, e.sel)) - 7.0), 15.0)
		ex2 = g.left + g.pw + 8.0
		ends = List.map2(model.ends, tops, |e, top| Scene.kept(measure, Scene.prepared(e.p, end_text(g.data, e.sel), 13.0, Data, sel_color(e.sel)), [{ x: ex2, y: top, align: Left }, { x: panel.x + panel.w, y: top, align: Right }], prio_end, panel))
		zero = Scene.kept(measure, Scene.prepared(model.zero_note, zero_text, 11.0, Prose, ink_faint), zero_spots(g), prio_zero, panel)
		# the projection's key along the plot's top: just past the last
		# measured day, then the plot's right end, then the same two a row
		# lower
		key =
			if g.n > g.meas {
				kx = x_at(g, g.meas - 1) + 8.0
				rx = g.left + g.pw - 6.0
				[Scene.kept(measure, Scene.txt(model.proj_key, Prose, ink_faint), [{ x: kx, y: g.top + 4.0, align: Left }, { x: rx, y: g.top + 4.0, align: Right }, { x: kx, y: g.top + 22.0, align: Left }, { x: rx, y: g.top + 22.0, align: Right }], prio_key, plot_box(g))]
			} else {
				[]
			}
		# the event marker's name beside its dashed line, left first. ev_idx
		# indexes the full series, so it shifts by the days the range cut.
		event =
			if model.ev_found and model.ev_idx >= g.off {
				ex = x_at(g, model.ev_idx - g.off)
				[Scene.free(measure, Scene.txt(model.ev_label, Prose, ink_muted), [{ x: ex - 6.0, y: g.top + 4.0, align: Right }, { x: ex + 6.0, y: g.top + 4.0, align: Left }], prio_event, plot_box(g))]
			} else {
				[]
			}
		List.join([ylabels, dates, ends, [zero], key, event])
	}

	# what the board's labels keep off: the chrome, the chips, the tiles and
	# the load bars, and the three series lines
	obstacles : Ui.Model, Scene.Measure -> Labels.Obstacles
	obstacles = |model, measure| {
		shapes = List.join([Chrome.boxes(model, measure), List.map(range_chips(model), |c| c.box), [verdict_box(model.win.w)], List.map(tiles_shown(model), tile_box)])
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
			List.map(tiles_shown(model), |i| { key: "tile ${U64.to_str(i + 1)}", box: tile_box(i) }),
		])
		if (plotted(model)) List.concat(shapes, List.map(bars(geom(model)), |b| { key: if (b.planned) "the planned load bar on ${b.day}" else "the load bar on ${b.day}", box: b.box })) else shapes
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
			tiles_shown(model),
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
			# a measured day's load fills its bar; a planned day's is hollow
			List.for_each!(bars(g), |b| frame.rectangle!({ x: b.box.x, y: b.box.y, width: b.box.w, height: b.box.h, style: if (b.planned) Draw.outlined(Color.with_alpha(ink_muted, 140), 1.0) else Draw.filled(Color.with_alpha(ink_muted, 55)) }))
			# soft fill under fitness, over the measured days only
			List.for_each!(
				List.map_with_index(g.data, |p, i| { i, v: p.ctl }),
				|cur|
					if cur.i + 1 < g.meas {
						frame.rectangle!({ x: x_at(g, cur.i), y: y_at(g, cur.v), width: (g.pw / U64.to_f32(n - 1)) + 1.0, height: zy - y_at(g, cur.v), style: Draw.filled(Color.with_alpha(ctl_c, 12)) })
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
						if U64.to_f32(cur.i) < limit and cur.i + 1 < g.meas {
							match List.get(g.data, cur.i + 1) {
								Ok(nxt) => frame.line!({ start: { x: x_at(g, cur.i), y: y_at(g, cur.v) }, end: { x: x_at(g, cur.i + 1), y: y_at(g, value_of(nxt, sel)) }, stroke: Draw.stroke(col, 2) })
								Err(_) => {}
							}
						},
				)
				List.for_each!(dashes_along(proj_line(g, sel, limit), 5.0, 4.0), |d| frame.line!({ start: d.a, end: d.b, stroke: Draw.stroke(col, 2) }))
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
expect Board.proj_lines("2026-11-08", "2027-06-26", { ok: Bool.True, ctl: 46.0, tsb: 14.3, considered: 4, projected: 1, days: [] }) == ["plan to 11-08: fit 46.0, form 14.3", "1 of 4 sessions carry load"]
expect Board.proj_lines("2027-06-26", "2027-06-26", { ok: Bool.True, ctl: 52.5, tsb: -3.2, considered: 40, projected: 12, days: [] }) == ["at event: fit 52.5, form -3.2", "12 of 40 sessions carry load"]
expect Board.proj_lines("2026-11-08", "2027-06-26", { ok: Bool.False, ctl: 0.0, tsb: 0.0, considered: 0, projected: 0, days: [] }) == []
expect Board.proj_lines("", "", { ok: Bool.True, ctl: 1.0, tsb: 1.0, considered: 1, projected: 1, days: [] }) == []

# the zero rule's caption keeps the right end of the rule unless a series
# crosses it there and the left end is clear; a series along the whole rule
# sends it past the rule's right end; a load bar under the right end sends
# it left, and with both ends under bars it steps inward to the first clear
# spot
expect {
	g = { data: [], days: [], n: 30, meas: 30, off: 0, lo: -10.0, hi: 70.0, left: 64.0, top: 182.0, pw: 830.0, ph: 362.0 }
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

# a dashed line: dashes of `on` from its start with `off` between, the
# last cut at the line's end, none for a line of no length; the rhythm is
# measured along the whole line, so a corner splits the dash it falls in
# and the next segment takes up the pattern where the last left it
expect {
	near = |a, b| (a - b).abs() < 0.001
	flat = |ds| List.map(ds, |d| [d.a.x, d.a.y, d.b.x, d.b.y])
	same = |ds, want| List.len(ds) == List.len(want) and List.all(List.map2(flat(ds), want, |got, w| List.len(got) == 4 and List.all(List.map2(got, w, near), |ok| ok)), |ok| ok)
	same(Board.dashes_along([{ x: 10.0, y: 50.0 }, { x: 30.0, y: 50.0 }], 5.0, 4.0), [[10.0, 50.0, 15.0, 50.0], [19.0, 50.0, 24.0, 50.0], [28.0, 50.0, 30.0, 50.0]])
		and List.is_empty(Board.dashes_along([{ x: 10.0, y: 50.0 }, { x: 10.0, y: 50.0 }], 5.0, 4.0))
		and List.is_empty(Board.dashes_along([{ x: 10.0, y: 50.0 }], 5.0, 4.0))
		and same(Board.dashes_along([{ x: 0.0, y: 0.0 }, { x: 3.0, y: 0.0 }, { x: 3.0, y: 10.0 }], 5.0, 4.0), [[0.0, 0.0, 3.0, 0.0], [3.0, 0.0, 3.0, 2.0], [3.0, 6.0, 3.0, 10.0]])
		and same(Board.dashes_along([{ x: 0.0, y: 0.0 }, { x: 7.0, y: 0.0 }, { x: 7.0, y: 10.0 }], 5.0, 4.0), [[0.0, 0.0, 5.0, 0.0], [7.0, 2.0, 7.0, 7.0]])
}

# the key names the dashed part and how many sessions are priced; a
# projected day's card reads the priced load, says when a session on it
# went unpriced, and never prints a load for a day nothing was priced onto
expect Board.proj_key_text(20, 17) == "dashed: projected, 17 of 20 sessions priced"
expect Board.planned_load_text({ day: "2026-12-01", ctl: 1.0, atl: 1.0, tsb: 0.0, tss: 45.0, known: Bool.True }) == "45.0"
expect Board.planned_load_text({ day: "2026-12-01", ctl: 1.0, atl: 1.0, tsb: 0.0, tss: 45.0, known: Bool.False }) == "45.0 + unpriced"
expect Board.planned_load_text({ day: "2026-12-01", ctl: 1.0, atl: 1.0, tsb: 0.0, tss: 0.0, known: Bool.False }) == "unpriced"
