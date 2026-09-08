import rr.Color
import rr.Draw
import rr.Text
import Db
import Theme
import Ui

Board :: [].{
	lo_of : List(Db.Point) -> F32
	lo_of = |pts| List.fold(pts, 0.0, |acc, p| F32.min(acc, p.tsb)) - 6.0
	hi_of : List(Db.Point) -> F32
	hi_of = |pts| List.fold(pts, 1.0, |acc, p| F32.max(acc, F32.max(p.ctl, p.atl))) + 8.0

	clamp_idx : F32, U64 -> U64
	clamp_idx = |raw, hi_idx|
		if raw <= 0.0 (0.U64)
		else match F32.round_to_u64_try(raw) {
			Ok(i) => if i >= hi_idx (hi_idx) else i
			Err(_) => hi_idx
		}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = Theme.win_w
		win_h = Theme.win_h
		pad_l = Theme.pad_l
		pad_r = Theme.pad_r
		# +56 makes room for the KPI tile row this view alone carries
		pad_t = Theme.pad_t + 56.0
		pad_b = Theme.pad_b
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		ctl_c = Theme.ctl_c
		atl_c = Theme.atl_c
		tsb_c = Theme.tsb_c
	# the artifact's tile cards: a lifted rounded panel behind each number
	List.for_each!([0.U64, 1, 2, 3], |i| {
		cx0 = 30.0 + U64.to_f32(i) * 234.0
		frame.rounded_rectangle!({ x: cx0, y: 88.0, width: 222.0, height: 62.0, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
	})
	List.for_each!(List.map_with_index(model.kpis, |k, i| { k, i }), |x| {
		tx0 = 42.0 + U64.to_f32(x.i) * 234.0
		col = if x.k.sel == 0 ctl_c else if x.k.sel == 1 atl_c else tsb_c
		x.k.v.draw!(frame, { pos: { x: tx0, y: 94.0 }, color: col, align: (Top, Left) })
		x.k.cap.draw!(frame, { pos: { x: tx0, y: 127.0 }, color: ink_faint, align: (Top, Left) })
	})
	model.ev_tile_top.draw!(frame, { pos: { x: 744.0, y: 96.0 }, color: ink_muted, align: (Top, Left) })
	model.ev_tile_sub.draw!(frame, { pos: { x: 744.0, y: 122.0 }, color: ink_faint, align: (Top, Left) })
	if model.ridden_found {
		model.ridden_note.draw!(frame, { pos: { x: 744.0, y: 136.0 }, color: ink_faint, align: (Top, Left) })
	} else {}
	# which range is live: three chips, the active one filled
	List.for_each!(List.map_with_index(model.subs, |s, i| { s, i }), |x| {
		chx = 560.0 + U64.to_f32(x.i) * 54.0
		on = x.s.r == model.range
		style = if on (Draw.filled(Color.with_alpha(ctl_c, 60))) else Draw.filled(Theme.card)
		frame.rounded_rectangle!({ x: chx, y: 64.0, width: 46.0, height: 22.0, radius: 6.0, segments: 6, style })
		x.s.chip.draw!(frame, { pos: { x: chx + 23.0, y: 68.0 }, color: if on Color.white else ink_muted, align: (Top, Center) })
	})
	List.for_each!(model.subs, |s|
		if s.r == model.range and model.view == 0 {
			s.p.draw!(frame, { pos: { x: 280.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		} else {})

	if model.ev_warn_found {
		model.ev_warn.draw!(frame, { pos: { x: 940.0, y: 52.0 }, color: atl_c, align: (Top, Right) })
	} else {}
	if model.stale_found {
		model.stale.draw!(frame, { pos: { x: 940.0, y: 34.0 }, color: ink_faint, align: (Top, Right) })
	} else {}

		if model.has_error {
			model.status.draw!(frame, { pos: { x: 36.0, y: pad_t + 20.0 }, color: atl_c, align: (Top, Left) })
			Ok({})
		} else if List.len(model.data) < 2 {
			model.empty.draw!(frame, { pos: { x: 36.0, y: pad_t + 20.0 }, color: ink_muted, align: (Top, Left) })
			Ok({})
		} else {
			full = model.data
			take = U64.min(model.range, List.len(full))
			data = List.take_last(full, take)
			lo = lo_of(data)
			hi = hi_of(data)
			n = List.len(data)
			span = hi - lo
			pw = I32.to_f32(win_w) - pad_l - pad_r
			ph = I32.to_f32(win_h) - pad_t - pad_b
			xf = |i| pad_l + pw * U64.to_f32(i) / U64.to_f32(n - 1)
			yf = |v| pad_t + ph * (1.0 - (v - lo) / span)

			# grid + y labels
			# only the gridlines the computed range actually contains — the prepared
			# set spans -30..100, which covers the common PMC window; a value
			# outside it plots fine but gets no gridline
			List.for_each!(model.ylabels, |yl|
				if yl.v >= lo and yl.v <= hi {
					gy = yf(yl.v)
					frame.line!({ start: { x: pad_l, y: gy }, end: { x: I32.to_f32(win_w) - pad_r, y: gy }, stroke: Draw.stroke(Color.with_alpha(Color.white, 18), 1) })
					yl.p.draw!(frame, { pos: { x: 30.0, y: gy - 8.0 }, color: ink_faint, align: (Top, Left) })
				} else {})
			frame.line!({ start: { x: pad_l, y: yf(0.0) }, end: { x: I32.to_f32(win_w) - pad_r, y: yf(0.0) }, stroke: Draw.stroke(Color.with_alpha(Color.white, 55), 1) })
			model.zero_note.draw!(frame, { pos: { x: I32.to_f32(win_w) - pad_r - 6.0, y: yf(0.0) - 16.0 }, color: ink_faint, align: (Top, Right) })

			# daily load (TSS) as a faint rug in its OWN scale along the bottom band,
			# never on the fitness/form axis: load peaks well above 50 and would
			# rocket off the top if it shared the axis (two measures, one axis = wrong).
			bw = F32.max(1.5, pw / U64.to_f32(n) - 1.4)
			tss_max = F32.max(1.0, List.fold(data, 1.0, |acc, p| F32.max(acc, p.tss)))
			rug_base = pad_t + ph
			rug_band = ph * 0.22
			List.for_each!(List.map_with_index(data, |p, i| { i, s: p.tss }), |c|
				if c.s > 0.0 {
					bh = (c.s / tss_max) * rug_band
					frame.rectangle!({ x: xf(c.i) - bw / 2.0, y: rug_base - bh, width: bw, height: bh, style: Draw.filled(Color.with_alpha(ink_muted, 55)) })
				} else {})

			# soft fill under fitness
			List.for_each!(List.map_with_index(data, |p, i| { i, v: p.ctl }), |cur|
				match List.get(data, cur.i + 1) {
					Ok(_) => frame.rectangle!({ x: xf(cur.i), y: yf(cur.v), width: (pw / U64.to_f32(n - 1)) + 1.0, height: yf(0.0) - yf(cur.v), style: Draw.filled(Color.with_alpha(ctl_c, 12)) })
					Err(_) => {}
				})

			# event marker: dashed vertical + label. ev_idx indexes the full series,
			# so shift it by however many days the range switch sliced off the front.
			off = List.len(full) - n
			if model.ev_found and model.ev_idx >= off {
				ex = xf(model.ev_idx - off)
				List.for_each!(List.map_with_index(List.repeat({}, 40), |_u, k| k), |k| {
					y0 = pad_t + U64.to_f32(k) * 12.0
					if y0 + 6.0 <= pad_t + ph {
						frame.line!({ start: { x: ex, y: y0 }, end: { x: ex, y: y0 + 6.0 }, stroke: Draw.stroke(Color.with_alpha(Color.white, 70), 1) })
					} else {}
				})
				model.ev_label.draw!(frame, { pos: { x: ex - 6.0, y: pad_t + 4.0 }, color: ink_muted, align: (Top, Right) })
			} else {}

			draw_line! = |sel, col| {
				pts = List.map_with_index(data, |p, i| { i, v: sel(p) })
				List.for_each!(pts, |cur|
					match List.get(pts, cur.i + 1) {
						Ok(nxt) => frame.line!({ start: { x: xf(cur.i), y: yf(cur.v) }, end: { x: xf(nxt.i), y: yf(nxt.v) }, stroke: Draw.stroke(col, 2) })
						Err(_) => {}
					})
			}
			draw_line!(|p| p.tsb, tsb_c)
			draw_line!(|p| p.atl, atl_c)
			draw_line!(|p| p.ctl, ctl_c)

			# current-value labels at the line ends
			last = match List.last(data) {
				Ok(l) => l
				Err(_) => { ctl: 0.0, atl: 0.0, tsb: 0.0, tss: 0.0 }
			}
			ex2 = I32.to_f32(win_w) - pad_r + 8.0
			List.for_each!(model.ends, |e| {
				v = if e.sel == 0 last.ctl else if e.sel == 1 last.atl else last.tsb
				col = if e.sel == 0 ctl_c else if e.sel == 1 atl_c else tsb_c
				e.p.draw!(frame, { pos: { x: ex2, y: yf(v) - 7.0 }, color: col, align: (Top, Left) })
			})

			# hover OR arrow-cursor: the selected day gets a crosshair + dots, and
			# its values print top-right as immediate text (the only dynamic string
			# drawn per frame). Mouse wins while it is inside the plot; the arrow
			# cursor counts days back from the latest.
			hi_idx = n - 1
			mouse_sel = model.mouse_in and model.mouse_x >= pad_l and model.mouse_x <= I32.to_f32(win_w) - pad_r
			cur_back = if model.cursor < 0 (0.U64) else match I64.to_u64_try(model.cursor) {
				Ok(c) => if c > hi_idx (hi_idx) else c
				Err(_) => 0.U64
			}
			if mouse_sel or model.cursor >= 0 {
				hovered =
					if mouse_sel {
						frac = (model.mouse_x - pad_l) / pw
						raw = frac * U64.to_f32(hi_idx)
						clamp_idx(raw, hi_idx)
					} else hi_idx - cur_back
				hx = xf(hovered)
				frame.line!({ start: { x: hx, y: pad_t }, end: { x: hx, y: pad_t + ph }, stroke: Draw.stroke(Color.with_alpha(Color.white, 60), 1) })
				match List.get(data, hovered) {
					Ok(hp) => {
						frame.circle!({ center: { x: hx, y: yf(hp.ctl) }, radius: 3.5, style: Draw.filled(ctl_c) })
						frame.circle!({ center: { x: hx, y: yf(hp.atl) }, radius: 3.5, style: Draw.filled(atl_c) })
						frame.circle!({ center: { x: hx, y: yf(hp.tsb) }, radius: 3.5, style: Draw.filled(tsb_c) })
						day = match List.get(List.take_last(model.days, take), hovered) {
							Ok(d) => d
							Err(_) => ""
						}
						# the artifact's tooltip: a small card beside the crosshair,
						# flipped left when the cursor nears the right edge
						readout = "${day}  CTL ${Db.fmt_f(hp.ctl)}  ATL ${Db.fmt_f(hp.atl)}  TSB ${Db.fmt_f(hp.tsb)}  TSS ${Db.fmt_f(hp.tss)}"
						tip_w = 372.0
						tip_x = if hx + 14.0 + tip_w > I32.to_f32(win_w) - pad_r (hx - 14.0 - tip_w) else hx + 14.0
						frame.rounded_rectangle!({ x: tip_x, y: pad_t + 8.0, width: tip_w, height: 26.0, radius: 6.0, segments: 6, style: Draw.filled(Theme.card) })
						Text.from(readout, model.font).size(13).draw!(frame, { pos: { x: tip_x + 10.0, y: pad_t + 14.0 }, color: Color.white, align: (Top, Left) })
					}
					Err(_) => {}
				}
			} else {}

			model.hint.draw!(frame, { pos: { x: 34.0, y: I32.to_f32(win_h) - 30.0 }, color: ink_faint, align: (Top, Left) })
			Ok({})
		}
	}
}
