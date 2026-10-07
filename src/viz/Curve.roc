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
	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
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
		# rather than dead (the clicked chip also highlights immediately). The
		# old curve stays on screen underneath until the fresh one lands. The
		# note sits in the chip band, just RIGHT of the last chip: the line
		# below the title belongs to the rung tooltip, and two texts at one
		# anchor overprint whenever a reload and a hover coincide. It names no
		# window - the lit chip already does. Anchored to the chips' right it
		# shares their anchor, so it can meet the title only at a width where
		# the chips already have; the minimum size is a hint the window
		# manager may ignore, and no anchor left of the chips survives that.
		if model.reloading {
			Text.from("loading...", model.font).size(12).draw!(frame, { pos: { x: win_w - 254.0, y: 68.0 }, color: Theme.gold_c, align: (Top, Left) })
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
			# readable with no narrator. The first rung's delta reads the same
			# list to keep clear of them, so the drawing and the avoidance
			# cannot drift apart; the introductions are laid out in their dots' order
			# first, since two bests a few watts apart would otherwise overprint
			intro_lines = match List.first(rungs) {
				Ok(r0) => List.join([
					(if r0.pr.w > 0 [{ text: "best ever", y: cy(I64.to_f32(r0.pr.w)) - 8.0, dot: cy(I64.to_f32(r0.pr.w)), color: Color.with_alpha(ink_muted, 130) }] else []),
					(if r0.prev_w > 0 and r0.prev_w < r0.pr.w [{ text: "previous window", y: cy(I64.to_f32(r0.prev_w)) - 8.0, dot: cy(I64.to_f32(r0.prev_w)), color: ink_muted }] else []),
					(if r0.now_w > 0 and r0.now_w < r0.pr.w [{ text: "this window", y: cy(I64.to_f32(r0.now_w)) + 6.0, dot: cy(I64.to_f32(r0.now_w)), color: Theme.ctl_c }] else []),
				])
				Err(_) => []
			}
			placed = layout_intros(intro_lines)
			List.for_each!(placed, |l| Text.from(l.text, model.font).size(11).draw!(frame, { pos: { x: cx(0.U64) + 14.0, y: l.y }, color: l.color, align: (Top, Left) }))
			intro_boxes = List.map(placed, |l| { top: l.y, bot: l.y + 11.0 })
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
				# the first rung's delta keeps clear of the introductions beside it
				delta_top = |top| if r.i == 0.U64 (top_clear(top, 10.0, intro_boxes)) else top
				fresh = r.pr.w > 0 and List.fold(recent7, Bool.False, |a9, hd| a9 or hd.day == r.pr.day)
				if fresh {
					halo_a = match F32.to_u8_try(50.0 + ntri * 50.0) { Ok(ha) => ha
						Err(_) => 50 }
					frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 9.0 + ntri * 3.0, style: Draw.filled(Color.with_alpha(Theme.gold_c, halo_a)) })
					nr_half = model.font.measure({ text: "new record", size: 11.0, spacing: Text.default_spacing }).width / 2.0
					Text.from("new record", model.font).size(11).draw!(frame, { pos: { x: label_center_within(cx(r.i), nr_half, pad_l, pad_l + pw - label_inset), y: rec_y - 34.0 }, color: Theme.gold_c, align: (Top, Center) })
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
					pr_half = model.font.measure({ text: "pr", size: 10.0, spacing: Text.default_spacing }).width / 2.0
					Text.from("pr", model.font).size(10).draw!(frame, { pos: { x: label_center_within(cx(r.i), pr_half, pad_l, pad_l + pw - label_inset), y: rec_y - 20.0 }, color: tsb_c, align: (Top, Center) })
					dpr_txt = delta_label(r.now_w, r.prev_w)
					if dpr_txt != "" {
						dpr_col = if r.now_w > r.prev_w tsb_c else Theme.alarm_c
						dpr_w = model.font.measure({ text: dpr_txt, size: 10.0, spacing: Text.default_spacing }).width
						# at the first rung "pr" is clamped to the plot's left edge, under the
						# delta's x, so it counts as a box to clear too
						dpr_boxes = if r.i == 0.U64 (List.append(intro_boxes, { top: rec_y - 20.0, bot: rec_y - 10.0 })) else []
						dpr_top = if r.i == 0.U64 (top_clear((cy(I64.to_f32(r.prev_w)) + rec_y) / 2.0 - 6.0, 10.0, dpr_boxes)) else (cy(I64.to_f32(r.prev_w)) + rec_y) / 2.0 - 6.0
						Text.from(dpr_txt, model.font).size(10).draw!(frame, { pos: { x: delta_left_x(cx(r.i), dpr_w, pad_l + pw - label_inset), y: dpr_top }, color: dpr_col, align: (Top, Left) })
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
							d_w = model.font.measure({ text: d_txt, size: 10.0, spacing: Text.default_spacing }).width
							d_top = delta_top((cy(I64.to_f32(r.prev_w)) + now_y) / 2.0 - 6.0)
							Text.from(d_txt, model.font).size(10).draw!(frame, { pos: { x: delta_left_x(cx(r.i), d_w, pad_l + pw - label_inset), y: d_top }, color: d_col, align: (Top, Left) })
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

	# a label keeps this much plot between itself and the right edge, so it
	# reads apart from the CP label drawn just beyond it
	label_inset : F32
	label_inset = 8.0

	# a label centred on a rung stays inside the plot: the last rung sits on
	# the plot's right edge, where a centred label would run into the CP
	# label beyond it, so the centre moves in by what overhangs. A label
	# wider than the plot centres on it
	label_center_within : F32, F32, F32, F32 -> F32
	label_center_within = |x, half_w, lo, hi|
		if half_w * 2.0 >= hi - lo ((lo + hi) / 2.0)
		else F32.max(lo + half_w, F32.min(x, hi - half_w))

	# a delta sits 10px right of its rung, left-aligned; when that would run
	# past the plot's right edge (the last rung is that edge, and the CP label
	# sits just beyond it) it sits 10px left of the rung instead, ending there
	delta_left_x : F32, F32, F32 -> F32
	delta_left_x = |x, w, hi| if x + 10.0 + w <= hi (x + 10.0) else x - 10.0 - w


	# the first rung's introductions laid out in the order of the dots they
	# name: a label crossing one placed before it goes below that one.
	# Whenever the draw includes another introduction it includes "best
	# ever", whose dot is the topmost, so the placed labels are in y order
	# when each next one is checked and the single pass settles. A
	# previous-window label whose dot sits at most three pixels below the
	# this-window dot does not cross that label and keeps its own offset,
	# which puts it first
	Intro : { text : Str, y : F32, dot : F32, color : Color.Rgba }
	layout_intros : List(Intro) -> List(Intro)
	layout_intros = |lines| {
		by_dot = List.sort_with(lines, |a, b| if a.dot < b.dot Before else if a.dot > b.dot After else Same)
		List.fold(by_dot, [], |acc, l| {
			y = List.fold(acc, l.y, |y0, p| if y0 < p.y + 11.0 and y0 + 11.0 > p.y (p.y + 11.0) else y0)
			List.append(acc, { ..l, y })
		})
	}

	# a label of height h against boxes already placed: one whose box crosses
	# any of them moves up or down to the nearest edge that clears every box,
	# keeping its x; one crossing none stays. The topmost box's upper edge
	# always clears, so a crossing label always moves. The first rung's delta
	# is placed with it against the introductions
	top_clear : F32, F32, List({ top : F32, bot : F32 }) -> F32
	top_clear = |top, h, boxes| {
		crosses = |t| List.any(boxes, |b| t < b.bot and t + h > b.top)
		if !crosses(top) top
		else {
			clear = List.keep_if(List.join(List.map(boxes, |b| [b.bot, b.top - h])), |c| !crosses(c))
			List.fold(clear, top, |best, c| if best == top or F32.abs(c - top) < F32.abs(best - top) c else best)
		}
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
# a centred label moves in from the plot's edges by its overhang and no
# further; one wider than the plot sits on the plot's centre
expect Curve.label_center_within(100.0, 40.0, 0.0, 110.0) == 70.0 and Curve.label_center_within(50.0, 40.0, 0.0, 110.0) == 50.0 and Curve.label_center_within(10.0, 40.0, 0.0, 110.0) == 40.0 and Curve.label_center_within(100.0, 60.0, 0.0, 110.0) == 55.0
# a delta that fits to the right of its rung stays there; one that would run
# past the plot ends 10px left of the rung instead
expect Curve.delta_left_x(100.0, 30.0, 200.0) == 110.0 and Curve.delta_left_x(170.0, 30.0, 200.0) == 130.0 and Curve.delta_left_x(160.0, 30.0, 200.0) == 170.0
# a first-rung delta crossing an introduction moves to the nearer clear edge,
# above or below; crossing two stacked ones it takes the nearest edge that
# clears both; crossing none, or touching a box's edge exactly, it stays
expect {
	prev = { top: 100.0, bot: 111.0 }
	now = { top: 130.0, bot: 141.0 }
	near = { top: 104.0, bot: 115.0 }
	Curve.top_clear(115.0, 10.0, [prev, now]) == 115.0
	and Curve.top_clear(104.0, 10.0, [prev, now]) == 111.0
	and Curve.top_clear(93.0, 10.0, [prev, now]) == 90.0
	and Curve.top_clear(125.0, 10.0, [prev, now]) == 120.0
	and Curve.top_clear(104.0, 10.0, []) == 104.0
	and Curve.top_clear(90.0, 10.0, [prev]) == 90.0
	and Curve.top_clear(111.0, 10.0, [prev]) == 111.0
	and Curve.top_clear(110.0, 10.0, [prev]) == 111.0
	and Curve.top_clear(100.0, 10.0, [prev, near]) == 90.0
	and Curve.top_clear(108.0, 10.0, [prev, near]) == 115.0
}
# introductions a few pixels apart are laid out clear of each other, the
# later one taking the nearer clear edge of the earlier
expect {
	prev = { top: 100.0, bot: 111.0 }
	Curve.top_clear(106.0, 11.0, [prev]) == 111.0 and Curve.top_clear(92.0, 11.0, [prev]) == 89.0 and Curve.top_clear(111.0, 11.0, [prev]) == 111.0 and Curve.top_clear(89.0, 11.0, [prev]) == 89.0
}
# the introductions come back in the order of their dots, each crossing label
# pushed below the one before it: a window best a few watts above the previous
# puts "this window" first and "previous window" under it; three bests within a
# few pixels stack best, this window, previous window; labels that do not cross
# keep their own offsets
expect {
	grey = Color.with_alpha(Theme.ctl_c, 130)
	best = { text: "best ever", y: 92.0, dot: 100.0, color: grey }
	prev_near = { text: "previous window", y: 97.0, dot: 105.0, color: grey }
	now_between = { text: "this window", y: 108.0, dot: 102.0, color: Theme.ctl_c }
	prev = { text: "previous window", y: 92.0, dot: 100.0, color: grey }
	now_above = { text: "this window", y: 100.0, dot: 94.0, color: Theme.ctl_c }
	now_far = { text: "this window", y: 136.0, dot: 130.0, color: Theme.ctl_c }
	pair = |ls| List.map(ls, |l| (l.text, l.y))
	pair(Curve.layout_intros([prev, now_above])) == [("this window", 100.0), ("previous window", 111.0)]
	and pair(Curve.layout_intros([best, prev_near, now_between])) == [("best ever", 92.0), ("this window", 108.0), ("previous window", 119.0)]
	and pair(Curve.layout_intros([prev, now_far])) == [("previous window", 92.0), ("this window", 136.0)]
	and pair(Curve.layout_intros([prev])) == [("previous window", 92.0)]
	and Curve.top_clear(100.5, 10.0, [{ top: 100.0, bot: 111.0 }]) == 111.0
}
