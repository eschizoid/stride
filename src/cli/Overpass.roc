# ── the base map's data source: OpenStreetMap through the Overpass API (pure) ──
#
# The map view draws roads and water around the athlete's routes. The area is
# a set of blocks, each 0.1 degrees of latitude by 0.1 of longitude, named by
# the integer tenths of its south-west corner, so a point's block is the floor
# of its coordinates times 10. The area holds every block a stored route
# passes through and every block next to one, so routes with at most two
# empty blocks between them join into one map rather than islands.
Overpass :: [].{

	Block : { lat : I64, lng : I64 }

	# one map line as stored: `points` is a JSON array [lat0,lng0,lat1,lng1,...]
	Way : { id : I64, kind : Str, points : Str }

	# the request for one block: every road class the map draws, cycleways,
	# and the water lines (rivers, canals, streams, shorelines and the outline
	# of a lake or pond). `out tags geom` sends each way's tags and coordinates
	# inline, so no node lookup is needed.
	query : Block -> Str
	query = |b| {
		box = bbox(b)
		"[out:json][timeout:180];(way[\"highway\"~\"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|cycleway)(_link)?$\"](${box});way[\"waterway\"~\"^(river|canal|stream)$\"](${box});way[\"natural\"~\"^(water|coastline)$\"](${box}););out tags geom qt;"
	}

	# what an HTTP status from Overpass means for the run. The public server
	# answers 429 when a client has used its slots, 502 or 503 when its own
	# queue is full, and 504 when a query waited too long for a slot; each is
	# a busy server, worth asking again later.
	answer : U16 -> [Answered, Busy, Failed]
	answer = |status|
		if (status < 300)
			Answered
		else if (status == 429 or status == 502 or status == 503 or status == 504)
			Busy
		else
			Failed

	# the public Overpass servers, asked in this order: the main instance, then
	# two mirrors serving the same OpenStreetMap data
	servers : List(Str)
	servers = ["https://overpass-api.de", "https://overpass.private.coffee", "https://overpass.kumi.systems"]

	# rounds of busy answers asked again before the run stops as busy; a round
	# asks every server once
	busy_retries : U64
	busy_retries = 2

	# the k-th try of a block (k from 0) asks server k mod n, in round k / n.
	# A try that starts a new round waits `backoff` per round on top of the
	# one-second spacing between requests; a block's first try waits only the
	# spacing, and none before the run's first request.
	try_plan : U64, U64, U64, Bool -> { server : U64, wait_ms : U64 }
	try_plan = |k, n, backoff, first_request| {
		round = k // n
		spacing = if (first_request and k == 0) 0 else 1000
		extra = if (k > 0 and k % n == 0) backoff * round else 0
		{ server: k % n, wait_ms: spacing + extra }
	}

	# tries a block gets before the run stops as busy
	max_tries : U64 -> U64
	max_tries = |n| n * (busy_retries + 1)

	# Overpass's bounding box order: south, west, north, east
	bbox : Block -> Str
	bbox = |b| "${deg(b.lat)},${deg(b.lng)},${deg(b.lat + 1)},${deg(b.lng + 1)}"

	# tenths of a degree as a decimal: 418 is 41.8, -877 is -87.7
	deg : I64 -> Str
	deg = |t| {
		a = if (t < 0) -t else t
		sign = if (t < 0) "-" else ""
		"${sign}${(a // 10).to_str()}.${(a % 10).to_str()}"
	}

	# a form value as `application/x-www-form-urlencoded` carries it: every byte
	# outside the unreserved set becomes %XX
	form_escape : Str -> Str
	form_escape = |s| {
		hex = Str.to_utf8("0123456789ABCDEF")
		bytes = List.fold(
			Str.to_utf8(s),
			[],
			|acc, b|
				if (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '-' or b == '_' or b == '.' or b == '~' {
					List.append(acc, b)
				} else {
					hi = List.get(hex, (b // 16).to_u64()) ?? '0'
					lo = List.get(hex, (b % 16).to_u64()) ?? '0'
					List.concat(acc, ['%', hi, lo])
				},
		)
		Str.from_utf8_lossy(bytes)
	}

	Tags : { highway : Try(Str, [Missing]), waterway : Try(Str, [Missing]), natural : Try(Str, [Missing]) }
	Element : { id : I64, tags : Try(Tags, [Missing]), geometry : Try(List({ lat : F64, lon : F64 }), [Missing]) }
	Answer : { elements : List(Element), remark : Try(Str, [Missing]) }

	# the ways in an Overpass answer, each with the kind the map draws it as. A
	# way with a tag the map does not draw, or fewer than two coordinates, is
	# left out. Any answer carrying a `remark` is Incomplete, never a block's
	# ways: Overpass reports a query that ran out of time or memory as a 200
	# with a remark and the elements it had gathered so far. Unreadable when
	# the text is not an Overpass JSON answer.
	decode_ways : Str -> Try(List(Way), [Unreadable, Incomplete(Str)])
	decode_ways = |text| {
		decoded : Try(Answer, [InvalidJson(Str), MissingRequiredField(Str)])
		decoded = Json.parse(text)
		match decoded {
			Err(_) => Err(Unreadable)
			Ok(a) =>
				match a.remark {
					Ok(r) => Err(Incomplete(r))
					Err(_) =>
						Ok(
							List.keep_oks(
								a.elements,
								|e|
									match (e.tags, e.geometry) {
										(Ok(t), Ok(g)) if List.len(g) >= 2 =>
											kind_of(t).map_ok(|k| { id: e.id, kind: k, points: points_json(g) })
										_ => Err(NotDrawn)
									},
							),
						)
				}
		}
	}

	# the readable part of an error page: Overpass answers a refused query
	# with an HTML page whose message follows a long preamble, so the tags
	# go and the text from the first "Error" on is kept
	error_text : Str -> Str
	error_text = |body| {
		bytes = Str.to_utf8(body)
		stripped = List.fold(
			bytes,
			{ out: [], in_tag: Bool.False, space: Bool.True },
			|st, b|
				if b == '<' {
					{ ..st, in_tag: Bool.True }
				} else if b == '>' {
					{ ..st, in_tag: Bool.False }
				} else if st.in_tag {
					st
				} else if b == ' ' or b == '\n' or b == '\r' or b == '\t' {
					if (st.space) st else { out: List.append(st.out, ' '), in_tag: Bool.False, space: Bool.True }
				} else {
					{ out: List.append(st.out, b), in_tag: Bool.False, space: Bool.False }
				},
		)
		text = Str.trim(Str.from_utf8_lossy(stripped.out))
		(Str.split_first(text, "Error")).map_ok(|p| "Error${p.after}").ok_or(text)
	}

	# the map's line classes, each road class with its ramps: 'motorway'
	# (motorways and trunk roads), 'arterial' (primary and secondary roads),
	# 'street' (tertiary, unclassified, residential and living streets),
	# 'cycleway', and 'water'
	kind_of : Tags -> Try(Str, [NotDrawn])
	kind_of = |t| {
		road = match t.highway {
			Ok(h) => Ok(Str.replace_each(h, "_link", ""))
			Err(_) => Err(NotDrawn)
		}
		match road {
			Ok("motorway") | Ok("trunk") => Ok("motorway")
			Ok("primary") | Ok("secondary") => Ok("arterial")
			Ok("tertiary") | Ok("unclassified") | Ok("residential") | Ok("living_street") => Ok("street")
			Ok("cycleway") => Ok("cycleway")
			_ =>
				match (t.waterway, t.natural) {
					(Ok("river"), _) | (Ok("canal"), _) | (Ok("stream"), _) => Ok("water")
					(_, Ok("water")) | (_, Ok("coastline")) => Ok("water")
					_ => Err(NotDrawn)
				}
		}
	}

	points_json : List({ lat : F64, lon : F64 }) -> Str
	points_json = |g| "[${Str.join_with(List.map(g, |p| "${p.lat.to_str()},${p.lon.to_str()}"), ",")}]"

	# the human line for a `basemap` run; `area` says whether any block has
	# been fetched or is owed, which tells a database with no routes from one
	# whose routes lie where the map has no roads or water
	summary_line : { blocks_fetched : I64, blocks_pending : I64, ways_stored : I64, map_ways : I64, stopped : Str }, Bool -> Str
	summary_line = |p, area|
		if p.stopped == "overpass_busy" {
			"fetched map data for ${p.blocks_fetched.to_str()} blocks (${p.ways_stored.to_str()} roads and water lines) — the Overpass server is busy, ${p.blocks_pending.to_str()} blocks to go: run `stride basemap` again in a few minutes"
		} else if p.blocks_fetched > 0 {
			"fetched map data for ${p.blocks_fetched.to_str()} blocks — ${p.ways_stored.to_str()} roads and water lines stored, ${p.map_ways.to_str()} in the map"
		} else if p.map_ways > 0 {
			"the map already covers every stored route — ${p.map_ways.to_str()} roads and water lines"
		} else if area {
			"the map's area holds no roads or water that OpenStreetMap knows of"
		} else {
			"no GPS routes to map yet — `stride sync` stores them, then run `stride basemap`"
		}
}

expect Overpass.deg(418) == "41.8"
expect Overpass.deg(-877) == "-87.7"
expect Overpass.deg(-5) == "-0.5"
expect Overpass.deg(7) == "0.7"
expect Overpass.deg(0) == "0.0"
expect Overpass.deg(-880) == "-88.0"
# a block's box runs from its own corner to its neighbours', so blocks tile
# the plane with no gap and no overlap at either sign
expect Overpass.bbox({ lat: 418, lng: -877 }) == "41.8,-87.7,41.9,-87.6"
expect Overpass.bbox({ lat: -1, lng: -1 }) == "-0.1,-0.1,0.0,0.0"
expect Str.contains(Overpass.query({ lat: 418, lng: -877 }), "way[\"waterway\"~\"^(river|canal|stream)$\"](41.8,-87.7,41.9,-87.6);")
expect Str.starts_with(Overpass.query({ lat: 1, lng: 2 }), "[out:json]")
expect Str.ends_with(Overpass.query({ lat: 1, lng: 2 }), ";);out tags geom qt;")
expect Overpass.form_escape("way[\"a\"~\"^b$\"](1.5,-2);") == "way%5B%22a%22~%22%5Eb%24%22%5D%281.5%2C-2%29%3B"
expect Overpass.form_escape("a b=c&d") == "a%20b%3Dc%26d"

# Overpass's answer: tags and geometry per way, unknown keys ignored
overpass_sample = "{\"version\":0.6,\"elements\":[{\"type\":\"way\",\"id\":11,\"bounds\":{\"minlat\":41.8},\"nodes\":[1,2],\"geometry\":[{\"lat\":41.88,\"lon\":-87.63},{\"lat\":41.89,\"lon\":-87.64}],\"tags\":{\"highway\":\"secondary_link\",\"name\":\"N Clark St\"}},{\"type\":\"way\",\"id\":12,\"geometry\":[{\"lat\":41.9,\"lon\":-87.6},{\"lat\":41.91,\"lon\":-87.61}],\"tags\":{\"natural\":\"coastline\"}},{\"type\":\"way\",\"id\":13,\"geometry\":[{\"lat\":41.9,\"lon\":-87.6},{\"lat\":41.91,\"lon\":-87.61}],\"tags\":{\"highway\":\"footway\"}},{\"type\":\"way\",\"id\":14,\"geometry\":[{\"lat\":41.9,\"lon\":-87.6}],\"tags\":{\"highway\":\"residential\"}}]}"
expect Overpass.decode_ways(overpass_sample) == Ok([{ id: 11, kind: "arterial", points: "[41.88,-87.63,41.89,-87.64]" }, { id: 12, kind: "water", points: "[41.9,-87.6,41.91,-87.61]" }])
expect Overpass.decode_ways("{\"elements\":[]}") == Ok([])
expect Overpass.decode_ways("<html>busy</html>") == Err(Unreadable)
expect Overpass.decode_ways("{\"remark\":\"runtime error\"}") == Err(Unreadable)

no_tags = { highway: Err(Missing), waterway: Err(Missing), natural: Err(Missing) }
expect Overpass.kind_of({ ..no_tags, highway: Ok("motorway_link") }) == Ok("motorway")
expect Overpass.kind_of({ ..no_tags, highway: Ok("trunk") }) == Ok("motorway")
expect Overpass.kind_of({ ..no_tags, highway: Ok("primary") }) == Ok("arterial")
expect Overpass.kind_of({ ..no_tags, highway: Ok("living_street") }) == Ok("street")
expect Overpass.kind_of({ ..no_tags, highway: Ok("cycleway") }) == Ok("cycleway")
expect Overpass.kind_of({ ..no_tags, waterway: Ok("canal") }) == Ok("water")
expect Overpass.kind_of({ ..no_tags, natural: Ok("water") }) == Ok("water")
expect Overpass.kind_of({ ..no_tags, highway: Ok("footway") }) == Err(NotDrawn)
expect Overpass.kind_of({ ..no_tags, natural: Ok("wood") }) == Err(NotDrawn)
expect Overpass.kind_of(no_tags) == Err(NotDrawn)

line = { blocks_fetched: 0, blocks_pending: 0, ways_stored: 0, map_ways: 0, stopped: "complete" }
expect Overpass.summary_line(line, Bool.False) == "no GPS routes to map yet — `stride sync` stores them, then run `stride basemap`"
expect Overpass.summary_line({ ..line, map_ways: 40 }, Bool.True) == "the map already covers every stored route — 40 roads and water lines"
expect Overpass.summary_line({ ..line, blocks_fetched: 3, ways_stored: 12, map_ways: 52 }, Bool.True) == "fetched map data for 3 blocks — 12 roads and water lines stored, 52 in the map"
expect Overpass.summary_line({ ..line, blocks_fetched: 9, blocks_pending: 20, ways_stored: 9, map_ways: 9, stopped: "overpass_busy" }, Bool.True) == "fetched map data for 9 blocks (9 roads and water lines) — the Overpass server is busy, 20 blocks to go: run `stride basemap` again in a few minutes"

expect Overpass.answer(200) == Answered
expect Overpass.answer(429) == Busy
expect Overpass.answer(502) == Busy
expect Overpass.answer(503) == Busy
expect Overpass.answer(504) == Busy
expect Overpass.answer(400) == Failed
expect Overpass.answer(500) == Failed

# a block walks the servers in order, and only a new round adds the backoff
expect Overpass.try_plan(0, 3, 15000, True) == { server: 0, wait_ms: 0 }
expect Overpass.try_plan(0, 3, 15000, False) == { server: 0, wait_ms: 1000 }
expect Overpass.try_plan(1, 3, 15000, False) == { server: 1, wait_ms: 1000 }
expect Overpass.try_plan(2, 3, 15000, False) == { server: 2, wait_ms: 1000 }
expect Overpass.try_plan(3, 3, 15000, False) == { server: 0, wait_ms: 16000 }
expect Overpass.try_plan(7, 3, 15000, False) == { server: 1, wait_ms: 1000 }
expect Overpass.try_plan(6, 3, 15000, False) == { server: 0, wait_ms: 31000 }
expect Overpass.try_plan(1, 1, 15000, True) == { server: 0, wait_ms: 16000 }
expect Overpass.max_tries(3) == 9
expect Overpass.max_tries(1) == 3
expect Overpass.summary_line(line, Bool.True) == "the map's area holds no roads or water that OpenStreetMap knows of"

# a query that ran out of time answers 200 with a remark and whatever it had
# gathered; that is never a block's ways
expect Overpass.decode_ways("{\"elements\":[],\"remark\":\"runtime error: Query timed out in \\\"query\\\" at line 1 after 181 seconds.\"}") == Err(Incomplete("runtime error: Query timed out in \"query\" at line 1 after 181 seconds."))
expect Overpass.decode_ways("{\"elements\":[{\"type\":\"way\",\"id\":11,\"geometry\":[{\"lat\":41.88,\"lon\":-87.63},{\"lat\":41.89,\"lon\":-87.64}],\"tags\":{\"highway\":\"primary\"}}],\"remark\":\"runtime error: out of memory\"}") == Err(Incomplete("runtime error: out of memory"))

expect Overpass.error_text("<?xml version=\"1.0\"?>\n<!DOCTYPE html>\n<html><head><title>OSM3S Response</title></head>\n<body>\n<p>The data included in this document is from www.openstreetmap.org.</p>\n<p><strong style=\"color:#FF0000\">Error</strong>: line 1: parse error: Unknown type \"wey\" </p>\n</body></html>") == "Error: line 1: parse error: Unknown type \"wey\""
expect Overpass.error_text("plain refusal") == "plain refusal"
