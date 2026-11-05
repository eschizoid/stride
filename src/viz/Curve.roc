import rr.Color
import rr.Draw
import rr.Text
import core.Fmt
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
		# planned targets are ride power, so they ride on the ride curve only
		ride_targets = if (model.curve_family == "Ride") model.plan_targets else []
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
				hov = model.mouse_x >= chx and model.mouse_x <= chx + 46.0 and model.mouse_y >= 64.0 and model.mouse_y <= 86.0
				style = if (on) (Draw.filled(Color.with_alpha(ctl_c, 60))) else if (hov) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
				frame.rounded_rectangle!({ x: chx, y: 64.0, width: 46.0, height: 22.0, radius: 6.0, segments: 6, style })
				x.s.chip.draw!(frame, { pos: { x: chx + 23.0, y: 68.0 }, color: if (on) Color.white else ink_muted, align: (Top, Center) })
			},
		)
		# the family chips beside them: the lit one is the family on screen
		List.for_each!(
			family_chips,
			|fc| {
				fx = win_w - 420.0 + fc.dx
				on = fc.fam == model.curve_family
				hov = model.mouse_x >= fx and model.mouse_x <= fx + 46.0 and model.mouse_y >= 64.0 and model.mouse_y <= 86.0
				style = if (on) (Draw.filled(Color.with_alpha(Theme.tsb_c, 60))) else if (hov) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
				frame.rounded_rectangle!({ x: fx, y: 64.0, width: 46.0, height: 22.0, radius: 6.0, segments: 6, style })
				Text.from(fc.label, model.font).size(12).draw!(frame, { pos: { x: fx + 23.0, y: 68.0 }, color: if (on) Color.white else ink_muted, align: (Top, Center) })
			},
		)
		# eight zero rungs IS the no-records state - the loader materializes
		# every rung, so emptiness is the summed watts, not the list length
		have = List.fold(model.prs, 0.I64, |a, pr| a + pr.w)
		if List.is_empty(model.prs) or have == 0 {
			Text.from(empty_note(model.curve_family), model.font).size(14).draw!(frame, { pos: { x: 36.0, y: 130.0 }, color: ink_muted, align: (Top, Left) })
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
			w_hi = F32.max(List.fold(rungs, 1.0, |a, r| F32.max(a, F32.max(I64.to_f32(r.pr.w), F32.max(I64.to_f32(r.now_w), I64.to_f32(r.prev_w))))), List.fold(ride_targets, 1.0, |a, t| F32.max(a, I64.to_f32(t.watts)))) * 1.08
			nlast = List.len(rungs) - 1
			cx = |i| if (nlast == 0) (pad_l + pw / 2.0) else pad_l + pw * U64.to_f32(i) / U64.to_f32(nlast)
			cy = |w| pad_t + ph * (1.0 - w / w_hi)
			# the watt grid: a faint rule and label every 100w; steps come from
			# the ceiling itself, so any scale gets its rules
			grid_n = match F32.round_to_u64_try(F32.div_floor_by(w_hi, 100.0)) {
				Ok(gn) => gn
				Err(_) => 0.U64
			}
			List.for_each!(
				List.map_with_index(List.repeat({}, grid_n), |_u, k| (U64.to_f32(k) + 1.0) * 100.0),
				|gw|
					if gw < w_hi {
						frame.line!({ start: { x: pad_l, y: cy(gw) }, end: { x: win_w - pad_r, y: cy(gw) }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 36), 1) })
						Text.from(
							match F32.round_to_u64_try(gw) {
								Ok(gi) => U64.to_str(gi)
								Err(_) => ""
							},
							model.font,
						).size(10).draw!(frame, { pos: { x: pad_l - 8.0, y: cy(gw) - 6.0 }, color: ink_faint, align: (Top, Right) })
					} else {},
			)
			# CP from the window's fit, dashed - the blue curve should flatten
			# toward it, and a fit far from the long rungs is visibly wrong. The
			# loader zeroes fit_cp unless the fit is usable (fit_usable), and the
			# footer then says why instead
			if model.fit_cp > 0.0 and model.fit_cp < w_hi {
				cpy = cy(model.fit_cp)
				cp_a = 120
				cp_lbl_c = tsb_c
				List.for_each!(
					List.map_with_index(List.repeat({}, 60), |_u, k| k),
					|k| {
						x0 = pad_l + U64.to_f32(k) * (pw / 60.0)
						frame.line!({ start: { x: x0, y: cpy }, end: { x: x0 + pw / 120.0, y: cpy }, stroke: Draw.stroke(Color.with_alpha(tsb_c, cp_a), 1) })
					},
				)
				model.cp_lbl.draw!(frame, { pos: { x: pad_l + pw + 8.0, y: cpy }, color: cp_lbl_c, align: (Middle, Left) })
			}
			# each line introduces itself at its first rung - the chart must be
			# readable with no narrator. The first rung's delta reads the same
			# list to keep clear of them, so the drawing and the avoidance
			# cannot drift apart; the introductions are laid out in their dots' order
			# first, since two bests a few watts apart would otherwise overprint
			intro_lines = match List.first(rungs) {
				Ok(r0) => List.join([
					(if (r0.pr.w > 0) [{ text: "best ever", y: cy(I64.to_f32(r0.pr.w)) - 8.0, dot: cy(I64.to_f32(r0.pr.w)), color: Color.with_alpha(ink_muted, 130) }] else []),
					(if (r0.prev_w > 0 and r0.prev_w < r0.pr.w) [{ text: "previous window", y: cy(I64.to_f32(r0.prev_w)) - 8.0, dot: cy(I64.to_f32(r0.prev_w)), color: ink_muted }] else []),
					(if (r0.now_w > 0 and r0.now_w < r0.pr.w) [{ text: "this window", y: cy(I64.to_f32(r0.now_w)) + 6.0, dot: cy(I64.to_f32(r0.now_w)), color: Theme.ctl_c }] else []),
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
			# athlete has done. Hovering a ring names the session and takes the
			# tooltip line from the rungs.
			rung_secs = List.map(rungs, |r| r.pr.secs)
			now_pts = List.map(rungs, |r| { secs: r.pr.secs, w: r.now_w })
			tx = |t| {
				p = rung_pos(rung_secs, t.dur_s)
				if (nlast == 0) (pad_l + pw / 2.0) else pad_l + pw * p / U64.to_f32(nlast)
			}
			tgt_hover = List.find_first(ride_targets, |t| F32.abs(model.mouse_x - tx(t)) <= 8.0 and F32.abs(model.mouse_y - cy(I64.to_f32(t.watts))) <= 8.0)
			tgt_hovering = match tgt_hover {
				Ok(_) => Bool.True
				Err(_) => Bool.False
			}
			List.for_each!(
				List.map_with_index(ride_targets, |t, i| { t, i }),
				|x| {
					mx = tx(x.t)
					my = cy(I64.to_f32(x.t.watts))
					best = best_at(now_pts, x.t.dur_s)
					frame.circle!({ center: { x: mx, y: my }, radius: 6.0, style: Draw.filled(Color.with_alpha(Theme.gold_c, 200)) })
					frame.circle!({ center: { x: mx, y: my }, radius: 3.0, style: Draw.filled(Theme.bg) })
					lbl = target_label(x.t, best)
					lw = model.font.measure({ text: lbl, size: 10.0, spacing: Text.default_spacing }).width
					Text.from(lbl, model.font).size(10).draw!(frame, { pos: { x: label_center_within(mx, lw / 2.0, pad_l, pad_l + pw - label_inset), y: my + 10.0 + U64.to_f32(x.i % 2) * 12.0 }, color: Theme.gold_c, align: (Top, Center) })
				},
			)
			match tgt_hover {
				Ok(t) => Text.from(target_tip(t, best_at(now_pts, t.dur_s)), model.font).size(12).draw!(frame, { pos: { x: 36.0, y: 92.0 }, color: Color.white, align: (Top, Left) })
				Err(_) => {}
			}
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
						dpr_txt = if (r.now_unp or r.prev_unp) "" else delta_label(r.now_w, r.prev_w)
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
							d_txt = if (r.now_unp or r.prev_unp) "" else delta_label(r.now_w, r.prev_w)
							if d_txt != "" {
								d_col = if (r.now_w > r.prev_w) tsb_c else Theme.alarm_c
								d_w = model.font.measure({ text: d_txt, size: 10.0, spacing: Text.default_spacing }).width
								d_top = delta_top((cy(I64.to_f32(r.prev_w)) + now_y) / 2.0 - 6.0)
								Text.from(d_txt, model.font).size(10).draw!(frame, { pos: { x: delta_left_x(cx(r.i), d_w, pad_l + pw - label_inset), y: d_top }, color: d_col, align: (Top, Left) })
							}
						}
					}
					Text.from(r.pr.rung, model.font).size(12).draw!(frame, { pos: { x: cx(r.i), y: pad_t + ph - 18.0 }, color: ink_faint, align: (Top, Center) })
					# hover the rung's column: the full story under the title
					half = if (nlast == 0) (pw / 2.0) else pw / U64.to_f32(nlast) / 2.0
					if model.mouse_x >= cx(r.i) - half and model.mouse_x < cx(r.i) + half and model.mouse_y >= pad_t and model.mouse_y <= pad_t + ph and !tgt_hovering {
						now_txt = if (r.now_w > 0) ("   now ${Db.num_unit(r.now_w, "w")}") else "   not ridden this window"
						prev_txt = if (r.prev_w > 0) ("   prev ${Db.num_unit(r.prev_w, "w")}") else ""
						quality = if (r.now_unp) "   not all-out" else if (r.stale) "   stale" else ""
						tip = if (r.pr.w > 0) ("${r.pr.rung}   best ${Db.num_unit(r.pr.w, "w")} set ${r.pr.day}${now_txt}${r.src_txt}${quality}${prev_txt}") else "${r.pr.rung}   never ridden"
						Text.from(tip, model.font).size(12).draw!(frame, { pos: { x: 36.0, y: 92.0 }, color: Color.white, align: (Top, Left) })
					}
				},
			)
			# the window's unpushed durations, named above the fit caption
			unp_txt = unpushed_caption(List.map(rungs, |r| r.pr.rung), List.map(rungs, |r| r.now_unp), model.curve_days)
			if unp_txt != "" {
				Text.from(unp_txt, model.font).size(12).draw!(frame, { pos: { x: win_w - 40.0, y: win_h - 72.0 }, color: ink_faint, align: (Top, Right) })
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

	# a planned target's marker label: its day, watts, and its share of the
	# window's best at the rep duration (omitted when the window has none)
	target_label : Db.Target, F32 -> Str
	target_label = |t, best| {
		mmdd = Str.from_utf8_lossy(List.drop_first(Str.to_utf8(t.day), 5))
		pct = if (best <= 0.0) "" else " ${Db.fmt_i(I64.to_f32(t.watts) / best * 100.0)}%"
		"${mmdd} ${I64.to_str(t.watts)}W${pct}"
	}

	target_tip : Db.Target, F32 -> Str
	target_tip = |t, best| {
		share = if (best <= 0.0) "no window best at that duration" else "${Db.fmt_i(I64.to_f32(t.watts) / best * 100.0)}% of this window's best at that duration"
		"${t.day} ${t.typ}: ${I64.to_str(t.reps)}x${Fmt.mmss(t.dur_s)} @ ${I64.to_str(t.watts)}W - ${share}"
	}

	# ── the family chips: bike and row, to the right of the range chips, on
	# the same row. chip0 is the first range chip's left edge.
	family_chips : List({ fam : Str, label : Str, dx : F32 })
	family_chips = [{ fam: "Ride", label: "bike", dx: 176.0 }, { fam: "Rowing", label: "row", dx: 230.0 }]

	family_chip_at : F32, F32 -> Str
	family_chip_at = |x, chip0|
		match List.find_first(family_chips, |c| x >= chip0 + c.dx and x <= chip0 + c.dx + 46.0) {
			Ok(c) => c.fam
			Err(_) => ""
		}

	# what the view says when the chosen family has no power on record: the
	# family is kept (the chip stays lit), and the note names the way back
	empty_note : Str -> Str
	empty_note = |fam| if (fam == "Ride") "no ride power yet" else if (fam == "Rowing") "no rowing power yet - the bike chip shows ride power" else "no ${fam} power yet - the bike chip shows ride power"

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
expect Curve.target_label({ day: "2026-11-05", typ: "threshold", reps: 2, dur_s: 900, watts: 225 }, 257.0) == "11-05 225W 88%"
expect Curve.target_label({ day: "2026-11-05", typ: "threshold", reps: 2, dur_s: 900, watts: 225 }, 0.0) == "11-05 225W"
expect Curve.target_tip({ day: "2026-11-05", typ: "threshold", reps: 2, dur_s: 900, watts: 225 }, 257.0) == "2026-11-05 threshold: 2x15:00 @ 225W - 88% of this window's best at that duration"
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
expect Curve.family_chip_at(1000.0 + 176.0, 1000.0) == "Ride" and Curve.family_chip_at(1000.0 + 276.0, 1000.0) == "Rowing" and Curve.family_chip_at(1000.0 + 100.0, 1000.0) == ""
expect Curve.empty_note("Rowing") == "no rowing power yet - the bike chip shows ride power" and Curve.empty_note("Ride") == "no ride power yet"
