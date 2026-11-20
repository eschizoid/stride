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

	# a route's marker at route time t: where the route is, and whether it
	# is still under way there
	Mark : { at : Geo.Pt, live : Bool }

	mark : List(Geo.Pt), List(F32), F32 -> Mark
	mark = |pts, ts, t| { at: at_time(pts, ts, t), live: t < ((List.last(ts)) ?? 0.0) }

	# The markers a frame draws while playback is paused. Paused, the clock
	# stands still, so the markers placed once are kept until the map they
	# stand on changes (`rebuilt`) or playback stops being paused in play;
	# `place` places them afresh. Running, none are kept, since every frame
	# moves them.
	Marks : [Stale, Held(List(Mark))]

	step_marks : Marks, { view : U8, paused : Bool, was_view : U8, was_paused : Bool, rebuilt : Bool }, ({} -> List(Mark)) -> Marks
	step_marks = |held, e, place|
		if e.view != 12 or !(e.paused) {
			Stale
		} else {
			match held {
				Held(ms) => if (e.was_view == 12 and e.was_paused and !(e.rebuilt)) Held(ms) else Held(place({}))
				Stale => Held(place({}))
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
	walked = |pts| {
		first = (List.first(pts)) ?? { x: 0.0, y: 0.0 }
		(
			List.fold(
				pts,
				{ last: first, d: 0.0, out: List.with_capacity(List.len(pts)) },
				|acc, p| {
					d = acc.d + F32.sqrt((p.x - acc.last.x) * (p.x - acc.last.x) + (p.y - acc.last.y) * (p.y - acc.last.y))
					{ last: p, d, out: List.append(acc.out, d) }
				},
			)
		).out
	}

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

	# each segment's band against `ref`, the route's moving speed
	bands_of : List(Geo.Pt), List(F32), F32 -> List(U8)
	bands_of = |pts, ts, ref| List.map(speeds(pts, ts, speed_reach), |v| band(v, ref))

	# the fewest segments a run of one band keeps its own colour over
	min_run : U64
	min_run = 4

	# Each segment's band with the short runs merged away: a run of one band
	# fewer than `least` segments long takes the band of the run before it,
	# and a short run at the start the band of the first run long enough to
	# keep its own. A short run costs a draw call of its own and reads as a
	# speck of colour at a wide zoom. The list keeps its length, so it stays
	# aligned with the segments it bands.
	merged : List(U8), U64 -> List(U8)
	merged = |bands, least| {
		n = List.len(bands)
		var $out = List.with_capacity(n)
		var $band = (List.first(bands)) ?? 0
		var $len = 0
		var $i = 0
		while $i < n {
			b = (List.get(bands, $i)) ?? 0
			var $j = $i + 1
			while $j < n and ((List.get(bands, $j)) ?? 0) == b {
				$j = $j + 1
			}
			run = $j - $i
			if $len == 0 or $band == b or run < least {
				$len = $len + run
			} else if $len < least {
				$band = b
				$len = $len + run
			} else {
				$out = List.concat($out, List.repeat($band, $len))
				$band = b
				$len = run
			}
			$i = $j
		}
		List.concat($out, List.repeat($band, $len))
	}

	# a route's speed bands as playback keeps them: one per segment against
	# `ref`, the route's moving speed, with the short runs merged away
	banded : List(Geo.Pt), List(F32), F32 -> List(U8)
	banded = |pts, ts, ref| merged(bands_of(pts, ts, ref), min_run)

	# A route on screen in strips of one band each, from its points, each
	# segment's band and where a point lands on screen. A strip starts on
	# the point the one before it ends on, so the line stays unbroken, and
	# inside a strip a point is kept only once it lies `step` pixels or more
	# from the last one kept on either axis, as Geo.thin keeps them; a strip's
	# ends always are. A route with no bands, or under two points, draws none.
	Strip : { band : U8, pts : List(Geo.Pt) }

	strips : List(Geo.Pt), List(U8), (Geo.Pt -> Geo.Pt), F32 -> List(Strip)
	strips = |pts, bands, at, step| {
		n = List.len(pts)
		if n < 2 or List.is_empty(bands) {
			[]
		} else {
			first = at((List.first(pts)) ?? { x: 0.0, y: 0.0 })
			var $out = []
			var $cur = [first]
			var $last = first
			var $b = (List.first(bands)) ?? 0
			var $i = 1
			while $i < n {
				p = at((List.get(pts, $i)) ?? { x: 0.0, y: 0.0 })
				next = (List.get(bands, $i)) ?? $b
				if $i + 1 == n {
					$cur = List.append($cur, p)
				} else if next != $b {
					$out = List.append($out, { band: $b, pts: List.append($cur, p) })
					$cur = [p]
					$last = p
					$b = next
				} else if (p.x - $last.x).abs() >= step or (p.y - $last.y).abs() >= step {
					$cur = List.append($cur, p)
					$last = p
				}
				$i = $i + 1
			}
			List.append($out, { band: $b, pts: $cur })
		}
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

	# a marker stands where its route is and is live until the route's last
	# sample
	expect {
		pts = [{ x: 0.0, y: 0.0 }, { x: 10.0, y: 0.0 }, { x: 10.0, y: 30.0 }]
		ts = [0.0, 10.0, 40.0]
		mark(pts, ts, 25.0) == { at: { x: 10.0, y: 15.0 }, live: Bool.True } and mark(pts, ts, 40.0) == { at: { x: 10.0, y: 30.0 }, live: Bool.False }
	}

	# a paused frame in play keeps the markers already placed; the first
	# paused frame, a new map, and a paused frame after leaving play place
	# them again, and running or another mode keeps none
	expect {
		one = [{ at: { x: 1.0, y: 2.0 }, live: Bool.True }]
		two = [{ at: { x: 5.0, y: 6.0 }, live: Bool.False }]
		e = { view: 12, paused: Bool.True, was_view: 12, was_paused: Bool.True, rebuilt: Bool.False }
		place = |_| two
		step_marks(Held(one), e, place) == Held(one) and step_marks(Stale, e, place) == Held(two)
			and step_marks(Held(one), { ..e, rebuilt: Bool.True }, place) == Held(two)
			and step_marks(Held(one), { ..e, was_paused: Bool.False }, place) == Held(two)
			and step_marks(Held(one), { ..e, was_view: 10 }, place) == Held(two)
			and step_marks(Held(one), { ..e, paused: Bool.False }, place) == Stale
			and step_marks(Held(one), { ..e, view: 11 }, place) == Stale
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

	# a run shorter than the least keeps no colour of its own: one inside a
	# route takes the band before it, one at the start the first band long
	# enough to keep, a route of short runs alone the first band, and the
	# list keeps its length
	expect merged([2, 2, 2, 2, 2, 3, 2, 3, 3, 3, 3, 3], 4) == [2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3]
		and merged([2, 2, 2, 2, 4, 4, 4, 2, 2, 2, 2], 4) == List.repeat(2, 11)
		and merged([1, 3, 3, 3, 3, 0, 0, 0, 0], 4) == [3, 3, 3, 3, 3, 0, 0, 0, 0]
		and merged([0, 1, 0, 1, 4, 4], 4) == List.repeat(0, 6)
		and merged([1, 1, 1, 1, 3, 3, 3, 3], 4) == [1, 1, 1, 1, 3, 3, 3, 3]
		and merged([], 4) == [] and merged([2, 4, 2], 1) == [2, 4, 2]

	# strips change at each band change, each starting on the point the last
	# ended on, and keep inside a strip only the points a step from the last
	# one kept, always keeping both ends
	expect {
		pt = |x| { x, y: 0.0 }
		pts = [pt(0.0), pt(1.0), pt(1.25), pt(2.0), pt(3.0), pt(3.25)]
		ss = strips(pts, [2, 2, 2, 4, 4], |p| { x: p.x * 10.0, y: p.y }, 5.0)
		List.map(ss, |s| s.band) == [2, 4] and List.map(ss, |s| s.pts) == [[pt(0.0), pt(10.0), pt(20.0)], [pt(20.0), pt(30.0), pt(32.5)]]
			and strips(pts, [], |p| p, 1.0) == [] and strips([pt(0.0)], [2], |p| p, 1.0) == []
			and List.map(strips(pts, [3, 3, 3, 3, 3], |p| p, 1.0), |s| s.pts) == [[pt(0.0), pt(1.0), pt(2.0), pt(3.0), pt(3.25)]]
	}

	# a route banded for playback reads its own speed everywhere when steady;
	# a burst near the start bands well above for one segment, which keeps no
	# colour of its own and takes the band of the run after it
	expect {
		pts = List.map_with_index(List.repeat(0, 12), |_, i| { x: U64.to_f32(i) * 5.0, y: 0.0 })
		ts = List.map_with_index(pts, |_, i| U64.to_f32(i))
		burst = List.map_with_index(pts, |p, i| if (i >= 2) { x: p.x + 7.0, y: 0.0 } else p)
		banded(pts, ts, 5.0) == List.repeat(2, 11) and bands_of(burst, ts, 5.0) == [4, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2] and banded(burst, ts, 5.0) == [3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2]
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
