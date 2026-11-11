import rr.Color
import rr.Draw
import rr.Text
import Theme
import Ui

Days :: [].{
	# The day-by-day tab. The data table (view 3), the plan (view 4) and the
	# heatmap (view 5) all answer "what happened on which day", so they share
	# one nav pill and switch by chips in the header: week (the plan, the
	# default), log (the table) and year (the heatmap). The three view ids
	# stay distinct, so a bus directive for any of them lands on this tab in
	# the matching mode and a capture is named for its mode.
	modes : List({ v : U8, label : Str })
	modes = [{ v: 4, label: "week" }, { v: 3, label: "log" }, { v: 5, label: "year" }]

	is_day : U8 -> Bool
	is_day = |v| v == 3 or v == 4 or v == 5

	# the pill a view lights: every mode of the day tab lights the plan pill
	group : U8 -> U8
	group = |v| if (is_day(v)) 4 else v

	# TAB walks the nav left to right: form, power, trace, the day tab,
	# strength, zones, ramp, career, and back to form. Any day mode steps on
	# to strength, the pill after the day tab.
	next_view : U8 -> U8
	next_view = |v|
		if (v == 0) 1
		else if (v == 1) 2
		else if (v == 2) 4
		else if (is_day(v)) 9
		else if (v == 9) 6
		else if (v == 6) 7
		else if (v == 7) 8
		else 0

	# a click on the day tab's pill keeps the mode on screen; from any other
	# view it opens the week mode
	from_pill : U8, U8 -> U8
	from_pill = |pill, current| if (pill == 4 and is_day(current)) current else pill

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

	draw_chips! : Ui.Model, Draw.Frame => {}
	draw_chips! = |model, frame|
		List.for_each!(
			List.map_with_index(modes, |m, i| { m, i }),
			|e| {
				cx = chip_x(e.i)
				on = e.m.v == model.view
				hov = model.mouse_x >= cx and model.mouse_x <= cx + chip_w and model.mouse_y >= chip_top and model.mouse_y <= chip_bottom
				style = if (on) (Draw.filled(Color.with_alpha(Theme.ctl_c, 60))) else if (hov) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
				frame.rounded_rectangle!({ x: cx, y: chip_top, width: chip_w, height: 22.0, radius: 6.0, segments: 6, style })
				Text.from(e.m.label, model.font).size(12).draw!(frame, { pos: { x: cx + chip_w / 2.0, y: 68.0 }, color: if (on) Color.white else Theme.ink_muted, align: (Top, Center) })
			},
		)
}

expect Days.group(3) == 4 and Days.group(4) == 4 and Days.group(5) == 4 and Days.group(9) == 9
# TAB visits every pill once, in nav order, and comes back to form
expect {
	walk = List.fold([0, 1, 2, 3, 4, 5, 6, 7], [0.U8], |acc, _| List.append(acc, Days.next_view((List.last(acc)).ok_or(0))))
	walk == [0, 1, 2, 4, 9, 6, 7, 8, 0]
}
expect Days.next_view(3) == 9 and Days.next_view(5) == 9
expect Days.from_pill(4, 5) == 5 and Days.from_pill(4, 1) == 4 and Days.from_pill(6, 5) == 6
expect Days.mode_at(40.0, 70.0) == 4 and Days.mode_at(100.0, 70.0) == 3 and Days.mode_at(150.0, 70.0) == 5
expect Days.mode_at(40.0, 100.0) == -1 and Days.mode_at(84.0, 70.0) == -1
# the titles clear the third chip
expect Days.title_x > Days.chip_x(2) + Days.chip_w
