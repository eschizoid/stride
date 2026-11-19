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
# and the block in map_blocks in one transaction. A block the server is too
# busy to answer is asked again after a wait; one still refused stops the run
# with the blocks already stored kept, and the next run asks only for the
# blocks still missing.
Basemap :: [].{

	basemap! : {} => Try({}, _)
	basemap! = |{}| {
		path = Db.open_db!({})?
		blocks = pending_blocks!(path)?
		match fetch_blocks!(path, overpass_base!({}), blocks, { fetched: 0, stored: 0, stopped: "complete" }, 0) {
			Ok(st) =>
				if st.stopped == "overpass_busy" and st.fetched == 0 {
					Output.err_out!("overpass_busy", "the Overpass server is busy and fetched nothing — run `stride basemap` again in a few minutes")
				} else {
					total = way_count!(path)?
					Output.out!(
						{ blocks_fetched: st.fetched, blocks_pending: List.len(blocks).to_i64_wrap() - st.fetched, ways_stored: st.stored, map_ways: total, stopped: st.stopped },
						Overpass.summary_line,
					)
				}
			Err(OverpassStatus(status, body)) =>
				Output.err_out!("overpass_error", "the Overpass API returned HTTP ${status.to_str()}: ${clip(body)}")
			Err(OverpassUnreadable) =>
				Output.err_out!("overpass_error", "the Overpass API answered with something that is not map data")
			Err(OverpassUnreachable(msg)) =>
				Output.err_out!("network_unreachable", "could not reach the Overpass API (${clip(msg)}) — check the connection and retry")
			Err(e) => Err(e)
		}
	}

	# Overpass base override (STRIDE_OVERPASS_BASE) — lets the e2e point
	# basemap at a local mock; humans never set it
	overpass_base! : {} => Str
	overpass_base! = |{}|
		match Env.var_str!(OsStr.from_str("STRIDE_OVERPASS_BASE")) {
			Ok(b) if !(Str.is_empty(b)) and Config.overpass_base_allowed(b) => b
			_ => "https://overpass-api.de"
		}

	# A busy answer is asked again after a wait that grows with each try, and
	# after `Overpass.busy_retries` of them the run stops as busy. One request
	# at a time, a second apart, as the public server asks.
	fetch_blocks! = |path, base, pending, st, tries|
		match pending {
			[] => Ok(st)
			[block, .. as rest] => {
				_ = if (st.fetched > 0 or tries > 0) Sleep.millis!(1000 + backoff_ms!({}) * tries) else Ok({})
				resp = post_query!(base, Overpass.query(block)).map_err(|e| OverpassUnreachable(Str.inspect(e)))?
				match Overpass.answer(Response.status(resp)) {
					Busy if tries < Overpass.busy_retries => fetch_blocks!(path, base, pending, st, tries + 1)
					Busy => Ok({ ..st, stopped: "overpass_busy" })
					Failed => Err(OverpassStatus(Response.status(resp), Str.from_utf8_lossy(Response.body(resp))))
					Answered => {
						text = Str.from_utf8(Response.body(resp)) ? |_| OverpassUnreadable
						ways = Overpass.decode_ways(text) ? |_| OverpassUnreadable
						store_block!(path, block, ways)?
						fetch_blocks!(path, base, rest, { ..st, fetched: st.fetched + 1, stored: st.stored + List.len(ways).to_i64_wrap() }, 0)
					}
				}
			}
		}

	# the wait added per busy try. STRIDE_OVERPASS_BACKOFF_MS can only shorten
	# it, so the e2e suite reaches the busy stop in milliseconds; humans never
	# set it.
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
	# shifted positive first. A body that is not JSON is read as having no
	# points rather than failing the query.
	pending_blocks! : Str => Try(List(Overpass.Block), _)
	pending_blocks! = |path|
		Sql.query_many!({
			path: Path.utf8(path),
			query: \\WITH p AS (
				\\  SELECT DISTINCT
				\\         CAST(json_extract(j.value, '$[0]') * 10 + 10000 AS INTEGER) - 10000 AS lat_block,
				\\         CAST(json_extract(j.value, '$[1]') * 10 + 10000 AS INTEGER) - 10000 AS lng_block
				\\  FROM routes r,
				\\       json_each(CASE WHEN json_valid(r.raw_json) THEN r.raw_json ELSE '{}' END, '$.latlng.data') j
				\\  WHERE json_type(j.value) = 'array'
				\\    AND json_extract(j.value, '$[0]') BETWEEN -90 AND 90
				\\    AND json_extract(j.value, '$[1]') BETWEEN -180 AND 180
				\\),
				\\step(d) AS (VALUES (-1), (0), (1)),
				\\area AS (
				\\  SELECT DISTINCT p.lat_block + a.d AS lat_block, p.lng_block + b.d AS lng_block
				\\  FROM p, step a, step b
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

	way_count! : Str => Try(I64, _)
	way_count! = |path|
		Sql.query!({ path: Path.utf8(path), query: "SELECT COUNT(*) AS n FROM map_ways", bindings: [], row: Sql.i64("n") })

	clip : Str -> Str
	clip = |s| {
		bytes = Str.to_utf8(s)
		if (List.len(bytes) <= 200) s else "${Str.from_utf8_lossy(List.take_first(bytes, 200))}… (truncated)"
	}
}
