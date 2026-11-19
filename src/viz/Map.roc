import rr.Color
import rr.Draw
import Chrome
import Db
import Geo
import Labels
import Scene
import Theme
import Ui

Map :: [].{
	# The map view: every GPS session drawn over the street map the
	# engine fetched, in Web Mercator, north up. Drag pans, the wheel zooms
	# at the cursor, and `0` fits the routes again (the street map when no route
	# has GPS). The streets come from
	# OpenStreetMap, and the view credits it on the map itself.

	title_text : Str
	title_text = "routes - every GPS session on the street map"

	hint_text : Str
	hint_text = "drag  pan      wheel  zoom      0  fit      TAB  form      R  reload      S  screenshot      ESC quit"

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
	# else the fit to the routes, which follows the window as it resizes
	cam : Ui.Model -> Geo.Cam
	cam = |model| if (model.map_moved) model.map_cam else Geo.fit(model.map.fit, rect(model.win))

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

	# every line the camera shows, base map first in the kind order the
	# load sorted it into, then the routes over it; a line wholly outside
	# the rectangle or faded out is skipped, and a point closer than a pixel
	# to the last one drawn adds nothing
	paint! : Ui.Model, Geo.Cam, Draw.Frame => {}
	paint! = |model, c, frame| {
		r = rect(model.win)
		List.for_each!(
			List.concat(model.map.ways, model.map.routes),
			|l| {
				s = style(l.kind)
				k = fade(s, c.mpp)
				if k > 0.0 and Geo.visible(c, r, l.box) {
					a = (F32.round_to_u64_try(s.alpha * k)) ?? 0
					frame.line_strip!({ points: Geo.strip(c, r, if (c.mpp > far_mpp) l.far else l.pts, 1.0), stroke: Draw.stroke(Color.with_alpha(s.color, U64.to_u8_wrap(a)), s.width) })
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
			} else if List.is_empty(model.map.ways) {
				[fix(Scene.prose(no_base_text, 13.0, Theme.ink_muted), r.x + 14.0, r.y + 14.0, Left, r)]
			} else {
				[]
			}
		List.join([
			[
				fix(Scene.prose(title_text, 15.0, Theme.ink_muted), 36.0, 70.0, Left, panel),
				fix(Scene.prose(credit_text, 11.0, Theme.ink_faint), r.x + r.w, credit_y, Right, panel),
				fix(Scene.data("c", 9.0, Theme.ink_faint), ring.x + ring.w / 2.0, ring.y + 2.0, Center, ring),
				fix(Scene.prose(hint_text, 13.0, Theme.ink_faint), 36.0, model.win.h - 30.0, Left, panel),
			],
			note,
		])
	}

	# the shapes no text may cover but its own: the pills, the map and the
	# copyright ring
	marks : Ui.Model, Scene.Measure -> List(Labels.Mark)
	marks = |model, measure| {
		r = rect(model.win)
		List.join([Chrome.marks(model), [{ key: "the map", box: r }, { key: "the copyright ring", box: credit_ring(model.win, measure) }]])
	}

	# The cached picture when the window holds one, shifted by however far
	# the camera has moved since it was painted, else every line drawn
	# straight to the frame. Either way the scissor keeps the lines inside
	# the map's rectangle; it takes screen pixels, so the logical rectangle
	# is scaled by the UI size.
	draw! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
	draw! = |model, frame| {
		r = rect(model.win)
		c = cam(model)
		measure = Scene.measure_of(model)
		frame.rounded_rectangle!({ x: r.x, y: r.y, width: r.w, height: r.h, radius: 10.0, segments: 8, style: Draw.filled(Theme.card) })
		sc = model.ui_scale
		px = { x: r.x * sc, y: r.y * sc, width: r.w * sc, height: r.h * sc }
		_ = frame.with_scissor!(
			px,
			|f| {
				match model.map_rt {
					Target(t) => {
						off = Geo.to_screen(c, r, Geo.to_world(model.map_painted, r, r.x, r.y))
						f.texture!({ texture: t.rt.texture(), source: t.rt.source(), dest: { x: off.x - r.x, y: off.y - r.y, width: model.win.w, height: model.win.h }, origin: { x: 0.0, y: 0.0 }, rotation: 0.0, tint: Color.white })
					}
					_ => paint!(model, c, f)
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
