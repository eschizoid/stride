import Geo
import Mvt

Tiles :: [].{
	# ── the street map's tiles (pure) ──────────────────────────────────────
	# The web's tile pyramid over Web Mercator's square world: zoom z cuts
	# it into 2^z by 2^z tiles, x counted east from the antimeridian and y
	# south from the projection's northern limit. OpenFreeMap serves every
	# tile of the planet in the OpenMapTiles schema down to zoom 14, where
	# its detail stops; a closer view draws zoom 14's tiles larger.
	#
	# A view asks for the tiles that cover it at the zoom its scale needs,
	# and for the one coarse tile three zooms up over each, so a pan into
	# new ground shows that coarse tile at once and sharpens as the rest
	# arrive. A tile not yet drawn shows its nearest drawn ancestor in its
	# place, cut to its square.

	Key : { z : U64, x : U64, y : U64 }

	# one tile of a view: its key, and its column east of the antimeridian
	# with no wrap, which places it beside its neighbours when a view runs
	# across the antimeridian and the key's x wraps round
	Cell : { key : Key, col : I64 }

	# the projected world's width, and half of it, in metres
	world : F64
	world = 2.0 * Geo.pi * Geo.radius

	half : F64
	half = Geo.pi * Geo.radius

	max_zoom : U64
	max_zoom = 14

	# a tile is drawn 256 to 512 logical pixels across at the zoom its view's
	# scale needs, and larger past zoom 14 or when a view that would need
	# more than max_cells tiles is drawn a zoom coarser; 256 is one zoom
	# closer than a map styled for 512-pixel tiles draws, for more detail
	tile_px : F64
	tile_px = 256.0

	# how many zooms up the coarse tile under a view sits
	coarse_up : U64
	coarse_up = 3

	# the most tiles a view asks for; a view that would need more is drawn
	# from a coarser zoom
	max_cells : U64
	max_cells = 48

	tiles_at : U64 -> U64
	tiles_at = |z| U64.pow(2, z)

	# a tile's side, in projected metres
	size : U64 -> F64
	size = |z| world / U64.to_f64(tiles_at(z))

	floor64 : F64 -> I64
	floor64 = |v| (F64.to_i64_try(F64.div_floor_by(v, 1.0))) ?? 0

	# the zoom whose tiles span tile_px to twice that, in logical pixels, at
	# mpp metres per pixel, held to the pyramid's zooms
	zoom_for : F32 -> U64
	zoom_for = |mpp| {
		t = world / (tile_px * F32.to_f64(mpp))
		z = if (t <= 1.0) 0 else floor64(Geo.ln(t) / Geo.ln2 + 1.0e-9)
		if (z < 0) 0 else if (z > U64.to_i64_wrap(max_zoom)) max_zoom else I64.to_u64_wrap(z)
	}

	# the column and row holding a projected point, the column unwrapped
	# and the row held to the pyramid
	cell_at : { x : F64, y : F64 }, U64 -> { col : I64, row : I64 }
	cell_at = |m, z| {
		s = size(z)
		last = U64.to_i64_wrap(tiles_at(z)) - 1
		row = floor64((half - m.y) / s)
		{ col: floor64((m.x + half) / s), row: if (row < 0) 0 else if (row > last) last else row }
	}

	# the key a column wraps to
	key_of : U64, I64, I64 -> Key
	key_of = |z, col, row| {
		n = U64.to_i64_wrap(tiles_at(z))
		{ z, x: I64.to_u64_wrap(I64.rem_by(I64.rem_by(col, n) + n, n)), y: I64.to_u64_wrap(row) }
	}

	# the tile holding a coordinate
	of_lat_lng : F64, F64, U64 -> Key
	of_lat_lng = |lat, lng, z| {
		c = cell_at(Geo.merc(lat, lng), z)
		key_of(z, c.col, c.row)
	}

	# a tile's north-west corner in degrees: the inverse of the projection,
	# latitude = atan(sinh(y / R))
	corner : Key -> { lat : F64, lng : F64 }
	corner = |k| {
		s = size(k.z)
		mx = U64.to_f64(k.x) * s - half
		my = half - U64.to_f64(k.y) * s
		e = F64.pow(2.718281828459045, my / Geo.radius)
		sinh = (e - 1.0 / e) / 2.0
		{ lat: F64.atan(sinh) * 180.0 / Geo.pi, lng: mx / Geo.radius * 180.0 / Geo.pi }
	}

	# a tile's north-west corner in projected metres, by unwrapped column
	nw : U64, I64, I64 -> { x : F64, y : F64 }
	nw = |z, col, row| { x: I64.to_f64(col) * size(z) - half, y: half - I64.to_f64(row) * size(z) }

	# the tiles at zoom z meeting the map rectangle, row by row from the
	# north-west; the origin is the projected point the camera's metres are
	# counted from
	cover : Geo.Cam, Geo.Rect, { x : F64, y : F64 }, U64 -> List(Cell)
	cover = |cam, r, origin, z| {
		sw = Geo.to_world(cam, r, r.x, r.y + r.h)
		ne = Geo.to_world(cam, r, r.x + r.w, r.y)
		lo = cell_at({ x: origin.x + F32.to_f64(sw.x), y: origin.y + F32.to_f64(sw.y) }, z)
		hi = cell_at({ x: origin.x + F32.to_f64(ne.x), y: origin.y + F32.to_f64(ne.y) }, z)
		var $out = []
		var $row = hi.row
		while $row <= lo.row {
			var $col = lo.col
			while $col <= hi.col {
				$out = List.append($out, { key: key_of(z, $col, $row), col: $col })
				$col = $col + 1
			}
			$row = $row + 1
		}
		$out
	}

	# the cells a camera draws: at the zoom its scale needs, or coarser
	# while that zoom would ask for more than max_cells
	view : Geo.Cam, Geo.Rect, { x : F64, y : F64 } -> { z : U64, cells : List(Cell) }
	view = |cam, r, origin| {
		var $z = zoom_for(cam.mpp)
		var $cells = cover(cam, r, origin, $z)
		while List.len($cells) > max_cells and $z > 0 {
			$z = $z - 1
			$cells = cover(cam, r, origin, $z)
		}
		{ z: $z, cells: $cells }
	}

	# the cell `up` zooms above, the one whose square holds this one's
	up_cell : Cell, U64 -> Cell
	up_cell = |c, up| {
		d = U64.to_i64_wrap(tiles_at(up))
		col = I64.div_floor_by(c.col, d)
		{ key: key_of(c.key.z - up, col, U64.to_i64_wrap(c.key.y) // d), col }
	}

	# what a view asks for: the coarse cells first, each once, then its own
	wanted : List(Cell) -> List(Cell)
	wanted = |cells| {
		coarse = List.fold(
			cells,
			[],
			|acc, c|
				if c.key.z < coarse_up {
					acc
				} else {
					u = up_cell(c, coarse_up)
					if (List.any(acc, |a| a.key == u.key)) acc else List.append(acc, u)
				},
		)
		List.concat(coarse, cells)
	}

	# Where a tile draws on screen: its north-west corner, and the logical
	# pixels one tile unit spans.
	Place : { x : F32, y : F32, k : F32 }

	place : Geo.Cam, Geo.Rect, { x : F64, y : F64 }, U64, I64, I64 -> Place
	place = |cam, r, origin, z, col, row| {
		c = nw(z, col, row)
		s = Geo.to_screen(cam, r, { x: F64.to_f32_wrap(c.x - origin.x), y: F64.to_f32_wrap(c.y - origin.y) })
		{ x: s.x, y: s.y, k: F64.to_f32_wrap(size(z) / F32.to_f64(Mvt.extent_units)) / cam.mpp }
	}

	# ── the tile source ─────────────────────────────────────────────────────
	# OpenFreeMap names its tiles in a TileJSON document whose first `tiles`
	# entry is the URL template of the current planet build,
	# https://tiles.openfreemap.org/planet/<build>/{z}/{x}/{y}.pbf. The
	# build changes as the planet is rebuilt, so the template is read from
	# the document rather than written here. A template outside the origin
	# the window may fetch from is refused.
	tilejson_url : Str
	tilejson_url = "https://tiles.openfreemap.org/planet"

	origin_url : Str
	origin_url = "https://tiles.openfreemap.org"

	template_of : Str -> Try(Str, [NoTemplate])
	template_of = |doc|
		match Str.split_first(doc, "\"tiles\"") {
			Err(_) => Err(NoTemplate)
			Ok(s1) =>
				match Str.split_first(s1.after, "\"") {
					Err(_) => Err(NoTemplate)
					Ok(s2) =>
						match Str.split_first(s2.after, "\"") {
							Err(_) => Err(NoTemplate)
							Ok(s3) => {
								t = s3.before
								if Str.starts_with(t, Str.concat(origin_url, "/")) and Str.contains(t, "{z}") and Str.contains(t, "{x}") and Str.contains(t, "{y}") {
									Ok(t)
								} else {
									Err(NoTemplate)
								}
							}
						}
				}
		}

	# the planet build a template names: the path segment after /planet/
	build_of : Str -> Str
	build_of = |t|
		match Str.split_first(t, "/planet/") {
			Ok(s) =>
				match Str.split_first(s.after, "/") {
					Ok(b) => b.before
					Err(_) => ""
				}
			Err(_) => ""
		}

	url : Str, Key -> Str
	url = |t, k| Str.replace_each(Str.replace_each(Str.replace_each(t, "{z}", U64.to_str(k.z)), "{x}", U64.to_str(k.x)), "{y}", U64.to_str(k.y))

	# A cached tile is kept by its key alone, whichever build it came from,
	# since each rebuild changes little of the map and a cache keyed by
	# build would fetch every tile ever seen again after every rebuild. One
	# older than this is fetched again, by the build of the day.
	max_age_secs : I64
	max_age_secs = 90 * 86400

	fresh : I64 -> Bool
	fresh = |age| age < max_age_secs

	# A tile answer's body: a 200 carries the tile and a 204 an empty one,
	# a tile with nothing in it. A 200 with no body is a fetch that failed
	# and is tried again, never a tile cached as empty; any other status is
	# a failure too.
	body_of : U16, List(U8) -> Try(List(U8), [NotATile])
	body_of = |status, body|
		if status == 204 {
			Ok([])
		} else if status == 200 and !(List.is_empty(body)) {
			Ok(body)
		} else {
			Err(NotATile)
		}

	# The cache's bound: the tiles kept are the most recently used whose
	# bytes, taken newest first, fit in cache_budget; every tile past that
	# point goes, oldest use first, a tie going by zoom, column and row. A
	# street-detail tile of a dense city runs to hundreds of kilobytes, so
	# 64 MB holds the street detail of a few metro areas and every coarser
	# zoom over them, and keeps the cache below the size of the athlete's
	# own records in the same file. A tile's last use is recorded when it
	# is stored and, at most hourly, when it is read.
	cache_budget : U64
	cache_budget = 64 * 1024 * 1024

	touch_secs : I64
	touch_secs = 3600

	# a key as one number in zoom, column, row order: a column or row stays
	# below 2^28 at any zoom the pyramid has
	order : Key -> U64
	order = |k| k.z * 72057594037927936 + k.x * 268435456 + k.y

	evicted : List({ key : Key, bytes : U64, used : I64 }), U64 -> List(Key)
	evicted = |rows, budget| {
		newest_first = List.sort_with(
			rows,
			|a, b|
				if a.used > b.used {
					Before
				} else if a.used < b.used {
					After
				} else if order(a.key) < order(b.key) {
					Before
				} else {
					After
				},
		)
		var $total = 0
		var $out = []
		for r in newest_first {
			$total = $total + r.bytes
			if $total > budget {
				$out = List.append($out, r.key)
			}
		}
		$out
	}

	# ── what the window knows of each tile ─────────────────────────────────
	# Fetching: a task is reading it. Waiting: it is not cached and the
	# source has not been read yet. Drawn: its picture, which a stale cached
	# copy refreshes from the network once the source is known (Wanted),
	# while a task does so (Running), or not again this run (Done). Failed:
	# neither the cache nor the network had it, as of that tick. A slot
	# remembers the tick a view last asked for it, and the slots no view
	# needs are dropped oldest first past max_slots.
	Slot : { key : Key, state : [Fetching, Waiting, Drawn(Mvt.Tile), Failed(U64)], refresh : [Done, Wanted, Running], used : U64 }

	# the TileJSON's state: not yet read, being read, its template, or
	# unreachable as of a tick
	Source : [Unasked, Asking, Known(Str), Unreachable(U64)]

	max_slots : U64
	max_slots = 64

	# tile tasks running at once; the window's SQLite allows eight open
	# connections, and the other tasks need theirs
	max_running : U64
	max_running = 4

	running : List(Slot) -> U64
	running = |slots|
		List.count_if(
			slots,
			|s|
				match (s.state, s.refresh) {
					(Fetching, _) => Bool.True
					(_, Running) => Bool.True
					_ => Bool.False
				},
		)

	known : Source -> Bool
	known = |src|
		match src {
			Known(_) => Bool.True
			_ => Bool.False
		}

	# a source that failed is asked again once the retry has passed
	askable : Source, U64, U64 -> Bool
	askable = |src, tick, retry|
		match src {
			Unasked => Bool.True
			Unreachable(t) => tick - t >= retry
			_ => Bool.False
		}

	# One frame's decision for the tiles a view wants, in the order they
	# are wanted: which to start a task for (each marked Fetching, or its
	# refresh Running), whether the source must be read first, and the
	# slots after it. A tile is started when the window has no slot for it,
	# when it waited for a source that is now known, when its failure is a
	# retry old, or when its stale copy wants refreshing and the source is
	# known; never more than max_running at once.
	Plan : { slots : List(Slot), start : List(Key), ask : Bool }

	plan : List(Slot), List(Key), Source, U64, U64 -> Plan
	plan = |slots0, want, src, tick, retry| {
		var $slots = slots0
		var $start = []
		var $ask = Bool.False
		var $free = max_running - U64.min(max_running, running(slots0))
		for k in want {
			match List.find_first_index($slots, |s| s.key == k) {
				Err(_) =>
					if $free > 0 {
						$slots = List.append($slots, { key: k, state: Fetching, refresh: Done, used: tick })
						$start = List.append($start, k)
						$free = $free - 1
					}
				Ok(i) => {
					s = List.get($slots, i) ?? { key: k, state: Fetching, refresh: Done, used: tick }
					go = match (s.state, s.refresh) {
						(Waiting, _) => known(src)
						(Failed(t), _) => tick - t >= retry
						(Drawn(_), Wanted) => known(src)
						_ => Bool.False
					}
					needs_src = match (s.state, s.refresh) {
						(Waiting, _) => !(known(src))
						(Drawn(_), Wanted) => !(known(src))
						_ => Bool.False
					}
					$ask = $ask or needs_src
					next =
						if go and $free > 0 {
							$start = List.append($start, k)
							$free = $free - 1
							match s.state {
								Drawn(_) => { ..s, refresh: Running, used: tick }
								_ => { ..s, state: Fetching, used: tick }
							}
						} else {
							{ ..s, used: tick }
						}
					$slots = List.set($slots, i, next) ?? $slots
				}
			}
		}
		{ slots: trim($slots, want), start: $start, ask: $ask and askable(src, tick, retry) }
	}

	# past max_slots, the slots no view wants and no task is filling go,
	# least recently wanted first
	trim : List(Slot), List(Key) -> List(Slot)
	trim = |slots, want| {
		over = List.len(slots) - U64.min(List.len(slots), max_slots)
		if over == 0 {
			slots
		} else {
			idle = |s| !(List.contains(want, s.key)) and running([s]) == 0
			oldest = List.sort_with(List.keep_if(slots, idle), |a, b| if (a.used < b.used) Before else if (a.used > b.used) After else Same)
			gone = List.map(List.take_first(oldest, over), |s| s.key)
			List.drop_if(slots, |s| List.contains(gone, s.key))
		}
	}

	# What a task's answer does to a tile's slot. A tile read whole lands
	# drawn, its refresh wanted when it came stale from the cache before the
	# network was tried; a stale copy the network could not replace keeps
	# the copy. A tile that is not there waits for the source when the
	# network was not tried and fails as of this tick when it was, unless a
	# copy is already drawn, which stays.
	Answer : [Read({ key : Key, tile : Mvt.Tile, fresh : Bool, tried : Bool }), Absent({ key : Key, tried : Bool })]

	land : List(Slot), Answer, U64 -> List(Slot)
	land = |slots, ans, tick| {
		k = match ans {
			Read(r) => r.key
			Absent(a) => a.key
		}
		List.map(
			slots,
			|s|
				if s.key != k {
					s
				} else {
					match ans {
						Read(r) => { ..s, state: Drawn(r.tile), refresh: if (!r.fresh and !r.tried) Wanted else Done }
						Absent(a) =>
							match s.state {
								Drawn(_) => { ..s, refresh: Done }
								_ => { ..s, state: if (a.tried) Failed(tick) else Waiting, refresh: Done }
							}
					}
				},
		)
	}

	# the drawn tile for a key, if the window holds one
	drawn : List(Slot), Key -> Try(Mvt.Tile, [NotDrawn])
	drawn = |slots, k|
		match List.find_first(slots, |s| s.key == k) {
			Ok(s) =>
				match s.state {
					Drawn(t) => Ok(t)
					_ => Err(NotDrawn)
				}
			Err(_) => Err(NotDrawn)
		}

	# What a cell draws: its own tile, else the nearest drawn ancestor's,
	# with the zoom and column it sits at, else nothing.
	Shown : { tile : Mvt.Tile, z : U64, col : I64, row : I64 }

	shown : List(Slot), Cell -> Try(Shown, [Nothing])
	shown = |slots, c| {
		var $up = 0
		var $out = Err(Nothing)
		while $up <= c.key.z {
			u = if ($up == 0) c else up_cell(c, $up)
			match drawn(slots, u.key) {
				Ok(t) => {
					$out = Ok({ tile: t, z: u.key.z, col: u.col, row: U64.to_i64_wrap(u.key.y) })
					$up = c.key.z + 1
				}
				Err(_) => {
					$up = $up + 1
				}
			}
		}
		$out
	}

	# A view is settled once every one of its cells has its own answer: its
	# tile drawn and no refresh of it running, or nothing to be had, a fetch
	# that failed or a wait on a source that cannot be reached.
	settled : List(Slot), List(Cell), Source -> Bool
	settled = |slots, cells, src|
		List.all(
			cells,
			|c|
				match List.find_first(slots, |s| s.key == c.key) {
					Err(_) => Bool.False
					Ok(s) =>
						match (s.state, s.refresh) {
							(Drawn(_), Running) => Bool.False
							(Drawn(_), _) => Bool.True
							(Failed(_), _) => Bool.True
							(Waiting, _) =>
								match src {
									Unreachable(_) => Bool.True
									_ => Bool.False
								}
							(Fetching, _) => Bool.False
						}
				},
		)
}

near : F64, F64, F64 -> Bool
near = |a, b, tol| (a - b).abs() <= tol

# the north of Chicago's Loop lies in zoom 14's tile 4203/6088, its centre in the
# tile south of that, and both in zoom 0's only tile
expect Tiles.of_lat_lng(41.89, -87.63, 14) == { z: 14, x: 4203, y: 6088 } and Tiles.of_lat_lng(41.8781, -87.6298, 14) == { z: 14, x: 4203, y: 6089 } and Tiles.of_lat_lng(41.8781, -87.6298, 0) == { z: 0, x: 0, y: 0 }

# a tile's north-west corner maps back into that tile, and the corner of
# zoom 0 is the projection's limit at the antimeridian
expect {
	c = Tiles.corner({ z: 14, x: 4203, y: 6088 })
	z0 = Tiles.corner({ z: 0, x: 0, y: 0 })
	Tiles.of_lat_lng(c.lat - 0.0001, c.lng + 0.0001, 14) == { z: 14, x: 4203, y: 6088 }
		and near(c.lng, -87.648925781, 1.0e-6) and near(c.lat, 41.902277, 1.0e-5)
		and near(z0.lat, Geo.max_lat, 1.0e-6) and near(z0.lng, -180.0, 1.0e-9)
}

# the equator and the prime meridian meet at the corner of zoom 1's four
# tiles, and a point just south-east of it is in the south-east tile
expect Tiles.of_lat_lng(-0.001, 0.001, 1) == { z: 1, x: 1, y: 1 } and near(Tiles.corner({ z: 1, x: 1, y: 1 }).lat, 0.0, 1.0e-9)

# the zoom halves the metres per pixel each step, from the whole world in
# one tile to zoom 14, past which the view draws zoom 14 larger
expect {
	at = |z| F64.to_f32_wrap(Tiles.world / (Tiles.tile_px * U64.to_f64(Tiles.tiles_at(z))))
	Tiles.zoom_for(at(10) * 0.99) == 10 and Tiles.zoom_for(at(10) * 1.01) == 9 and Tiles.zoom_for(at(14) / 8.0) == 14 and Tiles.zoom_for(100000.0) == 0 and Tiles.zoom_for(Geo.max_mpp) == 6
}

# a view 908 by 456 logical pixels at zoom 12's scale, its tiles 300 pixels
# across, meets five columns and three rows at most, and every key lies in the pyramid
expect {
	r = { x: 36.0, y: 96.0, w: 908.0, h: 456.0 }
	origin = Geo.merc(41.88, -87.63)
	mpp = F64.to_f32_wrap(Tiles.world / (300.0 * U64.to_f64(Tiles.tiles_at(12))))
	v = Tiles.view({ cx: 0.0, cy: 0.0, mpp }, r, origin)
	v.z == 12 and List.len(v.cells) >= 6 and List.len(v.cells) <= 15 and List.all(v.cells, |c| c.key.x < 4096 and c.key.y < 4096 and c.key.z == 12) and List.any(v.cells, |c| c.key == Tiles.of_lat_lng(41.88, -87.63, 12))
}

# a view across the antimeridian keeps its columns in order and wraps the
# keys round
expect {
	r = { x: 0.0, y: 0.0, w: 600.0, h: 300.0 }
	origin = Geo.merc(0.0, 179.99)
	cells = Tiles.cover({ cx: 0.0, cy: 0.0, mpp: 20.0 }, r, origin, 10)
	List.any(cells, |c| c.key.x == 1023 and c.col == 1023) and List.any(cells, |c| c.key.x == 0 and c.col == 1024)
}

# a tile placed at its own corner spans its side in pixels at the camera's scale
expect {
	r = { x: 0.0, y: 0.0, w: 800.0, h: 400.0 }
	k = { z: 12, x: 1050, y: 1522 }
	c = Tiles.nw(12, 1050, 1522)
	origin = { x: c.x, y: c.y }
	mpp = 10.0
	p = Tiles.place({ cx: 0.0, cy: 0.0, mpp }, r, origin, k.z, 1050, 1522)
	(p.x - 400.0).abs() < 0.01 and (p.y - 200.0).abs() < 0.01 and (p.k * 4096.0 - F64.to_f32_wrap(Tiles.size(12)) / mpp).abs() < 0.01
}

# the coarse cell three zooms up holds its square, and a view wants each
# coarse cell once, before its own
expect {
	c = { key: { z: 14, x: 4203, y: 6088 }, col: 4203 }
	d = { key: { z: 14, x: 4204, y: 6088 }, col: 4204 }
	w = Tiles.wanted([c, d])
	Tiles.up_cell(c, 3) == { key: { z: 11, x: 525, y: 761 }, col: 525 } and List.map(w, |x| x.key) == [{ z: 11, x: 525, y: 761 }, c.key, d.key]
}

# the template is the TileJSON's first tile URL, and the build its planet
# segment; a document naming another origin, or no template, gives none
expect {
	doc = "{\"tilejson\":\"3.0.0\",\"tiles\":[\"https://tiles.openfreemap.org/planet/20261115_080022_pt/{z}/{x}/{y}.pbf\"],\"vector_layers\":[]}"
	t = Tiles.template_of(doc) ?? ""
	t == "https://tiles.openfreemap.org/planet/20261115_080022_pt/{z}/{x}/{y}.pbf" and Tiles.build_of(t) == "20261115_080022_pt"
		and Tiles.url(t, { z: 14, x: 4203, y: 6088 }) == "https://tiles.openfreemap.org/planet/20261115_080022_pt/14/4203/6088.pbf"
		and Tiles.template_of("{\"tiles\":[\"https://elsewhere.example/{z}/{x}/{y}.pbf\"]}") == Err(NoTemplate) and Tiles.template_of("{\"tilejson\":\"3.0.0\"}") == Err(NoTemplate)
}

# a cached tile younger than the age is drawn as it is, and one older is fetched again
expect Tiles.fresh(0) and Tiles.fresh(Tiles.max_age_secs - 1) and !(Tiles.fresh(Tiles.max_age_secs))

k1 : Tiles.Key
k1 = { z: 12, x: 1, y: 1 }

k2 : Tiles.Key
k2 = { z: 12, x: 2, y: 1 }

slot : Tiles.Key, _ -> Tiles.Slot
slot = |k, st| { key: k, state: st, refresh: Done, used: 0 }

# a tile the window has no slot for is started, and no more than four run at once
expect {
	keys = List.map_with_index(List.repeat(0, 6), |_, i| { z: 12, x: i, y: 0 })
	p = Tiles.plan([], keys, Unasked, 10, 600)
	List.len(p.start) == 4 and List.len(p.slots) == 4 and !(p.ask) and Tiles.running(p.slots) == 4 and Tiles.plan(p.slots, keys, Unasked, 11, 600).start == []
}

# a tile waiting for the source asks for it, and is started once it is known
expect {
	waiting = [slot(k1, Waiting)]
	a = Tiles.plan(waiting, [k1], Unasked, 10, 600)
	b = Tiles.plan(waiting, [k1], Known("t"), 10, 600)
	a.ask and a.start == [] and b.start == [k1] and !(b.ask) and !(Tiles.plan(waiting, [k1], Asking, 10, 600).ask)
}

# a source that could not be reached is asked again only after the retry
expect !(Tiles.plan([slot(k1, Waiting)], [k1], Unreachable(100), 300, 600).ask) and Tiles.plan([slot(k1, Waiting)], [k1], Unreachable(100), 700, 600).ask

# a failed tile is retried once the retry has passed, not before
expect Tiles.plan([slot(k1, Failed(100))], [k1], Known("t"), 300, 600).start == [] and Tiles.plan([slot(k1, Failed(100))], [k1], Known("t"), 700, 600).start == [k1]

# a stale drawn tile refreshes once the source is known, staying drawn
expect {
	stale = [{ key: k1, state: Drawn(Mvt.empty), refresh: Wanted, used: 0 }]
	p = Tiles.plan(stale, [k1], Known("t"), 10, 600)
	p.start == [k1] and List.map(p.slots, |s| s.refresh) == [Running] and Tiles.drawn(p.slots, k1) == Ok(Mvt.empty) and Tiles.plan(stale, [k1], Unasked, 10, 600).ask
}

# past the slot limit the least recently wanted idle slot goes, never one a
# view wants
expect {
	many = List.map_with_index(List.repeat(0, Tiles.max_slots), |_, i| { key: { z: 10, x: i, y: 0 }, state: Drawn(Mvt.empty), refresh: Done, used: i + 5 })
	p = Tiles.plan(many, [{ z: 10, x: 0, y: 0 }, k2], Known("t"), 1000, 600)
	List.len(p.slots) == Tiles.max_slots and List.any(p.slots, |s| s.key == { z: 10, x: 0, y: 0 }) and !(List.any(p.slots, |s| s.key == { z: 10, x: 1, y: 0 })) and List.any(p.slots, |s| s.key == k2)
}

# answers: a fresh read draws, a stale one read before the network was
# tried wants a refresh, a miss waits or fails by whether the network was
# tried, and a miss never takes away a drawn copy
expect {
	s0 = [slot(k1, Fetching)]
	Tiles.land(s0, Read({ key: k1, tile: Mvt.empty, fresh: Bool.True, tried: Bool.False }), 5) == [{ key: k1, state: Drawn(Mvt.empty), refresh: Done, used: 0 }]
		and Tiles.land(s0, Read({ key: k1, tile: Mvt.empty, fresh: Bool.False, tried: Bool.False }), 5) == [{ key: k1, state: Drawn(Mvt.empty), refresh: Wanted, used: 0 }]
		and Tiles.land(s0, Absent({ key: k1, tried: Bool.False }), 5) == [slot(k1, Waiting)]
		and Tiles.land(s0, Absent({ key: k1, tried: Bool.True }), 5) == [slot(k1, Failed(5))]
		and Tiles.land([{ key: k1, state: Drawn(Mvt.empty), refresh: Running, used: 0 }], Absent({ key: k1, tried: Bool.True }), 5) == [{ key: k1, state: Drawn(Mvt.empty), refresh: Done, used: 0 }]
}

# a cell with no tile of its own shows its nearest drawn ancestor, placed
# at that ancestor's column and row
expect {
	c = { key: { z: 14, x: 4203, y: 6088 }, col: 4203 }
	far = { key: { z: 11, x: 525, y: 761 }, state: Drawn(Mvt.empty), refresh: Done, used: 0 }
	near_up = { key: { z: 13, x: 2101, y: 3044 }, state: Drawn({ fills: [], lines: [{ kind: 1, pts: [] }] }), refresh: Done, used: 0 }
	a = Tiles.shown([far], c)
	b = Tiles.shown([far, near_up], c)
	match (a, b) {
		(Ok(x), Ok(y)) => x.z == 11 and x.col == 525 and x.row == 761 and y.z == 13 and y.col == 2101 and y.row == 3044 and Tiles.shown([], c) == Err(Nothing)
		_ => Bool.False
	}
}

# a view settles once each cell is drawn or has nothing to be had; a
# fetch, a running refresh or a wait on a source still to be read keeps it
# open
expect {
	cells = [{ key: k1, col: 1 }, { key: k2, col: 2 }]
	Tiles.settled([slot(k1, Drawn(Mvt.empty)), slot(k2, Failed(3))], cells, Unasked)
		and !(Tiles.settled([slot(k1, Drawn(Mvt.empty)), slot(k2, Fetching)], cells, Unasked))
		and !(Tiles.settled([slot(k1, Drawn(Mvt.empty))], cells, Unasked))
		and !(Tiles.settled([slot(k1, Drawn(Mvt.empty)), slot(k2, Waiting)], cells, Asking))
		and Tiles.settled([slot(k1, Drawn(Mvt.empty)), slot(k2, Waiting)], cells, Unreachable(4))
		and !(Tiles.settled([{ key: k1, state: Drawn(Mvt.empty), refresh: Running, used: 0 }, slot(k2, Failed(3))], cells, Unasked))
}

# a view that would ask for more than max_cells tiles at its own zoom is
# drawn one zoom coarser, not more
expect {
	r = { x: 0.0, y: 0.0, w: 4000.0, h: 3000.0 }
	origin = Geo.merc(41.88, -87.63)
	mpp = F64.to_f32_wrap(Tiles.world / (300.0 * U64.to_f64(Tiles.tiles_at(12))))
	v = Tiles.view({ cx: 0.0, cy: 0.0, mpp }, r, origin)
	List.len(Tiles.cover({ cx: 0.0, cy: 0.0, mpp }, r, origin, 12)) > Tiles.max_cells and v.z == 11 and List.len(v.cells) <= Tiles.max_cells
}

# tiles already running count against the limit: with three running, of
# two waiting tiles the source now names only one is started
expect {
	running = List.map_with_index(List.repeat(0, 3), |_, i| { key: { z: 5, x: i, y: 0 }, state: Fetching, refresh: Done, used: 0 })
	p = Tiles.plan(List.concat(running, [slot(k1, Waiting), slot(k2, Waiting)]), [k1, k2], Known("t"), 10, 600)
	p.start == [k1] and Tiles.running(p.slots) == 4
}

# the limits docs/viz.md states: a view of at most 48 tiles, 64 held, four
# read at once, a coarse tile three zooms up, and a cached copy good for
# ninety days
expect Tiles.max_cells == 48 and Tiles.max_slots == 64 and Tiles.max_running == 4 and Tiles.coarse_up == 3 and Tiles.max_age_secs == 90 * 86400 and Tiles.tile_px == 256.0 and Tiles.max_zoom == 14

# a 200 with a body is a tile, a 204 the empty tile, and an empty 200 or any
# other status no tile at all
expect Tiles.body_of(200, [0x1a, 0x00]) == Ok([0x1a, 0x00]) and Tiles.body_of(204, []) == Ok([]) and Tiles.body_of(200, []) == Err(NotATile) and Tiles.body_of(404, [1]) == Err(NotATile) and Tiles.body_of(500, []) == Err(NotATile)

# past the budget the least recently used tiles go, however the rows came;
# the newest stay while their bytes fit, and once one does not, every older
# one goes too, even a small one that would have fit
expect {
	row = |x, bytes, used| { key: { z: 14, x, y: 0 }, bytes, used }
	rows = [row(1, 40, 100), row(2, 30, 300), row(3, 50, 200), row(4, 5, 50)]
	Tiles.evicted(rows, 100) == [{ z: 14, x: 1, y: 0 }, { z: 14, x: 4, y: 0 }]
		and Tiles.evicted(rows, 125) == []
		and Tiles.evicted(rows, 79) == [{ z: 14, x: 3, y: 0 }, { z: 14, x: 1, y: 0 }, { z: 14, x: 4, y: 0 }]
		and Tiles.evicted([], 10) == []
}

# tiles last used at the same time keep or go by zoom, column and row
expect Tiles.evicted([{ key: { z: 9, x: 2, y: 0 }, bytes: 10, used: 5 }, { key: { z: 9, x: 1, y: 0 }, bytes: 10, used: 5 }], 15) == [{ z: 9, x: 2, y: 0 }]

# the budget the docs state
expect Tiles.cache_budget == 64 * 1024 * 1024 and Tiles.touch_secs == 3600
