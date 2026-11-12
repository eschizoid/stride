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
	# The window's curve against the same-length window before it. Four tiles
	# under the chips carry the headline numbers. The plot draws this window
	# as the solid accent line, the previous window dashed grey and the
	# all-time envelope thin and faint, over faint zone bands on a power
	# curve, with a legend naming each line. The signed number at a rung is
	# its change against the previous window. A rung whose window best IS the
	# record collapses to one teal dot, and a record set this week rings gold.
	# Hovering a rung or a planned ring opens a card beside it.
	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		win_w = model.win.w
		curve = model.curve_family
		units = model.units
		# the planned targets this curve carries (marks_for says which)
		plan_marks = marks_for(curve, (List.first(model.curve_keys.power)).ok_or(""), model.plan_targets, model.pace_targets)
		win_h = model.win.h
		# folded short rungs give up their columns to a narrow gutter at the
		# left, and the remaining rungs spread over the rest of the plot
		lay = layout(model)
		pad_l = lay.left
		pad_r = Theme.pad_r
		pad_t = plot_top
		pad_b = Theme.pad_b
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		ctl_c = Theme.ctl_c
		tsb_c = Theme.tsb_c
		model.curve_title.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		# a chip click re-fetches the curve in the background; while that is in
		# flight a note at the caption row's right says so, so a click that
		# takes a beat reads as working. The old curve stays on screen until the
		# fresh one lands, and the unpushed caption, which describes it, yields
		# the slot.
		if model.reloading {
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
			List.concat(chips_for(win_w, model.curve_keys, curve, model.curve_days), short_chips(win_w, model.curve_keys, curve, layout(model).foldable, model.show_short)),
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
			# the headline tiles: what the chart says, before the chart is read
			List.for_each!(
				List.map_with_index(head_tiles(curve, units, model.prs, model.curve, model.curve_info), |t, i| { t, i }),
				|x| {
					tx0 = tile_x(win_w, x.i)
					frame.rounded_rectangle!({ x: tx0, y: tile_top, width: tile_w(win_w), height: tile_h, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
					Text.from(x.t.value, model.font).size(16).draw!(frame, { pos: { x: tx0 + 10.0, y: tile_top + 6.0 }, color: if (x.t.good) tsb_c else Color.white, align: (Top, Left) })
					Text.from(x.t.caption, model.font).size(10).draw!(frame, { pos: { x: tx0 + 10.0, y: tile_top + 28.0 }, color: ink_faint, align: (Top, Left) })
				},
			)
			pw = win_w - pad_l - pad_r
			ph = win_h - pad_t - pad_b
			# the record ladder is the master axis; the window's value joins by
			# duration. Index spacing, not time: a linear axis piles the short
			# rungs onto the left edge.
			joined = window_w
			# each window judged on its own, over the whole ladder: a rung within
			# flat_ratio of the next longer one was not pushed, and its dot and
			# delta go quiet
			now_flags = unpushed(List.map(model.prs, |pr| joined(model.curve, pr.secs)))
			prev_flags = unpushed(List.map(model.prs, |pr| joined(model.curve_prev, pr.secs)))
			full = List.map_with_index(
				model.prs,
				|pr, i| {
					now_w = joined(model.curve, pr.secs)
					prev_w = joined(model.curve_prev, pr.secs)
					now_unp = List.get(now_flags, i) ?? Bool.False
					prev_unp = List.get(prev_flags, i) ?? Bool.False
					src = List.find_first(model.curve, |cp| cp.dur_s == pr.secs)
					src_name = match src {
						Ok(sp) => sp.name
						Err(_) => ""
					}
					src_day = match src {
						Ok(sp) => sp.day
						Err(_) => ""
					}
					prev_day = match List.find_first(model.curve_prev, |cp| cp.dur_s == pr.secs) {
						Ok(pp) => pp.day
						Err(_) => ""
					}
					stale = match src {
						Ok(sp) => stale_best(sp.ago, model.curve_days)
						Err(_) => Bool.False
					}
					{ pr, now_w, prev_w, i, now_unp, prev_unp, src_name, src_day, prev_day, stale }
				},
			)
			# the rungs on screen, indexed by their column
			rungs = List.map_with_index(List.keep_if(full, |r| !(lay.folded) or r.pr.secs >= short_secs), |r, i| { ..r, i })
			span = axis_span(curve, List.join(List.map(rungs, |r| [r.pr.w, r.now_w, r.prev_w])), List.map(plan_marks, |t| t.val), model.fit_cp)
			w_lo = span.lo
			w_hi = span.hi
			nlast = List.len(rungs) - 1
			cx = |i| if (nlast == 0) (pad_l + pw / 2.0) else pad_l + pw * U64.to_f32(i) / U64.to_f32(nlast)
			cy = |w| pad_t + ph * (1.0 - (w - w_lo) / (w_hi - w_lo))
			# the zone bands behind everything: alternate zones shaded, each named
			# right-aligned to the window's edge where its visible part is tall
			# enough, clear of the threshold line's label and of the rung labels'
			# row
			cp_label_y = if (model.fit_cp > w_lo and model.fit_cp < w_hi) (cy(model.fit_cp)) else -100.0
			List.for_each!(
				zone_bands(curve, model.curve_info.thr, w_lo, w_hi),
				|b| {
					y_top = cy(b.hi)
					y_bot = cy(b.lo)
					if b.shade {
						frame.rectangle!({ x: pad_l, y: y_top, width: pw, height: y_bot - y_top, style: Draw.filled(Color.with_alpha(Color.white, 7)) })
					}
					mid = (y_top + y_bot) / 2.0
					if y_bot - y_top >= zone_label_min_h and F32.abs(mid - cp_label_y) > 12.0 and mid < pad_t + ph - 26.0 {
						Text.from(b.name, model.font).size(9).draw!(frame, { pos: { x: win_w - 20.0, y: mid - 5.0 }, color: Color.with_alpha(ink_faint, 160), align: (Top, Right) })
					}
				},
			)
			# the grid: a faint rule and label at each grid_vals value, which
			# come from the axis span itself, so any scale gets its rules
			List.for_each!(
				# a rule in the band the rung labels sit in, or hard under the plot's
				# top edge, would run through their text
				List.keep_if(grid_vals(curve, units, w_lo, w_hi), |gw| cy(gw) > pad_t + 8.0 and cy(gw) < pad_t + ph - 26.0),
				|gw| {
					frame.line!({ start: { x: Theme.pad_l, y: cy(gw) }, end: { x: win_w - pad_r, y: cy(gw) }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 36), 1) })
					Text.from(
						match F32.round_to_i64_try(gw) {
							Ok(gi) => axis_text(curve, units, gi)
							Err(_) => ""
						},
						model.font,
					).size(10).draw!(frame, { pos: { x: Theme.pad_l - 8.0, y: cy(gw) - 6.0 }, color: ink_faint, align: (Top, Right) })
				},
			)
			# the threshold line, dashed: CP from the window's fit, which the blue
			# curve should flatten toward (a fit far from the long rungs is visibly
			# wrong), or a marked test's threshold when the fit is unusable. The
			# loader zeroes fit_cp when neither exists, and the footer says why
			if model.fit_cp > w_lo and model.fit_cp < w_hi {
				cpy = cy(model.fit_cp)
				dashed_line!(frame, { x: pad_l, y: cpy }, { x: pad_l + pw, y: cpy }, Color.with_alpha(tsb_c, 120))
				model.cp_lbl.draw!(frame, { pos: { x: pad_l + pw + 8.0, y: cpy }, color: tsb_c, align: (Middle, Left) })
			}
			# three envelopes back to front: the record book a thin faint line,
			# the previous window dashed grey, this window the solid accent.
			# Envelope segments run only between rungs that HAVE values - a 0
			# rung must not drag a line to the floor.
			pair_each! = |sel, draw_seg!|
				List.for_each!(
					rungs,
					|r|
						match List.get(rungs, r.i + 1) {
							Ok(nxt) => if (sel(r) > 0 and sel(nxt) > 0) (draw_seg!({ x: cx(r.i), y: cy(I64.to_f32(sel(r))) }, { x: cx(nxt.i), y: cy(I64.to_f32(sel(nxt))) })) else {}
							Err(_) => {}
						},
				)
			pair_each!(|r| r.pr.w, |a, b| frame.line!({ start: a, end: b, stroke: Draw.stroke(Color.with_alpha(ink_muted, best_line_alpha), 1) }))
			pair_each!(|r| r.prev_w, |a, b| dashed_line!(frame, a, b, Color.with_alpha(ink_muted, 150)))
			pair_each!(|r| r.now_w, |a, b| frame.line!({ start: a, end: b, stroke: Draw.stroke(Color.with_alpha(ctl_c, 200), 2) }))
			# planned targets on the curve: a gold ring at the rep duration and the
			# target watts, labelled with the day and the share of this window's
			# best at that duration, so a prescription reads against what the
			# athlete has done. Targets whose rings would overlap share one ring
			# with their labels stacked under it, and a ring whose labels would
			# run into the previous ring's starts below them.
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
			List.for_each!(
				ring_rows,
				|x| {
					dashed_ring!(frame, x.g.x, x.g.y, 5.5)
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
						# the window best IS the record: one teal dot, and the delta
						# still prints, since a record rung's change is the best
						# news on the chart. Teal is the house "good" accent; the dot
						# and the text tell themselves apart by shape.
						frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 5.0, style: Draw.filled(tsb_c) })
						pr_half = model.font.measure({ text: "pr", size: 10.0, spacing: Text.default_spacing }).width / 2.0
						Text.from("pr", model.font).size(10).draw!(frame, { pos: { x: label_center_within(cx(r.i), pr_half, pad_l, pad_l + pw - label_inset), y: rec_y - 20.0 }, color: tsb_c, align: (Top, Center) })
						dpr_txt = if (r.now_unp or r.prev_unp) "" else delta_for(curve, units, r.now_w, r.prev_w)
						if dpr_txt != "" {
							dpr_col = if (r.now_w > r.prev_w) tsb_c else Theme.alarm_c
							dpr_w = model.font.measure({ text: dpr_txt, size: 10.0, spacing: Text.default_spacing }).width
							Text.from(dpr_txt, model.font).size(10).draw!(frame, { pos: { x: delta_left_x(cx(r.i), dpr_w, pad_l + pw - label_inset), y: (cy(I64.to_f32(r.prev_w)) + rec_y) / 2.0 - 6.0 }, color: dpr_col, align: (Top, Left) })
						}
					} else {
						frame.circle!({ center: { x: cx(r.i), y: rec_y }, radius: 2.5, style: Draw.filled(Color.with_alpha(ink_muted, 90)) })
						if r.prev_w > 0 and r.prev_w < r.pr.w {
							frame.circle!({ center: { x: cx(r.i), y: cy(I64.to_f32(r.prev_w)) }, radius: 3.5, style: Draw.filled(Color.with_alpha(ink_muted, if (r.prev_unp) (70) else 150)) })
						}
						if r.now_w > 0 {
							now_y = cy(I64.to_f32(r.now_w))
							frame.circle!({ center: { x: cx(r.i), y: now_y }, radius: 4.0, style: Draw.filled(if (r.now_unp) (Color.with_alpha(ink_muted, 170)) else if (r.stale) (Color.with_alpha(ctl_c, 110)) else ctl_c) })
							# the change against the PREVIOUS window, signed, at the first
							# spot clear of both lines - green-teal going up, alarm going down
							d_txt = if (r.now_unp or r.prev_unp) "" else delta_for(curve, units, r.now_w, r.prev_w)
							if d_txt != "" {
								d_col = if (r.now_w > r.prev_w) tsb_c else Theme.alarm_c
								d_w = model.font.measure({ text: d_txt, size: 10.0, spacing: Text.default_spacing }).width
								prev_y = cy(I64.to_f32(r.prev_w))
								spot = delta_spot({ x: cx(r.i), w: d_w, h: 10.0, mid: (prev_y + now_y) / 2.0 - 6.0, upper: F32.min(prev_y, now_y), lower: F32.max(prev_y, now_y), hi: pad_l + pw - label_inset }, segs)
								Text.from(d_txt, model.font).size(10).draw!(frame, { pos: { x: spot.left, y: spot.top }, color: d_col, align: (Top, Left) })
							}
						}
					}
					Text.from(r.pr.rung, model.font).size(12).draw!(frame, { pos: { x: cx(r.i), y: pad_t + ph - 18.0 }, color: ink_faint, align: (Top, Center) })
				},
			)
			if lay.folded {
				gx = Theme.pad_l + short_gutter / 2.0 - 14.0
				Text.from("short", model.font).size(11).draw!(frame, { pos: { x: gx, y: pad_t + ph - 18.0 }, color: ink_faint, align: (Top, Center) })
				Text.from("not pushed", model.font).size(9).draw!(frame, { pos: { x: gx, y: pad_t + ph - 4.0 }, color: Color.with_alpha(ink_faint, 150), align: (Top, Center) })
			}
			# the legend on the caption row's left: one swatch per line drawn
			legend = legend_items(List.any(rungs, |r| r.now_w > 0), List.any(rungs, |r| r.prev_w > 0), List.any(rungs, |r| r.pr.w > 0), !(List.is_empty(plan_marks)))
			legend_ws = List.map(legend, |it| legend_swatch_w + model.font.measure({ text: it.label, size: 11.0, spacing: Text.default_spacing }).width)
			legend_lefts = legend_xs(legend_ws, 36.0, legend_gap)
			List.for_each!(
				List.map2(legend, legend_lefts, |it, lx| { it, lx }),
				|e| {
					sy = caption_top + 6.0
					a = { x: e.lx, y: sy }
					b = { x: e.lx + 16.0, y: sy }
					match e.it.kind {
						Now => frame.line!({ start: a, end: b, stroke: Draw.stroke(Color.with_alpha(ctl_c, 200), 2) })
						Prev => dashed_line!(frame, a, b, Color.with_alpha(ink_muted, 150))
						Best => {
							frame.line!({ start: a, end: b, stroke: Draw.stroke(Color.with_alpha(ink_muted, best_line_alpha), 1) })
							frame.circle!({ center: { x: e.lx + 8.0, y: sy }, radius: 2.5, style: Draw.filled(Color.with_alpha(ink_muted, 90)) })
						}
						Planned => dashed_ring!(frame, e.lx + 8.0, sy, 4.5)
					}
					Text.from(e.it.label, model.font).size(11).draw!(frame, { pos: { x: e.lx + legend_swatch_w, y: caption_top }, color: ink_muted, align: (Top, Left) })
				},
			)
			legend_end = legend_right(legend_lefts, legend_ws)
			# the window's unpushed durations at the caption row's right, when it
			# clears the legend; the hover card says it per rung either way
			unp_txt = unpushed_caption(List.map(full, |r| r.pr.rung), List.map(full, |r| r.now_unp), model.curve_days)
			unp_w = model.font.measure({ text: unp_txt, size: 11.0, spacing: Text.default_spacing }).width
			if unp_txt != "" and !model.reloading and caption_fits(legend_end, win_w - 40.0 - unp_w) {
				Text.from(unp_txt, model.font).size(11).draw!(frame, { pos: { x: win_w - 40.0, y: caption_top }, color: ink_faint, align: (Top, Right) })
			}
			# the hover card, drawn last so it sits over everything: a planned
			# ring's sessions, or the hovered rung's three values and the session
			# that set this window's best
			bounds = { lo_x: pad_l, hi_x: pad_l + pw, top: pad_t, bot: pad_t + ph }
			card = match tgt_hover {
				Ok(g) => Ok({ lines: List.join(List.map(g.ts, |t| target_card(t, best_at(now_pts, t.dur_s)))), ax: g.x, ay: g.y })
				Err(_) =>
					match rung_at(model.mouse_x, model.mouse_y, win_w, win_h, List.len(rungs), pad_l) {
						Ok(ci) => match List.get(rungs, ci) {
							Ok(r) => Ok({ lines: rung_card(curve, units, { rung: r.pr.rung, rec_w: r.pr.w, rec_day: r.pr.day, now_w: r.now_w, now_day: r.src_day, name: r.src_name, prev_w: r.prev_w, prev_day: r.prev_day, unp: r.now_unp, stale: r.stale }), ax: cx(r.i), ay: if (r.now_w > 0) (cy(I64.to_f32(r.now_w))) else pad_t + ph / 2.0 })
							Err(_) => Err(NoCard)
						}
						Err(_) => Err(NoCard)
					}
			}
			match card {
				Ok(c) => {
					cw = 2.0 * card_pad + List.fold(c.lines, 0.0, |m, l| F32.max(m, model.font.measure({ text: l.text, size: 11.0, spacing: Text.default_spacing }).width))
					ch = 2.0 * card_pad + U64.to_f32(List.len(c.lines)) * card_line_h
					at = card_place(c.ax, c.ay, cw, ch, bounds)
					frame.rounded_rectangle!({ x: at.left, y: at.top, width: cw, height: ch, radius: 6.0, segments: 6, style: Draw.filled(Color.with_alpha(Theme.card, 245)) })
					List.for_each!(
						List.map_with_index(c.lines, |l, k| { l, k }),
						|e| Text.from(e.l.text, model.font).size(11).draw!(
							frame,
							{
								pos: { x: at.left + card_pad, y: at.top + card_pad + U64.to_f32(e.k) * card_line_h },
								color: (
									match e.l.tone {
										Title => Color.white
										Body => ink_muted
										Muted => ink_faint
									}
								),
								align: (Top, Left),
							},
						),
					)
				}
				Err(_) => {}
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
	# widest form, a pace label such as "planned MM-DD M:SS/100m NNN%"
	ring_label_w : F32
	ring_label_w = 170.0

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

	# a planned target's marker label: "planned", its day, its value, and its
	# share of the window's best at the rep duration (omitted when the window
	# has none). On a pace curve the share is of speed, so 95% is a target a
	# little slower than the window's best. The "planned" prefix and the
	# dashed ring keep a prescription from reading as a measured best.
	target_label : Mark, F32 -> Str
	target_label = |t, best| {
		mmdd = Str.from_utf8_lossy(List.drop_first(Str.to_utf8(t.day), 5))
		pct = if (best <= 0.0) "" else " ${Db.fmt_i(I64.to_f32(t.val) / best * 100.0)}%"
		"planned ${mmdd} ${t.val_txt}${pct}"
	}

	# a target ring drawn as dashes, the way a planned point differs from the
	# filled dots of measured bests: ring_dashes arcs around the centre, each
	# spanning half its share of the circle
	ring_dashes : U64
	ring_dashes = 10

	dashed_ring! : Draw.Frame, F32, F32, F32 => {}
	dashed_ring! = |frame, x, y, r| {
		step = 6.2831853 / U64.to_f32(ring_dashes)
		List.for_each!(
			List.map_with_index(List.repeat({}, ring_dashes), |_u, k| k),
			|k| {
				a0 = U64.to_f32(k) * step
				a1 = a0 + step / 2.0
				frame.line!({ start: { x: x + r * F32.cos(a0), y: y + r * F32.sin(a0) }, end: { x: x + r * F32.cos(a1), y: y + r * F32.sin(a1) }, stroke: Draw.stroke(Color.with_alpha(Theme.gold_c, 230), 2) })
			},
		)
	}

	# ── the band above the plot. The range and curve chips fill the top
	# right from chip_top to chip_bottom, the tiles sit under them from
	# tile_top, and the caption row at caption_top carries the legend on the
	# left and the unpushed caption or the loading note on the right, ending
	# before the plot starts at plot_top. Click and hover tests in main.roc
	# use the same 64..86 chip band.
	chip_top : F32
	chip_top = 64.0

	chip_bottom : F32
	chip_bottom = 86.0

	caption_top : F32
	caption_top = plot_top - 18.0

	loading_note : Str
	loading_note = "loading..."

	# ── the headline tiles: four numbers under the chips that say what the
	# chart says before it is read. The two longest rungs' window bests (a
	# best that is the record says so), the threshold the engine scores with,
	# and the window's CP or CS fit, or what would anchor one. Each tile is a
	# value line and a caption line; four share the row from the title's left
	# inset to the chips' right edge.
	tile_top : F32
	tile_top = chip_bottom + 6.0

	tile_h : F32
	tile_h = 44.0

	tile_gap : F32
	tile_gap = 12.0

	# the band the tiles take between the chip row and the plot
	tile_band : F32
	tile_band = 56.0

	plot_top : F32
	plot_top = Theme.pad_t + tile_band

	tile_w : F32 -> F32
	tile_w = |win_w| (win_w - 36.0 - 40.0 - 3.0 * tile_gap) / 4.0

	tile_x : F32, U64 -> F32
	tile_x = |win_w, i| 36.0 + U64.to_f32(i) * (tile_w(win_w) + tile_gap)

	Tile : { value : Str, caption : Str, good : Bool }

	# "2026-08-16" -> "08-16"
	short_day : Str -> Str
	short_day = |day| Str.from_utf8_lossy(List.drop_first(Str.to_utf8(day), 5))

	# how long ago the window's 20-minute best was set, for a caption
	age_text : I64 -> Str
	age_text = |age| if (age < 0) "no 20min best" else if (age == 0) "20min best today" else "20min best ${I64.to_str(age)}d ago"

	head_tiles : Str, [Metric, Imperial], List(Db.PrRung), List(Db.CurvePt), Db.CurveInfo -> List(Tile)
	head_tiles = |curve, units, prs, pts, info| {
		n = List.len(prs)
		best_tile = |back|
			match List.get(prs, n - back) {
				Ok(pr) => {
					w = window_w(pts, pr.secs)
					day = match List.find_first(pts, |c| c.dur_s == pr.secs) {
						Ok(c) => short_day(c.day)
						Err(_) => ""
					}
					if (w <= 0) ({ value: "-", caption: "${pr.rung} best: none this window", good: Bool.False })
					else if (w >= pr.w) ({ value: val_text(curve, units, w), caption: "${pr.rung} best ${day} - PR", good: Bool.True })
					else { value: val_text(curve, units, w), caption: "${pr.rung} best ${day} - PR ${val_text(curve, units, pr.w)}", good: Bool.False }
				}
				Err(_) => { value: "-", caption: "no best on record", good: Bool.False }
			}
		thr_name = if (is_pace(curve)) "threshold" else "FTP"
		thr_v = F32.round_to_i64_try(if (is_pace(curve)) (info.thr * 1000.0) else info.thr) ?? 0
		thr_tile =
			if (info.thr <= 0.0) ({ value: "-", caption: "no ${thr_name} on record", good: Bool.False })
			else { value: val_text(curve, units, thr_v), caption: if (info.test.value > 0.0) "${thr_name} from test ${short_day(info.test.date)}" else "${thr_name} derived", good: Bool.False }
		fit_name = if (is_pace(curve)) "CS" else "CP"
		prime = if (is_pace(curve)) "D' ${Db.fmt_i(info.fit.w_prime)} m" else "W' ${Db.fmt_f(info.fit.w_prime / 1000.0)} kJ"
		fit_tile =
			if (fit_usable_for(curve, info.fit)) ({ value: fit_tag(curve, units, info.fit), caption: "${prime} - fit r2 ${r2_str(info.fit.r2)}", good: Bool.True })
			else if (info.test.value > 0.0) ({ value: "${fit_name} from test", caption: "fit not reliable - test ${short_day(info.test.date)}", good: Bool.False })
			else { value: "test due", caption: "${fit_name} not reliable - ${age_text(info.best20_age)}", good: Bool.False }
		[best_tile(1), best_tile(2), thr_tile, fit_tile]
	}

	# ── the hover card: a rung's three values with their dates, the session
	# that set this window's best and its quality tags, or a planned ring's
	# sessions. It sits beside the point it describes, inside the plot.
	CardLine : { text : Str, tone : [Title, Body, Muted] }

	card_pad : F32
	card_pad = 8.0

	card_line_h : F32
	card_line_h = 15.0

	RungFacts : { rung : Str, rec_w : I64, rec_day : Str, now_w : I64, now_day : Str, name : Str, prev_w : I64, prev_day : Str, unp : Bool, stale : Bool }

	rung_card : Str, [Metric, Imperial], RungFacts -> List(CardLine)
	rung_card = |curve, units, r|
		if (r.rec_w <= 0) [{ text: r.rung, tone: Title }, { text: "no effort on record", tone: Muted }]
		else {
			row = |label, w, day| if (w > 0) ({ text: "${label}  ${val_text(curve, units, w)}${if (day == "") "" else "  ${day}"}", tone: Body }) else { text: "${label}  no effort", tone: Muted }
			src = if (r.name != "" and r.now_w > 0) [{ text: r.name, tone: Muted }] else []
			tags = List.join([if (r.now_w > 0 and r.unp) ["not all-out"] else [], if (r.now_w > 0 and r.stale) ["stale"] else []])
			tag = if (List.is_empty(tags)) [] else [{ text: Str.join_with(tags, " - "), tone: Muted }]
			List.join([[{ text: r.rung, tone: Title }, row("this window", r.now_w, r.now_day), row("previous window", r.prev_w, r.prev_day), row("best ever", r.rec_w, r.rec_day)], src, tag])
		}

	target_card : Mark, F32 -> List(CardLine)
	target_card = |t, best| {
		share = if (best <= 0.0) "no window best at that duration" else "${Db.fmt_i(I64.to_f32(t.val) / best * 100.0)}% of this window's best there"
		[{ text: "planned ${t.day} ${t.typ}", tone: Title }, { text: "${t.rep_txt} @ ${t.val_txt}", tone: Body }, { text: share, tone: Muted }]
	}

	# where a card of w x h sits beside its anchor: 14 px right of it, or 14 px
	# left when the right side would leave the plot, and centred on it
	# vertically within the plot's top and bottom
	card_place : F32, F32, F32, F32, { lo_x : F32, hi_x : F32, top : F32, bot : F32 } -> { left : F32, top : F32 }
	card_place = |ax, ay, w, h, b| {
		right = ax + 14.0
		left = if (right + w <= b.hi_x) right else F32.max(b.lo_x, ax - 14.0 - w)
		{ left, top: F32.max(b.top, F32.min(ay - h / 2.0, b.bot - h)) }
	}

	# ── the legend: one swatch and name per line on the chart, left to right
	# on the caption row
	LegendItem : { kind : [Now, Prev, Best, Planned], label : Str }

	legend_items : Bool, Bool, Bool, Bool -> List(LegendItem)
	legend_items = |has_now, has_prev, has_best, has_plan|
		List.join([
			if (has_now) [{ kind: Now, label: "this window" }] else [],
			if (has_prev) [{ kind: Prev, label: "previous window" }] else [],
			if (has_best) [{ kind: Best, label: "best ever" }] else [],
			if (has_plan) [{ kind: Planned, label: "planned" }] else [],
		])

	legend_swatch_w : F32
	legend_swatch_w = 22.0

	legend_gap : F32
	legend_gap = 16.0

	# each item's left edge from the items' widths, starting at x0
	legend_xs : List(F32), F32, F32 -> List(F32)
	legend_xs = |ws, x0, gap| (List.fold(ws, { at: x0, xs: [] }, |acc, w| { at: acc.at + w + gap, xs: List.append(acc.xs, acc.at) })).xs

	legend_right : List(F32), List(F32) -> F32
	legend_right = |xs, ws|
		match (List.last(xs), List.last(ws)) {
			(Ok(x), Ok(w)) => x + w
			_ => 0.0
		}

	# the caption at the row's right shows only with a legend gap of air
	# between it and the legend
	caption_fits : F32, F32 -> Bool
	caption_fits = |legend_end, cap_left| legend_end + legend_gap <= cap_left

	# the record envelope's line alpha: a reference, quieter than either window
	best_line_alpha : U8
	best_line_alpha = 60

	# a line drawn as dashes of dash_len with dash_gap between them, the
	# previous window's style
	dash_len : F32
	dash_len = 6.0

	dash_gap : F32
	dash_gap = 4.0

	dashed_line! : Draw.Frame, { x : F32, y : F32 }, { x : F32, y : F32 }, Color.Rgba => {}
	dashed_line! = |frame, a, b, c| {
		dx = b.x - a.x
		dy = b.y - a.y
		len = F32.sqrt(dx * dx + dy * dy)
		if len > 0.0 {
			n = F32.round_to_u64_try(F32.div_floor_by(len, dash_len + dash_gap)) ?? 0
			List.for_each!(
				List.map_with_index(List.repeat({}, n + 1), |_u, k| k),
				|k| {
					t0 = U64.to_f32(k) * (dash_len + dash_gap) / len
					t1 = F32.min(1.0, t0 + dash_len / len)
					if (t0 < 1.0) (frame.line!({ start: { x: a.x + dx * t0, y: a.y + dy * t0 }, end: { x: a.x + dx * t1, y: a.y + dy * t1 }, stroke: Draw.stroke(c, 1.0) })) else {}
				},
			)
		}
	}

	# ── the zone bands behind a power curve: the athlete's power zones from
	# the threshold the engine scores with (core.Units), clipped to the axis.
	# Each band runs from the zone below's upper edge to its own, so the
	# bands tile the axis with no gaps; alternate zones are shaded. A pace
	# curve, or one with no threshold, draws none.
	ZoneBand : { lo : F32, hi : F32, name : Str, shade : Bool }

	# a band's name prints only where the visible band is at least this tall
	zone_label_min_h : F32
	zone_label_min_h = 14.0

	zone_bands : Str, F32, F32, F32 -> List(ZoneBand)
	zone_bands = |curve, thr, lo, hi|
		if (is_pace(curve) or thr <= 0.0) []
		else {
			zones = Units.power_zones(F32.to_f64(thr))
			List.keep_oks(
				List.map_with_index(zones, |z, i| { z, i }),
				|e| {
					zlo = if (e.i == 0) 0.0 else (
						match List.get(zones, e.i - 1) {
							Ok(p) => F64.to_f32_wrap(p.hi_w)
							Err(_) => 0.0
						}
					)
					zhi = if (e.z.hi_w <= 0.0) hi else F64.to_f32_wrap(e.z.hi_w)
					blo = F32.max(lo, zlo)
					bhi = F32.min(hi, zhi)
					if (bhi <= blo) Err(OffAxis) else Ok({ lo: blo, hi: bhi, name: e.z.name, shade: e.i % 2 == 1 })
				},
			)
		}

	# what the view says when the chosen curve has no data on record: the
	# choice is kept, and the note says which kind of effort is missing
	empty_note : Str -> Str
	empty_note = |curve|
		match Bus.curve_key(curve) {
			Pace(sp) => "no ${sport_name(sp)} pace on record yet"
			Power(fam) => if (fam == "Ride") "no ride power on record yet" else "no ${chip_label(curve)} power on record yet"
		}

	# ── short efforts. A rung under short_secs is a short effort, and it
	# counts as pushed only when it is not flat against the next longer rung
	# AND reaches short_record_share of the athlete's own record at that
	# duration: a 1-minute best stands well above a 5-minute one even inside
	# an ordinary class, so flatness alone would call it all-out. When the
	# window holds short rungs and none was pushed, their bests are spikes
	# inside longer workouts, so they fold into a gutter of short_gutter
	# pixels at the left and the remaining rungs take the width. One pushed
	# short rung shows them all, and the short chip shows them on demand. An
	# absent short rung (no effort) counts as not pushed.
	short_secs : I64
	short_secs = 300

	short_gutter : F32
	short_gutter = 76.0

	short_record_share : F32
	short_record_share = 0.9

	fold_short : List(I64), List(I64), List(I64) -> Bool
	fold_short = |secs, ws, records| {
		flags = unpushed(ws)
		pushed = |i| {
			w = List.get(ws, i) ?? 0
			rec = List.get(records, i) ?? 0
			w > 0 and !(List.get(flags, i) ?? Bool.False) and I64.to_f32(w) >= I64.to_f32(rec) * short_record_share
		}
		shorts = List.keep_oks(List.map_with_index(secs, |sec, i| { sec, i }), |x| if (x.sec < short_secs) Ok(x.i) else Err(Long))
		!(List.is_empty(shorts)) and !(List.any(shorts, pushed))
	}

	# the window's best at one rung, in whole units; 0 when it has none
	window_w : List(Db.CurvePt), I64 -> I64
	window_w = |pts, secs|
		List.fold(
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

	# the rungs on screen and where the plot starts, shared by the drawing and
	# every hover test so the two cannot disagree
	# the focus row's curve_short: 1 when the short rungs are shown, 0 when
	# they are folded away, -1 (NULL) when there is nothing to fold, so a coach
	# never reads "folded" off a curve that has no short rungs to hide
	focus_short : Bool, Bool -> I64
	focus_short = |foldable, show| if (!(foldable)) -1 else if (show) 1 else 0

	layout : Ui.Model -> { prs : List(Db.PrRung), left : F32, folded : Bool, foldable : Bool }
	layout = |model| {
		foldable = fold_short(List.map(model.prs, |pr| pr.secs), List.map(model.prs, |pr| window_w(model.curve, pr.secs)), List.map(model.prs, |pr| pr.w))
		folded = foldable and !(model.show_short)
		{ prs: if (folded) (List.keep_if(model.prs, |pr| pr.secs >= short_secs)) else model.prs, left: if (folded) (Theme.pad_l + short_gutter) else Theme.pad_l, folded, foldable }
	}

	# the short chip sits right of the range chips, past the power and pace
	# pair when that shows, and only while the window has short rungs to fold
	short_chip_key : Str
	short_chip_key = "short"

	short_chips : F32, Db.CurveKeys, Str, Bool, Bool -> List(Chip)
	short_chips = |win_w, keys, cur, foldable, show|
		if (!foldable) []
		else [{ key: short_chip_key, label: "short", x: win_w - 420.0 + (if (counterpart(keys, cur) == "") 176.0 else 292.0), on: show }]

	# the short rungs open folded whenever the fold rule says none was
	# pushed; the short chip or a directive's `short` changes that for the
	# rest of the session
	show_short_at_boot : Bool
	show_short_at_boot = Bool.False

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

	# the rung column under (mx, my), laid out the way draw! lays it: index
	# spacing over the plot between plot_top and the theme's bottom padding,
	# each column half a step to either side of its rung
	rung_at : F32, F32, F32, F32, U64, F32 -> Try(U64, [NoRung])
	rung_at = |mx, my, win_w, win_h, n, left| {
		pw = win_w - left - Theme.pad_r
		ph = win_h - plot_top - Theme.pad_b
		if (n == 0 or my < plot_top or my > plot_top + ph) Err(NoRung)
		else {
			nlast = n - 1
			half = if (nlast == 0) (pw / 2.0) else pw / U64.to_f32(nlast) / 2.0
			cx = |i| if (nlast == 0) (left + pw / 2.0) else left + pw * U64.to_f32(i) / U64.to_f32(nlast)
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
		match rung_at(model.mouse_x, model.mouse_y, model.win.w, model.win.h, List.len(layout(model).prs), layout(model).left) {
			Ok(i) => match List.get(layout(model).prs, i) {
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

	# The value axis spans the drawn values: every rung on screen of all three
	# envelopes, the planned targets and the threshold line. Zero values are
	# absent rungs and never set the floor. A power curve runs from 5% under
	# the lowest to 5% over the highest, widened out to the nearest rules of
	# power_step, so its edges fall on round watts. A speed curve's values sit
	# in a narrow band far from zero (a runner's 5- and 20-minute bests differ
	# by a few percent), so its margins are 3% under the lowest and 2% over
	# the highest, and its rules are round paces instead.
	axis_span : Str, List(I64), List(I64), F32 -> { lo : F32, hi : F32 }
	axis_span = |curve, rung_vals, mark_vals, fit| {
		vals = List.concat(List.map(List.keep_if(List.concat(rung_vals, mark_vals), |v| v > 0), I64.to_f32), if (fit > 0.0) [fit] else [])
		top = List.fold(vals, 1.0, F32.max)
		low = List.fold(vals, top, F32.min)
		if !is_pace(curve) {
			lo0 = low * 0.95
			hi0 = top * 1.05
			step = power_step(lo0, hi0)
			{ lo: F32.div_floor_by(lo0, step) * step, hi: -(F32.div_floor_by(-hi0, step)) * step }
		} else {
			{ lo: low * 0.97, hi: top * 1.02 }
		}
	}

	# the power rule spacing: the smallest of the round steps that leaves at
	# most six rules between lo and hi
	power_step : F32, F32 -> F32
	power_step = |lo, hi| List.fold([1000.0, 500.0, 250.0, 200.0, 100.0, 50.0, 25.0, 20.0, 10.0, 5.0], 1000.0, |best, s| if ((hi - lo) / s <= 6.0) s else best)

	# The gridlines strictly between lo and hi. A power curve rules every
	# power_step watts. A pace curve rules round paces in its own unit, every
	# 5, 10, 15, 20 or 30 seconds or every 1, 2 or 5 minutes - the smallest
	# step that leaves at most six lines - placed at the speed each pace is.
	grid_vals : Str, [Metric, Imperial], F32, F32 -> List(F32)
	grid_vals = |curve, units, lo, hi|
		match Bus.curve_key(curve) {
			Power(_) => {
				step = power_step(lo, hi)
				first = F32.div_floor_by(lo, step) + 1.0
				n = F32.round_to_u64_try((hi - lo) / step + 1.0) ?? 0
				List.keep_if(List.map_with_index(List.repeat({}, n), |_u, k| (first + U64.to_f32(k)) * step), |v| v > lo and v < hi)
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
	# floor and D' inside a plausible band. D' is the distance an athlete can
	# cover above critical speed, and its scale is the sport's: tens of metres
	# in the water, low hundreds on the erg, up to several hundred on foot. One
	# band for every sport would either pass a swim fit far too large or
	# refuse a real one, so each family gets its own. Three 5-to-20-minute
	# bests that are steady efforts rather than maximal ones still fit a line,
	# with a D' outside the band.
	d_prime_band : Str -> { lo : F32, hi : F32 }
	d_prime_band = |sport| {
		fam = Sports.canonical(sport)
		if (fam == "Swim") ({ lo: 5.0, hi: 100.0 })
		else if (fam == "Rowing") ({ lo: 10.0, hi: 300.0 })
		else { lo: 10.0, hi: 600.0 }
	}

	fit_usable_for : Str, Db.Fit -> Bool
	fit_usable_for = |curve, fit|
		match Bus.curve_key(curve) {
			Pace(sp) => {
				band = d_prime_band(sp)
				fit.ok and fit.r2 >= fit_r2_min and fit.w_prime >= band.lo and fit.w_prime <= band.hi
			}
			Power(_) => fit_usable(fit)
		}

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

	# The threshold line the curve draws: the usable fit's, else the threshold of
	# a marked test in force for the curve's family (ADR 0020), else none (0).
	# A test is an all-out effort the athlete declared, so it stands in when the
	# window's bests are too steady to fit.
	anchor_line : Str, Db.Fit, Db.TestAnchor -> F32
	anchor_line = |curve, fit, test| {
		f = fit_line(curve, fit)
		if (f > 0.0) f else if (test.value <= 0.0) 0.0 else if (is_pace(curve)) (test.value * 1000.0) else test.value
	}

	anchor_tag : Str, [Metric, Imperial], Db.Fit, Db.TestAnchor -> Str
	anchor_tag = |curve, units, fit, test|
		if (fit_usable_for(curve, fit) or test.value <= 0.0) fit_tag(curve, units, fit)
		else Str.concat(test_shown(curve, units, test), " test")

	# the footer when a test anchors the curve: the threshold, the test that set
	# it, and that the window's own fit is the one not drawn
	anchor_caption_for : Str, [Metric, Imperial], Db.Fit, Db.TestAnchor, I64 -> Str
	anchor_caption_for = |curve, units, fit, test, best20_age|
		if (fit_usable_for(curve, fit) or test.value <= 0.0) fit_caption_for(curve, units, fit, best20_age)
		else {
			fit_name = if (is_pace(curve)) "CS" else "CP"
			"${test_shown(curve, units, test)} from a ${test.kind} test on ${test.date} - this window's ${fit_name} fit is not usable"
		}

	test_shown : Str, [Metric, Imperial], Db.TestAnchor -> Str
	test_shown = |curve, units, test|
		match Bus.curve_key(curve) {
			Power(_) => "FTP ${Db.fmt_f(test.value)}W"
			Pace(_) => "threshold ${val_text(curve, units, F32.round_to_i64_try(test.value * 1000.0) ?? 0)}"
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

	# ── planned targets as marks on the curve. A planned session names no
	# sport, and watts are not comparable across families (a ride's 230 W is
	# far beyond a row's best), so a power target goes on one curve: the power
	# family the athlete trains most, the first of CurveKeys.power. A pace
	# target goes on every pace curve its unit fits (Sports
	# pace_unit_families), at the speed its pace names and the duration one rep
	# takes at that speed.
	Mark : { day : Str, typ : Str, dur_s : I64, val : I64, val_txt : Str, rep_txt : Str }

	marks_for : Str, Str, List(Db.Target), List(Db.PaceTarget) -> List(Mark)
	marks_for = |curve, power_home, power, pace|
		match Bus.curve_key(curve) {
			Power(fam) if fam != power_home => []
			Power(_) =>
				List.map(power, |t| { day: t.day, typ: t.typ, dur_s: t.dur_s, val: t.watts, val_txt: "${I64.to_str(t.watts)}W", rep_txt: "${I64.to_str(t.reps)}x${Fmt.mmss(t.dur_s)}" })
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
	# from chip0 = win_w - 420. Left of them, right-aligned, sit the curve
	# chips: in power mode every family with power, then each pace sport
	# whose family has no power curve; in pace mode every pace sport, then
	# each power family with no pace curve. So every curve on record is one
	# click away from either mode, most-used first, as many as fit between
	# the title and the range chips, the one on screen always among them.
	# Right of the range chips sits the power and pace pair, only when the
	# sport on screen has a curve of the other kind: a ride has no pace
	# curve, so a bike curve shows no pace chip.
	Chip : { key : Str, label : Str, x : F32, on : Bool }

	chip_w : F32
	chip_w = 52.0

	chip_pitch : F32
	chip_pitch = 58.0

	# the title shares the chip row, so the chips start where its text ends:
	# its left inset, its width at the title's size (title_char_w per
	# character, an upper bound for the size-15 face) and a gap
	title_char_w : F32
	title_char_w = 9.0

	title_reserve_for : Str -> F32
	title_reserve_for = |title| 36.0 + U64.to_f32(Str.count_utf8_bytes(title)) * title_char_w + 12.0

	# the chip row for the curve on screen, laid out against its own title
	chips_for : F32, Db.CurveKeys, Str, I64 -> List(Chip)
	chips_for = |win_w, keys, cur, days| curve_chips(win_w, keys, cur, title_reserve_for(title_text(cur, days)))

	# the same sport's curve of the other kind: a power family's most-used
	# pace sport, or a pace sport's power family; '' when it has none
	counterpart : Db.CurveKeys, Str -> Str
	counterpart = |keys, cur|
		match Bus.curve_key(cur) {
			Power(fam) => (List.first(List.keep_if(keys.pace, |k| pace_family(k) == fam))).ok_or("")
			Pace(sp) => if (List.contains(keys.power, Sports.canonical(sp))) Sports.canonical(sp) else ""
		}

	# the family a pace key's sport belongs to; '' for a power key
	pace_family : Str -> Str
	pace_family = |k|
		match Bus.curve_key(k) {
			Pace(sp) => Sports.canonical(sp)
			Power(_) => ""
		}

	curve_chips : F32, Db.CurveKeys, Str, F32 -> List(Chip)
	curve_chips = |win_w, keys, cur, title_reserve| {
		chip0 = win_w - 420.0
		pace_on = is_pace(cur)
		other = counterpart(keys, cur)
		modes =
			if (other == "") []
			else [
				{ key: if (pace_on) other else cur, label: "power", x: chip0 + 176.0, on: !pace_on },
				{ key: if (pace_on) cur else other, label: "pace", x: chip0 + 234.0, on: pace_on },
			]
		mode_keys =
			if (pace_on) List.concat(keys.pace, List.keep_if(keys.power, |k| counterpart(keys, k) == ""))
			else List.concat(keys.power, List.keep_if(keys.pace, |k| counterpart(keys, k) == ""))
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
# a power target reads in watts on every power curve; its label carries
# its share of the window's best at the rep duration
expect {
	ms = Curve.marks_for("Ride", "Ride", [{ day: "2026-11-05", typ: "threshold", reps: 2, dur_s: 900, watts: 225 }], [])
	match ms {
		[m] => Curve.target_label(m, 257.0) == "planned 11-05 225W 88%" and Curve.target_label(m, 0.0) == "planned 11-05 225W" and List.map(Curve.target_card(m, 257.0), |l| l.text) == ["planned 2026-11-05 threshold", "2x15:00 @ 225W", "88% of this window's best there"]
		_ => Bool.False
	}
}
# a power target sits on the most-trained power family's curve only: a
# ride's 230 W drawn on a rowing curve would read as 157% of the row's best
expect List.len(Curve.marks_for("Rowing", "Rowing", [{ day: "2026-11-05", typ: "threshold", reps: 2, dur_s: 900, watts: 225 }], [])) == 1 and List.len(Curve.marks_for("Rowing", "Ride", [{ day: "2026-11-05", typ: "threshold", reps: 2, dur_s: 900, watts: 225 }], [])) == 0
# a pace target lands on every pace curve its unit fits, at the speed its
# pace names; a distance rep takes the time that distance needs at that
# pace, and a unit for another sport keeps it off the curve
expect {
	run = { day: "2026-11-10", typ: "threshold", reps: 5, dur_s: 240, dist_m: 0, pace_s: 402, unit: "/mi" }
	swim = { day: "2026-11-11", typ: "threshold", reps: 10, dur_s: 0, dist_m: 100, pace_s: 100, unit: "/100m" }
	match Curve.marks_for("pace:TrailRun", "Ride", [], [run, swim]) {
		[m] => m.val == 4003 and m.dur_s == 240 and m.val_txt == "6:42/mi" and m.rep_txt == "5x4:00" and Curve.target_label(m, 4210.0) == "planned 11-10 6:42/mi 95%"
		_ => Bool.False
	}
		and (
			match Curve.marks_for("pace:Swim", "Ride", [], [run, swim]) {
				[m] => m.val == 1000 and m.dur_s == 100 and m.rep_txt == "10x100m"
				_ => Bool.False
			}
		)
		and Curve.marks_for("Ride", "Ride", [], [run, swim]) == []
}
expect Curve.r2_str(0.84) == "0.84" and Curve.r2_str(0.9) == "0.90" and Curve.r2_str(0.05) == "0.05" and Curve.r2_str(1.0) == "1.00" and Curve.r2_str(0.899) == "0.89" and Curve.r2_str(0.8999) == "0.89" and Curve.r2_str(-0.253) == "-0.25"
# a rung within 5% of the next longer one was not pushed: in this ladder the
# short rungs crowd the 20-minute best, while the 20-minute best stands 5%
# over the hour; the hour has nothing longer to beat, and an absent rung is
# neither
expect Curve.flat_ratio == 1.05
expect Curve.unpushed([290, 272, 265, 262, 255, 254, 248, 236]) == [Bool.False, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False, Bool.False]
expect Curve.unpushed([400, 0, 300]) == [Bool.False, Bool.False, Bool.False]
expect Curve.unpushed_caption(["5s", "15s", "30s"], [Bool.False, Bool.True, Bool.True], 30) == "no all-out effort in 30 days at 15s, 30s"
expect Curve.unpushed_caption(["5s", "15s"], [Bool.False, Bool.False], 30) == ""
# a best set more than half the window ago is stale; exactly half is not
expect !Curve.stale_best(15, 30) and Curve.stale_best(16, 30) and !Curve.stale_best(-1, 30)
# the short rungs fold when none was pushed: a window of 333, 318, 312 and
# 303 W at 5 s-1 min against records of 475, 419, 385 and 340 W folds (the
# 1-minute best clears the 5-minute one, but sits under 90% of its record),
# a real sprint (460 W at 5 s, within 90% of 475) shows them all, absent
# short rungs fold, and a ladder with no short rung has nothing to fold
expect {
	secs = [5, 15, 30, 60, 300, 600, 1200, 3600]
	recs = [475, 419, 385, 340, 293, 289, 285, 236]
	Curve.fold_short(secs, [333, 318, 312, 303, 274, 271, 254, 233], recs)
		and !(Curve.fold_short(secs, [460, 318, 312, 303, 274, 271, 254, 233], recs))
		and Curve.fold_short(secs, [0, 0, 0, 0, 274, 271, 254, 233], recs)
		and !(Curve.fold_short([300, 1200], [274, 254], [293, 285]))
}
# the short chip shows only while there is something to fold, and moves past
# the power and pace pair when that shows
expect {
	keys = { power: ["Ride", "Rowing"], pace: ["pace:Rowing"] }
	Curve.short_chips(1400.0, keys, "Ride", Bool.False, Bool.False) == []
		and List.map(Curve.short_chips(1400.0, keys, "Ride", Bool.True, Bool.False), |c| c.x) == [1400.0 - 420.0 + 176.0]
		and List.map(Curve.short_chips(1400.0, keys, "Rowing", Bool.True, Bool.True), |c| { x: c.x, on: c.on }) == [{ x: 1400.0 - 420.0 + 292.0, on: Bool.True }]
}
# the window opens with the short rungs folded
expect !Curve.show_short_at_boot
# a hover test lays the columns out from the same left edge the plot uses:
# with the gutter, the first column's boundary moves right by its width
expect {
	left = Theme.pad_l + Curve.short_gutter
	half = (1400.0 - left - Theme.pad_r) / 3.0 / 2.0
	Curve.rung_at(left + half - 1.0, Curve.plot_top + 10.0, 1400.0, 900.0, 4, left) == Ok(0)
		and Curve.rung_at(left + half + 1.0, Curve.plot_top + 10.0, 1400.0, 900.0, 4, left) == Ok(1)
}
# the curve chips: right-aligned against the range chips, most-used first,
# as many as fit beside the title, the one on screen always among them and
# lit. Power mode lists the power families, then the pace sports with no
# power family; pace mode the reverse. The power and pace pair appears only
# when the sport on screen has a curve of the other kind, so a ride, which
# has no pace curve, shows none.
expect {
	keys = { power: ["Ride", "Rowing", "Run"], pace: ["pace:Rowing", "pace:Run", "pace:Swim", "pace:TrailRun", "pace:Walk"] }
	bike = Curve.curve_chips(1400.0, keys, "Ride", 340.0)
	row = Curve.curve_chips(1400.0, keys, "Rowing", 340.0)
	narrow = Curve.curve_chips(980.0, keys, "pace:TrailRun", 340.0)
	labels = |cs| List.map(cs, |c| c.label)
	labels(bike) == ["bike", "row", "run", "swim", "walk"]
		and List.map(List.keep_if(bike, |c| c.on), |c| c.label) == ["bike"]
		and labels(row) == ["bike", "row", "run", "swim", "walk", "power", "pace"]
		and Curve.chip_at(row, 1400.0 - 420.0 + 234.0 + 10.0) == "pace:Rowing"
		and Curve.chip_at(row, 1400.0 - 420.0 + 176.0 + 10.0) == "Rowing"
		and Curve.chip_at(bike, 1400.0 - 420.0 + 234.0 + 10.0) == ""
		and labels(narrow) == ["row", "run", "trail", "power", "pace"]
		and List.map(List.keep_if(narrow, |c| c.on), |c| c.key) == ["pace:TrailRun", "pace:TrailRun"]
		and List.map(List.keep_if(narrow, |c| c.label == "power"), |c| c.key) == ["Run"]
		and List.all(narrow, |c| c.x >= 340.0)
		and Curve.chip_at(bike, 1400.0 - 420.0 - 2.0) == ""
}
# a pace sport's counterpart is its family's power curve, and a power
# family's is its most-used pace sport; a ride and a pool swim have none
expect {
	keys = { power: ["Ride", "Run"], pace: ["pace:TrailRun", "pace:Run", "pace:Swim"] }
	Curve.counterpart(keys, "Run") == "pace:TrailRun" and Curve.counterpart(keys, "pace:Run") == "Run" and Curve.counterpart(keys, "Ride") == "" and Curve.counterpart(keys, "pace:Swim") == ""
}
# one kind of curve on record: no power and pace pair
expect List.map(Curve.curve_chips(1400.0, { power: [], pace: ["pace:Swim", "pace:OpenWaterSwim"] }, "pace:Swim", 340.0), |c| c.label) == ["swim", "open"]
# the chips' last right edge sits 14 px left of the first range chip
expect {
	cs = Curve.curve_chips(1400.0, { power: ["Ride", "Rowing"], pace: [] }, "Ride", 340.0)
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
# a power axis spans the drawn values with a 5% margin, out to round rules:
# 230-330 W (a 300 W target and a 247 W CP inside) runs 200-350 on 25 W
# rules, so the gaps between the lines get the height; a value only a
# target reaches still widens it, and an absent rung never sets the floor
expect {
	s = Curve.axis_span("Ride", [330, 0, 230, 271], [300], 247.0)
	(s.lo - 200.0).abs() < 0.001 and (s.hi - 350.0).abs() < 0.001 and List.map(Curve.grid_vals("Ride", Metric, s.lo, s.hi), |v| Curve.axis_text("Ride", Metric, F32.round_to_i64_try(v) ?? 0)) == ["225", "250", "275", "300", "325"]
}
expect {
	s = Curve.axis_span("Ride", [330, 230], [480], 0.0)
	(s.lo - 200.0).abs() < 0.001 and (s.hi - 550.0).abs() < 0.001
}
expect Curve.power_step(200.0, 350.0) == 25.0 and Curve.power_step(0.0, 540.0) == 100.0 and Curve.power_step(240.0, 260.0) == 5.0
expect List.len(Curve.grid_vals("Ride", Metric, 0.0, 540.0)) == 5
expect {
	s = Curve.axis_span("pace:Run", [4600, 4200, 4000, 0], [3850], 0.0)
	(s.lo - 3734.5).abs() < 0.5 and (s.hi - 4692.0).abs() < 0.5
}
expect List.map(Curve.grid_vals("pace:Run", Metric, 3465.0, 4689.0), |v| Curve.axis_text("pace:Run", Metric, F32.round_to_i64_try(v) ?? 0)) == ["3:45", "4:00", "4:15", "4:30", "4:45"]
expect List.map(Curve.grid_vals("pace:Swim", Metric, 1200.0, 1500.0), |v| Curve.axis_text("pace:Swim", Metric, F32.round_to_i64_try(v) ?? 0)) == ["1:10", "1:15", "1:20"]
expect Curve.title_text("Ride", 90) == "power - this 90d vs the 90d before it" and Curve.title_text("Rowing", 30) == "row power - this 30d vs the 30d before it" and Curve.title_text("pace:TrailRun", 60) == "trail run pace - this 60d vs the 60d before it"
expect Curve.chip_label("Ride") == "bike" and Curve.chip_label("Run") == "run" and Curve.chip_label("WeightTraining") == "strength" and Curve.chip_label("Kayaking") == "kayaking" and Curve.chip_label("pace:OpenWaterSwim") == "open"
# a CS fit is usable at the r2 floor with D' inside its band, and its line
# sits at the critical speed in millimetres per second
expect Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 200.0, r2: 0.95, points: 3.0, ok: Bool.True }) and !Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 2000.0, r2: 0.95, points: 3.0, ok: Bool.True }) and !Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 200.0, r2: 0.85, points: 3.0, ok: Bool.True })
# the D' band is the sport's own: a 150 m D' is a plausible run fit and an
# implausible swim one, and an open-water swim takes the pool's band
expect Curve.fit_usable_for("pace:Run", { cp: 4.0, w_prime: 150.0, r2: 0.95, points: 3.0, ok: Bool.True }) and !Curve.fit_usable_for("pace:Swim", { cp: 1.2, w_prime: 150.0, r2: 0.95, points: 3.0, ok: Bool.True }) and Curve.fit_usable_for("pace:OpenWaterSwim", { cp: 1.2, w_prime: 30.0, r2: 0.95, points: 3.0, ok: Bool.True })
expect Curve.d_prime_band("Rowing") == { lo: 10.0, hi: 300.0 } and Curve.d_prime_band("VirtualRow") == { lo: 10.0, hi: 300.0 } and Curve.d_prime_band("TrailRun") == { lo: 10.0, hi: 600.0 }
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
# the band above the plot stacks without overlap: the tiles start under
# the chips, the 11 pt caption row starts under the tiles and ends before
# the plot, so the legend, caption and loading note never overprint a tile
# or a chip at any width
expect Curve.tile_top >= Curve.chip_bottom + 4.0 and Curve.caption_top >= Curve.tile_top + Curve.tile_h + 4.0 and Curve.caption_top + 13.0 <= Curve.plot_top
expect Curve.chip_bottom - Curve.chip_top == 22.0

# a usable fit draws its own line; an unusable one gives way to a marked test
# in force, in the curve's own units; with neither there is no line
expect {
	weak = { cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }
	good = { cp: 250.0, w_prime: 15000.0, r2: 0.95, points: 3.0, ok: Bool.True }
	test = { value: 246.5, kind: "cp3-12", date: "2026-10-27" }
	none = { value: 0.0, kind: "none", date: "none" }
	(Curve.anchor_line("Ride", good, test) - 250.0).abs() < 0.01
		and (Curve.anchor_line("Ride", weak, test) - 246.5).abs() < 0.01
		and Curve.anchor_line("Ride", weak, none) == 0.0
}
expect (Curve.anchor_line("pace:Run", { cp: 4.0, w_prime: 2000.0, r2: 0.95, points: 3.0, ok: Bool.True }, { value: 3.76, kind: "5k", date: "2026-11-01" }) - 3760.0).abs() < 0.01
expect Curve.anchor_tag("Ride", Metric, { cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }, { value: 246.5, kind: "cp3-12", date: "2026-10-27" }) == "FTP 246.5W test"
expect Curve.anchor_tag("Ride", Metric, { cp: 250.0, w_prime: 15000.0, r2: 0.95, points: 3.0, ok: Bool.True }, { value: 246.5, kind: "cp3-12", date: "2026-10-27" }) == "CP 250.0W"
expect Curve.anchor_caption_for("Ride", Metric, { cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }, { value: 246.5, kind: "cp3-12", date: "2026-10-27" }, 9) == "FTP 246.5W from a cp3-12 test on 2026-10-27 - this window's CP fit is not usable"
expect Curve.anchor_caption_for("pace:Run", Metric, { cp: 4.0, w_prime: 2000.0, r2: 0.95, points: 3.0, ok: Bool.True }, { value: 4.0, kind: "5k", date: "2026-11-01" }, 3) == "threshold 4:10/km from a 5k test on 2026-11-01 - this window's CS fit is not usable"
# with no test the caption is the fit's own, prompt included
expect Curve.anchor_caption_for("Ride", Metric, { cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }, { value: 0.0, kind: "none", date: "none" }, 9) == Curve.fit_caption({ cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }, 9)

expect Curve.focus_short(Bool.False, Bool.False) == -1 and Curve.focus_short(Bool.False, Bool.True) == -1
expect Curve.focus_short(Bool.True, Bool.False) == 0 and Curve.focus_short(Bool.True, Bool.True) == 1

# the longest title a pace curve takes, at the minimum width with three
# curves on record: no chip starts inside the title's text
expect {
	keys = { power: [], pace: ["pace:OpenWaterSwim", "pace:Swim", "pace:Run"] }
	title = Curve.title_text("pace:OpenWaterSwim", 90)
	title == "open water swim pace - this 90d vs the 90d before it"
		and List.all(Curve.chips_for(980.0, keys, "pace:OpenWaterSwim", 90), |c| c.x >= 36.0 + U64.to_f32(Str.count_utf8_bytes(title)) * Curve.title_char_w)
}

# the tiles on a 90-day ride window: the hour best is the record and says
# PR, the 20-minute best names the record it trails, the FTP says where it
# came from, and a fit too weak to trust asks for the test with the 20-minute
# best's age
expect {
	prs = [{ rung: "10min", secs: 600, w: 289, day: "2026-05-04" }, { rung: "20min", secs: 1200, w: 285, day: "2026-05-04" }, { rung: "60min", secs: 3600, w: 236, day: "2026-11-11" }]
	pts = [{ dur_s: 1200, watts: 254.0, aid: 1, name: "a", day: "2026-10-30", ago: 13 }, { dur_s: 3600, watts: 236.4, aid: 2, name: "b", day: "2026-11-11", ago: 1 }]
	weak = { cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }
	none = { value: 0.0, kind: "none", date: "none" }
	ts = Curve.head_tiles("Ride", Metric, prs, pts, { fit: weak, test: none, thr: 241.0, best20_age: 13 })
	List.map(ts, |t| (t.value, t.caption, t.good)) == [("236 w", "60min best 11-11 - PR", Bool.True), ("254 w", "20min best 10-30 - PR 285 w", Bool.False), ("241 w", "FTP derived", Bool.False), ("test due", "CP not reliable - 20min best 13d ago", Bool.False)]
}
# a marked test names itself on the threshold tile and stands in for a weak
# fit; a usable fit shows CP and W'; a window with no effort at a rung says so
expect {
	prs = [{ rung: "20min", secs: 1200, w: 285, day: "2026-05-04" }, { rung: "60min", secs: 3600, w: 236, day: "2026-11-11" }]
	weak = { cp: 252.9, w_prime: 2980.0, r2: 0.84, points: 3.0, ok: Bool.True }
	good = { cp: 250.0, w_prime: 15000.0, r2: 0.95, points: 3.0, ok: Bool.True }
	test = { value: 246.5, kind: "cp3-12", date: "2026-10-27" }
	tested = Curve.head_tiles("Ride", Metric, prs, [], { fit: weak, test, thr: 246.5, best20_age: -1 })
	fitted = Curve.head_tiles("Ride", Metric, prs, [], { fit: good, test: { value: 0.0, kind: "none", date: "none" }, thr: 0.0, best20_age: -1 })
	List.map(tested, |t| t.caption) == ["60min best: none this window", "20min best: none this window", "FTP from test 10-27", "fit not reliable - test 10-27"]
		and List.map(tested, |t| t.value) == ["-", "-", "247 w", "CP from test"]
		and List.map(fitted, |t| (t.value, t.caption)) == [("-", "60min best: none this window"), ("-", "20min best: none this window"), ("-", "no FTP on record"), ("CP 250.0W", "W' 15.0 kJ - fit r2 0.95")]
}
# a pace curve's tiles read in pace in the sport's own unit: its two
# longest rungs, the threshold pace from m/s, and CS with D'
expect {
	prs = [{ rung: "5min", secs: 300, w: 4300, day: "2026-10-01" }, { rung: "10min", secs: 600, w: 4100, day: "2026-10-01" }, { rung: "20min", secs: 1200, w: 4000, day: "2026-10-02" }]
	pts = [{ dur_s: 600, watts: 4100.0, aid: 1, name: "a", day: "2026-10-01", ago: 3 }, { dur_s: 1200, watts: 3900.0, aid: 1, name: "a", day: "2026-10-05", ago: 3 }]
	good = { cp: 4.0, w_prime: 200.0, r2: 0.95, points: 3.0, ok: Bool.True }
	ts = Curve.head_tiles("pace:Rowing", Metric, prs, pts, { fit: good, test: { value: 0.0, kind: "none", date: "none" }, thr: 4.0, best20_age: 3 })
	List.map(ts, |t| (t.value, t.caption)) == [("2:08/500m", "20min best 10-05 - PR 2:05/500m"), ("2:02/500m", "10min best 10-01 - PR"), ("2:05/500m", "threshold derived"), ("CS 2:05/500m", "D' 200 m - fit r2 0.95")]
}
# four tiles fill the row from the title's inset to 40 px short of the right
# edge, at the minimum window and wider
expect {
	ends = |w| (Curve.tile_x(w, 0), Curve.tile_x(w, 3) + Curve.tile_w(w))
	ends(980.0) == (36.0, 940.0) and ends(1400.0) == (36.0, 1360.0) and Curve.tile_w(980.0) > 200.0
}
# the hover card titles the rung and gives one row per line with its date,
# the session behind this window's best, and its quality tags muted
expect {
	r = { rung: "10min", rec_w: 289, rec_day: "2026-05-04", now_w: 271, now_day: "2026-08-16", name: "45 min Ride", prev_w: 260, prev_day: "2026-06-01", unp: Bool.False, stale: Bool.True }
	List.map(Curve.rung_card("Ride", Metric, r), |l| (l.text, l.tone)) == [("10min", Title), ("this window  271 w  2026-08-16", Body), ("previous window  260 w  2026-06-01", Body), ("best ever  289 w  2026-05-04", Body), ("45 min Ride", Muted), ("stale", Muted)]
		and List.map(Curve.rung_card("Ride", Metric, { ..r, now_w: 0, prev_w: 0 }), |l| l.text) == ["10min", "this window  no effort", "previous window  no effort", "best ever  289 w  2026-05-04"]
		and List.map(Curve.rung_card("Ride", Metric, { ..r, rec_w: 0 }), |l| l.text) == ["10min", "no effort on record"]
}
# the card sits right of its point, flips left at the plot's right edge, and
# stays between the plot's top and bottom without covering the point
expect {
	b = { lo_x: 64.0, hi_x: 894.0, top: 166.0, bot: 544.0 }
	Curve.card_place(300.0, 300.0, 200.0, 90.0, b) == { left: 314.0, top: 255.0 }
		and Curve.card_place(800.0, 300.0, 200.0, 90.0, b) == { left: 586.0, top: 255.0 }
		and Curve.card_place(300.0, 170.0, 200.0, 90.0, b) == { left: 314.0, top: 166.0 }
		and Curve.card_place(300.0, 540.0, 200.0, 90.0, b) == { left: 314.0, top: 454.0 }
}
# the legend names only the lines on the chart, left to right from x0 with a
# gap between items; the caption at the row's right gives way when it would
# meet the legend
expect {
	all = Curve.legend_items(Bool.True, Bool.True, Bool.True, Bool.True)
	xs = Curve.legend_xs([100.0, 140.0, 90.0], 36.0, 16.0)
	List.map(all, |i| i.label) == ["this window", "previous window", "best ever", "planned"]
		and List.map(Curve.legend_items(Bool.True, Bool.False, Bool.True, Bool.False), |i| i.label) == ["this window", "best ever"]
		and List.map(Curve.legend_items(Bool.False, Bool.True, Bool.True, Bool.False), |i| i.label) == ["previous window", "best ever"]
		and xs == [36.0, 152.0, 308.0]
		and Curve.legend_right(xs, [100.0, 140.0, 90.0]) == 398.0
		and Curve.caption_fits(398.0, 414.0) and !Curve.caption_fits(398.0, 413.0)
}
# the zone bands from a 240 W FTP over a 200-350 W axis: Z3 from 216 W, Z4
# to 252, Z5 to 288, Z6 open past the axis top and clipped to it; Z1, Z2 and
# Z7 sit off the axis. Bands tile with no gaps, alternate zones shade, and a
# pace curve or a missing FTP draws none
expect {
	bs = Curve.zone_bands("Ride", 240.0, 200.0, 350.0)
	near = |a, b| (a - b).abs() < 0.01
	List.map(bs, |b| b.name) == ["tempo", "threshold", "VO2max", "anaerobic"]
		and List.map(bs, |b| b.shade) == [Bool.False, Bool.True, Bool.False, Bool.True]
		and (
			match bs {
				[t, th, v, an] => near(t.lo, 200.0) and near(t.hi, 216.0) and near(th.lo, 216.0) and near(th.hi, 252.0) and near(v.hi, 288.0) and near(an.lo, 288.0) and near(an.hi, 350.0)
				_ => Bool.False
			}
		)
		and Curve.zone_bands("pace:Run", 4.0, 3000.0, 5000.0) == []
		and Curve.zone_bands("Ride", 0.0, 200.0, 350.0) == []
}
# the hover columns start at plot_top, under the tiles: a pointer on the
# tile row hovers no rung
expect Curve.rung_at(400.0, Curve.plot_top - 1.0, 980.0, 600.0, 4, Theme.pad_l) == Err(NoRung) and Curve.rung_at(400.0, Curve.plot_top + 1.0, 980.0, 600.0, 4, Theme.pad_l) != Err(NoRung)
