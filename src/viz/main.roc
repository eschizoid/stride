## Stride Form Board — the viz suite's window: three TAB views (form board,
## power-duration curve, session trace) over ~/.stride/db.sqlite, read at
## launch. The modules beside this file carry the parts: Theme (geometry +
## palette), Db (every loader and its types), Ui (the Model), and one module
## per view (Board, Curve, Trace). This file owns the app contract: the
## platform pin, Model/Msg, init!, update!, and the view dispatch.
##
## NOTE the pin below: roc-ray's platform needs nightly-2026-08-23, not the
## engine's toolchain pin. The header carries its own compiler version, so
## `roc src/viz/main.roc` with a matching nightly is the whole build.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Capture
import rr.Cmd
import rr.Color
import rr.Draw
import rr.Sqlite
import rr.Task
import rr.Text
import Board
import Curve
import Db
import Theme
import Trace
import Ui

Model : Ui.Model

program = { init!, update!, render! }

init! : App.Init(Model, [AssetPathInvalid, AssetNotFound, AssetReadFailed, FontLoadFailed, ResourceLimit])
init! = App.init(
	App.default
		.with_title("Stride Form Board")
		.with_size({ width: Theme.win_w, height: Theme.win_h })
		.with_frame_pacing(Capped(60))
		.with_output_dir("captures"),
	|_startup| {
		font = Draw.default_font!()
		# ~/.stride/db.sqlite, resolved at launch — the platform has no Env
		# module, but Cmd captures stdout, so the shell answers for HOME.
		home = match Cmd.run_utf8!(Cmd.with_args(Cmd.new("printenv"), ["HOME"])) {
			Ok(out) => Str.trim(out.stdout)
			Err(_) => ""
		}
		db_path = Str.concat(home, "/.stride/db.sqlite")
		loaded = if home == "" {
			{ s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot resolve HOME" }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], st: 0 , tr: [], sg: [], du: 1.0 }
		} else match Sqlite.Db.open!(db_path) {
			Ok(db) => {
				s = Db.load_series!(db)
				e = Db.load_event!(db)
				c = Db.load_curve!(db)
				tid = Db.load_trace_id!(db)
				tr = Db.load_trace!(db, tid)
				sg = Db.load_segs!(db, tid)
				du = Db.load_dur!(db, tid)
				st = Db.load_stale!(db)
				{ s, e, c, st, tr, sg, du }
			}
			Err(_) => { s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot open ${db_path}" }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], st: 0 , tr: [], sg: [], du: 1.0 }
		}
		ev = Db.find_idx(loaded.s.days, loaded.e.day)
		fit = Db.load_fit!({})
		fit_text =
			if fit.ok
				"CP ${Db.fmt_f(fit.cp)} W · W' ${Db.fmt_f(fit.w_prime / 1000.0)} kJ · fit r2 ${Db.fmt_f(fit.r2)} from ${Db.fmt_i(fit.points)} bests"
			else "CP fit unavailable - the engine did not answer"
		mk! = |txt, sz| Text.from(txt, font).size(sz).prepare!()
		curve_lbls = List.map_try(loaded.c, |c| {
			p = mk!(I64.to_str(c.dur_s), 12)?
			Ok({ p, d: c.dur_s })
		})?
		ylabels = List.map_try([-30, -20, -10, 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100], |v| {
			p = mk!(I64.to_str(v), 12)?
			Ok({ p, v: I64.to_f32(v) })
		})?
		ends = List.map_try(
			[
				{ s: "CTL ${Db.fmt1(loaded.s.last.c)}", k: 0.U8 },
				{ s: "ATL ${Db.fmt1(loaded.s.last.a)}", k: 1.U8 },
				{ s: "TSB ${Db.fmt1(loaded.s.last.t)}", k: 2.U8 },
			],
			|e| {
				p = mk!(e.s, 13)?
				Ok({ p, sel: e.k })
			},
		)?
		Ok({
			title: mk!("Stride Form Board", 30)?,
			subs: [
				{ p: mk!("last 30 days, live from stride", 15)?, r: 30.U64 },
				{ p: mk!("last 60 days, live from stride", 15)?, r: 60.U64 },
				{ p: mk!("last 90 days, live from stride", 15)?, r: 90.U64 },
			],
			leg_fit: mk!("Fitness", 15)?,
			leg_fat: mk!("Fatigue", 15)?,
			leg_form: mk!("Form", 15)?,
			ylabels,
			ends,
			ev_label: mk!(loaded.e.name, 13)?,
			ev_found: ev.found,
			ev_idx: ev.idx,
			ev_ahead: loaded.e.ahead,
			ev_warn: mk!(loaded.e.err, 13)?,
			ev_warn_found: loaded.e.err != "",
			stale: mk!(
				match List.last(loaded.s.days) {
					Ok(ld) => "data as of ${ld} - analyze to refresh"
					Err(_) => ""
				},
				13,
			)?,
			stale_found: loaded.st > 0,
			ev_far_label: mk!("${loaded.e.name}  ${I64.to_str(loaded.e.ahead)}d", 13)?,
			view: 0,
			curve: loaded.c,
			curve_lbls: curve_lbls,
			fit_lbl: mk!(fit_text, 14)?,
			curve_title: mk!("power-duration curve - Ride, last 90 days", 15)?,
			curve_hint: mk!("TAB  session trace      ESC quit", 13)?,
			curve_empty: mk!("no rides in the last 90 days - the curve has nothing to draw", 16)?,
			trace: loaded.tr,
			segs: loaded.sg,
			trace_title: mk!("last structured session - detected blocks shaded behind the power trace", 15)?,
			trace_dur: loaded.du,
			fit_cp: if fit.ok (fit.cp) else 0.0,
			cp_lbl: mk!("CP ${Db.fmt_f(fit.cp)}W", 12)?,
			data: loaded.s.data,
			days: loaded.s.days,
			status: mk!(loaded.s.err, 16)?,
			has_error: loaded.s.err != "",
			font,
			hint: mk!("1 / 2 / 3  range 30 / 60 / 90 days      TAB  form / power curve / session      hover to read a day      ESC quit", 13)?,
			empty: mk!("no data yet - sync and analyze first, then reopen", 16)?,
			range: 90.U64,
			mouse_x: 0.0,
			mouse_in: Bool.False,
		})
	},
)

# The app spawns one kind of task: a screenshot, whose result it ignores —
# a failed shot must not take the window down, and the file's absence is the

Msg : [Shot(Try({}, Capture.ScreenshotError))]

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	d = program_input.devices
	if d.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		range =
			if d.key_pressed(Key1) 30.U64
			else if d.key_pressed(Key2) 60.U64
			else if d.key_pressed(Key3) 90.U64
			else model.range
		view = if d.key_pressed(KeyTab) (if model.view == 2 0 else model.view + 1) else model.view
		m = d.mouse.position()
		# S writes a PNG of the CURRENT view into ./captures — #372's "session
		# graphic for a training log". Spawned rather than called inline: a
		# screenshot waits for the end of a frame, and update! is not one.
		# The name carries the view so three presses do not overwrite each other.
		_ = if d.key_pressed(KeyS) {
			shot_name = if view == 0 ("form-board.png") else if view == 1 ("power-curve.png") else "session-trace.png"
			Task.spawn!(program_input, || Shot(Capture.screenshot!(shot_name)))
		} else {}
		Ok({ ..model, range, view, mouse_x: m.x, mouse_in: m.y > Theme.pad_t and m.y < I32.to_f32(Theme.win_h) - Theme.pad_b })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.rectangle!({ x: 0.0, y: 0.0, width: I32.to_f32(Theme.win_w), height: I32.to_f32(Theme.win_h), style: Draw.filled(Theme.bg) })
	frame.rounded_rectangle!({ x: 16.0, y: 16.0, width: I32.to_f32(Theme.win_w) - 32.0, height: I32.to_f32(Theme.win_h) - 32.0, radius: 14.0, segments: 10, style: Draw.filled(Theme.panel) })
	model.title.draw!(frame, { pos: { x: 34.0, y: 30.0 }, color: Color.white, align: (Top, Left) })
	# Legend belongs to the FORM BOARD only: it draws in the same row the
	# other views put their titles in, and overprinted them.
	if model.view == 0 {
		model.leg_fit.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: Theme.ctl_c, align: (Top, Left) })
		model.leg_fat.draw!(frame, { pos: { x: 118.0, y: 70.0 }, color: Theme.atl_c, align: (Top, Left) })
		model.leg_form.draw!(frame, { pos: { x: 206.0, y: 70.0 }, color: Theme.tsb_c, align: (Top, Left) })
	} else {}
	if model.view == 2 {
		Trace.draw!(model, frame)
	} else if model.view == 1 {
		Curve.draw!(model, frame)
	} else {
		Board.draw!(model, frame)
	}
}
