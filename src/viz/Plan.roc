import rr.Color
import rr.Draw
import core.Fmt
import Chrome
import Days
import Db
import Labels
import Scene
import Scroll
import Theme
import Ui
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

	title_text : Str
	title_text = "the week and the days ahead"

	hint_text : Str
	hint_text = "week / log / year  modes      wheel or up/down  scroll      TAB  lifts      R  reload      S  screenshot      V  record      ESC quit"

	# ── the layout the drawing, the scene and the gate share ───────────────
	# the week as a quest: one pip per weekday, Monday first, right-aligned
	# on the title row
	pip_w : F32
	pip_w = 18.0

	pips_x : F32 -> F32
	pips_x = |win_w| win_w - 36.0 - 7.0 * (pip_w + 4.0)

	pip_box : F32, U64 -> Labels.Rect
	pip_box = |win_w, i| { x: pips_x(win_w) + U64.to_f32(i) * (pip_w + 4.0), y: 70.0, w: pip_w, h: 8.0 }

	# today's card and the type stripe down its left side
	card_box : F32, F32 -> Labels.Rect
	card_box = |win_w, h| { x: 36.0, y: 100.0, w: win_w - 72.0, h }

	stripe_box : F32 -> Labels.Rect
	stripe_box = |h| { x: 52.0, y: 116.0, w: 10.0, h: h - 32.0 }

	# a ladder row's type pill
	type_pill : F32 -> Labels.Rect
	type_pill = |top| { x: 150.0, y: top + 2.0, w: 92.0, h: 16.0 }

	# the ladder rows on screen from the scroll offset, each with its top
	# and height, and where the scrollbar and its hints sit
	shown_rows : Ui.Model -> { rows : List({ p : Db.PlanRow, top : F32, h : F32 }), off : U64, n_shown : U64, cols : U64, at : { x : F32, top : F32, bottom : F32, hint_x : F32 } }
	shown_rows = |model| {
		lad = ladder(model)
		off = model.week_off.min(Scroll.last_offset(lad.heights, lad.room))
		n_shown = Scroll.shown(lad.heights, off, lad.room)
		walk = List.fold(
			List.take_first(List.drop_first(model.plan, off), n_shown),
			{ out: [], y: lad.top },
			|acc, p| {
				h = row_height(p, lad.cols)
				{ out: List.append(acc.out, { p, top: acc.y, h }), y: acc.y + h }
			},
		)
		{ rows: walk.out, off, n_shown, cols: lad.cols, at: { x: model.win.w - 30.0, top: lad.top, bottom: lad.top + lad.room, hint_x: 260.0 } }
	}

	# the scrollbar's track, when the ladder outgrows its room
	scroll_box : Ui.Model -> Try(Labels.Rect, [Fits])
	scroll_box = |model| {
		s = shown_rows(model)
		h = Scroll.hidden(s.off, s.n_shown, List.len(model.plan))
		if (h.above == 0 and h.below == 0) Err(Fits) else Ok({ x: s.at.x, y: s.at.top, w: 3.0, h: s.at.bottom - s.at.top })
	}

	# ── every string the view writes, placed ───────────────────────────────
	# All of it is fixed: the title and the quest label, today's card, each
	# ladder row's day, type, prescription, outcome and status, the scroll
	# hints, the load strip, the coach corner, the footer and the mode chips.
	scene : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	scene = |model, measure| Labels.place(texts(model, measure), { boxes: Chrome.boxes(model, measure), segs: [] })

	# the view's text and the chrome's, as the gate judges them
	owned : Ui.Model, Scene.Measure -> List(Labels.Owned)
	owned = |model, measure| List.concat(Scene.owned(Chrome.placed(model, measure)), Scene.owned(scene(model, measure)))

	texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	texts = |model, measure| {
		win_w = model.win.w
		win_h = model.win.h
		panel = Labels.panel(model.win)
		ink_muted = Theme.ink_muted
		ink_faint = Theme.ink_faint
		fix = |it, x, y, align, region| Scene.fixed(measure, it, { x, y, align }, region)
		head = [fix(Scene.prepared(model.plan_title, title_text, 15.0, Prose, ink_muted), Days.title_x, 70.0, Left, panel)]
		# the quest label counts the done sessions beside the pips
		qt = model.plan_week.total
		qd = model.plan_week.done
		quest =
			if qt > 0 {
				complete = qd >= qt
				[fix(Scene.data(if (complete) "week complete" else "quest ${I64.to_str(qd)}/${I64.to_str(qt)}", 11.0, if (complete) Theme.gold_c else ink_muted), pips_x(win_w) - 10.0, 72.0, Right, panel)]
			} else {
				[]
			}
		card = today_card(model.plan, win_w)
		cb = card_box(win_w, card.h)
		nd = U64.to_f32(List.len(card.dlines))
		card_texts = List.join([
			[fix(Scene.data(card.head, 14.0, type_color(card.today.typ)), 76.0, 112.0, Left, cb)],
			List.map_with_index(card.dlines, |ln, i| fix(Scene.data(ln, 13.0, Color.white), 76.0, 134.0 + U64.to_f32(i) * 19.0, Left, cb)),
			List.map_with_index(card.rlines, |ln, i| fix(Scene.data(ln, 11.0, ink_faint), 76.0, 134.0 + nd * 19.0 + 4.0 + U64.to_f32(i) * 16.0, Left, cb)),
		])
		# the ladder: Monday through the days ahead. A past or current day
		# takes one line of prescription (the card holds today's in full) and
		# one of outcome, and a day ahead up to three, so the coming days fit
		# under the week's history. Rows that do not fit above the load strip
		# scroll (Scroll), so no day is ever shed.
		s = shown_rows(model)
		rows = List.join(
			List.map(
				s.rows,
				|r| {
					lines = row_lines(r.p, s.cols)
					nl = U64.to_f32(List.len(lines))
					ink = if (r.p.today) Color.white else if (r.p.past) ink_faint else ink_muted
					k = kind_of(r.p)
					rcol = if (k == Done) Theme.tsb_c else ink_faint
					scol = if (k == Done) Theme.tsb_c else if (k == Rested) Theme.tsb_c else if (k == Open and r.p.today) Theme.ctl_c else ink_faint
					List.join([
						[
							fix(Scene.data(r.p.day, 12.0, ink), 44.0, r.top, Left, panel),
							fix(Scene.data(r.p.typ, 11.0, type_color(r.p.typ)), 196.0, r.top + 3.0, Center, type_pill(r.top)),
						],
						List.map_with_index(lines, |ln, i| fix(Scene.data(ln, 12.0, ink), 260.0, r.top + U64.to_f32(i) * 18.0, Left, panel)),
						List.map_with_index(Wrap.fit(result_text(r.p), s.cols, 1), |ln, i| fix(Scene.data(ln, 11.0, rcol), 260.0, r.top + nl * 18.0 + U64.to_f32(i) * 16.0, Left, panel)),
						[fix(Scene.data(status_text(r.p), 12.0, scol), win_w - 44.0, r.top, Right, panel)],
					])
				},
			),
		)
		# load strip + coach corner. The week's session count lives in the
		# quest label only; the strip states load, Monday-aligned on both
		# sides.
		strip = "${Db.num_unit(model.week_tss.this, "tss")} this week (last ${Db.grouped(model.week_tss.last)})"
		foot = [
			fix(Scene.data(strip, 13.0, ink_muted), 36.0, win_h - 84.0, Left, panel),
			fix(Scene.data("coach: ${model.bus_note}", 11.0, ink_faint), 36.0, win_h - 60.0, Left, panel),
			fix(Scene.prepared(model.plan_hint, hint_text, 13.0, Prose, ink_faint), 36.0, win_h - 30.0, Left, panel),
		]
		List.join([head, quest, card_texts, rows, Scroll.hints(measure, s.at, s.off, s.n_shown, List.len(model.plan), panel), foot, Days.chip_texts(model, measure)])
	}

	# the shapes no text may cover but its own: the pills, the mode chips,
	# the quest pips, today's card and its stripe, each row's type pill and
	# the scrollbar
	marks : Ui.Model -> List(Labels.Mark)
	marks = |model| {
		card = today_card(model.plan, model.win.w)
		List.join([
			Chrome.marks(model),
			Days.chip_marks,
			if (model.plan_week.total > 0) [{ key: "the quest pips", box: { x: pips_x(model.win.w), y: 70.0, w: 7.0 * (pip_w + 4.0) - 4.0, h: 8.0 } }] else [],
			[{ key: "today's card", box: card_box(model.win.w, card.h) }, { key: "today's stripe", box: stripe_box(card.h) }],
			List.map((shown_rows(model)).rows, |r| { key: "the ${r.p.day} type pill", box: type_pill(r.top) }),
			match scroll_box(model) {
				Ok(b) => [{ key: "the scrollbar", box: b }]
				Err(_) => []
			},
		])
	}

	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		win_w = model.win.w
		# the quest pips, colored by what became of each day; the whole row
		# pulses when every prescribed session is done
		qt = model.plan_week.total
		if qt > 0 {
			complete = model.plan_week.done >= qt
			t9 = model.tick % 40
			tri9 = (if (t9 < 20) (U64.to_f32(t9)) else U64.to_f32(40 - t9)) / 20.0
			pulse_a = (F32.round_to_u64_try(200.0 + tri9 * 55.0) ?? 255).to_u8_try() ?? 255
			List.for_each!(
				List.map_with_index(week_kinds(model.plan), |k, i| { k, i }),
				|q| {
					b = pip_box(win_w, q.i)
					c = if (complete and q.k == Done) (Color.with_alpha(Theme.gold_c, pulse_a)) else pip_color(q.k)
					frame.rounded_rectangle!({ x: b.x, y: b.y, width: b.w, height: b.h, radius: 4.0, segments: 4, style: Draw.filled(c) })
				},
			)
		}
		card = today_card(model.plan, win_w)
		cb = card_box(win_w, card.h)
		sb = stripe_box(card.h)
		frame.rounded_rectangle!({ x: cb.x, y: cb.y, width: cb.w, height: cb.h, radius: 10.0, segments: 8, style: Draw.filled(Theme.card) })
		frame.rounded_rectangle!({ x: sb.x, y: sb.y, width: sb.w, height: sb.h, radius: 4.0, segments: 4, style: Draw.filled(type_color(card.today.typ)) })
		s = shown_rows(model)
		List.for_each!(
			s.rows,
			|r| {
				if r.p.today {
					frame.rectangle!({ x: 34.0, y: r.top - 4.0, width: win_w - 68.0, height: r.h - 3.0, style: Draw.filled(Color.with_alpha(Color.white, 14)) })
				}
				pb = type_pill(r.top)
				frame.rounded_rectangle!({ x: pb.x, y: pb.y, width: pb.w, height: pb.h, radius: 5.0, segments: 4, style: Draw.filled(Color.with_alpha(type_color(r.p.typ), 45)) })
			},
		)
		Scroll.draw!(frame, s.at, s.off, s.n_shown, List.len(model.plan))
		Scene.draw!(frame, model, scene(model, Scene.measure_of(model)))
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
