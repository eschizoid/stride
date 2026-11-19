import rr.Color
import Geo
import Theme

Motion :: [].{
	# ── playback and heat for the map tab (pure) ───────────────────────────
	# Playback runs every route at once, each on its own clock from its own
	# start, all sped up by one factor, so a faster session's marker still
	# outruns a slower one's. Speed colours a route against that route's own
	# moving speed, so a run and a ride share one ramp. Heat counts segments:
	# every segment drawn adds one to each pixel it covers, so a road ridden
	# out and back counts twice and the overlapping ends of a line's
	# segments a little more, and the count is tone-mapped on a log scale
	# into the window's palette.

	# an hour of a session plays in thirty seconds
	speedup : F32
	speedup = 120.0

	# route seconds the cycle waits past the longest route before it starts
	# again, so the finished markers rest a moment in place
	rest : F32
	rest = 600.0

	# the route time playback shows after `secs` seconds of play: the clock
	# runs at speedup, and the whole cycle starts over `rest` route seconds
	# after the longest route ends
	play_time : F32, F32 -> F32
	play_time = |secs, longest| {
		t = secs * speedup
		cycle = longest + rest
		t - cycle * F32.div_floor_by(t, cycle)
	}

	# playback's clock after one frame: it starts at 0 each time the mode
	# opens, holds until the map has landed, so a capture made as the window
	# opens reads the same time on every run, and otherwise runs by the
	# frame's seconds unless paused; `toggle` is P, which pauses and resumes
	Clock : { secs : F32, paused : Bool }

	step_clock : Clock, { opening : Bool, landed : Bool, toggle : Bool, dt : F32 } -> Clock
	step_clock = |c, e|
		if e.opening {
			{ secs: 0.0, paused: Bool.False }
		} else {
			paused = if (e.toggle) !(c.paused) else c.paused
			{ secs: if (paused or !(e.landed)) c.secs else c.secs + e.dt, paused }
		}

	# where a route is at route time t: between the last sample at or before
	# t and the next, in proportion to the time between them; before the
	# first sample at the first point, after the last at the last
	at_time : List(Geo.Pt), List(F32), F32 -> Geo.Pt
	at_time = |pts, ts, t| {
		n = List.len(ts)
		first = (List.first(pts)) ?? { x: 0.0, y: 0.0 }
		last = (List.last(pts)) ?? first
		t0 = (List.first(ts)) ?? 0.0
		t1 = (List.last(ts)) ?? 0.0
		if n < 2 or t <= t0 {
			first
		} else if t >= t1 {
			last
		} else {
			i = before(ts, t, 0, n - 1)
			a = (List.get(pts, i)) ?? first
			b = (List.get(pts, i + 1)) ?? last
			ta = (List.get(ts, i)) ?? t0
			tb = (List.get(ts, i + 1)) ?? t1
			k = if (tb > ta) (t - ta) / (tb - ta) else 0.0
			{ x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k }
		}
	}

	# the last index whose time is at or before t, found by halving: ts[lo]
	# is at or before t and ts[hi] after it
	before : List(F32), F32, U64, U64 -> U64
	before = |ts, t, lo, hi|
		if hi - lo <= 1 {
			lo
		} else {
			mid = (lo + hi) // 2
			if (((List.get(ts, mid)) ?? 0.0) <= t) before(ts, t, mid, hi) else before(ts, t, lo, mid)
		}

	# the distance walked along a line up to each point, starting at 0
	walked : List(Geo.Pt) -> List(F32)
	walked = |pts|
		(
			List.fold(
				pts,
				{ prev: [], d: 0.0, out: [] },
				|acc, p| {
					d = match acc.prev {
						[q] => acc.d + F32.sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y))
						_ => 0.0
					}
					{ prev: [p], d, out: List.append(acc.out, d) }
				},
			)
		).out

	# each segment's speed, smoothed: the distance walked across `reach`
	# samples either side of it over the time they span, so one jittery fix
	# does not paint its own colour; a window that spans no time reads 0
	speeds : List(Geo.Pt), List(F32), U64 -> List(F32)
	speeds = |pts, ts, reach| {
		n = List.len(pts)
		w = walked(pts)
		List.map_with_index(
			List.drop_last(pts, 1),
			|_, j| {
				a = if (j >= reach) j - reach else 0
				b = if (j + 1 + reach < n) j + 1 + reach else n - 1
				dt = ((List.get(ts, b)) ?? 0.0) - ((List.get(ts, a)) ?? 0.0)
				dd = ((List.get(w, b)) ?? 0.0) - ((List.get(w, a)) ?? 0.0)
				if (dt > 0.0) dd / dt else 0.0
			},
		)
	}

	# the speed a route's colours are measured against: distance over time
	# across the segments where the athlete was moving, faster than half a
	# projected metre a second, so a stop at a light does not drag it down;
	# 0 for a route that never moved. The points are Web Mercator metres,
	# which stretch with latitude, and a band is a ratio of two speeds in the
	# same metres, so the stretch cancels.
	moving_speed : List(Geo.Pt), List(F32) -> F32
	moving_speed = |pts, ts| {
		raw = speeds(pts, ts, 0)
		w = walked(pts)
		sum = List.fold(
			List.map_with_index(raw, |v, j| { v, j }),
			{ d: 0.0, t: 0.0 },
			|acc, s|
				if s.v > 0.5 {
					dd = ((List.get(w, s.j + 1)) ?? 0.0) - ((List.get(w, s.j)) ?? 0.0)
					{ d: acc.d + dd, t: acc.t + dd / s.v }
				} else {
					acc
				},
		)
		if (sum.t > 0.0) sum.d / sum.t else 0.0
	}

	# the band a speed falls in against the route's moving speed: well
	# below, below, at, above, well above, split at 0.7, 0.9, 1.1 and 1.3
	# of it
	band : F32, F32 -> U8
	band = |v, ref|
		if ref <= 0.0 {
			2
		} else {
			q = v / ref
			if (q < 0.7) 0 else if (q < 0.9) 1 else if (q < 1.1) 2 else if (q < 1.3) 3 else 4
		}

	# the speed ramp, slowest first, in the window's palette: blue, a blue
	# leaning teal, the accent teal, gold and ember
	band_colour : U8 -> Color.Rgba
	band_colour = |b|
		if (b == 0) Theme.ctl_c
		else if (b == 1) Color.rgb(62, 177, 219)
		else if (b == 2) Theme.tsb_c
		else if (b == 3) Theme.gold_c
		else Theme.ember_c

	# the samples either side of a segment its speed is smoothed over
	speed_reach : U64
	speed_reach = 3

	# each segment's band against `ref`, the route's moving speed; the map
	# load works these out once per list and groups them into runs, so a
	# repaint only draws
	bands_of : List(Geo.Pt), List(F32), F32 -> List(U8)
	bands_of = |pts, ts, ref| List.map(speeds(pts, ts, speed_reach), |v| band(v, ref))

	# a route split into runs of one band each, from its points and each
	# segment's band; a run starts on the point the one before it ends on,
	# so the line stays unbroken. The band changes are found in one pass and
	# each run is sliced out of the points whole, so the cost grows with the
	# route's length, never with a run's.
	Run : { band : U8, pts : List(Geo.Pt) }

	runs : List(Geo.Pt), List(U8) -> List(Run)
	runs = |pts, bands| {
		n = List.len(bands)
		starts = List.keep_oks(
			List.map_with_index(bands, |b, j| if (j == 0) Ok({ j, b }) else if (((List.get(bands, j - 1)) ?? 255) != b) Ok({ j, b }) else Err(SameBand)),
			|s| s,
		)
		List.map_with_index(
			starts,
			|s, k| {
				end = ((List.get(starts, k + 1)).map_ok(|t| t.j)) ?? n
				{ band: s.b, pts: List.sublist(pts, { start: s.j, len: end - s.j + 1 }) }
			},
		)
	}

	# ── heat ────────────────────────────────────────────────────────────────
	# passes at which a road reads white-hot
	heat_top : F32
	heat_top = 48.0

	# the heat a count of passes shows, 0 to 1: the log of one more than the
	# count against the log of one more than heat_top, so a single pass
	# shows and the busiest roads still separate, held at 1 past heat_top
	heat_level : F32 -> F32
	heat_level = |n|
		if n < 0.5 {
			0.0
		} else {
			F32.min(1.0, F64.to_f32_wrap(Geo.ln(1.0 + F32.to_f64(n)) / Geo.ln(1.0 + F32.to_f64(heat_top))))
		}

	# the heat ramp's stops, coolest first, and the levels they sit at: the
	# views' blue, the accent teal, gold, and white for the busiest roads
	heat_stops : List({ at : F32, c : Color.Rgba })
	heat_stops = [{ at: 0.0, c: Theme.ctl_c }, { at: 0.45, c: Theme.tsb_c }, { at: 0.8, c: Theme.gold_c }, { at: 1.0, c: Color.white }]

	# a heat level's colour, each channel 0 to 1, between the two stops
	# around it
	heat_colour : F32 -> { r : F32, g : F32, b : F32 }
	heat_colour = |v| {
		lo = List.fold(heat_stops, { at: 0.0, c: Theme.ctl_c }, |acc, s| if (s.at <= v) s else acc)
		hi = (List.find_first(heat_stops, |s| s.at > v)) ?? lo
		k = if (hi.at > lo.at) (v - lo.at) / (hi.at - lo.at) else 0.0
		ch = |a, b| (U8.to_f32(a) + (U8.to_f32(b) - U8.to_f32(a)) * k) / 255.0
		{ r: ch(lo.c.r, hi.c.r), g: ch(lo.c.g, hi.c.g), b: ch(lo.c.b, hi.c.b) }
	}

	# how opaque heat draws: nothing where no route passed, heat_floor plus
	# heat_rise of the level otherwise, so a single pass (level about 0.18)
	# draws at about 0.42 and heat_top passes at full
	heat_floor : F32
	heat_floor = 0.3

	heat_rise : F32
	heat_rise = 0.7

	heat_alpha : F32 -> F32
	heat_alpha = |v| if (v <= 0.0) 0.0 else heat_floor + heat_rise * v

	# the shader's spelling of heat_level and heat_alpha: GLSL cannot call
	# the Roc, so the two formulas are written in both, and the alpha's
	# constants are spliced in from heat_floor and heat_rise
	heat_level_glsl : Str
	heat_level_glsl = "float v = min(1.0, log(1.0 + n) / log(1.0 + top));"

	heat_alpha_glsl : Str
	heat_alpha_glsl = "finalColor = vec4(ramp(v), ${F32.to_str(heat_floor)} + ${F32.to_str(heat_rise)} * v);"

	# The tone map as a fragment shader. Its ramp is built from heat_stops,
	# its saturation count arrives as the `top` uniform set to heat_top, and
	# its level and alpha lines are heat_level_glsl and heat_alpha_glsl; the
	# expects pin those lines beside the Roc definitions they spell. The
	# texture it reads holds a count in its red channel, one 255th added for
	# every segment drawn over the pixel.
	heat_frag : Str
	heat_frag = {
		v3 = |c| "vec3(${F32.to_str(U8.to_f32(c.r) / 255.0)}, ${F32.to_str(U8.to_f32(c.g) / 255.0)}, ${F32.to_str(U8.to_f32(c.b) / 255.0)})"
		stop = |i| (List.get(heat_stops, i)) ?? { at: 0.0, c: Color.white }
		Str.join_with(
			[
				"#version 330",
				"in vec2 fragTexCoord;",
				"in vec4 fragColor;",
				"uniform sampler2D texture0;",
				"uniform float top;",
				"out vec4 finalColor;",
				"vec3 ramp(float v) {",
				"    if (v < ${F32.to_str((stop(1)).at)}) return mix(${v3((stop(0)).c)}, ${v3((stop(1)).c)}, v / ${F32.to_str((stop(1)).at)});",
				"    if (v < ${F32.to_str((stop(2)).at)}) return mix(${v3((stop(1)).c)}, ${v3((stop(2)).c)}, (v - ${F32.to_str((stop(1)).at)}) / ${F32.to_str((stop(2)).at - (stop(1)).at)});",
				"    return mix(${v3((stop(2)).c)}, ${v3((stop(3)).c)}, (v - ${F32.to_str((stop(2)).at)}) / ${F32.to_str((stop(3)).at - (stop(2)).at)});",
				"}",
				"void main() {",
				"    float n = floor(texture(texture0, fragTexCoord).r * 255.0 + 0.5);",
				"    if (n < 1.0) { finalColor = vec4(0.0); return; }",
				"    ${heat_level_glsl}",
				"    ${heat_alpha_glsl}",
				"}",
			],
			"\n",
		)
	}

	near : F32, F32, F32 -> Bool
	near = |a, b, tol| (a - b).abs() <= tol

	# the clock: nothing at the start, an hour of route after thirty
	# seconds, and the cycle over the longest route and the rest starting
	# again
	expect near(play_time(0.0, 3600.0), 0.0, 0.001) and near(play_time(30.0, 3600.0), 3600.0, 0.01) and near(play_time(40.0, 3600.0), 600.0, 0.01)

	# the clock opens at 0, holds there while the map loads, runs once it has
	# landed, and stops and restarts with P
	expect {
		e = { opening: Bool.False, landed: Bool.True, toggle: Bool.False, dt: 0.5 }
		opened = step_clock({ secs: 9.0, paused: Bool.True }, { ..e, opening: Bool.True })
		held = step_clock(opened, { ..e, landed: Bool.False })
		ran = step_clock(held, e)
		paused = step_clock(ran, { ..e, toggle: Bool.True })
		resumed = step_clock(step_clock(paused, e), { ..e, toggle: Bool.True })
		opened == { secs: 0.0, paused: Bool.False } and held == opened and near(ran.secs, 0.5, 0.0001) and paused.paused and near(step_clock(paused, e).secs, 0.5, 0.0001) and !(resumed.paused) and near(resumed.secs, 1.0, 0.0001)
	}

	# a route between two samples sits in proportion to the time between
	# them, and before its start or after its end at its ends
	expect {
		pts = [{ x: 0.0, y: 0.0 }, { x: 10.0, y: 0.0 }, { x: 10.0, y: 30.0 }, { x: 0.0, y: 30.0 }]
		ts = [0.0, 10.0, 40.0, 50.0]
		m = at_time(pts, ts, 25.0)
		s = at_time(pts, ts, 10.0)
		near(m.x, 10.0, 0.001) and near(m.y, 15.0, 0.001) and near(s.x, 10.0, 0.001) and near(s.y, 0.0, 0.001)
			and at_time(pts, ts, -5.0) == { x: 0.0, y: 0.0 } and at_time(pts, ts, 99.0) == { x: 0.0, y: 30.0 }
	}

	# a steady route reads one speed everywhere; a stop reads slow, and the
	# moving speed leaves the stop out
	expect {
		pts = [{ x: 0.0, y: 0.0 }, { x: 10.0, y: 0.0 }, { x: 20.0, y: 0.0 }, { x: 20.0, y: 0.0 }, { x: 30.0, y: 0.0 }]
		ts = [0.0, 2.0, 4.0, 64.0, 66.0]
		raw = speeds(pts, ts, 0)
		List.len(raw) == 4 and near((List.get(raw, 0)) ?? 0.0, 5.0, 0.001) and near((List.get(raw, 2)) ?? 9.0, 0.0, 0.001) and near(moving_speed(pts, ts), 5.0, 0.001)
	}

	# smoothing spreads a jittery fix over its neighbours
	expect {
		pts = [{ x: 0.0, y: 0.0 }, { x: 10.0, y: 0.0 }, { x: 40.0, y: 0.0 }, { x: 50.0, y: 0.0 }, { x: 60.0, y: 0.0 }]
		ts = [0.0, 1.0, 2.0, 3.0, 4.0]
		near((List.get(speeds(pts, ts, 0), 1)) ?? 0.0, 30.0, 0.001) and near((List.get(speeds(pts, ts, 1), 1)) ?? 0.0, 50.0 / 3.0, 0.01)
	}

	# the bands split at 0.7, 0.9, 1.1 and 1.3 of the route's own moving
	# speed, and a route that never moved reads as at its speed
	expect List.map([0.69, 0.71, 0.89, 0.91, 1.09, 1.11, 1.29, 1.31], |q| band(q * 6.0, 6.0)) == [0, 1, 1, 2, 2, 3, 3, 4] and band(3.0, 0.0) == 2

	# a steady route bands at its own speed everywhere, and the same route
	# read against half that speed bands well above it
	expect {
		pts = [{ x: 0.0, y: 0.0 }, { x: 5.0, y: 0.0 }, { x: 10.0, y: 0.0 }, { x: 15.0, y: 0.0 }]
		ts = [0.0, 1.0, 2.0, 3.0]
		bands_of(pts, ts, 5.0) == [2, 2, 2] and bands_of(pts, ts, 2.5) == [4, 4, 4]
	}

	# runs change at each band change, each starting where the last ended
	expect {
		pts = [{ x: 0.0, y: 0.0 }, { x: 1.0, y: 0.0 }, { x: 2.0, y: 0.0 }, { x: 3.0, y: 0.0 }]
		rs = runs(pts, [2, 2, 4])
		List.map(rs, |r| r.band) == [2, 4] and List.map(rs, |r| List.len(r.pts)) == [3, 2] and ((List.get(rs, 1)) ?? { band: 0, pts: [] }).pts == [{ x: 2.0, y: 0.0 }, { x: 3.0, y: 0.0 }]
	}

	# heat: nothing for no pass, a visible fifth or so for one, full at
	# heat_top and held there past it, and every pass hotter than the last
	expect heat_level(0.0) == 0.0 and heat_level(1.0) > 0.15 and heat_level(1.0) < 0.2 and near(heat_level(48.0), 1.0, 0.0001) and heat_level(500.0) == 1.0 and heat_level(2.0) < heat_level(3.0)

	# the ramp runs from the blue through the accent and gold to white
	expect {
		c0 = heat_colour(0.0)
		ct = heat_colour(0.45)
		c1 = heat_colour(1.0)
		near(c0.b, U8.to_f32(Theme.ctl_c.b) / 255.0, 0.001) and near(ct.g, U8.to_f32(Theme.tsb_c.g) / 255.0, 0.001) and near(c1.r, 1.0, 0.001) and near(c1.g, 1.0, 0.001)
	}

	# the shader carries the stops and its level and alpha lines, which spell
	# heat_level and heat_alpha with heat_floor and heat_rise; one pass shows
	# at level 0.178 and alpha 0.425
	expect Str.contains(heat_frag, heat_level_glsl) and Str.contains(heat_frag, heat_alpha_glsl) and Str.contains(heat_level_glsl, "log(1.0 + n) / log(1.0 + top)") and Str.contains(heat_alpha_glsl, "ramp(v), 0.3") and Str.contains(heat_alpha_glsl, " + 0.7") and Str.contains(heat_frag, "if (v < 0.45)") and Str.contains(heat_frag, F32.to_str(U8.to_f32(Theme.tsb_c.g) / 255.0)) and heat_alpha(0.0) == 0.0 and near(heat_alpha(1.0), 1.0, 0.001) and near(heat_level(1.0), 0.1781, 0.0005) and near(heat_alpha(heat_level(1.0)), 0.4247, 0.0005)
}
