## Stride Form Board — the viz suite's window: four TAB views (form board,
## power-duration curve, session trace, data table) over ~/.stride/db.sqlite, read at
## launch. The modules beside this file carry the parts: Theme (geometry +
## palette), Db (every loader and its types), Ui (the Model), and one module
## per view (Board, Curve, Trace, Table). This file owns the app contract: the
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
import rr.Files
import rr.Sqlite
import rr.Task
import rr.Text
import Board
import Table
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
		load_model!(font, 90)
	},
)

# Everything the window knows, rebuilt from the local stride sources in one
# call — the database for every series, plus the engine's power-curve command
# for the CP fit. init! runs it once at launch, and the R key runs it again
# without reopening.
# One brand face at one size, from wherever it lives: the repo's assets/ in a
# dev checkout, ~/.stride/fonts when launched as the app bundle, and the
# platform default font when neither answers — the board must open regardless.
brand_font! : Str, Str, I32, Text.Font => Text.Font
brand_font! = |home, name, size, fallback| {
	bytes = match Files.read_bytes!("assets/fonts/${name}") {
		Ok(b) => b
		# no HOME means no second location — never probe /.stride at the root
		Err(_) => if home == "" [] else match Files.read_bytes!("${home}/.stride/fonts/${name}") {
			Ok(b) => b
			Err(_) => []
		}
	}
	if List.is_empty(bytes) fallback
	else match Draw.font_from_bytes!({ format: Ttf, bytes, size }) {
		Ok(f) => f
		Err(_) => fallback
	}
}

load_model! : Text.Font, I64 => Try(Ui.Model, [ResourceLimit, ..])
load_model! = |font, curve_days| {
		# ~/.stride/db.sqlite, resolved on every load (launch and R alike) —
		# the platform has no Env module, but Cmd captures stdout, so the
		# shell answers for HOME.
		home = match Cmd.run_utf8!(Cmd.with_args(Cmd.new("printenv"), ["HOME"])) {
			Ok(out) => Str.trim(out.stdout)
			Err(_) => ""
		}
		db_path = Str.concat(home, "/.stride/db.sqlite")
		loaded = if home == "" {
			{ s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot resolve HOME" }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], st: 0 , tr: [], sg: [], du: 1.0, rd: { day: "", name: "", ago: -1, err: "" }, tids: [] }
		} else match Sqlite.Db.open!(db_path) {
			Ok(db) => {
				s = Db.load_series!(db)
				e = Db.load_event!(db)
				c = Db.load_curve!(db, curve_days)
				tids = Db.load_trace_ids!(db)
				tid = match List.first(tids) {
					Ok(x) => x.id
					Err(_) => 0
				}
				tr = Db.load_trace!(db, tid)
				sg = Db.load_segs!(db, tid)
				du = Db.load_dur!(db, tid)
				st = Db.load_stale!(db)
				rd = Db.load_ridden!(db)
				{ s, e, c, st, tr, sg, du, rd, tids }
			}
			Err(_) => { s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot open ${db_path}" }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], st: 0 , tr: [], sg: [], du: 1.0, rd: { day: "", name: "", ago: -1, err: "" }, tids: [] }
		}
		ev = Db.find_idx(loaded.s.days, loaded.e.day)
		fit = Db.load_fit!(curve_days)
		fit_text =
			if fit.ok
				"CP ${Db.fmt_f(fit.cp)} W · W' ${Db.fmt_f(fit.w_prime / 1000.0)} kJ · fit r2 ${Db.fmt_f(fit.r2)} from ${Db.fmt_i(fit.points)} bests"
			else "CP fit unavailable - the engine did not answer"
		# the brand: Quicksand (the wordmark's rounded face) carries PROSE —
		# titles, legends, captions, hints; JetBrains Mono (the tagline's
		# voice) carries DATA SURFACES — KPI digits, ticks, end labels, and
		# every immediate readout/table cell, mixed words included, so a data
		# line never switches face mid-string. The platform default appears
		# only when neither file can be found
		head = brand_font!(home, "Quicksand-Medium.ttf", 32, font)
		mono_big = brand_font!(home, "JetBrainsMono-Regular.ttf", 30, font)
		mono = brand_font!(home, "JetBrainsMono-Regular.ttf", 16, font)
		mk! = |txt, sz| Text.from(txt, head).size(sz).prepare!()
		mkm! = |txt, sz| Text.from(txt, mono).size(sz).prepare!()
		mkb! = |txt, sz| Text.from(txt, mono_big).size(sz).prepare!()
		curve_lbls = List.map_try(loaded.c, |c| {
			p = mkm!(I64.to_str(c.dur_s), 12)?
			Ok({ p, d: c.dur_s })
		})?
		ylabels = List.map_try([-30, -20, -10, 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100], |v| {
			p = mkm!(I64.to_str(v), 12)?
			Ok({ p, v: I64.to_f32(v) })
		})?
		ends = List.map_try(
			[
				{ s: "CTL ${Db.fmt1(loaded.s.last.c)}", k: 0.U8 },
				{ s: "ATL ${Db.fmt1(loaded.s.last.a)}", k: 1.U8 },
				{ s: "TSB ${Db.fmt1(loaded.s.last.t)}", k: 2.U8 },
			],
			|e| {
				p = mkm!(e.s, 13)?
				Ok({ p, sel: e.k })
			},
		)?
		as_of = match List.last(loaded.s.days) {
			Ok(ld) => ld
			Err(_) => "no data"
		}
		# the event tile prefers the future; a race inside the last week still
		# deserves its "ridden" moment; otherwise the slot says so
		ev_tile =
			if loaded.e.day != "" {
				{ top: loaded.e.name, sub: if loaded.e.ahead == 0 ("today, ${loaded.e.day}") else "in ${I64.to_str(loaded.e.ahead)}d, ${loaded.e.day}" }
			} else if loaded.rd.ago >= 0 and loaded.rd.ago <= 7 {
				{ top: loaded.rd.name, sub: "ridden, ${I64.to_str(loaded.rd.ago)}d ago" }
			} else {
				{ top: "no event planned", sub: "stride event add <date> <name>" }
			}
		Ok({
			title: mk!("Stride Form Board", 30)?,
			subs: [
				{ p: mk!("last 30 days, as of ${as_of}", 15)?, r: 30.U64 },
				{ p: mk!("last 60 days, as of ${as_of}", 15)?, r: 60.U64 },
				{ p: mk!("last 90 days, as of ${as_of}", 15)?, r: 90.U64 },
			],
			leg_fit: mk!("Fitness", 15)?,
			leg_fat: mk!("Fatigue", 15)?,
			leg_form: mk!("Form", 15)?,
			ylabels,
			ends,
			ev_label: mk!(loaded.e.name, 13)?,
			ev_found: ev.found,
			ev_idx: ev.idx,
			ev_warn: mk!(if loaded.e.err != "" loaded.e.err else loaded.rd.err, 13)?,
			ev_warn_found: loaded.e.err != "" or loaded.rd.err != "",
			stale: mk!(
				match List.last(loaded.s.days) {
					Ok(ld) => "data as of ${ld} - analyze to refresh"
					Err(_) => ""
				},
				13,
			)?,
			stale_found: loaded.st > 0,
			view: 0,
			curve: loaded.c,
			curve_lbls: curve_lbls,
			fit_lbl: mk!(fit_text, 14)?,
			curve_title: mk!("power-duration curve - Ride, last ${I64.to_str(curve_days)} days", 15)?,
			curve_days,
			trace_ids: loaded.tids,
			trace_sel: 0.U64,
			trace_day: match List.first(loaded.tids) {
				Ok(x) => x.day
				Err(_) => ""
			},
			curve_hint: mk!("1/2/3  window 30/60/90d      TAB  session trace      R  reload      S  screenshot      ESC quit", 13)?,
			trace_hint: mk!("[ / ]  older / newer session      TAB  data table      R  reload      S  screenshot      ESC quit", 13)?,
			table_hint: mk!("arrows  scroll days      TAB  form board      R  reload      S  screenshot      ESC quit", 13)?,
			table_title: mk!("data table - last 14 days", 15)?,
			table_head: [mk!("day", 13)?, mk!("fitness", 13)?, mk!("fatigue", 13)?, mk!("form", 13)?, mk!("load", 13)?],
			kpis: [
				{ v: mkb!(Db.fmt1(loaded.s.last.c), 27)?, cap: mk!("fitness - 42-day load avg", 11)?, sel: 0.U8 },
				{ v: mkb!(Db.fmt1(loaded.s.last.a), 27)?, cap: mk!("fatigue - 7-day load avg", 11)?, sel: 1.U8 },
				{ v: mkb!(Db.fmt1(loaded.s.last.t), 27)?, cap: mk!("form - fitness minus fatigue", 11)?, sel: 2.U8 },
			],
			ev_tile_top: mk!(ev_tile.top, 14)?,
			ev_tile_sub: mk!(ev_tile.sub, 11)?,
			zero_note: mk!("fresh above", 11)?,
			curve_empty: mk!("no rides in the selected window - the curve has nothing to draw", 16)?,
			trace: loaded.tr,
			segs: loaded.sg,
			trace_title: mk!("last structured session - detected blocks shaded behind the power trace", 15)?,
			trace_dur: loaded.du,
			fit_cp: if fit.ok (fit.cp) else 0.0,
			cp_lbl: mkm!("CP ${Db.fmt_f(fit.cp)}W", 12)?,
			data: loaded.s.data,
			days: loaded.s.days,
			status: mk!(loaded.s.err, 16)?,
			has_error: loaded.s.err != "",
			font: mono,
			hint: mk!("1/2/3 range   TAB view   hover or arrows to read a day   R reload   S screenshot   ESC quit", 13)?,
			empty: mk!("no data yet - sync and analyze first, then reopen", 16)?,
			range: 90.U64,
			mouse_x: 0.0,
			mouse_in: Bool.False,
			cursor: -1,
		})
}

# The app spawns one kind of task: a screenshot, whose result it ignores —
# a failed shot must not take the window down, and the file's absence is the
# report. Was `[]` while nothing spawned.

# Re-reads one session's trace/segments/duration for the picker — a bounded
# synchronous read on an explicit keypress, same reasoning as R. Any failure
# keeps the session the window already had.
switch_trace! : Ui.Model, U64 => Ui.Model
switch_trace! = |model, sel| {
	home = match Cmd.run_utf8!(Cmd.with_args(Cmd.new("printenv"), ["HOME"])) {
		Ok(out) => Str.trim(out.stdout)
		Err(_) => ""
	}
	if home == "" model
	else match List.get(model.trace_ids, sel) {
		Err(_) => model
		Ok(entry) =>
			match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
				Err(_) => model
				Ok(db) => {
					tr = Db.load_trace!(db, entry.id)
					sg = Db.load_segs!(db, entry.id)
					du = Db.load_dur!(db, entry.id)
					{ ..model, trace: tr, segs: sg, trace_dur: du, trace_sel: sel, trace_day: entry.day }
				}
			}
	}
}

Msg : [Shot(Try({}, Capture.ScreenshotError))]

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	d = program_input.devices
	if d.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		# 1/2/3 answer to whichever view is showing: the form board's range, or
		# the curve's window — never both at once
		range =
			if model.view == 1 model.range
			else if d.key_pressed(Key1) 30.U64
			else if d.key_pressed(Key2) 60.U64
			else if d.key_pressed(Key3) 90.U64
			else model.range
		view = if d.key_pressed(KeyTab) (if model.view == 3 0 else model.view + 1) else model.view
		# cursor counts days back from the series' latest day — the last ANALYZED
		# day, not necessarily today (0 = that column, -1 = off); LEFT walks
		# older, RIGHT walks newer, and the board clamps to the window
		# the form board and the data table share the cursor (chart crosshair,
		# table scroll); the other views leave it parked
		cursor =
			if view != 0 and view != 3 model.cursor
			else if d.key_pressed(KeyLeft) (if model.cursor < 0 0 else model.cursor + 1)
			else if d.key_pressed(KeyRight) (if model.cursor <= 0 (-1) else model.cursor - 1)
			else model.cursor
		m = d.mouse.position()
		# S writes a PNG of the CURRENT view into ./captures — #372's "session
		# graphic for a training log". Spawned rather than called inline: a
		# screenshot waits for the end of a frame, and update! is not one.
		# The name carries the view so three presses do not overwrite each other.
		_ = if d.key_pressed(KeyS) {
			shot_name = if view == 0 ("form-board.png") else if view == 1 ("power-curve.png") else if view == 2 ("session-trace.png") else "data-table.png"
			Task.spawn!(program_input, || Shot(Capture.screenshot!(shot_name)))
		} else {}
		# on the curve view, 1/2/3 re-window the curve AND its CP fit — a full
		# reload through the same path as R, keeping what the user was looking at
		want_days = if view == 1 (if d.key_pressed(Key1) 30 else if d.key_pressed(Key2) 60 else if d.key_pressed(Key3) 90 else model.curve_days) else model.curve_days
		# on the trace view, [ and ] walk the last dozen structured sessions
		want_sel =
			if view != 2 model.trace_sel
			else if d.key_pressed(KeyLeftBracket) (if model.trace_sel + 1 < List.len(model.trace_ids) (model.trace_sel + 1) else model.trace_sel)
			else if d.key_pressed(KeyRightBracket) (if model.trace_sel > 0 (model.trace_sel - 1) else model.trace_sel)
			else model.trace_sel
		if want_sel != model.trace_sel {
			Ok(switch_trace!(model, want_sel))
		} else if want_days != model.curve_days {
			mouse_now2 = m.y > (if view == 0 (Theme.pad_t + 56.0) else Theme.pad_t) and m.y < I32.to_f32(Theme.win_h) - Theme.pad_b
			match load_model!(model.font, want_days) {
				Ok(fresh) => Ok({ ..fresh, range, view, cursor, mouse_x: m.x, mouse_in: mouse_now2 })
				Err(_) => Ok({ ..model, range, view, cursor, mouse_x: m.x, mouse_in: mouse_now2 })
			}
		} else if d.key_pressed(KeyR) {
			# rebuild from the database, keep what the user was looking at;
			# a failed rebuild keeps the window it had rather than taking it down.
			# Deliberately SYNCHRONOUS inside update!: the stall is bounded (the
			# queries are ms-scale, the fit shell-out the long pole) and follows
			# an explicit keypress — while a spawned rebuild would create Text
			# resources off the frame path, which this platform does not promise
			# to survive. Screenshots spawn because they must wait for frame end;
			# a reload has no such constraint.
			# both arms carry the frame's own input — reload swaps only the data
			mouse_now = m.y > (if view == 0 (Theme.pad_t + 56.0) else Theme.pad_t) and m.y < I32.to_f32(Theme.win_h) - Theme.pad_b
			match load_model!(model.font, model.curve_days) {
				Ok(fresh) => Ok({ ..fresh, range, view, cursor, mouse_x: m.x, mouse_in: mouse_now })
				Err(_) => Ok({ ..model, range, view, cursor, mouse_x: m.x, mouse_in: mouse_now })
			}
		} else {
			Ok({ ..model, range, view, cursor, mouse_x: m.x, mouse_in: m.y > (if view == 0 (Theme.pad_t + 56.0) else Theme.pad_t) and m.y < I32.to_f32(Theme.win_h) - Theme.pad_b })
		}
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
	if model.view == 3 {
		Table.draw!(model, frame)
	} else if model.view == 2 {
		Trace.draw!(model, frame)
	} else if model.view == 1 {
		Curve.draw!(model, frame)
	} else {
		Board.draw!(model, frame)
	}
}
