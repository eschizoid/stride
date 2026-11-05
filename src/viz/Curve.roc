import rr.Color
import rr.Draw
import rr.Text
import core.Bus
import core.Fmt
import core.Sports
import core.Units
import Db
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
		curve = model.curve_family
		units = model.units
		# the planned targets this curve carries (marks_for says which)
		plan_marks = marks_for(curve, model.plan_targets, model.pace_targets)
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
		# flight a note says so, so a click that takes a beat reads as working
		# rather than dead. The old curve stays on screen until the fresh one
		# lands. The note takes the caption slot: the row under the chips,
		# right-aligned, which no chip reaches (caption_top sits below
		# chip_bottom). The caption describes the curve being replaced, so it
		# yields to the note. Like the caption, the note gives way to a rung or
		# target tooltip, which owns the left of the same row.
		if model.reloading and !(rung_hovered(model, win_w, win_h)) {
			Text.from(loading_note, model.font).size(11).draw!(frame, { pos: { x: win_w - 40.0, y: caption_top }, color: ink_muted, align: (Top, Right) })
		}
		# one line above the hint row: the chips own the top-right band, and
		# hint plus caption together outgrow a single bottom line
		model.fit_lbl.draw!(frame, { pos: { x: win_w - 40.0, y: win_h - 52.0 }, color: ink_muted, align: (Top, Right) })
		# the same range chips the form board wears, judged on curve_days -
		# the window switch must be visible and clickable, not a key secret
		List.for_each!(
			List.map_with_index(model.subs, |s, i| { s, i }),
			|x| {
				chx = win_w - 420.0 + U64.to_f32(x.i) * 54.0
				on = (
					match U64.to_i64_try(x.s.r) {
						Ok(ri) => ri
						Err(_) => -1
					}
				) == model.curve_days
				hov = model.mouse_x >= chx and model.mouse_x <= chx + 46.0 and model.mouse_y >= chip_top and model.mouse_y <= chip_bottom
				style = if (on) (Draw.filled(Color.with_alpha(ctl_c, 60))) else if (hov) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
				frame.rounded_rectangle!({ x: chx, y: chip_top, width: 46.0, height: chip_bottom - chip_top, radius: 6.0, segments: 6, style })
				x.s.chip.draw!(frame, { pos: { x: chx + 23.0, y: 68.0 }, color: if (on) Color.white else ink_muted, align: (Top, Center) })
			},
		)
		# the curve chips and the power/pace pair beside the range chips: the
		# lit ones are the curve on screen and its mode
		List.for_each!(
			curve_chips(win_w, model.curve_keys, curve),
			|fc| {
				hov = model.mouse_x >= fc.x and model.mouse_x <= fc.x + chip_w and model.mouse_y >= chip_top and model.mouse_y <= chip_bottom
				style = if (fc.on) (Draw.filled(Color.with_alpha(Theme.tsb_c, 60))) else if (hov) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
				frame.rounded_rectangle!({ x: fc.x, y: chip_top, width: chip_w, height: chip_bottom - chip_top, radius: 6.0, segments: 6, style })
				Text.from(fc.label, model.font).size(12).draw!(frame, { pos: { x: fc.x + chip_w / 2.0, y: 68.0 }, color: if (fc.on) Color.white else ink_muted, align: (Top, Center) })
			},
		)
		# eight zero rungs IS the no-records state - the loader materializes
		# every rung, so emptiness is the summed watts, not the list length
		have = List.fold(model.prs, 0.I64, |a, pr| a + pr.w)
		if List.is_empty(model.prs) or have == 0 {
			Text.from(empty_note(curve), model.font).size(14).draw!(frame, { pos: { x: 36.0, y: 130.0 }, color: ink_muted, align: (Top, Left) })
		} else {
			pw = win_w - pad_l - pad_r
			ph = win_h - pad_t - pad_b
			# the record ladder is the master axis; the window's value joins by
			# duration. Index spacing, not time: a linear axis piles the short
			# rungs onto the left edge.
			joined = |pts, secs| List.fold(
				pts,
				0.I64,
				|a, c| if (c.dur_s == secs) (
					match F32.round_to_u64_try(c.watts) {
						Ok(cw) => (
							match U64.to_i64_try(cw) {
								Ok(ci) => ci
								Err(_) => a
							}
						)
						Err(_) => a
					}
				) else a,
			)
			# each window judged on its own: a rung within flat_ratio of the next
			# longer one was not pushed, and its dot and delta go quiet
			now_flags = unpushed(List.map(model.prs, |pr| joined(model.curve, pr.secs)))
			prev_flags = unpushed(List.map(model.prs, |pr| joined(model.curve_prev, pr.secs)))
			rungs = List.map_with_index(
				model.prs,
				|pr, i| {
					now_w = joined(model.curve, pr.secs)
					prev_w = joined(model.curve_prev, pr.secs)
					now_unp = List.get(now_flags, i) ?? Bool.False
					prev_unp = List.get(prev_flags, i) ?? Bool.False
					src = List.find_first(model.curve, |cp| cp.dur_s == pr.secs)
					src_txt = match src {
						Ok(sp) => source_text(sp)
						Err(_) => ""
					}
					stale = match src {
						Ok(sp) => stale_best(sp.ago, model.curve_days)
						Err(_) => Bool.False
					}
					{ pr, now_w, prev_w, i, now_unp, prev_unp, src_txt, stale }
				},
			)
			span = axis_span(curve, List.join(List.map(rungs, |r| [r.pr.w, r.now_w, r.prev_w])), List.map(plan_marks, |t| t.val), model.fit_cp)
			w_lo = span.lo
			w_hi = span.hi
			nlast = List.len(rungs) - 1
			cx = |i| if (nlast == 0) (pad_l + pw / 2.0) else pad_l + pw * U64.to_f32(i) / U64.to_f32(nlast)
			cy = |w| pad_t + ph * (1.0 - (w - w_lo) / (w_hi - w_lo))
			# Each line introduces itself at its first rung, so the chart reads
			# with no narrator. Each label clears its own line's first segment,
			# which can fall or rise steeply across the label's width; the labels
			# are then laid out in their dots' order, since two bests a few watts
			# apart would otherwise overprint. The first rung's delta, the grid
			# rules and the threshold line read the same placement to keep clear
			# of them, so the drawing and the avoidance cannot drift apart.
			slope0 = |sel| match (List.first(rungs), List.get(rungs, 1)) {
				(Ok(a), Ok(b)) => if (sel(a) > 0 and sel(b) > 0 and nlast > 0) ((cy(I64.to_f32(sel(b))) - cy(I64.to_f32(sel(a)))) / (cx(1) - cx(0))) else 0.0
				_ => 0.0
			}
			intro_w = |t| 14.0 + model.font.measure({ text: t, size: 11.0, spacing: Text.default_spacing }).width
			intro_lines = match List.first(rungs) {
				Ok(r0) => List.join([
					(if (r0.pr.w > 0) [{ text: "best ever", y: intro_above(cy(I64.to_f32(r0.pr.w)), slope0(|r| r.pr.w), intro_w("best ever")), dot: cy(I64.to_f32(r0.pr.w)), color: Color.with_alpha(ink_muted, 130) }] else []),
					(if (r0.prev_w > 0 and r0.prev_w < r0.pr.w) [{ text: "previous window", y: intro_above(cy(I64.to_f32(r0.prev_w)), slope0(|r| r.prev_w), intro_w("previous window")), dot: cy(I64.to_f32(r0.prev_w)), color: ink_muted }] else []),
					(if (r0.now_w > 0 and r0.now_w < r0.pr.w) [{ text: "this window", y: intro_below(cy(I64.to_f32(r0.now_w)), slope0(|r| r.now_w), intro_w("this window")), dot: cy(I64.to_f32(r0.now_w)), color: Theme.ctl_c }] else []),
				])
				Err(_) => []
			}
			placed = layout_intros(intro_lines)
			# where each introduction ends, so a rule crossing one starts past it
			intro_spans = List.map(placed, |l| { top: l.y, bot: l.y + 11.0, right: cx(0.U64) + intro_w(l.text) })
			# the grid: a faint rule and label at each grid_vals value, which
			# come from the axis span itself, so any scale gets its rules
			List.for_each!(
				# a rule in the band the rung labels sit in, or hard under the tooltip
				# row, would run through their text
				List.keep_if(grid_vals(curve, units, w_lo, w_hi), |gw| cy(gw) > pad_t + 8.0 and cy(gw) < pad_t + ph - 26.0),
				|gw| {
					frame.line!({ start: { x: rule_start(cy(gw), pad_l, intro_spans), y: cy(gw) }, end: { x: win_w - pad_r, y: cy(gw) }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 36), 1) })
					Text.from(
						match F32.round_to_i64_try(gw) {
							Ok(gi) => axis_text(curve, units, gi)
							Err(_) => ""
						},
						model.font,
					).size(10).draw!(frame, { pos: { x: pad_l - 8.0, y: cy(gw) - 6.0 }, color: ink_faint, align: (Top, Right) })
				},
			)
			# CP from the window's fit, dashed - the blue curve should flatten
			# toward it, and a fit far from the long rungs is visibly wrong. The
			# loader zeroes fit_cp unless the fit is usable (fit_usable), and the
			# footer then says why instead
			if model.fit_cp > w_lo and model.fit_cp < w_hi {
				cpy = cy(model.fit_cp)
				cp_a = 120
				cp_lbl_c = tsb_c
				List.for_each!(
					List.map_with_index(List.repeat({}, 60), |_u, k| k),
					|k| {
						x0 = pad_l + U64.to_f32(k) * (pw / 60.0)
						if (x0 >= rule_start(cpy, pad_l, intro_spans)) (frame.line!({ start: { x: x0, y: cpy }, end: { x: x0 + pw / 120.0, y: cpy }, stroke: Draw.stroke(Color.with_alpha(tsb_c, cp_a), 1) })) else {}
					},
				)
				model.cp_lbl.draw!(frame, { pos: { x: pad_l + pw + 8.0, y: cpy }, color: cp_lbl_c, align: (Middle, Left) })
			}
			List.for_each!(placed, |l| Text.from(l.text, model.font).size(11).draw!(frame, { pos: { x: cx(0.U64) + 14.0, y: l.y }, color: l.color, align: (Top, Left) }))
			intro_boxes = List.map(placed, |l| { top: l.y, bot: l.y + 11.0 })
			# three envelopes back to front: the record book faintest (a
			# reference, no longer the antagonist), the previous window in
			# quiet grey, this window loudest. Envelope segments only between
			# rungs that HAVE values - a 0 rung must not drag a line to the
			# floor.
			List.for_each!(
				rungs,
				|r|
					match List.get(rungs, r.i + 1) {
						Ok(nxt) => if (r.pr.w > 0 and nxt.pr.w > 0) (frame.line!({ start: { x: cx(r.i), y: cy(I64.to_f32(r.pr.w)) }, end: { x: cx(nxt.i), y: cy(I64.to_f32(nxt.pr.w)) }, stroke: Draw.stroke(Color.with_alpha(ink_muted, 45), 1) })) else {}
						Err(_) => {}
					},
			)
			List.for_each!(
				rungs,
				|r|
					match List.get(rungs, r.i + 1) {
						Ok(nxt) => if (r.prev_w > 0 and nxt.prev_w > 0) (frame.line!({ start: { x: cx(r.i), y: cy(I64.to_f32(r.prev_w)) }, end: { x: cx(nxt.i), y: cy(I64.to_f32(nxt.prev_w)) }, stroke: Draw.stroke(Color.with_alpha(ink_muted, 110), 1) })) else {}
						Err(_) => {}
					},
			)
			List.for_each!(
				rungs,
				|r|
					match List.get(rungs, r.i + 1) {
						Ok(nxt) => if (r.now_w > 0 and nxt.now_w > 0) (frame.line!({ start: { x: cx(r.i), y: cy(I64.to_f32(r.now_w)) }, end: { x: cx(nxt.i), y: cy(I64.to_f32(nxt.now_w)) }, stroke: Draw.stroke(Color.with_alpha(ctl_c, 150), 2) })) else {}
						Err(_) => {}
					},
			)
			# planned targets on the curve: a gold ring at the rep duration and the
			# target watts, labelled with the day and the share of this window's
			# best at that duration, so a prescription reads against what the
			# athlete has done. Targets whose rings would overlap share one ring
			# with their labels stacked under it, and a ring whose labels would
			# run into the previous ring's starts below them. Hovering a ring
			# names every session in it, one line each, and takes the tooltip
			# line from the rungs.
			rung_secs = List.map(rungs, |r| r.pr.secs)
			now_pts = List.map(rungs, |r| { secs: r.pr.secs, w: r.now_w })
			tx = |t| {
				p = rung_pos(rung_secs, t.dur_s)
				if (nlast == 0) (pad_l + pw / 2.0) else pad_l + pw * p / U64.to_f32(nlast)
			}
			marks = List.map(plan_marks, |t| { x: tx(t), y: cy(I64.to_f32(t.val)) })
			rings = List.map(
				cluster_marks(marks, ring_merge),
				|idxs| {
					# targets load in date order, so input order stacks a ring's
					# labels by date
					in_order = List.sort_with(idxs, |a, b| if (a < b) Before else if (a > b) After else Same)
					ts = List.keep_oks(in_order, |i| List.get(plan_marks, i))
					ps = List.keep_oks(in_order, |i| List.get(marks, i))
					n = F32.max(1.0, U64.to_f32(List.len(ps)))
					{ ts, x: List.fold(ps, 0.0, |a, p| a + p.x) / n, y: List.fold(ps, 0.0, |a, p| a + p.y) / n }
				},
			)
			ring_rows = List.map2(rings, label_rows(List.map(rings, |g| { x: g.x, lines: List.len(g.ts) }), ring_label_w), |g, base| { g, base })
			tgt_hover = List.find_first(rings, |g| F32.abs(model.mouse_x - g.x) <= 8.0 and F32.abs(model.mouse_y - g.y) <= 8.0)
			tgt_hovering = match tgt_hover {
				Ok(_) => Bool.True
				Err(_) => Bool.False
			}
			List.for_each!(
				ring_rows,
				|x| {
					frame.circle!({ center: { x: x.g.x, y: x.g.y }, radius: 6.0, style: Draw.filled(Color.with_alpha(Theme.gold_c, 200)) })
					frame.circle!({ center: { x: x.g.x, y: x.g.y }, radius: 3.0, style: Draw.filled(Theme.bg) })
					List.for_each!(
						List.map_with_index(x.g.ts, |t, k| { t, k }),
						|e| {
							lbl = target_label(e.t, best_at(now_pts, e.t.dur_s))
							lw = model.font.measure({ text: lbl, size: 10.0, spacing: Text.default_spacing }).width
							Text.from(lbl, model.font).size(10).draw!(frame, { pos: { x: label_center_within(x.g.x, lw / 2.0, pad_l, pad_l + pw - label_inset), y: x.g.y + 10.0 + (x.base + U64.to_f32(e.k)) * 12.0 }, color: Theme.gold_c, align: (Top, Center) })
						},
					)
				},
			)
			match tgt_hover {
				Ok(g) =>
					List.for_each!(
						List.map_with_index(g.ts, |t, k| { t, k }),
						|e| Text.from(target_tip(e.t, best_at(now_pts, e.t.dur_s)), model.font).size(12).draw!(frame, { pos: { x: 36.0, y: 92.0 + U64.to_f32(e.k) * 14.0 }, color: Color.white, align: (Top, Left) }),
					)
				Err(_) => {}
			}
			# the this-window and previous-window lines as segments, for the
			# deltas to keep clear of
			seg_list = |ys| List.keep_oks(
				List.map_with_index(ys, |y, i| { y, i }),
				|e| match List.get(ys, e.i + 1) {
					Ok(ny) => if (e.y > 0 and ny > 0) (Ok({ x0: cx(e.i), y0: cy(I64.to_f32(e.y)), x1: cx(e.i + 1), y1: cy(I64.to_f32(ny)) })) else Err(Gap)
					Err(_) => Err(Gap)
				},
			)
			segs = List.concat(seg_list(List.map(rungs, |r| r.now_w)), seg_list(List.map(rungs, |r| r.prev_w)))
			# a record set in the last seven calendar days is NEWS: the rung
			# earns a pulsing gold ring. Heat carries one row per day, so its
			# last seven entries ARE the last seven days.
			recent7 = List.take_last(model.heat, 7)
			nt = model.tick % 40
			ntri = (if (nt < 20) (U64.to_f32(nt)) else U64.to_f32(40 - nt)) / 20.0
			List.for_each!(
				rungs,
				|r| {
					rec_y = cy(I64.to_f32(r.pr.w))
					# the first rung's delta keeps clear of the introductions beside it
					delta_top = |top| if (r.i == 0.U64) (top_clear(top, 10.0, intro_boxes)) else top
					fresh = r.pr.w > 0 and List.fold(recent7, Bool.False, |a9, hd| a9 or hd.day == r.pr.day)
					if fresh {
						halo_a = match F32.to_u8_try(50.0 + ntri * 50.0) {
							Ok(ha) => ha
							Err(_) => 50
						}
						frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 9.0 + ntri * 3.0, style: Draw.filled(Color.with_alpha(Theme.gold_c, halo_a)) })
						nr_half = model.font.measure({ text: "new record", size: 11.0, spacing: Text.default_spacing }).width / 2.0
						Text.from("new record", model.font).size(11).draw!(frame, { pos: { x: label_center_within(cx(r.i), nr_half, pad_l, pad_l + pw - label_inset), y: rec_y - 34.0 }, color: Theme.gold_c, align: (Top, Center) })
					}
					if (r.pr.w == 0) {
						# a rung with no effort on record keeps its label and rail, nothing else
					} else if r.now_w >= r.pr.w and r.now_w > 0 {
						# the window best IS the record: one teal dot - and the
						# delta still prints, because a record rung's change is the
						# best news on the chart, not a case to suppress. Teal for
						# both is a decision: it is the house "good" accent, and
						# the dot and the text differ in shape.
						frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 5.0, style: Draw.filled(tsb_c) })
						pr_half = model.font.measure({ text: "pr", size: 10.0, spacing: Text.default_spacing }).width / 2.0
						Text.from("pr", model.font).size(10).draw!(frame, { pos: { x: label_center_within(cx(r.i), pr_half, pad_l, pad_l + pw - label_inset), y: rec_y - 20.0 }, color: tsb_c, align: (Top, Center) })
						dpr_txt = if (r.now_unp or r.prev_unp) "" else delta_for(curve, units, r.now_w, r.prev_w)
						if dpr_txt != "" {
							dpr_col = if (r.now_w > r.prev_w) tsb_c else Theme.alarm_c
							dpr_w = model.font.measure({ text: dpr_txt, size: 10.0, spacing: Text.default_spacing }).width
							# at the first rung "pr" is clamped to the plot's left edge, under the
							# delta's x, so it counts as a box to clear too
							dpr_boxes = if (r.i == 0.U64) (List.append(intro_boxes, { top: rec_y - 20.0, bot: rec_y - 10.0 })) else []
							dpr_top = if (r.i == 0.U64) (top_clear((cy(I64.to_f32(r.prev_w)) + rec_y) / 2.0 - 6.0, 10.0, dpr_boxes)) else (cy(I64.to_f32(r.prev_w)) + rec_y) / 2.0 - 6.0
							Text.from(dpr_txt, model.font).size(10).draw!(frame, { pos: { x: delta_left_x(cx(r.i), dpr_w, pad_l + pw - label_inset), y: dpr_top }, color: dpr_col, align: (Top, Left) })
						}
					} else {
						frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 3.0, style: Draw.filled(Color.with_alpha(ink_muted, 80)) })
						if r.prev_w > 0 and r.prev_w < r.pr.w {
							frame.circle!({ center: { x: cx(r.i), y: cy(I64.to_f32(r.prev_w)) }, radius: 4.0, style: Draw.filled(Color.with_alpha(ink_muted, if (r.prev_unp) (70) else 150)) })
						}
						if r.now_w > 0 {
							now_y = cy(I64.to_f32(r.now_w))
							frame.circle!({ center: { x: cx(r.i), y: now_y }, radius: 4.0, style: Draw.filled(if (r.now_unp) (Color.with_alpha(ink_muted, 170)) else if (r.stale) (Color.with_alpha(ctl_c, 110)) else ctl_c) })
							# the change against the PREVIOUS window, signed, right
							# where it lives - green-teal going up, alarm going down
							d_txt = if (r.now_unp or r.prev_unp) "" else delta_for(curve, units, r.now_w, r.prev_w)
							if d_txt != "" {
								d_col = if (r.now_w > r.prev_w) tsb_c else Theme.alarm_c
								d_w = model.font.measure({ text: d_txt, size: 10.0, spacing: Text.default_spacing }).width
								prev_y = cy(I64.to_f32(r.prev_w))
								d_mid = (prev_y + now_y) / 2.0 - 6.0
								# the first rung's delta keeps to its side of the introductions;
								# every other one takes the first spot clear of both lines
								spot = if (r.i == 0.U64) ({ left: delta_left_x(cx(r.i), d_w, pad_l + pw - label_inset), top: delta_top(d_mid) }) else delta_spot({ x: cx(r.i), w: d_w, h: 10.0, mid: d_mid, upper: F32.min(prev_y, now_y), lower: F32.max(prev_y, now_y), hi: pad_l + pw - label_inset }, segs)
								Text.from(d_txt, model.font).size(10).draw!(frame, { pos: { x: spot.left, y: spot.top }, color: d_col, align: (Top, Left) })
							}
						}
					}
					Text.from(r.pr.rung, model.font).size(12).draw!(frame, { pos: { x: cx(r.i), y: pad_t + ph - 18.0 }, color: ink_faint, align: (Top, Center) })
					# hover the rung's column: the full story under the title
					half = if (nlast == 0) (pw / 2.0) else pw / U64.to_f32(nlast) / 2.0
					if model.mouse_x >= cx(r.i) - half and model.mouse_x < cx(r.i) + half and model.mouse_y >= pad_t and model.mouse_y <= pad_t + ph and !tgt_hovering {
						now_txt = if (r.now_w > 0) ("   now ${val_text(curve, units, r.now_w)}") else "   no effort this window"
						prev_txt = if (r.prev_w > 0) ("   prev ${val_text(curve, units, r.prev_w)}") else ""
						quality = if (r.now_unp) "   not all-out" else if (r.stale) "   stale" else ""
						tip = if (r.pr.w > 0) ("${r.pr.rung}   best ${val_text(curve, units, r.pr.w)} set ${r.pr.day}${now_txt}${r.src_txt}${quality}${prev_txt}") else "${r.pr.rung}   no effort on record"
						Text.from(tip, model.font).size(12).draw!(frame, { pos: { x: 36.0, y: 92.0 }, color: Color.white, align: (Top, Left) })
					}
				},
			)
			# the window's unpushed durations, at the right of the tooltip line
			# between the chips and the plot, so no gridline runs through it. A
			# tooltip owns that line while one shows; the hovered rung's own
			# tooltip already says whether it was pushed.
			unp_txt = unpushed_caption(List.map(rungs, |r| r.pr.rung), List.map(rungs, |r| r.now_unp), model.curve_days)
			rung_hovering = match rung_at(model.mouse_x, model.mouse_y, win_w, win_h, List.len(model.prs)) {
				Ok(_) => Bool.True
				Err(_) => Bool.False
			}
			if unp_txt != "" and !rung_hovering and !tgt_hovering and !model.reloading {
				Text.from(unp_txt, model.font).size(11).draw!(frame, { pos: { x: win_w - 40.0, y: caption_top }, color: ink_faint, align: (Top, Right) })
			}
		}
		model.curve_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}

	# A CP fit is drawn only when it is usable: r2 at or above fit_r2_min and
	# W' inside a physiologically plausible band. A fit through steady class
	# bests rather than maximal ones returns a W' of a few kJ, far below any
	# rider's anaerobic capacity, and a CP line drawn from it reads as a
	# threshold the data does not support.
	fit_r2_min : F32
	fit_r2_min = 0.9
	w_prime_lo : F32
	w_prime_lo = 5000.0
	w_prime_hi : F32
	w_prime_hi = 40000.0

	# r2 to two decimals, cut toward zero and signed: one decimal reads 0.95
	# as 1.0, and rounding would show a fit just under the 0.9 floor as 0.90.
	# An r2 below zero (a fit worse than the mean) keeps its sign. The 1e-4
	# nudge keeps an F32 a hair under a two-decimal value (0.84 is stored as
	# 0.8399999) from cutting down a whole hundredth.
	r2_str : F32 -> Str
	r2_str = |v| match F32.round_to_i64_try(F32.div_floor_by((if (v < 0.0) -v else v) * 100.0 + 0.0001, 1.0)) {
		Ok(a) => {
			sign = if (v < 0.0 and a > 0) "-" else ""
			"${sign}${I64.to_str(a // 100)}.${if (a % 100 < 10) "0" else ""}${I64.to_str(a % 100)}"
		}
		Err(_) => "?"
	}

	fit_usable : Db.Fit -> Bool
	fit_usable = |fit| fit.ok and fit.r2 >= fit_r2_min and fit.w_prime >= w_prime_lo and fit.w_prime <= w_prime_hi

	# the footer under the curve: the fit's numbers when it is usable, and
	# otherwise what is wrong with it and the effort that would fix it, with
	# how long ago the window's 20-minute best was set (-1: none in the window)
	fit_caption : Db.Fit, I64 -> Str
	fit_caption = |fit, best20_age|
		if (!fit.ok) "CP fit unavailable - the engine did not answer"
		else if (fit_usable(fit)) "CP ${Db.fmt_f(fit.cp)} W - W' ${Db.fmt_f(fit.w_prime / 1000.0)} kJ - fit r2 ${r2_str(fit.r2)} from ${Db.fmt_i(fit.points)} bests"
		else {
			why = "no usable CP fit (r2 ${r2_str(fit.r2)}, W' ${Db.fmt_f(fit.w_prime / 1000.0)} kJ)"
			when = if (best20_age < 0) "no 20-min best in this window" else if (best20_age == 0) "20-min best set today" else if (best20_age == 1) "20-min best set 1 day ago" else "20-min best set ${I64.to_str(best20_age)} days ago"
			"${why} - ${when}; an all-out 20 minutes would anchor it"
		}

	# where a duration sits on the rung axis, as a fractional rung index:
	# linear in seconds between the two rungs around it, clamped to the
	# first and last rung
	rung_pos : List(I64), I64 -> F32
	rung_pos = |secs, d| {
		n = List.len(secs)
		first = List.first(secs) ?? 0
		last = List.last(secs) ?? 0
		if (n == 0) 0.0
		else if (d <= first) 0.0
		else if (d >= last) (U64.to_f32(n - 1))
		else
			List.fold(
				List.map_with_index(secs, |s, i| { s, i }),
				0.0,
				|acc, x| match List.get(secs, x.i + 1) {
					Ok(nx) => if (d >= x.s and d < nx) (U64.to_f32(x.i) + I64.to_f32(d - x.s) / I64.to_f32(nx - x.s)) else acc
					Err(_) => acc
				},
			)
	}

	# the window's best at a duration between rungs: linear between the two
	# rungs around it, and 0 when either has no value this window
	best_at : List({ secs : I64, w : I64 }), I64 -> F32
	best_at = |pts, d|
		match List.find_first(pts, |p| p.secs == d) {
			Ok(p) => I64.to_f32(p.w)
			Err(_) =>
				List.fold(
					List.map_with_index(pts, |p, i| { p, i }),
					0.0,
					|acc, x| match List.get(pts, x.i + 1) {
						Ok(nx) =>
							if (d > x.p.secs and d < nx.secs and x.p.w > 0 and nx.w > 0) (I64.to_f32(x.p.w) + I64.to_f32(nx.w - x.p.w) * I64.to_f32(d - x.p.secs) / I64.to_f32(nx.secs - x.p.secs))
							else acc
						Err(_) => acc
					},
				)
		}

	# Target rings that would overlap merge: a mark joins a cluster when it
	# lies within ring_merge pixels of the cluster's first mark on both axes,
	# the ring's diameter plus a pixel each side. Marks are taken in x then y
	# order, so clusters come out left to right; each cluster lists indices
	# into the input.
	ring_merge : F32
	ring_merge = 14.0

	cluster_marks : List({ x : F32, y : F32 }), F32 -> List(List(U64))
	cluster_marks = |pts, th| {
		order = List.sort_with(
			List.map_with_index(pts, |p, i| { p, i }),
			|a, b| if (a.p.x < b.p.x) Before else if (a.p.x > b.p.x) After else if (a.p.y < b.p.y) Before else if (a.p.y > b.p.y) After else if (a.i < b.i) Before else After,
		)
		grouped = List.fold(
			order,
			[],
			|acc, e| match List.last(acc) {
				Ok(c) =>
					if (F32.abs(e.p.x - c.x) <= th and F32.abs(e.p.y - c.y) <= th) (List.append(List.drop_last(acc, 1), { ..c, members: List.append(c.members, e.i) }))
					else List.append(acc, { x: e.p.x, y: e.p.y, members: [e.i] })
				Err(_) => List.append(acc, { x: e.p.x, y: e.p.y, members: [e.i] })
			},
		)
		List.map(grouped, |c| c.members)
	}

	# a target label's width at the 10px label size, generous for the
	# widest form, a pace label such as "MM-DD M:SS/100m NNN%"
	ring_label_w : F32
	ring_label_w = 120.0

	# the first label row of each ring, left to right: a ring closer than a
	# label's width to the one before it starts below that ring's labels, and
	# one far enough away starts at the top row again
	label_rows : List({ x : F32, lines : U64 }), F32 -> List(F32)
	label_rows = |groups, w| {
		placed = List.fold(
			groups,
			[],
			|acc, g| {
				base = match List.last(acc) {
					Ok(p) => if (F32.abs(g.x - p.x) < w) (p.base + U64.to_f32(p.lines)) else 0.0
					Err(_) => 0.0
				}
				List.append(acc, { x: g.x, lines: g.lines, base })
			},
		)
		List.map(placed, |p| p.base)
	}

	# a planned target's marker label: its day, its value, and its share of
	# the window's best at the rep duration (omitted when the window has
	# none). On a pace curve the share is of speed, so 95% is a target a
	# little slower than the window's best.
	target_label : Mark, F32 -> Str
	target_label = |t, best| {
		mmdd = Str.from_utf8_lossy(List.drop_first(Str.to_utf8(t.day), 5))
		pct = if (best <= 0.0) "" else " ${Db.fmt_i(I64.to_f32(t.val) / best * 100.0)}%"
		"${mmdd} ${t.val_txt}${pct}"
	}

	target_tip : Mark, F32 -> Str
	target_tip = |t, best| {
		share = if (best <= 0.0) "no window best at that duration" else "${Db.fmt_i(I64.to_f32(t.val) / best * 100.0)}% of this window's best at that duration"
		"${t.day} ${t.typ}: ${t.rep_txt} @ ${t.val_txt} - ${share}"
	}

	# ── the band above the plot. The range and curve chips fill the top
	# right from chip_top to chip_bottom; the row under them, caption_top,
	# carries the unpushed caption or the loading note on the right and a
	# rung tooltip on the left, and ends before the plot's first gridline at
	# Theme.pad_t. Click and hover tests in main.roc use the same 64..86 band.
	chip_top : F32
	chip_top = 64.0

	chip_bottom : F32
	chip_bottom = 86.0

	caption_top : F32
	caption_top = Theme.pad_t - 18.0

	loading_note : Str
	loading_note = "loading..."

	# whether the pointer sits on a rung column, where a tooltip owns the
	# caption row
	rung_hovered : Ui.Model, F32, F32 -> Bool
	rung_hovered = |model, win_w, win_h|
		match rung_at(model.mouse_x, model.mouse_y, win_w, win_h, List.len(model.prs)) {
			Ok(_) => Bool.True
			Err(_) => Bool.False
		}

	# what the view says when the chosen curve has no data on record: the
	# choice is kept, and the note says which kind of effort is missing
	empty_note : Str -> Str
	empty_note = |curve|
		match Bus.curve_key(curve) {
			Pace(sp) => "no ${sport_name(sp)} pace on record yet"
			Power(fam) => if (fam == "Ride") "no ride power on record yet" else "no ${chip_label(curve)} power on record yet"
		}

	# ── pushed and unpushed rungs. A maximal best at one duration stands
	# clearly above the best at the next longer one; a best within
	# flat_ratio of it is that session's ordinary output, not an all-out
	# effort, so a gap between two such rungs reflects which workouts were
	# chosen rather than a change in fitness. The longest rung has nothing
	# longer to compare with and counts as pushed; an absent rung (0) is
	# neither.
	flat_ratio : F32
	flat_ratio = 1.05

	unpushed : List(I64) -> List(Bool)
	unpushed = |ws|
		List.map_with_index(
			ws,
			|w, i| match List.get(ws, i + 1) {
				Ok(nx) => w > 0 and nx > 0 and I64.to_f32(w) < I64.to_f32(nx) * flat_ratio
				Err(_) => Bool.False
			},
		)

	# the caption naming the window's unpushed durations, or "" when every
	# rung with a value was pushed
	unpushed_caption : List(Str), List(Bool), I64 -> Str
	unpushed_caption = |rungs, flags, days| {
		names = List.keep_oks(List.map2(rungs, flags, |r, f| { r, f }), |x| if (x.f) Ok(x.r) else Err(Pushed))
		if (List.is_empty(names)) "" else "no all-out effort in ${I64.to_str(days)} days at ${Str.join_with(names, ", ")}"
	}

	# a window best set more than half the window ago reads as stale
	stale_best : I64, I64 -> Bool
	stale_best = |age_days, window_days| age_days >= 0 and age_days * 2 > window_days

	# the rung tooltip's source: which session set the window's best, and when
	source_text : Db.CurvePt -> Str
	source_text = |p| if (p.name == "" and p.day == "") "" else "   ${p.name} ${p.day}"

	# the rung column under (mx, my), laid out the way draw! lays it: index
	# spacing over the plot between the theme's paddings, each column half a
	# step to either side of its rung
	rung_at : F32, F32, F32, F32, U64 -> Try(U64, [NoRung])
	rung_at = |mx, my, win_w, win_h, n| {
		pw = win_w - Theme.pad_l - Theme.pad_r
		ph = win_h - Theme.pad_t - Theme.pad_b
		if (n == 0 or my < Theme.pad_t or my > Theme.pad_t + ph) Err(NoRung)
		else {
			nlast = n - 1
			half = if (nlast == 0) (pw / 2.0) else pw / U64.to_f32(nlast) / 2.0
			cx = |i| if (nlast == 0) (Theme.pad_l + pw / 2.0) else Theme.pad_l + pw * U64.to_f32(i) / U64.to_f32(nlast)
			match List.find_first(List.map_with_index(List.repeat({}, n), |_u, k| k), |i| mx >= cx(i) - half and mx < cx(i) + half) {
				Ok(i) => Ok(i)
				Err(_) => Err(NoRung)
			}
		}
	}

	# the session behind the hovered rung's window best, for TAB to open in
	# the trace view; -1 when no rung is hovered or the rung has no best
	hovered_source : Ui.Model -> I64
	hovered_source = |model|
		match rung_at(model.mouse_x, model.mouse_y, model.win.w, model.win.h, List.len(model.prs)) {
			Ok(i) => match List.get(model.prs, i) {
				Ok(pr) => match List.find_first(model.curve, |c| c.dur_s == pr.secs) {
					Ok(c) => if (c.aid > 0) c.aid else -1
					Err(_) => -1
				}
				Err(_) => -1
			}
			Err(_) => -1
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
		if (half_w * 2.0 >= hi - lo) ((lo + hi) / 2.0)
		else F32.max(lo + half_w, F32.min(x, hi - half_w))

	# a delta sits 10px right of its rung, left-aligned; when that would run
	# past the plot's right edge (the last rung is that edge, and the CP label
	# sits just beyond it) it sits 10px left of the rung instead, ending there
	delta_left_x : F32, F32, F32 -> F32
	delta_left_x = |x, w, hi| if (x + 10.0 + w <= hi) (x + 10.0) else x - 10.0 - w

	# A line segment between two rungs, in screen pixels.
	Seg : { x0 : F32, y0 : F32, x1 : F32, y1 : F32 }

	# a label box crosses a segment when the segment's y-span over the
	# box's columns meets the box's rows; a segment beside the box, or a
	# vertical one, does not cross it
	box_crosses : F32, F32, F32, F32, List(Seg) -> Bool
	box_crosses = |left, w, top, h, segs|
		List.any(
			segs,
			|s| {
				lo_x = F32.max(left, F32.min(s.x0, s.x1))
				hi_x = F32.min(left + w, F32.max(s.x0, s.x1))
				if (lo_x > hi_x or s.x1 == s.x0) Bool.False
				else {
					ya = s.y0 + (s.y1 - s.y0) * (lo_x - s.x0) / (s.x1 - s.x0)
					yb = s.y0 + (s.y1 - s.y0) * (hi_x - s.x0) / (s.x1 - s.x0)
					F32.min(ya, yb) < top + h and F32.max(ya, yb) > top
				}
			},
		)

	# where a delta sits: between its two dots, right of the rung and then
	# left of it; failing both, above the upper dot or below the lower one,
	# right side first. The first spot clear of every line wins. A right
	# spot that would run past hi is never tried, and with no spot clear the
	# delta takes delta_left_x's spot between the dots.
	delta_spot : { x : F32, w : F32, h : F32, mid : F32, upper : F32, lower : F32, hi : F32 }, List(Seg) -> { left : F32, top : F32 }
	delta_spot = |d, segs| {
		right = d.x + 10.0
		sides = if (right + d.w <= d.hi) [right, d.x - 10.0 - d.w] else [d.x - 10.0 - d.w]
		cands = List.concat(
			List.map(sides, |l| { left: l, top: d.mid }),
			List.join(List.map(sides, |l| [{ left: l, top: d.upper - d.h - 6.0 }, { left: l, top: d.lower + 6.0 }])),
		)
		match List.find_first(cands, |c| !box_crosses(c.left, d.w, c.top, d.h, segs)) {
			Ok(c) => c
			Err(_) => { left: delta_left_x(d.x, d.w, d.hi), top: d.mid }
		}
	}

	# where a horizontal rule at y starts: at x0, or 6 px past the right end
	# of every introduction whose box it would cross (2 px of air above and
	# below the box count as crossing)
	rule_start : F32, F32, List({ top : F32, bot : F32, right : F32 }) -> F32
	rule_start = |y, x0, spans| List.fold(List.keep_if(spans, |s| y >= s.top - 2.0 and y <= s.bot + 2.0), x0, |a, s| F32.max(a, s.right + 6.0))

	# Where an introduction sits beside its line's first dot. Below the line,
	# 6 px under the dot, pushed further down when the line falls more than
	# that across the label's width; above it, 8 px over the dot, pushed up
	# when the line rises across the label's width. An 11 pt label is 11 px
	# tall.
	intro_below : F32, F32, F32 -> F32
	intro_below = |dot, slope, w| F32.max(dot + 6.0, dot + slope * w + 2.0)

	intro_above : F32, F32, F32 -> F32
	intro_above = |dot, slope, w| F32.min(dot - 8.0, dot + slope * w - 13.0)

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
		by_dot = List.sort_with(lines, |a, b| if (a.dot < b.dot) Before else if (a.dot > b.dot) After else Same)
		List.fold(
			by_dot,
			[],
			|acc, l| {
				y = List.fold(acc, l.y, |y0, p| if (y0 < p.y + 11.0 and y0 + 11.0 > p.y) (p.y + 11.0) else y0)
				List.append(acc, { ..l, y })
			},
		)
	}

	# a label of height h against boxes already placed: one whose box crosses
	# any of them moves up or down to the nearest edge that clears every box,
	# keeping its x; one crossing none stays. The topmost box's upper edge
	# always clears, so a crossing label always moves. The first rung's delta
	# is placed with it against the introductions
	top_clear : F32, F32, List({ top : F32, bot : F32 }) -> F32
	top_clear = |top, h, boxes| {
		crosses = |t| List.any(boxes, |b| t < b.bot and t + h > b.top)
		if (!crosses(top)) top
		else {
			clear = List.keep_if(List.join(List.map(boxes, |b| [b.bot, b.top - h])), |c| !crosses(c))
			List.fold(clear, top, |best, c| if (best == top or F32.abs(c - top) < F32.abs(best - top)) c else best)
		}
	}

	# ── the signal a curve key draws. A family head draws power in watts; a
	# pace key draws speed, carried through the rungs in millimetres per
	# second and read aloud as pace in the sport's own unit, so the higher
	# dot is the faster one either way.
	is_pace : Str -> Bool
	is_pace = |curve|
		match Bus.curve_key(curve) {
			Pace(_) => Bool.True
			Power(_) => Bool.False
		}

	# the metres a pace curve reads its pace over, and how that reads aloud:
	# rowing per 500m, swimming per 100m, the foot sports per kilometre or
	# per mile as the athlete's units say
	pace_unit_for : [Metric, Imperial], Str -> { m : F64, label : Str }
	pace_unit_for = |units, sport| {
		fam = Sports.canonical(sport)
		label = Sports.pace_label_for(units, fam)
		if (fam == "Rowing" or fam == "Swim") ({ m: I64.to_f64(Sports.pace_unit(fam).dist_m), label }) else { m: Units.split_len(units), label }
	}

	# a speed in millimetres per second as the pace it is, in seconds per
	# unit; 0 for no speed
	pace_secs : I64, F64 -> I64
	pace_secs = |mmps, unit_m| if (mmps <= 0) 0 else (F64.round_to_i64_try(unit_m * 1000.0 / I64.to_f64(mmps)) ?? 0)

	# what the key is called on screen: a chip's short label
	chip_label : Str -> Str
	chip_label = |curve|
		match Bus.curve_key(curve) {
			Power(fam) =>
				if (fam == "Ride") "bike"
				else match List.first(List.keep_if(Sports.families, |f| List.first(f.sports) == Ok(fam))) {
					Ok(f) => (List.first(f.words)).ok_or(Str.with_ascii_lowercased(fam))
					Err(_) => Str.with_ascii_lowercased(fam)
				}
			Pace(sp) =>
				if (sp == "TrailRun") "trail"
				else if (sp == "VirtualRun") "v-run"
				else if (sp == "OpenWaterSwim") "open"
				else if (sp == "VirtualRow") "v-row"
				else if (sp == "Rowing") "row"
				else Str.with_ascii_lowercased(sp)
		}

	# a pace sport spelled for a sentence
	sport_name : Str -> Str
	sport_name = |sp|
		if (sp == "TrailRun") "trail run"
		else if (sp == "VirtualRun") "virtual run"
		else if (sp == "OpenWaterSwim") "open water swim"
		else if (sp == "VirtualRow") "virtual row"
		else Str.with_ascii_lowercased(sp)

	# the view's title line
	title_text : Str, I64 -> Str
	title_text = |curve, days| {
		what = match Bus.curve_key(curve) {
			Pace(sp) => "${sport_name(sp)} pace"
			Power(fam) => if (fam == "Ride") "power" else "${chip_label(curve)} power"
		}
		"${what} - this ${I64.to_str(days)}d vs the ${I64.to_str(days)}d before it"
	}

	# a value on the curve read aloud with its unit: watts, or the pace
	val_text : Str, [Metric, Imperial], I64 -> Str
	val_text = |curve, units, v|
		match Bus.curve_key(curve) {
			Power(_) => Db.num_unit(v, "w")
			Pace(sp) => {
				u = pace_unit_for(units, sp)
				"${Fmt.mmss(pace_secs(v, u.m))}${u.label}"
			}
		}

	# a gridline's label: plain watts, or the pace without its unit
	axis_text : Str, [Metric, Imperial], I64 -> Str
	axis_text = |curve, units, v|
		match Bus.curve_key(curve) {
			Power(_) => I64.to_str(v)
			Pace(sp) => Fmt.mmss(pace_secs(v, (pace_unit_for(units, sp)).m))
		}

	# The value axis. A power curve rises from 0 W to 8% over its highest
	# value, as it always has. A speed curve's values sit in a narrow band
	# far from zero (a runner's 5- and 20-minute bests differ by a few
	# percent), so its axis spans its own values: from 10% under the lowest
	# to 8% of the span over the highest. Zero values are absent rungs and
	# never set the floor.
	axis_span : Str, List(I64), List(I64), F32 -> { lo : F32, hi : F32 }
	axis_span = |curve, rung_vals, mark_vals, fit| {
		vals = List.concat(List.map(List.keep_if(List.concat(rung_vals, mark_vals), |v| v > 0), I64.to_f32), if (fit > 0.0) [fit] else [])
		top = List.fold(vals, 1.0, F32.max)
		if (!is_pace(curve)) ({ lo: 0.0, hi: top * 1.08 })
		else {
			low = List.fold(vals, top, F32.min) * 0.9
			{ lo: low, hi: top + (top - low) * 0.08 }
		}
	}

	# The gridlines between lo and hi. A power curve rules every 100 W. A pace
	# curve rules round paces in its own unit, every 5, 10, 15, 20 or 30
	# seconds or every 1, 2 or 5 minutes - the smallest step that leaves at
	# most six lines - placed at the speed each pace is.
	grid_vals : Str, [Metric, Imperial], F32, F32 -> List(F32)
	grid_vals = |curve, units, lo, hi|
		match Bus.curve_key(curve) {
			Power(_) => {
				n = F32.round_to_u64_try(F32.div_floor_by(hi, 100.0)) ?? 0
				List.keep_if(List.map_with_index(List.repeat({}, n), |_u, k| (U64.to_f32(k) + 1.0) * 100.0), |v| v > lo and v < hi)
			}
			Pace(sp) => {
				m = (pace_unit_for(units, sp)).m
				speed_of = |p| I64.to_f32(F64.round_to_i64_try(m * 1000.0 / I64.to_f64(p)) ?? 0)
				fast = pace_secs(F32.round_to_i64_try(hi) ?? 0, m)
				slow = pace_secs(F32.round_to_i64_try(lo) ?? 0, m)
				if (fast <= 0 or slow <= fast) []
				else {
					step = List.fold([300, 120, 60, 30, 20, 15, 10, 5], 600, |best, s| if ((slow - fast) // s <= 6) s else best)
					first = (fast + step - 1) // step
					count = slow // step - first + 1
					paces = if (count <= 0) [] else List.map_with_index(List.repeat({}, I64.to_u64_wrap(count)), |_u, k| (first + U64.to_i64_wrap(k)) * step)
					List.keep_if(List.map(paces, speed_of), |v| v > lo and v < hi)
				}
			}
		}

	# the window-over-window change: watts with their sign on a power curve
	# (delta_label), and on a pace curve the change in pace in seconds per
	# unit, negative when the window got faster
	delta_for : Str, [Metric, Imperial], I64, I64 -> Str
	delta_for = |curve, units, now, prev|
		match Bus.curve_key(curve) {
			Power(_) => delta_label(now, prev)
			Pace(sp) => {
				m = (pace_unit_for(units, sp)).m
				if (now <= 0 or prev <= 0) ""
				else {
					d = pace_secs(now, m) - pace_secs(prev, m)
					if (d > 0) "+${I64.to_str(d)}s" else if (d < 0) "-${I64.to_str(-d)}s" else ""
				}
			}
		}

	# A critical-speed fit is usable on the same terms as a CP fit: r2 at the
	# floor and D' inside a band that spans the foot, water and erg sports.
	# Three 5-to-20-minute bests that are steady efforts rather than maximal
	# ones still fit a line, with a D' far outside it.
	d_prime_lo : F32
	d_prime_lo = 10.0
	d_prime_hi : F32
	d_prime_hi = 600.0

	fit_usable_for : Str, Db.Fit -> Bool
	fit_usable_for = |curve, fit|
		if (is_pace(curve)) (fit.ok and fit.r2 >= fit_r2_min and fit.w_prime >= d_prime_lo and fit.w_prime <= d_prime_hi)
		else fit_usable(fit)

	# the threshold line's height in the curve's own units, 0 when unusable
	fit_line : Str, Db.Fit -> F32
	fit_line = |curve, fit|
		if (!fit_usable_for(curve, fit)) 0.0
		else if (is_pace(curve)) (fit.cp * 1000.0)
		else fit.cp

	# the threshold line's label
	fit_tag : Str, [Metric, Imperial], Db.Fit -> Str
	fit_tag = |curve, units, fit|
		match Bus.curve_key(curve) {
			Power(_) => "CP ${Db.fmt_f(fit.cp)}W"
			Pace(_) => "CS ${val_text(curve, units, F32.round_to_i64_try(fit.cp * 1000.0) ?? 0)}"
		}

	fit_caption_for : Str, [Metric, Imperial], Db.Fit, I64 -> Str
	fit_caption_for = |curve, units, fit, best20_age|
		if (!is_pace(curve)) fit_caption(fit, best20_age)
		else if (!fit.ok) "CS fit unavailable - the engine did not answer"
		else if (fit_usable_for(curve, fit)) "CS ${val_text(curve, units, F32.round_to_i64_try(fit.cp * 1000.0) ?? 0)} - D' ${Db.fmt_i(fit.w_prime)} m - fit r2 ${r2_str(fit.r2)} from ${Db.fmt_i(fit.points)} bests"
		else {
			why = if (fit.points < 2.0) "no CS fit (fewer than two bests in this window)" else "no usable CS fit (r2 ${r2_str(fit.r2)}, D' ${Db.fmt_i(fit.w_prime)} m)"
			when = if (best20_age < 0) "no 20-min best in this window" else if (best20_age == 0) "20-min best set today" else if (best20_age == 1) "20-min best set 1 day ago" else "20-min best set ${I64.to_str(best20_age)} days ago"
			"${why} - ${when}; an all-out 20 minutes would anchor it"
		}

	# ── planned targets as marks on the curve. A power target belongs on the
	# ride curve, where every power prescription stride writes is ridden; a
	# pace target belongs on every pace curve its unit fits (Sports
	# pace_unit_families), at the speed its pace names and the duration one
	# rep takes at that speed.
	Mark : { day : Str, typ : Str, dur_s : I64, val : I64, val_txt : Str, rep_txt : Str }

	marks_for : Str, List(Db.Target), List(Db.PaceTarget) -> List(Mark)
	marks_for = |curve, power, pace|
		match Bus.curve_key(curve) {
			Power(fam) =>
				if (fam != "Ride") []
				else List.map(power, |t| { day: t.day, typ: t.typ, dur_s: t.dur_s, val: t.watts, val_txt: "${I64.to_str(t.watts)}W", rep_txt: "${I64.to_str(t.reps)}x${Fmt.mmss(t.dur_s)}" })
			Pace(sp) =>
				List.keep_oks(
					pace,
					|t|
						if (!(List.contains(Sports.pace_unit_families(t.unit), Sports.canonical(sp)))) Err(OtherSport)
						else {
							mps = Db.pace_unit_m(t.unit) / I64.to_f64(t.pace_s)
							dur = if (t.dist_m > 0) (F64.round_to_i64_try(I64.to_f64(t.dist_m) / mps) ?? 0) else t.dur_s
							rep = if (t.dist_m > 0) "${I64.to_str(t.dist_m)}m" else Fmt.mmss(t.dur_s)
							Ok({ day: t.day, typ: t.typ, dur_s: dur, val: F64.round_to_i64_try(mps * 1000.0) ?? 0, val_txt: "${Fmt.mmss(t.pace_s)}${t.unit}", rep_txt: "${I64.to_str(t.reps)}x${rep}" })
						},
				)
		}

	# ── the chips. The range chips (30d 60d 90d) keep the form board's spot
	# from chip0 = win_w - 420. Right of them sit the mode chips, power and
	# pace, when the athlete has curves of both kinds; left of them,
	# right-aligned, the curve chips of the mode on screen, most-used first,
	# as many as fit between the title and the range chips, the one on
	# screen always among them.
	Chip : { key : Str, label : Str, x : F32, on : Bool }

	chip_w : F32
	chip_w = 52.0

	chip_pitch : F32
	chip_pitch = 58.0

	title_reserve : F32
	title_reserve = 340.0

	curve_chips : F32, Db.CurveKeys, Str -> List(Chip)
	curve_chips = |win_w, keys, cur| {
		chip0 = win_w - 420.0
		pace_on = is_pace(cur)
		modes =
			if (List.is_empty(keys.power) or List.is_empty(keys.pace)) []
			else [
				{ key: if (pace_on) ((List.first(keys.power)).ok_or(cur)) else cur, label: "power", x: chip0 + 176.0, on: !pace_on },
				{ key: if (pace_on) cur else (List.first(keys.pace)).ok_or(cur), label: "pace", x: chip0 + 234.0, on: pace_on },
			]
		mode_keys = if (pace_on) keys.pace else keys.power
		room = chip0 - 14.0 + (chip_pitch - chip_w) - title_reserve
		n_fit = if (room <= 0.0) 0 else (F32.round_to_u64_try(F32.div_floor_by(room, chip_pitch)) ?? 0)
		first_n = List.take_first(mode_keys, n_fit)
		shown = if (n_fit == 0 or List.contains(first_n, cur) or !(List.contains(mode_keys, cur))) first_n else List.append(List.drop_last(first_n, 1), cur)
		n = List.len(shown)
		sports = List.map_with_index(shown, |k, i| { key: k, label: chip_label(k), x: chip0 - 14.0 - U64.to_f32(n - i) * chip_pitch + (chip_pitch - chip_w), on: k == cur })
		List.concat(sports, modes)
	}

	# the key under x on the chip row, or '' between and beside the chips
	chip_at : List(Chip), F32 -> Str
	chip_at = |chips, x|
		match List.find_first(chips, |c| x >= c.x and x <= c.x + chip_w) {
			Ok(c) => c.key
			Err(_) => ""
		}

	# the window-over-window change, said in watts with its sign - the number
	# this view argues with. Empty when either side is absent (a comparison
	# with nothing is not a delta) and when equal (the dots already overlap,
	# and a "+0w" would claim a precision the rounding does not carry).
	delta_label : I64, I64 -> Str
	delta_label = |now, prev|
		if (now <= 0 or prev <= 0) ""
		else if (now > prev) "+${I64.to_str(now - prev)}w"
		else if (now < prev) "-${I64.to_str(prev - now)}w"
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
# a fit is usable at the r2 floor with a W' inside the band, and not a hair
# below either edge; an unanswered fit never is
expect Curve.fit_usable({ cp: 250.0, w_prime: 15000.0, r2: 0.9, points: 3.0, ok: Bool.True })
expect !Curve.fit_usable({ cp: 250.0, w_prime: 15000.0, r2: 0.89, points: 3.0, ok: Bool.True })
expect !Curve.fit_usable({ cp: 253.0, w_prime: 2980.0, r2: 0.95, points: 3.0, ok: Bool.True })
expect !Curve.fit_usable({ cp: 250.0, w_prime: 40001.0, r2: 0.95, points: 3.0, ok: Bool.True })
expect Curve.fit_usable({ cp: 250.0, w_prime: 5000.0, r2: 0.95, points: 3.0, ok: Bool.True })
expect !Curve.fit_usable({ cp: 250.0, w_prime: 15000.0, r2: 0.95, points: 3.0, ok: Bool.False })
# a weak fit's footer says what is wrong and when the 20-minute best was set
expect Curve.fit_caption({ cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }, 9) == "no usable CP fit (r2 0.84, W' 3.0 kJ) - 20-min best set 9 days ago; an all-out 20 minutes would anchor it"
expect Curve.fit_caption({ cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }, -1) == "no usable CP fit (r2 0.84, W' 3.0 kJ) - no 20-min best in this window; an all-out 20 minutes would anchor it"
expect Curve.fit_caption({ cp: 250.0, w_prime: 15000.0, r2: 0.95, points: 3.0, ok: Bool.True }, 9) == "CP 250.0 W - W' 15.0 kJ - fit r2 0.95 from 3 bests"
# a rep duration between rungs sits between them, linearly in seconds;
# outside the ladder it clamps to the ends
expect Curve.rung_pos([5, 15, 30, 60, 300, 600, 1200, 3600], 900) == 5.5
expect Curve.rung_pos([5, 15, 30, 60, 300, 600, 1200, 3600], 1200) == 6.0
expect Curve.rung_pos([5, 15, 30, 60, 300, 600, 1200, 3600], 2) == 0.0
expect Curve.rung_pos([5, 15, 30, 60, 300, 600, 1200, 3600], 7200) == 7.0
# the window best between two rungs is read off the line joining them, and
# is absent when either rung has no value
expect (Curve.best_at([{ secs: 600, w: 260 }, { secs: 1200, w: 254 }], 900) - 257.0).abs() < 0.001
expect Curve.best_at([{ secs: 600, w: 0 }, { secs: 1200, w: 254 }], 900) == 0.0
expect Curve.best_at([{ secs: 600, w: 260 }, { secs: 1200, w: 254 }], 1200) == 254.0
# a power target reads in watts on the ride curve and nowhere else; its
# label carries its share of the window's best at the rep duration
expect {
	ms = Curve.marks_for("Ride", [{ day: "2026-11-05", typ: "threshold", reps: 2, dur_s: 900, watts: 225 }], [])
	match ms {
		[m] => Curve.target_label(m, 257.0) == "11-05 225W 88%" and Curve.target_label(m, 0.0) == "11-05 225W" and Curve.target_tip(m, 257.0) == "2026-11-05 threshold: 2x15:00 @ 225W - 88% of this window's best at that duration"
		_ => Bool.False
	}
}
expect Curve.marks_for("Rowing", [{ day: "2026-11-05", typ: "threshold", reps: 2, dur_s: 900, watts: 225 }], []) == []
# a pace target lands on every pace curve its unit fits, at the speed its
# pace names; a distance rep takes the time that distance needs at that
# pace, and a unit for another sport keeps it off the curve
expect {
	run = { day: "2026-11-10", typ: "threshold", reps: 5, dur_s: 240, dist_m: 0, pace_s: 402, unit: "/mi" }
	swim = { day: "2026-11-11", typ: "threshold", reps: 10, dur_s: 0, dist_m: 100, pace_s: 100, unit: "/100m" }
	match Curve.marks_for("pace:TrailRun", [], [run, swim]) {
		[m] => m.val == 4003 and m.dur_s == 240 and m.val_txt == "6:42/mi" and m.rep_txt == "5x4:00" and Curve.target_label(m, 4210.0) == "11-10 6:42/mi 95%"
		_ => Bool.False
	}
		and (
			match Curve.marks_for("pace:Swim", [], [run, swim]) {
				[m] => m.val == 1000 and m.dur_s == 100 and m.rep_txt == "10x100m"
				_ => Bool.False
			}
		)
		and Curve.marks_for("Ride", [], [run, swim]) == []
}
expect Curve.r2_str(0.84) == "0.84" and Curve.r2_str(0.9) == "0.90" and Curve.r2_str(0.05) == "0.05" and Curve.r2_str(1.0) == "1.00" and Curve.r2_str(0.899) == "0.89" and Curve.r2_str(0.8999) == "0.89" and Curve.r2_str(-0.253) == "-0.25"
# a rung within 5% of the next longer one was not pushed: on the live 60-day
# ladder the short rungs crowd the 20-minute best, while the 20-minute best
# stands 5% over the hour; the hour has nothing longer to beat, and an
# absent rung is neither
expect Curve.flat_ratio == 1.05
expect Curve.unpushed([290, 272, 265, 262, 255, 254, 248, 236]) == [Bool.False, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False, Bool.False]
expect Curve.unpushed([400, 0, 300]) == [Bool.False, Bool.False, Bool.False]
expect Curve.unpushed_caption(["5s", "15s", "30s"], [Bool.False, Bool.True, Bool.True], 30) == "no all-out effort in 30 days at 15s, 30s"
expect Curve.unpushed_caption(["5s", "15s"], [Bool.False, Bool.False], 30) == ""
# a best set more than half the window ago is stale; exactly half is not
expect !Curve.stale_best(15, 30) and Curve.stale_best(16, 30) and !Curve.stale_best(-1, 30)
# the family chips sit right of the range chips; a family with no power
# keeps its chip lit and names the way back
# the curve chips: the curves of the mode on screen right-aligned against
# the range chips, most-used first, as many as fit beside the title, the
# one on screen always among them and lit; the power and pace pair right
# of the range chips only when the athlete has both kinds
expect {
	keys = { power: ["Ride", "Rowing", "Run"], pace: ["pace:Rowing", "pace:Run", "pace:Swim", "pace:TrailRun", "pace:Walk"] }
	wide = Curve.curve_chips(1400.0, keys, "Ride")
	narrow = Curve.curve_chips(980.0, keys, "pace:TrailRun")
	labels = |cs| List.map(cs, |c| c.label)
	labels(wide) == ["bike", "row", "run", "power", "pace"]
		and List.map(List.keep_if(wide, |c| c.on), |c| c.label) == ["bike", "power"]
		and labels(narrow) == ["row", "run", "trail", "power", "pace"]
		and List.map(List.keep_if(narrow, |c| c.on), |c| c.key) == ["pace:TrailRun", "pace:TrailRun"]
		and List.all(narrow, |c| c.x >= Curve.title_reserve)
		and Curve.chip_at(wide, 1400.0 - 420.0 + 234.0 + 10.0) == "pace:Rowing"
		and Curve.chip_at(wide, 1400.0 - 420.0 + 176.0 + 10.0) == "Ride"
		and Curve.chip_at(wide, 1400.0 - 420.0 - 2.0) == ""
}
# one kind of curve on record: no power and pace pair
expect List.map(Curve.curve_chips(1400.0, { power: [], pace: ["pace:Swim", "pace:OpenWaterSwim"] }, "pace:Swim"), |c| c.label) == ["swim", "open"]
# the chips' last right edge sits 14 px left of the first range chip
expect {
	cs = Curve.curve_chips(1400.0, { power: ["Ride", "Rowing"], pace: [] }, "Ride")
	match List.last(cs) {
		Ok(c) => c.x + Curve.chip_w == 1400.0 - 420.0 - 14.0
		Err(_) => Bool.False
	}
}
expect Curve.empty_note("Rowing") == "no row power on record yet" and Curve.empty_note("Ride") == "no ride power on record yet" and Curve.empty_note("pace:Swim") == "no swim pace on record yet"
# speed reads as pace in the sport's own unit, the foot sports in the
# athlete's units; the delta is the change in pace, negative when faster
expect Curve.val_text("pace:Run", Metric, 4000) == "4:10/km" and Curve.val_text("pace:Run", Imperial, 4000) == "6:42/mi" and Curve.val_text("pace:Swim", Imperial, 1000) == "1:40/100m" and Curve.val_text("pace:VirtualRow", Metric, 4000) == "2:05/500m"
expect Curve.val_text("Ride", Metric, 1234) == "1,234 w" and Curve.axis_text("Ride", Metric, 300) == "300" and Curve.axis_text("pace:Run", Metric, 4000) == "4:10"
expect Curve.delta_for("pace:Run", Metric, 4000, 3846) == "-10s" and Curve.delta_for("pace:Run", Metric, 3846, 4000) == "+10s" and Curve.delta_for("pace:Run", Metric, 4000, 4000) == "" and Curve.delta_for("Ride", Metric, 354, 340) == "+14w"
# a power axis rises from zero and rules every 100 W; a pace axis spans its
# own values and rules round paces, at most six of them
expect {
	s = Curve.axis_span("Ride", [500, 0, 300], [225], 0.0)
	s.lo.abs() < 0.001 and (s.hi - 540.0).abs() < 0.01 and List.map(Curve.grid_vals("Ride", Metric, 0.0, 540.0), |v| Curve.axis_text("Ride", Metric, F32.round_to_i64_try(v) ?? 0)) == ["100", "200", "300", "400", "500"]
}
expect {
	s = Curve.axis_span("pace:Run", [4600, 4200, 4000, 0], [3850], 0.0)
	(s.lo - 3465.0).abs() < 0.5 and (s.hi - 4690.8).abs() < 0.5
}
expect List.map(Curve.grid_vals("pace:Run", Metric, 3465.0, 4689.0), |v| Curve.axis_text("pace:Run", Metric, F32.round_to_i64_try(v) ?? 0)) == ["3:45", "4:00", "4:15", "4:30", "4:45"]
expect List.map(Curve.grid_vals("pace:Swim", Metric, 1200.0, 1500.0), |v| Curve.axis_text("pace:Swim", Metric, F32.round_to_i64_try(v) ?? 0)) == ["1:10", "1:15", "1:20"]
expect Curve.title_text("Ride", 90) == "power - this 90d vs the 90d before it" and Curve.title_text("Rowing", 30) == "row power - this 30d vs the 30d before it" and Curve.title_text("pace:TrailRun", 60) == "trail run pace - this 60d vs the 60d before it"
expect Curve.chip_label("Ride") == "bike" and Curve.chip_label("Run") == "run" and Curve.chip_label("WeightTraining") == "strength" and Curve.chip_label("Kayaking") == "kayaking" and Curve.chip_label("pace:OpenWaterSwim") == "open"
# a CS fit is usable at the r2 floor with D' inside its band, and its line
# sits at the critical speed in millimetres per second
expect Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 200.0, r2: 0.95, points: 3.0, ok: Bool.True }) and !Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 2000.0, r2: 0.95, points: 3.0, ok: Bool.True }) and !Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 200.0, r2: 0.85, points: 3.0, ok: Bool.True })
expect (Curve.fit_line("pace:Run", { cp: 4.0, w_prime: 200.0, r2: 0.95, points: 3.0, ok: Bool.True }) - 4000.0).abs() < 0.01 and Curve.fit_line("pace:Run", { cp: 4.0, w_prime: 2000.0, r2: 0.95, points: 3.0, ok: Bool.True }) == 0.0
expect Curve.fit_caption_for("pace:Run", Metric, { cp: 4.0, w_prime: 200.0, r2: 0.95, points: 3.0, ok: Bool.True }, 3) == "CS 4:10/km - D' 200 m - fit r2 0.95 from 3 bests"
expect Curve.fit_caption_for("pace:Swim", Metric, { cp: 0.0, w_prime: 0.0, r2: 0.0, points: 1.0, ok: Bool.True }, -1) == "no CS fit (fewer than two bests in this window) - no 20-min best in this window; an all-out 20 minutes would anchor it"
expect Curve.fit_tag("pace:Run", Metric, { cp: 4.0, w_prime: 200.0, r2: 0.95, points: 3.0, ok: Bool.True }) == "CS 4:10/km" and Curve.fit_tag("Ride", Metric, { cp: 247.3, w_prime: 9000.0, r2: 0.95, points: 3.0, ok: Bool.True }) == "CP 247.3W"
# two targets at the same duration a few watts apart share one ring; targets
# at different durations, or the same duration far apart in watts, keep their
# own; clusters come out left to right with input indices
expect Curve.cluster_marks([{ x: 500.0, y: 300.0 }, { x: 500.0, y: 292.0 }], 14.0) == [[1, 0]]
expect Curve.cluster_marks([{ x: 500.0, y: 300.0 }, { x: 400.0, y: 300.0 }], 14.0) == [[1], [0]]
expect Curve.cluster_marks([{ x: 500.0, y: 300.0 }, { x: 500.0, y: 260.0 }], 14.0) == [[1], [0]]
expect Curve.cluster_marks([{ x: 500.0, y: 300.0 }, { x: 500.0, y: 286.0 }], 14.0) == [[1, 0]] and Curve.cluster_marks([{ x: 500.0, y: 300.0 }, { x: 500.0, y: 285.0 }], 14.0) == [[1], [0]]
expect Curve.cluster_marks([], 14.0) == []
# a ring within a label's width of the one before it starts below that ring's
# labels; a far one starts at the top row
expect Curve.label_rows([{ x: 100.0, lines: 2 }, { x: 150.0, lines: 1 }, { x: 400.0, lines: 1 }], 90.0) == [0.0, 2.0, 0.0]
# a box crosses a segment that passes through its rows over its columns, and
# not one that passes above, below or beside it
expect {
	s = { x0: 0.0, y0: 100.0, x1: 100.0, y1: 200.0 }
	Curve.box_crosses(40.0, 20.0, 145.0, 10.0, [s]) and !Curve.box_crosses(40.0, 20.0, 170.0, 10.0, [s]) and !Curve.box_crosses(40.0, 20.0, 120.0, 10.0, [s]) and !Curve.box_crosses(120.0, 20.0, 150.0, 10.0, [s]) and !Curve.box_crosses(40.0, 20.0, 145.0, 10.0, [])
}
# a delta keeps its spot right of the rung between the dots when that is clear;
# a line through it sends it left, and lines on both sides send it above the
# upper dot
expect {
	d = { x: 100.0, w: 20.0, h: 10.0, mid: 150.0, upper: 145.0, lower: 165.0, hi: 400.0 }
	through_right = { x0: 100.0, y0: 155.0, x1: 200.0, y1: 155.0 }
	through_left = { x0: 0.0, y0: 155.0, x1: 100.0, y1: 155.0 }
	Curve.delta_spot(d, []) == { left: 110.0, top: 150.0 }
		and Curve.delta_spot(d, [through_right]) == { left: 70.0, top: 150.0 }
		and Curve.delta_spot(d, [through_right, through_left]) == { left: 110.0, top: 129.0 }
}
# a delta that cannot fit right of the rung never tries the right side, and
# with every spot crossed it falls back between the dots
expect {
	d = { x: 390.0, w: 20.0, h: 10.0, mid: 150.0, upper: 145.0, lower: 165.0, hi: 400.0 }
	wall = { x0: 300.0, y0: 0.0, x1: 400.0, y1: 400.0 }
	Curve.delta_spot(d, []) == { left: 360.0, top: 150.0 } and Curve.delta_spot({ ..d, x: 100.0, hi: 400.0 }, [{ x0: 0.0, y0: 0.0, x1: 200.0, y1: 400.0 }, { x0: 0.0, y0: 400.0, x1: 200.0, y1: 0.0 }, { x0: 0.0, y0: 130.0, x1: 200.0, y1: 130.0 }, { x0: 0.0, y0: 175.0, x1: 200.0, y1: 175.0 }]) == { left: 110.0, top: 150.0 } and !Curve.box_crosses(0.0, 1.0, 0.0, 1.0, [wall])
}
# the caption row clears the chips and ends before the plot: an 11 pt line
# under chip_bottom and above Theme.pad_t, so the loading note and caption
# never overprint a chip at any width
expect Curve.caption_top >= Curve.chip_bottom + 4.0 and Curve.caption_top + 13.0 <= Theme.pad_t
expect Curve.chip_bottom - Curve.chip_top == 22.0
# a label beside a gently falling line keeps its offset; beside a steep one
# it moves clear of where the line ends up under the label's far edge
expect (Curve.intro_below(100.0, 0.02, 100.0) - 106.0).abs() < 0.001 and (Curve.intro_below(100.0, 0.24, 100.0) - 126.0).abs() < 0.001
expect (Curve.intro_above(100.0, 0.24, 100.0) - 92.0).abs() < 0.001 and (Curve.intro_above(100.0, -0.2, 100.0) - 67.0).abs() < 0.001
# a rule through an introduction starts past its end; one clear of every
# introduction starts at the plot's edge
expect {
	spans = [{ top: 100.0, bot: 111.0, right: 200.0 }, { top: 130.0, bot: 141.0, right: 250.0 }]
	(Curve.rule_start(105.0, 64.0, spans) - 206.0).abs() < 0.001 and (Curve.rule_start(120.0, 64.0, spans) - 64.0).abs() < 0.001 and (Curve.rule_start(142.5, 64.0, spans) - 256.0).abs() < 0.001
}
