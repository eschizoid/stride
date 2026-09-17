import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Career :: [].{
	# The whole story: every month since the first session, assembled in the
	# order it happened. The spine is the month-close threshold of whichever
	# family the athlete trains most (monthly_threshold) - watts for a power
	# family, metres per second for a pace one, so the line rises with fitness
	# either way and only its LABELS change. Deliberately not season's ftp_end,
	# which is a family-weighted daily fold with its own body in ReportSeason.
	# The ground is monthly load; year bands give the axis its eras. A comet rides the spine on arrival and the header
	# digits rack up beneath it - the reveal animates, the values never do:
	# every drawn height and position is the datum, only WHEN it appears is
	# staged. Tick-driven throughout so the V-key recording stays regenerable.
	pad : F32
	pad = 64.0

	# the arrival sweep, in ticks: five years wants longer than the form
	# board's half second, and any click completes it (main.roc zeroes
	# view_anim, whose zero means "settled" everywhere)
	dur : F32
	dur = 120.0

	# eased progress through the sweep: 0 at arrival, 1 settled
	progress : Ui.Model -> F32
	progress = |model| {
		age = model.tick - model.view_anim
		if model.view_anim == 0 or U64.to_f32(age) >= dur (1.0)
		else {
			p = U64.to_f32(age) / dur
			1.0 - (1.0 - p) * (1.0 - p)
		}
	}

	# the distance a pace family reads its threshold over: rowers speak
	# seconds per 500m, runners per kilometre, swimmers per 100m. Anything
	# else falls to the kilometre - a wrong UNIT is visible, a wrong number
	# would not be.
	pace_unit : Str -> { d : F32, label : Str }
	pace_unit = |fam|
		if fam == "Rowing" ({ d: 500.0, label: "/500m" })
		else if fam == "Swim" ({ d: 100.0, label: "/100m" })
		else { d: 1000.0, label: "/km" }

	# a spine value in tenths, in its family's own units. Power reads as
	# watts; pace converts the stored SPEED to time over the family's
	# distance, which is what an athlete in that sport actually says.
	spine_label : I64, Str, Str -> Str
	spine_label = |v10, kind, fam|
		if kind == "power" "${I64.to_str(v10 // 10)}w"
		else {
			spd = I64.to_f32(v10) / 10.0
			u = pace_unit(fam)
			secs = if spd <= 0.0 (0.0) else u.d / spd
			total = match F32.to_i64_try(secs) { Ok(x) => x
				Err(_) => 0 }
			mm = total // 60
			ss = total % 60
			"${I64.to_str(mm)}:${if ss < 10 "0" else ""}${I64.to_str(ss)}"
		}

	# one KPI card: a racked-up value, its unit, its caption
	card! : Draw.Frame, Text.Font, F32, F32, Str, Str => {}
	card! = |frame, font, x, y, value, caption| {
		frame.rounded_rectangle!({ x, y, width: 196.0, height: 64.0, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
		Text.from(value, font).size(22).draw!(frame, { pos: { x: x + 16.0, y: y + 10.0 }, color: Color.white, align: (Top, Left) })
		Text.from(caption, font).size(11).draw!(frame, { pos: { x: x + 16.0, y: y + 42.0 }, color: Theme.ink_faint, align: (Top, Left) })
		{}
	}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		# the arc on screen is one of the loaded families; F cycles them, so an
		# athlete who rides AND rows sees each story rather than only the one
		# they have trained longest
		nspines = List.len(model.career_spines)
		cur = match List.get(model.career_spines, (if nspines == 0 (0) else model.spine_idx % nspines)) {
			Ok(c) => c
			Err(_) => { fam: "", kind: "", rows: [] }
		}
		months = cur.rows
		n = List.len(months)
		sp = { fam: cur.fam, kind: cur.kind }
		unit_note = if sp.kind == "power" "threshold watts" else "threshold pace${pace_unit(sp.fam).label}"
		switch_note = if nspines > 1 "   F  next sport" else ""
		subtitle = if sp.fam == "" "career - every month since the first session" else "career - ${Str.with_ascii_lowercased(sp.fam)} ${unit_note}${switch_note}"
		Text.from(subtitle, model.font).size(14).draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		if n < 2 {
			Text.from("no history yet - sync, analyze, and come back", model.font).size(14).draw!(frame, { pos: { x: 36.0, y: 130.0 }, color: ink_muted, align: (Top, Left) })
		} else {
			p = progress(model)

			# ── header: the career racking up. The final figures are the true
			# ones; the count-up is the feeling of accumulation, nothing else.
			tot = List.fold(model.career_sports, { h10: 0.I64, km: 0.I64, ss: 0.I64 }, |a, s| { h10: a.h10 + s.hours10, km: a.km + s.km, ss: a.ss + s.sessions })
			ease_i = |v| match F32.to_i64_try(I64.to_f32(v) * p) { Ok(x) => x
				Err(_) => v }
			cw = 196.0
			gap = (win_w - 72.0 - cw * 4.0) / 3.0
			cx0 = |i| 36.0 + I64.to_f32(i) * (cw + gap)
			card!(frame, model.font, cx0(0), 96.0, "${I64.to_str(ease_i(tot.h10) // 10)}h", "moving time")
			card!(frame, model.font, cx0(1), 96.0, "${I64.to_str(ease_i(tot.km))} km", "distance")
			card!(frame, model.font, cx0(2), 96.0, I64.to_str(ease_i(tot.ss)), "sessions")
			card!(frame, model.font, cx0(3), 96.0, I64.to_str(ease_i(match U64.to_i64_try(n) { Ok(v) => v
				Err(_) => 0 })), "months trained")

			# ── geometry: months on x, the spine value on the one y axis
			plot_l = pad
			plot_r = win_w - Theme.pad_r
			plot_w = plot_r - plot_l
			line_top = 208.0
			line_bot = win_h - 176.0
			bars_top = win_h - 168.0
			bars_bot = win_h - 92.0
			nf = U64.to_f32(n)
			# the camera pulls back: early in the sweep the axis frames only the
			# months that have arrived, and widens to the true full range as more
			# do. It MUST land exactly on the full range - the settled view is
			# the honest one, and a camera still moving at rest would misreport
			# the x axis. The floor keeps a two-month career from filling the
			# window at one bar per screen.
			shown = (nf * p).max(8.0).min(nf)
			xf = |i| plot_l + (U64.to_f32(i) + 0.5) / shown * plot_w
			head_x = plot_l + (if shown >= nf (p) else 1.0) * plot_w

			# spine scale from the measured points only; 0 means that family had
			# no scored session that month
			fmax = List.fold(months, 0.I64, |a, m| if m.ftp10 > a m.ftp10 else a)
			fmin = List.fold(months, fmax, |a, m| if m.ftp10 > 0 and m.ftp10 < a m.ftp10 else a)
			frange = (I64.to_f32(fmax - fmin)).max(10.0)
			yf = |f10| line_bot - (I64.to_f32(f10 - fmin) / frange) * (line_bot - line_top)
			lmax = List.fold(months, 1.I64, |a, m| if m.load > a m.load else a)

			# faint gridlines at the quarter marks, labeled in the family's units
			List.for_each!([0.0, 0.25, 0.5, 0.75, 1.0], |q| {
				gy = line_bot - q * (line_bot - line_top)
				frame.line!({ start: { x: plot_l, y: gy }, end: { x: plot_r, y: gy }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 40), 1) })
				w = fmin + (match F32.to_i64_try(q * I64.to_f32(fmax - fmin)) { Ok(v) => v
					Err(_) => 0 })
				Text.from(spine_label(w, sp.kind, sp.fam), model.font).size(10).draw!(frame, { pos: { x: plot_l - 8.0, y: gy - 5.0 }, color: ink_faint, align: (Top, Right) })
			})

			# ── year bands rise from the baseline as the head crosses into them.
			# A label draws only when it clears the last one by 42px, so a short
			# early year (a first December alone) does not collide with the
			# January beside it - the tick still rises, only the text is held.
			idx = List.map_with_index(months, |m, i| { m, i })
			_ = List.fold_try!(idx, -999.0, |last_x, x| {
				yr = Str.from_utf8_lossy(List.take_first(Str.to_utf8(x.m.month), 4))
				prev_yr = match List.get(months, (if x.i == 0 0 else x.i - 1)) {
					Ok(pm) => Str.from_utf8_lossy(List.take_first(Str.to_utf8(pm.month), 4))
					Err(_) => ""
				}
				if x.i == 0 or yr != prev_yr {
					bx = xf(x.i) - 0.5 / nf * plot_w
					reached = head_x >= bx
					rise = if p >= 1.0 (1.0) else if reached ((((head_x - bx) / plot_w) * 6.0).min(1.0)) else 0.0
					if rise > 0.0 {
						frame.line!({ start: { x: bx, y: bars_bot + 4.0 }, end: { x: bx, y: bars_bot + 4.0 - 10.0 * rise }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 120), 1) })
						if bx - last_x >= 42.0 {
							Text.from(yr, model.font).size(10).draw!(frame, { pos: { x: bx + 4.0, y: bars_bot + 8.0 }, color: Color.with_alpha(ink_muted, (match F32.to_u8_try(200.0 * rise) { Ok(a) => a
								Err(_) => 200 })), align: (Top, Left) })
							Ok(bx)
						} else Ok(last_x)
					} else Ok(last_x)
				} else Ok(last_x)
			})

			# ── monthly load: the recessive ground. partial renders as a dim
			# fill under a bright top edge - a month in progress must never
			# read as a collapse
			bw = (plot_w / nf - 1.5).max(1.0)
			List.for_each!(idx, |x| {
				bx = xf(x.i) - bw / 2.0
				reached = head_x >= bx
				rise = if p >= 1.0 (1.0) else if reached ((((head_x - bx) / plot_w) * 5.0).min(1.0)) else 0.0
				bh = (I64.to_f32(x.m.load) / I64.to_f32(lmax)) * (bars_bot - bars_top) * rise
				if bh > 0.5 {
					if x.m.partial {
						frame.rectangle!({ x: bx, y: bars_bot - bh, width: bw, height: bh, style: Draw.filled(Color.with_alpha(Theme.ctl_c, 45)) })
						frame.line!({ start: { x: bx, y: bars_bot - bh }, end: { x: bx + bw, y: bars_bot - bh }, stroke: Draw.stroke(Color.with_alpha(Theme.ctl_c, 200), 2) })
					} else {
						frame.rectangle!({ x: bx, y: bars_bot - bh, width: bw, height: bh, style: Draw.filled(Color.with_alpha(Theme.ctl_c, 90)) })
					}
				} else {}
			})

			# ── the spine: month-close FTP, drawn only between measured
			# neighbors - a gap is the engine saying "not measured", and a
			# line across it would invent the value
			List.for_each!(idx, |x| {
				if x.i + 1 < n {
					match List.get(months, x.i + 1) {
						Ok(nxt) =>
							if x.m.ftp10 > 0 and nxt.ftp10 > 0 and xf(x.i + 1) <= head_x {
								frame.line!({ start: { x: xf(x.i), y: yf(x.m.ftp10) }, end: { x: xf(x.i + 1), y: yf(nxt.ftp10) }, stroke: Draw.stroke(Theme.ctl_c, 2) })
							} else {}
						Err(_) => {}
					}
				} else {}
			})

			# ── milestones: the valley, the peak, and today, each punching in
			# as the head passes. The ring and the late arrival are staging;
			# the positions and the watts are data.
			last_known = List.fold(idx, { i: 0.U64, f: 0.I64 }, |a, x| if x.m.ftp10 > 0 { i: x.i, f: x.m.ftp10 } else a)
			valley = List.fold(idx, { i: 0.U64, f: fmax }, |a, x| if x.m.ftp10 > 0 and x.m.ftp10 <= a.f { i: x.i, f: x.m.ftp10 } else a)
			peak = List.fold(idx, { i: 0.U64, f: 0.I64 }, |a, x| if x.m.ftp10 >= a.f and x.m.ftp10 > 0 { i: x.i, f: x.m.ftp10 } else a)
			mark! = |mi, mf, col, tag| {
				mx = xf(mi)
				if mx <= head_x and mf > 0 {
					# the ring is a one-shot pulse: it MUST reach 1.0 (fully
					# faded) on settle, or a milestone near the right edge - the
					# head never travels far past it - keeps a permanent halo
					age_past = ((head_x - mx) / plot_w) * dur
					ring = if p >= 1.0 (1.0) else (age_past / 14.0).min(1.0)
					frame.circle!({ center: { x: mx, y: yf(mf) }, radius: 3.0 + 9.0 * ring, style: Draw.filled(Color.with_alpha(col, (match F32.to_u8_try(90.0 * (1.0 - ring)) { Ok(a) => a
						Err(_) => 0 }))) })
					frame.circle!({ center: { x: mx, y: yf(mf) }, radius: 3.5, style: Draw.filled(col) })
					lift = if tag == "valley" (18.0) else -24.0
					Text.from(spine_label(mf, sp.kind, sp.fam), model.font).size(13).draw!(frame, { pos: { x: mx, y: yf(mf) + lift }, color: col, align: (Top, Center) })
				} else {}
				{}
			}
			mark!(valley.i, valley.f, Theme.alarm_c, "valley")
			mark!(peak.i, peak.f, Theme.tsb_c, "peak")
			if last_known.i != peak.i and last_known.i != valley.i {
				mark!(last_known.i, last_known.f, Theme.ctl_c, "today")
			} else {}

			# ── the comet: a bright head riding the spine, halo fading behind
			# it. Gone when settled - the finished view is a chart, not a show.
			if p < 1.0 {
				head_f = List.fold(idx, 0.I64, |a, x| if x.m.ftp10 > 0 and xf(x.i) <= head_x x.m.ftp10 else a)
				if head_f > 0 {
					hy = yf(head_f)
					frame.circle!({ center: { x: head_x, y: hy }, radius: 10.0, style: Draw.filled(Color.with_alpha(Color.white, 26)) })
					frame.circle!({ center: { x: head_x, y: hy }, radius: 6.0, style: Draw.filled(Color.with_alpha(Theme.ctl_c, 120)) })
					frame.circle!({ center: { x: head_x, y: hy }, radius: 3.0, style: Draw.filled(Color.white) })
				} else {}
			} else {}

			# ── composition: one stacked bar of every sport by session count,
			# widest first, filling as the sweep runs. Segments narrower than a
			# label keep their colour and lose their text - the bar still totals
			# the whole career either way. Never a pie: an angle is harder to
			# compare than a length.
			comp_y = win_h - 66.0
			comp_w = plot_r - 36.0
			tot_ss = List.fold(model.career_sports, 0.I64, |a, s| a + s.sessions)
			if tot_ss > 0 {
				_ = List.fold_try!(List.map_with_index(model.career_sports, |s, i| { s, i }), 36.0, |x0, y| {
					seg = I64.to_f32(y.s.sessions) / I64.to_f32(tot_ss) * comp_w * p
					col = match List.get(Theme.zone_ramp, y.i % 5) { Ok(c) => c
						Err(_) => ink_faint }
					if seg > 1.0 {
						frame.rounded_rectangle!({ x: x0, y: comp_y, width: (seg - 1.5).max(1.0), height: 12.0, radius: 3.0, segments: 3, style: Draw.filled(Color.with_alpha(col, 190)) })
						if seg > 64.0 {
							Text.from("${y.s.sport} ${I64.to_str(y.s.sessions)}", model.font).size(10).draw!(frame, { pos: { x: x0 + 6.0, y: comp_y + 15.0 }, color: Color.with_alpha(col, 220), align: (Top, Left) })
						} else {}
					} else {}
					Ok(x0 + seg)
				})
			} else {}
		}
		Text.from("click to settle   F  sport   TAB  form board   R  reload   S  screenshot   ESC  quit", model.font).size(13).draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
