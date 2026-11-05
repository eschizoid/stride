import rr.Color
import rr.Draw
import rr.Text
import core.Sports
import core.Units
import Db
import Wrap
import Theme
import Ui

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
	# columns, sets x reps or sets x seconds for a hold, then the weight in
	# the athlete's units when one was moved
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

	# whether the selected session is a lifting one, and the lines its sets
	# panel prints: the stored rows (at most 18), or the empty-state note
	lifting_shown : Ui.Model -> Bool
	lifting_shown = |model| match List.get(model.trace_ids, model.trace_sel) {
		Ok(te) => strength_session(te.sport)
		Err(_) => Bool.False
	}

	panel_lines : Ui.Model -> List(Str)
	panel_lines = |model|
		if (!lifting_shown(model)) []
		else if (List.is_empty(model.trace_sets.rows)) [no_sets_note(model.trace_sets.pasted)]
		else List.map(List.take_first(model.trace_sets.rows, 18), |r| set_line(model.units, r))

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
	# per session; model.trace_unit names what the samples count.
	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		pad_l = Theme.pad_l
		lifting = lifting_shown(model)
		set_lines = panel_lines(model)
		pad_r = right_pad(model)
		pad_t = Theme.pad_t
		pad_b = Theme.pad_b
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		ctl_c = Theme.ctl_c
		tsb_c = Theme.tsb_c
		# The subtitle is built per frame rather than prepared once, because it
		# describes THIS session: both the channel it plots and whether the
		# detector found any blocks in it vary from one session to the next.
		nsegs = List.len(List.keep_if(model.segs, |sg| sg.kind == "work"))
		what = if (model.trace_unit == "bpm") ("heart rate") else if (pace_axis(model.trace_unit)) ("pace") else "power"
		# a lifting session has no power or pace for the detector to read, so
		# its heading names the channel only and the sets panel speaks for it
		blocks =
			if (List.is_empty(model.trace) or lifting) ("")
			else if (nsegs == 0) (" - no intervals detected")
			else if (nsegs == 1) (" - 1 detected block shaded behind it") else " - ${U64.to_str(nsegs)} detected blocks shaded behind it"
		Text.from("${what} trace${blocks}", model.font).size(15).draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		# Which session, said the way a human remembers one: its NAME first,
		# then the date, sport and picker position, then the filter X is
		# holding - a mode key with no visible mode reads as a dead key.
		if (List.is_empty(model.trace_ids)) {} else {
			n_ids = List.len(model.trace_ids)
			sel = match List.get(model.trace_ids, model.trace_sel) {
				Ok(te) => te
				Err(_) => { id: 0, day: model.trace_day, name: "", sport: "", chan: "" }
			}
			Text.from(sel.name, model.font).size(13).draw!(frame, { pos: { x: model.win.w - 34.0, y: 70.0 }, color: Color.white, align: (Top, Right) })
			filt = if (model.trace_sport == "") ("all sports") else "${model.trace_sport} only"
			Text.from("${sel.day}   ${sel.sport}   ${U64.to_str(model.trace_sel + 1)}/${U64.to_str(n_ids)}   showing ${filt} (X cycles)", model.font).size(12).draw!(frame, { pos: { x: model.win.w - 34.0, y: 90.0 }, color: ink_muted, align: (Top, Right) })
			if model.ghost_day != "" {
				gname = List.fold(model.trace_ids, "", |acc, ge| if (ge.day == model.ghost_day) ge.name else acc)
				Text.from("ghost (purple): ${gname}  ${model.ghost_day}   C clears", model.font).size(12).draw!(frame, { pos: { x: model.win.w - 34.0, y: 110.0 }, color: Theme.atl_c, align: (Top, Right) })
			}
		}
		# ── the splits panel: the pace channel's companion - the same rows
		# the CLI's activity screen prints, in the athlete's units. Capped to
		# what fits beside the plot; the overflow line says how many rows it
		# holds back rather than letting the run appear to end early.
		if pace_axis(model.trace_unit) and !(List.is_empty(model.trace_splits)) {
			Text.from("splits (${Units.dist_unit(model.units)})", model.font).size(11).draw!(frame, { pos: { x: model.win.w - 34.0, y: 136.0 }, color: ink_muted, align: (Top, Right) })
			shown = List.take_first(model.trace_splits, 14)
			List.for_each!(List.map_with_index(shown, |r, i| { r, i }), |x|
				Text.from("${I64.to_str(x.r.n)}  ${Units.pace_per_dist(model.units, x.r.distance_m, x.r.elapsed_s)}", model.font).size(11).draw!(frame, { pos: { x: model.win.w - 34.0, y: 154.0 + U64.to_f32(x.i) * 16.0 }, color: ink_faint, align: (Top, Right) }))
			extra = List.len(model.trace_splits) - List.len(shown)
			if extra > 0 {
				Text.from("+${U64.to_str(extra)} more", model.font).size(10).draw!(frame, { pos: { x: model.win.w - 34.0, y: 154.0 + 14.0 * 16.0 }, color: ink_faint, align: (Top, Right) })
			}
		}
		# ── the sets panel: a lifting session's stored sets in order, holds
		# included, capped to what fits beside the plot with an overflow line
		if lifting {
			Text.from("sets", model.font).size(11).draw!(frame, { pos: { x: model.win.w - 34.0, y: 136.0 }, color: ink_muted, align: (Top, Right) })
			List.for_each!(List.map_with_index(set_lines, |l, i| { l, i }), |x|
				Text.from(x.l, model.font).size(11).draw!(frame, { pos: { x: model.win.w - 34.0, y: 154.0 + U64.to_f32(x.i) * 16.0 }, color: ink_faint, align: (Top, Right) }))
			if !(List.is_empty(model.trace_sets.rows)) {
				extra = List.len(model.trace_sets.rows) - List.len(set_lines)
				if extra > 0 {
					Text.from("+${U64.to_str(extra)} more", model.font).size(10).draw!(frame, { pos: { x: model.win.w - 34.0, y: 154.0 + 18.0 * 16.0 }, color: ink_faint, align: (Top, Right) })
				}
			}
		}
		if List.is_empty(model.trace) {
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
			if model.trace_loading {
				Text.from("loading trace...", model.font).size(13).draw!(frame, { pos: { x: win_w / 2.0, y: win_h / 2.0 }, color: ink_muted, align: (Top, Center) })
			} else if !(List.is_empty(model.trace_ids)) {
				Text.from("this session's stream holds no plottable samples", model.font).size(13).draw!(frame, { pos: { x: win_w / 2.0, y: win_h / 2.0 }, color: ink_muted, align: (Top, Center) })
			}
			model.trace_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		} else {
			pw = win_w - pad_l - pad_r
			ph = win_h - pad_t - pad_b
			# the shared scale: both traces judged against one ceiling,
			# or the comparison lies
			w_hi = F32.max(List.fold(model.trace, 1.0, |a, v| F32.max(a, v)), List.fold(model.ghost, 1.0, |a, v| F32.max(a, v))) * 1.1
			nlast = List.len(model.trace) - 1
			# Segments carry SECONDS while the trace is downsampled samples, so
			# both map through the session's own duration rather than through
			# each other's index.
			total_s = model.trace_dur
			# every x runs through the camera: the visible window is
			# [pan, pan + 1/zoom] of the session, in session-fraction space
			cam = |frac| pad_l + pw * (frac - model.trace_pan) * model.trace_zoom
			sx = |sec| cam(sec / total_s)
			tx = |i| if (nlast == 0) (pad_l) else cam(U64.to_f32(i) / U64.to_f32(nlast))
			ty = |w| pad_t + ph * (1.0 - w / w_hi)
			x_min = pad_l
			x_max = pad_l + pw
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
					col = if (sg.kind == "work") (Color.with_alpha(tsb_c, 52)) else if (sg.kind == "recovery") (Color.with_alpha(ink_faint, 36)) else Color.with_alpha(ink_faint, 18)
					# blocks clamp to the plot edges; one fully outside draws nothing
					x0 = F32.max(x_min, sx(I64.to_f32(sg.start_s)))
					x1 = F32.min(x_max, sx(I64.to_f32(sg.start_s + sg.dur_s)))
					if x1 > x0 {
						frame.rectangle!({ x: x0, y: pad_t, width: F32.max(x1 - x0, 1.0), height: ph, style: Draw.filled(col) })
					}
				},
			)
			# The y grid: a faint rule and a value at each step, so a level can
			# be read off the plot instead of guessed. The axis starts at zero
			# — the same origin the trace itself is scaled against.
			is_pace = pace_axis(model.trace_unit)
			ystep = if (is_pace) (y_step_pace(w_hi)) else y_step(w_hi)
			ycount = match F32.round_to_u64_try(F32.div_floor_by(w_hi, ystep)) {
				Ok(yn) => yn
				Err(_) => 0.U64
			}
			# the step reaches F64 through a millimetre integer - exact for
			# every step this file chooses, and the label math wants F64
			ystep64 = (
				(
					match F32.round_to_u64_try(ystep * 1000.0) {
						Ok(u) => u
						Err(_) => 0.U64
					}
				)
			).to_f64() / 1000.0
			List.for_each!(
				List.map_with_index(List.repeat({}, ycount), |_u, k| k),
				|k|
					{
						gv = (U64.to_f32(k) + 1.0) * ystep
						if gv < w_hi {
							frame.line!({ start: { x: x_min, y: ty(gv) }, end: { x: x_max, y: ty(gv) }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 36), 1) })
							# a pace gridline says the pace, not the raw m/s the
							# samples are stored in - the same last-moment rule
							# every other surface follows
							lbl = if (is_pace) (Units.pace_from_speed(model.units, ((k).to_f64() + 1.0) * ystep64)) else (
								match F32.round_to_u64_try(gv) {
									Ok(gi) => U64.to_str(gi)
									Err(_) => ""
								}
							)
							Text.from(lbl, model.font).size(10).draw!(frame, { pos: { x: x_min - 8.0, y: ty(gv) - 6.0 }, color: ink_faint, align: (Top, Right) })
						} else {}
					},
			)
			# the unit names itself once, above the column of values it governs,
			# rather than repeating on every rule
			Text.from(model.trace_unit, model.font).size(10).draw!(frame, { pos: { x: x_min - 8.0, y: pad_t - 15.0 }, color: ink_muted, align: (Top, Right) })
			# The x grid: elapsed time. Every tick runs through the same camera
			# as the trace, so a panned or zoomed view stays labelled correctly;
			# ticks the camera puts outside the plot are skipped rather than
			# clamped, which would stack them on the edge.
			xstep = x_step(total_s, model.trace_zoom)
			xcount = match F32.round_to_u64_try(F32.div_floor_by(total_s, xstep)) {
				Ok(xn) => xn
				Err(_) => 0.U64
			}
			List.for_each!(
				List.map_with_index(List.repeat({}, xcount + 1), |_u, k| U64.to_f32(k) * xstep),
				|gs| {
					gx9 = sx(gs)
					if gx9 >= x_min and gx9 <= x_max {
						frame.line!({ start: { x: gx9, y: pad_t }, end: { x: gx9, y: pad_t + ph }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 28), 1) })
						Text.from(fmt_clock(gs), model.font).size(10).draw!(frame, { pos: { x: gx9, y: pad_t + ph + 6.0 }, color: ink_faint, align: (Top, Center) })
					} else {}
				},
			)
			# pairing the samples with their own tail expresses "each sample
			# and its successor" without index arithmetic
			# the ghost rides the SAME seconds-per-pixel as the live trace, so a
			# shorter session honestly ends early instead of stretching to fit
			_ = if List.len(model.ghost) > 1 {
				gn = List.len(model.ghost) - 1
				gx = |i| cam((model.ghost_dur * U64.to_f32(i) / U64.to_f32(gn)) / total_s)
				gtail = List.take_last(model.ghost, gn)
				gsegs = List.map2(model.ghost, gtail, |a, b| { a, b })
				# a ghost longer than the live session stops at the edge rather
				# than smearing its overrun into a vertical line there: segments
				# starting past the live duration are skipped, the one straddling
				# it keeps its clamped end
				List.for_each!(List.map_with_index(gsegs, |pr, i| { pr, i }), |x|
					clip_seg!(gx(x.i), ty(x.pr.a), gx(x.i + 1), ty(x.pr.b), Draw.stroke(Color.with_alpha(Theme.atl_c, 120), 1.0)))
			}
			tail = List.take_last(model.trace, List.len(model.trace) - 1)
			segs2 = List.map2(model.trace, tail, |a, b| { a, b })
			List.for_each!(List.map_with_index(segs2, |pr, i| { pr, i }), |x|
				clip_seg!(tx(x.i), ty(x.pr.a), tx(x.i + 1), ty(x.pr.b), Draw.stroke(ctl_c, 1.0)))
			# the camera says where it is when it is anywhere but home
			if model.trace_zoom > 1.01 {
				zoom10 = match F32.round_to_u64_try(model.trace_zoom * 10.0) {
					Ok(z9) => z9
					Err(_) => 10
				}
				Text.from("zoom ${U64.to_str(zoom10 // 10)}.${U64.to_str(zoom10 % 10)}x   0 resets", model.font).size(11).draw!(frame, { pos: { x: win_w - 34.0, y: 130.0 }, color: ink_muted, align: (Top, Right) })
			}
			model.trace_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		}
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
