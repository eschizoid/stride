import rr.Color
import rr.Draw
import Chrome
import Db
import Geo
import Labels
import Motion
import Mvt
import Scene
import Theme
import Tiles
import Ui

Map :: [].{
	# The map view: every GPS session drawn over the street map, in Web
	# Mercator, north up. Drag pans, the wheel zooms at the cursor, and `0`
	# returns to the opening view (Geo.opening). The street map is
	# OpenFreeMap's vector tiles of OpenStreetMap's data in the OpenMapTiles
	# schema, fetched as the view needs them and cached (Tiles). The view
	# shows no attribution of them.

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

	no_routes_text : Str
	no_routes_text = "no GPS routes yet - stride sync fetches one per outdoor session"

	fetching_text : Str
	fetching_text = "fetching the street map from OpenFreeMap..."

	no_base_text : Str
	no_base_text = "no street map here yet - it is fetched from OpenFreeMap once the network answers"

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

	# how each kind draws, by Mvt.line_kinds' codes: its colour and opacity,
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

	# the fills' colours: the theme's blue for water and, for parks, a green
	# of the map's own, apart from every sport's and zone's colour, each laid
	# over the map's ground at a fixed strength and opaque, so where
	# neighbouring tiles meet nothing shows doubled
	park_hue : Color.Rgba
	park_hue = Color.from_hex_rgb(0x6abf69)

	over : Color.Rgba, Color.Rgba, F32 -> Color.Rgba
	over = |ground, hue, t| {
		mix = |a, b| U64.to_u8_wrap((F32.round_to_u64_try(U8.to_f32(a) * (1.0 - t) + U8.to_f32(b) * t)) ?? 0)
		Color.rgba(mix(ground.r, hue.r), mix(ground.g, hue.g), mix(ground.b, hue.b), 255)
	}

	fill_colour : U8 -> Color.Rgba
	fill_colour = |k| if (k == Mvt.water_fill) over(Theme.card, Theme.ctl_c, 0.26) else over(Theme.card, park_hue, 0.14)

	# the tiles the camera shows, at the zoom its scale needs (Tiles.view)
	cells : Ui.Model, Geo.Cam -> List(Tiles.Cell)
	cells = |model, c| (Tiles.view(c, rect(model.win), model.map.origin)).cells

	# whether the map has anything to show, and so any tile to fetch: a
	# route with GPS
	has_data : Ui.Model -> Bool
	has_data = |model| !(List.is_empty(model.map.routes))

	# whether any tile of the view, its own or an ancestor's, is drawn
	tiles_shown : Ui.Model, Geo.Cam -> Bool
	tiles_shown = |model, c| List.any(cells(model, c), |cell| Tiles.shown(model.map_tiles, cell).is_ok())

	# whether the view's tiles have all had their answer (Tiles.settled); a
	# map with nothing to show fetches none and is settled at once
	tiles_settled : Ui.Model -> Bool
	tiles_settled = |model| !(has_data(model)) or Tiles.settled(model.map_tiles, cells(model, cam(model)), model.map_source)

	# whether a tile of the view is still on its way: a task is reading it,
	# or it waits on a source not yet read
	fetching : Ui.Model -> Bool
	fetching = |model|
		has_data(model) and List.any(
			cells(model, cam(model)),
			|cell|
				match List.find_first(model.map_tiles, |s| s.key == cell.key) {
					Err(_) => Bool.True
					Ok(s) =>
						match s.state {
							Fetching => Bool.True
							Waiting =>
								match model.map_source {
									Unreachable(_) => Bool.False
									_ => Bool.True
								}
							_ => Bool.False
						}
				},
		)

	# what the map says of its street map when none of it is on screen:
	# that it is on its way, or, once nothing more is coming, that there is
	# none here yet; nothing while any tile draws, or in playback, whose
	# clock holds that corner
	base_note : Ui.Model -> Str
	base_note = |model|
		if model.view == 12 or tiles_shown(model, cam(model)) {
			""
		} else if fetching(model) {
			fetching_text
		} else {
			no_base_text
		}

	# One tile drawn at its place: its fills, then its lines in kind
	# order, a line faded out at this zoom skipped and a point closer than a
	# pixel to the last one kept adding nothing.
	draw_tile! : Draw.Frame, Mvt.Tile, Tiles.Place, F32 => {}
	draw_tile! = |frame, t, at, mpp| {
		to = |p| { x: at.x + p.x * at.k, y: at.y + p.y * at.k }
		List.for_each!(t.fills, |f| frame.triangles!({ points: List.map(f.tris, to), color: fill_colour(f.kind) }))
		List.for_each!(
			t.lines,
			|l| {
				s = style(l.kind)
				k = fade(s, mpp)
				if k > 0.0 {
					a = (F32.round_to_u64_try(s.alpha * k)) ?? 0
					frame.line_strip!({ points: Geo.thin(List.map(l.pts, to), 1.0), stroke: Draw.stroke(Color.with_alpha(s.color, U64.to_u8_wrap(a)), s.width) })
				}
			},
		)
	}

	# a cell's square in the picture's pixels, cut to the map's rectangle,
	# its edges pushed out to whole pixels so that neighbouring squares meet
	# with no gap between them
	cut : Tiles.Place, Geo.Rect, F32 -> Try({ x : F32, y : F32, width : F32, height : F32 }, [Outside])
	cut = |p, r, sc| {
		side = p.k * Mvt.extent_units
		x0 = F32.max(p.x, r.x) * sc
		y0 = F32.max(p.y, r.y) * sc
		x1 = F32.min(p.x + side, r.x + r.w) * sc
		y1 = F32.min(p.y + side, r.y + r.h) * sc
		fx = F32.div_floor_by(x0, 1.0)
		fy = F32.div_floor_by(y0, 1.0)
		if (x1 <= x0 or y1 <= y0) Err(Outside) else Ok({ x: fx, y: fy, width: 0.0 - F32.div_floor_by(0.0 - x1, 1.0) - fx, height: 0.0 - F32.div_floor_by(0.0 - y1, 1.0) - fy })
	}

	# Every cell of the view draws its own tile or, until that lands, its
	# nearest drawn ancestor's scaled up (Tiles.shown). When `squared`, as
	# in the picture, each is cut to its cell's square, so a coarse stand-in
	# never spills over a neighbour already sharp and the buffer every tile
	# carries past its edge never draws twice. Otherwise the view is drawing
	# straight to the frame inside the map's own scissor, which a second
	# scissor would replace rather than narrow, so each tile shown draws
	# once, whole.
	paint_tiles! : Ui.Model, Geo.Cam, Bool, Draw.Frame => {}
	paint_tiles! = |model, c, squared, frame| {
		r = rect(model.win)
		o = model.map.origin
		shown = List.keep_oks(cells(model, c), |cell| Tiles.shown(model.map_tiles, cell).map_ok(|s| { cell, s }))
		if squared {
			List.for_each!(
				shown,
				|e|
					match cut(Tiles.place(c, r, o, e.cell.key.z, e.cell.col, U64.to_i64_wrap(e.cell.key.y)), r, model.ui_scale) {
						Ok(px) => {
							_ = frame.with_scissor!(
								px,
								|f| {
									draw_tile!(f, e.s.tile, Tiles.place(c, r, o, e.s.z, e.s.col, e.s.row), c.mpp)
									Ok({})
								},
							)
							{}
						}
						Err(_) => {}
					},
			)
		} else {
			once = List.fold(shown, [], |acc, e| if (List.any(acc, |x| x.z == e.s.z and x.col == e.s.col and x.row == e.s.row)) acc else List.append(acc, e.s))
			List.for_each!(once, |s| draw_tile!(frame, s.tile, Tiles.place(c, r, o, s.z, s.col, s.row), c.mpp))
		}
	}

	# what each mode paints into the cached picture. The street map goes
	# first, the view's tiles. Routes mode draws the routes over it in the
	# accent; play draws them in strips coloured by speed band
	# (paint_speed!); heat draws none here, its passes being summed into a
	# texture of their own (paint_heat!), unless the window could not build
	# that texture, when it draws them as routes mode does.
	paint! : Ui.Model, Geo.Cam, Bool, Draw.Frame => {}
	paint! = |model, c, squared, frame| {
		paint_tiles!(model, c, squared, frame)
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

	# every route the camera shows, in strips of one speed band each from
	# the bands of the list this zoom draws (Motion.strips)
	paint_speed! : Ui.Model, Geo.Cam, Draw.Frame => {}
	paint_speed! = |model, c, frame| {
		r = rect(model.win)
		wide = c.mpp > far_mpp
		List.for_each!(
			model.map.routes,
			|l|
				if Geo.visible(c, r, l.box) {
					ss = if (wide) Motion.strips(l.far, l.fbands, |p| Geo.to_screen(c, r, p), 1.0) else Motion.strips(l.pts, l.bands, |p| Geo.to_screen(c, r, p), 1.0)
					List.for_each!(ss, |s| frame.line_strip!({ points: s.pts, stroke: Draw.stroke(Color.with_alpha(Motion.band_colour(s.band), 220), 2.0) }))
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
	# cycle before its rest: kept beside the speed bands once they are
	# built, so a frame does not walk every route for it
	longest : Ui.Model -> F32
	longest = |model|
		match model.map_speed {
			Built(b) => b.longest
			Unbuilt => longest_of(model.map)
		}

	longest_of : Db.MapData -> F32
	longest_of = |m| List.fold(m.routes, 0.0, |acc, l| F32.max(acc, (List.last(l.ts)) ?? 0.0))

	# A marker is a disc a few pixels across, drawn as a polygon of this many
	# sides rather than raylib's 36, since a frame draws one or two per
	# route; strays bounds how far the polygon departs from its circle.
	halo_sides : I32
	halo_sides = 12

	dot_sides : I32
	dot_sides = 8

	# how far a polygon of n sides departs from its circle of radius r, in
	# pixels at UI scale k: r k (1 - cos x) for x = pi / n, bounded above by
	# r k x^2 / 2
	strays : F32, I32, F32 -> F32
	strays = |r, n, k| {
		x = 3.14159265 / I32.to_f32(n)
		r * k * x * x / 2.0
	}

	disc! : Draw.Frame, Geo.Pt, F32, I32, Color.Rgba => {}
	disc! = |frame, at, radius, sides, color| frame.circle_sector!({ center: at, radius, start_angle: 0.0, end_angle: 360.0, segments: sides, style: Draw.filled(color) })

	# every route's marker at the playback time
	markers : Ui.Model -> List(Motion.Mark)
	markers = |model| {
		t = Motion.play_time(model.map_play.secs, longest(model))
		List.map(model.map.routes, |l| Motion.mark(l.pts, l.ts, t))
	}

	# One marker per route at the playback time, drawn every frame over the
	# cached picture, which playback never repaints: a route still under way
	# in white with a halo, one already finished dimmed at its end. Paused,
	# the markers are the ones the window keeps (Motion.step_marks).
	draw_markers! : Ui.Model, Geo.Cam, Draw.Frame => {}
	draw_markers! = |model, c, frame| {
		r = rect(model.win)
		ms = match model.map_marks {
			Held(kept) => kept
			Stale => markers(model)
		}
		List.for_each!(
			ms,
			|m| {
				s = Geo.to_screen(c, r, m.at)
				if s.x >= r.x and s.x <= r.x + r.w and s.y >= r.y and s.y <= r.y + r.h {
					if m.live {
						disc!(frame, s, 5.0, halo_sides, Color.with_alpha(Theme.tsb_c, 70))
						disc!(frame, s, 2.4, dot_sides, Color.white)
					} else {
						disc!(frame, s, 2.0, dot_sides, Color.with_alpha(Theme.ink_faint, 150))
					}
				}
			},
		)
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
		fix = |it, x, y, align, region| Scene.fixed(measure, it, { x, y, align }, region)
		note =
			if model.map.err != "" {
				[fix(Scene.prose(clip(model.map.err), 13.0, Theme.alarm_c), r.x + 14.0, r.y + 14.0, Left, r)]
			} else if model.map_cache_err != "" {
				[fix(Scene.prose(clip(model.map_cache_err), 13.0, Theme.alarm_c), r.x + 14.0, r.y + 14.0, Left, r)]
			} else if loading(model) and List.is_empty(model.map.routes) {
				[fix(Scene.prose(loading_text, 13.0, Theme.ink_muted), r.x + 14.0, r.y + 14.0, Left, r)]
			} else if List.is_empty(model.map.routes) {
				[fix(Scene.prose(no_routes_text, 13.0, Theme.ink_muted), r.x + 14.0, r.y + 14.0, Left, r)]
			} else if base_note(model) != "" {
				[fix(Scene.prose(base_note(model), 13.0, Theme.ink_muted), r.x + 14.0, r.y + 14.0, Left, r)]
			} else {
				[]
			}
		List.join([
			[
				fix(Scene.prose(title_text(model.view), 15.0, Theme.ink_muted), title_x, 70.0, Left, panel),
				fix(Scene.prose(hint_text(model.view), 13.0, Theme.ink_faint), 36.0, model.win.h - 30.0, Left, panel),
			],
			note,
			if (model.view == 12 and List.is_empty(note)) [fix(Scene.data(clock_text(Motion.play_time(model.map_play.secs, longest(model))), 12.0, Theme.ink_muted), r.x + 14.0, r.y + 14.0, Left, r)] else [],
			chip_texts(model, measure),
		])
	}

	# the shapes no text may cover but its own: the pills, the mode chips and
	# the map
	marks : Ui.Model, Scene.Measure -> List(Labels.Mark)
	marks = |model, _measure| {
		r = rect(model.win)
		List.join([Chrome.marks(model), chip_marks, [{ key: "the map", box: r }]])
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
					_ => paint!(model, c, Bool.False, f)
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

# water and parks fill opaque, each nearer its hue than the ground is
expect {
	w = Map.fill_colour(Mvt.water_fill)
	p = Map.fill_colour(Mvt.park_fill)
	w.a == 255 and p.a == 255 and w.b > Theme.card.b and p.g > Theme.card.g and w != p
}

# a cell's square cut to the map, its edges pushed out to whole pixels, and
# one wholly outside the map cut to nothing
expect {
	r = { x: 36.0, y: 96.0, w: 908.0, h: 456.0 }
	inside = Map.cut({ x: 100.25, y: 120.5, k: 0.1 }, r, 1.5)
	off = Map.cut({ x: 2000.0, y: 120.5, k: 0.1 }, r, 1.5)
	match inside {
		Ok(px) => px.x == 150.0 and px.y == 180.0 and px.x + px.width >= (100.25 + 409.6) * 1.5 and px.x + px.width < (100.25 + 409.6) * 1.5 + 1.0 and off == Err(Outside)
		Err(_) => Bool.False
	}
}

# the parks' green is the map's own: no sport and no zone wears it
expect !(List.contains(Theme.sport_palette, Map.park_hue)) and !(List.contains(Theme.zone_ramp, Map.park_hue))
