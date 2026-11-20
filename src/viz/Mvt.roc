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
	# rivers and roads as lines, and the names of places and streets.
	# Everything else a tile carries (buildings, boundaries, points of
	# interest) is skipped without being decoded.

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

	# One layer, decoded. A whole number (an int, uint or zigzagged sint
	# value) is kept as its decimal text, so a place's rank reads like any
	# other tag; any other value that is not text (a float or a flag) is
	# kept as "".
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
					Ok(vs) => {
						$values = List.append($values, value_text(bytes, vs))
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

	# a value message's text: its string (field 1), else its whole number in
	# decimal: an int (4) read as a signed 64-bit two's complement, so a
	# negative one, which a varint stores in ten bytes, reads with its sign;
	# a uint (5) as unsigned; and a sint (6) unzigzagged; else ""
	value_text : List(U8), List(Pbf.Field) -> Str
	value_text = |bytes, vs|
		match List.find_first(vs, |v| v.num == 1 and v.wire == 2) {
			Ok(v) => Pbf.text(bytes, v)
			Err(_) =>
				match List.find_first(vs, |v| v.wire == 0 and (v.num == 4 or v.num == 5 or v.num == 6)) {
					Ok(v) =>
						if v.num == 6 {
							I64.to_str(Pbf.zigzag(v.value))
						} else if v.num == 4 {
							I64.to_str(U64.to_i64_wrap(v.value))
						} else {
							U64.to_str(v.value)
						}
					Err(_) => ""
				}
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
	# Fills, then lines, then names, each in tile units scaled to
	# `extent_units` whatever extent a layer declares. A fill is every
	# triangle of one kind in one list, three points apiece, so a kind draws
	# in one call; a line is one run of one kind. A name is a place's point
	# or one run of a named street, with its kind (by name_kinds' codes),
	# the place's rank (OpenMapTiles ranks the larger places of a class
	# first, from 1; 0 for a street, which has none) and its text.
	Fill : { kind : U8, tris : List(Geo.Pt) }

	Line : { kind : U8, pts : List(Geo.Pt) }

	Name : { kind : U8, rank : U64, text : Str, pts : List(Geo.Pt) }

	Tile : { fills : List(Fill), lines : List(Line), names : List(Name) }

	empty : Tile
	empty = { fills: [], lines: [], names: [] }

	extent_units : F32
	extent_units = 4096.0

	# the fills in drawing order, bottom first: parks, then water over them
	fill_kinds : List(Str)
	fill_kinds = ["park", "water"]

	park_fill : U8
	park_fill = 0

	water_fill : U8
	water_fill = 1

	# the line kinds, each coded by its place here, in the order the map
	# draws them, bottom first (Map.style draws each code)
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

	# A line feature's kind, by the classes the street map draws: rivers,
	# canals and streams; motorways and trunk roads; primary and secondary
	# roads as arterials; tertiary and minor roads as streets; and paths that
	# are cycleways.
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

	# The name kinds, each coded by its place here: the places, larger
	# first, then the streets, major first. The first `street_kind` codes
	# are places.
	name_kinds : List(Str)
	name_kinds = ["city", "town", "village", "suburb", "neighbourhood", "motorway", "arterial", "street", "minor"]

	street_kind : U8
	street_kind = 5

	is_street : U8 -> Bool
	is_street = |kind| kind >= street_kind

	# A place point's kind by its class: cities, towns, villages, suburbs,
	# and the neighbourhoods and quarters inside them; hamlets, islands,
	# states and the rest are not named.
	place_of : Str -> Try(U8, [NotNamed])
	place_of = |class|
		if (class == "city") Ok(0)
		else if (class == "town") Ok(1)
		else if (class == "village") Ok(2)
		else if (class == "suburb") Ok(3)
		else if (class == "neighbourhood" or class == "quarter") Ok(4)
		else Err(NotNamed)

	# A named street's kind by its class, among the road classes line_of
	# draws: motorways and trunk roads; primary and secondary roads as
	# arterials; tertiary roads; and minor roads. Service roads, tracks,
	# paths and railways are not named.
	street_of : Str -> Try(U8, [NotNamed])
	street_of = |class|
		if (class == "motorway" or class == "trunk") Ok(5)
		else if (class == "primary" or class == "secondary") Ok(6)
		else if (class == "tertiary") Ok(7)
		else if (class == "minor") Ok(8)
		else Err(NotNamed)

	# A name's text: the first of its name tags that is printable ASCII,
	# the range the window's fonts carry glyphs for, so a name the fonts
	# cannot draw is never drawn as fallback boxes. OpenMapTiles' `name` is
	# the local name, `name:latin` and `name_en` its Latin and English
	# forms, and `name_int` its international one.
	name_of : Layer, Feature -> Str
	name_of = |l, ft| {
		found = List.find_first(List.map(["name", "name:latin", "name_en", "name_int"], |k| tag(l, ft, k)), printable)
		found ?? ""
	}

	printable : Str -> Bool
	printable = |s| !(Str.is_empty(s)) and List.all(Str.to_utf8(s), |b| b >= 32 and b < 127)

	drawn_layers : List(Str)
	drawn_layers = ["water", "waterway", "park", "landcover", "landuse", "transportation", "place", "transportation_name"]

	to_pt : Earcut.P, F32 -> Geo.Pt
	to_pt = |p, s| { x: I64.to_f32(p.x) * s, y: I64.to_f32(p.y) * s }

	# The tile as the window draws it. A layer the window does not draw is
	# never decoded, and a tile that is not a well-formed vector tile is
	# refused whole rather than drawn in part. Each fill's triangles, the
	# lines and the names are gathered into lists that only grow at their
	# end; the lines are then put in kind order, each kind keeping the order
	# the tile gave. A place is named at its point, the first a feature
	# gives, and a street along each run of two points or more; a feature
	# with no printable name is skipped.
	drawable : List(U8) -> Try(Tile, [Malformed])
	drawable = |bytes| {
		lfs = layer_fields(bytes)?
		wanted = List.keep_if(lfs, |lf| List.contains(drawn_layers, lf.name))
		layers = List.map_try(wanted, |lf| layer(bytes, lf.field))?
		var $park = []
		var $water = []
		var $lines = []
		var $names = []
		for l in layers {
			s = if (l.extent == 0) 1.0 else extent_units / U64.to_f32(l.extent)
			for ft in l.features {
				if l.name == "place" or l.name == "transportation_name" {
					text = name_of(l, ft)
					coded = if (l.name == "place") place_of(tag(l, ft, "class")) else street_of(tag(l, ft, "class"))
					match coded {
						Ok(k) if text != "" =>
							if l.name == "place" and ft.kind == 1 {
								match List.first(List.join(parts(ft.geometry))) {
									Ok(p) => {
										$names = List.append($names, { kind: k, rank: U64.from_str(tag(l, ft, "rank")) ?? 0, text, pts: [to_pt(p, s)] })
									}
									Err(_) => {}
								}
							} else if l.name == "transportation_name" and ft.kind == 2 {
								for r in parts(ft.geometry) {
									if List.len(r) >= 2 {
										$names = List.append($names, { kind: k, rank: 0, text, pts: List.map(r, |q| to_pt(q, s)) })
									}
								}
							}
						_ => {}
					}
				} else if ft.kind == 3 {
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
		Ok({ fills, lines, names: $names })
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

# ── a tile written out field by field, for the name layers' expects ──────
enc_varint : U64 -> List(U8)
enc_varint = |n| if (n < 128) [U64.to_u8_wrap(n)] else List.concat([U64.to_u8_wrap(n % 128 + 128)], enc_varint(n // 128))

enc_len : U64, List(U8) -> List(U8)
enc_len = |num, payload| List.join([enc_varint(num * 8 + 2), enc_varint(List.len(payload)), payload])

enc_num : U64, U64 -> List(U8)
enc_num = |num, v| List.concat(enc_varint(num * 8), enc_varint(v))

# a layer of extent 4096 from its keys, its values (each already a value
# message) and its features, each a geometry type, packed tags and packed
# geometry commands
enc_layer : Str, List(Str), List(List(U8)), List({ kind : U64, tags : List(U64), cmds : List(U64) }) -> List(U8)
enc_layer = |name, keys, values, features|
	enc_len(
		3,
		List.join([
			enc_len(1, Str.to_utf8(name)),
			List.join(List.map(features, |f| enc_len(2, List.join([enc_len(2, List.join(List.map(f.tags, enc_varint))), enc_num(3, f.kind), enc_len(4, List.join(List.map(f.cmds, enc_varint)))])))),
			List.join(List.map(keys, |k| enc_len(3, Str.to_utf8(k)))),
			List.join(List.map(values, |v| enc_len(4, v))),
			enc_num(5, 4096),
		]),
	)

str_value : Str -> List(U8)
str_value = |s| enc_len(1, Str.to_utf8(s))

# a sint value, zigzagged as OpenMapTiles' tiles store a place's rank
sint_value : U64 -> List(U8)
sint_value = |n| enc_num(6, 2 * n)

# A place layer of a city ranked 1, a neighbourhood with no rank, a hamlet,
# and a town whose local name is not ASCII but whose Latin one is; and a
# street layer of a minor road in one run of three points, and a service
# road.
names_tile : List(U8)
names_tile = List.concat(
	enc_layer(
		"place",
		["name", "class", "rank", "name:latin"],
		[str_value("Chicago"), str_value("city"), sint_value(1), str_value("Pilsen"), str_value("neighbourhood"), str_value("Nowhere"), str_value("hamlet"), str_value("Łódź"), str_value("Lodz"), str_value("town"), sint_value(4)],
		[
			{ kind: 1, tags: [0, 0, 1, 1, 2, 2], cmds: [9, 200, 400] },
			{ kind: 1, tags: [0, 3, 1, 4], cmds: [9, 20, 40] },
			{ kind: 1, tags: [0, 5, 1, 6], cmds: [9, 60, 60] },
			{ kind: 1, tags: [0, 7, 3, 8, 1, 9, 2, 10], cmds: [9, 2, 2] },
		],
	),
	enc_layer(
		"transportation_name",
		["name", "class"],
		[str_value("West 18th Street"), str_value("minor"), str_value("Alley"), str_value("service")],
		[
			{ kind: 2, tags: [0, 0, 1, 1], cmds: [9, 0, 0, 18, 200, 0, 200, 20] },
			{ kind: 2, tags: [0, 2, 1, 3], cmds: [9, 0, 0, 10, 50, 50] },
		],
	),
)

# the name layers decode to one name per named place and street run, the
# hamlet and the service road skipped, a rank read from its sint value, and
# a name the fonts cannot draw replaced by its Latin form
expect {
	match Mvt.drawable(names_tile) {
		Err(_) => Bool.False
		Ok(t) => {
			ints = |pts| List.map(pts, |p| ((F32.round_to_u64_try(p.x)) ?? 9999, (F32.round_to_u64_try(p.y)) ?? 9999))
			List.map(t.names, |n| (n.kind, n.rank, n.text, ints(n.pts))) == [(0, 1, "Chicago", [(100, 200)]), (4, 0, "Pilsen", [(10, 20)]), (1, 4, "Lodz", [(1, 1)]), (8, 0, "West 18th Street", [(0, 0), (100, 0), (200, 10)])]
				and List.is_empty(t.fills) and List.is_empty(t.lines)
		}
	}
}

# a whole-number value reads as its decimal text whichever of the three
# integer fields holds it, a negative int with its sign and the same ten
# bytes as a uint without one, a float as nothing, and a string as itself
expect {
	vt = |bytes| Mvt.value_text(bytes, (Pbf.fields(bytes, 0, List.len(bytes))) ?? [])
	minus_one = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]
	vt([0x20, 0x07]) == "7" and vt([0x28, 0x05]) == "5" and vt([0x30, 0x03]) == "-2" and vt([0x15, 0, 0, 0x80, 0x3f]) == "" and vt(str_value("lake")) == "lake"
		and vt(List.prepend(minus_one, 0x20)) == "-1" and vt(List.prepend(minus_one, 0x28)) == "18446744073709551615"
}

# the classes named: the five place classes, the four street groups, and
# nothing else; a name is printable ASCII or not drawn
expect List.map(["city", "town", "village", "suburb", "neighbourhood", "quarter", "hamlet", "state"], Mvt.place_of) == [Ok(0), Ok(1), Ok(2), Ok(3), Ok(4), Ok(4), Err(NotNamed), Err(NotNamed)]
expect List.map(["motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service", "path", "rail"], Mvt.street_of) == [Ok(5), Ok(5), Ok(6), Ok(6), Ok(7), Ok(8), Err(NotNamed), Err(NotNamed), Err(NotNamed)]
expect Mvt.printable("North Avenue") and !(Mvt.printable("")) and !(Mvt.printable("Łódź")) and !(Mvt.printable("a\tb")) and Mvt.is_street(5) and !(Mvt.is_street(4)) and List.len(Mvt.name_kinds) == 9
