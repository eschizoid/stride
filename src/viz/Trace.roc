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
			sel_note = "${model.trace_day}   (${U64.to_str(model.trace_sel + 1)} of ${U64.to_str(List.len(model.trace_ids))})"
			Text.from(sel_note, model.font).size(13).draw!(frame, { pos: { x: model.win.w - 34.0, y: 70.0 }, color: Color.white, align: (Top, Right) })
			if model.ghost_day != "" {
				Text.from("ghost: ${model.ghost_day}", model.font).size(13).draw!(frame, { pos: { x: model.win.w - 34.0, y: 90.0 }, color: Theme.atl_c, align: (Top, Right) })
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
			sx = |sec| pad_l + pw * sec / total_s
			tx = |i| if nlast == 0 (pad_l) else pad_l + pw * U64.to_f32(i) / U64.to_f32(nlast)
			ty = |w| pad_t + ph * (1.0 - w / w_hi)
			List.for_each!(model.segs, |sg| {
				col = if sg.kind == "work" (Color.with_alpha(tsb_c, 52)) else if sg.kind == "recovery" (Color.with_alpha(ink_faint, 36)) else Color.with_alpha(ink_faint, 18)
				x0 = sx(I64.to_f32(sg.start_s))
				x1 = sx(I64.to_f32(sg.start_s + sg.dur_s))
				frame.rectangle!({ x: x0, y: pad_t, width: F32.max(x1 - x0, 1.0), height: ph, style: Draw.filled(col) })
			})
			# One pass, no random access: zip each sample with its successor.
			# (Roc lists are contiguous arrays — even the List.get form this
			# replaces was O(1) per lookup, not a linked-list walk.)
			# the ghost rides the SAME seconds-per-pixel as the live trace, so a
			# shorter session honestly ends early instead of stretching to fit
			_ = if List.len(model.ghost) > 1 {
				gn = List.len(model.ghost) - 1
				gx = |i| pad_l + F32.min(pw, pw * (model.ghost_dur * U64.to_f32(i) / U64.to_f32(gn)) / total_s)
				gtail = List.take_last(model.ghost, gn)
				gsegs = List.map2(model.ghost, gtail, |a, b| { a, b })
				List.for_each!(List.map_with_index(gsegs, |pr, i| { pr, i }), |x|
					frame.line!({ start: { x: gx(x.i), y: ty(x.pr.a) }, end: { x: gx(x.i + 1), y: ty(x.pr.b) }, stroke: Draw.stroke(Color.with_alpha(Theme.atl_c, 120), 1.0) }))
				{}
			} else {}
			tail = List.take_last(model.trace, List.len(model.trace) - 1)
			segs2 = List.map2(model.trace, tail, |a, b| { a, b })
			List.for_each!(List.map_with_index(segs2, |pr, i| { pr, i }), |x|
				frame.line!({ start: { x: tx(x.i), y: ty(x.pr.a) }, end: { x: tx(x.i + 1), y: ty(x.pr.b) }, stroke: Draw.stroke(ctl_c, 1.0) }))
			model.trace_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		}
	}
}
