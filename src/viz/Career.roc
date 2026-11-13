import rr.Color
import rr.Draw
import rr.Text
import core.Fmt
import core.Sports
import core.Units
import Chrome
import Db
import Hud
import Labels
import Scene
import Theme
import Ui

Career :: [].{
	# The whole story: every month since the first session, in the order it
	# happened. The spine is the month-close threshold of the selected family
	# (monthly_threshold): watts for a power family, metres per second for a
	# pace one, so the line rises with fitness either way and only its LABELS
	# change. It is not season's ftp_end, which is a family-weighted daily fold
	# with its own body in ReportSeason. The ground is monthly load, and year
	# bands give the axis its eras. A comet rides the spine on arrival and the
	# header digits rack up beneath it: the reveal animates, the values never
	# do. Every drawn height and position is the datum; only WHEN it appears is
	# staged. Tick-driven throughout, so a V-key recording is regenerable.
	pad : F32
	pad = 64.0

	# the arrival sweep, in ticks: five years wants longer than the form
	# board's half second, and any click completes it (main.roc zeroes
	# view_anim, whose zero means "settled" everywhere). A capture of this
	# view waits the whole sweep out (main.roc's settle_ticks).
	sweep_ticks : U64
	sweep_ticks = 120

	dur : F32
	dur = U64.to_f32(sweep_ticks)

	# eased progress through the sweep: 0 at arrival, 1 settled
	progress : Ui.Model -> F32
	progress = |model| {
		age = model.tick - model.view_anim
		if (model.view_anim == 0 or U64.to_f32(age) >= dur) (1.0)
		else {
			p = U64.to_f32(age) / dur
			1.0 - (1.0 - p) * (1.0 - p)
		}
	}

	# the spine F has cycled to: the index wraps over the families the
	# athlete has, so the renderer and the focus row name the same one at
	# every press; none when the athlete has no family at all
	spine_at : List(Db.CareerSpine), U64 -> Db.CareerSpine
	spine_at = |spines, idx| {
		n = List.len(spines)
		match List.get(spines, (if (n == 0) 0 else idx % n)) {
			Ok(c) => c
			Err(_) => { fam: "", kind: "", rows: [] }
		}
	}

	# a spine value in tenths, in its family's own units - and, for the
	# kilometre family, the ATHLETE's units. Power reads as watts; pace
	# converts the stored SPEED to time over the family's distance, which is
	# what an athlete in that sport actually says. The km family goes through
	# Units.pace_from_speed - the same body the CLI renders with, so the two
	# surfaces cannot disagree on a label by a rounding mode or a constant -
	# and the fixed-distance families round the same way beside it.
	# Tonnage is mass lifted in a month (kg, from strength_sets): under a
	# tonne it reads as whole kg, above as tonnes to one decimal - integer
	# arithmetic on the tenths-of-kg value, so no float rounding mode can
	# disagree between the axis and the peak label.
	spine_label : [Metric, Imperial], I64, Str, Str -> Str
	spine_label = |units, v10, kind, fam|
		if (kind == "power") "${I64.to_str(v10 // 10)}w"
		else if kind == "tonnage" {
			kg = v10 // 10
			if (kg < 1000) "${I64.to_str(kg)}kg"
			else {
				tenths_t = (v10 + 500) // 1000
				"${I64.to_str(tenths_t // 10)}.${I64.to_str(tenths_t % 10)}t"
			}
		}
		else {
			spd = I64.to_f64(v10) / 10.0
			if fam == "Rowing" or fam == "Swim" {
				u = Sports.pace_unit(fam)
				if (spd <= 0.0) "-" else Fmt.mmss((I64.to_f64(u.dist_m) / spd).round_to_i64_try().ok_or(0))
			} else {
				Units.pace_from_speed(units, spd)
			}
		}

	# The tangent at one month for a MONOTONE cubic (Fritsch-Carlson), in
	# spine-units per month. A Catmull-Rom curve overshoots its own control
	# points, so a smooth line through two months can bulge above the
	# higher one and draw a threshold the athlete never held. This flattens
	# the tangent at every local extremum and limits it to three times the
	# smaller neighbouring slope, which is exactly the condition that keeps
	# the curve inside the data.
	tangent : List(Ui.SpinePt), U64 -> F32
	tangent = |pts, i| {
		at = |k| match List.get(pts, k) {
			Ok(v) => v
			Err(_) => { x: 0.0, y: 0.0, ok: Bool.False }
		}
		here = at(i)
		prev = if (i == 0) here else at(i - 1)
		next = at(i + 1)
		has_prev = i > 0 and prev.ok
		has_next = next.ok
		d_prev = if (has_prev) (here.y - prev.y) else 0.0
		d_next = if (has_next) (next.y - here.y) else 0.0
		# a missing neighbour makes this an endpoint of its run, so the
		# tangent is one-sided. A FLAT neighbouring segment is different:
		# Fritsch-Carlson requires a zero tangent there, or the cubic
		# between two equal values bulges above the plateau and draws an
		# apex the athlete never reached.
		if (!has_prev) (d_next)
		else if (!has_next) (d_prev)
		else if (d_prev == 0.0 or d_next == 0.0) (0.0)
		else if (d_prev * d_next < 0.0) (0.0)
		else {
			m = (d_prev + d_next) / 2.0
			lim = 3.0 * (d_prev).abs().min((d_next).abs())
			if ((m).abs() > lim) ((if (m < 0.0) (-1.0) else 1.0) * lim) else m
		}
	}
	# career_totals groups by sport_type; the composition bar wants FAMILIES,
	# so members are merged on Sports.canonical and the result re-sorted
	# widest-first. The fold pins a family to where its LARGEST member first
	# appeared and only adds to it afterwards, so without the sort a family
	# split evenly across two members could finish larger than one that sat
	# between them and still draw behind it.
	fold_families : List(Db.CareerSport) -> List({ sport : Str, sessions : I64 })
	fold_families = |sports| {
		folded = List.fold(
			sports,
			[],
			|acc, s| {
				c = Sports.canonical(s.sport)
				if List.is_empty(List.keep_if(acc, |x| x.sport == c)) {
					List.append(acc, { sport: c, sessions: s.sessions })
				} else {
					List.map(acc, |x| if (x.sport == c) ({ ..x, sessions: x.sessions + s.sessions }) else x)
				}
			},
		)
		List.sort_with(folded, |a, b| b.sessions.order_relative_to(a.sessions))
	}

	# the share of all sessions, in percent, under which a family is too
	# narrow to read as its own segment of the composition strip
	strip_min_pct : I64
	strip_min_pct = 2

	# the narrowest segment the strip draws, so the smallest family is still
	# a swatch the pointer can find rather than a hairline
	strip_min_w : F32
	strip_min_w = 8.0

	# the strip's segments: families at or above strip_min_pct keep their
	# own segment in the order given; two or more below it fold into one
	# `other` segment at the end. A single small family keeps its own name,
	# since folding one family into `other` would only hide which it is.
	strip_segments : List({ sport : Str, sessions : I64 }) -> List({ sport : Str, sessions : I64 })
	strip_segments = |fams| {
		total = List.fold(fams, 0.I64, |a, f| a + f.sessions)
		small = |f| f.sessions * 100 < total * strip_min_pct
		kept = List.keep_if(fams, |f| !small(f))
		smalls = List.keep_if(fams, small)
		if List.len(smalls) < 2 {
			List.concat(kept, smalls)
		} else {
			List.append(kept, { sport: "other", sessions: List.fold(smalls, 0.I64, |a, f| a + f.sessions) })
		}
	}

	# each segment's width across total_w: proportional to its sessions, never
	# under strip_min_w, and the room the widened segments take comes off the
	# others in proportion, so the strip still ends at total_w
	strip_widths : List(I64), F32 -> List(F32)
	strip_widths = |counts, total_w| {
		tot = List.fold(counts, 0.I64, |a, c| a + c)
		if tot <= 0 {
			[]
		} else {
			raw = List.map(counts, |c| I64.to_f32(c) / I64.to_f32(tot) * total_w)
			floor_sum = List.fold(raw, 0.0, |a, w| if (w < strip_min_w) (a + strip_min_w) else a)
			wide_sum = List.fold(raw, 0.0, |a, w| if (w < strip_min_w) a else a + w)
			scale = if (wide_sum <= 0.0) (1.0) else (total_w - floor_sum) / wide_sum
			List.map(raw, |w| if (w < strip_min_w) strip_min_w else w * scale)
		}
	}

	# the width a label beside the strip's end may take: the right margin
	# (Theme.pad_r) less the 6 px gap after the strip, the panel's 16 px
	# inset from the window edge and 10 px clear of the panel's border
	beside_room : F32
	beside_room = Theme.pad_r - 32.0

	# where a strip segment's name draws. Under the segment when it fits
	# inside the segment's width, so it never runs onto a neighbour. Failing
	# that, the last segment names itself beside the strip's end, in the
	# right margin, which holds nothing else at the strip's height; the
	# families too small to label are the ones strip_segments puts last, so
	# the smallest family is the one that gets this spot. Otherwise nowhere.
	strip_label_at : { x0 : F32, seg : F32, lw : F32, last : Bool } -> [Under(F32), Beside(F32), Unlabeled]
	strip_label_at = |s|
		if (s.lw + 12.0 <= s.seg - 1.5) Under(s.x0 + 6.0)
		else if (s.last and s.lw <= beside_room) Beside(s.x0 + s.seg + 6.0)
		else Unlabeled

	# a family's name on the strip: what the athlete does, not one of its
	# Strava spellings. The strength family pools Workout and WeightTraining
	# into one segment, and naming it after either reads as only that one.
	family_name : Str -> Str
	family_name = |head| if (List.contains(Sports.family("strength"), head)) "Strength" else head

	# the monthly-bar legend shares the gutter under the curve with the
	# valley's label, so it takes the half of the plot the valley is not on
	legend_left : F32, F32, F32 -> Bool
	legend_left = |valley_x, plot_l, plot_r| valley_x > (plot_l + plot_r) / 2.0

	# what the arc on screen measures, said after its family
	unit_note : [Metric, Imperial], Str, Str -> Str
	unit_note = |units, kind, fam|
		if (kind == "power") "threshold watts"
		# the withheld months are the honest gaps: a month where under a
		# third of the sessions carry sets is a biased sample, and the view
		# refuses to draw it (the rule lives in monthly_threshold's tonnage
		# arm; a refused month bridges with dashes like any unmeasured one)
		else if (kind == "tonnage") "monthly tonnage (kg lifted; thin months bridge as gaps)"
		else "threshold pace${Sports.pace_label_for(units, fam)}"

	subtitle : Ui.Model -> Str
	subtitle = |model| {
		cur = spine_at(model.career_spines, model.spine_idx)
		switch_note = if (List.len(model.career_spines) > 1) "   F  next sport" else ""
		if (cur.fam == "") "career - every month since the first session" else "career - ${Str.with_ascii_lowercased(cur.fam)} ${unit_note(model.units, cur.kind, cur.fam)}${switch_note}"
	}

	# ── the kind chips. A family can carry more than one threshold kind (a
	# run with a power meter has a power arc and a pace arc), and F cycles
	# every arc in the list, so the family on screen gets one chip per kind it
	# holds, right of the subtitle on the chip row: a click shows that kind's
	# arc. A family with a single kind gets none.
	KindChip : { label : Str, idx : U64, x : F32, on : Bool }

	kind_chip_w : F32
	kind_chip_w = 52.0

	kind_chip_top : F32
	kind_chip_top = 64.0

	kind_chip_bottom : F32
	kind_chip_bottom = 86.0

	kind_chips_at : List(Db.CareerSpine), U64, F32 -> List(KindChip)
	kind_chips_at = |spines, spine_idx, x0| {
		n = List.len(spines)
		cur_i = if (n == 0) 0 else spine_idx % n
		cur = spine_at(spines, spine_idx)
		same = List.keep_if(List.map_with_index(spines, |s, i| { s, i }), |x| cur.fam != "" and x.s.fam == cur.fam)
		if (List.len(same) < 2) []
		else List.map_with_index(same, |x, j| { label: x.s.kind, idx: x.i, x: x0 + U64.to_f32(j) * (kind_chip_w + 6.0), on: x.i == cur_i })
	}

	kind_chips : Ui.Model -> List(KindChip)
	kind_chips = |model| {
		w = model.font.measure({ text: subtitle(model), size: 14.0, spacing: Text.default_spacing }).width
		kind_chips_at(model.career_spines, model.spine_idx, 36.0 + w + 16.0)
	}

	# the spine index under x on the chip row, if a kind chip is there
	kind_chip_at : List(KindChip), F32 -> Try(U64, [None])
	kind_chip_at = |chips, x|
		match List.find_first(chips, |c| x >= c.x and x <= c.x + kind_chip_w) {
			Ok(c) => Ok(c.idx)
			Err(_) => Err(None)
		}

	# a test marks the spine of its own family AND threshold signal: a run's
	# power test belongs on the run power spine, never on its pace spine
	marks_spine : { fam : Str, month : Str, kind : Str, signal : Str }, Str, Str -> Bool
	marks_spine = |t, fam, kind| t.fam == fam and t.signal == kind

	# ── the layout the drawing, the scene and the gate share ───────────────
	# the arc on screen and the story's frame: one of the loaded family arcs
	# (F cycles them, so an athlete who rides AND rows sees each story), its
	# months, the sweep's progress and the camera, the plot's rows, and the
	# spine's scale.
	#
	# A spine needs a series before it is a trajectory: with fewer than three
	# measured months the tonnage arc withholds its stroke (one point is a
	# dot the athlete reads as a verdict, two a segment, not a career) and the
	# view says what it is waiting for instead. Zeroing the values in `months`
	# makes every reader of them (stroke, bridge, milestones, the gold
	# celebration) take its no-measurement branch, so one test withholds them
	# all. Threshold kinds are always ready: their histories are long where
	# tonnage's is young.
	Geom : {
		cur : Db.CareerSpine,
		ready : Bool,
		measured : U64,
		months : List(Db.CareerMonth),
		n : U64,
		p : F32,
		plot_l : F32,
		plot_r : F32,
		plot_w : F32,
		line_top : F32,
		line_bot : F32,
		bars_top : F32,
		bars_bot : F32,
		shown : F32,
		head_x : F32,
		fmax : I64,
		fmin : I64,
		frange : F32,
		lmax : I64,
	}

	geom : Ui.Model -> Geom
	geom = |model| {
		cur = spine_at(model.career_spines, model.spine_idx)
		measured = List.len(List.keep_if(cur.rows, |m| m.ftp10 > 0))
		ready = cur.kind != "tonnage" or measured >= 3
		months = if (ready) cur.rows else List.map(cur.rows, |m| { ..m, ftp10: 0 })
		n = List.len(months)
		nf = U64.to_f32(n)
		p = progress(model)
		plot_l = pad
		plot_r = model.win.w - Theme.pad_r
		plot_w = plot_r - plot_l
		# the camera pulls back: early in the sweep the axis frames only the
		# months that have arrived, and widens to the true full range as more
		# do. It lands exactly on the full range, since the settled view is
		# the honest one. The floor keeps a two-month career from filling the
		# window at one bar per screen.
		shown = (nf * p).max(8.0).min(nf)
		# spine scale from the measured points only; 0 means that family had
		# no scored session that month
		fmax = List.fold(months, 0.I64, |a, m| if (m.ftp10 > a) m.ftp10 else a)
		{
			cur,
			ready,
			measured,
			months,
			n,
			p,
			plot_l,
			plot_r,
			plot_w,
			line_top: 208.0,
			# the gutter between line_bot and bars_top is kept clear of both the
			# curve and the bars: the valley's label and the bar legend live in it
			line_bot: model.win.h - 196.0,
			bars_top: model.win.h - 168.0,
			bars_bot: model.win.h - 92.0,
			shown,
			head_x: plot_l + (if (shown >= nf) (p) else 1.0) * plot_w,
			fmax,
			fmin: List.fold(months, fmax, |a, m| if (m.ftp10 > 0 and m.ftp10 < a) m.ftp10 else a),
			frange: (I64.to_f32(fmax - List.fold(months, fmax, |a, m| if (m.ftp10 > 0 and m.ftp10 < a) m.ftp10 else a))).max(10.0),
			lmax: List.fold(months, 1.I64, |a, m| if (m.load > a) m.load else a),
		}
	}

	xf : Geom, U64 -> F32
	xf = |g, i| g.plot_l + (U64.to_f32(i) + 0.5) / g.shown * g.plot_w

	yf : Geom, I64 -> F32
	yf = |g, f10| g.line_bot - (I64.to_f32(f10 - g.fmin) / g.frange) * (g.line_bot - g.line_top)

	# the KPI cards' row: four cards of card_w, spread to the plot's edges
	card_w : F32
	card_w = 196.0

	card_top : F32
	card_top = 96.0

	card_h : F32
	card_h = 64.0

	card_box : F32, I64 -> Labels.Rect
	card_box = |win_w, i| {
		gap = (win_w - 72.0 - card_w * 4.0) / 3.0
		{ x: 36.0 + I64.to_f32(i) * (card_w + gap), y: card_top, w: card_w, h: card_h }
	}

	# the character sheet's chips: level and tier with the XP bar, and the
	# streak beside them, each only with hours on record and a streak running
	level_box : F32 -> Labels.Rect
	level_box = |win_w| { x: win_w - 36.0 - 196.0, y: 62.0, w: 196.0, h: 26.0 }

	streak_box : F32 -> Labels.Rect
	streak_box = |win_w| { x: win_w - 36.0 - 196.0 - 110.0, y: 62.0, w: 100.0, h: 26.0 }

	# the flame's square at the chip's left, clear of the streak text, which
	# starts 26 in
	flame_box : F32 -> Labels.Rect
	flame_box = |win_w| {
		sb = streak_box(win_w)
		{ x: sb.x + 5.0, y: sb.y + 4.0, w: 18.0, h: 18.0 }
	}

	# where the header row's left part ends: the subtitle, or the last kind
	# chip after it
	head_end : Ui.Model, Scene.Measure -> F32
	head_end = |model, measure| List.fold(kind_chips(model), 36.0 + measure(subtitle(model), 14.0, Data), |a, kc| F32.max(a, kc.x + kind_chip_w))

	# The character sheet's chips share the header row with the subtitle and
	# the kind chips, and yield to them: a chip shows only with sheet_gap of
	# air between it and them, and the streak only beside a level chip. The
	# rail's hover sheet carries the level, the tier and the streak either way.
	sheet_gap : F32
	sheet_gap = 10.0

	sheet : Ui.Model, Scene.Measure -> { level : Bool, streak : Bool }
	sheet = |model, measure| {
		end = head_end(model, measure)
		level = Hud.total_hours(model.career_sports) > 0 and level_box(model.win.w).x >= end + sheet_gap
		{ level, streak: level and Hud.streak_weeks(model.heat) > 0 and streak_box(model.win.w).x >= end + sheet_gap }
	}

	# the milestones: the valley, the peak and the last measured month, by
	# month index and value; a value of 0 means the spine has none
	Milestones : { valley : { i : U64, f : I64 }, peak : { i : U64, f : I64 }, last : { i : U64, f : I64 } }

	milestones : Geom -> Milestones
	milestones = |g| {
		idx = List.map_with_index(g.months, |m, i| { m, i })
		{
			valley: List.fold(idx, { i: 0.U64, f: g.fmax }, |a, x| if (x.m.ftp10 > 0 and x.m.ftp10 <= a.f) { i: x.i, f: x.m.ftp10 } else a),
			peak: List.fold(idx, { i: 0.U64, f: 0.I64 }, |a, x| if (x.m.ftp10 >= a.f and x.m.ftp10 > 0) { i: x.i, f: x.m.ftp10 } else a),
			last: List.fold(idx, { i: 0.U64, f: 0.I64 }, |a, x| if (x.m.ftp10 > 0) { i: x.i, f: x.m.ftp10 } else a),
		}
	}

	# a peak that IS the last measured month is a record in progress
	peak_is_now : Milestones -> Bool
	peak_is_now = |ms| ms.peak.i == ms.last.i and ms.peak.f > 0

	# the spine as screen points, `ok` marking a measured month, and the
	# curve drawn between adjacent measured months as short straight steps
	# of a monotone cubic (tangent); an unmeasured month ends one run and
	# starts another
	spine_pts : Geom -> List(Ui.SpinePt)
	spine_pts = |g| List.map_with_index(g.months, |m, i| { x: xf(g, i), y: yf(g, m.ftp10), ok: m.ftp10 > 0 })

	spine_steps : U64
	spine_steps = 10

	spine_segs : Geom -> List(Labels.Seg)
	spine_segs = |g| {
		pts = spine_pts(g)
		List.join(
			List.map_with_index(
				pts,
				|pt, i| {
					nxt = List.get(pts, i + 1) ?? { x: 0.0, y: 0.0, ok: Bool.False }
					if pt.ok and nxt.ok {
						m0 = tangent(pts, i)
						m1 = tangent(pts, i + 1)
						at = |s| {
							tt = U64.to_f32(s) / U64.to_f32(spine_steps)
							t2 = tt * tt
							t3 = t2 * tt
							{ x: pt.x + (nxt.x - pt.x) * tt, y: (2.0 * t3 - 3.0 * t2 + 1.0) * pt.y + (t3 - 2.0 * t2 + tt) * m0 + (-2.0 * t3 + 3.0 * t2) * nxt.y + (t3 - t2) * m1 }
						}
						List.map(
							List.map_with_index(List.repeat({}, spine_steps), |_u, k| k),
							|k| {
								a = at(k)
								b = at(k + 1)
								{ x0: a.x, y0: a.y, x1: b.x, y1: b.y }
							},
						)
					} else {
						[]
					}
				},
			),
		)
	}

	# the composition strip's segments: each family, its left edge and its
	# width at the sweep's progress
	comp_y : F32 -> F32
	comp_y = |win_h| win_h - 66.0

	strip : Ui.Model, Geom -> List({ sport : Str, sessions : I64, x0 : F32, seg : F32, last : Bool })
	strip = |model, g| {
		fams = strip_segments(fold_families(model.career_sports))
		ws = strip_widths(List.map(fams, |s| s.sessions), g.plot_r - 36.0)
		n = List.len(fams)
		(
			List.fold(
				List.map_with_index(fams, |s, i| { s, i }),
				{ x0: 36.0, out: [] },
				|st, y| {
					seg = (List.get(ws, y.i) ?? 0.0) * g.p
					{ x0: st.x0 + seg, out: List.append(st.out, { sport: y.s.sport, sessions: y.s.sessions, x0: st.x0, seg, last: y.i + 1 == n }) }
				},
			)
		).out
	}

	# the bars' legend keys: what the ground and the family's share are, and
	# the in-progress mark when a month carries it
	LegendKey : { label : Str, fill : Color.Rgba, base : Color.Rgba, split : Bool }

	legend_keys : Geom -> List(LegendKey)
	legend_keys = |g| {
		fam = g.cur.fam
		List.join([
			[{ label: "monthly load, every sport", fill: Color.with_alpha(Theme.ctl_c, 90), base: Color.with_alpha(Theme.ctl_c, 90), split: Bool.False }],
			if (fam == "") [] else [{ label: Str.with_ascii_lowercased(family_name(fam)), fill: Color.with_alpha(Theme.sport_color(fam), 210), base: Color.with_alpha(Theme.sport_color(fam), 210), split: Bool.False }],
			if (List.any(g.months, |m| m.partial)) [{ label: "month in progress", fill: Color.with_alpha(Theme.ctl_c, 50), base: if (fam == "") Color.with_alpha(Theme.ctl_c, 50) else Color.with_alpha(Theme.sport_color(fam), 120), split: Bool.True }] else [],
		])
	}

	# each key's left edge, from the half of the plot the valley is not on
	legend_rows : Geom, Scene.Measure -> List({ k : LegendKey, x : F32 })
	legend_rows = |g, measure| {
		keys = legend_keys(g)
		key_w = |k| 16.0 + measure(k.label, 10.0, Data)
		keys_w = List.fold(keys, 0.0, |a, k| a + key_w(k) + 18.0) - 18.0
		valley_x = xf(g, (milestones(g)).valley.i)
		start = if (legend_left(valley_x, g.plot_l, g.plot_r)) g.plot_l else g.plot_r - keys_w
		(List.fold(keys, { x: start, out: [] }, |st, k| { x: st.x + key_w(k) + 18.0, out: List.append(st.out, { k, x: st.x }) })).out
	}

	legend_y : Geom -> F32
	legend_y = |g| g.bars_top - 16.0

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		win_w = model.win.w
		ink_faint = Theme.ink_faint
		measure = Scene.measure_of(model)
		List.for_each!(
			kind_chips(model),
			|kc| {
				hov = model.mouse_x >= kc.x and model.mouse_x <= kc.x + kind_chip_w and model.mouse_y >= kind_chip_top and model.mouse_y <= kind_chip_bottom
				style = if (kc.on) (Draw.filled(Color.with_alpha(Theme.tsb_c, 60))) else if (hov) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
				frame.rounded_rectangle!({ x: kc.x, y: kind_chip_top, width: kind_chip_w, height: kind_chip_bottom - kind_chip_top, radius: 6.0, segments: 6, style })
			},
		)
		# ── the character sheet: level and streak, earned by the same
		# career the chart below tells. The XP bar eases in with the sweep.
		hours = Hud.total_hours(model.career_sports)
		shown = sheet(model, measure)
		if shown.level {
			lb = level_box(win_w)
			frame.rounded_rectangle!({ x: lb.x, y: lb.y, width: lb.w, height: lb.h, radius: 7.0, segments: 6, style: Draw.filled(Theme.card) })
			bar_x = lb.x + 118.0
			frame.rounded_rectangle!({ x: bar_x, y: 72.0, width: 66.0, height: 6.0, radius: 3.0, segments: 4, style: Draw.filled(Color.with_alpha(Theme.ink_faint, 70)) })
			bw9 = 66.0 * Hud.xp_frac(hours) * progress(model)
			if bw9 > 2.0 {
				frame.rounded_rectangle!({ x: bar_x, y: 72.0, width: bw9, height: 6.0, radius: 3.0, segments: 4, style: Draw.filled(Theme.gold_c) })
			}
			if shown.streak {
				sb = streak_box(win_w)
				frame.rounded_rectangle!({ x: sb.x, y: sb.y, width: sb.w, height: sb.h, radius: 7.0, segments: 6, style: Draw.filled(Theme.card) })
				match model.flame {
					Flame(ft) => {
						fb = flame_box(win_w)
						frame.texture!({ texture: ft, source: { x: 0.0, y: 0.0, width: ft.width, height: ft.height }, dest: { x: fb.x, y: fb.y, width: fb.w, height: fb.h }, origin: { x: 0.0, y: 0.0 }, rotation: 0.0, tint: Color.white })
					}
					NoFlame => {}
				}
			}
		}
		g = geom(model)
		if g.n >= 2 {
			List.for_each!(
				[0, 1, 2, 3],
				|i| {
					b = card_box(win_w, i)
					frame.rounded_rectangle!({ x: b.x, y: b.y, width: b.w, height: b.h, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
				},
			)
			p = g.p
			nf = U64.to_f32(g.n)
			sp = { fam: g.cur.fam, kind: g.cur.kind }
			# faint gridlines at the quarter marks, labelled in the scene
			List.for_each!(
				grid_qs,
				|q| {
					gy = g.line_bot - q * (g.line_bot - g.line_top)
					frame.line!({ start: { x: g.plot_l, y: gy }, end: { x: g.plot_r, y: gy }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 40), 1) })
				},
			)
			# the withheld spine withholds the STROKE, not the measurements: a
			# line through two points claims a direction two points cannot
			# support, but the points are measured, and hiding them reads as
			# "no data" when the truth is "not enough for a trend yet". Each
			# measured month draws as its own dot on a zero-based scale so the
			# heights compare honestly, labelled in the scene.
			if !g.ready {
				List.for_each!(withheld_dots(g), |d| frame.circle!({ center: { x: d.x, y: d.y }, radius: 4.0, style: Draw.filled(Theme.sport_color(sp.fam)) }))
			}
			# ── year bands rise from the baseline as the head crosses into them
			List.for_each!(
				year_ticks(g),
				|t| frame.line!({ start: { x: t.x, y: g.bars_bot + 4.0 }, end: { x: t.x, y: g.bars_bot + 4.0 - 10.0 * t.rise }, stroke: Draw.stroke(Color.with_alpha(ink_faint, 120), 1) }),
			)
			# ── monthly load: the recessive ground. A month in progress is the
			# same stack from the baseline in dimmer tints, so it reads as
			# unfinished rather than as a collapse, and the legend names the
			# tint. It carries no outline or top edge: a stroke rasterises
			# offset from the fill and reads as a second shape on the bar.
			bw = (g.plot_w / nf - 1.5).max(1.0)
			List.for_each!(
				List.map_with_index(g.months, |m, i| { m, i }),
				|x| {
					bx = xf(g, x.i) - bw / 2.0
					rise = bar_rise(g, bx)
					bh = (I64.to_f32(x.m.load) / I64.to_f32(g.lmax)) * (g.bars_bot - g.bars_top) * rise
					if bh > 0.5 {
						frame.rectangle!({ x: bx, y: g.bars_bot - bh, width: bw, height: bh, style: Draw.filled(Color.with_alpha(Theme.ctl_c, (if (x.m.partial) 50 else 90))) })
						# the SELECTED family's share of that month, filled from the
						# baseline in the family's own identity colour. The ground bar
						# pools every sport, so without this a family whose threshold
						# history is thin puts nothing of its own on the chart. Scaled
						# on the same lmax as the bar it sits inside, so the two
						# compare rather than each being normalised to itself.
						if sp.fam != "" {
							fl = List.fold(model.career_fam_months, 0.I64, |a, fm| if (fm.fam == sp.fam and fm.month == x.m.month) (fm.load) else a)
							fh = (I64.to_f32(fl) / I64.to_f32(g.lmax)) * (g.bars_bot - g.bars_top) * rise
							if fh > 0.5 {
								frame.rectangle!({ x: bx, y: g.bars_bot - fh, width: bw, height: fh, style: Draw.filled(Color.with_alpha(Theme.sport_color(sp.fam), (if (x.m.partial) 120 else 210))) })
							}
						}
					}
				},
			)
			# ── the bars' legend swatches, in the gutter: each a small bar, the
			# in-progress key the same dimmed ground over its dimmed share the
			# bar draws
			ky = legend_y(g)
			List.for_each!(
				legend_rows(g, measure),
				|e| {
					frame.rectangle!({ x: e.x, y: ky + 1.0, width: 10.0, height: 10.0, style: Draw.filled(e.k.fill) })
					if e.k.split {
						frame.rectangle!({ x: e.x, y: ky + 6.0, width: 10.0, height: 5.0, style: Draw.filled(e.k.base) })
					}
				},
			)
			# ── the spine: month-close threshold, drawn only between measured
			# neighbours - a gap is the engine saying "not measured", and a
			# line across it would invent the value. A dashed bridge joins the
			# last measured month to the next one so the career reads as
			# continuous while staying visibly NOT the curve: dashes carry no
			# value. Drawn first, so the solid spine covers it wherever both
			# would fall.
			List.for_each!(
				bridge_dashes(g),
				|d|
					if d.x1 <= g.head_x {
						frame.line!({ start: { x: d.x0, y: d.y0 }, end: { x: d.x1, y: d.y1 }, stroke: Draw.stroke(Color.with_alpha(Theme.ctl_c, 60), 1) })
					},
			)
			List.for_each!(
				spine_segs(g),
				|s|
					if s.x1 <= g.head_x {
						frame.line!({ start: { x: s.x0, y: s.y0 }, end: { x: s.x1, y: s.y1 }, stroke: Draw.stroke(Theme.ctl_c, 2) })
					},
			)
			# ── milestones: the valley, the peak and the last measured month,
			# each punching in as the head passes. The ring and the late
			# arrival are staging; the positions and the values are data.
			ms = milestones(g)
			mark! = |mi, mf, col| {
				mx = xf(g, mi)
				if mx <= g.head_x and mf > 0 {
					# the ring is a one-shot pulse that reaches 1.0, fully faded, on
					# settle, so a milestone near the right edge, which the head
					# never travels far past, keeps no permanent halo
					age_past = ((g.head_x - mx) / g.plot_w) * dur
					ring = if (p >= 1.0) (1.0) else (age_past / 14.0).min(1.0)
					frame.circle!({ center: { x: mx, y: yf(g, mf) }, radius: 3.0 + 9.0 * ring, style: Draw.filled(Color.with_alpha(col, F32.to_u8_try(90.0 * (1.0 - ring)) ?? 0)) })
					frame.circle!({ center: { x: mx, y: yf(g, mf) }, radius: 3.5, style: Draw.filled(col) })
				}
			}
			mark!(ms.valley.i, ms.valley.f, Theme.alarm_c)
			mark!(ms.peak.i, ms.peak.f, if (peak_is_now(ms)) (Theme.gold_c) else Theme.tsb_c)
			# a peak that IS the current month celebrates in gold with a
			# breathing halo, for every family; past peaks stay teal
			if peak_is_now(ms) and p >= 1.0 {
				gt = model.tick % 40
				gtri = (if (gt < 20) (U64.to_f32(gt)) else U64.to_f32(40 - gt)) / 20.0
				frame.circle!({ center: { x: xf(g, ms.peak.i), y: yf(g, ms.peak.f) }, radius: 8.0 + gtri * 3.0, style: Draw.filled(Color.with_alpha(Theme.gold_c, F32.to_u8_try(40.0 + gtri * 50.0) ?? 40)) })
			}
			if ms.last.i != ms.peak.i and ms.last.i != ms.valley.i {
				mark!(ms.last.i, ms.last.f, Theme.ctl_c)
			}
			# ── tests: a marked threshold test sets the spine from its own month
			# (ADR 0020), so that month wears a gold dot once the head passes it
			List.for_each!(test_marks(model, g), |t| frame.circle!({ center: { x: t.x, y: t.y }, radius: 4.5, style: Draw.filled(Theme.gold_c) }))
			# ── the comet: a bright head riding the spine, halo fading behind
			# it. Gone when settled - the finished view is a chart, not a show.
			if p < 1.0 {
				head_f = List.fold(List.map_with_index(g.months, |m, i| { m, i }), 0.I64, |a, x| if (x.m.ftp10 > 0 and xf(g, x.i) <= g.head_x) x.m.ftp10 else a)
				if head_f > 0 {
					hy = yf(g, head_f)
					frame.circle!({ center: { x: g.head_x, y: hy }, radius: 10.0, style: Draw.filled(Color.with_alpha(Color.white, 26)) })
					frame.circle!({ center: { x: g.head_x, y: hy }, radius: 6.0, style: Draw.filled(Color.with_alpha(Theme.ctl_c, 120)) })
					frame.circle!({ center: { x: g.head_x, y: hy }, radius: 3.0, style: Draw.filled(Color.white) })
				}
			}
			# ── composition: one stacked bar of every family by session count,
			# widest first, filling as the sweep runs, each segment in its
			# family's identity colour (Theme.sport_color). Never a pie: an
			# angle is harder to compare than a length.
			cy = comp_y(model.win.h)
			List.for_each!(
				strip(model, g),
				|s|
					if s.seg > 1.0 {
						frame.rounded_rectangle!({ x: s.x0, y: cy, width: (s.seg - 1.5).max(1.0), height: 12.0, radius: 3.0, segments: 3, style: Draw.filled(Color.with_alpha(Theme.sport_color(s.sport), 190)) })
					},
			)
		}
		Scene.draw!(frame, model, scene(model, measure))
		# the tooltip for the strip segment under the pointer, drawn ABOVE the
		# strip so it never hides the thing it describes, over everything
		if g.n >= 2 {
			match strip_tip(model, g, measure) {
				Ok(tip) => {
					frame.rounded_rectangle!({ x: tip.box.x, y: tip.box.y, width: tip.box.w, height: tip.box.h, radius: 6.0, segments: 5, style: Draw.filled(Theme.card) })
					frame.rounded_rectangle!({ x: tip.box.x + 10.0, y: tip.box.y + 7.0, width: 8.0, height: 8.0, radius: 2.0, segments: 3, style: Draw.filled(Theme.sport_color(tip.sport)) })
					Scene.draw!(frame, model, Labels.place([tip.text], { boxes: [], segs: [] }))
				}
				Err(_) => {}
			}
		}
		Ok({})
	}

	grid_qs : List(F32)
	grid_qs = [0.0, 0.25, 0.5, 0.75, 1.0]

	# a withheld spine's measured months as dots on a zero-based scale
	withheld_dots : Geom -> List({ x : F32, y : F32, f : I64 })
	withheld_dots = |g| {
		rmax = List.fold(g.cur.rows, 0.I64, |a, m| if (m.ftp10 > a) m.ftp10 else a)
		dot_bot = g.line_bot - 24.0
		dot_top = g.line_top + 72.0
		if rmax <= 0 {
			[]
		} else {
			List.keep_oks(
				List.map_with_index(g.cur.rows, |m, i| { m, i }),
				|x| if (x.m.ftp10 > 0 and g.head_x >= xf(g, x.i)) Ok({ x: xf(g, x.i), y: dot_bot - (I64.to_f32(x.m.ftp10) / I64.to_f32(rmax)) * (dot_bot - dot_top), f: x.m.ftp10 }) else Err(Hidden),
			)
		}
	}

	# where each year begins on the axis and how far its tick has risen;
	# `named` marks the years whose label prints, one clear of the last
	# named one by year_gap, so a first December alone does not crowd the
	# January beside it - the tick still rises, only the text is held
	year_gap : F32
	year_gap = 42.0

	year_ticks : Geom -> List({ x : F32, rise : F32, year : Str, named : Bool })
	year_ticks = |g| {
		nf = U64.to_f32(g.n)
		year_of = |m| Str.from_utf8_lossy(List.take_first(Str.to_utf8(m.month), 4))
		(
			List.fold(
				List.map_with_index(g.months, |m, i| { m, i }),
				{ last_x: -999.0, out: [] },
				|st, x| {
					prev_yr = if (x.i == 0) "" else year_of(List.get(g.months, x.i - 1) ?? x.m)
					yr = year_of(x.m)
					if x.i == 0 or yr != prev_yr {
						bx = xf(g, x.i) - 0.5 / nf * g.plot_w
						rise = if (g.p >= 1.0) (1.0) else if (g.head_x >= bx) ((((g.head_x - bx) / g.plot_w) * 6.0).min(1.0)) else 0.0
						if rise > 0.0 {
							named = bx - st.last_x >= year_gap
							{ last_x: if (named) bx else st.last_x, out: List.append(st.out, { x: bx, rise, year: yr, named }) }
						} else {
							st
						}
					} else {
						st
					}
				},
			)
		).out
	}

	# the dashes of the bridges across unmeasured months: only a real gap,
	# wider than one and a half month steps, bridges
	bridge_dashes : Geom -> List(Labels.Seg)
	bridge_dashes = |g| {
		step = g.plot_w / U64.to_f32(g.n)
		(
			List.fold(
				spine_pts(g),
				{ lx: -1.0, ly: 0.0, out: [] },
				|acc, pt|
					if (!pt.ok) acc
					else if (acc.lx < 0.0) { lx: pt.x, ly: pt.y, out: acc.out }
					else {
						span = pt.x - acc.lx
						dashes =
							if span > step * 1.5 {
								List.keep_oks(
									List.map_with_index(List.repeat({}, 14), |_u, k| k),
									|k|
										if k % 2 == 0 {
											t0 = U64.to_f32(k) / 14.0
											t1 = (U64.to_f32(k) + 0.8) / 14.0
											Ok({ x0: acc.lx + span * t0, y0: acc.ly + (pt.y - acc.ly) * t0, x1: acc.lx + span * t1, y1: acc.ly + (pt.y - acc.ly) * t1 })
										} else {
											Err(Gap)
										},
								)
							} else {
								[]
							}
						{ lx: pt.x, ly: pt.y, out: List.concat(acc.out, dashes) }
					},
			)
		).out
	}

	# the marked tests on the spine on screen whose month the head has
	# passed: the dot's centre, the test's kind, and whether it is the
	# valley's month
	test_marks : Ui.Model, Geom -> List({ x : F32, y : F32, kind : Str, valley : Bool })
	test_marks = |model, g| {
		ms = milestones(g)
		List.keep_oks(
			model.career_tests,
			|t|
				if marks_spine(t, g.cur.fam, g.cur.kind) {
					match List.first(List.keep_if(List.map_with_index(g.months, |m, i| { m, i }), |x| x.m.month == t.month)) {
						Ok(x) if x.m.ftp10 > 0 and xf(g, x.i) <= g.head_x => Ok({ x: xf(g, x.i), y: yf(g, x.m.ftp10), kind: t.kind, valley: x.i == ms.valley.i })
						_ => Err(Off)
					}
				} else {
					Err(Off)
				},
		)
	}

	# the strip segment under the pointer and its tooltip: the segment's
	# FULL width counts, not the narrower drawn width, so the narrowest
	# segment is still hoverable
	strip_tip : Ui.Model, Geom, Scene.Measure -> Try({ box : Labels.Rect, sport : Str, text : Labels.Label(Scene.Item) }, [None])
	strip_tip = |model, g, measure| {
		cy = comp_y(model.win.h)
		segs = strip(model, g)
		tot = List.fold(segs, 0.I64, |a, s| a + s.sessions)
		over = List.find_first(segs, |s| s.seg > 0.5 and model.mouse_y >= cy and model.mouse_y <= cy + 12.0 and model.mouse_x >= s.x0 and model.mouse_x < s.x0 + s.seg)
		match over {
			Ok(s) if tot > 0 => {
				pct = (I64.to_f32(s.sessions) / I64.to_f32(tot) * 100.0).round_to_i64_try().ok_or(0)
				label = "${family_name(s.sport)}  ${Db.grouped(s.sessions)} sessions  ${I64.to_str(pct)}%"
				tw = 8.0 * U64.to_f32(Str.count_utf8_bytes(label)) + 20.0
				tx = F32.max(36.0, F32.min(s.x0 + s.seg / 2.0 - tw / 2.0, g.plot_r - tw))
				box = { x: tx, y: cy - 30.0, w: tw, h: 22.0 }
				Ok({ box, sport: s.sport, text: Scene.fixed(measure, Scene.data(label, 11.0, Color.white), { x: tx + 24.0, y: cy - 25.0, align: Left }, box) })
			}
			_ => Err(None)
		}
	}

	# ── every string the view writes, placed ───────────────────────────────
	# Fixed text first: the subtitle and kind chips, the character sheet,
	# the cards, the axis, the bars' legend and the footer. Then the labels
	# on the chart: the milestone values (kept, they never drop), the
	# all-time-high cheer and the test kinds (kept), the withheld spine's
	# dot values (kept), the year names and the strip's family names. A
	# year name is its tick and its neighbours; a strip name is in the
	# strip's hover tooltip.
	scene : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	scene = |model, measure| Labels.place(texts(model, measure), obstacles(model, measure))

	# the view's text and the chrome's, as the gate judges them
	owned : Ui.Model, Scene.Measure -> List(Labels.Owned)
	owned = |model, measure| List.concat(Scene.owned(Chrome.placed(model, measure)), Scene.owned(scene(model, measure)))

	prio_milestone : U64
	prio_milestone = 1

	prio_note : U64
	prio_note = 2

	prio_year : U64
	prio_year = 3

	prio_strip : U64
	prio_strip = 4

	hint_text : Str
	hint_text = "click to settle   F  sport   TAB  form board   R  reload   S  screenshot   ESC  quit"

	texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	texts = |model, measure| {
		win_w = model.win.w
		win_h = model.win.h
		panel = Labels.panel(model.win)
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		fix = |it, x, y, align, region| Scene.fixed(measure, it, { x, y, align }, region)
		chips = List.map(
			kind_chips(model),
			|kc| fix(Scene.data(kc.label, 12.0, if (kc.on) Color.white else ink_muted), kc.x + kind_chip_w / 2.0, 68.0, Center, { x: kc.x, y: kind_chip_top, w: kind_chip_w, h: kind_chip_bottom - kind_chip_top }),
		)
		shown = sheet(model, measure)
		sheet_texts =
			if shown.level {
				lvl = Hud.level_of(Hud.total_hours(model.career_sports))
				lb = level_box(win_w)
				sb = streak_box(win_w)
				List.concat(
					[fix(Scene.data("LVL ${I64.to_str(lvl)}", 13.0, Theme.gold_c), lb.x + 10.0, 68.0, Left, lb), fix(Scene.data(Hud.tier(lvl), 11.0, ink_muted), lb.x + 62.0, 70.0, Left, lb)],
					if (shown.streak) [fix(Scene.data("${I64.to_str(Hud.streak_weeks(model.heat))} wk streak", 11.0, Theme.ember_c), sb.x + 26.0, 70.0, Left, sb)] else [],
				)
			} else {
				[]
			}
		head = [
			fix(Scene.data(subtitle(model), 14.0, ink_muted), 36.0, 70.0, Left, panel),
			fix(Scene.data(hint_text, 13.0, ink_faint), 36.0, win_h - 30.0, Left, panel),
		]
		g = geom(model)
		body = if (g.n < 2) [fix(Scene.data("no history yet - sync, analyze, and come back", 14.0, ink_muted), 36.0, 130.0, Left, panel)] else chart_texts(model, g, measure)
		List.join([head, chips, sheet_texts, body])
	}

	chart_texts : Ui.Model, Geom, Scene.Measure -> List(Labels.Label(Scene.Item))
	chart_texts = |model, g, measure| {
		win_w = model.win.w
		panel = Labels.panel(model.win)
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		units = model.units
		sp = { fam: g.cur.fam, kind: g.cur.kind }
		fix = |it, x, y, align, region| Scene.fixed(measure, it, { x, y, align }, region)
		chart = { x: g.plot_l - 40.0, y: g.line_top - 64.0, w: g.plot_w + 40.0 + Theme.pad_r - 24.0, h: comp_y(model.win.h) - g.line_top + 64.0 }
		# ── header: the career racking up. The final figures are the true
		# ones; the count-up is the feeling of accumulation, nothing else. The
		# cards count the spine's own family, not the whole career: rows fold
		# through Sports.canonical to reach the family the spine names, and
		# the captions carry the family, since a scoped number under an
		# unscoped word reads as the whole career's.
		scoped = if (sp.fam == "") (model.career_sports) else List.keep_if(model.career_sports, |s| Sports.canonical(s.sport) == sp.fam)
		fam_cap = if (sp.fam == "") "" else " - ${Str.with_ascii_lowercased(sp.fam)}"
		tot = List.fold(scoped, { h10: 0.I64, m: 0.0.F64, ss: 0.I64 }, |a, s| { h10: a.h10 + s.hours10, m: a.m + s.dist_m, ss: a.ss + s.sessions })
		# metres held until here; the card is the last moment (core.Units)
		dist_whole = (Units.dist_value(units, tot.m)).round_to_i64_try().ok_or(0)
		ease_i = |v| F32.to_i64_try(I64.to_f32(v) * g.p) ?? v
		# months TRAINED, not months elapsed: the axis spans every month
		# daily_load carries, decay days after the last session included, so
		# a month with no session is on the axis and does not count
		trained =
			if sp.fam == "" {
				List.fold(g.months, 0.I64, |a, m| if (m.load > 0) (a + 1) else a)
			} else {
				List.fold(model.career_fam_months, 0.I64, |a, fm| if (fm.fam == sp.fam and fm.sessions > 0) (a + 1) else a)
			}
		# a family that records no distance says so rather than showing a
		# zero: 0 km under a lifting arc reads as a measurement that came back
		# empty, when the sport does not carry the quantity
		cards = [
			{ v: Db.num_unit(ease_i(tot.h10) // 10, "h"), c: "moving time${fam_cap}" },
			{ v: if (tot.m <= 0.0) "-" else Db.num_unit(ease_i(dist_whole), Units.dist_unit(units)), c: "distance${fam_cap}" },
			{ v: Db.grouped(ease_i(tot.ss)), c: "sessions${fam_cap}" },
			{ v: Db.grouped(ease_i(trained)), c: "months trained${fam_cap}" },
		]
		card_texts = List.join(
			List.map_with_index(
				cards,
				|c, i| {
					b = card_box(win_w, U64.to_i64_wrap(i))
					[fix(Scene.data(c.v, 22.0, Color.white), b.x + 16.0, b.y + 10.0, Left, b), fix(Scene.data(c.c, 11.0, ink_faint), b.x + 16.0, b.y + 42.0, Left, b)]
				},
			),
		)
		# the quarter marks' values in the family's units. No labels on an
		# unmeasured scale (fmax 0, the withheld-spine state): five identical
		# zero labels would caption a ruler with nothing on it
		grid =
			if g.fmax > 0 {
				List.map(
					grid_qs,
					|q| {
						gy = g.line_bot - q * (g.line_bot - g.line_top)
						w = g.fmin + (F32.to_i64_try(q * I64.to_f32(g.fmax - g.fmin)) ?? 0)
						fix(Scene.data(spine_label(units, w, sp.kind, sp.fam), 10.0, ink_faint), g.plot_l - 8.0, gy - 5.0, Right, panel)
					},
				)
			} else {
				[]
			}
		ky = legend_y(g)
		legend = List.map(legend_rows(g, measure), |e| fix(Scene.data(e.k.label, 10.0, ink_faint), e.x + 16.0, ky, Left, panel))
		# what the withheld spine is waiting for, where the arc would be, and
		# each measured month's value over its dot
		withheld =
			if g.ready {
				[]
			} else {
				col = Theme.sport_color(sp.fam)
				List.prepend(
					List.map(withheld_dots(g), |d| Scene.kept(measure, Scene.data(spine_label(units, d.f, sp.kind, sp.fam), 11.0, col), [{ x: d.x, y: d.y - 20.0, align: Center }, { x: d.x, y: d.y + 9.0, align: Center }], prio_milestone, chart)),
					fix(Scene.data("tonnage arc: ${U64.to_str(g.measured)} of 3 months measured - the spine draws at 3", 13.0, ink_muted), g.plot_l + g.plot_w / 2.0, g.line_top + 24.0, Center, panel),
				)
			}
		# the milestone values: a peak's goes ABOVE, far enough that the
		# stroke and its halo clear the glyphs, since the curve rises steeply
		# into its extremes; the valley is the scale's minimum, on line_bot,
		# so its value goes BELOW into the gutter, which neither the curve nor
		# the bars reach. Each falls back to the other side, then beside.
		ms = milestones(g)
		mark = |mi, mf, col, below|
			if xf(g, mi) <= g.head_x and mf > 0 {
				x = xf(g, mi)
				y = yf(g, mf)
				txt = spine_label(units, mf, sp.kind, sp.fam)
				over = { x, y: y - 34.0, align: Center }
				under = { x, y: y + 10.0, align: Center }
				right = { x: x + 10.0, y: y - 6.5, align: Left }
				left = { x: x - 10.0, y: y - 6.5, align: Right }
				[Scene.kept(measure, Scene.data(txt, 13.0, col), if (below) [under, over, right, left] else [over, under, right, left], prio_milestone, chart)]
			} else {
				[]
			}
		now = peak_is_now(ms)
		marks = List.join([
			mark(ms.valley.i, ms.valley.f, Theme.alarm_c, Bool.True),
			mark(ms.peak.i, ms.peak.f, if (now) (Theme.gold_c) else Theme.tsb_c, Bool.False),
			if (ms.last.i != ms.peak.i and ms.last.i != ms.valley.i) mark(ms.last.i, ms.last.f, Theme.ctl_c, Bool.False) else [],
		])
		# a full line-height of clearance above the size-13 value at its
		# spot, which itself clears the dot and halo
		cheer =
			if now and g.p >= 1.0 {
				x = xf(g, ms.peak.i)
				y = yf(g, ms.peak.f)
				[Scene.kept(measure, Scene.data("all-time high", 11.0, Theme.gold_c), [{ x, y: y - 64.0, align: Center }, { x, y: y - 50.0, align: Center }, { x: x + 10.0, y: y - 24.0, align: Left }, { x: x - 10.0, y: y - 24.0, align: Right }, { x, y: y + 26.0, align: Center }], prio_note, chart)]
			} else {
				[]
			}
		# a test's kind sits under its dot, or over it when the gutter there
		# is taken: on the valley's month the valley's own value holds it
		tests = List.map(
			test_marks(model, g),
			|t| {
				under = { x: t.x, y: t.y + 10.0, align: Center }
				over = { x: t.x, y: t.y - 20.0, align: Center }
				Scene.kept(measure, Scene.data("${t.kind} test", 11.0, Theme.gold_c), if (t.valley) [over, under] else [under, over], prio_note, chart)
			},
		)
		years = List.keep_oks(
			year_ticks(g),
			|t|
				if t.named {
					a = F32.to_u8_try(200.0 * t.rise) ?? 200
					Ok(Scene.free(measure, Scene.data(t.year, 10.0, Color.with_alpha(ink_muted, a)), [{ x: t.x + 4.0, y: g.bars_bot + 8.0, align: Left }], prio_year, panel))
				} else {
					Err(Unnamed)
				},
		)
		# each strip segment's name where strip_label_at puts it: under the
		# segment, beside the strip's end, or nowhere; a segment without one
		# keeps its meaning through the hover tooltip
		cy = comp_y(model.win.h)
		names = List.keep_oks(
			strip(model, g),
			|s|
				if s.seg > 1.0 {
					col = Theme.sport_color(s.sport)
					lbl = "${family_name(s.sport)} ${Db.grouped(s.sessions)}"
					lw = measure(lbl, 10.0, Data)
					match strip_label_at({ x0: s.x0, seg: s.seg, lw, last: s.last }) {
						Under(lx) => Ok(Scene.free(measure, Scene.data(lbl, 10.0, Color.with_alpha(col, 235)), [{ x: lx, y: cy + 15.0, align: Left }], prio_strip, panel))
						Beside(lx) => Ok(Scene.free(measure, Scene.data(lbl, 10.0, Color.with_alpha(col, 235)), [{ x: lx, y: cy + 1.0, align: Left }], prio_strip, panel))
						Unlabeled => Err(Unlabeled)
					}
				} else {
					Err(Unlabeled)
				},
		)
		List.join([card_texts, grid, legend, withheld, marks, cheer, tests, years, names])
	}

	# what the chart's labels keep off: the chrome, every shape the view
	# draws (marks), the composition strip's whole length, and the spine's
	# stroke
	obstacles : Ui.Model, Scene.Measure -> Labels.Obstacles
	obstacles = |model, measure| {
		boxes = List.concat(Chrome.boxes(model, measure), List.map(marks(model, measure), |m| m.box))
		g = geom(model)
		if g.n < 2 {
			{ boxes, segs: [] }
		} else {
			{ boxes: List.append(boxes, { x: 36.0, y: comp_y(model.win.h), w: g.plot_r - 36.0, h: 12.0 }), segs: spine_segs(g) }
		}
	}

	# the shapes no text may cover but its own: the pills and the XP rail,
	# the kind chips, the level and streak chips, and with a history the
	# cards, the milestone, test and withheld dots, the monthly load bars,
	# the bars' legend swatches and the strip's segments. The peak's
	# breathing halo is a glow text may sit over, so it is not one.
	marks : Ui.Model, Scene.Measure -> List(Labels.Mark)
	marks = |model, measure| {
		dot = |key, x, y, r| { key, box: { x: x - r, y: y - r, w: 2.0 * r, h: 2.0 * r } }
		chips = List.map(kind_chips(model), |kc| { key: "the ${kc.label} chip", box: { x: kc.x, y: kind_chip_top, w: kind_chip_w, h: kind_chip_bottom - kind_chip_top } })
		shown = sheet(model, measure)
		sheet_marks = List.concat(if (shown.level) [{ key: "the level chip", box: level_box(model.win.w) }] else [], if (shown.streak) [{ key: "the streak chip", box: streak_box(model.win.w) }] else [])
		shapes = List.join([Chrome.marks(model), chips, sheet_marks])
		g = geom(model)
		if g.n < 2 {
			shapes
		} else {
			ms = milestones(g)
			at = |key, mi, mf| if (xf(g, mi) <= g.head_x and mf > 0) [dot(key, xf(g, mi), yf(g, mf), 4.0)] else []
			spine_dots = List.join([at("the valley dot", ms.valley.i, ms.valley.f), at("the peak dot", ms.peak.i, ms.peak.f), if (ms.last.i != ms.peak.i and ms.last.i != ms.valley.i) at("the last month's dot", ms.last.i, ms.last.f) else []])
			tests = List.map(test_marks(model, g), |t| dot("the ${t.kind} test dot", t.x, t.y, 4.5))
			withheld = if (g.ready) [] else List.map(withheld_dots(g), |d| dot("the withheld dot at ${Db.fmt_i(d.x)}", d.x, d.y, 4.0))
			ky = legend_y(g)
			swatches = List.map(legend_rows(g, measure), |e| { key: "the ${e.k.label} swatch", box: { x: e.x, y: ky + 1.0, w: 10.0, h: 10.0 } })
			cards = List.map([0, 1, 2, 3], |i| { key: "card ${I64.to_str(i + 1)}", box: card_box(model.win.w, i) })
			cy = comp_y(model.win.h)
			segments = List.keep_oks(strip(model, g), |s| if (s.seg > 1.0) Ok({ key: "the ${family_name(s.sport)} strip segment", box: { x: s.x0, y: cy, w: (s.seg - 1.5).max(1.0), h: 12.0 } }) else Err(Undrawn))
			List.join([shapes, cards, spine_dots, tests, withheld, load_bars(g), swatches, segments])
		}
	}

	# the monthly load bars as drawn: each month's ground bar from the
	# baseline, risen with the sweep, when it is taller than half a pixel.
	# The family's share fills from the same baseline inside it.
	load_bars : Geom -> List(Labels.Mark)
	load_bars = |g| {
		bw = (g.plot_w / U64.to_f32(g.n) - 1.5).max(1.0)
		List.keep_oks(
			List.map_with_index(g.months, |m, i| { m, i }),
			|x| {
				bx = xf(g, x.i) - bw / 2.0
				bh = (I64.to_f32(x.m.load) / I64.to_f32(g.lmax)) * (g.bars_bot - g.bars_top) * bar_rise(g, bx)
				if (bh > 0.5) Ok({ key: "the load bar for ${x.m.month}", box: { x: bx, y: g.bars_bot - bh, w: bw, h: bh } }) else Err(Flat)
			},
		)
	}

	# how far a load bar whose left edge is bx has risen: whole once the
	# sweep settles, rising from the moment the head reaches it before then
	bar_rise : Geom, F32 -> F32
	bar_rise = |g, bx| if (g.p >= 1.0) (1.0) else if (g.head_x >= bx) ((((g.head_x - bx) / g.plot_w) * 5.0).min(1.0)) else 0.0
}

# the tonnage label's two regimes and the boundary between them: whole kg
# under a tonne, tonnes to one decimal above - the rounding is integer on
# tenths-of-kg, so 1197 kg carries to 1.2t
expect Career.spine_label(Metric, 11970, "tonnage", "WeightTraining") == "1.2t"
expect Career.spine_label(Metric, 8500, "tonnage", "WeightTraining") == "850kg"

# the flame sits wholly inside the streak chip and ends before the streak
# text, which starts 26 in from the chip's left edge
expect {
	sb = Career.streak_box(1400.0)
	fb = Career.flame_box(1400.0)
	fb.x >= sb.x
		and fb.y >= sb.y
		and fb.y + fb.h <= sb.y + sb.h
		and fb.x + fb.w <= sb.x + 26.0
}

# members of one family merge and the segment carries the family head, so a
# gravel ride and a road ride are one Ride rather than two neighbours wearing
# the same colour
expect {
	got = Career.fold_families([
		{ sport: "Ride", sessions: 485, hours10: 0, dist_m: 0.0 },
		{ sport: "Rowing", sessions: 208, hours10: 0, dist_m: 0.0 },
		{ sport: "Workout", sessions: 52, hours10: 0, dist_m: 0.0 },
		{ sport: "GravelRide", sessions: 11, hours10: 0, dist_m: 0.0 },
		{ sport: "WeightTraining", sessions: 5, hours10: 0, dist_m: 0.0 },
	])
	got
		== [
			{ sport: "Ride", sessions: 496 },
			{ sport: "Rowing", sessions: 208 },
			{ sport: "WeightTraining", sessions: 57 },
		]
}

# widest-first is ENFORCED by the sort, not inherited from the input order: a
# family split across two members can total more than one that sat between
# them, and must still be drawn first. Rowing's 250 + 80 beats Ride's 300 + 5
# even though Ride's largest member came first.
expect {
	got = Career.fold_families([
		{ sport: "Ride", sessions: 300, hours10: 0, dist_m: 0.0 },
		{ sport: "Rowing", sessions: 250, hours10: 0, dist_m: 0.0 },
		{ sport: "VirtualRow", sessions: 80, hours10: 0, dist_m: 0.0 },
		{ sport: "GravelRide", sessions: 5, hours10: 0, dist_m: 0.0 },
	])
	got == [{ sport: "Rowing", sessions: 330 }, { sport: "Ride", sessions: 305 }]
}

# a sport with no family row stands alone rather than joining anything
expect Career.fold_families([{ sport: "Yoga", sessions: 3, hours10: 0, dist_m: 0.0 }]) == [{ sport: "Yoga", sessions: 3 }]

# F past the last family wraps to the first, and the focus row reads the
# same family the screen draws at every index
expect {
	two = [{ fam: "Ride", kind: "", rows: [] }, { fam: "Rowing", kind: "", rows: [] }]
	Career.spine_at(two, 0).fam == "Ride" and Career.spine_at(two, 1).fam == "Rowing" and Career.spine_at(two, 2).fam == "Ride" and Career.spine_at(two, 7).fam == "Rowing" and Career.spine_at([], 3).fam == ""
}

# a segment names itself under its own width when the label fits there;
# the last segment, too narrow, names itself beside the strip's end; a
# narrow segment that is not last, or a label wider than the margin, goes
# unlabeled and keeps the hover tooltip
expect {
	Career.strip_label_at({ x0: 100.0, seg: 80.0, lw: 40.0, last: Bool.False }) == Under(106.0)
		and Career.strip_label_at({ x0: 900.0, seg: 8.0, lw: 30.0, last: Bool.True }) == Beside(914.0)
		and Career.strip_label_at({ x0: 800.0, seg: 8.0, lw: 30.0, last: Bool.False }) == Unlabeled
		and Career.strip_label_at({ x0: 900.0, seg: 8.0, lw: Career.beside_room + 1.0, last: Bool.True }) == Unlabeled
}
# two or more families under the strip's minimum share fold into one `other`
# segment at the end; the families above it keep their order
expect {
	got = Career.strip_segments([{ sport: "Ride", sessions: 500 }, { sport: "Rowing", sessions: 213 }, { sport: "WeightTraining", sessions: 70 }, { sport: "Run", sessions: 1 }, { sport: "Swim", sessions: 2 }])
	got == [{ sport: "Ride", sessions: 500 }, { sport: "Rowing", sessions: 213 }, { sport: "WeightTraining", sessions: 70 }, { sport: "other", sessions: 3 }]
}

# a lone small family keeps its own name, and nothing folds when every family
# clears the minimum
expect Career.strip_segments([{ sport: "Ride", sessions: 500 }, { sport: "Run", sessions: 1 }]) == [{ sport: "Ride", sessions: 500 }, { sport: "Run", sessions: 1 }]
expect Career.strip_segments([{ sport: "Ride", sessions: 60 }, { sport: "Rowing", sessions: 40 }]) == [{ sport: "Ride", sessions: 60 }, { sport: "Rowing", sessions: 40 }]

# every segment is at least strip_min_w wide and the strip still spans its
# whole width; proportional widths pass through when none is that narrow
expect {
	ws = Career.strip_widths([999, 1], 1000.0)
	total = List.fold(ws, 0.0, |a, w| a + w)
	List.len(ws) == 2 and List.all(ws, |w| w >= Career.strip_min_w) and (total - 1000.0).abs() < 0.01
}
expect Career.strip_widths([3, 1], 400.0) == [300.0, 100.0]
expect Career.strip_widths([], 400.0) == []

# the strength family is named for what it is, whichever spelling heads it;
# other families keep their head
expect Career.family_name("WeightTraining") == "Strength" and Career.family_name("Workout") == "Strength"
expect Career.family_name("Ride") == "Ride" and Career.family_name("other") == "other"

# the legend takes the half of the plot the valley label is not on
expect Career.legend_left(900.0, 64.0, 1000.0) and !Career.legend_left(100.0, 64.0, 1000.0)

# a family holding two threshold kinds gets one chip per kind, the arc on
# screen lit; a family with one kind, or no family, gets none
expect {
	run_pw = { fam: "Run", kind: "power", rows: [] }
	run_pc = { fam: "Run", kind: "pace", rows: [] }
	ride = { fam: "Ride", kind: "power", rows: [] }
	chips = Career.kind_chips_at([ride, run_pw, run_pc], 2, 400.0)
	List.map(chips, |c| c.label) == ["power", "pace"]
		and List.map(chips, |c| c.idx) == [1, 2]
		and List.map(List.keep_if(chips, |c| c.on), |c| c.label) == ["pace"]
		and Career.kind_chip_at(chips, 400.0 + 58.0 + 10.0) == Ok(2)
		and Career.kind_chip_at(chips, 380.0) == Err(None)
		and Career.kind_chips_at([ride, run_pw, run_pc], 0, 400.0) == []
		and Career.kind_chips_at([], 0, 400.0) == []
}

expect Career.marks_spine({ fam: "Run", month: "2026-11", kind: "ftp20", signal: "power" }, "Run", "power")
expect !(Career.marks_spine({ fam: "Run", month: "2026-11", kind: "5k", signal: "pace" }, "Run", "power")) and !(Career.marks_spine({ fam: "Ride", month: "2026-11", kind: "ftp20", signal: "power" }, "Run", "power"))
