import rr.Color
import rr.Draw
import Chrome
import Db
import Geo
import Labels
import Motion
import Scene
import Theme
import Ui

Map :: [].{
	# The map view: every GPS session drawn over the street map the engine
	# fetched, in Web Mercator, north up. Drag pans, the wheel zooms at the
	# cursor, and `0` returns to the opening view (Geo.opening). The streets
	# come from OpenStreetMap, and the view credits it on the map itself.

	# The tab's three modes share its pill and switch by chips in the
	# header, as the day tab's do: routes (view 10) draws every route in the
	# accent, heat (11) the passes summed and tone-mapped so the roads used
	# most glow hottest, and play (12) every route coloured by its speed with
	# a marker riding each at its own pace. The view ids stay distinct, so a
	# directive or a capture names the mode.
	modes : List({ v : U8, label : Str })
	modes = [{ v: 10, label: "routes" }, { v: 11, label: "heat" }, { v: 12, label: "play" }]

	is_map : U8 -> Bool
	is_map = |v| v == 10 or v == 11 or v == 12

	# the pill a view lights: every mode lights the map pill
	group : U8 -> U8
	group = |v| if (is_map(v)) 10 else v

	# a click on the map's pill keeps the mode on screen; from any other view
	# it opens the routes
	from_pill : U8, U8 -> U8
	from_pill = |pill, current| if (pill == 10 and is_map(current)) current else pill

	chip_w : F32
	chip_w = 46.0

	chip_x : U64 -> F32
	chip_x = |i| 36.0 + U64.to_f32(i) * 54.0

	chip_top : F32
	chip_top = 64.0

	chip_bottom : F32
	chip_bottom = 86.0

	chip_box : U64 -> Labels.Rect
	chip_box = |i| { x: chip_x(i), y: chip_top, w: chip_w, h: chip_bottom - chip_top }

	# the mode a click at (x, y) picks, or -1 when it misses every chip
	mode_at : F32, F32 -> I64
	mode_at = |x, y|
		if y < chip_top or y > chip_bottom {
			-1
		} else {
			List.fold(
				List.map_with_index(modes, |m, i| { m, i }),
				-1,
				|acc, e| if (x >= chip_x(e.i) and x <= chip_x(e.i) + chip_w) (U8.to_i64(e.m.v)) else acc,
			)
		}

	# each mode's title starts right of the chips, on the same row
	title_x : F32
	title_x = chip_x(List.len(modes)) + 12.0

	draw_chips! : Ui.Model, Draw.Frame => {}
	draw_chips! = |model, frame|
		List.for_each!(
			List.map_with_index(modes, |m, i| { m, i }),
			|e| {
				b = chip_box(e.i)
				on = e.m.v == model.view
				hov = model.mouse_x >= b.x and model.mouse_x <= b.x + b.w and model.mouse_y >= b.y and model.mouse_y <= b.y + b.h
				look = if (on) (Draw.filled(Color.with_alpha(Theme.ctl_c, 60))) else if (hov) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
				frame.rounded_rectangle!({ x: b.x, y: b.y, width: b.w, height: b.h, radius: 6.0, segments: 6, style: look })
			},
		)

	chip_texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	chip_texts = |model, measure| List.map_with_index(modes, |m, i| Scene.fixed(measure, Scene.data(m.label, 12.0, if (m.v == model.view) Color.white else Theme.ink_muted), { x: chip_x(i) + chip_w / 2.0, y: 68.0, align: Center }, chip_box(i)))

	chip_marks : List(Labels.Mark)
	chip_marks = List.map_with_index(modes, |m, i| { key: "the ${m.label} chip", box: chip_box(i) })

	title_text : U8 -> Str
	title_text = |v|
		if (v == 11) "heat - the roads used most glow hottest"
		else if (v == 12) "playback - every session at once, an hour in ${U64.to_str((F32.round_to_u64_try(3600.0 / Motion.speedup)) ?? 0)} seconds"
		else "routes - every GPS session on the street map"

	hint_text : U8 -> Str
	hint_text = |v|
		if (v == 12) "P  pause      drag  pan      wheel  zoom      0  home      TAB  form      S  screenshot      ESC quit"
		else "drag  pan      wheel  zoom      0  home      TAB  form      R  reload      S  screenshot      ESC quit"

	# playback's clock as the route time every marker shows: hours and
	# minutes into each session
	clock_text : F32 -> Str
	clock_text = |secs| {
		m = (F32.round_to_u64_try(F32.div_floor_by(secs, 60.0))) ?? 0
		mm = m % 60
		pad = if (mm < 10) Str.concat("0", U64.to_str(mm)) else U64.to_str(mm)
		"${U64.to_str(m // 60)}:${pad} into each session"
	}

	credit_text : Str
	credit_text = "OpenStreetMap contributors"

	no_routes_text : Str
	no_routes_text = "no GPS routes yet - stride sync fetches one per outdoor session"

	no_base_text : Str
	no_base_text = "no street map yet - stride basemap fetches the streets around these routes"

	loading_text : Str
	loading_text = "reading the routes and the street map..."

	# the map has not landed yet: its load is waiting to start or running
	loading : Ui.Model -> Bool
	loading = |model|
		match model.map_load {
			Loaded => Bool.False
			_ => Bool.True
		}

	# the camera a picture that was never painted holds: no zoom the view
	# ever has, so the first frame that shows the map paints it
	unpainted : Geo.Cam
	unpainted = { cx: 0.0, cy: 0.0, mpp: 0.0 }

	# the map's rectangle: the panel between the title row and the hint row
	rect : { w : F32, h : F32 } -> Geo.Rect
	rect = |win| { x: 36.0, y: 96.0, w: win.w - 72.0, h: win.h - 96.0 - 48.0 }

	# the camera the view shows: the athlete's own once they have moved it,
	# else the opening Geo.opening picks, which follows the window as it
	# resizes
	cam : Ui.Model -> Geo.Cam
	cam = |model| if (model.map_moved) model.map_cam else Geo.opening(model.map.fit, model.map.focus, rect(model.win))

	# how each kind draws, by Db.way_kinds' codes: its colour and opacity,
	# its width in logical pixels, and the zooms, in metres per pixel, where
	# it starts to show and where it is fully drawn. Streets and cycleways
	# fade in only once the view is close enough that the grid stops being a
	# grey wash; water, the arterials, the motorways and the routes draw at
	# every zoom.
	Style : { color : Color.Rgba, alpha : F32, width : F32, appear : F32, full : F32 }

	style : U8 -> Style
	style = |kind|
		if (kind == 0) { color: Theme.ctl_c, alpha: 150.0, width: 1.4, appear: Geo.max_mpp, full: Geo.max_mpp }
		else if (kind == 1) { color: Theme.ink_faint, alpha: 85.0, width: 1.0, appear: 24.0, full: 10.0 }
		else if (kind == 2) { color: Theme.atl_c, alpha: 110.0, width: 1.0, appear: 24.0, full: 10.0 }
		else if (kind == 3) { color: Theme.ink_faint, alpha: 130.0, width: 1.6, appear: Geo.max_mpp, full: Geo.max_mpp }
		else if (kind == 4) { color: Theme.ink_muted, alpha: 150.0, width: 2.4, appear: Geo.max_mpp, full: Geo.max_mpp }
		else { color: Theme.tsb_c, alpha: 190.0, width: 1.6, appear: Geo.max_mpp, full: Geo.max_mpp }

	# how much of a kind's opacity shows at a zoom: none past where it
	# appears, all of it closer than where it is full, and a straight ramp
	# between
	fade : Style, F32 -> F32
	fade = |s, mpp|
		if mpp >= s.appear and s.appear < Geo.max_mpp {
			0.0
		} else if mpp <= s.full or s.appear <= s.full {
			1.0
		} else {
			(s.appear - mpp) / (s.appear - s.full)
		}

	# past this zoom a line draws from its far list, whose forty-metre
	# spacing is under five pixels
	far_mpp : F32
	far_mpp = 8.0

	# what each mode paints into the cached picture. A line wholly outside
	# the rectangle or faded out is skipped, and a point closer than a pixel
	# to the last one drawn adds nothing. The base map goes first, in the kind
	# order the load sorted it into. Routes mode draws the routes over it in
	# the accent; play draws them in runs of their speed bands; heat draws
	# none here, its passes being summed into a texture of their own
	# (paint_heat!), unless the window could not build that texture, when it
	# draws them as routes mode does.
	paint! : Ui.Model, Geo.Cam, Draw.Frame => {}
	paint! = |model, c, frame| {
		r = rect(model.win)
		List.for_each!(
			model.map.ways,
			|l| {
				s = style(l.kind)
				k = fade(s, c.mpp)
				if k > 0.0 and Geo.visible(c, r, l.box) {
					a = (F32.round_to_u64_try(s.alpha * k)) ?? 0
					frame.line_strip!({ points: Geo.strip(c, r, if (c.mpp > far_mpp) l.far else l.pts, 1.0), stroke: Draw.stroke(Color.with_alpha(s.color, U64.to_u8_wrap(a)), s.width) })
				}
			},
		)
		if model.view == 12 {
			paint_speed!(model, c, frame)
		} else if model.view != 11 or !(heat_ready(model)) {
			s = style(Db.route_kind)
			paint_routes!(model, c, Color.with_alpha(s.color, 190), s.width, frame)
		}
	}

	# every route the camera shows in one colour and width
	paint_routes! : Ui.Model, Geo.Cam, Color.Rgba, F32, Draw.Frame => {}
	paint_routes! = |model, c, color, width, frame| {
		r = rect(model.win)
		List.for_each!(
			model.map.routes,
			|l|
				if Geo.visible(c, r, l.box) {
					frame.line_strip!({ points: Geo.strip(c, r, if (c.mpp > far_mpp) l.far else l.pts, 1.0), stroke: Draw.stroke(color, width) })
				},
		)
	}

	# the samples either side of a segment its speed is smoothed over
	speed_reach : U64
	speed_reach = 3

	# every route the camera shows, in runs of its speed bands against its own
	# moving speed
	paint_speed! : Ui.Model, Geo.Cam, Draw.Frame => {}
	paint_speed! = |model, c, frame| {
		r = rect(model.win)
		List.for_each!(
			model.map.routes,
			|l|
				if Geo.visible(c, r, l.box) {
					wide = c.mpp > far_mpp
					pts = if (wide) l.far else l.pts
					ts = if (wide) l.fts else l.ts
					runs = Motion.runs(pts, Motion.speeds(pts, ts, speed_reach), Motion.moving_speed(l.far, l.fts))
					List.for_each!(runs, |run| frame.line_strip!({ points: Geo.strip(c, r, run.pts, 1.0), stroke: Draw.stroke(Color.with_alpha(Motion.band_colour(run.band), 220), 2.0) }))
				},
		)
	}

	# a route's ink in the heat texture: one 255th of white, so each segment
	# drawn with added colours adds one count to every pixel it covers
	heat_ink : Color.Rgba
	heat_ink = Color.rgba(1, 1, 1, 255)

	heat_width : F32
	heat_width = 2.0

	# the heat texture's passes, to be drawn with added colours into a
	# cleared texture
	paint_heat! : Ui.Model, Geo.Cam, Draw.Frame => {}
	paint_heat! = |model, c, frame| paint_routes!(model, c, heat_ink, heat_width, frame)

	heat_ready : Ui.Model -> Bool
	heat_ready = |model|
		match model.map_heat {
			Ready(_) => Bool.True
			_ => Bool.False
		}

	# the route seconds the longest route lasts, the length of a playback
	# cycle before its rest
	longest : Ui.Model -> F32
	longest = |model| List.fold(model.map.routes, 0.0, |m, l| F32.max(m, (List.last(l.ts)) ?? 0.0))

	# One marker per route at the playback time, drawn every frame over the
	# cached picture, which playback never repaints: a route still under way
	# in white with a halo, one already finished dimmed at its end.
	draw_markers! : Ui.Model, Geo.Cam, Draw.Frame => {}
	draw_markers! = |model, c, frame| {
		r = rect(model.win)
		t = Motion.play_time(model.map_play.secs, longest(model))
		List.for_each!(
			model.map.routes,
			|l| {
				s = Geo.to_screen(c, r, Motion.at_time(l.pts, l.ts, t))
				if s.x >= r.x and s.x <= r.x + r.w and s.y >= r.y and s.y <= r.y + r.h {
					if t < ((List.last(l.ts)) ?? 0.0) {
						frame.circle!({ center: s, radius: 5.0, style: Draw.filled(Color.with_alpha(Theme.tsb_c, 70)) })
						frame.circle!({ center: s, radius: 2.4, style: Draw.filled(Color.white) })
					} else {
						frame.circle!({ center: s, radius: 2.0, style: Draw.filled(Color.with_alpha(Theme.ink_faint, 150)) })
					}
				}
			},
		)
	}

	# the credit sits on the title row over the map's right edge, after its
	# copyright mark: a ring with its letter inside, drawn, because the brand
	# atlases carry ASCII alone
	credit_y : F32
	credit_y = 74.0

	credit_ring : { w : F32, h : F32 }, Scene.Measure -> Labels.Rect
	credit_ring = |win, measure| {
		r = rect(win)
		w = measure(credit_text, 11.0, Prose)
		{ x: r.x + r.w - w - 18.0, y: credit_y, w: 13.0, h: 13.0 }
	}

	# a failed read's message, cut to what the map's narrowest width holds
	clip : Str -> Str
	clip = |s| if (Str.count_utf8_bytes(s) > 96) Str.concat(Str.from_utf8_lossy(List.take_first(Str.to_utf8(s), 93)), "...") else s
	# ── every string the view writes, placed ───────────────────────────────
	scene : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	scene = |model, measure| Labels.place(texts(model, measure), { boxes: Chrome.boxes(model, measure), segs: [] })

	# the view's text and the chrome's, as the gate judges them
	owned : Ui.Model, Scene.Measure -> List(Labels.Owned)
	owned = |model, measure| List.concat(Scene.owned(Chrome.placed(model, measure)), Scene.owned(scene(model, measure)))

	texts : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	texts = |model, measure| {
		panel = Labels.panel(model.win)
		r = rect(model.win)
		ring = credit_ring(model.win, measure)
		fix = |it, x, y, align, region| Scene.fixed(measure, it, { x, y, align }, region)
		note =
			if model.map.err != "" {
				[fix(Scene.prose(clip(model.map.err), 13.0, Theme.alarm_c), r.x + 14.0, r.y + 14.0, Left, r)]
			} else if loading(model) and List.is_empty(model.map.routes) {
				[fix(Scene.prose(loading_text, 13.0, Theme.ink_muted), r.x + 14.0, r.y + 14.0, Left, r)]
			} else if List.is_empty(model.map.routes) {
				[fix(Scene.prose(no_routes_text, 13.0, Theme.ink_muted), r.x + 14.0, r.y + 14.0, Left, r)]
			} else if List.is_empty(model.map.ways) and model.view != 12 {
				[fix(Scene.prose(no_base_text, 13.0, Theme.ink_muted), r.x + 14.0, r.y + 14.0, Left, r)]
			} else {
				[]
			}
		List.join([
			[
				fix(Scene.prose(title_text(model.view), 15.0, Theme.ink_muted), title_x, 70.0, Left, panel),
				fix(Scene.prose(credit_text, 11.0, Theme.ink_faint), r.x + r.w, credit_y, Right, panel),
				fix(Scene.data("c", 9.0, Theme.ink_faint), ring.x + ring.w / 2.0, ring.y + 2.0, Center, ring),
				fix(Scene.prose(hint_text(model.view), 13.0, Theme.ink_faint), 36.0, model.win.h - 30.0, Left, panel),
			],
			note,
			if (model.view == 12 and List.is_empty(note)) [fix(Scene.data(clock_text(Motion.play_time(model.map_play.secs, longest(model))), 12.0, Theme.ink_muted), r.x + 14.0, r.y + 14.0, Left, r)] else [],
			chip_texts(model, measure),
		])
	}

	# the shapes no text may cover but its own: the pills, the mode chips,
	# the map and the copyright ring
	marks : Ui.Model, Scene.Measure -> List(Labels.Mark)
	marks = |model, measure| {
		r = rect(model.win)
		List.join([Chrome.marks(model), chip_marks, [{ key: "the map", box: r }, { key: "the copyright ring", box: credit_ring(model.win, measure) }]])
	}

	# The cached picture when the window holds one, shifted by however far
	# the camera has moved since it was painted, else every line drawn
	# straight to the frame. In heat mode the summed passes follow, through
	# the tone-mapping shader, with the same shift; in play the markers
	# follow, placed this frame. The scissor keeps all of it inside the
	# map's rectangle; it takes screen pixels, so the logical rectangle is
	# scaled by the UI size.
	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		r = rect(model.win)
		c = cam(model)
		measure = Scene.measure_of(model)
		draw_chips!(model, frame)
		frame.rounded_rectangle!({ x: r.x, y: r.y, width: r.w, height: r.h, radius: 10.0, segments: 8, style: Draw.filled(Theme.card) })
		sc = model.ui_scale
		px = { x: r.x * sc, y: r.y * sc, width: r.w * sc, height: r.h * sc }
		off = Geo.to_screen(c, r, Geo.to_world(model.map_painted, r, r.x, r.y))
		dest = { x: off.x - r.x, y: off.y - r.y, width: model.win.w, height: model.win.h }
		_ = frame.with_scissor!(
			px,
			|f| {
				match model.map_rt {
					Target(t) => f.texture!({ texture: t.rt.texture(), source: t.rt.source(), dest, origin: { x: 0.0, y: 0.0 }, rotation: 0.0, tint: Color.white })
					_ => paint!(model, c, f)
				}
				if model.view == 11 {
					match model.map_heat {
						Ready(h) => {
							_ = f.with_shader!(
								h.shader,
								|f2| {
									f2.texture!({ texture: h.rt.texture(), source: h.rt.source(), dest, origin: { x: 0.0, y: 0.0 }, rotation: 0.0, tint: Color.white })
									Ok({})
								},
							)
							{}
						}
						_ => {}
					}
				}
				if model.view == 12 {
					draw_markers!(model, c, f)
				}
				Ok({})
			},
		)
		ring = credit_ring(model.win, measure)
		frame.circle!({ center: { x: ring.x + ring.w / 2.0, y: ring.y + ring.h / 2.0 }, radius: ring.w / 2.0, style: Draw.outlined(Theme.ink_faint, 1.0) })
		Scene.draw!(frame, model, scene(model, measure))
		Ok({})
	}
}

# the map sits inside the panel, under the title row and above the hint row
expect {
	r = Map.rect({ w: 980.0, h: 600.0 })
	r.x == 36.0 and r.y == 96.0 and r.w == 908.0 and r.h == 456.0
}

# streets and cycleways are gone at the wide zooms, ramp in between, and
# are fully drawn close in
expect List.all([1, 2], |k| Map.fade(Map.style(k), 30.0) == 0.0 and Map.fade(Map.style(k), 8.0) == 1.0 and Map.fade(Map.style(k), 17.0) > 0.4 and Map.fade(Map.style(k), 17.0) < 0.6)

# water, the arterials, the motorways and the routes draw at every zoom
expect List.all([0, 3, 4, Db.route_kind], |k| Map.fade(Map.style(k), Geo.max_mpp) == 1.0 and Map.fade(Map.style(k), Geo.min_mpp) == 1.0)

# the three modes are the map, light its pill, and a click on that pill keeps
# the mode on screen while from elsewhere it opens the routes
expect List.all([10, 11, 12], Map.is_map) and !(Map.is_map(9)) and !(Map.is_map(13)) and Map.group(12) == 10 and Map.group(8) == 8 and Map.from_pill(10, 11) == 11 and Map.from_pill(10, 4) == 10 and Map.from_pill(6, 12) == 6

# a click on a chip picks its mode, and one beside the chips or off their row picks none
expect Map.mode_at(Map.chip_x(1) + 10.0, 70.0) == 11 and Map.mode_at(Map.chip_x(2) + 1.0, 80.0) == 12 and Map.mode_at(Map.chip_x(0) + Map.chip_w + 2.0, 70.0) == -1 and Map.mode_at(Map.chip_x(0) + 10.0, 90.0) == -1

# the clock reads hours and minutes into each session
expect Map.clock_text(0.0) == "0:00 into each session" and Map.clock_text(3725.0) == "1:02 into each session" and Map.clock_text(599.0) == "0:09 into each session"

# each mode titles itself, and only playback offers P
expect Map.title_text(11) != Map.title_text(10) and Map.title_text(12) != Map.title_text(10) and Str.starts_with(Map.hint_text(12), "P  pause") and !(Str.contains(Map.hint_text(10), "P  pause"))

# playback's title states the speed-up the clock runs at
expect Str.contains(Map.title_text(12), "an hour in ${U64.to_str((F32.round_to_u64_try(3600.0 / Motion.speedup)) ?? 0)} seconds") and Str.contains(Map.title_text(12), "an hour in 30 seconds")
