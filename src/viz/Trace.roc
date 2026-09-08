import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Trace :: [].{
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
			} else {}
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
				} else {}
			})
			# One pass, no random access: zip each sample with its successor.
			# (Roc lists are contiguous arrays — even the List.get form this
			# replaces was O(1) per lookup, not a linked-list walk.)
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
				{}
			} else {}
			tail = List.take_last(model.trace, List.len(model.trace) - 1)
			segs2 = List.map2(model.trace, tail, |a, b| { a, b })
			List.for_each!(List.map_with_index(segs2, |pr, i| { pr, i }), |x|
				clip_seg!(tx(x.i), ty(x.pr.a), tx(x.i + 1), ty(x.pr.b), Draw.stroke(ctl_c, 1.0)))
			# the camera says where it is when it is anywhere but home
			if model.trace_zoom > 1.01 {
				zoom10 = match F32.round_to_u64_try(model.trace_zoom * 10.0) { Ok(z9) => z9
					Err(_) => 10 }
				Text.from("zoom ${U64.to_str(zoom10 // 10)}.${U64.to_str(zoom10 % 10)}x   0 resets", model.font).size(11).draw!(frame, { pos: { x: win_w - 34.0, y: 110.0 }, color: ink_muted, align: (Top, Right) })
			} else {}
			model.trace_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		}
	}
}
