Labels :: [].{
	# ── the label placer every view routes its text through ───────────────
	# A label is a measured box, the spots it may take in order of
	# preference, a priority and the region it must stay inside. Obstacles
	# are what is on screen before any label: shapes as boxes, plotted lines
	# as segments. `place` takes the labels in priority order, lower first
	# and ties in input order, and gives each the first spot inside its
	# region that is clear of every obstacle box and of every label placed
	# before it. Among those spots, one no plotted line crosses wins; a line
	# through a label is accepted only when no spot avoids every line, since
	# a line stays readable under text and text does not stay readable under
	# text. A label with no clear spot is dropped, unless it keeps: a kept
	# label takes its first spot anyway, so essential text never vanishes,
	# and `check` is the gate that holds every kept label clear.
	#
	# Nothing here measures text or draws: Scene builds the labels from
	# measured strings and draws what this module placed.

	# a box by its top-left corner and size, in the window's logical units
	Rect : { x : F32, y : F32, w : F32, h : F32 }

	# a drawn line segment, in the same units
	Seg : { x0 : F32, y0 : F32, x1 : F32, y1 : F32 }

	Pt : { x : F32, y : F32 }

	Obstacles : { boxes : List(Rect), segs : List(Seg) }

	# `item` is the caller's own payload, carried through to the placement
	# untouched
	Label(a) : { w : F32, h : F32, spots : List(Pt), prio : U64, keep : Bool, region : Rect, item : a }

	Placed(a) : { box : Rect, region : Rect, item : a }

	# one box the gate judges: a name for the failure message, where it is,
	# and the region it belongs inside
	Owned : { key : Str, box : Rect, region : Rect }

	# the placements, in the labels' input order, every dropped label left out
	place : List(Label(a)), Obstacles -> List(Placed(a))
	place = |labels, obs| {
		order = List.sort_with(
			List.map_with_index(labels, |l, i| { prio: l.prio, i }),
			|a, b| if (a.prio < b.prio) Before else if (a.prio > b.prio) After else if (a.i < b.i) Before else if (a.i > b.i) After else Same,
		)
		taken = List.fold(
			order,
			[],
			|acc, o|
				match List.get(labels, o.i) {
					Ok(l) =>
						match spot_for(l, obs, List.map(acc, |p| p.box)) {
							Ok(b) => List.append(acc, { i: o.i, box: b })
							Err(_) => acc
						}
					Err(_) => acc
				},
		)
		List.keep_oks(
			List.map_with_index(labels, |l, i| { l, i }),
			|e|
				match List.find_first(taken, |t| t.i == e.i) {
					Ok(t) => Ok({ box: t.box, region: e.l.region, item: e.l.item })
					Err(_) => Err(Dropped)
				},
		)
	}

	# the box a label takes against the obstacles and the boxes already
	# placed: the first spot clear of everything, else the first clear of
	# every box though a line crosses it, else a kept label's first spot
	spot_for : Label(a), Obstacles, List(Rect) -> Try(Rect, [Dropped])
	spot_for = |l, obs, placed| {
		boxes = List.map(l.spots, |s| { x: s.x, y: s.y, w: l.w, h: l.h })
		roomy = List.keep_if(boxes, |b| inside(b, l.region) and !(List.any(obs.boxes, |o| intersects(b, o))) and !(List.any(placed, |o| intersects(b, o))))
		match List.find_first(roomy, |b| !(List.any(obs.segs, |s| crosses(b, s)))) {
			Ok(b) => Ok(b)
			Err(_) =>
				match List.first(roomy) {
					Ok(b) => Ok(b)
					Err(_) =>
						if l.keep {
							match List.first(boxes) {
								Ok(b) => Ok(b)
								Err(_) => Err(Dropped)
							}
						} else {
							Err(Dropped)
						}
				}
		}
	}

	# two boxes overlap when they share area; boxes that only touch along an
	# edge do not. Both tests forgive `slack`, a hundredth of a pixel, so a
	# box laid exactly against an edge is not judged across it by the
	# rounding of the sums that place it.
	intersects : Rect, Rect -> Bool
	intersects = |a, b| a.x + slack < b.x + b.w and b.x + slack < a.x + a.w and a.y + slack < b.y + b.h and b.y + slack < a.y + a.h

	# a box lies inside a region when no part of it is outside
	inside : Rect, Rect -> Bool
	inside = |b, r| b.x + slack >= r.x and b.y + slack >= r.y and b.x + b.w <= r.x + r.w + slack and b.y + b.h <= r.y + r.h + slack

	slack : F32
	slack = 0.01

	# a segment crosses a box when it passes through the box's rows over the
	# box's columns; a vertical one crosses when its x is inside the box and
	# its span meets the box's rows
	crosses : Rect, Seg -> Bool
	crosses = |b, s| {
		lo_x = F32.max(b.x, F32.min(s.x0, s.x1))
		hi_x = F32.min(b.x + b.w, F32.max(s.x0, s.x1))
		if lo_x > hi_x {
			Bool.False
		} else if s.x1 == s.x0 {
			F32.min(s.y0, s.y1) < b.y + b.h and F32.max(s.y0, s.y1) > b.y
		} else {
			ya = s.y0 + (s.y1 - s.y0) * (lo_x - s.x0) / (s.x1 - s.x0)
			yb = s.y0 + (s.y1 - s.y0) * (hi_x - s.x0) / (s.x1 - s.x0)
			F32.min(ya, yb) < b.y + b.h and F32.max(ya, yb) > b.y
		}
	}

	# the left edge of a w-wide box whose anchor sits at x, the way a text
	# draw aligned Left, Center or Right reads its position
	left_of : F32, F32, [Left, Center, Right] -> F32
	left_of = |x, w, align|
		match align {
			Left => x
			Center => x - w / 2.0
			Right => x - w
		}

	# the panel every view draws inside: the window less its 16 px inset
	panel : { w : F32, h : F32 } -> Rect
	panel = |win| { x: 16.0, y: 16.0, w: win.w - 32.0, h: win.h - 32.0 }

	# what the gate reports for one scene: every box outside its region and
	# every pair of boxes that overlap, each named by its keys. Empty is a
	# clean scene.
	check : List(Owned) -> List(Str)
	check = |boxes| {
		indexed = List.map_with_index(boxes, |b, i| { b, i })
		outside = List.keep_oks(boxes, |o| if (inside(o.box, o.region)) Err(In) else Ok("${o.key} leaves its region"))
		overlaps = List.join(
			List.map(
				indexed,
				|e| List.keep_oks(
					List.drop_first(indexed, e.i + 1),
					|f| if (intersects(e.b.box, f.b.box)) Ok("${e.b.key} overlaps ${f.b.key}") else Err(Clear),
				),
			),
		)
		List.concat(outside, overlaps)
	}
}

# overlap needs shared area: a box overlaps one it crosses into, and not one
# it only touches along an edge or sits apart from
expect {
	a = { x: 0.0, y: 0.0, w: 10.0, h: 10.0 }
	Labels.intersects(a, { x: 5.0, y: 5.0, w: 10.0, h: 10.0 })
		and !(Labels.intersects(a, { x: 10.0, y: 0.0, w: 10.0, h: 10.0 }))
		and !(Labels.intersects(a, { x: 0.0, y: 11.0, w: 10.0, h: 10.0 }))
}
expect Labels.inside({ x: 2.0, y: 2.0, w: 4.0, h: 4.0 }, { x: 0.0, y: 0.0, w: 10.0, h: 10.0 }) and !(Labels.inside({ x: 8.0, y: 2.0, w: 4.0, h: 4.0 }, { x: 0.0, y: 0.0, w: 10.0, h: 10.0 }))

# a segment crosses a box when it passes through the box's rows over its
# columns, and not when it passes above, below or beside it; a vertical
# segment crosses only through the box
expect {
	s = { x0: 0.0, y0: 100.0, x1: 100.0, y1: 200.0 }
	b = |x, y| { x, y, w: 20.0, h: 10.0 }
	Labels.crosses(b(40.0, 145.0), s)
		and !(Labels.crosses(b(40.0, 170.0), s))
		and !(Labels.crosses(b(40.0, 120.0), s))
		and !(Labels.crosses(b(120.0, 150.0), s))
		and Labels.crosses(b(40.0, 145.0), { x0: 50.0, y0: 0.0, x1: 50.0, y1: 300.0 })
		and !(Labels.crosses(b(40.0, 145.0), { x0: 70.0, y0: 0.0, x1: 70.0, y1: 300.0 }))
}

# a label takes its first spot when it is clear and the next when an
# obstacle blocks it; a lower priority number places first and wins a
# contested spot, and a label left with no clear spot is dropped
expect {
	region = { x: 0.0, y: 0.0, w: 200.0, h: 200.0 }
	lbl = |spots, prio, item| { w: 20.0, h: 10.0, spots, prio, keep: Bool.False, region, item }
	got = Labels.place(
		[
			lbl([{ x: 0.0, y: 0.0 }, { x: 50.0, y: 0.0 }], 1, "a"),
			lbl([{ x: 50.0, y: 0.0 }, { x: 100.0, y: 0.0 }], 1, "b"),
			lbl([{ x: 100.0, y: 0.0 }, { x: 150.0, y: 0.0 }], 0, "c"),
		],
		{ boxes: [{ x: 5.0, y: 5.0, w: 4.0, h: 4.0 }], segs: [] },
	)
	List.map(got, |p| (p.item, p.box.x)) == [("a", 50.0), ("c", 100.0)]
}

# a kept label takes its first spot when none is clear, and a spot outside
# the region is never taken by one that is not kept
expect {
	region = { x: 0.0, y: 0.0, w: 100.0, h: 100.0 }
	wall = { x: 0.0, y: 0.0, w: 100.0, h: 20.0 }
	free = { w: 20.0, h: 10.0, spots: [{ x: 0.0, y: 0.0 }, { x: 90.0, y: 50.0 }], prio: 0, keep: Bool.False, region, item: "free" }
	kept = { ..free, keep: Bool.True, item: "kept" }
	List.map(Labels.place([free, kept], { boxes: [wall], segs: [] }), |p| (p.item, p.box.x, p.box.y)) == [("kept", 0.0, 0.0)]
}

# a spot no line crosses beats an earlier one a line crosses, and with every
# spot crossed the label still takes the first spot clear of every box
expect {
	region = { x: 0.0, y: 0.0, w: 200.0, h: 200.0 }
	line = { x0: 0.0, y0: 5.0, x1: 200.0, y1: 5.0 }
	l = { w: 20.0, h: 10.0, spots: [{ x: 0.0, y: 0.0 }, { x: 0.0, y: 50.0 }], prio: 0, keep: Bool.False, region, item: {} }
	crossed = { ..l, spots: [{ x: 0.0, y: 0.0 }, { x: 50.0, y: 0.0 }] }
	List.map(Labels.place([l], { boxes: [], segs: [line] }), |p| p.box.y) == [50.0]
		and List.map(Labels.place([crossed], { boxes: [], segs: [line] }), |p| p.box.x) == [0.0]
}

# the gate names every box outside its region and every overlapping pair,
# and a clean scene reports nothing
expect {
	r = { x: 0.0, y: 0.0, w: 100.0, h: 100.0 }
	a = { key: "a", box: { x: 0.0, y: 0.0, w: 20.0, h: 10.0 }, region: r }
	b = { key: "b", box: { x: 10.0, y: 5.0, w: 20.0, h: 10.0 }, region: r }
	c = { key: "c", box: { x: 95.0, y: 50.0, w: 20.0, h: 10.0 }, region: r }
	Labels.check([a, b, c]) == ["c leaves its region", "a overlaps b"] and Labels.check([a, c]) == ["c leaves its region"] and Labels.check([a]) == []
}
expect Labels.left_of(100.0, 40.0, Left) == 100.0 and Labels.left_of(100.0, 40.0, Center) == 80.0 and Labels.left_of(100.0, 40.0, Right) == 60.0
