import Earcut
import Geo
import Pbf

Mvt :: [].{
	# ── Mapbox vector tiles, version 2 (pure) ──────────────────────────────
	# A tile is a protocol buffer of layers (field 3). A layer has a name
	# (1), features (2), the keys (3) and values (4) its features' tags
	# index into, and an extent (5), the size of the tile's square in its
	# own units, 4096 unless it says otherwise. A feature has its tags (2),
	# packed pairs of a key index and a value index, a geometry type (3: a
	# point, a line or a polygon) and its geometry (4), packed commands. A
	# command integer holds its id in the low three bits and a repeat count
	# above them: MoveTo (1) and LineTo (2) take that many zigzagged x, y
	# deltas from a cursor that carries over from command to command, and
	# ClosePath (7) takes none. Coordinates run east and south from the
	# tile's north-west corner, and a feature may reach a little past the
	# tile's edge, into the buffer neighbouring tiles also carry.
	#
	# The window draws the OpenMapTiles schema: water and parks filled,
	# rivers and roads as lines. Everything else a tile carries (buildings,
	# labels, boundaries) is skipped without being decoded.

	Feature : { kind : U64, tags : List(U64), geometry : List(U64) }

	Layer : { name : Str, extent : U64, keys : List(Str), values : List(Str), features : List(Feature) }

	# the tile's layers by name, each one's bytes located but not decoded
	layer_fields : List(U8) -> Try(List({ name : Str, field : Pbf.Field }), [Malformed])
	layer_fields = |bytes| {
		fs = Pbf.fields(bytes, 0, List.len(bytes))?
		List.map_try(
			List.keep_if(fs, |f| f.num == 3 and f.wire == 2),
			|f| {
				inner = Pbf.fields(bytes, f.start, f.len)?
				name = match List.find_first(inner, |g| g.num == 1 and g.wire == 2) {
					Ok(g) => Pbf.text(bytes, g)
					Err(_) => ""
				}
				Ok({ name, field: f })
			},
		)
	}

	# One layer, decoded. A value that is not text (a number or a flag) is
	# kept as "", since the window reads only text values.
	layer : List(U8), Pbf.Field -> Try(Layer, [Malformed])
	layer = |bytes, lf| {
		fs = Pbf.fields(bytes, lf.start, lf.len)?
		var $name = ""
		var $extent = 4096
		var $keys = []
		var $values = []
		var $features = []
		var $bad = Bool.False
		for f in fs {
			if f.num == 1 and f.wire == 2 {
				$name = Pbf.text(bytes, f)
			} else if f.num == 5 and f.wire == 0 {
				$extent = f.value
			} else if f.num == 3 and f.wire == 2 {
				$keys = List.append($keys, Pbf.text(bytes, f))
			} else if f.num == 4 and f.wire == 2 {
				match Pbf.fields(bytes, f.start, f.len) {
					Ok(vs) =>
						match List.find_first(vs, |v| v.num == 1 and v.wire == 2) {
							Ok(v) => {
								$values = List.append($values, Pbf.text(bytes, v))
							}
							Err(_) => {
								$values = List.append($values, "")
							}
						}
					Err(_) => {
						$bad = Bool.True
					}
				}
			} else if f.num == 2 and f.wire == 2 {
				match feature(bytes, f) {
					Ok(ft) => {
						$features = List.append($features, ft)
					}
					Err(_) => {
						$bad = Bool.True
					}
				}
			}
		}
		if ($bad) Err(Malformed) else Ok({ name: $name, extent: $extent, keys: $keys, values: $values, features: $features })
	}

	feature : List(U8), Pbf.Field -> Try(Feature, [Malformed])
	feature = |bytes, ff| {
		fs = Pbf.fields(bytes, ff.start, ff.len)?
		List.fold_try(
			fs,
			{ kind: 0, tags: [], geometry: [] },
			|acc, f|
				if f.num == 2 and f.wire == 2 {
					Ok({ ..acc, tags: Pbf.packed(bytes, f.start, f.len)? })
				} else if f.num == 3 and f.wire == 0 {
					Ok({ ..acc, kind: f.value })
				} else if f.num == 4 and f.wire == 2 {
					Ok({ ..acc, geometry: Pbf.packed(bytes, f.start, f.len)? })
				} else {
					Ok(acc)
				},
		)
	}

	# the text a feature's tags give a key, "" when it has none
	tag : Layer, Feature, Str -> Str
	tag = |l, ft, key|
		match List.find_first_index(l.keys, |k| k == key) {
			Err(_) => ""
			Ok(ki) => {
				n = List.len(ft.tags) // 2
				var $i = 0
				var $out = ""
				while $i < n {
					if (List.get(ft.tags, 2 * $i) ?? 0) == ki {
						$out = List.get(l.values, List.get(ft.tags, 2 * $i + 1) ?? 0) ?? ""
						$i = n
					} else {
						$i = $i + 1
					}
				}
				$out
			}
		}

	# The geometry's parts in tile units: a MoveTo starts a part and each
	# LineTo point extends it. For a line a part is one run; for a polygon
	# it is one ring, which ClosePath ends without repeating its first point.
	parts : List(U64) -> List(List(Earcut.P))
	parts = |cmds| {
		n = List.len(cmds)
		var $i = 0
		var $x = 0
		var $y = 0
		var $cur = []
		var $out = []
		while $i < n {
			c = List.get(cmds, $i) ?? 0
			id = c % 8
			count = c // 8
			if id == 1 or id == 2 {
				if id == 1 and List.len($cur) > 0 {
					$out = List.append($out, $cur)
					$cur = []
				}
				var $k = 0
				while $k < count {
					$x = $x + Pbf.zigzag(List.get(cmds, $i + 1 + 2 * $k) ?? 0)
					$y = $y + Pbf.zigzag(List.get(cmds, $i + 2 + 2 * $k) ?? 0)
					$cur = List.append($cur, { x: $x, y: $y })
					$k = $k + 1
				}
				$i = $i + 1 + 2 * count
			} else {
				# ClosePath, or a command this version does not define
				$i = $i + 1
			}
		}
		if (List.len($cur) > 0) List.append($out, $cur) else $out
	}

	# A polygon's rings grouped: a ring of positive area (clockwise with y
	# down) starts a polygon, and each negative ring after it is one of its
	# holes. A ring of no area adds nothing.
	polygons : List(List(Earcut.P)) -> List({ outline : List(Earcut.P), holes : List(List(Earcut.P)) })
	polygons = |rings| {
		folded = List.fold(
			rings,
			{ done: [], cur: Err(NoOutline) },
			|acc, r| {
				a = Earcut.area2(r)
				if a > 0 {
					{
						done: match acc.cur {
							Ok(p) => List.append(acc.done, p)
							Err(_) => acc.done
						},
						cur: Ok({ outline: r, holes: [] }),
					}
				} else if a < 0 {
					match acc.cur {
						Ok(p) => { ..acc, cur: Ok({ ..p, holes: List.append(p.holes, r) }) }
						Err(_) => acc
					}
				} else {
					acc
				}
			},
		)
		match folded.cur {
			Ok(p) => List.append(folded.done, p)
			Err(_) => folded.done
		}
	}

	# ── what the window draws of a tile ────────────────────────────────────
	# Fills, then lines, each in tile units scaled to `extent_units`
	# whatever extent a layer declares. A fill is every triangle of one kind
	# in one list, three points apiece, so a kind draws in one call; a line
	# is one run of one kind.
	Fill : { kind : U8, tris : List(Geo.Pt) }

	Line : { kind : U8, pts : List(Geo.Pt) }

	Tile : { fills : List(Fill), lines : List(Line) }

	empty : Tile
	empty = { fills: [], lines: [] }

	extent_units : F32
	extent_units = 4096.0

	# the fills in drawing order, bottom first: parks, then water over them
	fill_kinds : List(Str)
	fill_kinds = ["park", "water"]

	park_fill : U8
	park_fill = 0

	water_fill : U8
	water_fill = 1

	# the line kinds, coded in drawing order as the base map's ways are
	# (Db.way_kinds, which Map holds equal to this list)
	line_kinds : List(Str)
	line_kinds = ["water", "street", "cycleway", "arterial", "motorway"]

	# A polygon feature's fill: any water but a swimming pool; parks and
	# nature reserves; and the green land cover, grass (which carries the
	# city parks) and wood, but for private gardens, which speckle every
	# block of houses at street zoom.
	fill_of : Str, Str, Str -> Try(U8, [NotDrawn])
	fill_of = |layer_name, class, subclass|
		if layer_name == "water" and class != "swimming_pool" {
			Ok(water_fill)
		} else if layer_name == "park" or (layer_name == "landuse" and class == "park") {
			Ok(park_fill)
		} else if layer_name == "landcover" and (class == "grass" or class == "wood") and subclass != "garden" {
			Ok(park_fill)
		} else {
			Err(NotDrawn)
		}

	# A line feature's kind, by the classes the street map has always drawn:
	# rivers, canals and streams; motorways and trunk roads; primary and
	# secondary roads as arterials; tertiary and minor roads as streets; and
	# paths that are cycleways.
	line_of : Str, Str, Str -> Try(U8, [NotDrawn])
	line_of = |layer_name, class, subclass|
		if layer_name == "waterway" {
			if (class == "river" or class == "canal" or class == "stream") Ok(0) else Err(NotDrawn)
		} else if layer_name == "transportation" {
			if class == "motorway" or class == "trunk" {
				Ok(4)
			} else if class == "primary" or class == "secondary" {
				Ok(3)
			} else if class == "tertiary" or class == "minor" {
				Ok(1)
			} else if class == "path" and subclass == "cycleway" {
				Ok(2)
			} else {
				Err(NotDrawn)
			}
		} else {
			Err(NotDrawn)
		}

	drawn_layers : List(Str)
	drawn_layers = ["water", "waterway", "park", "landcover", "landuse", "transportation"]

	to_pt : Earcut.P, F32 -> Geo.Pt
	to_pt = |p, s| { x: I64.to_f32(p.x) * s, y: I64.to_f32(p.y) * s }

	# The tile as the window draws it. A layer the window does not draw is
	# never decoded, and a tile that is not a well-formed vector tile is
	# refused whole rather than drawn in part. Each fill's triangles and the
	# lines are gathered into lists that only grow at their end; the lines
	# are then put in kind order, each kind keeping the order the tile gave.
	drawable : List(U8) -> Try(Tile, [Malformed])
	drawable = |bytes| {
		lfs = layer_fields(bytes)?
		wanted = List.keep_if(lfs, |lf| List.contains(drawn_layers, lf.name))
		layers = List.map_try(wanted, |lf| layer(bytes, lf.field))?
		var $park = []
		var $water = []
		var $lines = []
		for l in layers {
			s = if (l.extent == 0) 1.0 else extent_units / U64.to_f32(l.extent)
			for ft in l.features {
				if ft.kind == 3 {
					match fill_of(l.name, tag(l, ft, "class"), tag(l, ft, "subclass")) {
						Ok(k) => {
							for p in polygons(parts(ft.geometry)) {
								pts = List.map(Earcut.triangulate(p.outline, p.holes), |q| to_pt(q, s))
								if k == water_fill {
									$water = List.concat($water, pts)
								} else {
									$park = List.concat($park, pts)
								}
							}
						}
						Err(_) => {}
					}
				} else if ft.kind == 2 {
					match line_of(l.name, tag(l, ft, "class"), tag(l, ft, "subclass")) {
						Ok(k) => {
							for r in parts(ft.geometry) {
								if List.len(r) >= 2 {
									$lines = List.append($lines, { kind: k, pts: List.map(r, |q| to_pt(q, s)) })
								}
							}
						}
						Err(_) => {}
					}
				}
			}
		}
		fills = List.keep_if([{ kind: park_fill, tris: $park }, { kind: water_fill, tris: $water }], |f| !(List.is_empty(f.tris)))
		lines = List.join(List.map_with_index(line_kinds, |_, i| List.keep_if($lines, |ln| U8.to_u64(ln.kind) == i)))
		Ok({ fills, lines })
	}
}

# A real tile: OpenFreeMap's z14/4206/6088, open water off Chicago's
# lakefront, 244 bytes. Its park layer holds one label point (a nature
# reserve's), and its water layer one lake polygon covering the tile and
# its 64-unit buffer.
lake_tile : List(U8)
lake_tile = [0x1a, 0x96, 0x01, 0x0a, 0x04, 0x70, 0x61, 0x72, 0x6b, 0x12, 0x1e, 0x08, 0xf3, 0xd2, 0xa1, 0x19, 0x12, 0x0e, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x01, 0x04, 0x02, 0x05, 0x00, 0x06, 0x00, 0x18, 0x01, 0x22, 0x05, 0x09, 0xa3, 0x3a, 0x92, 0x19, 0x1a, 0x08, 0x6e, 0x61, 0x6d, 0x65, 0x5f, 0x69, 0x6e, 0x74, 0x1a, 0x07, 0x6e, 0x61, 0x6d, 0x65, 0x5f, 0x64, 0x65, 0x1a, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x1a, 0x04, 0x72, 0x61, 0x6e, 0x6b, 0x1a, 0x05, 0x63, 0x6c, 0x61, 0x73, 0x73, 0x1a, 0x0a, 0x6e, 0x61, 0x6d, 0x65, 0x3a, 0x6c, 0x61, 0x74, 0x69, 0x6e, 0x1a, 0x07, 0x6e, 0x61, 0x6d, 0x65, 0x5f, 0x65, 0x6e, 0x22, 0x18, 0x0a, 0x16, 0x4a, 0x61, 0x72, 0x64, 0x69, 0x6e, 0x65, 0x20, 0x42, 0x69, 0x72, 0x64, 0x20, 0x53, 0x61, 0x6e, 0x63, 0x74, 0x75, 0x61, 0x72, 0x79, 0x22, 0x02, 0x30, 0x02, 0x22, 0x10, 0x0a, 0x0e, 0x6e, 0x61, 0x74, 0x75, 0x72, 0x65, 0x5f, 0x72, 0x65, 0x73, 0x65, 0x72, 0x76, 0x65, 0x28, 0x80, 0x20, 0x78, 0x02, 0x1a, 0x59, 0x0a, 0x05, 0x77, 0x61, 0x74, 0x65, 0x72, 0x12, 0x1f, 0x08, 0xa5, 0xc8, 0xdf, 0x05, 0x12, 0x06, 0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x18, 0x03, 0x22, 0x0e, 0x09, 0x7f, 0x7f, 0x1a, 0x80, 0x42, 0x00, 0x00, 0x80, 0x42, 0xff, 0x41, 0x00, 0x0f, 0x1a, 0x0c, 0x69, 0x6e, 0x74, 0x65, 0x72, 0x6d, 0x69, 0x74, 0x74, 0x65, 0x6e, 0x74, 0x1a, 0x05, 0x63, 0x6c, 0x61, 0x73, 0x73, 0x1a, 0x02, 0x69, 0x64, 0x22, 0x02, 0x30, 0x00, 0x22, 0x06, 0x0a, 0x04, 0x6c, 0x61, 0x6b, 0x65, 0x22, 0x05, 0x30, 0xba, 0x8e, 0x93, 0x01, 0x28, 0x80, 0x20, 0x78, 0x02]

# the real tile's two layers, in the order it stores them
expect (Mvt.layer_fields(lake_tile) ?? []).map(|l| l.name) == ["park", "water"]

# its water layer: extent 4096, one polygon whose class is lake, a square
# from (-64, -64) to (4160, 4160) ringed clockwise with y down
expect {
	lfs = Mvt.layer_fields(lake_tile) ?? []
	match List.find_first(lfs, |l| l.name == "water") {
		Err(_) => Bool.False
		Ok(lf) =>
			match Mvt.layer(lake_tile, lf.field) {
				Err(_) => Bool.False
				Ok(l) => {
					ft = List.first(l.features) ?? { kind: 0, tags: [], geometry: [] }
					l.extent == 4096 and List.len(l.features) == 1 and ft.kind == 3 and Mvt.tag(l, ft, "class") == "lake" and Mvt.tag(l, ft, "subclass") == ""
						and Mvt.parts(ft.geometry) == [[{ x: -64, y: -64 }, { x: 4160, y: -64 }, { x: 4160, y: 4160 }, { x: -64, y: 4160 }]]
				}
			}
	}
}

# the park layer's one feature is a point, its class read through the
# value table
expect {
	lfs = Mvt.layer_fields(lake_tile) ?? []
	match List.find_first(lfs, |l| l.name == "park") {
		Err(_) => Bool.False
		Ok(lf) =>
			match Mvt.layer(lake_tile, lf.field) {
				Err(_) => Bool.False
				Ok(l) => {
					ft = List.first(l.features) ?? { kind: 0, tags: [], geometry: [] }
					ft.kind == 1 and Mvt.tag(l, ft, "class") == "nature_reserve" and Mvt.tag(l, ft, "name") == "Jardine Bird Sanctuary" and List.len(Mvt.parts(ft.geometry)) == 1
				}
			}
	}
}

# drawn, the real tile is one water fill of two triangles covering its
# square and no line; the label point draws nothing
expect {
	match Mvt.drawable(lake_tile) {
		Err(_) => Bool.False
		Ok(t) => List.map(t.fills, |f| { kind: f.kind, n: List.len(f.tris) }) == [{ kind: Mvt.water_fill, n: 6 }] and List.is_empty(t.lines)
	}
}

# a cut tile is refused rather than drawn in part
expect Mvt.drawable(List.take_first(lake_tile, 200)) == Err(Malformed)

# MoveTo, LineTo and ClosePath: two rings, the cursor carried from the first
# to the second, and a line's MoveTo starting a second run
expect {
	# MoveTo(1) +2,+2; LineTo(2) +8,0 0,+8; ClosePath; MoveTo(1) -1,-1;
	# LineTo(2) -4,0 0,-4; ClosePath
	cmds = [9, 4, 4, 18, 16, 0, 0, 16, 15, 9, 1, 1, 18, 7, 0, 0, 7, 15]
	Mvt.parts(cmds) == [[{ x: 2, y: 2 }, { x: 10, y: 2 }, { x: 10, y: 10 }], [{ x: 9, y: 9 }, { x: 5, y: 9 }, { x: 5, y: 5 }]]
}

# rings group into polygons by their sign: an outline, its hole, then a
# second outline; a ring with no area is dropped
expect {
	outer = [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }]
	hole = [{ x: 2, y: 2 }, { x: 2, y: 4 }, { x: 4, y: 4 }, { x: 4, y: 2 }]
	flat = [{ x: 0, y: 0 }, { x: 5, y: 0 }, { x: 9, y: 0 }]
	second = [{ x: 20, y: 0 }, { x: 30, y: 0 }, { x: 30, y: 10 }]
	Mvt.polygons([outer, hole, flat, second]) == [{ outline: outer, holes: [hole] }, { outline: second, holes: [] }]
}

# the classes drawn: water but pools, parks, green cover but gardens, and the
# street map's road classes; anything else is not drawn
expect Mvt.fill_of("water", "river", "") == Ok(Mvt.water_fill) and Mvt.fill_of("water", "swimming_pool", "") == Err(NotDrawn) and Mvt.fill_of("park", "national_park", "") == Ok(Mvt.park_fill) and Mvt.fill_of("landcover", "grass", "park") == Ok(Mvt.park_fill) and Mvt.fill_of("landcover", "grass", "garden") == Err(NotDrawn) and Mvt.fill_of("landuse", "park", "") == Ok(Mvt.park_fill) and Mvt.fill_of("landuse", "residential", "") == Err(NotDrawn) and Mvt.fill_of("landcover", "farmland", "") == Err(NotDrawn) and Mvt.fill_of("building", "", "") == Err(NotDrawn)
expect Mvt.line_of("transportation", "trunk", "") == Ok(4) and Mvt.line_of("transportation", "secondary", "") == Ok(3) and Mvt.line_of("transportation", "minor", "") == Ok(1) and Mvt.line_of("transportation", "path", "cycleway") == Ok(2) and Mvt.line_of("transportation", "path", "footway") == Err(NotDrawn) and Mvt.line_of("transportation", "service", "") == Err(NotDrawn) and Mvt.line_of("waterway", "stream", "") == Ok(0) and Mvt.line_of("waterway", "ditch", "") == Err(NotDrawn)
