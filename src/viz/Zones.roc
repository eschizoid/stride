import rr.Color
import rr.Draw
import rr.Text
import Db
import Theme
import Ui

Zones :: [].{
	# Weekly time-in-zone, twelve Monday weeks: stacked hour bars in the zone
	# ramp below, each week's easy share against the 80/20 rule line above.
	# Two panels because hours and percent are different scales - never one.
	pad : F32
	pad = 36.0

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		model.zones_title.draw!(frame, { pos: { x: pad, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		grand = List.fold(model.zone_weeks, 0.I64, |a, w| a + w.z1 + w.z2 + w.z3 + w.z4 + w.z5)
		# the loader materializes empty weeks, so 12 zero rows IS the no-history
		# state - the emptiness test is the grand total, not the list length
		if List.is_empty(model.zone_weeks) or grand == 0 {
			Text.from("no zone history yet", model.font).size(14).draw!(frame, { pos: { x: pad, y: 130.0 }, color: ink_muted, align: (Top, Left) })
		} else {
			n = List.len(model.zone_weeks)
			slot = (win_w - pad * 2.0) / U64.to_f32(n)
			bw = slot * 0.62
			# the 80/20 panel, scaled to where easy shares actually live
			# (30%..100% - an athlete under 30% easy has bigger problems than
			# this panel's resolution)
			po_top = 104.0
			po_h = 120.0
			sy = |sh9| po_top + (1.0 - (F32.max(sh9, 0.3) - 0.3) / 0.7) * po_h
			# right-anchored: the hover readout owns the left of this row
			Text.from("easy share, week by week", model.font).size(11).draw!(frame, { pos: { x: win_w - pad, y: po_top - 16.0 }, color: ink_faint, align: (Top, Right) })
			List.for_each!([{ v: 1.0, lb: "100%" }, { v: 0.5, lb: "50%" }, { v: 0.3, lb: "30%" }], |tk| {
				frame.line!({ start: { x: pad, y: sy(tk.v) }, end: { x: win_w - pad, y: sy(tk.v) }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 30), 1) })
				Text.from(tk.lb, model.font).size(10).draw!(frame, { pos: { x: pad - 6.0, y: sy(tk.v) - 6.0 }, color: ink_faint, align: (Top, Right) })
			})
			rule_y = sy(0.8)
			frame.line!({ start: { x: pad, y: rule_y }, end: { x: win_w - pad, y: rule_y }, stroke: Draw.stroke(Color.with_alpha(Theme.tsb_c, 110), 1) })
			Text.from("80%", model.font).size(10).draw!(frame, { pos: { x: pad - 6.0, y: rule_y - 6.0 }, color: Theme.tsb_c, align: (Top, Right) })
			Text.from("the 80/20 line", model.font).size(10).draw!(frame, { pos: { x: win_w - pad, y: rule_y - 14.0 }, color: Theme.tsb_c, align: (Top, Right) })
			# the bars panel
			bars_top = po_top + po_h + 42.0
			bars_bot = win_h - 96.0
			bars_h = bars_bot - bars_top
			peak = List.fold(model.zone_weeks, 1, |a, w| {
				tot = w.z1 + w.z2 + w.z3 + w.z4 + w.z5
				if tot > a tot else a
			})
			peak_hours_10 = peak * 10 // 3600
			Text.from("${I64.to_str(peak_hours_10 // 10)}.${I64.to_str(peak_hours_10 % 10)}h", model.font).size(10).draw!(frame, { pos: { x: pad - 6.0, y: bars_top - 4.0 }, color: ink_faint, align: (Top, Right) })
			Text.from("0", model.font).size(10).draw!(frame, { pos: { x: pad - 6.0, y: bars_bot - 10.0 }, color: ink_faint, align: (Top, Right) })
			# legend
			_ = List.fold([0.U64, 1, 2, 3, 4], 0.0, |lx, zi9| {
				zc = match List.get(Theme.zone_ramp, zi9) { Ok(c2) => c2
					Err(_) => ink_faint }
				bx = win_w - pad - 5.0 * 44.0 + lx
				frame.rectangle!({ x: bx, y: bars_top - 24.0, width: 8.0, height: 8.0, style: Draw.filled(zc) })
				Text.from("z${U64.to_str(zi9 + 1)}", model.font).size(10).draw!(frame, { pos: { x: bx + 12.0, y: bars_top - 26.0 }, color: ink_faint, align: (Top, Left) })
				lx + 44.0
			})
			# the share trend as a connected line first, dots ride on top of it
			# segments join only ADJACENT weeks that both have a share - a week
			# with no classified time breaks the line rather than being bridged,
			# so a gap in the timeline looks like one
			_ = List.fold(List.map_with_index(model.zone_weeks, |w9, i9| { w9, i9 }), { px: 0.0, py: 0.0, live: Bool.False }, |acc9, x9| {
				it9 = x9.w9.easy + x9.w9.moderate + x9.w9.hard
				if it9 > 0 {
					nx9 = pad + (U64.to_f32(x9.i9) + 0.5) * slot
					ny9 = sy(I64.to_f32(x9.w9.easy) / I64.to_f32(it9))
					if acc9.live {
						frame.line!({ start: { x: acc9.px, y: acc9.py }, end: { x: nx9, y: ny9 }, stroke: Draw.stroke(Color.with_alpha(Theme.ctl_c, 80), 1) })
					} else {}
					{ px: nx9, py: ny9, live: Bool.True }
				} else { px: 0.0, py: 0.0, live: Bool.False }
			})
			# one pass: bar stack, easy-share dot, hover
			List.for_each!(List.map_with_index(model.zone_weeks, |w, i| { w, i }), |x| {
				cx = pad + (U64.to_f32(x.i) + 0.5) * slot
				x0 = cx - bw / 2.0
				tot = x.w.z1 + x.w.z2 + x.w.z3 + x.w.z4 + x.w.z5
				itot = x.w.easy + x.w.moderate + x.w.hard
				# stack z1 (bottom) .. z5, hairline gaps like the day panel bars
				_ = List.fold(List.map_with_index([x.w.z1, x.w.z2, x.w.z3, x.w.z4, x.w.z5], |zs, zi| { zs, zi }), 0.0, |yacc, z| {
					seg = I64.to_f32(z.zs) / I64.to_f32(peak) * bars_h
					zc = match List.get(Theme.zone_ramp, z.zi) { Ok(c2) => c2
						Err(_) => ink_faint }
					if seg > 1.5 {
						frame.rectangle!({ x: x0, y: bars_bot - yacc - seg, width: bw, height: seg - 1.0, style: Draw.filled(zc) })
					} else {}
					yacc + seg
				})
				# week label every other slot, Monday's MM-DD
				if x.i % 2 == 0 {
					Text.from(Str.from_utf8_lossy(List.drop_first(Str.to_utf8(x.w.wk), 5)), model.font).size(10).draw!(frame, { pos: { x: cx, y: bars_bot + 8.0 }, color: ink_faint, align: (Top, Center) })
				} else {}
				# easy-share dot on the 80/20 panel; a week with no classified
				# seconds has no share to plot
				if itot > 0 {
					share = I64.to_f32(x.w.easy) / I64.to_f32(itot)
					dy = sy(share)
					dc = if share >= 0.8 (Theme.tsb_c) else Theme.alarm_c
					# the white halo marks these as MARKERS - the alarm red is the
					# same hex as the z5 ramp step, so a bare dot reads as z5 data
					frame.circle!({ center: { x: cx, y: dy }, radius: 5.0, style: Draw.filled(Color.with_alpha(Color.white, 200)) })
					frame.circle!({ center: { x: cx, y: dy }, radius: 3.5, style: Draw.filled(dc) })
				} else {}
				# hover: full-column hit target, one tooltip line under the title
				if model.mouse_x >= cx - slot / 2.0 and model.mouse_x < cx + slot / 2.0 and model.mouse_y >= po_top and model.mouse_y <= bars_bot {
					h10 = tot * 10 // 3600
					shr = if itot > 0 ("easy ${I64.to_str(x.w.easy * 100 // itot)}%") else "no classified time"
					tip = "wk of ${x.w.wk}   ${I64.to_str(h10 // 10)}.${I64.to_str(h10 % 10)}h in zones   ${shr}"
					Text.from(tip, model.font).size(12).draw!(frame, { pos: { x: pad, y: 88.0 }, color: Color.white, align: (Top, Left) })
					frame.rectangle!({ x: x0 - 3.0, y: bars_top, width: bw + 6.0, height: bars_h, style: Draw.filled(Color.with_alpha(Color.white, 14)) })
				} else {}
			})
			{}
		}
		model.zones_hint.draw!(frame, { pos: { x: pad, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
