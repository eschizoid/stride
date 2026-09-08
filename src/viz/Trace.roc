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
		win_w = Theme.win_w
		win_h = Theme.win_h
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
			Text.from(sel_note, model.font).size(13).draw!(frame, { pos: { x: I32.to_f32(Theme.win_w) - 34.0, y: 70.0 }, color: Color.white, align: (Top, Right) })
		}
		if List.is_empty(model.trace) {
			model.trace_hint.draw!(frame, { pos: { x: 36.0, y: I32.to_f32(win_h) - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		} else {
			pw = I32.to_f32(win_w) - pad_l - pad_r
			ph = I32.to_f32(win_h) - pad_t - pad_b
			w_hi = List.fold(model.trace, 1.0, |a, v| F32.max(a, v)) * 1.1
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
			tail = List.take_last(model.trace, List.len(model.trace) - 1)
			segs2 = List.map2(model.trace, tail, |a, b| { a, b })
			List.for_each!(List.map_with_index(segs2, |pr, i| { pr, i }), |x|
				frame.line!({ start: { x: tx(x.i), y: ty(x.pr.a) }, end: { x: tx(x.i + 1), y: ty(x.pr.b) }, stroke: Draw.stroke(ctl_c, 1.0) }))
			model.trace_hint.draw!(frame, { pos: { x: 36.0, y: I32.to_f32(win_h) - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		}
	}
}
