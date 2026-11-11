import rr.Color
import rr.Draw
import rr.Text
import core.Fmt
import Days
import Db
import Theme
import Ui
import Scroll
import Wrap

Plan :: [].{
	# The command-and-progress view: today's prescription (or, once it is
	# done, its result) in a card, the whole Mon-Sun week plus the days ahead
	# with what happened on each, the week as a row of day pips, the load
	# strip, and the coach corner - the bus made visible.
	type_color : Str -> Color.Rgba
	type_color = |typ|
		if (typ == "threshold") Theme.tsb_c
		else if (typ == "vo2") Theme.atl_c
		else if (typ == "endurance") Theme.ctl_c
		else if (typ == "strength") (Color.from_hex_rgb(0xd8c27a))
		else Theme.ink_faint

	# What became of one planned day. A skipped session that names a
	# substitute is its own kind: the athlete trained, just not as written.
	# A rest day reads Rested once its date has passed with under 1.0 load on
	# a day daily_load covers, the rule the engine's `week` and `plan` apply;
	# a day daily_load has not reached stays Open. Future is an open day after
	# today, and NoSession is a weekday the plan holds nothing for.
	DayKind : [Done, Substituted, Skipped, Rested, Open, Future, NoSession]

	kind_of : Db.PlanRow -> DayKind
	kind_of = |p|
		if (p.status == "done") Done
		else if (p.status == "skipped") (if (p.sub_id > 0) Substituted else Skipped)
		else if (p.typ == "rest" and p.past and p.day_load_known and p.day_load < 1.0) Rested
		else if (p.past or p.today) Open
		else Future

	# One kind per weekday, Monday first, so a pip's position is its day and
	# never its rank among completed sessions.
	week_kinds : List(Db.PlanRow) -> List(DayKind)
	week_kinds = |rows|
		List.map(
			[0, 1, 2, 3, 4, 5, 6],
			|i| match List.find_first(rows, |p| p.wi == i) {
				Ok(p) => kind_of(p)
				Err(_) => NoSession
			},
		)

	pip_color : DayKind -> Color.Rgba
	pip_color = |k| match k {
		Done => Theme.gold_c
		Substituted => Color.with_alpha(Theme.gold_c, 110)
		Skipped => Color.with_alpha(Theme.atl_c, 150)
		Rested => Color.with_alpha(Theme.tsb_c, 170)
		Open => Color.with_alpha(Theme.ctl_c, 170)
		Future => Color.with_alpha(Theme.ink_faint, 70)
		NoSession => Color.with_alpha(Theme.ink_faint, 25)
	}

	# The right-hand status word of a ladder row. A session completed by an
	# activity from another day names that day, so the row does not imply
	# the work happened on the date it was prescribed for.
	status_text : Db.PlanRow -> Str
	status_text = |p| match kind_of(p) {
		Done => if (p.done_day != "" and p.done_day != p.day) "done ${p.done_day}" else "done"
		Substituted => "skipped"
		Skipped => "skipped"
		Rested => "rested"
		Open => if (p.today) ">>" else "open"
		Future => ""
		NoSession => ""
	}

	watts_str : F64 -> Str
	watts_str = |w| I64.to_str(w.round_to_i64_try().ok_or(0))

	# the detected mean work watts as a share of the target watts, rounded
	# to a whole percent: the quantity `stride complete` reports as watts_pct
	pct_label : F64, F64 -> Str
	pct_label = |detected, target|
		if (target <= 0.0) "" else "${watts_str(detected / target * 100.0)}%"

	# a power target beside the detected power work reps of the linked
	# activity, each side stated only when it is known; any other target
	# (heart rate, zone, pace, RPE) beside the result `complete` stored for
	# it, in the CLI's own words
	target_text : Db.PlanRow -> Str
	target_text = |p| {
		tgt = "${I64.to_str(p.tgt_reps)}x${Fmt.mmss(p.tgt_dur_s)} @ ${watts_str(p.tgt_watts)}W"
		if (p.tgt_reps <= 0) (if (p.tgt_lit == "") "" else if (p.tgt_res == "") "target ${p.tgt_lit}" else "target ${p.tgt_lit}; ${p.tgt_res}")
		else if (p.det_reps <= 0) "target ${tgt}, no power intervals detected"
		else "${I64.to_str(p.det_reps)}x${Fmt.mmss(p.det_dur_s)} @ ${watts_str(p.det_watts)}W - ${pct_label(p.det_watts, p.tgt_watts)} of ${tgt}"
	}

	# what happened, in one line under the prescription
	result_text : Db.PlanRow -> Str
	result_text = |p| {
		why = if (p.reason == "") "skipped" else "skipped: ${p.reason}"
		match kind_of(p) {
			Done => {
				name = if (p.act_name == "") "linked activity" else p.act_name
				base = "${name} - ${I64.to_str((p.act_secs + 30) // 60)} min - load ${I64.to_str(p.act_load)}"
				tt = target_text(p)
				if (tt == "") base else "${base} - ${tt}"
			}
			Substituted => if (p.sub_name == "") why else "${why} -> ${p.sub_name}"
			Skipped => why
			Rested => "no load on the day"
			_ => ""
		}
	}

	# today's card: the prescription in full until the day has an outcome, then
	# the outcome. It is bounded even though coach-written details are not:
	# past these caps the last line ends in an ellipsis, so a long
	# prescription cannot crowd the ladder off the screen.
	today_card : List(Db.PlanRow), F32 -> { today : Db.PlanRow, head : Str, dlines : List(Str), rlines : List(Str), h : F32 }
	today_card = |plan, win_w| {
		blank = { day: "", wi: -1, typ: "", detail: "no plan for today - ask the coach", rationale: "", status: "open", reason: "", today: Bool.False, past: Bool.False, done_day: "", act_name: "", act_secs: 0, act_load: 0, sub_id: 0, sub_name: "", tgt_reps: 0, tgt_dur_s: 0, tgt_watts: 0.0, tgt_lit: "", tgt_res: "", det_reps: 0, det_dur_s: 0, det_watts: 0.0, day_load_known: Bool.False, day_load: 0.0 }
		today = List.fold(plan, blank, |acc, p| if (p.today) p else acc)
		outcome = result_text(today)
		head = if (outcome == "") "today - ${today.typ}" else "today - ${today.typ} - ${status_text(today)}"
		body = if (outcome == "") today.detail else outcome
		note = if (outcome == "") today.rationale else today.detail
		cols = Wrap.cols_for(win_w - 160.0, 7.8)
		dlines = Wrap.fit(body, cols, 6)
		rlines = Wrap.fit(note, cols + 8, 3)
		h = 46.0 + U64.to_f32(List.len(dlines)) * 19.0 + U64.to_f32(List.len(rlines)) * 16.0 + 14.0
		{ today, head, dlines, rlines, h }
	}

	# a ladder row's prescription lines: one for a past or current day, up to
	# three for a day ahead
	row_lines : Db.PlanRow, U64 -> List(Str)
	row_lines = |p, cols| if (p.past or p.today) Wrap.fit(p.detail, cols, 1) else Wrap.fit(p.detail, cols, 3)

	row_height : Db.PlanRow, U64 -> F32
	row_height = |p, cols| (U64.to_f32(List.len(row_lines(p, cols))) * 18.0 + U64.to_f32(List.len(Wrap.fit(result_text(p), cols, 1))) * 16.0 + 12.0).max(30.0)

	# the ladder's geometry, shared by the drawing and by the scroll clamp in
	# update: every row's height, where it starts, and the room above the
	# load strip, less a line for the `more below` hint
	ladder : Ui.Model -> { heights : List(F32), top : F32, room : F32, cols : U64 }
	ladder = |model| {
		cols = Wrap.cols_for(model.win.w - 340.0, 7.2)
		top = 100.0 + (today_card(model.plan, model.win.w)).h + 20.0
		room = (model.win.h - 110.0 - top - 14.0).max(30.0)
		{ heights: List.map(model.plan, |p| row_height(p, cols)), top, room, cols }
	}

	# the last offset the ladder may scroll to
	week_last : Ui.Model -> U64
	week_last = |model| {
		l = ladder(model)
		Scroll.last_offset(l.heights, l.room)
	}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		win_w = model.win.w
		win_h = model.win.h
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		model.plan_title.draw!(frame, { pos: { x: Days.title_x, y: 70.0 }, color: ink_muted, align: (Top, Left) })
		# ── the week as a quest: one pip per weekday, Monday first, colored by
		# what became of that day, and the label counts the done sessions.
		# The whole row pulses when every prescribed session is done.
		qt = model.plan_week.total
		qd = model.plan_week.done
		if qt > 0 {
			pipw = 18.0
			qx0 = win_w - 36.0 - 7.0 * (pipw + 4.0)
			complete = qd >= qt
			t9 = model.tick % 40
			tri9 = (if (t9 < 20) (U64.to_f32(t9)) else U64.to_f32(40 - t9)) / 20.0
			label = if (complete) "week complete" else "quest ${I64.to_str(qd)}/${I64.to_str(qt)}"
			lc9 = if (complete) (Theme.gold_c) else ink_muted
			Text.from(label, model.font).size(11).draw!(frame, { pos: { x: qx0 - 10.0, y: 72.0 }, color: lc9, align: (Top, Right) })
			pulse_a = match F32.round_to_u64_try(200.0 + tri9 * 55.0) {
				Ok(u8v) => (
					match U64.to_u8_try(u8v) {
						Ok(a9) => a9
						Err(_) => 255.U8
					}
				)
				Err(_) => 255.U8
			}
			List.for_each!(
				List.map_with_index(week_kinds(model.plan), |k, i| { k, i }),
				|q| {
					px = qx0 + U64.to_f32(q.i) * (pipw + 4.0)
					c = if (complete and q.k == Done) (Color.with_alpha(Theme.gold_c, pulse_a)) else pip_color(q.k)
					frame.rounded_rectangle!({ x: px, y: 70.0, width: pipw, height: 8.0, radius: 4.0, segments: 4, style: Draw.filled(c) })
				},
			)
		}

		# today's card (today_card)
		card = today_card(model.plan, win_w)
		today = card.today
		card_head = card.head
		dlines = card.dlines
		rlines = card.rlines
		nd = U64.to_f32(List.len(dlines))
		card_h = card.h
		frame.rounded_rectangle!({ x: 36.0, y: 100.0, width: win_w - 72.0, height: card_h, radius: 10.0, segments: 8, style: Draw.filled(Theme.card) })
		frame.rounded_rectangle!({ x: 52.0, y: 116.0, width: 10.0, height: card_h - 32.0, radius: 4.0, segments: 4, style: Draw.filled(type_color(today.typ)) })
		Text.from(card_head, model.font).size(14).draw!(frame, { pos: { x: 76.0, y: 112.0 }, color: type_color(today.typ), align: (Top, Left) })
		List.for_each!(List.map_with_index(dlines, |ln, i| { ln, i }), |d|
			Text.from(d.ln, model.font).size(13).draw!(frame, { pos: { x: 76.0, y: 134.0 + U64.to_f32(d.i) * 19.0 }, color: Color.white, align: (Top, Left) }))
		List.for_each!(List.map_with_index(rlines, |ln, i| { ln, i }), |r|
			Text.from(r.ln, model.font).size(11).draw!(frame, { pos: { x: 76.0, y: 134.0 + nd * 19.0 + 4.0 + U64.to_f32(r.i) * 16.0 }, color: ink_faint, align: (Top, Left) }))

		# the ladder: Monday through the days ahead. A past or current day takes
		# one line of prescription (the card holds today's in full) and one of
		# outcome, and a day ahead up to three, so the coming days fit under the
		# week's history. Rows that do not fit above the load strip scroll
		# (Scroll), so no day is ever shed.
		lad = ladder(model)
		row_cols = lad.cols
		ladder_top = lad.top
		off = model.week_off.min(Scroll.last_offset(lad.heights, lad.room))
		n_shown = Scroll.shown(lad.heights, off, lad.room)
		_ = List.fold_try!(
			List.take_first(List.drop_first(List.map_with_index(model.plan, |p, i| { p, i }), off), n_shown),
			{ y: ladder_top },
			|acc, x| {
				lines = row_lines(x.p, row_cols)
				res = Wrap.fit(result_text(x.p), row_cols, 1)
				nl = U64.to_f32(List.len(lines))
				row_h = row_height(x.p, row_cols)
				ly = acc.y
				ink = if (x.p.today) Color.white else if (x.p.past) ink_faint else ink_muted
				if x.p.today {
					frame.rectangle!({ x: 34.0, y: ly - 4.0, width: win_w - 68.0, height: row_h - 3.0, style: Draw.filled(Color.with_alpha(Color.white, 14)) })
				}
				Text.from(x.p.day, model.font).size(12).draw!(frame, { pos: { x: 44.0, y: ly }, color: ink, align: (Top, Left) })
				frame.rounded_rectangle!({ x: 150.0, y: ly + 2.0, width: 92.0, height: 16.0, radius: 5.0, segments: 4, style: Draw.filled(Color.with_alpha(type_color(x.p.typ), 45)) })
				Text.from(x.p.typ, model.font).size(11).draw!(frame, { pos: { x: 196.0, y: ly + 3.0 }, color: type_color(x.p.typ), align: (Top, Center) })
				List.for_each!(List.map_with_index(lines, |ln, i| { ln, i }), |d|
					Text.from(d.ln, model.font).size(12).draw!(frame, { pos: { x: 260.0, y: ly + U64.to_f32(d.i) * 18.0 }, color: ink, align: (Top, Left) }))
				k = kind_of(x.p)
				rcol = if (k == Done) Theme.tsb_c else ink_faint
				List.for_each!(List.map_with_index(res, |ln, i| { ln, i }), |d|
					Text.from(d.ln, model.font).size(11).draw!(frame, { pos: { x: 260.0, y: ly + nl * 18.0 + U64.to_f32(d.i) * 16.0 }, color: rcol, align: (Top, Left) }))
				scol = if (k == Done) Theme.tsb_c else if (k == Rested) Theme.tsb_c else if (k == Open and x.p.today) Theme.ctl_c else ink_faint
				Text.from(status_text(x.p), model.font).size(12).draw!(frame, { pos: { x: win_w - 44.0, y: ly }, color: scol, align: (Top, Right) })
				Ok({ y: ly + row_h })
			},
		)?
		Scroll.draw!(frame, model.font, { x: win_w - 30.0, top: ladder_top, bottom: ladder_top + lad.room, hint_x: 260.0 }, off, n_shown, List.len(model.plan))

		# load strip + coach corner. The week's session count lives in the
		# quest label only; the strip states load, Monday-aligned on both sides.
		strip = "${Db.num_unit(model.week_tss.this, "tss")} this week (last ${Db.grouped(model.week_tss.last)})"
		Text.from(strip, model.font).size(13).draw!(frame, { pos: { x: 36.0, y: win_h - 84.0 }, color: ink_muted, align: (Top, Left) })
		Text.from("coach: ${model.bus_note}", model.font).size(11).draw!(frame, { pos: { x: 36.0, y: win_h - 60.0 }, color: ink_faint, align: (Top, Left) })
		model.plan_hint.draw!(frame, { pos: { x: 36.0, y: win_h - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}

	blank_row : Db.PlanRow
	blank_row = { day: "2026-11-02", wi: 0, typ: "endurance", detail: "", rationale: "", status: "open", reason: "", today: Bool.False, past: Bool.True, done_day: "", act_name: "", act_secs: 0, act_load: 0, sub_id: 0, sub_name: "", tgt_reps: 0, tgt_dur_s: 0, tgt_watts: 0.0, tgt_lit: "", tgt_res: "", det_reps: 0, det_dur_s: 0, det_watts: 0.0, day_load_known: Bool.True, day_load: 0.0 }

	# each pip is its weekday: Mon done, Tue skipped with a substitute, Wed
	# done, Thu today and open, Fri ahead, Sat holds nothing, Sun rest ahead
	expect {
		rows = [
			{ ..blank_row, wi: 0, status: "done" },
			{ ..blank_row, wi: 1, status: "skipped", sub_id: 7 },
			{ ..blank_row, wi: 2, status: "done" },
			{ ..blank_row, wi: 3, past: Bool.False, today: Bool.True },
			{ ..blank_row, wi: 4, past: Bool.False },
			{ ..blank_row, wi: 6, typ: "rest", past: Bool.False, day_load_known: Bool.False },
			{ ..blank_row, wi: 7, past: Bool.False },
		]
		week_kinds(rows) == [Done, Substituted, Done, Open, Future, NoSession, Future]
	}

	# a skip without a substitute, and the rest-day rule on its three inputs
	expect kind_of({ ..blank_row, status: "skipped" }) == Skipped
	expect kind_of({ ..blank_row, typ: "rest" }) == Rested
	expect kind_of({ ..blank_row, typ: "rest", day_load: 1.0 }) == Open
	expect kind_of({ ..blank_row, typ: "rest", day_load_known: Bool.False }) == Open
	expect kind_of({ ..blank_row, typ: "rest", past: Bool.False, today: Bool.True }) == Open

	# the share rounds to the nearest whole percent; no target, no label
	expect pct_label(228.0, 225.0) == "101%"
	expect pct_label(224.0, 225.0) == "100%"
	expect pct_label(220.0, 225.0) == "98%"
	expect pct_label(220.0, 0.0) == ""

	expect status_text({ ..blank_row, status: "done", done_day: "2026-11-03" }) == "done 2026-11-03"
	expect status_text({ ..blank_row, status: "done", done_day: "2026-11-02" }) == "done"
	expect status_text({ ..blank_row, past: Bool.False, today: Bool.True }) == ">>"

	expect result_text({ ..blank_row, status: "done", act_name: "Ride", act_secs: 3600, act_load: 62, tgt_reps: 2, tgt_dur_s: 900, tgt_watts: 225.0, det_reps: 2, det_dur_s: 905, det_watts: 228.0 }) == "Ride - 60 min - load 62 - 2x15:05 @ 228W - 101% of 2x15:00 @ 225W"
	expect result_text({ ..blank_row, status: "done", act_name: "Ride", act_secs: 3600, act_load: 62, tgt_reps: 2, tgt_dur_s: 900, tgt_watts: 225.0 }) == "Ride - 60 min - load 62 - target 2x15:00 @ 225W, no power intervals detected"
	expect result_text({ ..blank_row, status: "done", act_name: "Trail run", act_secs: 3600, act_load: 55, tgt_lit: "5x4:00@4:10/km" }) == "Trail run - 60 min - load 55 - target 5x4:00@4:10/km"
	# every other target kind states the result `complete` stored beside it
	expect result_text({ ..blank_row, status: "done", act_name: "Ride", act_secs: 3600, act_load: 60, tgt_lit: "1x1:00:00@HR125-147", tgt_res: "HR in band 52:10, over 3:05, under 4:45, mean 138 bpm" }) == "Ride - 60 min - load 60 - target 1x1:00:00@HR125-147; HR in band 52:10, over 3:05, under 4:45, mean 138 bpm"
	expect result_text({ ..blank_row, status: "done", act_name: "Row", act_secs: 5400, act_load: 70, tgt_lit: "1x1:30:00@Z2", tgt_res: "in zone 1:10:00, above 5:00, below 15:00" }) == "Row - 90 min - load 70 - target 1x1:30:00@Z2; in zone 1:10:00, above 5:00, below 15:00"
	expect result_text({ ..blank_row, status: "done", act_name: "Pool swim", act_secs: 2700, act_load: 40, tgt_lit: "10x100m@1:40/100m", tgt_res: "whole session at 1:44/100m" }) == "Pool swim - 45 min - load 40 - target 10x100m@1:40/100m; whole session at 1:44/100m"
	expect result_text({ ..blank_row, status: "done", act_name: "Strength", act_secs: 2700, act_load: 45, tgt_lit: "1x45:00@RPE6", tgt_res: "rated 7.0" }) == "Strength - 45 min - load 45 - target 1x45:00@RPE6; rated 7.0"
	expect result_text({ ..blank_row, status: "skipped", reason: "sick", sub_id: 7, sub_name: "Z2 Ride" }) == "skipped: sick -> Z2 Ride"
	expect result_text({ ..blank_row, status: "skipped" }) == "skipped"
	expect result_text({ ..blank_row, past: Bool.False }) == ""
}
