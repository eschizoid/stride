import rr.Color
import rr.Draw
import Theme
import Ui

Curve :: [].{
	# ── power-curve view (TAB) ──────────────────────────────────────────────
	# Log-x, because the ladder spans 5s to 20min: on a linear axis the six
	# short rungs collapse onto the left edge and the chart shows one point.
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
		if List.is_empty(model.curve) {
			model.curve_empty.draw!(frame, { pos: { x: 36.0, y: 120.0 }, color: ink_muted, align: (Top, Left) })
			model.curve_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		} else {
			pw = win_w - pad_l - pad_r
			ph = win_h - pad_t - pad_b
			w_hi = List.fold(model.curve, 1.0, |a, c| F32.max(a, c.watts)) * 1.08
			# Rungs are evenly spaced by INDEX, not by duration: the ladder is a
			# fixed 5s..20min set, and a linear time axis would pile the six short
			# rungs onto the left edge. Index spacing keeps every rung readable and
			# its label under it.
			nlast = List.len(model.curve) - 1
			cx = |i| if nlast == 0 (pad_l + pw / 2.0) else pad_l + pw * U64.to_f32(i) / U64.to_f32(nlast)
			cy = |w| pad_t + ph * (1.0 - w / w_hi)
			# CP as a horizontal line: the curve should flatten toward it, and a fit
			# drawn far from the long rungs is visibly wrong — which is the whole
			# reason #372 wanted this view rather than the table.
			if model.fit_cp > 0.0 and model.fit_cp < w_hi {
				cpy = cy(model.fit_cp)
				List.for_each!(List.map_with_index(List.repeat({}, 60), |_u, k| k), |k| {
					x0 = pad_l + U64.to_f32(k) * (pw / 60.0)
					frame.line!({ start: { x: x0, y: cpy }, end: { x: x0 + pw / 120.0, y: cpy }, stroke: Draw.stroke(Color.with_alpha(tsb_c, 120), 1.0) })
				})
				model.cp_lbl.draw!(frame, { pos: { x: pad_l + pw + 8.0, y: cpy }, color: tsb_c, align: (Middle, Left) })
			} else {}
			rungs = List.map_with_index(model.curve, |c, i| { c, i })
			List.for_each!(rungs, |x|
				match List.get(rungs, x.i + 1) {
					Ok(nxt) => frame.line!({ start: { x: cx(x.i), y: cy(x.c.watts) }, end: { x: cx(nxt.i), y: cy(nxt.c.watts) }, stroke: Draw.stroke(Color.with_alpha(ctl_c, 150), 2) })
					Err(_) => {}
				})
			List.for_each!(rungs, |x| {
				frame.circle!({ center: { x: cx(x.i), y: cy(x.c.watts) }, radius: 4.0, style: Draw.filled(ctl_c) })
			})
			List.for_each!(List.map_with_index(model.curve_lbls, |l, i| { l, i }), |x| {
				x.l.p.draw!(frame, { pos: { x: cx(x.i), y: pad_t + ph - 18.0 }, color: ink_faint, align: (Top, Center) })
			})
			model.curve_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		}
	}
}
