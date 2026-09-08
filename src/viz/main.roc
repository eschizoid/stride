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
import rr.Mouse
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
		.with_resizable(Bool.True)
		.with_min_size({ width: 980, height: 600 })
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
			{ s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot resolve HOME" }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], st: 0 , tr: [], sg: [], du: 1.0, rd: { day: "", name: "", ago: -1, err: "" }, tids: [], nts: [] }
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
				nts = Db.load_day_notes!(db)
				{ s, e, c, st, tr, sg, du, rd, tids, nts }
			}
			Err(_) => { s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot open ${db_path}" }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], st: 0 , tr: [], sg: [], du: 1.0, rd: { day: "", name: "", ago: -1, err: "" }, tids: [], nts: [] }
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
		head = brand_font!(home, "Quicksand-Medium.ttf", 64, font)
		mono_big = brand_font!(home, "JetBrainsMono-Regular.ttf", 60, font)
		mono = brand_font!(home, "JetBrainsMono-Regular.ttf", 32, font)
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
				{ p: mk!("last 30 days, as of ${as_of}", 15)?, r: 30.U64, chip: mkm!("30d", 12)? },
				{ p: mk!("last 60 days, as of ${as_of}", 15)?, r: 60.U64, chip: mkm!("60d", 12)? },
				{ p: mk!("last 90 days, as of ${as_of}", 15)?, r: 90.U64, chip: mkm!("90d", 12)? },
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
			table_head: [mk!("day", 13)?, mk!("fitness", 13)?, mk!("fatigue", 13)?, mk!("form", 13)?, mk!("load", 13)?, mk!("session", 13)?],
			kpis: [
				{ v: mkb!(Db.fmt1(loaded.s.last.c), 27)?, cap: mk!("fitness - 42-day load avg", 11)?, sel: 0.U8 },
				{ v: mkb!(Db.fmt1(loaded.s.last.a), 27)?, cap: mk!("fatigue - 7-day load avg", 11)?, sel: 1.U8 },
				{ v: mkb!(Db.fmt1(loaded.s.last.t), 27)?, cap: mk!("form - fitness minus fatigue", 11)?, sel: 2.U8 },
			],
			ev_tile_top: mk!(ev_tile.top, 14)?,
			ev_tile_sub: mk!(ev_tile.sub, 11)?,
			zero_note: mk!("fresh above", 11)?,
			ridden_found: loaded.rd.ago >= 0 and loaded.rd.ago <= 7 and loaded.e.day != "",
			ridden_note: mk!("${loaded.rd.name} ridden, ${I64.to_str(loaded.rd.ago)}d ago", 10)?,
			curve_empty: mk!("no rides in the selected window - the curve has nothing to draw", 16)?,
			trace: loaded.tr,
			segs: loaded.sg,
			trace_title: mk!("last structured session - detected blocks shaded behind the power trace", 15)?,
			trace_dur: loaded.du,
			fit_cp: if fit.ok (fit.cp) else 0.0,
			cp_lbl: mkm!("CP ${Db.fmt_f(fit.cp)}W", 12)?,
			data: loaded.s.data,
			days: loaded.s.days,
			home,
			tick: 0,
			last_focus: { view: -1, range: -1, cursor_day: "", trace_day: "" },
			day_notes: loaded.nts,
			status: mk!(loaded.s.err, 16)?,
			has_error: loaded.s.err != "",
			font: mono,
			hint: mk!("1/2/3 range   TAB view   hover or arrows to read a day   R reload   S screenshot   ESC quit", 13)?,
			empty: mk!("no data yet - sync and analyze first, then reopen", 16)?,
			range: 90.U64,
			mouse_x: 0.0,
			mouse_y: 0.0,
			win: { w: I32.to_f32(Theme.win_w), h: I32.to_f32(Theme.win_h) },
			detail_day: "",
			detail: [],
			mouse_in: Bool.False,
			cursor: -1,
		})
}

# The app spawns one kind of task: a screenshot, whose result it ignores —
# a failed shot must not take the window down, and the file's absence is the
# report. Was `[]` while nothing spawned.

# Runs INSIDE a spawned task (Sqlite parks there legally): re-reads one
# session's trace/segments/duration and reports back as a message. Any
# failure keeps the session the window already had.
trace_task! : Str, List({ id : I64, day : Str }), U64 => Msg
trace_task! = |home, ids, sel|
	if home == "" TraceSwitchFailed
	else match List.get(ids, sel) {
		Err(_) => TraceSwitchFailed
		Ok(entry) =>
			match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
				Err(_) => TraceSwitchFailed
				Ok(db) => {
					tr = Db.load_trace!(db, entry.id)
					sg = Db.load_segs!(db, entry.id)
					du = Db.load_dur!(db, entry.id)
					TraceSwitched({ tr, sg, du, sel, day: entry.day })
				}
			}
	}

# One day's story, fetched when a table row is clicked
detail_task! : Str, Str => Msg
detail_task! = |home, day|
	if home == "" DayDetail({ day, lines: [{ title: "no database path", stats: "" }] })
	else match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
		Err(_) => DayDetail({ day, lines: [{ title: "cannot open the database", stats: "" }] })
		Ok(db) => DayDetail({ day, lines: Db.load_day_detail!(db, day) })
	}

# The coach's poll: read-and-consume the newest directive, every 60
# frames (~1s at the capped rate; slower if frames are),
# from a spawned task (Sqlite parks there).
poll_task! : Str => Msg
poll_task! = |home|
	if home == "" DirectiveNone
	else match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
		Err(_) => DirectiveNone
		Ok(db) => match Db.poll_directive!(db) {
			Some(dv) => Directive(dv)
			None => DirectiveNone
		}
	}

# The window's answer: upsert what the human is looking at
focus_task! : Str, { view : I64, range : I64, cursor_day : Str, trace_day : Str } => Msg
focus_task! = |home, f|
	if home == "" FocusWriteFailed
	else match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
		Err(_) => FocusWriteFailed
		Ok(db) => match Db.write_focus!(db, f) {
			Ok(_) => FocusWritten
			Err(_) => FocusWriteFailed
		}
	}

# Reload work is Cmd + Sqlite + text preparation — all of it task-legal and
# none of it update!-legal (the platform panics on Cmd there, by design).
# update! only ever spawns; results come back through these messages.
Msg : [
	Shot(Try({}, Capture.ScreenshotError)),
	Reloaded(Ui.Model),
	ReloadFailed,
	TraceSwitched({ tr : List(F32), sg : List(Db.Seg), du : F32, sel : U64, day : Str }),
	TraceSwitchFailed,
	Directive(Db.Directive),
	DirectiveNone,
	FocusWritten,
	FocusWriteFailed,
	DayDetail({ day : Str, lines : List({ title : Str, stats : Str }) }),
]

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model0, program_input| {
	d = program_input.devices
	# task answers land as messages; fold them in before this frame's input.
	# A finished reload keeps the UI state the user has moved since spawning.
	model = List.fold(program_input.messages, model0, |acc, msg|
		match msg {
			Shot(_) => acc
			ReloadFailed => acc
			TraceSwitchFailed => acc
			DirectiveNone => acc
			FocusWritten => acc
			# a dropped write must not leave the coach stale: resetting
			# last_focus makes the next throttle tick try again
			# only the answer for the day still open lands; a result for a day
			# the user closed or switched away from is dropped
			DayDetail(dd) => if dd.day == acc.detail_day ({ ..acc, detail: dd.lines }) else acc
			FocusWriteFailed => { ..acc, last_focus: { view: -1, range: -1, cursor_day: "", trace_day: "" } }
			Directive(_) => acc
			Reloaded(fresh) => { ..fresh, range: acc.range, view: acc.view, cursor: acc.cursor, mouse_x: acc.mouse_x, mouse_y: acc.mouse_y, mouse_in: acc.mouse_in, tick: acc.tick, last_focus: acc.last_focus, win: acc.win, detail_day: acc.detail_day, detail: acc.detail }
			TraceSwitched(sw) => { ..acc, trace: sw.tr, segs: sw.sg, trace_dur: sw.du, trace_sel: sw.sel, trace_day: sw.day }
		})
	# the coach's word arrives beside the human's input and steers only what
	# it names: view, range, a day for the crosshair, a session for the trace
	directive = List.fold(program_input.messages, { has_d: Bool.False, view: -1, range: -1, cursor_day: "", trace_day: "" }, |acc, msg|
		match msg {
			Directive(dv) => { has_d: Bool.True, view: dv.view, range: dv.range, cursor_day: dv.cursor_day, trace_day: dv.trace_day }
			_ => acc
		})
	if d.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		win = { w: I32.to_f32(program_input.window.size.width), h: I32.to_f32(program_input.window.size.height) }
		m0 = d.mouse.position()
		# the range chips are buttons: a left click inside one selects it. Chip
		# geometry mirrors Board's row exactly - right-anchored at
		# win.w - 420 + i*54, y 64, each 46x22 - and must move with it.
		view_input = if d.key_pressed(KeyTab) (if model.view == 3 0 else model.view + 1) else model.view
		view = if directive.has_d and directive.view >= 0 and directive.view <= 3 (match I64.to_u8_try(directive.view) { Ok(v8) => v8
			Err(_) => view_input }) else view_input
		# chips hit-test against the frame-true view render will draw
		clicked_chip =
			if view == 0 and Mouse.button_pressed(d.mouse, Left) and m0.y >= 64.0 and m0.y <= 86.0 {
				chip0 = win.w - 420.0
				if m0.x >= chip0 and m0.x <= chip0 + 46.0 (30.U64)
				else if m0.x >= chip0 + 54.0 and m0.x <= chip0 + 100.0 (60.U64)
				else if m0.x >= chip0 + 108.0 and m0.x <= chip0 + 154.0 (90.U64)
				else 0.U64
			} else 0.U64
		# 1/2/3 answer to whichever view is showing: the form board's range, or
		# the curve's window — never both at once
		range =
			# a directive's range lands on the view the directive lands on —
			# judged against THIS frame's visible view (post-directive, post-TAB),
			# never the prior frame's. The curve keeps its own window (want_days
			# below), never the form-board range.
			if directive.has_d and view != 1 and (directive.range == 30 or directive.range == 60 or directive.range == 90) (match I64.to_u64_try(directive.range) { Ok(rr) => rr
				Err(_) => model.range }) else
			if clicked_chip > 0 clicked_chip
			# keys judge the same frame-true view the directive rule does — a
			# TAB and a range key in one frame land the range where TAB went
			else if view == 1 model.range
			else if d.key_pressed(Key1) 30.U64
			else if d.key_pressed(Key2) 60.U64
			else if d.key_pressed(Key3) 90.U64
			else model.range
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
		m = m0
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
		# on the curve view "range" MEANS the curve window — a directive saying
		# (view 1, range 30) re-windows the ladder and fit, same as the keys
		want_days =
			if view == 1 and directive.has_d and (directive.range == 30 or directive.range == 60 or directive.range == 90) directive.range
			else if view == 1 (if d.key_pressed(Key1) 30 else if d.key_pressed(Key2) 60 else if d.key_pressed(Key3) 90 else model.curve_days)
			else model.curve_days
		# on the trace view, [ and ] walk the last dozen structured sessions
		want_sel =
			if view != 2 model.trace_sel
			else if d.key_pressed(KeyLeftBracket) (if model.trace_sel + 1 < List.len(model.trace_ids) (model.trace_sel + 1) else model.trace_sel)
			else if d.key_pressed(KeyRightBracket) (if model.trace_sel > 0 (model.trace_sel - 1) else model.trace_sel)
			else model.trace_sel
		# clicking a table row jumps to that day's crosshair on the form board
		# -2 = no directive OR day not in the series: both leave the cursor
		# alone. A found day maps to its days-back index (>= 0).
		cursor_dir =
			if directive.has_d and directive.cursor_day != "" {
				total2 = List.len(model.days)
				List.fold(List.map_with_index(model.days, |dy, di| { dy, di }), -2, |acc, x| if x.dy == directive.cursor_day (match U64.to_i64_try(total2 - 1 - x.di) { Ok(cb2) => cb2
					Err(_) => acc }) else acc)
			} else -2
		# the frame-true pre-click cursor: arrows and directives applied, row
		# clicks not yet - THIS is the scroll state the table renders from,
		# so click and hover hit-tests share it
		cursor_pre = if cursor_dir >= 0 cursor_dir else cursor
		row_hit =
			if view == 3 and Mouse.button_pressed(d.mouse, Left) and m.x >= 36.0 and (if model.detail_day != "" (m.x < win.w / 2.0) else m.x <= win.w - 40.0) and m.y >= 134.0 {
				total = List.len(model.data)
				max_back = if total > 14 (total - 14) else 0.U64
				back = if cursor_pre < 0 (0.U64) else match I64.to_u64_try(cursor_pre) {
					Ok(c) => if c > max_back max_back else c
					Err(_) => 0.U64
				}
				kept = total - back
				rowcount = if kept > 14 (14.U64) else kept
				# floored, not rounded: rounding flips to the NEXT row past a
				# row's midline and made lower-half clicks select the neighbor
				ri = match F32.round_to_u64_try(F32.div_floor_by(m.y - 134.0, 24.0) + 0.1) {
					Ok(r) => r
					Err(_) => 99
				}
				if ri < rowcount and total > 0 {
					dayidx = kept - rowcount + ri
					match U64.to_i64_try(total - 1 - dayidx) {
						Ok(cb) => { hit: Bool.True, cb }
						Err(_) => { hit: Bool.False, cb: -1 }
					}
				} else { hit: Bool.False, cb: -1 }
			} else { hit: Bool.False, cb: -1 }
		# a clicked row opens the day's detail panel in place (same row again
		# closes it); the crosshair follows so tabbing to the board lines up
		clicked_day =
			if row_hit.hit {
				total4 = List.len(model.days)
				match I64.to_u64_try(row_hit.cb) {
					Err(_) => ""
					Ok(cb4) =>
						if cb4 >= total4 ""
						else match List.get(model.days, total4 - 1 - cb4) {
							Ok(dy) => dy
							Err(_) => ""
						}
				}
			} else ""
		detail_day2 = if row_hit.hit (if clicked_day == model.detail_day "" else clicked_day) else model.detail_day
		# spawn unconditionally: detail_task! answers "no database path" itself,
		# so a missing HOME shows that instead of loading... forever
		_ = if row_hit.hit and detail_day2 != "" {
			homed = model.home
			dayd = detail_day2
			Task.spawn!(program_input, || detail_task!(homed, dayd))
		} else {}
		view2 = view
		# a directive naming a day parks the crosshair there
		cursor2 = if row_hit.hit row_hit.cb else cursor_pre
		# reloads and trace switches SPAWN — Cmd panics in update!, and the
		# task lane is where Sqlite and text preparation park legally
		# a directive naming a session day resolves to its picker slot
		want_sel2 =
			if directive.has_d and directive.trace_day != "" {
				List.fold(List.map_with_index(model.trace_ids, |e, ei| { e, ei }), want_sel, |acc, x| if x.e.day == directive.trace_day x.ei else acc)
			} else want_sel
		_ = if want_sel2 != model.trace_sel {
			home2 = model.home
			ids2 = model.trace_ids
			Task.spawn!(program_input, || trace_task!(home2, ids2, want_sel2))
		} else {}
		_ = if want_days != model.curve_days or d.key_pressed(KeyR) {
			f2 = model.font
			Task.spawn!(program_input, || match load_model!(f2, want_days) {
				Ok(m2) => Reloaded(m2)
				Err(_) => ReloadFailed
			})
		} else {}
		over_chip = view2 == 0 and m.y >= 64.0 and m.y <= 86.0 and m.x >= win.w - 420.0 and m.x <= win.w - 266.0
		row_total = List.len(model.data)
		row_maxb = if row_total > 14 (row_total - 14) else 0.U64
		row_back = if cursor2 < 0 (0.U64) else match I64.to_u64_try(cursor2) {
			Ok(c) => if c > row_maxb row_maxb else c
			Err(_) => 0.U64
		}
		row_count = if row_total - row_back > 14 (14.U64) else row_total - row_back
		over_row = view2 == 3 and m.x >= 36.0 and (if detail_day2 != "" (m.x < win.w / 2.0) else m.x <= win.w - 40.0) and m.y >= 134.0 and m.y <= 134.0 + U64.to_f32(row_count) * 24.0
		Mouse.set_cursor!(if over_chip or over_row PointingHand else Default)
		tick = model.tick + 1
		# no HOME means no database path means no bus — spawning would only
		# manufacture failing tasks every tick, forever
		_ = if tick % 60 == 0 and model.home != "" {
			homep = model.home
			Task.spawn!(program_input, || poll_task!(homep))
		} else {}
		# focus mirrors the screen: view, range, the crosshair day, the session
		cur_day =
			if cursor2 < 0 ""
			else {
				total3 = List.len(model.days)
				match I64.to_u64_try(cursor2) {
					Err(_) => ""
					Ok(cb3) =>
						if cb3 >= total3 ""
						else match List.get(model.days, total3 - 1 - cb3) {
							Ok(dy) => dy
							Err(_) => ""
						}
				}
			}
		focus_now = {
			view: match view2 { 0 => 0
				1 => 1
				2 => 2
				_ => 3 },
			# the curve view's window IS its range; the other views report the
			# form board's
			range:
				if view2 == 1 want_days
				else match U64.to_i64_try(range) { Ok(ri) => ri
					Err(_) => 90 },
			cursor_day: cur_day,
			trace_day: model.trace_day,
		}
		last_focus =
			if focus_now != model.last_focus and tick % 30 == 0 and model.home != "" {
				homef = model.home
				_ = Task.spawn!(program_input, || focus_task!(homef, focus_now))
				focus_now
			} else model.last_focus
		Ok({ ..model, range, view: view2, cursor: cursor2, curve_days: want_days, trace_sel: want_sel2, tick, last_focus, win, detail_day: detail_day2, detail: (if detail_day2 != model.detail_day [] else model.detail), mouse_x: m.x, mouse_y: m.y, mouse_in: m.y > (if view2 == 0 (Theme.pad_t + 56.0) else Theme.pad_t) and m.y < win.h - Theme.pad_b })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.rectangle!({ x: 0.0, y: 0.0, width: model.win.w, height: model.win.h, style: Draw.filled(Theme.bg) })
	frame.rounded_rectangle!({ x: 16.0, y: 16.0, width: model.win.w - 32.0, height: model.win.h - 32.0, radius: 14.0, segments: 10, style: Draw.filled(Theme.panel) })
	model.title.draw!(frame, { pos: { x: 34.0, y: 30.0 }, color: Color.white, align: (Top, Left) })
	# Legend belongs to the FORM BOARD only: it draws in the same row the
	# other views put their titles in, and overprinted them.
	if model.view == 0 {
		# the artifact's legend: a 14x3 rounded swatch before each label
		List.for_each!([{ x: 36.0, c: Theme.ctl_c }, { x: 128.0, c: Theme.atl_c }, { x: 226.0, c: Theme.tsb_c }], |sw|
			frame.rounded_rectangle!({ x: sw.x, y: 77.0, width: 14.0, height: 3.0, radius: 1.5, segments: 4, style: Draw.filled(sw.c) }))
		model.leg_fit.draw!(frame, { pos: { x: 56.0, y: 70.0 }, color: Theme.ctl_c, align: (Top, Left) })
		model.leg_fat.draw!(frame, { pos: { x: 148.0, y: 70.0 }, color: Theme.atl_c, align: (Top, Left) })
		model.leg_form.draw!(frame, { pos: { x: 246.0, y: 70.0 }, color: Theme.tsb_c, align: (Top, Left) })
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
