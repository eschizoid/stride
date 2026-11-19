Geo :: [].{
	# ── the map view's geometry (pure) ─────────────────────────────────────
	# Web Mercator (EPSG:3857), the projection web street maps use: metres
	# on a sphere of the WGS84 equatorial radius, x east and y north. The
	# window keeps every point relative to one origin near the data, so a
	# metro area fits in F32 to well under a centimetre, and a camera maps
	# those metres onto a rectangle of the screen.

	# a point in metres east and north of the map's origin, or on screen
	Pt : { x : F32, y : F32 }

	# an axis-aligned extent in the same metres
	Bounds : { x0 : F32, y0 : F32, x1 : F32, y1 : F32 }

	# the world point at the centre of the map rectangle, and how many
	# metres one logical pixel spans
	Cam : { cx : F32, cy : F32, mpp : F32 }

	# the screen rectangle the map draws in, in logical pixels
	Rect : { x : F32, y : F32, w : F32, h : F32 }

	radius : F64
	radius = 6378137.0

	pi : F64
	pi = 3.141592653589793

	# the projection's latitude limit, where its square world ends
	max_lat : F64
	max_lat = 85.0511287798

	ln2 : F64
	ln2 = 0.6931471805599453

	# natural log of a positive number: halve or double into
	# [1/sqrt 2, sqrt 2), then the series ln(m) = 2 atanh((m - 1) / (m + 1)),
	# whose argument stays under 0.172 there, so eleven odd terms carry
	# double precision. This compiler's F64 has no log of its own.
	ln : F64 -> F64
	ln = |x|
		if x <= 0.0 {
			0.0
		} else {
			r = reduce(x, 0)
			z = (r.m - 1.0) / (r.m + 1.0)
			z2 = z * z
			s = z * (1.0 + z2 * (1.0 / 3.0 + z2 * (1.0 / 5.0 + z2 * (1.0 / 7.0 + z2 * (1.0 / 9.0 + z2 * (1.0 / 11.0 + z2 * (1.0 / 13.0 + z2 * (1.0 / 15.0 + z2 * (1.0 / 17.0 + z2 * (1.0 / 19.0 + z2 / 21.0))))))))))
			2.0 * s + I64.to_f64(r.k) * ln2
		}

	# the exponent stops past any finite double's, so an infinity returns
	# instead of halving forever
	reduce : F64, I64 -> { m : F64, k : I64 }
	reduce = |m, k|
		if k > 1100 or k < -1100 {
			{ m, k }
		} else if m >= 1.4142135623730951 {
			reduce(m / 2.0, k + 1)
		} else if m < 0.7071067811865476 {
			reduce(m * 2.0, k - 1)
		} else {
			{ m, k }
		}

	# degrees to projected metres; a latitude past the limit lands on it
	merc : F64, F64 -> { x : F64, y : F64 }
	merc = |lat, lng| {
		la = if (lat > max_lat) max_lat else if (lat < 0.0 - max_lat) 0.0 - max_lat else lat
		{ x: radius * lng * pi / 180.0, y: radius * ln(F64.tan(pi / 4.0 + la * pi / 360.0)) }
	}

	# a coordinate as metres from the origin, the origin itself projected
	rel : { x : F64, y : F64 }, F64, F64 -> Pt
	rel = |origin, lat, lng| {
		m = merc(lat, lng)
		{ x: F64.to_f32_wrap(m.x - origin.x), y: F64.to_f32_wrap(m.y - origin.y) }
	}

	# north is up on screen, so world y and screen y run opposite ways
	to_screen : Cam, Rect, Pt -> Pt
	to_screen = |cam, r, p| { x: r.x + r.w / 2.0 + (p.x - cam.cx) / cam.mpp, y: r.y + r.h / 2.0 - (p.y - cam.cy) / cam.mpp }

	to_world : Cam, Rect, F32, F32 -> Pt
	to_world = |cam, r, sx, sy| { x: cam.cx + (sx - r.x - r.w / 2.0) * cam.mpp, y: cam.cy - (sy - r.y - r.h / 2.0) * cam.mpp }

	# the closest and farthest the camera goes: a quarter metre per pixel
	# shows a street's lanes, two kilometres per pixel a region a thousand or
	# more kilometres across
	min_mpp : F32
	min_mpp = 0.25

	max_mpp : F32
	max_mpp = 2000.0

	clamp_mpp : F32 -> F32
	clamp_mpp = |m| if (m < min_mpp) min_mpp else if (m > max_mpp) max_mpp else m

	# the camera that shows the whole box with a tenth of the rectangle to
	# spare on its tighter axis; an empty box gets the closest zoom
	fit : Bounds, Rect -> Cam
	fit = |b, r|
		if b.x1 < b.x0 or b.y1 < b.y0 {
			{ cx: 0.0, cy: 0.0, mpp: min_mpp }
		} else {
			{ cx: (b.x0 + b.x1) / 2.0, cy: (b.y0 + b.y1) / 2.0, mpp: clamp_mpp(F32.max((b.x1 - b.x0) / (r.w * 0.9), (b.y1 - b.y0) / (r.h * 0.9))) }
		}

	# zoom by `factor` (above 1 closer) keeping the world point under the
	# cursor under it
	zoom_at : Cam, Rect, F32, F32, F32 -> Cam
	zoom_at = |cam, r, factor, sx, sy| {
		w = to_world(cam, r, sx, sy)
		mpp = clamp_mpp(cam.mpp / factor)
		{ cx: w.x - (sx - r.x - r.w / 2.0) * mpp, cy: w.y + (sy - r.y - r.h / 2.0) * mpp, mpp }
	}

	# a drag of (dx, dy) screen pixels carries the world with the cursor
	pan : Cam, F32, F32 -> Cam
	pan = |cam, dx, dy| { ..cam, cx: cam.cx - dx * cam.mpp, cy: cam.cy + dy * cam.mpp }

	no_box : Bounds
	no_box = { x0: 1.0e30, y0: 1.0e30, x1: -1.0e30, y1: -1.0e30 }

	box_of : List(Pt) -> Bounds
	box_of = |pts| List.fold(pts, no_box, |b, p| { x0: F32.min(b.x0, p.x), y0: F32.min(b.y0, p.y), x1: F32.max(b.x1, p.x), y1: F32.max(b.y1, p.y) })

	union : Bounds, Bounds -> Bounds
	union = |a, b| { x0: F32.min(a.x0, b.x0), y0: F32.min(a.y0, b.y0), x1: F32.max(a.x1, b.x1), y1: F32.max(a.y1, b.y1) }

	# whether any of the box shows inside the rectangle
	visible : Cam, Rect, Bounds -> Bool
	visible = |cam, r, b| {
		lo = to_world(cam, r, r.x, r.y + r.h)
		hi = to_world(cam, r, r.x + r.w, r.y)
		b.x1 >= lo.x and b.x0 <= hi.x and b.y1 >= lo.y and b.y0 <= hi.y
	}

	# a line's points on screen, keeping a point only once it moves at
	# least `step` pixels from the last one kept, and always the last
	# point, so a line never draws shorter than it is
	strip : Cam, Rect, List(Pt), F32 -> List(Pt)
	strip = |cam, r, pts, step| thin(List.map(pts, |p| to_screen(cam, r, p)), step)

	# the same rule on any points: a point is kept once it lies `step` or
	# more from the last one kept on either axis, and the first and last
	# points always are
	thin : List(Pt), F32 -> List(Pt)
	thin = |pts, step| {
		n = List.len(pts)
		List.fold(
			List.map_with_index(pts, |p, i| { s: p, last: i + 1 == n }),
			[],
			|acc, q|
				match List.last(acc) {
					Ok(k) => if (q.last or (q.s.x - k.x).abs() >= step or (q.s.y - k.y).abs() >= step) List.append(acc, q.s) else acc
					Err(_) => List.append(acc, q.s)
				},
		)
	}

	# whether a box can be shown whole in the rectangle at the widest zoom,
	# with the tenth to spare fit keeps
	fits : Bounds, Rect -> Bool
	fits = |b, r| b.x1 - b.x0 <= r.w * 0.9 * max_mpp and b.y1 - b.y0 <= r.h * 0.9 * max_mpp

	# where the lines gather, for when they cannot all be shown at once: the
	# square cell, focus_cell metres on a side, holding the most line starts
	# (the routes', or the base map's when no route has GPS), a tie going to
	# the cell met first; the extent of every line starting in that cell or
	# the eight around it, so a metro a cell edge runs through stays whole;
	# and the first line start in that cell, the point a cluster too wide to
	# fit is centred on
	Focus : { box : Bounds, anchor : Pt }

	focus_cell : F32
	focus_cell = 100000.0

	# a start's cell, as whole cell numbers east and north of the origin
	cell_of : Pt -> { cx : I64, cy : I64 }
	cell_of = |p| { cx: (F32.to_i64_try(F32.div_floor_by(p.x, focus_cell))) ?? 0, cy: (F32.to_i64_try(F32.div_floor_by(p.y, focus_cell))) ?? 0 }

	# one number per cell: a cell lies within a few hundred cells of the
	# origin on either axis, far inside the multiplier
	cell_key : { cx : I64, cy : I64 } -> I64
	cell_key = |c| c.cx * 1048576 + c.cy

	# The starts are counted per cell in one pass and the best cell found in
	# a second, so the cost grows with the number of lines, not its square:
	# a base map alone holds hundreds of thousands of them.
	focus : List({ start : Pt, box : Bounds }) -> Focus
	focus = |items| {
		cells = List.map(items, |it| cell_of(it.start))
		counts = List.fold(cells, Dict.empty(), |d, c| Dict.insert(d, cell_key(c), (Dict.get(d, cell_key(c)) ?? 0) + 1))
		best = List.fold(
			List.map_with_index(cells, |c, i| { c, i }),
			{ c: { cx: 0, cy: 0 }, i: 0, n: 0 },
			|acc, x| {
				n = Dict.get(counts, cell_key(x.c)) ?? 0
				if (n > acc.n) { c: x.c, i: x.i, n } else acc
			},
		)
		near = List.keep_if(
			List.map2(items, cells, |it, c| { it, c }),
			|x| (x.c.cx - best.c.cx).abs() <= 1 and (x.c.cy - best.c.cy).abs() <= 1,
		)
		{
			box: List.fold(near, no_box, |b, x| union(b, x.it.box)),
			anchor: (List.get(items, best.i)).map_ok(|it| it.start).ok_or({ x: 0.0, y: 0.0 }),
		}
	}

	# the camera that opens the map: the whole extent when it fits, else the
	# cluster's extent when that fits, else the widest zoom centred on the
	# cluster's first start, so the opening view always holds a route
	opening : Bounds, Focus, Rect -> Cam
	opening = |all, f, r|
		if fits(all, r) {
			fit(all, r)
		} else if fits(f.box, r) {
			fit(f.box, r)
		} else {
			{ cx: f.anchor.x, cy: f.anchor.y, mpp: max_mpp }
		}

	# A route's longitudes made continuous: a step of more than half the
	# globe between two samples is a crossing of the antimeridian, not a
	# flight round the world, so every longitude after it is carried on past
	# 180 (or below -180) and the line draws across the seam instead of
	# across the whole map.
	unwrap : List({ lat : F64, lng : F64 }) -> List({ lat : F64, lng : F64 })
	unwrap = |coords| {
		walk = List.fold(
			coords,
			{ shift: 0.0, prev: [], out: [] },
			|acc, c| {
				raw = c.lng + acc.shift
				shift = match acc.prev {
					[p] => if (raw - p > 180.0) acc.shift - 360.0 else if (raw - p < -180.0) acc.shift + 360.0 else acc.shift
					_ => acc.shift
				}
				lng = c.lng + shift
				{ shift, prev: [lng], out: List.append(acc.out, { lat: c.lat, lng }) }
			},
		)
		walk.out
	}

	near64 : F64, F64, F64 -> Bool
	near64 = |a, b, tol| (a - b).abs() <= tol

	near32 : F32, F32, F32 -> Bool
	near32 = |a, b, tol| (a - b).abs() <= tol

	# the log against awk's: one, ten, a thousandth and two
	expect near64(ln(1.0), 0.0, 1.0e-15) and near64(ln(10.0), 2.302585092994046, 1.0e-13) and near64(ln(0.001), -6.907755278982137, 1.0e-13) and near64(ln(2.0), 0.6931471805599453, 1.0e-15)

	# projected metres against awk's for Chicago, Sydney, a point at 60N and
	# the latitude limit, and the origin of the projection at (0, 0)
	expect {
		c = merc(41.8781, -87.6298)
		s = merc(-33.8688, 151.2093)
		n = merc(60.0, 30.0)
		z = merc(0.0, 0.0)
		near64(c.x, -9754904.714316, 0.001) and near64(c.y, 5142736.869193, 0.001)
			and near64(s.x, 16832542.279207, 0.001) and near64(s.y, -4011198.647308, 0.001)
			and near64(n.x, 3339584.723798, 0.001) and near64(n.y, 8399737.889818, 0.001)
			and near64(z.x, 0.0, 1.0e-9) and near64(z.y, 0.0, 1.0e-9)
	}

	# the square world ends at the limit: a pole lands on it, top and bottom
	expect near64(merc(90.0, 0.0).y, merc(max_lat, 0.0).y, 1.0e-6) and near64(merc(-90.0, 0.0).y, 0.0 - merc(max_lat, 0.0).y, 1.0e-6) and near64(merc(max_lat, 0.0).y, 20037508.342789, 0.01)

	# a point 0.0009 degrees of latitude north of the origin lands due north
	# of it, in metres stretched by one over the cosine of the latitude, as
	# every Mercator distance is: about 134.56 of them at 41.88N
	expect {
		o = merc(41.88, -87.63)
		p = rel(o, 41.8809, -87.63)
		near32(p.x, 0.0, 0.001) and near32(p.y, 134.56, 0.01)
	}

	# screen and world invert each other, north up
	expect {
		cam = { cx: 120.0, cy: -40.0, mpp: 3.0 }
		r = { x: 36.0, y: 96.0, w: 800.0, h: 500.0 }
		s = to_screen(cam, r, { x: 150.0, y: 20.0 })
		w = to_world(cam, r, s.x, s.y)
		near32(s.x, 446.0, 0.001) and near32(s.y, 326.0, 0.001) and near32(w.x, 150.0, 0.001) and near32(w.y, 20.0, 0.001)
	}

	# a fitted box sits centred, wholly inside, and fills nine tenths of its
	# tighter axis
	expect {
		r = { x: 36.0, y: 96.0, w: 800.0, h: 500.0 }
		b = { x0: -1000.0, y0: -200.0, x1: 3000.0, y1: 600.0 }
		cam = fit(b, r)
		lo = to_screen(cam, r, { x: b.x0, y: b.y0 })
		hi = to_screen(cam, r, { x: b.x1, y: b.y1 })
		near32(cam.cx, 1000.0, 0.001) and near32(cam.cy, 200.0, 0.001)
			and lo.x >= r.x and hi.x <= r.x + r.w and hi.y >= r.y and lo.y <= r.y + r.h
			and near32(hi.x - lo.x, 720.0, 0.01)
	}

	# an empty box, as with no routes, gets the closest zoom, never a NaN
	expect fit(no_box, { x: 0.0, y: 0.0, w: 800.0, h: 500.0 }) == { cx: 0.0, cy: 0.0, mpp: min_mpp }

	# zooming keeps the point under the cursor where it was, and clamps
	expect {
		r = { x: 36.0, y: 96.0, w: 800.0, h: 500.0 }
		cam = { cx: 0.0, cy: 0.0, mpp: 10.0 }
		before = to_world(cam, r, 600.0, 200.0)
		z = zoom_at(cam, r, 2.0, 600.0, 200.0)
		after = to_world(z, r, 600.0, 200.0)
		near32(z.mpp, 5.0, 0.0001) and near32(after.x, before.x, 0.01) and near32(after.y, before.y, 0.01)
			and zoom_at(cam, r, 1000.0, 600.0, 200.0).mpp == min_mpp and zoom_at(cam, r, 0.0001, 600.0, 200.0).mpp == max_mpp
	}

	# a drag carries the world point under the cursor with the cursor
	expect {
		r = { x: 0.0, y: 0.0, w: 800.0, h: 500.0 }
		cam = { cx: 50.0, cy: 50.0, mpp: 4.0 }
		w = to_world(cam, r, 300.0, 300.0)
		moved = to_screen(pan(cam, 25.0, -10.0), r, w)
		near32(moved.x, 325.0, 0.001) and near32(moved.y, 290.0, 0.001)
	}

	# a box shows when it overlaps the rectangle's world extent, not when it
	# lies wholly past an edge
	expect {
		r = { x: 0.0, y: 0.0, w: 800.0, h: 500.0 }
		cam = { cx: 0.0, cy: 0.0, mpp: 1.0 }
		visible(cam, r, { x0: 390.0, y0: -10.0, x1: 500.0, y1: 10.0 }) and !(visible(cam, r, { x0: 401.0, y0: -10.0, x1: 500.0, y1: 10.0 })) and !(visible(cam, r, { x0: -10.0, y0: 251.0, x1: 10.0, y1: 300.0 }))
	}

	# the strip drops points closer than the step to the last one kept,
	# keeps the line's last point, and keeps a single point
	expect {
		r = { x: 0.0, y: 0.0, w: 100.0, h: 100.0 }
		cam = { cx: 0.0, cy: 0.0, mpp: 1.0 }
		s = strip(cam, r, [{ x: 0.0, y: 0.0 }, { x: 0.4, y: 0.0 }, { x: 2.0, y: 0.0 }, { x: 2.3, y: 0.0 }], 1.0)
		List.map(s, |p| p.x) == [50.0, 52.0, 52.3] and List.len(strip(cam, r, [{ x: 0.0, y: 0.0 }], 1.0)) == 1
	}

	# thinning keeps the first and last points and every point a full step
	# from the last kept one
	expect List.map(thin([{ x: 0.0, y: 0.0 }, { x: 1.0, y: 0.0 }, { x: 3.0, y: 0.0 }, { x: 3.5, y: 0.0 }, { x: 3.6, y: 0.0 }], 2.0), |p| p.x) == [0.0, 3.0, 3.6]

	# thirty routes round a home and one in Madrid, about 9,350 km east: the
	# whole extent cannot fit, so the map opens on the home cluster with every
	# home route inside the rectangle and Madrid left out
	expect {
		r = { x: 36.0, y: 96.0, w: 908.0, h: 456.0 }
		home = List.map_with_index(List.repeat(0, 30), |_, i| { start: { x: U64.to_f32(i) * 1000.0, y: U64.to_f32(i) * 500.0 }, box: { x0: U64.to_f32(i) * 1000.0 - 5000.0, y0: U64.to_f32(i) * 500.0 - 5000.0, x1: U64.to_f32(i) * 1000.0 + 5000.0, y1: U64.to_f32(i) * 500.0 + 5000.0 } })
		madrid = { start: { x: 9350000.0, y: -230000.0 }, box: { x0: 9349000.0, y0: -231000.0, x1: 9351000.0, y1: -229000.0 } }
		items = List.append(home, madrid)
		all = List.fold(items, no_box, |b, it| union(b, it.box))
		f = focus(items)
		cam = opening(all, f, r)
		lo = to_screen(cam, r, { x: -5000.0, y: -5000.0 })
		hi = to_screen(cam, r, { x: 34000.0, y: 19500.0 })
		!(fits(all, r)) and f.box.x1 < 100000.0 and lo.x >= r.x and hi.x <= r.x + r.w and hi.y >= r.y and lo.y <= r.y + r.h
	}

	# routes that fit together open on all of them, the far one included
	expect {
		r = { x: 0.0, y: 0.0, w: 908.0, h: 456.0 }
		items = [{ start: { x: 0.0, y: 0.0 }, box: { x0: 0.0, y0: 0.0, x1: 10.0, y1: 10.0 } }, { start: { x: 300000.0, y: 0.0 }, box: { x0: 300000.0, y0: 0.0, x1: 300010.0, y1: 10.0 } }]
		all = List.fold(items, no_box, |b, it| union(b, it.box))
		cam = opening(all, focus(items), r)
		near32(cam.cx, 150005.0, 0.5)
	}

	# the densest cell wins though a lone start comes first, and two cells
	# whose numbers sum alike, (0, 5) and (3, 2), are counted apart
	expect {
		f = focus([
			{ start: { x: 50000.0, y: 550000.0 }, box: { x0: 50000.0, y0: 550000.0, x1: 50010.0, y1: 550010.0 } },
			{ start: { x: 350000.0, y: 250000.0 }, box: { x0: 350000.0, y0: 250000.0, x1: 350010.0, y1: 250010.0 } },
			{ start: { x: 360000.0, y: 260000.0 }, box: { x0: 360000.0, y0: 260000.0, x1: 360010.0, y1: 260010.0 } },
		])
		near32(f.anchor.x, 350000.0, 0.5) and near32(f.box.x0, 350000.0, 0.5) and near32(f.box.y1, 260010.0, 0.5)
	}

	# a metro a cell edge runs through stays whole, and a tie goes to the
	# cell met first
	expect {
		edge = focus([{ start: { x: 99000.0, y: 10.0 }, box: { x0: 99000.0, y0: 0.0, x1: 99500.0, y1: 20.0 } }, { start: { x: 101000.0, y: 10.0 }, box: { x0: 100500.0, y0: 0.0, x1: 101000.0, y1: 20.0 } }])
		tie = focus([{ start: { x: 0.0, y: 0.0 }, box: { x0: 0.0, y0: 0.0, x1: 1.0, y1: 1.0 } }, { start: { x: 5000000.0, y: 0.0 }, box: { x0: 5000000.0, y0: 0.0, x1: 5000001.0, y1: 1.0 } }])
		near32(edge.box.x0, 99000.0, 0.5) and near32(edge.box.x1, 101000.0, 0.5) and near32(tie.anchor.x, 0.0, 0.5) and near32(tie.box.x1, 1.0, 0.01)
	}

	# a cluster too tall to fit, a route run toward a pole, opens at the
	# widest zoom centred on its start
	expect {
		r = { x: 0.0, y: 0.0, w: 908.0, h: 456.0 }
		polar = [{ start: { x: 10.0, y: 20.0 }, box: { x0: 0.0, y0: 0.0, x1: 50.0, y1: 12000000.0 } }]
		all = List.fold(polar, no_box, |b, it| union(b, it.box))
		cam = opening(all, focus(polar), r)
		near32(cam.cx, 10.0, 0.01) and near32(cam.cy, 20.0, 0.01) and cam.mpp == max_mpp
	}

	# crossing the antimeridian eastward carries on past 180, westward past
	# -180, and a route that never crosses keeps its longitudes
	expect {
		east = List.map(unwrap([{ lat: 0.0, lng: 179.9 }, { lat: 0.0, lng: -179.9 }, { lat: 0.0, lng: -179.8 }]), |c| c.lng)
		west = List.map(unwrap([{ lat: 0.0, lng: -179.9 }, { lat: 0.0, lng: 179.9 }]), |c| c.lng)
		plain = List.map(unwrap([{ lat: 41.9, lng: -87.6 }, { lat: 41.9, lng: -87.7 }]), |c| c.lng)
		List.all(List.map2(east, [179.9, 180.1, 180.2], |a, b| near64(a, b, 1.0e-9)), |ok| ok)
			and List.all(List.map2(west, [-179.9, -180.1], |a, b| near64(a, b, 1.0e-9)), |ok| ok)
			and plain == [-87.6, -87.7]
	}
	# the box of a list is its extremes, and a union holds both
	expect box_of([{ x: 1.0, y: 5.0 }, { x: -2.0, y: 3.0 }]) == { x0: -2.0, y0: 3.0, x1: 1.0, y1: 5.0 } and union({ x0: 0.0, y0: 0.0, x1: 1.0, y1: 1.0 }, { x0: -1.0, y0: 0.5, x1: 0.5, y1: 2.0 }) == { x0: -1.0, y0: 0.0, x1: 1.0, y1: 2.0 }
}
