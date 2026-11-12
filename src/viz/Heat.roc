import rr.Color
import rr.Draw
import Chrome
import Days
import Db
import Labels
import Scene
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

	# the row axis, Monday first: row r of the grid is day_labels[r]
	day_labels : List(Str)
	day_labels = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

	# %w gives 0=Sun..6=Sat; rows run Monday-first
	row_of : I64 -> I64
	row_of = |dow| if (dow == 0) (6) else dow - 1

	title_text : Str
	title_text = "training heat - one cell per day"

	hint_text : Str
	hint_text = "hover a cell to read the day      TAB  lifts      R  reload      S  screenshot      V  record      ESC quit"

	# the grid's top-left corner
	grid_x : F32
	grid_x = 96.0

	grid_y : F32
	grid_y = 130.0

	step : F32
	step = cell + gap

	# the cells on screen: the newest weeks the width holds, from the first
	# Monday inside the kept span so columns align, each with its corner and
	# row; the week advances when the row wraps past Sunday. `peak` is the
	# shown window's largest load.
	layout : Ui.Model -> { cells : List({ h : Db.HeatDay, x : F32, y : F32, r : I64 }), peak : I64 }
	layout = |model| {
		weeks_fit = match F32.round_to_u64_try(F32.div_floor_by(model.win.w - 120.0, step)) {
			Ok(wk) => if (wk < 4) (4.U64) else if (wk > 53) (53.U64) else wk
			# sizing failure clamps to the same floor a cramped window gets
			Err(_) => 4.U64
		}
		max_days = weeks_fit * 7
		kept = if (List.len(model.heat) > max_days) (List.take_last(model.heat, max_days)) else model.heat
		skip_to_monday = List.fold(List.map_with_index(kept, |h, i| { h, i }), 0.U64, |acc, x| if (acc == 0 and row_of(x.h.dow) == 0) (x.i + 1) else acc)
		days = if (skip_to_monday > 0) (List.drop_first(kept, skip_to_monday - 1)) else kept
		walk = List.fold(
			days,
			{ col: 0.U64, prev_row: -1, out: [] },
			|acc, h| {
				r = row_of(h.dow)
				col = if (r <= acc.prev_row) (acc.col + 1) else acc.col
				{ col, prev_row: r, out: List.append(acc.out, { h, x: grid_x + U64.to_f32(col) * step, y: grid_y + I64.to_f32(r) * step, r }) }
			},
		)
		{ cells: walk.out, peak: List.fold(days, 1, |a, h| if (h.tss > a) h.tss else a) }
	}

	# the grid's extent with the gold rings around event days
	grid_box : List({ h : Db.HeatDay, x : F32, y : F32, r : I64 }) -> Labels.Rect
	grid_box = |cells| {
		right = List.fold(cells, grid_x, |a, c| F32.max(a, c.x + cell))
		{ x: grid_x - 2.0, y: grid_y - 2.0, w: right - grid_x + 4.0, h: 7.0 * step - gap + 4.0 }
	}

	# the gold-ring legend's swatch, on the hint row left of the keys
	swatch : F32 -> Labels.Rect
	swatch = |win_h| { x: 36.0, y: win_h - 27.0, w: 10.0, h: 10.0 }

	# a month's first Monday: day of month 01..07, so every month's column
	# band gets exactly one tick
	first_monday : Str -> Bool
	first_monday = |day| {
		db = Str.to_utf8(day)
		d1 = (List.get(db, 8)) ?? 57
		d2 = (List.get(db, 9)) ?? 57
		d1 == 48 and d2 >= 49 and d2 <= 55
	}

	# the hovered cell's day, told on one line in a card under the grid
	tip : Ui.Model, Scene.Measure -> Try({ box : Labels.Rect, lines : List(Labels.Label(Scene.Item)) }, [NoHover])
	tip = |model, measure|
		match List.find_first((layout(model)).cells, |c| model.mouse_x >= c.x and model.mouse_x < c.x + cell and model.mouse_y >= c.y and model.mouse_y < c.y + cell) {
			Ok(c) => {
				note = Db.note_for(model.day_notes, c.h.day)
				# the note joins only when the day actually has one
				line = if (note == "rest day") ("${c.h.day}   ${Db.num_unit(c.h.tss, "tss")}") else "${c.h.day}   ${Db.num_unit(c.h.tss, "tss")}   ${note}"
				short = if (Str.count_utf8_bytes(line) > 70) (Str.concat(Str.from_utf8_lossy(List.take_first(Str.to_utf8(line), 68)), "..")) else line
				box = { x: grid_x, y: grid_y + 7.0 * step + 18.0, w: model.win.w - 132.0, h: 26.0 }
				Ok({ box, lines: [Scene.fixed(measure, Scene.data(short, 12.0, Color.white), { x: 108.0, y: box.y + 6.0, align: Left }, box)] })
			}
			Err(_) => Err(NoHover)
		}

	# ── every string the view writes, placed ───────────────────────────────
	# All of it is fixed: the title, the weekday names, the month ticks,
	# the legend, the footer and the mode chips.
	scene : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	scene = |model, measure| Labels.place(texts(model, measure), { boxes: Chrome.boxes(model, measure), segs: [] })

	# the view's text and the chrome's, as the gate judges them
	owned : Ui.Model, Scene.Measure -> List(Labels.Owned)
	owned = |model, measure| List.concat(Scene.owned(Chrome.placed(model, measure)), Scene.owned(scene(model, measure)))

	texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	texts = |model, measure| {
		win_h = model.win.h
		panel = Labels.panel(model.win)
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		fix = |it, x, y, align| Scene.fixed(measure, it, { x, y, align }, panel)
		head = [fix(Scene.prepared(model.heat_title, title_text, 15.0, Prose, ink_muted), Days.title_x, 70.0, Left)]
		grid =
			if List.is_empty(model.heat) {
				[fix(Scene.data("no training history yet", 14.0, ink_muted), 36.0, 130.0, Left)]
			} else {
				# every weekday row named, each label centred on its row, and a
				# month tick above each month's first Monday
				List.concat(
					List.map_with_index(day_labels, |t, r| fix(Scene.data(t, 10.0, ink_faint), grid_x - 10.0, grid_y + U64.to_f32(r) * step + cell / 2.0 - 5.0, Right)),
					List.keep_oks((layout(model)).cells, |c| if (c.r == 0 and first_monday(c.h.day)) Ok(fix(Scene.data(Str.from_utf8_lossy(List.take_first(List.drop_first(Str.to_utf8(c.h.day), 5), 2)), 10.0, ink_faint), c.x, grid_y - 16.0, Left)) else Err(NoTick)),
				)
			}
		# the gold-ring legend, shown only when a marked day is on screen: a
		# swatch and its word, so the ring in the grid is never a mystery.
		# Placed on the hint row, left of the keys, in the ring's own colour.
		foot =
			if List.is_empty(model.heat_events) {
				[fix(Scene.prepared(model.heat_hint, hint_text, 13.0, Prose, ink_faint), 36.0, win_h - 30.0, Left)]
			} else {
				[fix(Scene.data("event day", 11.0, ink_faint), 52.0, win_h - 28.0, Left), fix(Scene.prepared(model.heat_hint, hint_text, 13.0, Prose, ink_faint), 150.0, win_h - 30.0, Left)]
			}
		List.join([head, grid, foot, Days.chip_texts(model, measure)])
	}

	# the shapes no text may cover but its own: the pills, the mode chips,
	# the grid and the legend's swatch
	marks : Ui.Model -> List(Labels.Mark)
	marks = |model| {
		cells = (layout(model)).cells
		List.join([
			Chrome.marks(model),
			Days.chip_marks,
			if (List.is_empty(cells)) [] else [{ key: "the heat grid", box: grid_box(cells) }],
			if (List.is_empty(model.heat_events)) [] else [{ key: "the event-day swatch", box: swatch(model.win.h) }],
		])
	}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		lay = layout(model)
		List.for_each!(
			lay.cells,
			|c| {
				h = c.h
				# five intensity buckets on the brand blue; zero stays a socket
				a = if (h.tss <= 0) (0) else {
					q = h.tss * 4 // lay.peak
					if (q >= 4) (255) else 60 + q * 48
				}
				sty = if (a == 0) (Draw.filled(Theme.card)) else Draw.filled(Color.with_alpha(Theme.ctl_c, (I64.to_u8_try(a)) ?? 255))
				# event days ringed in GOLD, the app's colour for earned/marked
				# things (levels, records): it reads as "this day is marked",
				# and the legend names it so the meaning is not left to guess
				if List.contains(model.heat_events, h.day) {
					frame.rounded_rectangle!({ x: c.x - 2.0, y: c.y - 2.0, width: cell + 4.0, height: cell + 4.0, radius: 4.0, segments: 3, style: Draw.filled(Color.with_alpha(Theme.gold_c, 200)) })
				}
				frame.rounded_rectangle!({ x: c.x, y: c.y, width: cell, height: cell, radius: 3.0, segments: 3, style: sty })
			},
		)
		if !(List.is_empty(model.heat_events)) {
			s = swatch(model.win.h)
			frame.rounded_rectangle!({ x: s.x, y: s.y, width: s.w, height: s.h, radius: 3.0, segments: 3, style: Draw.filled(Color.with_alpha(Theme.gold_c, 200)) })
		}
		measure = Scene.measure_of(model)
		Scene.draw!(frame, model, scene(model, measure))
		# hover: the day's story in a card under the grid, over everything
		match tip(model, measure) {
			Ok(t) => {
				frame.rounded_rectangle!({ x: t.box.x, y: t.box.y, width: t.box.w, height: t.box.h, radius: 6.0, segments: 5, style: Draw.filled(Theme.card) })
				Scene.draw!(frame, model, Labels.place(t.lines, { boxes: [], segs: [] }))
			}
			Err(_) => {}
		}
		Ok({})
	}
}

# seven row labels, Monday first, the order row_of lays the grid in
expect Heat.day_labels == ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
# a month's first Monday falls on day 01 to 07 and on no other
expect Heat.first_monday("2026-11-02") and Heat.first_monday("2026-09-07") and !(Heat.first_monday("2026-11-09")) and !(Heat.first_monday("2026-10-31"))
