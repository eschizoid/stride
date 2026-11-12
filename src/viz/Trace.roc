import rr.Color
import rr.Draw
import rr.Text
import core.Fmt
import core.Sports
import core.Units
import Chrome
import Db
import Labels
import Scene
import Theme
import Ui
import Wrap

Trace :: [].{
	# The y grid step for a plot whose ceiling is `hi`: enough rules to read a
	# level off the trace, few enough that the labels do not collide. It comes
	# from the ceiling rather than being fixed per unit, because watts and
	# heart rate span different ranges on the same axis.
	y_step : F32 -> F32
	y_step = |hi|
		if (hi <= 60.0) (10.0)
		else if (hi <= 150.0) (25.0)
		else if (hi <= 300.0) (50.0)
		else if (hi <= 600.0) (100.0)
		else if (hi <= 1500.0) (250.0)
		else 500.0

	# The pace channel's samples are metres per second, spanning single
	# digits where watts span hundreds - so it gets its own step, and its
	# gridline labels render as pace through core.Units rather than as bare
	# small integers nobody runs by. Higher on the axis is faster; the pace
	# strings shrink going up, which is the direction a runner expects
	# "better" to read.
	y_step_pace : F32 -> F32
	y_step_pace = |hi|
		if (hi <= 2.0) (0.25)
		else if (hi <= 4.0) (0.5)
		else 1.0

	# the metres a fixed-distance pace axis counts per unit (100 for "min/100m",
	# 500 for "min/500m"), 0 on the athlete's kilometre or mile axis
	fixed_pace_m : Str -> I64
	fixed_pace_m = |unit|
		List.fold(["Swim", "Rowing"], 0, |acc, fam| if (unit == Str.concat("min", Sports.pace_unit(fam).label)) Sports.pace_unit(fam).dist_m else acc)

	expect fixed_pace_m(Db.swim_pace_unit) == 100 and fixed_pace_m("min/500m") == 500 and fixed_pace_m(Units.pace_unit(Metric)) == 0

	# a speed on a pace trace read as the pace its axis names: per 100 m on
	# a swim's axis, per 500 m on the erg's, the athlete's kilometre or mile
	# otherwise
	trace_pace : Str, [Metric, Imperial], F64 -> Str
	trace_pace = |unit, units, mps| {
		m = fixed_pace_m(unit)
		if (m == 0) (Units.pace_from_speed(units, mps))
		else if (mps <= 0.0) "-"
		else Fmt.mmss(F64.round_to_i64_try(I64.to_f64(m) / mps) ?? 0)
	}

	expect trace_pace(Db.swim_pace_unit, Metric, 1.0) == "1:40" and trace_pace(Units.pace_unit(Metric), Metric, 4.0) == "4:10" and trace_pace("min/500m", Imperial, 4.0) == "2:05"

	# one split's pace on the trace's own axis, and the distance its header
	# names: a 100 m swim split reads per 100 m, a 500 m erg split per 500 m
	split_pace : Str, [Metric, Imperial], F64, I64 -> Str
	split_pace = |unit, units, distance_m, secs| {
		m = fixed_pace_m(unit)
		if (m == 0) (Units.pace_per_dist(units, distance_m, secs))
		else if (distance_m <= 0.0 or secs <= 0) "-"
		else Fmt.mmss(F64.round_to_i64_try(I64.to_f64(secs) * I64.to_f64(m) / distance_m) ?? 0)
	}

	split_head : Str, [Metric, Imperial] -> Str
	split_head = |unit, units| {
		m = fixed_pace_m(unit)
		if (m == 0) "splits (${Units.dist_unit(units)})" else "splits (${I64.to_str(m)} m)"
	}

	expect split_pace(Db.swim_pace_unit, Metric, 100.0, 104) == "1:44" and split_pace("min/500m", Metric, 500.0, 118) == "1:58" and split_pace(Units.pace_unit(Metric), Metric, 1000.0, 300) == "5:00"
	expect split_head(Db.swim_pace_unit, Imperial) == "splits (100 m)" and split_head(Units.pace_unit(Imperial), Imperial) == "splits (mi)"

	# the pace channel is recognized by its unit label - the one channel
	# whose unit begins "min/" in either unit culture
	pace_axis : Str -> Bool
	pace_axis = |unit| Str.starts_with(unit, "min/")

	# tested against the REAL labels the channel carries, so the predicate
	# cannot drift from what Units actually emits
	expect pace_axis(Units.pace_unit(Metric)) and pace_axis(Units.pace_unit(Imperial))
	expect !pace_axis("W") and !pace_axis("bpm")
	expect y_step_pace(3.5) == 0.5
	expect y_step_pace(1.4) == 0.25
	expect y_step_pace(6.0) == 1.0

	# The x grid step in SECONDS. The visible span is the session divided by
	# the zoom, so zooming in earns finer ticks instead of holding the
	# whole-session spacing and labelling nothing.
	x_step : F32, F32 -> F32
	x_step = |dur, zoom| {
		vis = if (zoom > 0.0) (dur / zoom) else dur
		if (vis <= 120.0) (15.0)
		else if (vis <= 300.0) (30.0)
		else if (vis <= 900.0) (60.0)
		else if (vis <= 1800.0) (300.0)
		else if (vis <= 5400.0) (600.0)
		else 1800.0
	}

	# Elapsed seconds as m:ss — the axis reads as a clock, which is how a
	# session is remembered, rather than as a sample count.
	fmt_clock : F32 -> Str
	fmt_clock = |s| {
		t = match F32.round_to_u64_try(F32.max(s, 0.0)) {
			Ok(v) => v
			Err(_) => 0.U64
		}
		ss = t % 60
		"${U64.to_str(t // 60)}:${if (ss < 10) ("0") else ""}${U64.to_str(ss)}"
	}

	expect {
		# a ride peaking near 500W and a strength session's heart rate land on
		# different steps from the same function
		y_step(550.0) == 100.0
			and y_step(198.0) == 50.0
			and y_step(40.0) == 10.0
			and y_step(3000.0) == 500.0
	}

	expect {
		# a 45-minute session unzoomed gets 10-minute ticks. At 10x the visible
		# span is 270s, which earns 30s ticks — the step follows what is ON
		# SCREEN, not the session length
		x_step(2700.0, 1.0) == 600.0
			and x_step(2700.0, 2.0) == 300.0
			and x_step(2700.0, 10.0) == 30.0
			# a zoom of zero cannot divide: the whole session stands in
			and x_step(2700.0, 0.0) == 600.0
	}

	expect {
		fmt_clock(0.0) == "0:00"
			and fmt_clock(600.0) == "10:00"
			and fmt_clock(65.0) == "1:05"
			# a negative never reaches the axis, but it must not underflow U64
			and fmt_clock(-5.0) == "0:00"
	}

	# the sessions strength_sets can hold rows for: the WeightTraining family
	# (Sports.canonical), the gate the engine's rebuild of strength_sets joins
	# on through activity_family_month
	strength_session : Str -> Bool
	strength_session = |sport| Sports.canonical(sport) == "WeightTraining"

	# one stored row as the panel prints it: the exercise name cut to 32
	# columns, sets x reps or sets x seconds for a hold, then the weight when
	# one was moved, in the mass units the lifts tab uses (Db.mass_units), so
	# the same set reads the same weight on both
	set_line : [Metric, Imperial], Db.SetRow -> Str
	set_line = |units, r| {
		shape = if (r.hold_s > 0) "${I64.to_str(r.sets)}x${I64.to_str(r.hold_s)}s hold" else "${I64.to_str(r.sets)}x${I64.to_str(r.reps)}"
		w = if (r.kg > 0.0) " @ ${Units.mass_label(units, r.kg)}" else ""
		name = match List.first(Wrap.fit(r.exercise, 32, 1)) {
			Ok(n) => n
			Err(_) => ""
		}
		"${name}  ${shape}${w}"
	}

	# the empty panel says which absence it is: text in the description that
	# no adapter read, or nothing logged at all
	no_sets_note : Bool -> Str
	no_sets_note = |pasted| if (pasted) "no sets read - the description holds text no adapter parsed" else "no sets logged"

	# whether the selected session is a lifting one
	lifting_shown : Ui.Model -> Bool
	lifting_shown = |model| match List.get(model.trace_ids, model.trace_sel) {
		Ok(te) => strength_session(te.sport)
		Err(_) => Bool.False
	}

	# the lines a lifting session's sets panel prints: the stored rows, at
	# most 18, or the empty-state note
	panel_lines : Ui.Model -> List(Str)
	panel_lines = |model|
		if (!lifting_shown(model)) []
		else if (List.is_empty(model.trace_sets.rows)) [no_sets_note(model.trace_sets.pasted)]
		else List.map(List.take_first(model.trace_sets.rows, 18), |r| set_line(model.strength.mass, r))

	# the plot's right padding: a lifting session's sets panel takes its own
	# column, as wide as its longest line, so the trace never runs under the
	# text. The pointer's zoom and pan read the same padding.
	right_pad : Ui.Model -> F32
	right_pad = |model| {
		w = List.fold(panel_lines(model), 0.0, |acc, l| F32.max(acc, model.font.measure({ text: l, size: 11.0, spacing: Text.default_spacing }).width))
		if (w > 0.0) (Theme.pad_r + panel_room(w + 24.0, model.win.w - Theme.pad_l - Theme.pad_r)) else Theme.pad_r
	}

	# the column never takes more than panel_share of the room the plot has,
	# so the plot keeps a positive width at any window size; set_line caps a
	# name's length so a line rarely needs more
	panel_share : F32
	panel_share = 0.45

	panel_room : F32, F32 -> F32
	panel_room = |want, room| F32.max(0.0, F32.min(want, room * panel_share))

	# ── session trace view (TAB) ────────────────────────────────────────────
	# One session's measured trace, with the detector's blocks shaded BEHIND it
	# where it found any, so the two can be compared by eye — which is the
	# whole point: a table of segments cannot show you that a "work" block
	# started thirty seconds before the effort did. The plotted channel varies
	# per session; model.trace_unit names what the samples count. The shapes
	# draw from geom and every string from scene, so the drawing, the label
	# placer and the gate read one layout.
	hint_text : Str
	hint_text = "[ / ]  older/newer session      X  sport filter      shift+[ / shift+]  ghost older/newer      C  clear ghost      wheel zoom  drag pan  0 reset      TAB  plan"

	# the keys every view shares, after the trace's own on the footer row
	keys_text : Str
	keys_text = "R  reload      S  screenshot      V  record      ESC quit"

	# the plot on screen and the ceiling both traces are judged against: one
	# scale, or the comparison lies
	Geom : { left : F32, top : F32, pw : F32, ph : F32, hi : F32 }

	geom : Ui.Model -> Geom
	geom = |model| {
		hi = F32.max(List.fold(model.trace, 1.0, |a, v| F32.max(a, v)), List.fold(model.ghost, 1.0, |a, v| F32.max(a, v))) * 1.1
		{ left: Theme.pad_l, top: Theme.pad_t, pw: model.win.w - Theme.pad_l - right_pad(model), ph: model.win.h - Theme.pad_t - Theme.pad_b, hi }
	}

	y_at : Geom, F32 -> F32
	y_at = |g, w| g.top + g.ph * (1.0 - w / g.hi)

	# every x runs through the camera: the visible window is [pan, pan +
	# 1/zoom] of the session, in session-fraction space
	cam : Ui.Model, Geom, F32 -> F32
	cam = |model, g, frac| g.left + g.pw * (frac - model.trace_pan) * model.trace_zoom

	# The heading is built per frame rather than prepared once, because it
	# describes THIS session: both the channel it plots and whether the
	# detector found any blocks in it vary from one session to the next. A
	# lifting session has no power or pace for the detector to read, so its
	# heading names the channel only and the sets panel speaks for it.
	heading : Ui.Model -> Str
	heading = |model| {
		nsegs = List.len(List.keep_if(model.segs, |sg| sg.kind == "work"))
		what = if (model.trace_unit == "bpm") ("heart rate") else if (pace_axis(model.trace_unit)) ("pace") else "power"
		blocks =
			if (List.is_empty(model.trace) or lifting_shown(model)) ("")
			else if (nsegs == 0) (" - no intervals detected")
			else if (nsegs == 1) (" - 1 detected block shaded behind it") else " - ${U64.to_str(nsegs)} detected blocks shaded behind it"
		"${what} trace${blocks}"
	}

	# The y grid: a value at each step under the ceiling, so a level can be
	# read off the plot instead of guessed. The axis starts at zero, the same
	# origin the trace itself is scaled against. A pace gridline says the
	# pace, not the raw m/s the samples are stored in.
	y_grid : Ui.Model, Geom -> List({ v : F32, label : Str })
	y_grid = |model, g| {
		is_pace = pace_axis(model.trace_unit)
		ystep = if (is_pace) (y_step_pace(g.hi)) else y_step(g.hi)
		ycount = (F32.round_to_u64_try(F32.div_floor_by(g.hi, ystep))) ?? 0
		# the step reaches F64 through a millimetre integer - exact for every
		# step this file chooses, and the label math wants F64
		ystep64 = (F32.round_to_u64_try(ystep * 1000.0) ?? 0).to_f64() / 1000.0
		List.keep_oks(
			List.map_with_index(List.repeat({}, ycount), |_u, k| k),
			|k| {
				gv = (U64.to_f32(k) + 1.0) * ystep
				lbl = if (is_pace) (trace_pace(model.trace_unit, model.units, ((k).to_f64() + 1.0) * ystep64)) else (F32.round_to_u64_try(gv) ?? 0).to_str()
				if (gv < g.hi) Ok({ v: gv, label: lbl }) else Err(Above)
			},
		)
	}

	# The x grid: elapsed time. Every tick runs through the same camera as
	# the trace, so a panned or zoomed view stays labelled correctly; ticks
	# the camera puts outside the plot are skipped rather than clamped, which
	# would stack them on the edge.
	x_grid : Ui.Model, Geom -> List({ x : F32, s : F32 })
	x_grid = |model, g| {
		xstep = x_step(model.trace_dur, model.trace_zoom)
		xcount = (F32.round_to_u64_try(F32.div_floor_by(model.trace_dur, xstep))) ?? 0
		List.keep_oks(
			List.map_with_index(List.repeat({}, xcount + 1), |_u, k| U64.to_f32(k) * xstep),
			|s| {
				x = cam(model, g, s / model.trace_dur)
				if (x >= g.left and x <= g.left + g.pw) Ok({ x, s }) else Err(Outside)
			},
		)
	}

	# the camera's zoom when it is anywhere but home
	zoom_text : F32 -> Str
	zoom_text = |zoom| {
		zoom10 = (F32.round_to_u64_try(zoom * 10.0)) ?? 10
		"zoom ${U64.to_str(zoom10 // 10)}.${U64.to_str(zoom10 % 10)}x   0 resets"
	}

	# ── every string the view writes, placed ───────────────────────────────
	# Everything is fixed text but three labels. The channel's unit keeps:
	# right-aligned above the value column, else from the plot's left edge.
	# The camera's zoom note keeps: at the top of the right column, else
	# inside the plot's top-left corner, since the sets and splits panels
	# start just below it. The keys every view shares are free and drop
	# when the footer row has no room for them.
	scene : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	scene = |model, measure| Labels.place(texts(model, measure), obstacles(model, measure))

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
		right = win_w - 34.0
		fix = |it, x, y, align| Scene.fixed(measure, it, { x, y, align }, panel)
		head = [fix(Scene.data(heading(model), 15.0, ink_muted), 36.0, 70.0, Left)]
		# Which session, said the way a human remembers one: its NAME first,
		# then the date, sport and picker position, then the filter X is
		# holding - a mode key with no visible mode reads as a dead key.
		picker =
			if List.is_empty(model.trace_ids) {
				[]
			} else {
				sel = (List.get(model.trace_ids, model.trace_sel)) ?? { id: 0, day: model.trace_day, name: "", sport: "", chan: "" }
				filt = if (model.trace_sport == "") ("all sports") else "${model.trace_sport} only"
				ghost =
					if model.ghost_day != "" {
						gname = List.fold(model.trace_ids, "", |acc, ge| if (ge.day == model.ghost_day) ge.name else acc)
						[fix(Scene.data("ghost (purple): ${gname}  ${model.ghost_day}   C clears", 12.0, Theme.atl_c), right, 110.0, Right)]
					} else {
						[]
					}
				List.concat(
					[
						fix(Scene.data(sel.name, 13.0, Color.white), right, 70.0, Right),
						fix(Scene.data("${sel.day}   ${sel.sport}   ${U64.to_str(model.trace_sel + 1)}/${U64.to_str(List.len(model.trace_ids))}   showing ${filt} (X cycles)", 12.0, ink_muted), right, 90.0, Right),
					],
					ghost,
				)
			}
		# the splits panel: the pace channel's companion, one row per pace
		# unit's distance (100 m swimming, 500 m rowing, the athlete's
		# kilometre or mile on foot), read on the trace's own axis. Capped to
		# what fits beside the plot; the overflow line says how many rows it
		# holds back rather than letting the session appear to end early.
		splits =
			if pace_axis(model.trace_unit) and !(List.is_empty(model.trace_splits)) {
				shown = List.take_first(model.trace_splits, 14)
				extra = List.len(model.trace_splits) - List.len(shown)
				List.join([
					[fix(Scene.data(split_head(model.trace_unit, model.units), 11.0, ink_muted), right, 136.0, Right)],
					List.map_with_index(shown, |r, i| fix(Scene.data("${I64.to_str(r.n)}  ${split_pace(model.trace_unit, model.units, r.distance_m, r.elapsed_s)}", 11.0, ink_faint), right, 154.0 + U64.to_f32(i) * 16.0, Right)),
					if (extra > 0) [fix(Scene.data("+${U64.to_str(extra)} more", 10.0, ink_faint), right, 154.0 + 14.0 * 16.0, Right)] else [],
				])
			} else {
				[]
			}
		# the sets panel: a lifting session's stored sets in order, holds
		# included, capped to what fits beside the plot with an overflow line
		sets =
			if lifting_shown(model) {
				lines = panel_lines(model)
				extra = if (List.is_empty(model.trace_sets.rows)) 0 else List.len(model.trace_sets.rows) - List.len(lines)
				List.join([
					[fix(Scene.data("sets", 11.0, ink_muted), right, 136.0, Right)],
					List.map_with_index(lines, |l, i| fix(Scene.data(l, 11.0, ink_faint), right, 154.0 + U64.to_f32(i) * 16.0, Right)),
					if (extra > 0) [fix(Scene.data("+${U64.to_str(extra)} more", 10.0, ink_faint), right, 154.0 + 18.0 * 16.0, Right)] else [],
				])
			} else {
				[]
			}
		# The plot is blank for one of two reasons, and they must not read
		# alike. A LOAD IN FLIGHT: only the boot-cached session is in memory,
		# so switching to any other blanks the plot until its samples arrive
		# off the main loop (trace_loading, latched from the fetch spawn) -
		# saying "no samples" there is a lie the athlete reads as data loss.
		# GENUINELY EMPTY: the session is loaded and its chosen channel holds
		# nothing - the menu gates on the stream key being present, an empty
		# array passes that, and the CASE prefers watts, so an empty watts
		# array blanks the plot while a full heart-rate array sits beside it;
		# a failed query blanks the same way. That blank says why. An empty
		# picker stays quiet - there is no session for either message.
		plot =
			if List.is_empty(model.trace) {
				if model.trace_loading {
					[fix(Scene.data("loading trace...", 13.0, ink_muted), win_w / 2.0, win_h / 2.0, Center)]
				} else if !(List.is_empty(model.trace_ids)) {
					[fix(Scene.data("this session's stream holds no plottable samples", 13.0, ink_muted), win_w / 2.0, win_h / 2.0, Center)]
				} else {
					[]
				}
			} else {
				g = geom(model)
				# the unit names itself once, above the column of values it
				# governs, rather than repeating on every rule: right-aligned
				# to the column, or from the plot's left edge when a long unit
				# would reach the XP rail
				unit = Scene.kept(measure, Scene.data(model.trace_unit, 10.0, ink_muted), [{ x: g.left - 8.0, y: g.top - 15.0, align: Right }, { x: g.left, y: g.top - 15.0, align: Left }], 1, panel)
				zoom =
					if model.trace_zoom > 1.01 {
						[Scene.kept(measure, Scene.data(zoom_text(model.trace_zoom), 11.0, ink_muted), [{ x: right, y: 130.0, align: Right }, { x: g.left + 8.0, y: g.top + 4.0, align: Left }], 2, panel)]
					} else {
						[]
					}
				List.join([
					List.map(y_grid(model, g), |gr| fix(Scene.data(gr.label, 10.0, ink_faint), g.left - 8.0, y_at(g, gr.v) - 6.0, Right)),
					[unit],
					List.map(x_grid(model, g), |gx| fix(Scene.data(fmt_clock(gx.s), 10.0, ink_faint), gx.x, g.top + g.ph + 6.0, Center)),
					zoom,
				])
			}
		# the footer: the trace's own keys, then the keys every view shares
		# after one gap, dropped when the row has no room left for them; every
		# other view's footer carries them
		hint = [
			fix(Scene.prepared(model.trace_hint, hint_text, 13.0, Prose, ink_faint), 36.0, win_h - 30.0, Left),
			Scene.free(measure, Scene.prose(keys_text, 13.0, ink_faint), [{ x: 36.0 + measure("${hint_text}      ", 13.0, Prose), y: win_h - 30.0, align: Left }], 1, panel),
		]
		List.join([head, picker, splits, sets, plot, hint])
	}

	# what the unit, the zoom note and the shared keys keep off: the chrome
	obstacles : Ui.Model, Scene.Measure -> Labels.Obstacles
	obstacles = |model, measure| { boxes: Chrome.boxes(model, measure), segs: [] }

	# the shapes no text may cover but its own: the pills
	marks : Ui.Model -> List(Labels.Mark)
	marks = |model| Chrome.marks(model)

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		measure = Scene.measure_of(model)
		ink_faint = Theme.ink_faint
		if !(List.is_empty(model.trace)) {
			g = geom(model)
			x_min = g.left
			x_max = g.left + g.pw
			total_s = model.trace_dur
			nlast = List.len(model.trace) - 1
			# Segments carry SECONDS while the trace is downsampled samples, so
			# both map through the session's own duration rather than through
			# each other's index.
			sx = |sec| cam(model, g, sec / total_s)
			tx = |i| if (nlast == 0) (g.left) else cam(model, g, U64.to_f32(i) / U64.to_f32(nlast))
			ty = |w| y_at(g, w)
			# clip a segment to the plot: fully outside skips, a straddler keeps
			# its interpolated portion - ends clamp instead of vanishing
			clip_seg! = |x0, y0, x1, y1, stk| {
				if (x1 <= x_min or x0 >= x_max or x1 <= x0) {} else {
					t0 = if (x0 < x_min) ((x_min - x0) / (x1 - x0)) else 0.0
					t1 = if (x1 > x_max) ((x_max - x0) / (x1 - x0)) else 1.0
					frame.line!({ start: { x: x0 + (x1 - x0) * t0, y: y0 + (y1 - y0) * t0 }, end: { x: x0 + (x1 - x0) * t1, y: y0 + (y1 - y0) * t1 }, stroke: stk })
				}
			}
			List.for_each!(
				model.segs,
				|sg| {
					col = if (sg.kind == "work") (Color.with_alpha(Theme.tsb_c, 52)) else if (sg.kind == "recovery") (Color.with_alpha(ink_faint, 36)) else Color.with_alpha(ink_faint, 18)
					# blocks clamp to the plot edges; one fully outside draws nothing
					x0 = F32.max(x_min, sx(I64.to_f32(sg.start_s)))
					x1 = F32.min(x_max, sx(I64.to_f32(sg.start_s + sg.dur_s)))
					if x1 > x0 {
						frame.rectangle!({ x: x0, y: g.top, width: F32.max(x1 - x0, 1.0), height: g.ph, style: Draw.filled(col) })
					}
				},
			)
			List.for_each!(y_grid(model, g), |gr| frame.line!({ start: { x: x_min, y: ty(gr.v) }, end: { x: x_max, y: ty(gr.v) }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 36), 1) }))
			List.for_each!(x_grid(model, g), |gx| frame.line!({ start: { x: gx.x, y: g.top }, end: { x: gx.x, y: g.top + g.ph }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 28), 1) }))
			# pairing the samples with their own tail expresses "each sample
			# and its successor" without index arithmetic. The ghost rides the
			# SAME seconds-per-pixel as the live trace, so a shorter session
			# honestly ends early instead of stretching to fit, and a longer
			# one stops at the edge: segments starting past the live duration
			# are skipped, the one straddling it keeps its clamped end.
			_ = if List.len(model.ghost) > 1 {
				gn = List.len(model.ghost) - 1
				gx = |i| cam(model, g, (model.ghost_dur * U64.to_f32(i) / U64.to_f32(gn)) / total_s)
				gsegs = List.map2(model.ghost, List.take_last(model.ghost, gn), |a, b| { a, b })
				List.for_each!(List.map_with_index(gsegs, |pr, i| { pr, i }), |x|
					clip_seg!(gx(x.i), ty(x.pr.a), gx(x.i + 1), ty(x.pr.b), Draw.stroke(Color.with_alpha(Theme.atl_c, 120), 1.0)))
			}
			segs2 = List.map2(model.trace, List.take_last(model.trace, List.len(model.trace) - 1), |a, b| { a, b })
			List.for_each!(List.map_with_index(segs2, |pr, i| { pr, i }), |x|
				clip_seg!(tx(x.i), ty(x.pr.a), tx(x.i + 1), ty(x.pr.b), Draw.stroke(Theme.ctl_c, 1.0)))
		}
		Scene.draw!(frame, model, scene(model, measure))
		Ok({})
	}
}

# the family gate matches the engine's: WeightTraining and Workout hold sets;
# a ride, and a yoga class the engine's strength class covers but its sets
# rebuild does not, hold none
expect Trace.strength_session("WeightTraining") and Trace.strength_session("Workout")
expect !Trace.strength_session("Ride") and !Trace.strength_session("Yoga")
expect Trace.set_line(Metric, { exercise: "Incline Barbell Bench Press", sets: 1, reps: 8, kg: 54.4, hold_s: 0 }) == "Incline Barbell Bench Press  1x8 @ 54.4 kg"
expect Trace.set_line(Imperial, { exercise: "Curl", sets: 3, reps: 0, kg: 9.0718474, hold_s: 60 }) == "Curl  3x60s hold @ 20.0 lb"
expect Trace.set_line(Metric, { exercise: "Push Up", sets: 3, reps: 12, kg: 0.0, hold_s: 0 }) == "Push Up  3x12"
expect Trace.no_sets_note(Bool.True) == "no sets read - the description holds text no adapter parsed"
expect Trace.no_sets_note(Bool.False) == "no sets logged"
# the column takes what it wants up to its share of the plot's room, and
# never a negative width
expect Trace.panel_room(300.0, 1600.0) == 300.0
expect Trace.panel_room(900.0, 1000.0) == 450.0
expect Trace.panel_room(300.0, -50.0) == 0.0
expect Trace.set_line(Metric, { exercise: "An Extremely Long Exercise Name That Keeps Going", sets: 3, reps: 8, kg: 10.0, hold_s: 0 }) == "An Extremely Long Exercise Na...  3x8 @ 10.0 kg"
