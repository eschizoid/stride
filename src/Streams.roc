# ── decoding of stored Strava stream JSON (pure) ────────────────────
Streams :: [].{

	StreamSeq : { data : List(F64) }
	StreamsResp : { time : Try(StreamSeq, [Missing]), heartrate : Try(StreamSeq, [Missing]), watts : Try(StreamSeq, [Missing]), altitude : Try(StreamSeq, [Missing]), distance : Try(StreamSeq, [Missing]) }

	empty_streams : StreamsResp
	empty_streams = { time: Err(Missing), heartrate: Err(Missing), watts: Err(Missing), altitude: Err(Missing), distance: Err(Missing) }

	# decode stored stream JSON, distinguishing a genuine "no streams" (Null, or the
	# {} 404-marker which decodes to all-absent) from a real DECODE FAILURE (corrupt /
	# schema-drifted JSON) so callers can surface it instead of silently zeroing.
	# Strava data arrays contain JSON null (sensor dropouts); builtin Json.parse rejects
	# null inside List(F64), so null is replaced with a sentinel first. The sentinel is
	# -99999, chosen BELOW any real reading (altitude bottoms out near -430m at the Dead
	# Sea; hr/watts/distance are >= 0), so a null is always distinguishable from a genuine
	# value — including a legitimately negative altitude. The pairing helpers drop the
	# sentinel; stream_pairs additionally drops negatives (hr/watts can never be < 0).
	decode_streams : [NotNull(Str), Null] -> { streams : StreamsResp, failed : Bool }
	decode_streams = |raw|
		match raw {
			NotNull(text) => {
				cleaned = Str.replace_each(text, "null", "-99999")
				decoded : Try(StreamsResp, [InvalidJson(Str), MissingRequiredField(Str)])
				decoded = Json.parse(cleaned)
				match decoded {
					Ok(s) => { streams: s, failed: False }
					Err(_) => { streams: empty_streams, failed: True }
				}
			}
			Null => { streams: empty_streams, failed: False }
		}

	# pair up stream time+value samples by index, dropping null (-99999 sentinel) samples
	stream_pairs : Try(StreamSeq, [Missing]), Try(StreamSeq, [Missing]) -> List({ t : I64, v : F64 })
	stream_pairs = |time_opt, val_opt|
		match (time_opt, val_opt) {
			(Ok(ts), Ok(vs)) => {
				paired = List.map2(ts.data, vs.data, |t, v| { t: t.round_to_i64_try().ok_or(0), v })
				List.keep_if(paired, |p| p.v >= 0.0)
			}
			_ => []
		}

	# pair cumulative-distance + altitude samples by index, for grade-adjusted pace.
	# A pair drops out only when either value is the -99999 null sentinel; a genuinely
	# negative altitude (below sea level) is KEPT — the whole point of a sentinel far below
	# any real reading. Feed the aligned {dist, alt} to Metrics.grade_adjusted_distance.
	dist_alt_pairs : Try(StreamSeq, [Missing]), Try(StreamSeq, [Missing]) -> { dist : List(F64), alt : List(F64) }
	dist_alt_pairs = |dist_opt, alt_opt|
		match (dist_opt, alt_opt) {
			(Ok(ds), Ok(al)) => {
				paired = List.map2(ds.data, al.data, |d, a| { d, a })
				kept = List.keep_if(paired, |p| p.d > -99998.0 and p.a > -99998.0)
				{ dist: List.map(kept, |p| p.d), alt: List.map(kept, |p| p.a) }
			}
			_ => { dist: [], alt: [] }
		}

	# align time+distance+altitude by index into THREE equal-length lists, for the pace
	# engine (grade-adjusted speed stream). This exists because a naive per-stream filter
	# would desync the lists: Metrics.grade_adjusted_speeds combines the three with a nested
	# map2 that truncates to the SHORTEST, so its inputs must already be equal-length and
	# index-aligned. Here we zip all three FIRST (one unit), then drop any sample whose
	# distance OR altitude is the -99999 null sentinel — removing that index from ALL three
	# lists together. A genuinely negative altitude (below sea level) is KEPT. Time is always
	# valid, so it never triggers a drop. Any missing stream -> three empty lists.
	dist_alt_time : Try(StreamSeq, [Missing]), Try(StreamSeq, [Missing]), Try(StreamSeq, [Missing]) -> { time : List(F64), dist : List(F64), alt : List(F64) }
	dist_alt_time = |time_opt, dist_opt, alt_opt|
		match (time_opt, dist_opt, alt_opt) {
			(Ok(ts), Ok(ds), Ok(al)) => {
				triples = List.map2(ts.data, List.map2(ds.data, al.data, |d, a| { d, a }), |t, da| { t, d: da.d, a: da.a })
				kept = List.keep_if(triples, |p| p.d > -99998.0 and p.a > -99998.0)
				{ time: List.map(kept, |p| p.t), dist: List.map(kept, |p| p.d), alt: List.map(kept, |p| p.a) }
			}
			_ => { time: [], dist: [], alt: [] }
		}
}

# the {} 404-marker decodes cleanly to "no streams", NOT a failure
expect {
	d = Streams.decode_streams(NotNull("{}"))
	d.failed == False and List.is_empty(Streams.stream_pairs(d.streams.time, d.streams.heartrate))
}

# corrupt JSON is a FAILURE (so analyze can say "unreadable"), not silent zeros
expect Streams.decode_streams(NotNull("not json at all")).failed == True

# absent row (Null) is genuine no-data, not a failure
expect Streams.decode_streams(Null).failed == False

# real payload: pairs join on index, null samples dropped
expect {
	d = Streams.decode_streams(NotNull("{\"time\":{\"data\":[0,1,2]},\"heartrate\":{\"data\":[100,null,120]}}"))
	pairs = Streams.stream_pairs(d.streams.time, d.streams.heartrate)
	!(d.failed) and List.len(pairs) == 2 and (match List.last(pairs) { Ok(p) => p.t == 2  Err(_) => False })
}

# distance + altitude decode and pair by index for grade-adjusted pace
expect {
	d = Streams.decode_streams(NotNull("{\"distance\":{\"data\":[0,100,200]},\"altitude\":{\"data\":[0,10,20]}}"))
	p = Streams.dist_alt_pairs(d.streams.distance, d.streams.altitude)
	near = |xs, ys| List.len(xs) == List.len(ys) and List.all(List.map2(xs, ys, |a, b| (a - b).abs() < 0.001), |ok| ok)
	!(d.failed) and near(p.dist, [0.0, 100.0, 200.0]) and near(p.alt, [0.0, 10.0, 20.0])
}

# altitude below sea level is KEPT (negative is valid), not dropped like a sentinel
expect {
	d = Streams.decode_streams(NotNull("{\"distance\":{\"data\":[0,50]},\"altitude\":{\"data\":[-30,-25]}}"))
	p = Streams.dist_alt_pairs(d.streams.distance, d.streams.altitude)
	near = |xs, ys| List.len(xs) == List.len(ys) and List.all(List.map2(xs, ys, |a, b| (a - b).abs() < 0.001), |ok| ok)
	near(p.alt, [-30.0, -25.0])
}

# time+dist+alt align into three equal-length lists by index (the pace-engine triple)
expect {
	d = Streams.decode_streams(NotNull("{\"time\":{\"data\":[0,1,2]},\"distance\":{\"data\":[0,100,200]},\"altitude\":{\"data\":[0,10,20]}}"))
	t = Streams.dist_alt_time(d.streams.time, d.streams.distance, d.streams.altitude)
	near = |xs, ys| List.len(xs) == List.len(ys) and List.all(List.map2(xs, ys, |a, b| (a - b).abs() < 0.001), |ok| ok)
	near(t.time, [0.0, 1.0, 2.0]) and near(t.dist, [0.0, 100.0, 200.0]) and near(t.alt, [0.0, 10.0, 20.0])
}

# a null distance drops that index from ALL three lists — they stay aligned
expect {
	d = Streams.decode_streams(NotNull("{\"time\":{\"data\":[0,1,2]},\"distance\":{\"data\":[0,null,200]},\"altitude\":{\"data\":[0,10,20]}}"))
	t = Streams.dist_alt_time(d.streams.time, d.streams.distance, d.streams.altitude)
	near = |xs, ys| List.len(xs) == List.len(ys) and List.all(List.map2(xs, ys, |a, b| (a - b).abs() < 0.001), |ok| ok)
	near(t.time, [0.0, 2.0]) and near(t.dist, [0.0, 200.0]) and near(t.alt, [0.0, 20.0])
}

# unequal-length streams truncate to the SHORTEST, all three still aligned
expect {
	d = Streams.decode_streams(NotNull("{\"time\":{\"data\":[0,1,2,3]},\"distance\":{\"data\":[0,100]},\"altitude\":{\"data\":[0,10,20]}}"))
	t = Streams.dist_alt_time(d.streams.time, d.streams.distance, d.streams.altitude)
	List.len(t.time) == 2 and List.len(t.dist) == 2 and List.len(t.alt) == 2
}

# a missing stream -> three empty lists, and it's genuine no-data (NOT a decode failure —
# both would give empty lists, so assert !failed to catch a decode-semantics regression)
expect {
	d = Streams.decode_streams(NotNull("{\"time\":{\"data\":[0,1]},\"distance\":{\"data\":[0,100]}}"))
	t = Streams.dist_alt_time(d.streams.time, d.streams.distance, d.streams.altitude)
	!(d.failed) and List.is_empty(t.time) and List.is_empty(t.dist) and List.is_empty(t.alt)
}

# absent distance/altitude -> empty pairing, no failure
expect {
	d = Streams.decode_streams(NotNull("{\"time\":{\"data\":[0,1]}}"))
	p = Streams.dist_alt_pairs(d.streams.distance, d.streams.altitude)
	!(d.failed) and List.is_empty(p.dist) and List.is_empty(p.alt)
}

# a null altitude becomes the sentinel and drops out; a real negative altitude is KEPT
expect {
	d = Streams.decode_streams(NotNull("{\"distance\":{\"data\":[0,100,200]},\"altitude\":{\"data\":[-30,null,-25]}}"))
	p = Streams.dist_alt_pairs(d.streams.distance, d.streams.altitude)
	near = |xs, ys| List.len(xs) == List.len(ys) and List.all(List.map2(xs, ys, |a, b| (a - b).abs() < 0.001), |ok| ok)
	List.len(p.dist) == 2 and near(p.alt, [-30.0, -25.0])
}
