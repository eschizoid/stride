import rr.Camera
import rr.Color
import rr.Draw
import rr.Text
import core.Fmt
import core.Sports
import core.Units
import Chrome
import Db
import Geo
import Labels
import MapNames
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
		if (v == 12) "P  pause      click  session      drag  pan      wheel  zoom      0  home      TAB  form      S  screenshot      ESC quit"
		else "click  session      drag  pan      wheel  zoom      0  home      TAB  form      R  reload      S  screenshot      ESC quit"

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
	# nearest drawn ancestor's scaled up (Tiles.shown). Squared, as in the
	# picture, each is cut to its cell's square, its scissor in the
	# target's pixels at `k` of them to a logical unit, so a coarse
	# stand-in never spills over a neighbour already sharp and the buffer
	# every tile carries past its edge never draws twice. Whole, the view
	# is drawing straight to the frame inside the map's own scissor, which
	# a second scissor would replace rather than narrow, so each tile shown
	# draws once, whole.
	paint_tiles! : Ui.Model, Geo.Cam, [Whole, Squared(F32)], Draw.Frame => {}
	paint_tiles! = |model, c, how, frame| {
		r = rect(model.win)
		o = model.map.origin
		shown = List.keep_oks(cells(model, c), |cell| Tiles.shown(model.map_tiles, cell).map_ok(|s| { cell, s }))
		match how {
			Squared(k) =>
				List.for_each!(
					shown,
					|e|
						match cut(Tiles.place(c, r, o, e.cell.key.z, e.cell.col, U64.to_i64_wrap(e.cell.key.y)), r, k) {
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
			Whole => {
				once = List.fold(shown, [], |acc, e| if (List.any(acc, |x| x.z == e.s.z and x.col == e.s.col and x.row == e.s.row)) acc else List.append(acc, e.s))
				List.for_each!(once, |s| draw_tile!(frame, s.tile, Tiles.place(c, r, o, s.z, s.col, s.row), c.mpp))
			}
		}
	}

	# What each mode paints, straight to the frame when the window holds
	# no picture. The street map goes first, the view's tiles, then the
	# street map's names over them (names), then the routes over both.
	# Routes mode draws the routes in the accent; play draws them in strips
	# coloured by speed band (paint_speed!); heat draws none here, its
	# passes being summed into a texture of their own (paint_heat!) and
	# drawn over the picture, unless the window could not build that
	# texture, when it draws them as routes mode does.
	paint! : Ui.Model, Geo.Cam, Draw.Frame => {}
	paint! = |model, c, frame| {
		paint_tiles!(model, c, Whole, frame)
		draw_names!(frame, model, model.ui_scale, names(model, c, Scene.measure_of(model)))
		paint_over!(model, c, frame)
	}

	# The picture itself, the same three layers. It is held in the
	# framebuffer's own pixels, which a HiDPI display packs more of into a
	# logical unit than the window's size counts, so its lines and names
	# are drawn as sharp as the text the view draws straight to the screen:
	# `k`, the target's pixels to a logical unit, is the camera's zoom. The
	# tiles and the routes are each drawn under that camera and each name
	# under a camera of its own that turns it about its centre at that
	# zoom, so no camera is opened inside another. The picture starts
	# transparent and is laid over the map's ground, so a glyph's edge
	# covering a share a of a pixel, blended the usual way, would land in
	# it as its colour times a with alpha a squared and show at a cubed,
	# far dimmer than the same text drawn on the ground. Through the
	# picture's text shader the names are blended with premultiplied alpha
	# instead: each pixel is stored as its colour times a with alpha a over
	# the transparent ground, and blended the usual way over a fill, so a
	# name shows as the window's other text does.
	paint_picture! : Ui.Model, Draw.Frame => {}
	paint_picture! = |model, frame|
		match model.map_rt {
			Target(t) => {
				k = picture_zoom(t.w, model.win.w, model.ui_scale)
				zoom = Camera.default.with_zoom(k)
				c = model.map_painted
				_ = frame.with_camera!(zoom, |g| Ok(paint_tiles!(model, c, Squared(k), g)))
				placed = names(model, c, Scene.measure_of(model))
				match t.text {
					Text(shader) => {
						_ = frame.with_blend_mode!(
							AlphaPremultiply,
							|g| g.with_shader!(
								shader,
								|s| {
									draw_names!(s, model, k, placed)
									Ok({})
								},
							),
						)
						{}
					}
					NoText => draw_names!(frame, model, k, placed)
				}
				_ = frame.with_camera!(zoom, |g| Ok(paint_over!(model, c, g)))
				{}
			}
			_ => {}
		}

	# the picture's pixels to a logical unit: its width over the window's
	# logical width, or the UI scale while the window has none
	picture_zoom : F32, F32, F32 -> F32
	picture_zoom = |target_w, win_w, ui_scale| if (win_w > 0.0) target_w / win_w else ui_scale

	# the fragment shader that premultiplies a name's colour by its
	# coverage, scaled by `gain`
	text_frag : Str
	text_frag = Str.join_with(
		[
			"#version 330",
			"in vec2 fragTexCoord;",
			"in vec4 fragColor;",
			"uniform sampler2D texture0;",
			"uniform float gain;",
			"out vec4 finalColor;",
			"void main() {",
			"    vec4 t = texture(texture0, fragTexCoord) * fragColor;",
			"    float a = t.a * gain;",
			"    finalColor = vec4(t.rgb * a, a);",
			"}",
		],
		"\n",
	)

	paint_over! : Ui.Model, Geo.Cam, Draw.Frame => {}
	paint_over! = |model, c, frame| {
		if model.view == 12 {
			paint_speed!(model, c, frame)
		} else if model.view != 11 or !(heat_ready(model)) {
			s = style(Db.route_kind)
			paint_routes!(model, c, Color.with_alpha(s.color, 190), s.width, frame)
		}
	}

	# ── the street map's names ─────────────────────────────────────────────
	# Every name of the tiles the view shows (each tile once, a coarse
	# stand-in included) that its zoom shows, on screen, placed by
	# MapNames clear of the routes and held off everything the view writes:
	# the chrome, the title, the chips, the hint and the note in the map's
	# corner, which in playback is the clock at the longest it reads, since
	# the clock ticks while the picture holds still.
	names : Ui.Model, Geo.Cam, Scene.Measure -> List(Labels.Placed(MapNames.Item))
	names = |model, c, measure| {
		runs = name_runs(model, c)
		if List.is_empty(runs) {
			[]
		} else {
			r = rect(model.win)
			g = MapNames.grid(r, route_lines(model, c), |p| Geo.to_screen(c, r, p))
			clock = if (model.view == 12) [{ x: r.x + 14.0, y: r.y + 14.0, w: measure(clock_text(longest(model)), 12.0, Data), h: 12.0 }] else []
			held = List.join([Chrome.boxes(model, measure), List.map(scene(model, measure), |p| p.box), clock])
			MapNames.place(runs, c.mpp, measure, r, g, { boxes: held, segs: [] })
		}
	}

	name_runs : Ui.Model, Geo.Cam -> List(MapNames.Run)
	name_runs = |model, c| {
		r = rect(model.win)
		o = model.map.origin
		shown = List.keep_oks(cells(model, c), |cell| Tiles.shown(model.map_tiles, cell))
		once = List.fold(shown, [], |acc, s| if (List.any(acc, |x| x.z == s.z and x.col == s.col and x.row == s.row)) acc else List.append(acc, s))
		List.join(
			List.map(
				once,
				|s| {
					at = Tiles.place(c, r, o, s.z, s.col, s.row)
					List.keep_oks(s.tile.names, |n| if (MapNames.shows(n.kind, c.mpp)) Ok({ kind: n.kind, rank: n.rank, text: n.text, pts: List.map(n.pts, |p| { x: at.x + p.x * at.k, y: at.y + p.y * at.k }) }) else Err(Hidden))
				},
			),
		)
	}

	# every route the camera shows, in projected metres, from the list a
	# repaint at this zoom draws
	route_lines : Ui.Model, Geo.Cam -> List(List(Geo.Pt))
	route_lines = |model, c| {
		r = rect(model.win)
		List.keep_oks(model.map.routes, |l| if (Geo.visible(c, r, l.box)) Ok(if (c.mpp > far_mpp) l.far else l.pts) else Err(Hidden))
	}

	# each name centred in its placed box and turned about its centre, at
	# `sc` target pixels to a logical unit, over a halo of the map's ground,
	# the text drawn a pixel off each way, so the streets under it do not
	# run through its letters
	draw_names! : Draw.Frame, Ui.Model, F32, List(Labels.Placed(MapNames.Item)) => {}
	draw_names! = |frame, model, sc, placed| {
		List.for_each!(
			placed,
			|p| {
				at = { x: p.box.x + p.box.w / 2.0, y: p.box.y + p.box.h / 2.0 }
				turn = Camera.default.with_target(at).with_offset({ x: at.x * sc, y: at.y * sc }).with_rotation(p.item.angle).with_zoom(sc)
				x = at.x - p.item.w / 2.0
				y = at.y - p.item.item.size / 2.0
				t = Text.from(p.item.item.text, model.prose).size(p.item.item.size)
				_ = frame.with_camera!(
					turn,
					|f| {
						List.for_each!(halo, |d| t.draw!(f, { pos: { x: x + d.x, y: y + d.y }, color: Theme.card, align: (Top, Left) }))
						t.draw!(f, { pos: { x, y }, color: p.item.item.color, align: (Top, Left) })
						Ok({})
					},
				)
				{}
			},
		)
	}

	halo : List({ x : F32, y : F32 })
	halo = [{ x: -1.0, y: 0.0 }, { x: 1.0, y: 0.0 }, { x: 0.0, y: -1.0 }, { x: 0.0, y: 1.0 }]

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

	# ── a click on a route, and the card it opens ──────────────────────────
	# A click is a press on the map and its release with the cursor never
	# farther than slop_px from where the press began, on either axis; a
	# press that strays farther is a drag, which pans and never clicks. A
	# click picks the routes the zoom draws within hit_px of it, in logical
	# pixels at every zoom, and of those the session that started last,
	# then the higher id. The pick opens a card for that session over the
	# map, anchored where the click landed, and its route draws highlighted
	# while the card is up. Every mode takes the same click: the hit test is
	# geometry, and heat and play draw the same routes. A click on the card,
	# or Enter, opens the trace view on the session; Esc or a click that
	# picks nothing closes the card.
	slop_px : F32
	slop_px = 4.0

	hit_px : F32
	hit_px = 5.0

	# one frame of the map's press: a press begins on the map, follows the
	# cursor while the button is held, and on its release is a click at the
	# last place it was held, unless it strayed
	press_step : Ui.MapPress, { down : Bool, pressed : Bool, on_map : Bool, x : F32, y : F32 } -> { press : Ui.MapPress, click : Try(Geo.Pt, [NoClick]) }
	press_step = |p, i|
		match p {
			Held(h) => {
				far = h.far or (i.x - h.ox).abs() > slop_px or (i.y - h.oy).abs() > slop_px
				if i.down {
					{ press: Held({ x: i.x, y: i.y, ox: h.ox, oy: h.oy, far }), click: Err(NoClick) }
				} else if far {
					{ press: Idle, click: Err(NoClick) }
				} else {
					{ press: Idle, click: Ok({ x: h.x, y: h.y }) }
				}
			}
			Idle => if (i.down and i.pressed and i.on_map) { press: Held({ x: i.x, y: i.y, ox: i.x, oy: i.y, far: Bool.False }), click: Err(NoClick) } else { press: Idle, click: Err(NoClick) }
		}

	on_map : { w : F32, h : F32 }, F32, F32 -> Bool
	on_map = |win, x, y| {
		r = rect(win)
		x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
	}

	# the point of segment a-b nearest p
	nearest : Geo.Pt, Geo.Pt, Geo.Pt -> Geo.Pt
	nearest = |a, b, p| {
		dx = b.x - a.x
		dy = b.y - a.y
		len2 = dx * dx + dy * dy
		t = if (len2 <= 0.0) 0.0 else F32.min(1.0, F32.max(0.0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
		{ x: a.x + t * dx, y: a.y + t * dy }
	}

	# whether a segment of the line from index i on passes within tol of w
	# at a point inside the view's extent, so a stretch the map's edge cuts
	# away is never picked
	passes : List(Geo.Pt), U64, Geo.Pt, F32, Geo.Bounds -> Bool
	passes = |pts, i, w, tol, view|
		match (List.get(pts, i - 1), List.get(pts, i)) {
			(Ok(a), Ok(b)) => {
				q = nearest(a, b, w)
				if (q.x - w.x) * (q.x - w.x) + (q.y - w.y) * (q.y - w.y) <= tol * tol and q.x >= view.x0 and q.x <= view.x1 and q.y >= view.y0 and q.y <= view.y1 {
					Bool.True
				} else {
					passes(pts, i + 1, w, tol, view)
				}
			}
			_ => Bool.False
		}

	# the session whose route a click at (sx, sy) picks, among the lines the
	# camera's zoom draws; a click off the map picks none
	hit : List(Db.MapLine), Geo.Cam, Geo.Rect, F32, F32 -> Try(Db.RouteSession, [Miss])
	hit = |routes, c, r, sx, sy|
		if sx < r.x or sx > r.x + r.w or sy < r.y or sy > r.y + r.h {
			Err(Miss)
		} else {
			w = Geo.to_world(c, r, sx, sy)
			tol = hit_px * c.mpp
			lo = Geo.to_world(c, r, r.x, r.y + r.h)
			hi = Geo.to_world(c, r, r.x + r.w, r.y)
			view = { x0: lo.x, y0: lo.y, x1: hi.x, y1: hi.y }
			wide = c.mpp > far_mpp
			List.fold(
				routes,
				Err(Miss),
				|best, l| {
					b = l.box
					near = w.x >= b.x0 - tol and w.x <= b.x1 + tol and w.y >= b.y0 - tol and w.y <= b.y1 + tol
					later = match best {
						Ok(s) => l.session.start > s.start or (l.session.start == s.start and l.session.id > s.id)
						Err(_) => Bool.True
					}
					if (near and later and passes(if (wide) l.far else l.pts, 1, w, tol, view)) Ok(l.session) else best
				},
			)
		}

	# the route of the session the card is up for, on a map mode
	picked : Ui.Model -> Try(Db.MapLine, [NoCard])
	picked = |model|
		match model.map_card {
			Open(o) =>
				if is_map(model.view) {
					match List.find_first(model.map.routes, |l| l.session.id == o.id) {
						Ok(l) => Ok(l)
						Err(_) => Err(NoCard)
					}
				} else {
					Err(NoCard)
				}
			Closed => Err(NoCard)
		}

	# the selected route drawn over every mode's picture: a dark casing under
	# a white line, so it reads over the accent, the heat and the speed ramp
	draw_picked! : Ui.Model, Geo.Cam, Draw.Frame => {}
	draw_picked! = |model, c, frame|
		match picked(model) {
			Ok(l) => {
				pts = Geo.strip(c, rect(model.win), if (c.mpp > far_mpp) l.far else l.pts, 1.0)
				frame.line_strip!({ points: pts, stroke: Draw.stroke(Color.with_alpha(Theme.bg, 200), 5.0) })
				frame.line_strip!({ points: pts, stroke: Draw.stroke(Color.white, 2.4) })
			}
			Err(_) => {}
		}

	# the card's text: the name, the sport and day, the distance, moving
	# time and effort, and what the athlete can do next
	CardLine : { text : Str, size : F32, face : Scene.Face, tone : [Title, Body, Muted] }

	card_lines : Db.RouteSession, [Metric, Imperial], [Ready, Opening, NoTrace] -> List(CardLine)
	card_lines = |s, units, state| {
		title = if (s.name == "") s.sport else s.name
		next = match state {
			Ready => "Enter or click  open its trace      Esc  close"
			Opening => "opening its trace..."
			NoTrace => "no trace to open - its stream holds nothing to plot"
		}
		[
			{ text: title, size: 14.0, face: Prose, tone: Title },
			{ text: "${s.sport}   ${s.day}", size: 12.0, face: Data, tone: Body },
			{ text: Str.join_with(List.keep_if([dist_text(s.dist_m, units), time_text(s.moving_s), effort_text(s, units)], |t| t != ""), "   "), size: 12.0, face: Data, tone: Body },
			{ text: next, size: 12.0, face: Prose, tone: Muted },
		]
	}

	dist_text : F64, [Metric, Imperial] -> Str
	dist_text = |m, units|
		if m <= 0.0 {
			"-"
		} else {
			"${Fmt.tenths((Units.dist_value(units, m) * 10.0).round_to_i64_try().ok_or(0))} ${Units.dist_unit(units)}"
		}

	# moving time as hours and minutes, or minutes alone under an hour
	time_text : I64 -> Str
	time_text = |secs|
		if secs <= 0 {
			"-"
		} else {
			mins = (secs + 30) // 60
			h = mins // 60
			mm = mins % 60
			if (h == 0) "${I64.to_str(mm)}m" else "${I64.to_str(h)}h ${if (mm < 10) "0" else ""}${I64.to_str(mm)}m"
		}

	# a pace family reads its pace over the distance it is paced in, the
	# kilometre or mile on foot, 100 m in the water, 500 m on the erg; a
	# session a power meter measured reads its average power; a ride without
	# one says so, since a ride's effort is its power; any other sport has no
	# effort to state, and its slot is left out
	effort_text : Db.RouteSession, [Metric, Imperial] -> Str
	effort_text = |s, units| {
		fam = Sports.canonical(s.sport)
		if List.contains(Sports.pace_target_families, fam) {
			pace =
				if fam == "Swim" or fam == "Rowing" {
					if (s.dist_m <= 0.0 or s.moving_s <= 0) "-" else Fmt.mmss((I64.to_f64(s.moving_s) * I64.to_f64(Sports.pace_unit(fam).dist_m) / s.dist_m).round_to_i64_try().ok_or(0))
				} else {
					Units.pace_per_dist(units, s.dist_m, s.moving_s)
				}
			"${pace} ${Sports.pace_label_for(units, fam)}"
		} else if s.watts > 0 {
			"${I64.to_str(s.watts)} W avg"
		} else if fam == "Ride" {
			"no power meter"
		} else {
			""
		}
	}

	card_pad : F32
	card_pad = 10.0

	card_gap : F32
	card_gap = 5.0

	# the card's box and its lines as fixed text inside it: beside the
	# clicked point, 14 pixels right of it, or left of it when the right
	# would leave the map, centred on it vertically, and held inside the map
	# on both axes; a clicked point panned off the map anchors the card at
	# the map's edge, so the card stays up beside the nearest part of the map
	card : Ui.Model, Scene.Measure -> Try({ box : Labels.Rect, lines : List(Labels.Label(Scene.Item)) }, [NoCard])
	card = |model, measure|
		match (picked(model), model.map_card) {
			(Ok(l), Open(o)) => {
				r = rect(model.win)
				ls = card_lines(l.session, model.units, o.state)
				w = 2.0 * card_pad + List.fold(ls, 0.0, |m, x| F32.max(m, measure(x.text, x.size, x.face)))
				h = 2.0 * card_pad + List.fold(ls, 0.0, |acc, x| acc + x.size) + U64.to_f32(List.len(ls) - 1) * card_gap
				a = Geo.to_screen(cam(model), r, o.at)
				right = a.x + 14.0
				left = F32.max(r.x, F32.min(if (right + w <= r.x + r.w) right else a.x - 14.0 - w, r.x + r.w - w))
				top = F32.max(r.y, F32.min(a.y - h / 2.0, r.y + r.h - h))
				box = { x: left, y: top, w, h }
				tone = |t|
					match t {
						Title => Color.white
						Body => Theme.ink_muted
						Muted => Theme.ink_faint
					}
				placed = List.fold(
					ls,
					{ y: top + card_pad, out: [] },
					|acc, x| {
						it = { text: x.text, size: x.size, color: tone(x.tone), face: x.face, prep: Fresh }
						{ y: acc.y + x.size + card_gap, out: List.append(acc.out, Scene.fixed(measure, it, { x: left + card_pad, y: acc.y, align: Left }, box)) }
					},
				)
				Ok({ box, lines: placed.out })
			}
			_ => Err(NoCard)
		}

	draw_card! : Ui.Model, Draw.Frame => {}
	draw_card! = |model, frame|
		match card(model, Scene.measure_of(model)) {
			Ok(c) => {
				frame.rounded_rectangle!({ x: c.box.x, y: c.box.y, width: c.box.w, height: c.box.h, radius: 6.0, segments: 6, style: Draw.filled(Color.with_alpha(Theme.card, 245)) })
				Scene.draw!(frame, model, Labels.place(c.lines, { boxes: [], segs: [] }))
			}
			Err(_) => {}
		}

	# what the athlete did to the card this frame: a click on the card, or
	# Enter, opens the session (`open`, -1 when nothing opens), a click that
	# picks a route opens its card, a click that picks none and Esc close it.
	# A card waiting on its session, or with no trace to open, opens nothing,
	# and a card whose route is no longer loaded closes on a map mode's next
	# frame and opens nothing.
	act : Ui.Model, Try(Geo.Pt, [NoClick]), { enter : Bool, esc : Bool }, Scene.Measure -> { card : Ui.MapCard, open : I64 }
	act = |model, click, keys, measure| {
		up = match picked(model) {
			Ok(_) => model.map_card
			Err(_) => Closed
		}
		ready = match up {
			Open(o) =>
				match o.state {
					Ready => o.id
					_ => -1
				}
			Closed => -1
		}
		if !(is_map(model.view)) {
			{ card: model.map_card, open: -1 }
		} else {
			match click {
				Ok(p) => {
					on_card = match card(model, measure) {
						Ok(cd) => p.x >= cd.box.x and p.x <= cd.box.x + cd.box.w and p.y >= cd.box.y and p.y <= cd.box.y + cd.box.h
						Err(_) => Bool.False
					}
					if on_card {
						{ card: up, open: ready }
					} else {
						r = rect(model.win)
						c = cam(model)
						match hit(model.map.routes, c, r, p.x, p.y) {
							Ok(s) => { card: Open({ id: s.id, at: Geo.to_world(c, r, p.x, p.y), state: Ready }), open: -1 }
							Err(_) => { card: Closed, open: -1 }
						}
					}
				}
				Err(_) =>
					if keys.esc {
						{ card: Closed, open: -1 }
					} else if keys.enter {
						{ card: up, open: ready }
					} else {
						{ card: up, open: -1 }
					}
			}
		}
	}

	# whether Esc closes the card rather than the window
	card_up : Ui.Model -> Bool
	card_up = |model| is_map(model.view) and picked(model).is_ok()

	# the session the focus row names: the card's, while a map mode shows it
	map_focus : Ui.Model -> I64
	map_focus = |model|
		match picked(model) {
			Ok(l) => l.session.id
			Err(_) => -1
		}

	# the session a card waits on for its picker row, -1 when it waits on none
	waiting_on : Ui.MapCard -> I64
	waiting_on = |c|
		match c {
			Open(o) =>
				match o.state {
					Opening => o.id
					_ => -1
				}
			Closed => -1
		}

	with_state : Ui.MapCard, [Ready, Opening, NoTrace] -> Ui.MapCard
	with_state = |c, state|
		match c {
			Open(o) => Open({ ..o, state })
			Closed => Closed
		}

	# a failed read's message, cut to what the map's narrowest width holds
	clip : Str -> Str
	clip = |s| if (Str.count_utf8_bytes(s) > 96) Str.concat(Str.from_utf8_lossy(List.take_first(Str.to_utf8(s), 93)), "...") else s
	# ── every string the view writes, placed ───────────────────────────────
	scene : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	scene = |model, measure| Labels.place(texts(model, measure), { boxes: Chrome.boxes(model, measure), segs: [] })

	# the view's text and the chrome's, as the gate judges them
	owned : Ui.Model, Scene.Measure -> List(Labels.Owned)
	owned = |model, measure| List.join([Scene.owned(Chrome.placed(model, measure)), Scene.owned(scene(model, measure)), MapNames.owned(names(model, cam(model), measure))])

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
	# the camera has moved since it was painted, else its layers drawn
	# straight to the frame (paint!), each name under its own camera inside
	# the view's. In heat mode the summed passes follow, through the
	# tone-mapping shader, with the same shift; then the route a card is up
	# for, highlighted; in play the markers follow, placed this frame. The
	# scissor keeps all of it inside the map's rectangle; it takes screen
	# pixels, so the logical rectangle is scaled by the UI size. The card
	# draws last, over the view's text.
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
				draw_picked!(model, c, f)
				if model.view == 12 {
					draw_markers!(model, c, f)
				}
				Ok({})
			},
		)
		Scene.draw!(frame, model, scene(model, measure))
		draw_card!(model, frame)
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

# a route as the hit test reads it: one list for every zoom, its session
# named by id and start
expect {
	line = |id, start, pts| { kind: Db.route_kind, pts, ts: [], far: pts, fts: [], bands: [], fbands: [], box: Geo.box_of(pts), session: { ..Db.no_session, id, start } }
	r = Map.rect({ w: 980.0, h: 600.0 })
	flat = line(7, 100, [{ x: -1000.0, y: 0.0 }, { x: 1000.0, y: 0.0 }])
	diag = line(8, 100, [{ x: -1000.0, y: -1000.0 }, { x: 1000.0, y: 1000.0 }])
	# a click within hit_px of the drawn line picks it and one past it
	# does not, at a close, a middle and a wide zoom alike, and across a
	# diagonal line, whose extent holds every point near it
	List.all(
		[0.5, 4.0, 50.0],
		|mpp| {
			c = { cx: 0.0, cy: 0.0, mpp }
			s = Geo.to_screen(c, r, { x: 0.0, y: 0.0 })
			# a step of k pixels on both axes lies k times the square root of
			# two from the diagonal
			k_in = (Map.hit_px - 0.5) / 1.41421356
			k_out = (Map.hit_px + 0.5) / 1.41421356
			(Map.hit([flat], c, r, s.x, s.y + Map.hit_px - 1.0)).map_ok(|x| x.id) == Ok(7) and Map.hit([flat], c, r, s.x, s.y + Map.hit_px + 1.0) == Err(Miss)
				and (Map.hit([diag], c, r, s.x + k_in, s.y + k_in)).map_ok(|x| x.id) == Ok(8) and Map.hit([diag], c, r, s.x + k_out, s.y + k_out) == Err(Miss)
		},
	)
}

# where routes overlap at a click the session that started last wins, even
# when an older one passes nearer, and of two that started together the
# higher id
expect {
	line = |id, start, pts| { kind: Db.route_kind, pts, ts: [], far: pts, fts: [], bands: [], fbands: [], box: Geo.box_of(pts), session: { ..Db.no_session, id, start } }
	r = Map.rect({ w: 980.0, h: 600.0 })
	c = { cx: 0.0, cy: 0.0, mpp: 1.0 }
	s = Geo.to_screen(c, r, { x: 0.0, y: 0.0 })
	old = line(1, 100, [{ x: -500.0, y: 0.0 }, { x: 500.0, y: 0.0 }])
	new = line(2, 200, [{ x: -500.0, y: 3.0 }, { x: 500.0, y: 3.0 }])
	twin = line(3, 200, [{ x: -500.0, y: -2.0 }, { x: 500.0, y: -2.0 }])
	(Map.hit([new, old], c, r, s.x, s.y)).map_ok(|x| x.id) == Ok(2)
		and (Map.hit([old, new], c, r, s.x, s.y)).map_ok(|x| x.id) == Ok(2)
		and (Map.hit([old, new, twin], c, r, s.x, s.y)).map_ok(|x| x.id) == Ok(3)
		and (Map.hit([twin, new, old], c, r, s.x, s.y)).map_ok(|x| x.id) == Ok(3)
}

# a click off the map picks nothing though a route runs under it, a route
# within hit_px of a click but only past the map's edge is never picked,
# and a route far from the click is passed over on its extent alone
expect {
	line = |id, start, pts| { kind: Db.route_kind, pts, ts: [], far: pts, fts: [], bands: [], fbands: [], box: Geo.box_of(pts), session: { ..Db.no_session, id, start } }
	r = Map.rect({ w: 980.0, h: 600.0 })
	c = { cx: 0.0, cy: 0.0, mpp: 1.0 }
	edge = Geo.to_world(c, r, r.x - 2.0, r.y + 100.0)
	beyond = line(4, 100, [{ x: edge.x, y: -1000.0 }, { x: edge.x, y: 1000.0 }])
	across = line(5, 100, [{ x: -2000.0, y: 0.0 }, { x: 2000.0, y: 0.0 }])
	far = line(6, 100, [{ x: 50000.0, y: 50000.0 }, { x: 50100.0, y: 50000.0 }])
	s = Geo.to_screen(c, r, { x: 0.0, y: 0.0 })
	Map.hit([beyond], c, r, r.x + 1.0, r.y + 100.0) == Err(Miss)
		and Map.hit([across], c, r, r.x - 10.0, s.y) == Err(Miss)
		and (Map.hit([across], c, r, r.x + 10.0, s.y)).map_ok(|x| x.id) == Ok(5)
		and Map.hit([far], c, r, s.x, s.y) == Err(Miss)
}

# the hit test reads the list the zoom draws: a bend the near list keeps
# and the far list cuts is picked close in and not from the wide zooms
expect {
	r = Map.rect({ w: 980.0, h: 600.0 })
	near = [{ x: -400.0, y: 0.0 }, { x: 0.0, y: 300.0 }, { x: 400.0, y: 0.0 }]
	cut = [{ x: -400.0, y: 0.0 }, { x: 400.0, y: 0.0 }]
	l = { kind: Db.route_kind, pts: near, ts: [], far: cut, fts: [], bands: [], fbands: [], box: Geo.box_of(near), session: { ..Db.no_session, id: 8, start: 1 } }
	close = { cx: 0.0, cy: 300.0, mpp: Map.far_mpp }
	wide = { cx: 0.0, cy: 300.0, mpp: Map.far_mpp * 2.0 }
	at = |c| Geo.to_screen(c, r, { x: 0.0, y: 300.0 })
	(Map.hit([l], close, r, (at(close)).x, (at(close)).y)).map_ok(|x| x.id) == Ok(8) and Map.hit([l], wide, r, (at(wide)).x, (at(wide)).y) == Err(Miss)
}

# a route carried across the antimeridian is picked where it is drawn, on
# the far side of 180 degrees from where it set out
expect {
	r = Map.rect({ w: 980.0, h: 600.0 })
	o = Geo.merc(0.0, 179.9)
	coords = Geo.unwrap([{ lat: 0.0, lng: 179.9 }, { lat: 0.0, lng: -179.9 }, { lat: 0.0, lng: -179.8 }])
	match Db.map_line(o, Db.route_kind, coords, []) {
		Ok(l0) => {
			l = { ..l0, session: { ..Db.no_session, id: 9, start: 1 } }
			p = Geo.rel(o, 0.0, 180.15)
			c = { cx: p.x, cy: p.y, mpp: 2.0 }
			s = Geo.to_screen(c, r, p)
			p.x > 0.0 and (Map.hit([l], c, r, s.x, s.y)).map_ok(|x| x.id) == Ok(9)
		}
		Err(_) => Bool.False
	}
}

# a press and its release within slop_px is a click where it was last held,
# one that strays past it is a drag however it ends, and a press that
# begins off the map is neither
expect {
	at = |down, pressed, x, y| { down, pressed, on_map: Bool.True, x, y }
	run = |steps| List.fold(
		steps,
		{ press: Idle, clicks: [] },
		|acc, i| {
			s = Map.press_step(acc.press, i)
			{
				press: s.press,
				clicks: match s.click {
					Ok(p) => List.append(acc.clicks, p)
					Err(_) => acc.clicks
				},
			}
		},
	).clicks
	run([at(Bool.True, Bool.True, 100.0, 100.0), at(Bool.False, Bool.False, 100.0, 100.0)]) == [{ x: 100.0, y: 100.0 }]
		and run([at(Bool.True, Bool.True, 100.0, 100.0), at(Bool.True, Bool.False, 103.0, 98.0), at(Bool.False, Bool.False, 103.0, 98.0)]) == [{ x: 103.0, y: 98.0 }]
		and run([at(Bool.True, Bool.True, 100.0, 100.0), at(Bool.True, Bool.False, 100.0 + Map.slop_px + 1.0, 100.0), at(Bool.True, Bool.False, 100.0, 100.0), at(Bool.False, Bool.False, 100.0, 100.0)]) == []
		and run([{ ..at(Bool.True, Bool.True, 100.0, 100.0), on_map: Bool.False }, at(Bool.False, Bool.False, 100.0, 100.0)]) == []
		and run([at(Bool.True, Bool.True, 100.0, 100.0), at(Bool.True, Bool.False, 100.0, 100.0)]) == []
}

# the card in metric: a ride its meter measured reads its power, and one
# without a meter says so; in imperial, the miles; and a sport neither
# paced nor ridden reads its power when a meter measured it and leaves the
# slot out when none did
expect {
	s = { id: 1, start: 0, name: "Lakefront loop", day: "2026-11-15", sport: "Ride", dist_m: 100000.0, moving_s: 35940, watts: 250 }
	texts = |x, u, st| List.map(Map.card_lines(x, u, st), |l| l.text)
	texts(s, Metric, Ready) == ["Lakefront loop", "Ride   2026-11-15", "100.0 km   9h 59m   250 W avg", "Enter or click  open its trace      Esc  close"]
		and texts({ ..s, watts: 0, dist_m: 160934.4 }, Imperial, Ready) == ["Lakefront loop", "Ride   2026-11-15", "100.0 mi   9h 59m   no power meter", "Enter or click  open its trace      Esc  close"]
		and texts({ ..s, watts: 0 }, Metric, Ready) == ["Lakefront loop", "Ride   2026-11-15", "100.0 km   9h 59m   no power meter", "Enter or click  open its trace      Esc  close"]
		and texts({ ..s, sport: "Kayaking", watts: 0 }, Metric, Ready) == ["Lakefront loop", "Kayaking   2026-11-15", "100.0 km   9h 59m", "Enter or click  open its trace      Esc  close"]
		and texts({ ..s, sport: "Kayaking" }, Metric, Ready) == ["Lakefront loop", "Kayaking   2026-11-15", "100.0 km   9h 59m   250 W avg", "Enter or click  open its trace      Esc  close"]
}

# a run reads its pace per kilometre or per mile, a swim per 100 m and an
# erg session per 500 m in either unit, a session under an hour in minutes,
# and an unnamed session by its sport
expect {
	run = { id: 2, start: 0, name: "", day: "2026-11-14", sport: "TrailRun", dist_m: 10000.0, moving_s: 3000, watts: 300 }
	swim = { ..run, sport: "Swim", dist_m: 1500.0, moving_s: 1800 }
	row = { ..run, sport: "VirtualRow", dist_m: 5000.0, moving_s: 1200 }
	data = |x, u| (List.get(Map.card_lines(x, u, Ready), 2)).map_ok(|l| l.text)
	data(run, Metric) == Ok("10.0 km   50m   5:00 ${Sports.pace_unit("Run").label}")
		and data({ ..run, dist_m: 16093.44, moving_s: 4800 }, Imperial) == Ok("10.0 mi   1h 20m   8:00 /mi")
		and data(swim, Imperial) == Ok("0.9 mi   30m   2:00 /100m") and data(swim, Metric) == Ok("1.5 km   30m   2:00 /100m")
		and data(row, Imperial) == Ok("3.1 mi   20m   2:00 /500m")
		and (List.first(Map.card_lines(run, Metric, Ready))).map_ok(|l| l.text) == Ok("TrailRun")
		and Map.time_text(3900) == "1h 05m" and Map.time_text(0) == "-" and Map.dist_text(0.0, Metric) == "-"
}

# the card says when its trace is on its way and when there is none
expect {
	s = { id: 1, start: 0, name: "a", day: "2026-11-15", sport: "Ride", dist_m: 1000.0, moving_s: 600, watts: 0 }
	(List.last(Map.card_lines(s, Metric, Opening))).map_ok(|l| l.text) == Ok("opening its trace...")
		and (List.last(Map.card_lines(s, Imperial, NoTrace))).map_ok(|l| l.text) == Ok("no trace to open - its stream holds nothing to plot")
}

# the route query reads watts as analyze does: an unmarked row's as
# measured, and none from a row Strava marked estimated
expect Str.contains(Db.route_page_sql, "CASE WHEN COALESCE(a.device_watts, 1) <> 0 THEN ROUND(COALESCE(a.avg_watts, 0)) ELSE 0 END")

# the picture of a doubled HiDPI display at the default UI size holds
# three of its pixels to a logical unit, one of an ordinary display one
# and a half, and a window with no width falls back to the UI scale
expect (Map.picture_zoom(2940.0, 980.0, 1.5) - 3.0).abs() < 0.001 and (Map.picture_zoom(1470.0, 980.0, 1.5) - 1.5).abs() < 0.001 and (Map.picture_zoom(2940.0, 0.0, 1.5) - 1.5).abs() < 0.001
