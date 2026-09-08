import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Curve :: [].{
	# ── the power view (TAB) ────────────────────────────────────────────────
	# The window's curve drawn against the all-time record envelope, one
	# chart: grey dots are the best EVER at each rung, blue dots are the best
	# inside the chosen window, and the number between them is the gap. A
	# rung whose window best IS the record collapses to one teal dot - a PR
	# set recently enough to still be in the window.
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
		model.curve_title.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		model.fit_lbl.draw!(frame, { pos: { x: win_w - 40.0, y: 70.0 }, color: ink_muted, align: (Top, Right) })
		# eight zero rungs IS the no-records state - the loader materializes
		# every rung, so emptiness is the summed watts, not the list length
		have = List.fold(model.prs, 0.I64, |a, pr| a + pr.w)
		if List.is_empty(model.prs) or have == 0 {
			Text.from("no ride power yet", model.font).size(14).draw!(frame, { pos: { x: 36.0, y: 130.0 }, color: ink_muted, align: (Top, Left) })
		} else {
			pw = win_w - pad_l - pad_r
			ph = win_h - pad_t - pad_b
			# the record ladder is the master axis; the window's value joins by
			# duration. Index spacing, not time: a linear axis piles the short
			# rungs onto the left edge.
			rungs = List.map_with_index(model.prs, |pr, i| {
				now_w = List.fold(model.curve, 0.I64, |a, c| if c.dur_s == pr.secs (match F32.round_to_u64_try(c.watts) { Ok(cw) => (match U64.to_i64_try(cw) { Ok(ci) => ci
					Err(_) => a })
					Err(_) => a }) else a)
				{ pr, now_w, i }
			})
			w_hi = List.fold(rungs, 1.0, |a, r| F32.max(a, F32.max(I64.to_f32(r.pr.w), I64.to_f32(r.now_w)))) * 1.08
			nlast = List.len(rungs) - 1
			cx = |i| if nlast == 0 (pad_l + pw / 2.0) else pad_l + pw * U64.to_f32(i) / U64.to_f32(nlast)
			cy = |w| pad_t + ph * (1.0 - w / w_hi)
			# the watt grid: a faint rule and label every 100w; steps come from
			# the ceiling itself, so any scale gets its rules
			grid_n = match F32.round_to_u64_try(F32.div_floor_by(w_hi, 100.0)) { Ok(gn) => gn
				Err(_) => 0.U64 }
			List.for_each!(List.map_with_index(List.repeat({}, grid_n), |_u, k| (U64.to_f32(k) + 1.0) * 100.0), |gw|
				if gw < w_hi {
					frame.line!({ start: { x: pad_l, y: cy(gw) }, end: { x: win_w - pad_r, y: cy(gw) }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 36), 1) })
					Text.from(match F32.round_to_u64_try(gw) { Ok(gi) => U64.to_str(gi)
						Err(_) => "" }, model.font).size(10).draw!(frame, { pos: { x: pad_l - 8.0, y: cy(gw) - 6.0 }, color: ink_faint, align: (Top, Right) })
				} else {})
			# CP from the window's fit, dashed - the blue curve should flatten
			# toward it, and a fit far from the long rungs is visibly wrong
			if model.fit_cp > 0.0 and model.fit_cp < w_hi {
				cpy = cy(model.fit_cp)
				List.for_each!(List.map_with_index(List.repeat({}, 60), |_u, k| k), |k| {
					x0 = pad_l + U64.to_f32(k) * (pw / 60.0)
					frame.line!({ start: { x: x0, y: cpy }, end: { x: x0 + pw / 120.0, y: cpy }, stroke: Draw.stroke(Color.with_alpha(tsb_c, 120), 1) })
				})
				model.cp_lbl.draw!(frame, { pos: { x: pad_l + pw + 8.0, y: cpy }, color: tsb_c, align: (Middle, Left) })
			} else {}
			# record envelope first (it sits above), then the window curve
			# envelope segments only between rungs that HAVE records - a 0 rung
			# must not drag the grey line to the floor
			List.for_each!(rungs, |r|
				match List.get(rungs, r.i + 1) {
					Ok(nxt) => if r.pr.w > 0 and nxt.pr.w > 0 (frame.line!({ start: { x: cx(r.i), y: cy(I64.to_f32(r.pr.w)) }, end: { x: cx(nxt.i), y: cy(I64.to_f32(nxt.pr.w)) }, stroke: Draw.stroke(Color.with_alpha(ink_muted, 90), 1) })) else {}
					Err(_) => {}
				})
			List.for_each!(rungs, |r|
				match List.get(rungs, r.i + 1) {
					Ok(nxt) => if r.now_w > 0 and nxt.now_w > 0 (frame.line!({ start: { x: cx(r.i), y: cy(I64.to_f32(r.now_w)) }, end: { x: cx(nxt.i), y: cy(I64.to_f32(nxt.now_w)) }, stroke: Draw.stroke(Color.with_alpha(ctl_c, 150), 2) })) else {}
					Err(_) => {}
				})
			List.for_each!(rungs, |r| {
				rec_y = cy(I64.to_f32(r.pr.w))
				if r.pr.w == 0 {
					# a rung never ridden keeps its label and rail, nothing else
					{}
				} else if r.now_w >= r.pr.w and r.now_w > 0 {
					# the window best IS the record: one teal dot, the good news
					frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 5.0, style: Draw.filled(tsb_c) })
					Text.from("pr", model.font).size(10).draw!(frame, { pos: { x: cx(r.i), y: rec_y - 20.0 }, color: tsb_c, align: (Top, Center) })
				} else {
					frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 4.0, style: Draw.filled(Color.with_alpha(ink_muted, 160)) })
					if r.now_w > 0 {
						now_y = cy(I64.to_f32(r.now_w))
						frame.circle!({ center: { x: cx(r.i), y: now_y }, radius: 4.0, style: Draw.filled(ctl_c) })
						# the gap, said in watts right where it lives
						Text.from("-${I64.to_str(r.pr.w - r.now_w)}", model.font).size(10).draw!(frame, { pos: { x: cx(r.i) + 10.0, y: (rec_y + now_y) / 2.0 - 6.0 }, color: Theme.alarm_c, align: (Top, Left) })
					} else {}
				}
				{}
				Text.from(r.pr.rung, model.font).size(12).draw!(frame, { pos: { x: cx(r.i), y: pad_t + ph - 18.0 }, color: ink_faint, align: (Top, Center) })
				# hover the rung's column: the full story under the title
				half = if nlast == 0 (pw / 2.0) else pw / U64.to_f32(nlast) / 2.0
				if model.mouse_x >= cx(r.i) - half and model.mouse_x < cx(r.i) + half and model.mouse_y >= pad_t and model.mouse_y <= pad_t + ph {
					now_txt = if r.now_w > 0 ("   now ${I64.to_str(r.now_w)}w") else "   not ridden this window"
					Text.from("${r.pr.rung}   best ${I64.to_str(r.pr.w)}w set ${r.pr.day}${now_txt}", model.font).size(12).draw!(frame, { pos: { x: 36.0, y: 92.0 }, color: Color.white, align: (Top, Left) })
				} else {}
			})
			{}
		}
		model.curve_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
