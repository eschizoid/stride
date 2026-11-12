import rr.Color
import rr.Draw
import core.Fmt
import Db
import Labels
import Scene
import Theme
import Ui

Weeks :: [].{
	# The weeks tab. Time in zone (view 6) and weekly load (view 7) chart the
	# same twelve Monday weeks on the same x-axis, so they share one nav pill
	# and switch by chips in the header: zones (the default) and load. The
	# two view ids stay distinct, so a bus directive for either lands on this
	# tab in the matching mode and a capture is named for its mode. One week
	# is in focus across both modes: the hovered bar, else the one clicked,
	# and the header line reads it the same way in either mode.
	modes : List({ v : U8, label : Str })
	modes = [{ v: 6, label: "zones" }, { v: 7, label: "load" }]

	is_week : U8 -> Bool
	is_week = |v| v == 6 or v == 7

	# the pill a view lights: both modes light the zones pill
	group : U8 -> U8
	group = |v| if (is_week(v)) 6 else v

	# a click on the weeks pill keeps the mode on screen; from any other view
	# it opens the zones mode
	from_pill : U8, U8 -> U8
	from_pill = |pill, current| if (pill == 6 and is_week(current)) current else pill

	chip_w : F32
	chip_w = 46.0

	chip_x : U64 -> F32
	chip_x = |i| 36.0 + U64.to_f32(i) * 54.0

	chip_top : F32
	chip_top = 64.0

	chip_bottom : F32
	chip_bottom = 86.0

	# the view a click at (x, y) picks, or -1 when it misses every chip
	mode_at : F32, F32 -> I64
	mode_at = |x, y|
		if y < chip_top or y > chip_bottom {
			-1
		} else {
			List.fold(
				List.map_with_index(modes, |m, i| { m, i }),
				-1,
				|acc, e| if (x >= chip_x(e.i) and x <= chip_x(e.i) + chip_w) (U8.to_i64(e.m.v)) else acc,
			)
		}

	# each mode's title starts right of the chips, on the same row
	title_x : F32
	title_x = chip_x(List.len(modes)) + 12.0

	# ── the bar band both modes draw: twelve slots across the panel ──────
	pad : F32
	pad = 36.0

	bars_top : F32
	bars_top = 168.0

	bars_bot : F32 -> F32
	bars_bot = |win_h| win_h - 96.0

	slot_w : F32, U64 -> F32
	slot_w = |win_w, n| if (n == 0) (win_w - pad * 2.0) else (win_w - pad * 2.0) / U64.to_f32(n)

	slot_cx : F32, U64, U64 -> F32
	slot_cx = |win_w, n, i| pad + (U64.to_f32(i) + 0.5) * slot_w(win_w, n)

	# the slot under (x, y), counted over the band a bar and its cap occupy,
	# or -1 outside it
	slot_at : F32, F32, U64, F32, F32 -> I64
	slot_at = |win_w, win_h, n, x, y|
		if n == 0 or y < bars_top - 44.0 or y > bars_bot(win_h) or x < pad or x >= win_w - pad {
			-1
		} else {
			raw = F32.div_floor_by(x - pad, slot_w(win_w, n))
			i = F32.round_to_i64_try(raw) ?? -1
			if (i >= 0 and i < (U64.to_i64_try(n) ?? 0)) i else -1
		}

	# a week the series covers fewer than all seven days of is still running,
	# and both modes draw it muted rather than judge it
	partial : I64 -> Bool
	partial = |days| days < 7

	# the week a mode's bars are keyed by, for each slot
	weeks_of : Ui.Model -> List(Str)
	weeks_of = |model| if (model.view == 7) (List.map(model.ramp_weeks, |w| w.wk)) else List.map(model.zone_weeks, |w| w.wk)

	hovered_week : Ui.Model -> Str
	hovered_week = |model| {
		wks = weeks_of(model)
		i = slot_at(model.win.w, model.win.h, List.len(wks), model.mouse_x, model.mouse_y)
		if (i < 0) "" else (List.get(wks, I64.to_u64_try(i) ?? 0)).ok_or("")
	}

	# the week in focus: the hovered bar, else the one clicked, else none
	focus_week : Ui.Model -> Str
	focus_week = |model| {
		h = hovered_week(model)
		if (h != "") h else model.week_cursor
	}

	# a click on a bar picks its week; a click on the picked week drops it
	pick : Str, Str -> Str
	pick = |current, clicked| if (clicked == "" or clicked == current) "" else clicked

	# the shared header line for a week: hours in zones, load, easy share and
	# the fitness it gained, each part only when its mode has the week
	week_line : Str, List(Db.ZoneWeek), List(Db.RampWeek) -> Str
	week_line = |wk, zws, rws| {
		z = List.first(List.keep_if(zws, |w| w.wk == wk))
		r = List.first(List.keep_if(rws, |w| w.wk == wk))
		parts = List.join([
			match z {
				Ok(zw) => {
					tot = zw.z1 + zw.z2 + zw.z3 + zw.z4 + zw.z5
					itot = zw.easy + zw.moderate + zw.hard
					share = if (itot <= 0) "no classified time" else if (zw.days < 7) "easy ${I64.to_str(zw.easy * 100 // itot)}% so far, ${I64.to_str(zw.days)} of 7 days" else "easy ${I64.to_str(zw.easy * 100 // itot)}%"
					[hours(tot), share]
				}
				Err(_) => []
			},
			match r {
				Ok(rw) => [Db.num_unit(rw.tss, "load"), "ctl ${Fmt.tenths_signed(rw.ramp10)}/wk"]
				Err(_) => []
			},
		])
		"wk of ${wk}   ${Str.join_with(parts, "   ")}"
	}

	hours : I64 -> Str
	hours = |secs| {
		h10 = secs * 10 // 3600
		"${Db.grouped(h10 // 10)}.${I64.to_str(h10 % 10)} h"
	}

	chip_box : U64 -> Labels.Rect
	chip_box = |i| { x: chip_x(i), y: chip_top, w: chip_w, h: chip_bottom - chip_top }

	# the chips' shapes; their labels are fixed text in each mode's scene
	draw_chips! : Ui.Model, Draw.Frame => {}
	draw_chips! = |model, frame|
		List.for_each!(
			List.map_with_index(modes, |m, i| { m, i }),
			|e| {
				b = chip_box(e.i)
				on = e.m.v == model.view
				hov = model.mouse_x >= b.x and model.mouse_x <= b.x + b.w and model.mouse_y >= b.y and model.mouse_y <= b.y + b.h
				style = if (on) (Draw.filled(Color.with_alpha(Theme.ctl_c, 60))) else if (hov) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
				frame.rounded_rectangle!({ x: b.x, y: b.y, width: b.w, height: b.h, radius: 6.0, segments: 6, style })
			},
		)

	# each chip's label inside its chip, the one on screen lit
	chip_texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	chip_texts = |model, measure| List.map_with_index(modes, |m, i| Scene.fixed(measure, Scene.data(m.label, 12.0, if (m.v == model.view) Color.white else Theme.ink_muted), { x: chip_x(i) + chip_w / 2.0, y: 68.0, align: Center }, chip_box(i)))

	chip_marks : List(Labels.Mark)
	chip_marks = List.map_with_index(modes, |m, i| { key: "the ${m.label} chip", box: chip_box(i) })

	# the header row under the chips: the focused week, else the mode's key
	focus_text : Ui.Model, Scene.Measure, Str -> Labels.Label(Scene.Item)
	focus_text = |model, measure, key| {
		wk = focus_week(model)
		it = if (wk == "") Scene.data(key, 11.0, Theme.ink_faint) else Scene.data(week_line(wk, model.zone_weeks, model.ramp_weeks), 12.0, Color.white)
		Scene.fixed(measure, it, { x: pad, y: 96.0, align: Left }, Labels.panel(model.win))
	}

	# the headline card at the header's right: where the newest week stands,
	# in the form board's KPI card style
	card_box : F32 -> Labels.Rect
	card_box = |win_w| { x: win_w - pad - 260.0, y: 60.0, w: 260.0, h: 64.0 }

	# a bar's cap or chip, 54 wide over its slot's centre, never above the band
	cap_box : F32, F32 -> Labels.Rect
	cap_box = |cx, top| { x: cx - 27.0, y: F32.max(bars_top - 30.0, top - 30.0), w: 54.0, h: 20.0 }

	# the week a slot's date label names, every other slot
	week_label : Str -> Str
	week_label = |wk| Str.from_utf8_lossy(List.drop_first(Str.to_utf8(wk), 5))
}

expect Weeks.partial(6) and !Weeks.partial(7)
expect Weeks.group(6) == 6 and Weeks.group(7) == 6 and Weeks.group(4) == 4
expect Weeks.from_pill(6, 7) == 7 and Weeks.from_pill(6, 1) == 6 and Weeks.from_pill(8, 7) == 8
expect Weeks.mode_at(40.0, 70.0) == 6 and Weeks.mode_at(100.0, 70.0) == 7
expect Weeks.mode_at(40.0, 100.0) == -1 and Weeks.mode_at(84.0, 70.0) == -1 and Weeks.mode_at(150.0, 70.0) == -1
# the titles clear the second chip
expect Weeks.title_x > Weeks.chip_x(1) + Weeks.chip_w
# twelve slots over a 980-wide panel: the first and last slot, and outside
expect Weeks.slot_at(980.0, 600.0, 12, 40.0, 300.0) == 0
expect Weeks.slot_at(980.0, 600.0, 12, 943.0, 300.0) == 11
expect Weeks.slot_at(980.0, 600.0, 12, 20.0, 300.0) == -1 and Weeks.slot_at(980.0, 600.0, 12, 400.0, 100.0) == -1 and Weeks.slot_at(980.0, 600.0, 0, 400.0, 300.0) == -1
# picking a week, picking another, and clicking the picked one again
expect Weeks.pick("", "2026-11-02") == "2026-11-02" and Weeks.pick("2026-11-02", "2026-10-26") == "2026-10-26" and Weeks.pick("2026-11-02", "2026-11-02") == "" and Weeks.pick("2026-11-02", "") == ""
# one line reads the week from both modes; a week only one mode has gets
# only that mode's parts
expect {
	zw = [{ wk: "2026-11-02", days: 7, z1: 3600, z2: 18000, z3: 3600, z4: 0, z5: 0, easy: 21600, moderate: 3600, hard: 0 }]
	rw = [{ wk: "2026-11-02", days: 7, tss: 393, ctl10: 496, ramp10: 10 }]
	Weeks.week_line("2026-11-02", zw, rw) == "wk of 2026-11-02   7.0 h   easy 85%   393 load   ctl +1.0/wk"
		and Weeks.week_line("2026-11-02", [], rw) == "wk of 2026-11-02   393 load   ctl +1.0/wk"
}
expect {
	zw = [{ wk: "2026-11-09", days: 3, z1: 0, z2: 7200, z3: 0, z4: 0, z5: 0, easy: 7200, moderate: 0, hard: 0 }]
	Weeks.week_line("2026-11-09", zw, []) == "wk of 2026-11-09   2.0 h   easy 100% so far, 3 of 7 days"
}
