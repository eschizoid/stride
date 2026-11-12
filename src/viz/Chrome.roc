import rr.Color
import Days
import Db
import DisplayScale
import Hud
import Labels
import Scene
import Theme
import Ui
import Weeks

Chrome :: [].{
	# ── the text every view shares: the wordmark, the scale chip, the nav
	# pills, the recording badge, the form board's legend and the XP rail's
	# level. main.roc draws it before the view, from these definitions, and
	# each view registers the same boxes as fixed text and the pills as
	# obstacles, so a view label can neither land on the chrome nor drift
	# from where the chrome is drawn.

	wordmark : Str
	wordmark = "Stride"

	# the scale chip shows the percent only once the athlete has moved it
	# off the default: at the default it is a plain affordance, and a
	# changed scale earns the number as feedback on the athlete's own choice
	scale_label : Ui.Model -> Str
	scale_label = |model| if (model.ui_percent == DisplayScale.default_percent) "Ctrl +/-  resize" else "${Db.fmt_i(model.ui_scale * 100.0)}%  Ctrl +/-"

	# One nav density: every pill carries its 12x12 vector mark beside its
	# label at every window width, since a tier that switched information
	# off by width would go dark for whole classes of displays at the 150%
	# default. The render and both hit tests read these, and at the minimum
	# window width the pills clear the title row's scale chip.
	nav_pitch : F32
	nav_pitch = 76.0

	nav_width : F32
	nav_width = 70.0

	nav_top : F32
	nav_top = 30.0

	nav_h : F32
	nav_h = 24.0

	# the views the nav offers, left to right, and each pill's label
	nav_views : List(U8)
	nav_views = [0, 1, 2, 4, 9, 6, 8]

	nav_name : U8 -> Str
	nav_name = |v|
		if (v == 0) "form"
		else if (v == 1) "power"
		else if (v == 2) "trace"
		else if (v == 4) "plan"
		else if (v == 9) "lifts"
		else if (v == 6) "weeks"
		else if (v == 8) "career"
		else ""

	# the left edge of the i-th of n pills, right-anchored to the window
	nav_x : F32, U64, U64 -> F32
	nav_x = |win_w, n, i| win_w - 36.0 - U64.to_f32(n - i) * nav_pitch

	nav_pill : F32, U64, U64 -> Labels.Rect
	nav_pill = |win_w, n, i| { x: nav_x(win_w, n, i), y: nav_top, w: nav_width, h: nav_h }

	# the form board's legend: a swatch and a name per line, on the row the
	# other views put their titles in
	legend : List({ x : F32, c : Color.Rgba, name : Str })
	legend = [{ x: 36.0, c: Theme.ctl_c, name: "Fitness" }, { x: 128.0, c: Theme.atl_c, name: "Fatigue" }, { x: 226.0, c: Theme.tsb_c, name: "Form" }]

	# the recording badge's dot and the text beside it, by status
	rec_text : Ui.Model -> Try({ text : Str, at : Scene.Anchor, color : Color.Rgba, dot : Bool }, [Idle])
	rec_text = |model| {
		w = model.win.w
		match model.rec_status {
			Active(af) => Ok({ text: "rec ${U64.to_str(af.frames)}f   V stops", at: { x: w - 138.0, y: 58.0, align: Left }, color: Theme.alarm_c, dot: Bool.True })
			Finished(ff) => Ok({ text: "recording saved to captures/ (${U64.to_str(ff.bytes / 1024)}kb)", at: { x: w - 40.0, y: 58.0, align: Right }, color: Theme.tsb_c, dot: Bool.False })
			Failed(ff2) => {
				why = match ff2.reason {
					PathInvalid | PathEscapesOutputDir => "bad path"
					AlreadyRecording => "already recording"
					BudgetExceeded | OutOfMemory => "out of memory - try again shorter"
					WriteFailed => "could not write captures/"
					EncodeFailed | UnsupportedFormat => "encoder refused webm"
					_ => "unknown"
				}
				Ok({ text: "recording failed: ${why}   V retries", at: { x: w - 40.0, y: 58.0, align: Right }, color: Theme.alarm_c, dot: Bool.False })
			}
			Idle => Err(Idle)
		}
	}

	# the XP rail's level number under the rail's foot, when the athlete has
	# any hours at all
	rail_level : Ui.Model -> Try(Str, [NoHours])
	rail_level = |model| {
		hours = Hud.total_hours(model.career_sports)
		if (hours <= 0) Err(NoHours) else Ok(I64.to_str(Hud.level_of(hours)))
	}

	# every chrome text as fixed labels; the nav labels belong inside their
	# pills, everything else inside the panel
	labels : Ui.Model, Scene.Measure -> List(Labels.Label(Scene.Item))
	labels = |model, measure| {
		win = model.win
		panel = Labels.panel(win)
		n = List.len(model.nav)
		title = Scene.fixed(measure, Scene.prepared(model.title, wordmark, 30.0, Prose, Color.white), { x: 34.0, y: 30.0, align: Left }, panel)
		scale = Scene.fixed(measure, Scene.data(scale_label(model), 11.0, Theme.ink_muted), { x: 152.0, y: 40.0, align: Left }, panel)
		on_view = Weeks.group(Days.group(model.view))
		pills = List.map_with_index(
			model.nav,
			|nv, i| {
				pill = nav_pill(win.w, n, i)
				color = if (nv.v == on_view) Color.white else Theme.ink_muted
				# the label centres in the span right of the mark, not on the pill,
				# which would put it under the mark
				Scene.fixed(measure, Scene.prepared(nv.p, nav_name(nv.v), 13.0, Prose, color), { x: pill.x + 44.0, y: 35.0, align: Center }, pill)
			},
		)
		rec = match rec_text(model) {
			Ok(r) => [Scene.fixed(measure, Scene.data(r.text, 11.0, r.color), r.at, panel)]
			Err(_) => []
		}
		leg =
			if model.view == 0 {
				List.map2(legend, [model.leg_fit, model.leg_fat, model.leg_form], |l, p| Scene.fixed(measure, Scene.prepared(p, l.name, 15.0, Prose, l.c), { x: l.x + 20.0, y: 70.0, align: Left }, panel))
			} else {
				[]
			}
		lvl = match rail_level(model) {
			Ok(t) => [Scene.fixed(measure, Scene.data(t, 10.0, Theme.gold_c), { x: 23.0, y: win.h - 38.0, align: Center }, panel)]
			Err(_) => []
		}
		List.join([[title, scale], pills, rec, leg, lvl])
	}

	# the chrome text where main.roc draws it
	placed : Ui.Model, Scene.Measure -> List(Labels.Placed(Scene.Item))
	placed = |model, measure| Labels.place(labels(model, measure), { boxes: [], segs: [] })

	# everything of the chrome a view label must keep off: its text and its
	# shapes
	boxes : Ui.Model, Scene.Measure -> List(Labels.Rect)
	boxes = |model, measure| List.concat(List.map(placed(model, measure), |p| p.box), shapes(model))

	# the chrome's shapes a view label must keep off: the nav pills
	shapes : Ui.Model -> List(Labels.Rect)
	shapes = |model| {
		n = List.len(model.nav)
		List.map_with_index(model.nav, |_nv, i| nav_pill(model.win.w, n, i))
	}
}

expect Chrome.nav_x(980.0, 7, 0) == 980.0 - 36.0 - 7.0 * Chrome.nav_pitch and Chrome.nav_x(980.0, 7, 6) == 980.0 - 36.0 - Chrome.nav_pitch
expect List.all(Chrome.nav_views, |v| Chrome.nav_name(v) != "")
