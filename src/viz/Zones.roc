import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Zones :: [].{
	# Twelve Monday weeks of time in zone as stacked bars. Every week with
	# classified time wears a cap holding its easy share: teal at or above
	# the 80/20 line, alarm below. The share reads across the row of caps.
	pad : F32
	pad = 36.0

	# absence is not a failed verdict: a week with no classified time reads
	# muted, never in the color that means "you broke the rule"
	verdict : I64, I64 -> Color.Rgba
	verdict = |easy, itot|
		if itot <= 0 (Theme.ink_muted)
		else if easy * 100 // itot >= 80 (Theme.tsb_c)
		else Theme.alarm_c

	hours : I64 -> Str
	hours = |secs| {
		h10 = secs * 10 // 3600
		"${I64.to_str(h10 // 10)}.${I64.to_str(h10 % 10)}h"
	}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		model.zones_title.draw!(frame, { pos: { x: pad, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		grand = List.fold(model.zone_weeks, 0.I64, |a, w| a + w.z1 + w.z2 + w.z3 + w.z4 + w.z5)
		if List.is_empty(model.zone_weeks) or grand == 0 {
			Text.from("no zone history yet", model.font).size(14).draw!(frame, { pos: { x: pad, y: 130.0 }, color: ink_muted, align: (Top, Left) })
		} else {
			n = List.len(model.zone_weeks)
			slot = (win_w - pad * 2.0) / U64.to_f32(n)
			bw = F32.min(74.0, slot * 0.60)
			# this week's verdict, in the KPI card language the board established
			last = List.fold(model.zone_weeks, { wk: "", z1: 0, z2: 0, z3: 0, z4: 0, z5: 0, easy: 0, moderate: 0, hard: 0 }, |acc, w|
				if w.easy + w.moderate + w.hard > 0 (w) else acc)
			li = last.easy + last.moderate + last.hard
			lc = verdict(last.easy, li)
			card_x = win_w - pad - 260.0
			frame.rounded_rectangle!({ x: card_x, y: 60.0, width: 260.0, height: 64.0, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
			pct_txt = if li > 0 ("${I64.to_str(last.easy * 100 // li)}%") else "-"
			Text.from(pct_txt, model.font).size(28).draw!(frame, { pos: { x: card_x + 16.0, y: 68.0 }, color: lc, align: (Top, Left) })
			wk_lbl = if last.wk == "" ("no training yet") else "easy, wk of ${Str.from_utf8_lossy(List.drop_first(Str.to_utf8(last.wk), 5))}"
			Text.from(wk_lbl, model.font).size(11).draw!(frame, { pos: { x: card_x + 16.0, y: 102.0 }, color: ink_faint, align: (Top, Left) })
			Text.from(hours(last.z1 + last.z2 + last.z3 + last.z4 + last.z5), model.font).size(28).draw!(frame, { pos: { x: win_w - pad - 16.0, y: 68.0 }, color: Theme.ctl_c, align: (Top, Right) })
			Text.from("in zones", model.font).size(11).draw!(frame, { pos: { x: win_w - pad - 16.0, y: 102.0 }, color: ink_faint, align: (Top, Right) })
			bars_top = 168.0
			bars_bot = win_h - 96.0
			bars_h = bars_bot - bars_top
			peak = List.fold(model.zone_weeks, 1.I64, |a, w| {
				tot = w.z1 + w.z2 + w.z3 + w.z4 + w.z5
				if tot > a (tot) else a
			})
			Text.from(hours(peak), model.font).size(10).draw!(frame, { pos: { x: pad, y: bars_top - 14.0 }, color: ink_faint, align: (Top, Left) })
			Text.from("0", model.font).size(10).draw!(frame, { pos: { x: pad, y: bars_bot - 12.0 }, color: ink_faint, align: (Top, Left) })
			frame.line!({ start: { x: pad, y: bars_bot }, end: { x: win_w - pad, y: bars_bot }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 70), 1) })
			hover_any = List.fold(List.map_with_index(model.zone_weeks, |w, i| { w, i }), Bool.False, |acc, x| {
				cx9 = pad + (U64.to_f32(x.i) + 0.5) * slot
				if model.mouse_x >= cx9 - slot / 2.0 and model.mouse_x < cx9 + slot / 2.0 and model.mouse_y >= bars_top - 44.0 and model.mouse_y <= bars_bot (Bool.True) else acc
			})
			if hover_any {} else {
				Text.from("caps: the week's easy share     teal holds 80/20     red breaks it", model.font).size(11).draw!(frame, { pos: { x: pad, y: 96.0 }, color: ink_faint, align: (Top, Left) })
			}
			# the zone key rides its own row, clear of every cap
			_ = List.fold([0.U64, 1, 2, 3, 4], 0.0, |lx, zi| {
				zc = match List.get(Theme.zone_ramp, zi) { Ok(c2) => c2
					Err(_) => ink_faint }
				bx = pad + lx
				frame.rounded_rectangle!({ x: bx, y: 120.0, width: 9.0, height: 9.0, radius: 2.0, segments: 3, style: Draw.filled(zc) })
				Text.from("z${U64.to_str(zi + 1)}", model.font).size(10).draw!(frame, { pos: { x: bx + 13.0, y: 118.0 }, color: ink_faint, align: (Top, Left) })
				lx + 42.0
			})
			List.for_each!(List.map_with_index(model.zone_weeks, |w, i| { w, i }), |x| {
				cx = pad + (U64.to_f32(x.i) + 0.5) * slot
				x0 = cx - bw / 2.0
				tot = x.w.z1 + x.w.z2 + x.w.z3 + x.w.z4 + x.w.z5
				itot = x.w.easy + x.w.moderate + x.w.hard
				bh = I64.to_f32(tot) / I64.to_f32(peak) * bars_h
				hovered = model.mouse_x >= cx - slot / 2.0 and model.mouse_x < cx + slot / 2.0 and model.mouse_y >= bars_top - 44.0 and model.mouse_y <= bars_bot
				# z1 at the base, z5 on top, a hairline of ground between each
				_ = List.fold(List.map_with_index([x.w.z1, x.w.z2, x.w.z3, x.w.z4, x.w.z5], |zs, zi| { zs, zi }), 0.0, |yacc, z| {
					seg = I64.to_f32(z.zs) / I64.to_f32(peak) * bars_h
					zc = match List.get(Theme.zone_ramp, z.zi) { Ok(c2) => c2
						Err(_) => ink_faint }
					if seg > 1.5 {
						frame.rectangle!({ x: x0, y: bars_bot - yacc - seg, width: bw, height: seg - 1.0, style: Draw.filled(Color.with_alpha(zc, if hovered (255.U8) else 235)) })
					} else {}
					yacc + seg
				})
				# depth over the whole stack, so the bars sit in the panel
				if bh > 8.0 {
					frame.rectangle_gradient_v!({ x: x0, y: bars_bot - bh, width: bw, height: bh, color_top: Color.with_alpha(Theme.bg, 0), color_bottom: Color.with_alpha(Theme.bg, 90) })
				} else {}
				# the cap: this week's easy share, in its verdict color
				if bh > 3.0 {} else {
					frame.rounded_rectangle!({ x: x0, y: bars_bot - 3.0, width: bw, height: 3.0, radius: 1.5, segments: 3, style: Draw.filled(Color.with_alpha(ink_faint, 90)) })
				}
				if itot > 0 {
					cap_y = F32.max(bars_top - 30.0, bars_bot - bh - 30.0)
					vc = verdict(x.w.easy, itot)
					frame.rounded_rectangle!({ x: cx - 27.0, y: cap_y, width: 54.0, height: 20.0, radius: 6.0, segments: 5, style: Draw.filled(Color.with_alpha(vc, if hovered (70.U8) else 42)) })
					Text.from("${I64.to_str(x.w.easy * 100 // itot)}%", model.font).size(11).draw!(frame, { pos: { x: cx, y: cap_y + 4.0 }, color: vc, align: (Top, Center) })
				} else {}
				if x.i % 2 == 0 {
					Text.from(Str.from_utf8_lossy(List.drop_first(Str.to_utf8(x.w.wk), 5)), model.font).size(10).draw!(frame, { pos: { x: cx, y: bars_bot + 10.0 }, color: ink_faint, align: (Top, Center) })
				} else {}
				if hovered {
					shr = if itot > 0 ("easy ${I64.to_str(x.w.easy * 100 // itot)}%") else "no classified time"
					Text.from("wk of ${x.w.wk}   ${hours(tot)} in zones   ${shr}", model.font).size(12).draw!(frame, { pos: { x: pad, y: 96.0 }, color: Color.white, align: (Top, Left) })
				} else {}
			})
			{}
		}
		model.zones_hint.draw!(frame, { pos: { x: pad, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
