import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Ramp :: [].{
	# One chart, one scale. Twelve Monday weeks of load as gradient bars, each
	# wearing a chip with the CTL it gained. The ramp is encoded as COLOR on
	# the bars' own axis rather than as a second y: two scales sharing a plot
	# is a lie no legend repairs, and the split panel it replaces spent a
	# third of the window on air.
	pad : F32
	pad = 36.0
	danger : F32
	danger = 6.0

	# the verdict a week's ramp earns, and the color that says it
	verdict : F32 -> Color.Rgba
	verdict = |rv| if rv > danger (Theme.alarm_c) else if rv > 0.0 (Theme.tsb_c) else Theme.ink_faint

	# a tenths integer as a signed decimal: 25 -> "+2.5", -10 -> "-1.0"
	tenths : I64 -> Str
	tenths = |v| {
		s = if v >= 0 "+" else "-"
		a = I64.abs(v)
		"${s}${I64.to_str(a // 10)}.${I64.to_str(a % 10)}"
	}

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
			bw = F32.min(74.0, slot * 0.60)
			# where fitness stands and how fast it is moving, in the KPI card
			# language the form board established
			last = match List.last(model.ramp_weeks) { Ok(l) => l
				Err(_) => { wk: "", tss: 0, ctl10: 0, ramp10: 0 } }
			lc = verdict(I64.to_f32(last.ramp10) / 10.0)
			card_x = win_w - pad - 260.0
			frame.rounded_rectangle!({ x: card_x, y: 60.0, width: 260.0, height: 64.0, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
			Text.from("${I64.to_str(last.ctl10 // 10)}.${I64.to_str(I64.abs(last.ctl10) % 10)}", model.font).size(28).draw!(frame, { pos: { x: card_x + 16.0, y: 68.0 }, color: Theme.ctl_c, align: (Top, Left) })
			Text.from("ctl now", model.font).size(11).draw!(frame, { pos: { x: card_x + 16.0, y: 102.0 }, color: ink_faint, align: (Top, Left) })
			Text.from(tenths(last.ramp10), model.font).size(28).draw!(frame, { pos: { x: win_w - pad - 16.0, y: 68.0 }, color: lc, align: (Top, Right) })
			Text.from("ctl per week", model.font).size(11).draw!(frame, { pos: { x: win_w - pad - 16.0, y: 102.0 }, color: ink_faint, align: (Top, Right) })
			# the chips explain themselves once, here
			bars_top = 168.0
			bars_bot = win_h - 96.0
			bars_h = bars_bot - bars_top
			peak = List.fold(model.ramp_weeks, 1.I64, |a, w| if w.tss > a (w.tss) else a)
			Text.from("${I64.to_str(peak)} tss", model.font).size(10).draw!(frame, { pos: { x: pad, y: bars_top - 14.0 }, color: ink_faint, align: (Top, Left) })
			Text.from("0", model.font).size(10).draw!(frame, { pos: { x: pad, y: bars_bot - 12.0 }, color: ink_faint, align: (Top, Left) })
			frame.line!({ start: { x: pad, y: bars_bot }, end: { x: win_w - pad, y: bars_bot }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 70), 1) })
			hover_any = List.fold(List.map_with_index(model.ramp_weeks, |w, i| { w, i }), Bool.False, |acc, x| {
				cx9 = pad + (U64.to_f32(x.i) + 0.5) * slot
				if model.mouse_x >= cx9 - slot / 2.0 and model.mouse_x < cx9 + slot / 2.0 and model.mouse_y >= bars_top - 44.0 and model.mouse_y <= bars_bot (Bool.True) else acc
			})
			if hover_any {} else {
				Text.from("chips: the ctl each week gained     teal builds     red past +6/wk     grey sheds", model.font).size(11).draw!(frame, { pos: { x: pad, y: 96.0 }, color: ink_faint, align: (Top, Left) })
			}
			List.for_each!(List.map_with_index(model.ramp_weeks, |w, i| { w, i }), |x| {
				cx = pad + (U64.to_f32(x.i) + 0.5) * slot
				x0 = cx - bw / 2.0
				bh = I64.to_f32(x.w.tss) / I64.to_f32(peak) * bars_h
				vc = verdict(I64.to_f32(x.w.ramp10) / 10.0)
				hovered = model.mouse_x >= cx - slot / 2.0 and model.mouse_x < cx + slot / 2.0 and model.mouse_y >= bars_top - 44.0 and model.mouse_y <= bars_bot
				body = if hovered (250.U8) else 220
				top_y = bars_bot - bh
				if bh > 3.0 {
					frame.rounded_rectangle!({ x: x0, y: top_y, width: bw, height: bh, radius: 7.0, segments: 5, style: Draw.filled(Color.with_alpha(Theme.ctl_c, body)) })
					# depth: the bar darkens toward its base, below the rounded cap
					frame.rectangle_gradient_v!({ x: x0, y: top_y + 8.0, width: bw, height: bh - 8.0, color_top: Color.with_alpha(Theme.bg, 0), color_bottom: Color.with_alpha(Theme.bg, 120) })
				} else {
					frame.rounded_rectangle!({ x: x0, y: bars_bot - 3.0, width: bw, height: 3.0, radius: 1.5, segments: 3, style: Draw.filled(Color.with_alpha(ink_faint, 90)) })
				}
				# the ramp chip rides above its bar, never above the panel
				chip_y = F32.max(bars_top - 30.0, top_y - 30.0)
				frame.rounded_rectangle!({ x: cx - 27.0, y: chip_y, width: 54.0, height: 20.0, radius: 6.0, segments: 5, style: Draw.filled(Color.with_alpha(vc, if hovered (70.U8) else 42)) })
				Text.from(tenths(x.w.ramp10), model.font).size(11).draw!(frame, { pos: { x: cx, y: chip_y + 4.0 }, color: vc, align: (Top, Center) })
				if x.i % 2 == 0 {
					Text.from(Str.from_utf8_lossy(List.drop_first(Str.to_utf8(x.w.wk), 5)), model.font).size(10).draw!(frame, { pos: { x: cx, y: bars_bot + 10.0 }, color: ink_faint, align: (Top, Center) })
				} else {}
				if hovered {
					Text.from("wk of ${x.w.wk}   ${I64.to_str(x.w.tss)} tss   ctl ${I64.to_str(x.w.ctl10 // 10)}.${I64.to_str(I64.abs(x.w.ctl10) % 10)}   ramp ${tenths(x.w.ramp10)}/wk", model.font).size(12).draw!(frame, { pos: { x: pad, y: 96.0 }, color: Color.white, align: (Top, Left) })
				} else {}
			})
			{}
		}
		model.ramp_hint.draw!(frame, { pos: { x: pad, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
