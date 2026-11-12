import rr.Color
import rr.Draw
import rr.Text
import Db
import Theme
import Ui

# ── the athlete HUD: level, streak, form ────────────────────────────
#
# The one surface a game window has that a web dashboard cannot: persistent
# character state. The XP rail rides the panel's left edge on every view;
# the detail lives where it belongs (career sheet, plan quest, curve PRs).
Hud :: [].{
	# career hours -> level. Cumulative hours to reach level L is 5*L*(L+1),
	# so each level costs 10 more hours than the last: level 1 at 10h, level
	# 10 at 550h, level 20 at 2100h. A new athlete levels every few weeks, a
	# ten-year one still has a next rung that means something.
	level_of : I64 -> I64
	level_of = |hours| level_climb(hours, 0)

	level_climb : I64, I64 -> I64
	level_climb = |hours, l|
		if (5 * (l + 1) * (l + 2) <= hours) level_climb(hours, l + 1) else l

	# progress through the current level, 0..1
	xp_frac : I64 -> F32
	xp_frac = |hours| {
		l = level_of(hours)
		into = hours - 5 * l * (l + 1)
		cost = 10 * (l + 1)
		I64.to_f32(into) / I64.to_f32(cost)
	}

	# hours still to climb before the next level
	hours_to_next : I64 -> I64
	hours_to_next = |hours| {
		l = level_of(hours)
		5 * (l + 1) * (l + 2) - hours
	}

	tier : I64 -> Str
	tier = |l|
		if (l < 10) "rookie"
		else if (l < 20) "grinder"
		else if (l < 30) "engine"
		else if (l < 40) "machine"
		else "legend"

	total_hours : List(Db.CareerSport) -> I64
	total_hours = |sports|
		List.fold(sports, 0.I64, |a, s| a + s.hours10) // 10

	# consecutive Mon-Sun weeks with any load, counted back from the newest
	# heat day. daily_load carries decay days, so heat has a row per calendar
	# day and dow==1 marks each Monday. A loadless week still in progress
	# does not break the streak - the week is not over.
	streak_weeks : List(Db.HeatDay) -> I64
	streak_weeks = |heat| {
		folded = List.fold(
			heat,
			{ weeks: [], cur: Bool.False, seen: Bool.False },
			|a, d| {
				if d.dow == 1 and a.seen {
					{ weeks: List.append(a.weeks, a.cur), cur: d.tss > 0, seen: Bool.True }
				} else {
					{ weeks: a.weeks, cur: a.cur or (d.tss > 0), seen: Bool.True }
				}
			},
		)
		all = if (folded.seen) List.append(folded.weeks, folded.cur) else folded.weeks
		# the newest week only counts while it has load; empty-so-far is skipped
		trimmed = match List.last(all) {
			Ok(last) => if (last) all else List.take_first(all, List.len(all) - 1)
			Err(_) => all
		}
		count_back(trimmed)
	}

	count_back : List(Bool) -> I64
	count_back = |flags|
		match List.last(flags) {
			Ok(f) => if (f) (count_back(List.take_first(flags, List.len(flags) - 1)) + 1) else 0
			Err(_) => 0
		}

	# the form verdict a TSB value earns, in the app's own voice
	form_band : F32 -> { label : Str, c : Color.Rgba }
	form_band = |tsb|
		if (tsb < -30.0) ({ label: "cooked", c: Theme.alarm_c })
		else if (tsb < -10.0) ({ label: "building", c: Theme.atl_c })
		else if (tsb < 5.0) ({ label: "steady", c: Theme.ink_muted })
		else if (tsb < 25.0) ({ label: "primed", c: Theme.gold_c })
		else { label: "coasting", c: Theme.tsb_c }

	# The streak flame, still: an ember body that tapers to a pointed tip
	# flicked to the right, a smaller tongue on the left, and a gold core low
	# in the body. Geometry only (the font atlas is ascii-only). A still
	# frame has to read as fire on its own, so the asymmetry carries the
	# motion a sway would. Triangles list their corners counter-clockwise
	# on screen, the winding the host fills.
	FlamePart : [Disc({ cx : F32, cy : F32, r : F32 }), Tri({ a : { x : F32, y : F32 }, b : { x : F32, y : F32 }, c : { x : F32, y : F32 } })]

	flame_shape : F32, F32 -> List({ part : FlamePart, tone : [Ember, Gold], a : U8 })
	flame_shape = |x, y| [
		{ part: Disc({ cx: x, cy: y + 2.6, r: 4.2 }), tone: Ember, a: 200 },
		{ part: Tri({ a: { x: x + 1.8, y: y - 9.5 }, b: { x: x - 4.1, y: y + 2.0 }, c: { x: x + 4.1, y: y + 2.0 } }), tone: Ember, a: 230 },
		{ part: Tri({ a: { x: x - 2.9, y: y - 4.8 }, b: { x: x - 4.2, y: y + 1.5 }, c: { x: x - 0.6, y: y + 1.5 } }), tone: Ember, a: 190 },
		{ part: Disc({ cx: x + 0.1, cy: y + 3.1, r: 2.2 }), tone: Gold, a: 255 },
		{ part: Tri({ a: { x: x + 0.8, y: y - 3.2 }, b: { x: x - 2.0, y: y + 2.8 }, c: { x: x + 2.1, y: y + 2.8 } }), tone: Gold, a: 235 },
	]

	flame! : Draw.Frame, F32, F32 => {}
	flame! = |frame, x, y|
		List.for_each!(
			flame_shape(x, y),
			|p| {
				col = Color.with_alpha((if (p.tone == Gold) Theme.gold_c else Theme.ember_c), p.a)
				match p.part {
					Disc(d) => frame.circle!({ center: { x: d.cx, y: d.cy }, radius: d.r, style: Draw.filled(col) })
					Tri(t) => frame.triangle!({ a: t.a, b: t.b, c: t.c, style: Draw.filled(col) })
				}
			},
		)

	# ── the XP rail: the panel's left edge, filled to level progress ──
	# Fills bottom-up over the first seconds of a session (eased), carries a
	# pulsing head, and answers on hover with the full sheet. The rail lives
	# at x 21..25, left of where every view starts drawing; the level number
	# under its foot is chrome text (Chrome.rail_level), placed and gated with
	# the rest of the chrome.
	rail! : Ui.Model, Draw.Frame => {}
	rail! = |model, frame| {
		hours = total_hours(model.career_sports)
		if (hours <= 0) {} else {
			lvl = level_of(hours)
			top = 40.0
			bot = model.win.h - 44.0
			span = bot - top
			# arrive over ~1.5s: the fill is the greeting
			arr0 = U64.to_f32(model.tick) / 90.0
			arr1 = if (arr0 > 1.0) (1.0) else arr0
			arr = 1.0 - (1.0 - arr1) * (1.0 - arr1)
			fill = span * xp_frac(hours) * arr
			frame.rounded_rectangle!({ x: 21.0, y: top, width: 4.0, height: span, radius: 2.0, segments: 4, style: Draw.filled(Color.with_alpha(Theme.card, 220)) })
			if fill > 3.0 {
				frame.rectangle_gradient_v!({ x: 21.0, y: bot - fill, width: 4.0, height: fill, color_top: Theme.gold_c, color_bottom: Color.with_alpha(Theme.ctl_c, 200) })
				# the head breathes on the tick
				t = model.tick % 40
				tri = (if (t < 20) (U64.to_f32(t)) else U64.to_f32(40 - t)) / 20.0
				frame.circle!({ center: { x: 23.0, y: bot - fill }, radius: 3.0 + tri * 1.2, style: Draw.filled(Color.with_alpha(Theme.gold_c, 200)) })
			}
			# hover the rail: the character sheet
			if model.mouse_in and model.mouse_x < 34.0 and model.mouse_y >= top and model.mouse_y <= bot {
				sk = streak_weeks(model.heat)
				frame.rounded_rectangle!({ x: 40.0, y: bot - 84.0, width: 250.0, height: 72.0, radius: 8.0, segments: 6, style: Draw.filled(Theme.card) })
				Text.from("level ${I64.to_str(lvl)} - ${tier(lvl)}", model.font).size(14).draw!(frame, { pos: { x: 54.0, y: bot - 72.0 }, color: Theme.gold_c, align: (Top, Left) })
				Text.from("${Db.num_unit(hours_to_next(hours), "h")} to level ${I64.to_str(lvl + 1)}", model.font).size(11).draw!(frame, { pos: { x: 54.0, y: bot - 52.0 }, color: Theme.ink_muted, align: (Top, Left) })
				Text.from("${I64.to_str(sk)} week streak", model.font).size(11).draw!(frame, { pos: { x: 54.0, y: bot - 36.0 }, color: Theme.ink_muted, align: (Top, Left) })
			}
		}
	}
}

# the static flame: its tip stands above the whole body, flicked right of
# centre so a still frame is not a symmetric teardrop, and the gold core
# sits low, below the tip's midpoint
expect {
	parts = Hud.flame_shape(100.0, 50.0)
	tips = List.keep_oks(
		parts,
		|p| match p.part {
			Tri(t) => Ok(t.a)
			Disc(_) => Err(NotTri)
		},
	)
	main_tip = List.first(tips) ?? { x: 0.0, y: 0.0 }
	cores = List.keep_if(parts, |p| p.tone == Gold)
	List.all(tips, |t| t.y >= main_tip.y) and main_tip.x > 100.0 and main_tip.y < 50.0 - 8.0 and List.len(cores) == 2 and List.all(
		cores,
		|c| match c.part {
			Disc(d) => d.cy > 50.0
			Tri(t) => t.a.y > main_tip.y + 4.0
		},
	)
}
