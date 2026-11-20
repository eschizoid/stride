import rr.Color
import Labels
import Mvt
import Scene
import Theme

MapNames :: [].{
	# ── the street map's names (pure) ──────────────────────────────────────
	# Places (Mvt.place_of) are named at the wide and middle zooms and the
	# streets (Mvt.street_of) close in, each kind between the zooms `look`
	# gives it, so the map stays quiet: a kind shows only once the view is
	# close enough that its names do not crowd, cities and towns give way
	# at street level, and larger places and major roads place first. A
	# name is a label for the window's one placer, judged by the label gate
	# like every other, and its candidates are chosen here, in screen
	# space, before the placer sees them:
	#
	# - a place tries its point, then above, below, right and left of it;
	# - a street is named on a part of its run the view shows (`clip`),
	#   along a stretch that is near straight (`stretches`), the one
	#   nearest the part's middle that the routes leave clear, turned to
	#   the stretch's direction and kept upright, and is not named where
	#   every stretch long enough for its text bends;
	# - no spot is taken where a route is drawn (`blocked`), so the routes
	#   stay clear of text, and the placer holds every name off the view's
	#   other text and off every other name;
	# - a name already chosen within `repeat_px` of another run of the same
	#   name is not chosen again, so a long road is named once per stretch
	#   of the view and a place a tile's buffer repeats is named once.
	#
	# A turned name's box is the upright box around it, which holds every
	# pixel of its text, so a gate that finds no two boxes overlapping
	# proves no two names do.

	# a name in screen space: its kind, rank and text as the tile gives
	# them, and its point or run in the window's logical units
	Run : { kind : U8, rank : U64, text : Str, pts : List(Labels.Pt) }

	# what a placed name draws: its text, the width of that text, and the
	# angle it is turned by, in degrees clockwise; it draws centred in its
	# placed box
	Item : { item : Scene.Item, w : F32, angle : F32 }

	# each kind's zooms, in metres per pixel: shown closer than `far` and no
	# closer than `near`, at a pixel size, in its ink
	Look : { near : F32, far : F32, size : F32, color : Color.Rgba }

	look : U8 -> Look
	look = |kind|
		if (kind == 0) { near: 3.0, far: 2000.0, size: 14.0, color: place_ink }
		else if (kind == 1) { near: 3.0, far: 400.0, size: 13.0, color: place_ink }
		else if (kind == 2) { near: 1.5, far: 120.0, size: 12.0, color: place_ink }
		else if (kind == 3) { near: 0.0, far: 60.0, size: 12.0, color: place_ink }
		else if (kind == 4) { near: 0.0, far: 20.0, size: 11.0, color: place_ink }
		else if (kind == 5) { near: 0.0, far: 40.0, size: 11.0, color: street_ink }
		else if (kind == 6) { near: 0.0, far: 16.0, size: 11.0, color: street_ink }
		else if (kind == 7) { near: 0.0, far: 8.0, size: 11.0, color: street_ink }
		else { near: 0.0, far: 4.0, size: 11.0, color: street_ink }

	# The names' inks: every place in the theme's muted ink, which the view's
	# title and chips also wear but larger, and every street most of the way
	# from the faint ink to it, so a street reads against the dark ground
	# and still sits a step below the places.
	place_ink : Color.Rgba
	place_ink = Theme.ink_muted

	street_ink : Color.Rgba
	street_ink = toward(Theme.ink_faint, Theme.ink_muted, 0.75)

	# a colour a share t of the way from one to another, opaque
	toward : Color.Rgba, Color.Rgba, F32 -> Color.Rgba
	toward = |a, b, t| {
		mix = |x, y| U64.to_u8_wrap((F32.round_to_u64_try(U8.to_f32(x) * (1.0 - t) + U8.to_f32(y) * t)) ?? 0)
		Color.rgba(mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b), 255)
	}

	shows : U8, F32 -> Bool
	shows = |kind, mpp| {
		l = look(kind)
		mpp < l.far and mpp >= l.near
	}

	# the placer's order: places by kind then rank (an unranked place last
	# in its kind), then streets by kind, after the view's fixed text
	prio : Run -> U64
	prio = |r| 1 + U8.to_u64(r.kind) * 20 + (if (r.rank == 0) 19 else U64.min(r.rank, 19))

	# how far apart two runs of one name must be, in logical pixels, for
	# both to be named
	repeat_px : F32
	repeat_px = 360.0

	# the most names one view offers the placer
	most : U64
	most = 100

	# the space a name keeps clear around its text, in logical pixels
	gap : F32
	gap = 2.0

	# how far a stretch's points may stray from its chord, as a share of
	# the text's height, and the least share of the stretch's length its
	# chord must span, for the stretch to read as straight
	stray : F32
	stray = 0.3

	chord_share : F32
	chord_share = 0.97

	# a turn smaller than this many degrees draws level
	level_deg : F32
	level_deg = 2.0

	# ── a name along a line ────────────────────────────────────────────────
	# The stretches of `len` pixels that read as straight, nearest the
	# run's middle first: a stretch's chord is at least chord_share of its
	# length, and every point inside it lies within `tol` of the chord. The
	# tries are the middle, then half a stretch and a whole one either
	# side, then one and a half; a run shorter than `len`, or bent at every
	# try, has none. Each is its middle and its chord's angle, turned
	# upright (`upright`). `along` is the first of them.
	stretches : List(Labels.Pt), F32, F32 -> List({ at : Labels.Pt, angle : F32 })
	stretches = |pts, len, tol| {
		cum = cumulative(pts)
		total = List.last(cum) ?? 0.0
		if total < len or len <= 0.0 {
			[]
		} else {
			mid = total / 2.0 - len / 2.0
			tries = List.map([0.0, -0.5, 0.5, -1.0, 1.0, -1.5, 1.5], |k| mid + k * len)
			fits = List.keep_if(tries, |s0| s0 >= 0.0 and s0 + len <= total + 0.001 and straight(pts, cum, s0, len, tol))
			List.map(
				fits,
				|s0| {
					a = point_at(pts, cum, s0)
					b = point_at(pts, cum, s0 + len)
					{ at: { x: (a.x + b.x) / 2.0, y: (a.y + b.y) / 2.0 }, angle: upright(b.x - a.x, b.y - a.y) }
				},
			)
		}
	}

	along : List(Labels.Pt), F32, F32 -> Try({ at : Labels.Pt, angle : F32 }, [Bent])
	along = |pts, len, tol|
		match List.first(stretches(pts, len, tol)) {
			Ok(s) => Ok(s)
			Err(_) => Err(Bent)
		}

	# The parts of a run inside a rectangle, each segment cut to it
	# (Liang and Barsky's clip), consecutive cut segments joined into one
	# part, so a street that crosses the view is named where it shows.
	clip : List(Labels.Pt), Labels.Rect -> List(List(Labels.Pt))
	clip = |pts, r| {
		var $out = []
		var $cur = []
		var $prev = List.first(pts) ?? { x: 0.0, y: 0.0 }
		var $first = Bool.True
		for p in pts {
			if $first {
				$first = Bool.False
			} else {
				match cut_seg($prev, p, r) {
					Ok(s) => {
						joined = match List.last($cur) {
							Ok(l) => (l.x - s.a.x).abs() < 0.001 and (l.y - s.a.y).abs() < 0.001
							Err(_) => Bool.False
						}
						if joined {
							$cur = List.append($cur, s.b)
						} else {
							if List.len($cur) >= 2 {
								$out = List.append($out, $cur)
							}
							$cur = [s.a, s.b]
						}
					}
					Err(_) => {}
				}
			}
			$prev = p
		}
		if (List.len($cur) >= 2) List.append($out, $cur) else $out
	}

	# one segment cut to a rectangle, Err when none of it lies inside
	cut_seg : Labels.Pt, Labels.Pt, Labels.Rect -> Try({ a : Labels.Pt, b : Labels.Pt }, [Outside])
	cut_seg = |a, b, r| {
		dx = b.x - a.x
		dy = b.y - a.y
		edges = [{ p: 0.0 - dx, q: a.x - r.x }, { p: dx, q: r.x + r.w - a.x }, { p: 0.0 - dy, q: a.y - r.y }, { p: dy, q: r.y + r.h - a.y }]
		span = List.fold(
			edges,
			{ t0: 0.0, t1: 1.0, out: Bool.False },
			|acc, e|
				if e.p == 0.0 {
					if (e.q < 0.0) { ..acc, out: Bool.True } else acc
				} else {
					t = e.q / e.p
					if (e.p < 0.0) { ..acc, t0: F32.max(acc.t0, t) } else { ..acc, t1: F32.min(acc.t1, t) }
				},
		)
		if span.out or span.t0 >= span.t1 {
			Err(Outside)
		} else {
			Ok({ a: { x: a.x + dx * span.t0, y: a.y + dy * span.t0 }, b: { x: a.x + dx * span.t1, y: a.y + dy * span.t1 } })
		}
	}

	# the distance along the run to each of its points
	cumulative : List(Labels.Pt) -> List(F32)
	cumulative = |pts| {
		var $out = List.with_capacity(List.len(pts))
		var $acc = 0.0
		var $prev = List.first(pts) ?? { x: 0.0, y: 0.0 }
		for p in pts {
			$acc = $acc + dist($prev, p)
			$out = List.append($out, $acc)
			$prev = p
		}
		$out
	}

	dist : Labels.Pt, Labels.Pt -> F32
	dist = |a, b| F32.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))

	# the point `s` along the run
	point_at : List(Labels.Pt), List(F32), F32 -> Labels.Pt
	point_at = |pts, cum, s| {
		n = List.len(pts)
		var $i = 1
		var $out = List.last(pts) ?? { x: 0.0, y: 0.0 }
		while $i < n {
			c1 = List.get(cum, $i) ?? 0.0
			if c1 >= s {
				c0 = List.get(cum, $i - 1) ?? 0.0
				a = List.get(pts, $i - 1) ?? $out
				b = List.get(pts, $i) ?? $out
				t = if (c1 - c0 <= 0.0) 0.0 else (s - c0) / (c1 - c0)
				$out = { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t }
				$i = n
			} else {
				$i = $i + 1
			}
		}
		$out
	}

	straight : List(Labels.Pt), List(F32), F32, F32, F32 -> Bool
	straight = |pts, cum, s0, len, tol| {
		a = point_at(pts, cum, s0)
		b = point_at(pts, cum, s0 + len)
		chord = dist(a, b)
		if chord < len * chord_share {
			Bool.False
		} else {
			inner = List.keep_oks(List.map_with_index(pts, |p, i| { p, s: List.get(cum, i) ?? 0.0 }), |e| if (e.s > s0 and e.s < s0 + len) Ok(e.p) else Err(Outside))
			List.all(inner, |p| ((p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x)).abs() / chord <= tol)
		}
	}

	# A direction's angle in degrees clockwise from level, turned upright:
	# from steep_deg short of a quarter turn anticlockwise to as far past a
	# quarter turn clockwise, so text reads left to right and every street
	# near vertical reads the same way, top to bottom; and level when
	# within level_deg of it.
	upright : F32, F32 -> F32
	upright = |dx, dy| {
		deg = if (dx.abs() < 0.000001) 90.0 else F64.to_f32_wrap(F64.atan(F32.to_f64(dy / dx)) * 180.0 / 3.141592653589793)
		if (deg.abs() < level_deg) 0.0 else if (deg <= steep_deg - 90.0) deg + 180.0 else deg
	}

	steep_deg : F32
	steep_deg = 5.0

	# the upright box around a w by h box turned by `angle` degrees
	turned : F32, F32, F32 -> { w : F32, h : F32 }
	turned = |w, h, angle| {
		r = angle * 3.14159265 / 180.0
		c = F32.cos(r).abs()
		s = F32.sin(r).abs()
		{ w: w * c + h * s, h: w * s + h * c }
	}

	# ── where the routes are ───────────────────────────────────────────────
	# The routes on screen as a grid of cells, each marked when a route
	# passes through it. A level box looks at every cell it covers; a
	# turned one is sampled at half a cell, so every cell it covers is
	# looked at too. A spot whose box meets a marked cell is not taken.
	Grid : { x : F32, y : F32, cols : U64, rows : U64, hit : List(Bool) }

	cell : F32
	cell = 4.0

	# the whole part of a number no less than zero, which every cell
	# measure here is
	floor_u : F32 -> U64
	floor_u = |v| F32.to_u64_wrap(v)

	# the cell holding a point, Err when it lies outside the grid
	index : Grid, F32, F32 -> Try(U64, [Outside])
	index = |g, x, y| at_cell(g.x, g.y, g.cols, g.rows, x, y)

	at_cell : F32, F32, U64, U64, F32, F32 -> Try(U64, [Outside])
	at_cell = |gx, gy, cols, rows, x, y| {
		dx = x - gx
		dy = y - gy
		if dx < 0.0 or dy < 0.0 {
			Err(Outside)
		} else {
			cx = floor_u(dx / cell)
			cy = floor_u(dy / cell)
			if (cx >= cols or cy >= rows) Err(Outside) else Ok(cy * cols + cx)
		}
	}

	# The grid over a region with every line marked, each point taken to
	# the screen by `to` as it is read, so no line is copied. A line's
	# first point is marked, and then each point at least half a cell from
	# the last one marked, with half-cell steps between the two; a point
	# nearer than that is passed over, so a line is marked within half a
	# cell of where it runs. The marks go into a list nothing else holds,
	# so each is written in place.
	grid : Labels.Rect, List(List(a)), (a -> Labels.Pt) -> Grid
	grid = |r, lines, to| {
		cols = floor_u(r.w / cell) + 1
		rows = floor_u(r.h / cell) + 1
		half = cell / 2.0
		var $hit = List.repeat(Bool.False, cols * rows)
		for l in lines {
			var $prev = { x: 0.0, y: 0.0 }
			var $first = Bool.True
			for q in l {
				p = to(q)
				d = if ($first) half else dist($prev, p)
				if d >= half {
					steps = if ($first) 1 else floor_u(d / half)
					var $k = 1
					while $k <= steps {
						t = U64.to_f32($k) / U64.to_f32(steps)
						match at_cell(r.x, r.y, cols, rows, $prev.x + (p.x - $prev.x) * t, $prev.y + (p.y - $prev.y) * t) {
							Ok(i) => {
								$hit = List.set($hit, i, Bool.True) ?? []
							}
							Err(_) => {}
						}
						$k = $k + 1
					}
					$prev = p
					$first = Bool.False
				}
			}
		}
		{ x: r.x, y: r.y, cols, rows, hit: $hit }
	}

	# whether a w by h box centred on `at` and turned by `angle` meets a
	# marked cell
	blocked : Grid, Labels.Pt, F32, F32, F32 -> Bool
	blocked = |g, at, w, h, angle|
		if angle == 0.0 {
			level_blocked(g, at.x - w / 2.0 - g.x, at.y - h / 2.0 - g.y, at.x + w / 2.0 - g.x, at.y + h / 2.0 - g.y)
		} else {
			r = angle * 3.14159265 / 180.0
			c = F32.cos(r)
			s = F32.sin(r)
			nu = floor_u(w / (cell / 2.0)) + 1
			nv = floor_u(h / (cell / 2.0)) + 1
			var $hit = Bool.False
			var $i = 0
			while !$hit and $i <= nu {
				u = U64.to_f32($i) / U64.to_f32(nu) * w - w / 2.0
				var $j = 0
				while !$hit and $j <= nv {
					v = U64.to_f32($j) / U64.to_f32(nv) * h - h / 2.0
					match index(g, at.x + u * c - v * s, at.y + u * s + v * c) {
						Ok(k) => {
							$hit = List.get(g.hit, k) ?? Bool.False
						}
						Err(_) => {}
					}
					$j = $j + 1
				}
				$i = $i + 1
			}
			$hit
		}

	# whether any cell a level box covers is marked, the box given by its
	# edges measured from the grid's corner
	level_blocked : Grid, F32, F32, F32, F32 -> Bool
	level_blocked = |g, x0, y0, x1, y1|
		if x1 < 0.0 or y1 < 0.0 {
			Bool.False
		} else {
			c0 = if (x0 < 0.0) 0 else floor_u(x0 / cell)
			r0 = if (y0 < 0.0) 0 else floor_u(y0 / cell)
			c1 = U64.min(floor_u(x1 / cell), g.cols - 1)
			r1 = U64.min(floor_u(y1 / cell), g.rows - 1)
			var $hit = Bool.False
			var $row = r0
			while !$hit and $row <= r1 {
				var $col = c0
				while !$hit and $col <= c1 {
					$hit = List.get(g.hit, $row * g.cols + $col) ?? Bool.False
					$col = $col + 1
				}
				$row = $row + 1
			}
			$hit
		}

	# ── choosing the names ─────────────────────────────────────────────────
	# one run's label, and the centre the repetition rule measures from;
	# Err when the run is off the region, shows no stretch straight enough,
	# or has every spot on a route
	label_of : Run, Scene.Measure, Labels.Rect, Grid -> Try({ label : Labels.Label(Item), at : Labels.Pt }, [Unnamed])
	label_of = |run, measure, region, g| {
		l = look(run.kind)
		it = Scene.prose(run.text, l.size, l.color)
		tw = measure(run.text, l.size, Prose)
		bw = tw + 2.0 * gap
		bh = l.size + 2.0 * gap
		box = |at, d, angle| {
			t = turned(d.w, d.h, angle)
			{ x: at.x - t.w / 2.0, y: at.y - t.h / 2.0 }
		}
		if Mvt.is_street(run.kind) {
			fits = |s| {
				t = turned(bw, bh, s.angle)
				spot = box(s.at, { w: bw, h: bh }, s.angle)
				if Labels.inside({ x: spot.x, y: spot.y, w: t.w, h: t.h }, region) and !(blocked(g, s.at, bw, bh, s.angle)) {
					Ok({ label: { w: t.w, h: t.h, spots: [spot], prio: prio(run), keep: Bool.False, region, item: { item: it, w: tw, angle: s.angle } }, at: s.at })
				} else {
					Err(Unnamed)
				}
			}
			found = List.join(List.map(clip(run.pts, region), |part| stretches(part, bw, l.size * stray)))
			match List.first(List.keep_oks(found, fits)) {
				Ok(c) => Ok(c)
				Err(_) => Err(Unnamed)
			}
		} else {
			match List.first(run.pts) {
				Err(_) => Err(Unnamed)
				Ok(p) => {
					centres = [p, { x: p.x, y: p.y - bh }, { x: p.x, y: p.y + bh }, { x: p.x + bw / 2.0 + gap, y: p.y }, { x: p.x - bw / 2.0 - gap, y: p.y }]
					clear = List.keep_if(centres, |at| Labels.inside({ x: at.x - bw / 2.0, y: at.y - bh / 2.0, w: bw, h: bh }, region) and !(blocked(g, at, bw, bh, 0.0)))
					if List.is_empty(clear) {
						Err(Unnamed)
					} else {
						Ok({ label: { w: bw, h: bh, spots: List.map(clear, |at| box(at, { w: bw, h: bh }, 0.0)), prio: prio(run), keep: Bool.False, region, item: { item: it, w: tw, angle: 0.0 } }, at: p })
					}
				}
			}
		}
	}

	# the runs a zoom shows, in the placer's order: each place kind by
	# rank, then each street kind, a kind keeping the order the runs came in
	ordered : List(Run), F32 -> List(Run)
	ordered = |runs, mpp| {
		shown = List.keep_if(runs, |r| shows(r.kind, mpp))
		place_prios = List.map_with_index(List.repeat({}, U8.to_u64(Mvt.street_kind) * 20), |_, i| i + 1)
		places = List.join(List.map(place_prios, |p| List.keep_if(shown, |r| !(Mvt.is_street(r.kind)) and prio(r) == p)))
		street_kinds = List.map_with_index(List.repeat({}, List.len(Mvt.name_kinds) - U8.to_u64(Mvt.street_kind)), |_, i| U64.to_u8_wrap(i) + Mvt.street_kind)
		streets = List.join(List.map(street_kinds, |k| List.keep_if(shown, |r| r.kind == k)))
		List.concat(places, streets)
	}

	# whether a run can be named in the region at all: a place's point lies
	# inside it, and a street's points span a box that meets it
	touches : Run, Labels.Rect -> Bool
	touches = |run, r|
		if Mvt.is_street(run.kind) {
			b = List.fold(run.pts, { x0: 1.0e30, y0: 1.0e30, x1: -1.0e30, y1: -1.0e30 }, |a, p| { x0: F32.min(a.x0, p.x), y0: F32.min(a.y0, p.y), x1: F32.max(a.x1, p.x), y1: F32.max(a.y1, p.y) })
			b.x1 >= r.x and b.x0 <= r.x + r.w and b.y1 >= r.y and b.y0 <= r.y + r.h
		} else {
			match List.first(run.pts) {
				Ok(p) => p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h
				Err(_) => Bool.False
			}
		}

	# The labels a view offers the placer: the runs that reach its region
	# (`touches`) and that its zoom shows, in order, each that has a spot
	# clear of the routes and is not within repeat_px of a run of its name
	# already chosen, up to `most`. A place is held to that rule by its
	# point before its spots are looked at.
	choose : List(Run), F32, Scene.Measure, Labels.Rect, Grid -> List(Labels.Label(Item))
	choose = |runs, mpp, measure, region, g| {
		var $kept = []
		repeats = |kept, text, at| List.any(kept, |k| dist(k.at, at) < repeat_px and k.text == text)
		for r in ordered(List.keep_if(runs, |r0| touches(r0, region)), mpp) {
			early =
				if Mvt.is_street(r.kind) {
					Bool.False
				} else {
					match List.first(r.pts) {
						Ok(p) => repeats($kept, r.text, p)
						Err(_) => Bool.True
					}
				}
			if List.len($kept) < most and !early {
				match label_of(r, measure, region, g) {
					Ok(c) =>
						if !(repeats($kept, r.text, c.at)) {
							$kept = List.append($kept, { at: c.at, text: r.text, label: c.label })
						}
					Err(_) => {}
				}
			}
		}
		List.map($kept, |k| k.label)
	}

	# the names placed against what the view already holds
	place : List(Run), F32, Scene.Measure, Labels.Rect, Grid, Labels.Obstacles -> List(Labels.Placed(Item))
	place = |runs, mpp, measure, region, g, obs| Labels.place(choose(runs, mpp, measure, region, g), obs)

	# the placements as the gate reads them, each named by its text
	owned : List(Labels.Placed(Item)) -> List(Labels.Owned)
	owned = |ps| List.map(ps, |p| { key: "'${p.item.item.text}'", box: p.box, region: p.region })
}

# a measure of ten pixels a character at any size, for the expects
ten : Scene.Measure
ten = |text, _size, _face| U64.to_f32(Str.count_utf8_bytes(text)) * 10.0

map_region : Labels.Rect
map_region = { x: 0.0, y: 0.0, w: 1000.0, h: 600.0 }

# places at the wide zooms, the smaller ones and the streets only closer in;
# a city is not named at street level, and a minor road only close in
expect {
	at = |mpp| List.keep_if([0, 1, 2, 3, 4, 5, 6, 7, 8], |k| MapNames.shows(k, mpp))
	at(1000.0) == [0] and at(200.0) == [0, 1] and at(50.0) == [0, 1, 2, 3] and at(30.0) == [0, 1, 2, 3, 5] and at(12.0) == [0, 1, 2, 3, 4, 5, 6] and at(6.0) == [0, 1, 2, 3, 4, 5, 6, 7] and at(2.0) == [2, 3, 4, 5, 6, 7, 8] and at(1.0) == [3, 4, 5, 6, 7, 8]
}

# larger places before smaller, a place's rank inside its kind with the
# unranked last, then the streets major first, whatever order they came in
expect {
	run = |kind, rank, text| { kind, rank, text, pts: [{ x: 100.0, y: 100.0 }] }
	got = MapNames.ordered([run(8, 0, "minor"), run(3, 0, "suburb"), run(6, 0, "arterial"), run(1, 0, "town unranked"), run(1, 2, "town 2"), run(0, 5, "city")], 5.0)
	List.map(got, |r| r.text) == ["city", "town 2", "town unranked", "suburb", "arterial"]
}

# a straight run is named at its middle along its own direction; a run
# drawn the other way reads the same way up; a vertical one turns a
# quarter; one too short for the text, or bent everywhere, is not named
expect {
	flat = MapNames.along([{ x: 0.0, y: 100.0 }, { x: 400.0, y: 100.0 }], 100.0, 3.0)
	slope = MapNames.along([{ x: 0.0, y: 0.0 }, { x: 100.0, y: 100.0 }, { x: 200.0, y: 200.0 }], 100.0, 3.0)
	back = MapNames.along([{ x: 200.0, y: 200.0 }, { x: 100.0, y: 100.0 }, { x: 0.0, y: 0.0 }], 100.0, 3.0)
	up = MapNames.along([{ x: 50.0, y: 300.0 }, { x: 50.0, y: 0.0 }], 100.0, 3.0)
	zig = List.map_with_index(List.repeat({}, 21), |_, i| { x: U64.to_f32(i) * 10.0, y: if (i % 2 == 0) 0.0 else 12.0 })
	match (flat, slope, back, up) {
		(Ok(f), Ok(s), Ok(b), Ok(u)) =>
			(f.at.x - 200.0).abs() < 0.01 and (f.at.y - 100.0).abs() < 0.01 and f.angle == 0.0
				and (s.angle - 45.0).abs() < 0.01 and (b.angle - 45.0).abs() < 0.01 and (s.at.x - 100.0).abs() < 0.01
				and (u.angle.abs() - 90.0).abs() < 0.01
				and MapNames.along([{ x: 0.0, y: 0.0 }, { x: 80.0, y: 0.0 }], 100.0, 3.0) == Err(Bent)
				and MapNames.along(zig, 100.0, 3.0) == Err(Bent)
		_ => Bool.False
	}
}

# a run bent at its middle is named on the straight stretch beside it; a
# gentle wobble within the tolerance still reads as straight
expect {
	elbow = [{ x: 0.0, y: 0.0 }, { x: 300.0, y: 0.0 }, { x: 300.0, y: 300.0 }]
	wobble = [{ x: 0.0, y: 0.0 }, { x: 50.0, y: 1.0 }, { x: 100.0, y: 0.0 }, { x: 150.0, y: -1.0 }, { x: 200.0, y: 0.0 }]
	match (MapNames.along(elbow, 100.0, 3.0), MapNames.along(wobble, 100.0, 3.0)) {
		(Ok(e), Ok(w)) => (e.angle == 0.0 or (e.angle.abs() - 90.0).abs() < 0.01) and (e.at.x - 300.0).abs() + (e.at.y - 0.0).abs() > 40.0 and w.angle == 0.0
		_ => Bool.False
	}
}

# the upright box around a turned one: level keeps it, a quarter turn
# swaps its sides
expect {
	l = MapNames.turned(100.0, 10.0, 0.0)
	q = MapNames.turned(100.0, 10.0, 90.0)
	(l.w - 100.0).abs() < 0.01 and (l.h - 10.0).abs() < 0.01 and (q.w - 10.0).abs() < 0.01 and (q.h - 100.0).abs() < 0.01
}

# a route marks the cells it passes through: a box over it is blocked, one
# beside it is not, and one turned across it is blocked though its upright
# position would not be
expect {
	g = MapNames.grid(map_region, [[{ x: 100.0, y: 300.0 }, { x: 900.0, y: 300.0 }]], |p| p)
	MapNames.blocked(g, { x: 500.0, y: 302.0 }, 60.0, 10.0, 0.0)
		and !(MapNames.blocked(g, { x: 500.0, y: 330.0 }, 60.0, 10.0, 0.0))
		and MapNames.blocked(g, { x: 500.0, y: 330.0 }, 80.0, 10.0, 90.0)
		and !(MapNames.blocked(MapNames.grid(map_region, [], |p| p), { x: 500.0, y: 302.0 }, 60.0, 10.0, 0.0))
}

# a place on a route takes a spot beside it; a street whose stretch lies on
# a route is not named
expect {
	g = MapNames.grid(map_region, [[{ x: 0.0, y: 300.0 }, { x: 1000.0, y: 300.0 }]], |p| p)
	town = { kind: 1, rank: 1, text: "Oak Park", pts: [{ x: 500.0, y: 300.0 }] }
	road = { kind: 6, rank: 0, text: "Lake Street", pts: [{ x: 0.0, y: 300.0 }, { x: 1000.0, y: 300.0 }] }
	got = MapNames.choose([town, road], 10.0, ten, map_region, g)
	match got {
		[t] => List.all(t.spots, |s| s.y + t.h <= 300.0 or s.y >= 300.0) and t.item.item.text == "Oak Park"
		_ => Bool.False
	}
}

# a name repeats along a road only past repeat_px from its last run, and a
# place a neighbouring tile's buffer repeats is named once
expect {
	g = MapNames.grid(map_region, [], |p| p)
	seg = |x0| { kind: 6, rank: 0, text: "Halsted Street", pts: [{ x: x0, y: 200.0 }, { x: x0 + 200.0, y: 200.0 }] }
	twice = { kind: 0, rank: 1, text: "Chicago", pts: [{ x: 300.0, y: 400.0 }] }
	got = MapNames.choose([seg(0.0), seg(200.0), seg(400.0), twice, twice], 10.0, ten, map_region, g)
	centre = |l|
		match List.first(l.spots) {
			Ok(s) => (F32.round_to_u64_try(s.x + l.w / 2.0)) ?? 0
			Err(_) => 0
		}
	xs = List.map(List.keep_if(got, |l| l.item.item.text == "Halsted Street"), centre)
	xs == [100, 500] and List.count_if(got, |l| l.item.item.text == "Chicago") == 1
}

# a turned street's label holds its text's turned box, and the placer keeps
# two crossing streets' names apart
expect {
	g = MapNames.grid(map_region, [], |p| p)
	ns = { kind: 7, rank: 0, text: "Damen Avenue", pts: [{ x: 500.0, y: 0.0 }, { x: 500.0, y: 600.0 }] }
	ew = { kind: 7, rank: 0, text: "Cermak Road", pts: [{ x: 0.0, y: 300.0 }, { x: 1000.0, y: 300.0 }] }
	placed = MapNames.place([ns, ew], 5.0, ten, map_region, g, { boxes: [], segs: [] })
	boxes = List.map(placed, |p| p.box)
	List.len(placed) == 1 and Labels.check(MapNames.owned(placed)) == []
		and match MapNames.choose([ns], 5.0, ten, map_region, g) {
			[l] => (l.h - (120.0 + 2.0 * MapNames.gap)).abs() < 0.5 and (l.item.angle.abs() - 90.0).abs() < 0.01
			_ => Bool.False
		}
		and List.all(boxes, |b| Labels.inside(b, map_region))
}

# a run is cut to the rectangle: a line crossing it keeps the part inside,
# a run inside it stays one part however many points it has, a run that
# leaves and comes back is two parts, and one wholly outside is none
expect {
	r = { x: 100.0, y: 100.0, w: 200.0, h: 100.0 }
	ints = |parts| List.map(parts, |ps| List.map(ps, |p| ((F32.round_to_u64_try(p.x)) ?? 9999, (F32.round_to_u64_try(p.y)) ?? 9999)))
	across = MapNames.clip([{ x: 0.0, y: 150.0 }, { x: 400.0, y: 150.0 }], r)
	inside = MapNames.clip([{ x: 120.0, y: 150.0 }, { x: 200.0, y: 160.0 }, { x: 280.0, y: 150.0 }], r)
	back = MapNames.clip([{ x: 150.0, y: 150.0 }, { x: 150.0, y: 0.0 }, { x: 250.0, y: 0.0 }, { x: 250.0, y: 150.0 }], r)
	ints(across) == [[(100, 150), (300, 150)]]
		and ints(inside) == [[(120, 150), (200, 160), (280, 150)]]
		and ints(back) == [[(150, 150), (150, 100)], [(250, 100), (250, 150)]]
		and MapNames.clip([{ x: 0.0, y: 0.0 }, { x: 50.0, y: 50.0 }], r) == []
}

# every street near vertical reads top to bottom whichever way it leans,
# a steep slant up keeps its own way, and a near-level one draws level
expect (MapNames.upright(1.0, -50.0) - 91.15).abs() < 0.05 and (MapNames.upright(1.0, 50.0) - 88.85).abs() < 0.05 and MapNames.upright(0.0, -1.0) == 90.0 and (MapNames.upright(1.0, -1.0) + 45.0).abs() < 0.01 and (MapNames.upright(-1.0, 4.0) + 75.96).abs() < 0.05 and MapNames.upright(100.0, 1.0) == 0.0

# a cell measure's whole part, as floor gives it for numbers no less than
# zero
expect MapNames.floor_u(3.7) == 3 and MapNames.floor_u(0.2) == 0 and MapNames.floor_u(4.0) == 4 and MapNames.floor_u(1023.999) == 1023

# a run reaches the region when a place's point lies inside it or a
# street's span meets it, even with no point of the street inside
expect {
	place = |x, y| { kind: 3, rank: 0, text: "Pilsen", pts: [{ x, y }] }
	street = |pts| { kind: 7, rank: 0, text: "Archer Avenue", pts }
	MapNames.touches(place(500.0, 300.0), map_region) and !(MapNames.touches(place(1200.0, 300.0), map_region))
		and MapNames.touches(street([{ x: -500.0, y: 300.0 }, { x: 1500.0, y: 300.0 }]), map_region)
		and !(MapNames.touches(street([{ x: -500.0, y: 700.0 }, { x: 1500.0, y: 800.0 }]), map_region))
}

# a street a route crosses at its middle is named on a straight stretch
# beside the crossing, clear of the route
expect {
	g = MapNames.grid(map_region, [[{ x: 500.0, y: 0.0 }, { x: 500.0, y: 600.0 }]], |p| p)
	road = { kind: 6, rank: 0, text: "Lake Street", pts: [{ x: 100.0, y: 300.0 }, { x: 900.0, y: 300.0 }] }
	match MapNames.choose([road], 10.0, ten, map_region, g) {
		[l] =>
			match List.first(l.spots) {
				Ok(s) => s.x + l.w <= 500.0 or s.x >= 500.0
				Err(_) => Bool.False
			}
		_ => Bool.False
	}
}

# a run whose chord is long enough but whose bump strays past the
# tolerance from it does not read as straight
expect {
	bump = [{ x: 0.0, y: 0.0 }, { x: 100.0, y: 0.0 }, { x: 110.0, y: 5.0 }, { x: 120.0, y: 0.0 }, { x: 220.0, y: 0.0 }]
	MapNames.along(bump, 100.0, 3.0) == Err(Bent) and MapNames.along(bump, 100.0, 6.0) != Err(Bent)
}

# a street's ink sits between the faint ink and the places' muted one on
# every channel, three quarters of the way up, and every kind wears one of
# the two
expect {
	s = MapNames.street_ink
	f = Theme.ink_faint
	m = Theme.ink_muted
	s.r > f.r and s.r < m.r and s.g > f.g and s.g < m.g and s.b > f.b and s.b < m.b and s == Color.rgba(167, 179, 195, 255)
		and List.all([0, 1, 2, 3, 4], |k| (MapNames.look(k)).color == MapNames.place_ink) and List.all([5, 6, 7, 8], |k| (MapNames.look(k)).color == MapNames.street_ink)
		and MapNames.place_ink == m
}
