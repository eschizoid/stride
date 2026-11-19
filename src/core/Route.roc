# stride-core: a stored route answer read back as GPS points. The engine
# stores Strava's `latlng,time` streams answer as sent, and both binaries
# read it: the engine to tell a real route from the no-GPS marker, the
# window to draw it.
Route :: [].{
	# one GPS sample: degrees, and seconds since the activity started
	RoutePoint : { lat : F64, lng : F64, t : I64 }

	# the route request's answer: `latlng` is a list of [lat, lng] pairs aligned
	# index for index with `time`. Strava sends a `distance` stream with every
	# streams answer; it is not read here.
	RouteResp : { latlng : Try({ data : List(List(F64)) }, [Missing]), time : Try({ data : List(F64) }, [Missing]) }

	# what a route body says. `Points` holds every sample that is a real
	# coordinate with a real time. `NoGps` is a body with no position to keep:
	# no `latlng` stream at all, which is what Strava sends for an indoor
	# session, or coordinates of which none is on the globe. `Unreadable` is a
	# body that is not a streams answer, or one holding a real position that no
	# usable time can be paired with, since storing the no-GPS marker for it
	# would retire a route that exists. A JSON null becomes -99999 first, the
	# sentinel the engine's stream decoder uses, so a null time drops its sample.
	decode_route : Str -> [Points(List(RoutePoint)), NoGps, Unreadable]
	decode_route = |text| {
		decoded : Try(RouteResp, [InvalidJson(Str), MissingRequiredField(Str)])
		decoded = Json.parse(Str.replace_each(text, "null", "-99999"))
		match decoded {
			Err(_) => Unreadable
			Ok(r) =>
				match (r.latlng, r.time) {
					(Ok(ll), Ok(ts)) => {
						pts = List.keep_oks(List.map2(ll.data, ts.data, |pair, t| route_point(pair, t)), |p| p)
						if !(List.is_empty(pts)) {
							Points(pts)
						} else if List.any(ll.data, on_globe) {
							Unreadable
						} else {
							NoGps
						}
					}
					(Ok(ll), Err(Missing)) => if (List.any(ll.data, on_globe)) Unreadable else NoGps
					(Err(Missing), _) => NoGps
				}
		}
	}

	# a [lat, lng] pair that names a place: two numbers, latitude within 90
	# degrees and longitude within 180
	on_globe : List(F64) -> Bool
	on_globe = |pair|
		match pair {
			[lat, lng] => lat >= -90.0 and lat <= 90.0 and lng >= -180.0 and lng <= 180.0
			_ => False
		}

	route_point : List(F64), F64 -> Try(RoutePoint, [NotACoordinate])
	route_point = |pair, t|
		match pair {
			[lat, lng] if on_globe(pair) and t > -99998.0 => Ok({ lat, lng, t: t.round_to_i64_try().ok_or(0) })
			_ => Err(NotACoordinate)
		}

	# a route answer pairs each coordinate with its time, in order
	expect {
		r = decode_route("{\"latlng\":{\"data\":[[41.88,-87.63],[41.89,-87.64]]},\"time\":{\"data\":[0,5]},\"distance\":{\"data\":[0,120]}}")
		match r {
			Points([a, b]) => a.lat == 41.88 and a.lng == -87.63 and a.t == 0 and b.lat == 41.89 and b.t == 5
			_ => False
		}
	}

	# an indoor session's answer has no latlng key at all: no GPS, not unreadable
	expect decode_route("{\"time\":{\"data\":[0,1]},\"distance\":{\"data\":[0,0]}}") == NoGps

	# the {} marker is no GPS
	expect decode_route("{}") == NoGps

	# a body that is not a streams answer is unreadable
	expect decode_route("not json at all") == Unreadable

	# a sample with a null time, or a pair outside the globe, is dropped and the rest kept
	expect {
		r = decode_route("{\"latlng\":{\"data\":[[41.88,-87.63],[41.89,-87.64],[95.0,-87.65]]},\"time\":{\"data\":[0,null,9]}}")
		match r {
			Points([only]) => only.t == 0
			_ => False
		}
	}

	# coordinates with no usable sample at all are no GPS
	expect decode_route("{\"latlng\":{\"data\":[[0.5]]},\"time\":{\"data\":[0]}}") == NoGps

	# coordinates with no usable time are unreadable, never the no-GPS marker: a
	# missing time stream, an empty one, and one of nothing but nulls
	expect decode_route("{\"latlng\":{\"data\":[[41.88,-87.63]]}}") == Unreadable
	expect decode_route("{\"latlng\":{\"data\":[[41.88,-87.63]]},\"time\":{\"data\":[]}}") == Unreadable
	expect decode_route("{\"latlng\":{\"data\":[[41.88,-87.63],[41.89,-87.64]]},\"time\":{\"data\":[null,null]}}") == Unreadable

	# an empty latlng stream is no GPS whatever the time stream says
	expect decode_route("{\"latlng\":{\"data\":[]}}") == NoGps

	# timed coordinates of which none is on the globe are no GPS, and a longitude
	# past 180 drops its sample like a latitude past 90
	expect decode_route("{\"latlng\":{\"data\":[[95.0,0.0]]},\"time\":{\"data\":[0]}}") == NoGps
	expect {
		r = decode_route("{\"latlng\":{\"data\":[[41.88,181.0],[41.88,-87.63]]},\"time\":{\"data\":[0,1]}}")
		match r {
			Points([only]) => only.t == 1
			_ => False
		}
	}

	# a real position that no usable time pairs with is unreadable, never the marker:
	# its only time on a sample off the globe, or a time stream shorter than the
	# coordinates
	expect decode_route("{\"latlng\":{\"data\":[[41.88,-87.63],[41.89,-87.64],[95.0,0.0]]},\"time\":{\"data\":[null,null,5]}}") == Unreadable
	expect decode_route("{\"latlng\":{\"data\":[[95.0,0.0],[41.89,-87.64]]},\"time\":{\"data\":[0]}}") == Unreadable
}
