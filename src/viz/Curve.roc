import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Curve :: [].{
	# ── the power view (TAB) ────────────────────────────────────────────────
	# The window's curve drawn against the SAME-LENGTH window before it, one
	# chart: blue dots are the best inside the chosen window, grey dots the
	# best of the previous window, and the signed number between them is the
	# change - progress argues with the recent self, not the record book. The
	# all-time envelope stays as a faint reference above; a rung whose window
	# best IS the record still collapses to one teal dot and a fresh record
	# still rings gold. The CP line dims when its own fit is too weak to
	# deserve a confident stroke.
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
		# a chip click re-fetches the curve in the background; while that is in
		# flight the note says so, so a click that takes a beat reads as working
		# rather than dead (the clicked chip also highlights immediately below).
		# The old curve stays on screen underneath until the fresh one lands.
		if model.reloading {
			Text.from("loading ${I64.to_str(model.curve_days)}d window…", model.font).size(12).draw!(frame, { pos: { x: 36.0, y: 92.0 }, color: Theme.gold_c, align: (Top, Left) })
		}
		# one line above the hint row: the chips own the top-right band, and
		# hint plus caption together outgrow a single bottom line
		model.fit_lbl.draw!(frame, { pos: { x: win_w - 40.0, y: win_h - 52.0 }, color: ink_muted, align: (Top, Right) })
		# the same range chips the form board wears, judged on curve_days -
		# the window switch must be visible and clickable, not a key secret
		List.for_each!(List.map_with_index(model.subs, |s, i| { s, i }), |x| {
			chx = win_w - 420.0 + U64.to_f32(x.i) * 54.0
			on = (match U64.to_i64_try(x.s.r) { Ok(ri) => ri
				Err(_) => -1 }) == model.curve_days
			hov = model.mouse_x >= chx and model.mouse_x <= chx + 46.0 and model.mouse_y >= 64.0 and model.mouse_y <= 86.0
			style = if on (Draw.filled(Color.with_alpha(ctl_c, 60))) else if hov (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
			frame.rounded_rectangle!({ x: chx, y: 64.0, width: 46.0, height: 22.0, radius: 6.0, segments: 6, style })
			x.s.chip.draw!(frame, { pos: { x: chx + 23.0, y: 68.0 }, color: if on Color.white else ink_muted, align: (Top, Center) })
		})
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
			joined = |pts, secs| List.fold(pts, 0.I64, |a, c| if c.dur_s == secs (match F32.round_to_u64_try(c.watts) { Ok(cw) => (match U64.to_i64_try(cw) { Ok(ci) => ci
				Err(_) => a })
				Err(_) => a }) else a)
			rungs = List.map_with_index(model.prs, |pr, i| {
				now_w = joined(model.curve, pr.secs)
				prev_w = joined(model.curve_prev, pr.secs)
				{ pr, now_w, prev_w, i }
			})
			w_hi = List.fold(rungs, 1.0, |a, r| F32.max(a, F32.max(I64.to_f32(r.pr.w), F32.max(I64.to_f32(r.now_w), I64.to_f32(r.prev_w))))) * 1.08
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
			# toward it, and a fit far from the long rungs is visibly wrong.
			# A weak fit (r2 under 0.9) draws dimmed: the footer already admits
			# the r2, and a confident stroke over a shaky fit would outrank it.
			if model.fit_cp > 0.0 and model.fit_cp < w_hi {
				cpy = cy(model.fit_cp)
				cp_a = if model.fit_r2 < 0.9 (55) else 120
				cp_lbl_c = if model.fit_r2 < 0.9 (Color.with_alpha(tsb_c, 140)) else tsb_c
				List.for_each!(List.map_with_index(List.repeat({}, 60), |_u, k| k), |k| {
					x0 = pad_l + U64.to_f32(k) * (pw / 60.0)
					frame.line!({ start: { x: x0, y: cpy }, end: { x: x0 + pw / 120.0, y: cpy }, stroke: Draw.stroke(Color.with_alpha(tsb_c, cp_a), 1) })
				})
				model.cp_lbl.draw!(frame, { pos: { x: pad_l + pw + 8.0, y: cpy }, color: cp_lbl_c, align: (Middle, Left) })
			}
			# each line introduces itself at its first rung - the chart must be
			# readable with no narrator
			_ = match List.first(rungs) {
				Ok(r0) => {
					if r0.pr.w > 0 {
						Text.from("best ever", model.font).size(11).draw!(frame, { pos: { x: cx(r0.i) + 14.0, y: cy(I64.to_f32(r0.pr.w)) - 8.0 }, color: Color.with_alpha(ink_muted, 130), align: (Top, Left) })
					}
					if r0.prev_w > 0 and r0.prev_w < r0.pr.w {
						Text.from("previous window", model.font).size(11).draw!(frame, { pos: { x: cx(r0.i) + 14.0, y: cy(I64.to_f32(r0.prev_w)) - 8.0 }, color: ink_muted, align: (Top, Left) })
					}
					if r0.now_w > 0 and r0.now_w < r0.pr.w {
						Text.from("this window", model.font).size(11).draw!(frame, { pos: { x: cx(r0.i) + 14.0, y: cy(I64.to_f32(r0.now_w)) + 6.0 }, color: Theme.ctl_c, align: (Top, Left) })
					}
				}
				Err(_) => {}
			}
			# three envelopes back to front: the record book faintest (a
			# reference, no longer the antagonist), the previous window in
			# quiet grey, this window loudest. Envelope segments only between
			# rungs that HAVE values - a 0 rung must not drag a line to the
			# floor.
			List.for_each!(rungs, |r|
				match List.get(rungs, r.i + 1) {
					Ok(nxt) => if r.pr.w > 0 and nxt.pr.w > 0 (frame.line!({ start: { x: cx(r.i), y: cy(I64.to_f32(r.pr.w)) }, end: { x: cx(nxt.i), y: cy(I64.to_f32(nxt.pr.w)) }, stroke: Draw.stroke(Color.with_alpha(ink_muted, 45), 1) })) else {}
					Err(_) => {}
				})
			List.for_each!(rungs, |r|
				match List.get(rungs, r.i + 1) {
					Ok(nxt) => if r.prev_w > 0 and nxt.prev_w > 0 (frame.line!({ start: { x: cx(r.i), y: cy(I64.to_f32(r.prev_w)) }, end: { x: cx(nxt.i), y: cy(I64.to_f32(nxt.prev_w)) }, stroke: Draw.stroke(Color.with_alpha(ink_muted, 110), 1) })) else {}
					Err(_) => {}
				})
			List.for_each!(rungs, |r|
				match List.get(rungs, r.i + 1) {
					Ok(nxt) => if r.now_w > 0 and nxt.now_w > 0 (frame.line!({ start: { x: cx(r.i), y: cy(I64.to_f32(r.now_w)) }, end: { x: cx(nxt.i), y: cy(I64.to_f32(nxt.now_w)) }, stroke: Draw.stroke(Color.with_alpha(ctl_c, 150), 2) })) else {}
					Err(_) => {}
				})
			# a record set in the last seven calendar days is NEWS: the rung
			# earns a pulsing gold ring. Heat carries one row per day, so its
			# last seven entries ARE the last seven days.
			recent7 = List.take_last(model.heat, 7)
			nt = model.tick % 40
			ntri = (if nt < 20 (U64.to_f32(nt)) else U64.to_f32(40 - nt)) / 20.0
			List.for_each!(rungs, |r| {
				rec_y = cy(I64.to_f32(r.pr.w))
				fresh = r.pr.w > 0 and List.fold(recent7, Bool.False, |a9, hd| a9 or hd.day == r.pr.day)
				if fresh {
					halo_a = match F32.to_u8_try(50.0 + ntri * 50.0) { Ok(ha) => ha
						Err(_) => 50 }
					frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 9.0 + ntri * 3.0, style: Draw.filled(Color.with_alpha(Theme.gold_c, halo_a)) })
					Text.from("new record", model.font).size(11).draw!(frame, { pos: { x: cx(r.i), y: rec_y - 34.0 }, color: Theme.gold_c, align: (Top, Center) })
				}
				if r.pr.w == 0 {
					# a rung never ridden keeps its label and rail, nothing else
				} else if r.now_w >= r.pr.w and r.now_w > 0 {
					# the window best IS the record: one teal dot - and the
					# delta still prints, because a record rung's change is the
					# best news on the chart, not a case to suppress. Teal for
					# both is a decision: it is the house "good" accent, and
					# the dot and the text differ in shape.
					frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 5.0, style: Draw.filled(tsb_c) })
					Text.from("pr", model.font).size(10).draw!(frame, { pos: { x: cx(r.i), y: rec_y - 20.0 }, color: tsb_c, align: (Top, Center) })
					dpr_txt = delta_label(r.now_w, r.prev_w)
					if dpr_txt != "" {
						dpr_col = if r.now_w > r.prev_w tsb_c else Theme.alarm_c
						Text.from(dpr_txt, model.font).size(10).draw!(frame, { pos: { x: cx(r.i) + 10.0, y: (cy(I64.to_f32(r.prev_w)) + rec_y) / 2.0 - 6.0 }, color: dpr_col, align: (Top, Left) })
					}
				} else {
					frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 3.0, style: Draw.filled(Color.with_alpha(ink_muted, 80)) })
					if r.prev_w > 0 and r.prev_w < r.pr.w {
						frame.circle!({ center: { x: cx(r.i), y: cy(I64.to_f32(r.prev_w)) }, radius: 4.0, style: Draw.filled(Color.with_alpha(ink_muted, 150)) })
					}
					if r.now_w > 0 {
						now_y = cy(I64.to_f32(r.now_w))
						frame.circle!({ center: { x: cx(r.i), y: now_y }, radius: 4.0, style: Draw.filled(ctl_c) })
						# the change against the PREVIOUS window, signed, right
						# where it lives - green-teal going up, alarm going down
						d_txt = delta_label(r.now_w, r.prev_w)
						if d_txt != "" {
							d_col = if r.now_w > r.prev_w tsb_c else Theme.alarm_c
							Text.from(d_txt, model.font).size(10).draw!(frame, { pos: { x: cx(r.i) + 10.0, y: (cy(I64.to_f32(r.prev_w)) + now_y) / 2.0 - 6.0 }, color: d_col, align: (Top, Left) })
						}
					}
				}
				Text.from(r.pr.rung, model.font).size(12).draw!(frame, { pos: { x: cx(r.i), y: pad_t + ph - 18.0 }, color: ink_faint, align: (Top, Center) })
				# hover the rung's column: the full story under the title
				half = if nlast == 0 (pw / 2.0) else pw / U64.to_f32(nlast) / 2.0
				if model.mouse_x >= cx(r.i) - half and model.mouse_x < cx(r.i) + half and model.mouse_y >= pad_t and model.mouse_y <= pad_t + ph {
					now_txt = if r.now_w > 0 ("   now ${I64.to_str(r.now_w)}w") else "   not ridden this window"
					prev_txt = if r.prev_w > 0 ("   prev ${I64.to_str(r.prev_w)}w") else ""
					tip = if r.pr.w > 0 ("${r.pr.rung}   best ${I64.to_str(r.pr.w)}w set ${r.pr.day}${now_txt}${prev_txt}") else "${r.pr.rung}   never ridden"
					Text.from(tip, model.font).size(12).draw!(frame, { pos: { x: 36.0, y: 92.0 }, color: Color.white, align: (Top, Left) })
				}
			})
		}
		model.curve_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}

	# the window-over-window change, said in watts with its sign - the number
	# this view argues with. Empty when either side is absent (a comparison
	# with nothing is not a delta) and when equal (the dots already overlap,
	# and a "+0w" would claim a precision the rounding does not carry).
	delta_label : I64, I64 -> Str
	delta_label = |now, prev|
		if now <= 0 or prev <= 0 ""
		else if now > prev "+${I64.to_str(now - prev)}w"
		else if now < prev "-${I64.to_str(prev - now)}w"
		else ""
}

expect Curve.delta_label(354, 340) == "+14w"
expect Curve.delta_label(300, 333) == "-33w"
expect Curve.delta_label(300, 300) == ""
expect Curve.delta_label(0, 300) == ""
expect Curve.delta_label(300, 0) == ""
