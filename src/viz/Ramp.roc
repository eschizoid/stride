import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Ramp :: [].{
	# Weekly load beside the CTL slope, twelve Monday weeks: TSS bars below,
	# ramp rate (CTL gained per week) above with the >+6/wk danger band
	# shaded - the overtraining early warning. Different scales, two panels.
	pad : F32
	pad = 36.0
	danger : F32
	danger = 6.0

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		model.ramp_title.draw!(frame, { pos: { x: pad, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		grand = List.fold(model.ramp_weeks, 0.I64, |a, w| a + w.tss)
		if List.is_empty(model.ramp_weeks) or grand == 0 {
			Text.from("no load history yet", model.font).size(14).draw!(frame, { pos: { x: pad, y: 130.0 }, color: ink_muted, align: (Top, Left) })
		} else {
			n = List.len(model.ramp_weeks)
			slot = (win_w - pad * 2.0) / U64.to_f32(n)
			bw = slot * 0.62
			# ramp panel: an asymmetric y - from just under the deepest shed to
			# just over the danger line or the steepest build, so the dots use
			# the room instead of huddling at a symmetric axis's waist
			po_top = 104.0
			po_h = 130.0
			hi9 = List.fold(model.ramp_weeks, danger + 1.0, |a, w| F32.max(a, I64.to_f32(w.ramp10) / 10.0 + 0.5))
			# the floor keeps the zero line on screen with half a unit of margin;
			# an all-building stretch spends the rest of the pixels on the builds
			lo9 = List.fold(model.ramp_weeks, -0.5, |a, w| F32.min(a, I64.to_f32(w.ramp10) / 10.0 - 0.5))
			ry = |v9| po_top + (1.0 - (v9 - lo9) / (hi9 - lo9)) * po_h
			Text.from("ctl gained per week", model.font).size(11).draw!(frame, { pos: { x: pad, y: po_top - 16.0 }, color: ink_faint, align: (Top, Left) })
			# the band above +6/wk, then the rule lines
			frame.rectangle!({ x: pad, y: po_top, width: win_w - pad * 2.0, height: ry(danger) - po_top, style: Draw.filled(Color.with_alpha(Theme.alarm_c, 26)) })
			frame.line!({ start: { x: pad, y: ry(danger) }, end: { x: win_w - pad, y: ry(danger) }, stroke: Draw.stroke(Color.with_alpha(Theme.alarm_c, 110), 1) })
			frame.line!({ start: { x: pad, y: ry(0.0) }, end: { x: win_w - pad, y: ry(0.0) }, stroke: Draw.stroke(Color.with_alpha(Color.white, 30), 1) })
			Text.from("+6 ctl/wk", model.font).size(10).draw!(frame, { pos: { x: win_w - pad, y: ry(danger) - 14.0 }, color: Theme.alarm_c, align: (Top, Right) })
			Text.from("0", model.font).size(10).draw!(frame, { pos: { x: pad - 6.0, y: ry(0.0) - 6.0 }, color: ink_faint, align: (Top, Right) })
			# bars panel
			bars_top = po_top + po_h + 42.0
			bars_bot = win_h - 96.0
			bars_h = bars_bot - bars_top
			peak = List.fold(model.ramp_weeks, 1.I64, |a, w| if w.tss > a (w.tss) else a)
			Text.from(I64.to_str(peak), model.font).size(10).draw!(frame, { pos: { x: pad - 6.0, y: bars_top - 4.0 }, color: ink_faint, align: (Top, Right) })
			Text.from("0", model.font).size(10).draw!(frame, { pos: { x: pad - 6.0, y: bars_bot - 10.0 }, color: ink_faint, align: (Top, Right) })
			Text.from("weekly tss", model.font).size(10).draw!(frame, { pos: { x: win_w - pad, y: bars_top - 24.0 }, color: ink_faint, align: (Top, Right) })
			# the ramp trend as a connected line under the dots
			_ = List.fold(List.map_with_index(model.ramp_weeks, |w8, i8| { w8, i8 }), { px: 0.0, py: 0.0, first: Bool.True }, |acc8, x8| {
				x9 = pad + (U64.to_f32(x8.i8) + 0.5) * slot
				y9 = ry(I64.to_f32(x8.w8.ramp10) / 10.0)
				if acc8.first {} else {
					frame.line!({ start: { x: acc8.px, y: acc8.py }, end: { x: x9, y: y9 }, stroke: Draw.stroke(Color.with_alpha(Theme.ctl_c, 70), 1) })
				}
				{ px: x9, py: y9, first: Bool.False }
			})
			# where fitness stands after all of it: the last week's CTL, said
			_ = match List.last(model.ramp_weeks) {
				Ok(lw) => {
					lx9 = pad + (U64.to_f32(List.len(model.ramp_weeks) - 1) + 0.5) * slot
					Text.from("ctl ${I64.to_str(lw.ctl10 // 10)}.${I64.to_str(I64.abs(lw.ctl10) % 10)}", model.font).size(11).draw!(frame, { pos: { x: lx9, y: ry(I64.to_f32(lw.ramp10) / 10.0) + 12.0 }, color: Color.white, align: (Top, Center) })
					{}
				}
				Err(_) => {}
			}
			List.for_each!(List.map_with_index(model.ramp_weeks, |w, i| { w, i }), |x| {
				cx = pad + (U64.to_f32(x.i) + 0.5) * slot
				x0 = cx - bw / 2.0
				bh = I64.to_f32(x.w.tss) / I64.to_f32(peak) * bars_h
				if bh > 1.0 {
					frame.rectangle!({ x: x0, y: bars_bot - bh, width: bw, height: bh, style: Draw.filled(Color.with_alpha(Theme.ctl_c, 200)) })
				} else {}
				# ramp dot: alarm past the band, teal on a sane build, faint idle
				rv = I64.to_f32(x.w.ramp10) / 10.0
				dc = if rv > danger (Theme.alarm_c) else if rv > 0.0 (Theme.tsb_c) else ink_faint
				frame.circle!({ center: { x: cx, y: ry(rv) }, radius: 3.5, style: Draw.filled(dc) })
				if x.i % 2 == 0 {
					Text.from(Str.from_utf8_lossy(List.drop_first(Str.to_utf8(x.w.wk), 5)), model.font).size(10).draw!(frame, { pos: { x: cx, y: bars_bot + 8.0 }, color: ink_faint, align: (Top, Center) })
				} else {}
				if model.mouse_x >= cx - slot / 2.0 and model.mouse_x < cx + slot / 2.0 and model.mouse_y >= po_top and model.mouse_y <= bars_bot {
					sign = if x.w.ramp10 >= 0 "+" else "-"
					a10 = I64.abs(x.w.ramp10)
					tip = "wk of ${x.w.wk}   ${I64.to_str(x.w.tss)} tss   ctl ${I64.to_str(x.w.ctl10 // 10)}.${I64.to_str(I64.abs(x.w.ctl10) % 10)}   ramp ${sign}${I64.to_str(a10 // 10)}.${I64.to_str(a10 % 10)}/wk"
					Text.from(tip, model.font).size(12).draw!(frame, { pos: { x: pad, y: 88.0 }, color: Color.white, align: (Top, Left) })
					frame.rectangle!({ x: x0 - 3.0, y: bars_top, width: bw + 6.0, height: bars_h, style: Draw.filled(Color.with_alpha(Color.white, 14)) })
				} else {}
			})
			{}
		}
		model.ramp_hint.draw!(frame, { pos: { x: pad, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
