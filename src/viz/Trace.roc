import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Trace :: [].{
	# The y grid step for a plot whose ceiling is `hi`: enough rules to read a
	# level off the trace, few enough that the labels do not collide. It comes
	# from the ceiling rather than being fixed per unit, because watts and
	# heart rate span different ranges on the same axis.
	y_step : F32 -> F32
	y_step = |hi|
		if hi <= 60.0 (10.0)
		else if hi <= 150.0 (25.0)
		else if hi <= 300.0 (50.0)
		else if hi <= 600.0 (100.0)
		else if hi <= 1500.0 (250.0)
		else 500.0

	# The x grid step in SECONDS. The visible span is the session divided by
	# the zoom, so zooming in earns finer ticks instead of holding the
	# whole-session spacing and labelling nothing.
	x_step : F32, F32 -> F32
	x_step = |dur, zoom| {
		vis = if zoom > 0.0 (dur / zoom) else dur
		if vis <= 120.0 (15.0)
		else if vis <= 300.0 (30.0)
		else if vis <= 900.0 (60.0)
		else if vis <= 1800.0 (300.0)
		else if vis <= 5400.0 (600.0)
		else 1800.0
	}

	# Elapsed seconds as m:ss — the axis reads as a clock, which is how a
	# session is remembered, rather than as a sample count.
	fmt_clock : F32 -> Str
	fmt_clock = |s| {
		t = match F32.round_to_u64_try(F32.max(s, 0.0)) { Ok(v) => v
			Err(_) => 0.U64 }
		ss = t % 60
		"${U64.to_str(t // 60)}:${if ss < 10 ("0") else ""}${U64.to_str(ss)}"
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

	# ── session trace view (TAB) ────────────────────────────────────────────
	# The detector's blocks shaded BEHIND the real power trace, so the two can
	# be compared by eye — which is the whole point: a table of segments cannot
	# show you that a "work" block started thirty seconds before the power did.
	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		pad_l = Theme.pad_l
		pad_r = Theme.pad_r
		pad_t = Theme.pad_t
		pad_b = Theme.pad_b
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		ctl_c = Theme.ctl_c
		tsb_c = Theme.tsb_c
		model.trace_title.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		# which session, and where in the picker it sits
		if List.is_empty(model.trace_ids) {} else {
			n_ids = List.len(model.trace_ids)
			sel_note = if n_ids == 1 ("${model.trace_day}   the only structured session") else "${model.trace_day}   session ${U64.to_str(model.trace_sel + 1)} of the last ${U64.to_str(n_ids)}"
			Text.from(sel_note, model.font).size(13).draw!(frame, { pos: { x: model.win.w - 34.0, y: 70.0 }, color: Color.white, align: (Top, Right) })
			if model.ghost_day != "" {
				Text.from("vs ${model.ghost_day} (purple)   shift+] dismisses", model.font).size(13).draw!(frame, { pos: { x: model.win.w - 34.0, y: 90.0 }, color: Theme.atl_c, align: (Top, Right) })
			}
		}
		if List.is_empty(model.trace) {
			model.trace_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		} else {
			pw = win_w - pad_l - pad_r
			ph = win_h - pad_t - pad_b
			# the shared watts scale: both traces judged against one ceiling,
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
			tx = |i| if nlast == 0 (pad_l) else cam(U64.to_f32(i) / U64.to_f32(nlast))
			ty = |w| pad_t + ph * (1.0 - w / w_hi)
			x_min = pad_l
			x_max = pad_l + pw
			# clip a segment to the plot: fully outside skips, a straddler keeps
			# its interpolated portion - ends clamp instead of vanishing
			clip_seg! = |x0, y0, x1, y1, stk| {
				if x1 <= x_min or x0 >= x_max or x1 <= x0 {} else {
					t0 = if x0 < x_min ((x_min - x0) / (x1 - x0)) else 0.0
					t1 = if x1 > x_max ((x_max - x0) / (x1 - x0)) else 1.0
					frame.line!({ start: { x: x0 + (x1 - x0) * t0, y: y0 + (y1 - y0) * t0 }, end: { x: x0 + (x1 - x0) * t1, y: y0 + (y1 - y0) * t1 }, stroke: stk })
				}
			}
			List.for_each!(model.segs, |sg| {
				col = if sg.kind == "work" (Color.with_alpha(tsb_c, 52)) else if sg.kind == "recovery" (Color.with_alpha(ink_faint, 36)) else Color.with_alpha(ink_faint, 18)
				# blocks clamp to the plot edges; one fully outside draws nothing
				x0 = F32.max(x_min, sx(I64.to_f32(sg.start_s)))
				x1 = F32.min(x_max, sx(I64.to_f32(sg.start_s + sg.dur_s)))
				if x1 > x0 {
					frame.rectangle!({ x: x0, y: pad_t, width: F32.max(x1 - x0, 1.0), height: ph, style: Draw.filled(col) })
				}
			})
			# The y grid: a faint rule and a value at each step, so a level can
			# be read off the plot instead of guessed. The axis starts at zero
			# — the same origin the trace itself is scaled against.
			ystep = y_step(w_hi)
			ycount = match F32.round_to_u64_try(F32.div_floor_by(w_hi, ystep)) { Ok(yn) => yn
				Err(_) => 0.U64 }
			List.for_each!(List.map_with_index(List.repeat({}, ycount), |_u, k| (U64.to_f32(k) + 1.0) * ystep), |gv|
				if gv < w_hi {
					frame.line!({ start: { x: x_min, y: ty(gv) }, end: { x: x_max, y: ty(gv) }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 36), 1) })
					Text.from(match F32.round_to_u64_try(gv) { Ok(gi) => U64.to_str(gi)
						Err(_) => "" }, model.font).size(10).draw!(frame, { pos: { x: x_min - 8.0, y: ty(gv) - 6.0 }, color: ink_faint, align: (Top, Right) })
				} else {})
			# the unit names itself once, above the column of values it governs,
			# rather than repeating on every rule
			Text.from(model.trace_unit, model.font).size(10).draw!(frame, { pos: { x: x_min - 8.0, y: pad_t - 15.0 }, color: ink_muted, align: (Top, Right) })
			# The x grid: elapsed time. Every tick runs through the same camera
			# as the trace, so a panned or zoomed view stays labelled correctly;
			# ticks the camera puts outside the plot are skipped rather than
			# clamped, which would stack them on the edge.
			xstep = x_step(total_s, model.trace_zoom)
			xcount = match F32.round_to_u64_try(F32.div_floor_by(total_s, xstep)) { Ok(xn) => xn
				Err(_) => 0.U64 }
			List.for_each!(List.map_with_index(List.repeat({}, xcount + 1), |_u, k| U64.to_f32(k) * xstep), |gs| {
				gx9 = sx(gs)
				if gx9 >= x_min and gx9 <= x_max {
					frame.line!({ start: { x: gx9, y: pad_t }, end: { x: gx9, y: pad_t + ph }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 28), 1) })
					Text.from(fmt_clock(gs), model.font).size(10).draw!(frame, { pos: { x: gx9, y: pad_t + ph + 6.0 }, color: ink_faint, align: (Top, Center) })
				} else {}
			})
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
				zoom10 = match F32.round_to_u64_try(model.trace_zoom * 10.0) { Ok(z9) => z9
					Err(_) => 10 }
				Text.from("zoom ${U64.to_str(zoom10 // 10)}.${U64.to_str(zoom10 % 10)}x   0 resets", model.font).size(11).draw!(frame, { pos: { x: win_w - 34.0, y: 110.0 }, color: ink_muted, align: (Top, Right) })
			}
			model.trace_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		}
	}
}
