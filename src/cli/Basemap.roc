import Config
import Db
import Output
import Overpass
import Sql
import pf.Env
import pf.Http
import pf.OsStr
import pf.Path
import pf.Sleep
import http.Method
import http.Request
import http.Response

# ── basemap: the map view's roads and water, fetched from Overpass ──────
#
# `stride basemap` asks the Overpass API for the roads and water in every
# 0.1-degree block the stored GPS routes reach (see Overpass) that no earlier
# run fetched, one block per request, and stores the block's ways in map_ways
# and the block in map_blocks in one transaction. A block the main server is
# too busy to answer goes to the mirrors in Overpass.servers, and round after
# round with a longer wait each time; one still refused stops the run with
# the blocks already stored kept, and the next run asks only for the blocks
# still missing.
Basemap :: [].{

	basemap! : {} => Try({}, _)
	basemap! = |{}| {
		path = Db.open_db!({})?
		blocks = pending_blocks!(path)?
		match fetch_blocks!(path, overpass_bases!({}), blocks, { fetched: 0, stored: 0, stopped: "complete" }, 0, 0) {
			Ok(st) =>
				if st.stopped == "overpass_busy" and st.fetched == 0 {
					Output.err_out!("overpass_busy", "every Overpass server was busy and nothing was fetched — run `stride basemap` again in a few minutes")
				} else {
					total = way_count!(path)?
					area = st.fetched > 0 or List.len(blocks) > 0 or block_count!(path)? > 0
					Output.out!(
						{ blocks_fetched: st.fetched, blocks_pending: List.len(blocks).to_i64_wrap() - st.fetched, ways_stored: st.stored, map_ways: total, stopped: st.stopped },
						|p| Overpass.summary_line(p, area),
					)
				}
			Err(OverpassStatus(status, body, fetched)) =>
				Output.err_out!("overpass_error", "the Overpass API returned HTTP ${status.to_str()}: ${clip(Overpass.error_text(body))}${kept(fetched)}")
			Err(OverpassUnreadable(fetched)) =>
				Output.err_out!("overpass_error", "the Overpass API answered with something that is not map data${kept(fetched)}")
			Err(OverpassUnreachable(msg, fetched)) =>
				Output.err_out!("network_unreachable", "could not reach any Overpass server (${clip(msg)}) — check the connection and retry${kept(fetched)}")
			Err(e) => Err(e)
		}
	}

	# what an error leaves behind: blocks fetched before it stay stored
	kept : I64 -> Str
	kept = |fetched|
		if (fetched == 1) " — the block fetched before it is kept, and the next run asks only for the rest" else if (fetched > 1) " — the ${fetched.to_str()} blocks fetched before it are kept, and the next run asks only for the rest" else ""

	# the servers to ask, in order: Overpass.servers, or STRIDE_OVERPASS_BASE,
	# a comma-separated list that lets the e2e point basemap at a local mock.
	# An entry outside the allow-list is dropped, and a list with nothing left
	# falls back to the public servers. Humans never set it.
	overpass_bases! : {} => List(Str)
	overpass_bases! = |{}| {
		named = match Env.var_str!(OsStr.from_str("STRIDE_OVERPASS_BASE")) {
			Ok(v) => List.keep_if(List.map(Str.split_on(v, ","), Str.trim), |b| !(Str.is_empty(b)) and Config.overpass_base_allowed(b))
			Err(_) => []
		}
		if (List.is_empty(named)) Overpass.servers else named
	}

	# A block walks the servers in order (Overpass.try_plan): a busy answer,
	# an answer carrying a remark, or a server that cannot be reached sends the
	# block to the next server, and each new round waits longer. As many tries
	# in a row as there are servers, none of which connected, end the run at
	# once as network_unreachable; otherwise, after Overpass.max_tries tries,
	# the run stops as busy.
	fetch_blocks! = |path, bases, pending, st, k, down|
		match pending {
			[] => Ok(st)
			[block, .. as rest] => {
				n = List.len(bases)
				plan = Overpass.try_plan(k, n, backoff_ms!({}), st.fetched == 0)
				_ = if (plan.wait_ms > 0) Sleep.millis!(plan.wait_ms) else Ok({})
				base = List.get(bases, plan.server) ?? "https://overpass-api.de"
				next! = |failure_down|
					if (k + 1 >= Overpass.max_tries(n)) Ok({ ..st, stopped: "overpass_busy" })
					else fetch_blocks!(path, bases, pending, st, k + 1, failure_down)
				match post_query!(base, Overpass.query(block)) {
					Err(e) =>
						if (down + 1 >= n)
							Err(OverpassUnreachable(unreachable_text(e), st.fetched))
						else
							next!(down + 1)
					Ok(resp) =>
						match Overpass.answer(Response.status(resp)) {
							Busy => next!(0)
							Failed => Err(OverpassStatus(Response.status(resp), Str.from_utf8_lossy(Response.body(resp)), st.fetched))
							Answered => {
								text = Str.from_utf8(Response.body(resp)) ? |_| OverpassUnreadable(st.fetched)
								match Overpass.decode_ways(text) {
									Ok(ways) => {
										store_block!(path, block, ways)?
										fetch_blocks!(path, bases, rest, { ..st, fetched: st.fetched + 1, stored: st.stored + List.len(ways).to_i64_wrap() }, 0, 0)
									}
									Err(Incomplete(_)) => next!(0)
									Err(Unreadable) => Err(OverpassUnreadable(st.fetched))
								}
							}
						}
				}
			}
		}

	# the platform's error, as text a person can read
	unreachable_text = |e|
		match e {
			HttpErr(Other(bytes)) => Str.from_utf8_lossy(bytes)
			_ => Str.inspect(e)
		}

	# the wait added per round of retries, on top of the one-second spacing.
	# STRIDE_OVERPASS_BACKOFF_MS can only shorten it, so the e2e suite waits
	# only the spacing; humans never set it.
	backoff_ms! : {} => U64
	backoff_ms! = |{}| {
		dflt = 15000
		match Env.var_str!(OsStr.from_str("STRIDE_OVERPASS_BACKOFF_MS")) {
			Ok(s) =>
				match U64.from_str(s) {
					Ok(n) if n < dflt => n
					_ => dflt
				}
			Err(_) => dflt
		}
	}

	post_query! = |base, query|
		Http.send!(
			Request.from_method(Method.POST)
				.with_uri("${base}/api/interpreter")
				.add_header("Content-Type", "application/x-www-form-urlencoded")
				.add_header("User-Agent", "stride (https://github.com/eschizoid/stride)")
				.with_body("data=${Overpass.form_escape(query)}".to_utf8())
				.with_timeout(TimeoutMilliseconds(200000)),
			{},
		)

	# a block's ways and the block commit together, so a stored block always
	# has its ways. The ways ride in as one JSON binding and SQLite unpacks it;
	# a way crossing a block edge arrives with both blocks and is stored once.
	store_block! = |path, block, ways|
		Sql.transaction!(
			Path.utf8(path),
			|run!| {
				_ = run!(
					"INSERT OR REPLACE INTO map_ways (way_id, kind, points) SELECT json_extract(value, '$.id'), json_extract(value, '$.kind'), json_extract(value, '$.points') FROM json_each(:w)",
					[{ name: ":w", value: String(Json.to_str(ways)) }],
				)?
				run!(
					"INSERT OR REPLACE INTO map_blocks (lat_block, lng_block, fetched_at) VALUES (:a, :b, datetime('now'))",
					[{ name: ":a", value: Integer(block.lat) }, { name: ":b", value: Integer(block.lng) }],
				)
			},
		)

	# every block a stored route passes through, and every block next to one,
	# that map_blocks does not hold, south to north. A block is the floor of a
	# coordinate times 10; CAST truncates toward zero, so the coordinate is
	# shifted positive first. The ring stops at the poles and wraps at the
	# antimeridian, so every block names a real box. A body that is not JSON,
	# and an element that is not a [lat, lng] pair of numbers on the globe,
	# add no block rather than failing the query: json_each hands a string
	# element over as bare text, and any JSON function given bare text fails
	# with malformed JSON, so each step tests `j.type` or `json_type(pair,
	# path)` before it extracts.
	pending_blocks! : Str => Try(List(Overpass.Block), _)
	pending_blocks! = |path|
		Sql.query_many!({
			path: Path.utf8(path),
			query: \\WITH e AS (
				\\  SELECT CASE WHEN j.type = 'array' THEN j.value END AS pair
				\\  FROM routes r,
				\\       json_each(CASE WHEN json_valid(r.raw_json) THEN r.raw_json ELSE '{}' END, '$.latlng.data') j
				\\),
				\\c AS (
				\\  SELECT CASE WHEN json_type(pair, '$[0]') IN ('integer', 'real') THEN json_extract(pair, '$[0]') END AS lat,
				\\         CASE WHEN json_type(pair, '$[1]') IN ('integer', 'real') THEN json_extract(pair, '$[1]') END AS lng
				\\  FROM e WHERE pair IS NOT NULL
				\\),
				\\p AS (
				\\  SELECT DISTINCT
				\\         CAST(lat * 10 + 10000 AS INTEGER) - 10000 AS lat_block,
				\\         CAST(lng * 10 + 10000 AS INTEGER) - 10000 AS lng_block
				\\  FROM c
				\\  WHERE lat BETWEEN -90 AND 90 AND lng BETWEEN -180 AND 180
				\\),
				\\step(d) AS (VALUES (-1), (0), (1)),
				\\area AS (
				\\  SELECT DISTINCT p.lat_block + a.d AS lat_block, ((p.lng_block + b.d + 1800) % 3600 + 3600) % 3600 - 1800 AS lng_block
				\\  FROM p, step a, step b
				\\  WHERE p.lat_block + a.d BETWEEN -900 AND 899
				\\)
				\\SELECT lat_block, lng_block FROM area
				\\WHERE NOT EXISTS (SELECT 1 FROM map_blocks m WHERE m.lat_block = area.lat_block AND m.lng_block = area.lng_block)
				\\ORDER BY lat_block, lng_block
			,
			bindings: [],
			rows: |cols| |vals| {
				lat = Sql.i64("lat_block")(cols)(vals)?
				lng = Sql.i64("lng_block")(cols)(vals)?
				Ok({ lat, lng })
			},
		})

	block_count! : Str => Try(I64, _)
	block_count! = |path|
		Sql.query!({ path: Path.utf8(path), query: "SELECT COUNT(*) AS n FROM map_blocks", bindings: [], row: Sql.i64("n") })

	way_count! : Str => Try(I64, _)
	way_count! = |path|
		Sql.query!({ path: Path.utf8(path), query: "SELECT COUNT(*) AS n FROM map_ways", bindings: [], row: Sql.i64("n") })

	clip : Str -> Str
	clip = |s| {
		bytes = Str.to_utf8(s)
		if (List.len(bytes) <= 200) s else "${Str.from_utf8_lossy(List.take_first(bytes, 200))}… (truncated)"
	}
}
