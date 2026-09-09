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
import Heat
import Plan
import Ramp
import Zones
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
			{ s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot resolve HOME" }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], st: 0 , tr: [], sg: [], du: 1.0, rd: { day: "", name: "", ago: -1, err: "" }, tids: [], nts: [], pl: [], wk: { this: 0, last: 0 }, pw: { done: 0, total: 0 }, bn: "", ht: [], hev: [], zw: [], rw: [], prs: [], tcache: [] }
		} else match Sqlite.Db.open!(db_path) {
			Ok(db) => {
				s = Db.load_series!(db)
				e = Db.load_event!(db)
				c = Db.load_curve!(db, curve_days)
				tids = Db.load_trace_ids!(db)
				# the whole picker loads up front (~3ms of SQL per session), so
				# every later switch and ghost summon is a memory read, not a
				# task round-trip - the trace view answers keys instantly
				tcache = load_tcache!(db, tids)
				tr = match List.first(tcache) { Ok(t0) => t0.tr
					Err(_) => [] }
				sg = match List.first(tcache) { Ok(t0) => t0.sg
					Err(_) => [] }
				du = match List.first(tcache) { Ok(t0) => t0.du
					Err(_) => 1.0 }
				st = Db.load_stale!(db)
				pl = Db.load_plan!(db)
				wk = Db.load_week_tss!(db)
				pw = Db.load_plan_week!(db)
				bn = Db.load_bus_note!(db)
				rd = Db.load_ridden!(db)
				ht = Db.load_heat!(db)
				hev = Db.load_event_days!(db)
				zw = Db.load_zone_weeks!(db)
				rw = Db.load_ramp_weeks!(db)
				prs = Db.load_prs!(db)
				nts = Db.load_day_notes!(db)
				{ s, e, c, st, tr, sg, du, rd, tids, nts, pl, wk, pw, bn, ht, hev, zw, rw, prs, tcache }
			}
			Err(_) => { s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot open ${db_path}" }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], st: 0 , tr: [], sg: [], du: 1.0, rd: { day: "", name: "", ago: -1, err: "" }, tids: [], nts: [], pl: [], wk: { this: 0, last: 0 }, pw: { done: 0, total: 0 }, bn: "", ht: [], hev: [], zw: [], rw: [], prs: [], tcache: [] }
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
			fit_lbl: mk!(Db.ascii_safe(fit_text), 14)?,
			curve_title: mk!("power - last ${I64.to_str(curve_days)} days against the record book", 15)?,
			curve_days,
			trace_ids: loaded.tids,
			trace_sel: 0.U64,
			trace_day: match List.first(loaded.tids) {
				Ok(x) => x.day
				Err(_) => ""
			},
			curve_hint: mk!("1/2/3 or chips  window      hover a rung      TAB  session trace      R  reload      S  screenshot      V  record      ESC quit", 13)?,
			trace_hint: mk!("[ / ]  session      shift+[ / shift+]  ghost      wheel zoom  drag pan  0 reset      TAB  data table      R  reload      S  screenshot      V  record      ESC quit", 13)?,
			table_hint: mk!("arrows  scroll days      TAB  plan      R  reload      S  screenshot      V  record      ESC quit", 13)?,
			table_title: mk!("data table", 15)?,
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
			ghost: [],
			ghost_dur: 1.0,
			ghost_sel: -1,
			ghost_day: "",
			trace_zoom: 1.0,
			trace_pan: 0.0,
			trace_cache: loaded.tcache,
			segs: loaded.sg,
			trace_title: mk!("last structured session - detected blocks shaded behind the power trace", 15)?,
			trace_dur: loaded.du,
			fit_cp: if fit.ok (fit.cp) else 0.0,
			cp_lbl: mkm!("CP ${Db.fmt_f(fit.cp)}W", 12)?,
			data: loaded.s.data,
			days: loaded.s.days,
			home,
			tick: 0,
			view_anim: 0,
			last_focus: { view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "" },
			day_notes: loaded.nts,
			plan: loaded.pl,
			week_tss: loaded.wk,
			plan_week: loaded.pw,
			bus_note: loaded.bn,
			heat: loaded.ht,
			heat_events: loaded.hev,
			zone_weeks: loaded.zw,
			ramp_weeks: loaded.rw,
			prs: loaded.prs,
			rec_status: Idle,
			glow: Unbuilt,
			glow_on: Bool.False,
			ramp_title: mk!("the ramp - weekly load and how fast fitness is climbing", 15)?,
			ramp_hint: mk!("hover a week to read it      TAB  form board      R  reload      S  screenshot      V  record      ESC quit", 13)?,
			zones_title: mk!("time in zone - twelve weeks, and the 80/20 story", 15)?,
			zones_hint: mk!("hover a week to read it      TAB  ramp      R  reload      S  screenshot      V  record      ESC quit", 13)?,
			heat_title: mk!("training heat - one cell per day", 15)?,
			heat_hint: mk!("hover a cell to read the day      TAB  zones      R  reload      S  screenshot      V  record      ESC quit", 13)?,
			plan_title: mk!("next 7 days - plan and progress", 15)?,
			plan_hint: mk!("TAB  heat      R  reload      S  screenshot      V  record      ESC quit", 13)?,
			nav: [
				{ p: mk!("form", 13)?, v: 0.U8 },
				{ p: mk!("power", 13)?, v: 1.U8 },
				{ p: mk!("trace", 13)?, v: 2.U8 },
				{ p: mk!("table", 13)?, v: 3.U8 },
				{ p: mk!("plan", 13)?, v: 4.U8 },
				{ p: mk!("heat", 13)?, v: 5.U8 },
				{ p: mk!("zones", 13)?, v: 6.U8 },
				{ p: mk!("ramp", 13)?, v: 7.U8 },
			],
			status: mk!(loaded.s.err, 16)?,
			has_error: loaded.s.err != "",
			font: mono,
			hint: mk!("1/2/3 range   TAB view   hover or arrows to read a day   R reload   S screenshot   V record   G glow   ESC quit", 13)?,
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

# The offscreen pipeline for the glow pass: a window-sized framebuffer, a
# 25-tap bloom shader compiled from source (no asset to ship), and its two
# resolution uniforms. Any refusal degrades to Unavailable - the app then
# draws exactly as it did before the feature existed.
glow_frag : Str
glow_frag = Str.join_with(
	[
		"#version 330",
		"in vec2 fragTexCoord;",
		"in vec4 fragColor;",
		"uniform sampler2D texture0;",
		"uniform float res_x;",
		"uniform float res_y;",
		"out vec4 finalColor;",
		"void main() {",
		"    vec2 px = vec2(2.0 / res_x, 2.0 / res_y);",
		"    vec3 sum = vec3(0.0);",
		"    for (int i = -2; i <= 2; i++) {",
		"        for (int j = -2; j <= 2; j++) {",
		"            vec3 c = texture(texture0, fragTexCoord + vec2(float(i), float(j)) * px).rgb;",
		"            float l = dot(c, vec3(0.299, 0.587, 0.114));",
		"            sum += c * step(0.22, l) * (1.0 - smoothstep(0.68, 0.82, l));",
		"        }",
		"    }",
		"    finalColor = vec4(sum / 25.0 * 0.40, 1.0);",
		"}",
	],
	"\n",
)

build_glow! : { w : F32, h : F32 } => [Unbuilt, Unavailable({ gw : F32, gh : F32 }), Ready({ rt : Draw.RenderTexture, shader : Draw.Shader, rx : Draw.F32Uniform, ry : Draw.F32Uniform, gw : F32, gh : F32 })]
build_glow! = |win|
	# a size that will not convert cleanly is a size we refuse to guess at -
	# the pass exists only window-sized, so failure here degrades like any
	# other refusal instead of allocating a wrong-sized target
	match (F32.round_to_u64_try(win.w), F32.round_to_u64_try(win.h)) {
		(Ok(wu), Ok(hu)) =>
			match (U64.to_i32_try(wu), U64.to_i32_try(hu)) {
				(Ok(wi), Ok(hi)) =>
					match Draw.RenderTexture.load!({ width: wi, height: hi }) {
						Err(_) => Unavailable({ gw: win.w, gh: win.h })
						Ok(rt) =>
							match Draw.Shader.from_source!({ vertex_source: "", fragment_source: glow_frag }) {
								Err(_) => Unavailable({ gw: win.w, gh: win.h })
								Ok(shader) =>
									match Draw.Shader.uniform_f32!(shader, "res_x") {
										Err(_) => Unavailable({ gw: win.w, gh: win.h })
										Ok(rx) =>
											match Draw.Shader.uniform_f32!(shader, "res_y") {
												Err(_) => Unavailable({ gw: win.w, gh: win.h })
												Ok(ry) => Ready({ rt, shader, rx, ry, gw: win.w, gh: win.h })
											}
									}
							}
					}
				_ => Unavailable({ gw: win.w, gh: win.h })
			}
		_ => Unavailable({ gw: win.w, gh: win.h })
	}

# Runs INSIDE a spawned task (Sqlite parks there legally): loads the ghost
# session's trace and duration (no segments - the ghost is a line, not a
# block chart). The caller already cleared the drawn overlay when the
# selection moved, so a failure leaves no ghost, never a stale one.
ghost_task! : Str, List({ id : I64, day : Str }), I64 => Msg
ghost_task! = |home, ids, gsel|
	if home == "" GhostSwitchFailed
	else match I64.to_u64_try(gsel) {
		Err(_) => GhostSwitchFailed
		Ok(gu) => match List.get(ids, gu) {
			Err(_) => GhostSwitchFailed
			Ok(entry) =>
				match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
					Err(_) => GhostSwitchFailed
					Ok(db) => {
						tr = Db.load_trace!(db, entry.id)
						du = Db.load_dur!(db, entry.id)
						GhostSwitched({ tr, du, sel: gsel, day: entry.day })
					}
				}
		}
	}

# Same task lane, the live session: re-reads one session's trace, segments
# and duration and reports back as a message. Any failure keeps the session
# the window already had.
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
	if home == "" DayDetail({ day, lines: [{ title: "no database path", stats: "", extra: "", zones: [] }] })
	else match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
		Err(_) => DayDetail({ day, lines: [{ title: "cannot open the database", stats: "", extra: "", zones: [] }] })
		Ok(db) => DayDetail({ day, lines: Db.load_day_detail!(db, day) })
	}

# The coach's poll: read-and-consume the newest directive, every 60
# frames (~1s at the capped rate; slower if frames are),
# from a spawned task (Sqlite parks there).
# every poll also refreshes the coach corner's note, so the plan view
# shows the directive that actually arrived last, not launch-time state
poll_task! : Str => Msg
poll_task! = |home|
	if home == "" DirectiveNone
	else match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
		Err(_) => DirectiveNone
		Ok(db) => {
			note = Db.load_bus_note!(db)
			match Db.poll_directive!(db) {
				Some(dv) => Directive({ dv, note })
				None => Polled(note)
			}
		}
	}

# The window's answer: upsert what the human is looking at
focus_task! : Str, { view : I64, range : I64, cursor_day : Str, trace_day : Str, ghost_day : Str } => Msg
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
	GhostSwitched({ tr : List(F32), du : F32, sel : I64, day : Str }),
	GhostSwitchFailed,
	Shot(Try({}, Capture.ScreenshotError)),
	RecCmd({}),
	Reloaded(Ui.Model),
	ReloadFailed,
	TraceSwitched({ tr : List(F32), sg : List(Db.Seg), du : F32, sel : U64, day : Str }),
	TraceSwitchFailed,
	Directive({ dv : Db.Directive, note : Str }),
	Polled(Str),
	DirectiveNone,
	FocusWritten,
	FocusWriteFailed,
	DayDetail({ day : Str, lines : List(Db.DayLine) }),
]

# The nav's two densities: wide windows carry icon pills (88px pitch),
# narrow ones fall back to compact text-only pills (76px) so the row never
# runs into the title. ONE predicate, shared by render and both hit-tests.
nav_iconic : F32, U64 -> Bool
nav_iconic = |w, n| w >= 36.0 + U64.to_f32(n) * 88.0 + 540.0

nav_pitch : F32, U64 -> F32
nav_pitch = |w, n| if nav_iconic(w, n) 88.0 else 76.0

nav_width : F32, U64 -> F32
nav_width = |w, n| if nav_iconic(w, n) 80.0 else 68.0

# One entry per pickable session, loaded eagerly: switching and ghost
# summons read this list instead of a task round-trip per keypress.
# Recursion because an effectful body cannot reassign an outer var.
load_tcache! : Sqlite.Db, List({ id : I64, day : Str }) => List({ tr : List(F32), sg : List(Db.Seg), du : F32 })
load_tcache! = |db, ids|
	match List.first(ids) {
		Err(_) => []
		Ok(te) => {
			tr9 = Db.load_trace!(db, te.id)
			sg9 = Db.load_segs!(db, te.id)
			du9 = Db.load_dur!(db, te.id)
			# prepend onto the tail's result rather than appending onto an
			# accumulator: one cons per session instead of a rebuilt list,
			# and picker order survives without a reverse (this stdlib has none)
			List.prepend(load_tcache!(db, List.drop_first(ids, 1)), { tr: tr9, sg: sg9, du: du9 })
		}
	}

# ONE view->basename map for every capture format: png and webm derive
# from it, so the "named for the view" invariant cannot drift per-path
view_basename : U8 -> Str
view_basename = |v|
	if v == 0 "form-board" else if v == 1 "power" else if v == 2 "session-trace" else if v == 3 "data-table" else if v == 4 "plan" else if v == 5 "heat" else if v == 6 "zones" else "ramp"

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model0, program_input| {
	d = program_input.devices
	# task answers land as messages; fold them in before this frame's input.
	# A finished reload keeps the UI state the user has moved since spawning.
	model = List.fold(program_input.messages, model0, |acc, msg|
		match msg {
			Shot(_) => acc
			RecCmd(_) => acc
			ReloadFailed => acc
			TraceSwitchFailed => acc
			GhostSwitchFailed => acc
			# a slow load must not resurrect a dismissed ghost or overwrite a
			# newer pick: only the result matching the current selection lands
			GhostSwitched(gw) => if gw.sel == acc.ghost_sel ({ ..acc, ghost: gw.tr, ghost_dur: gw.du, ghost_day: gw.day }) else acc
			DirectiveNone => acc
			Polled(note) => { ..acc, bus_note: note }
			FocusWritten => acc
			# a dropped write must not leave the coach stale: resetting
			# last_focus makes the next throttle tick try again
			# only the answer for the day still open lands; a result for a day
			# the user closed or switched away from is dropped
			DayDetail(dd) => if dd.day == acc.detail_day ({ ..acc, detail: dd.lines }) else acc
			FocusWriteFailed => { ..acc, last_focus: { view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "" } }
			Directive(d2) => { ..acc, bus_note: d2.note }
			Reloaded(fresh) => { ..fresh, range: acc.range, view: acc.view, cursor: acc.cursor, mouse_x: acc.mouse_x, mouse_y: acc.mouse_y, mouse_in: acc.mouse_in, tick: acc.tick, last_focus: acc.last_focus, win: acc.win, detail_day: acc.detail_day, detail: acc.detail, view_anim: acc.view_anim }
			TraceSwitched(sw) => { ..acc, trace: sw.tr, segs: sw.sg, trace_dur: sw.du, trace_sel: sw.sel, trace_day: sw.day }
		})
	# the coach's word arrives beside the human's input and steers only what
	# it names: view, range, a day for the crosshair, a session for the trace
	directive = List.fold(program_input.messages, { has_d: Bool.False, view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "" }, |acc, msg|
		match msg {
			Directive(d2) => { has_d: Bool.True, view: d2.dv.view, range: d2.dv.range, cursor_day: d2.dv.cursor_day, trace_day: d2.dv.trace_day, ghost_day: d2.dv.ghost_day }
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
		# nav clicks mirror the render geometry exactly (right-anchored pills)
		nav_click =
			if Mouse.button_pressed(d.mouse, Left) and m0.y >= 30.0 and m0.y <= 54.0 {
				nav_n = List.len(model.nav)
				List.fold(List.map_with_index(model.nav, |nv2, vi| { nv2, vi }), -1, |acc, x| {
					nx2 = win.w - 36.0 - U64.to_f32(nav_n - x.vi) * nav_pitch(win.w, nav_n)
					if m0.x >= nx2 and m0.x <= nx2 + nav_width(win.w, nav_n) (U8.to_i64(x.nv2.v)) else acc
				})
			} else -1
		view_input =
			if nav_click >= 0 (match I64.to_u8_try(nav_click) { Ok(v9) => v9
				Err(_) => model.view })
			else if d.key_pressed(KeyTab) (if model.view == 7 0 else model.view + 1) else model.view
		view = if directive.has_d and directive.view >= 0 and directive.view <= 7 (match I64.to_u8_try(directive.view) { Ok(v8) => v8
			Err(_) => view_input }) else view_input
		# chips hit-test against the frame-true view render will draw
		clicked_chip =
			if (view == 0 or view == 1) and Mouse.button_pressed(d.mouse, Left) and m0.y >= 64.0 and m0.y <= 86.0 {
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
			# chips clicked on the power view re-window the curve (below), not this
			if view != 1 and clicked_chip > 0 clicked_chip
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
		# The name carries the VIEW'S OWN NAME (docs: "named for the view") -
		# view 1 is the power view, so its captures are power.png/power.webm,
		# one basename per view across both formats. img/power-curve.png in the
		# docs is a committed illustration, not a capture.
		_ = if d.key_pressed(KeyS) {
			shot_name = Str.concat(view_basename(view), ".png")
			Task.spawn!(program_input, || Shot(Capture.screenshot!(shot_name)))
		} else {}
		# V toggles a recording of whatever is on screen: WebM, full scale,
		# 30fps, FixedStep timing - the deterministic regenerable session
		# graphic #372 promised. Named for the view it started on.
		_ = if d.key_pressed(KeyV) {
			match program_input.capture {
				Active(_) => Task.spawn!(program_input, || RecCmd(Capture.stop!()))
				_ => {
					rec_name = Str.concat(view_basename(view), ".webm")
					# max_frames 0 is the platform's "record until Capture.stop"
					# sentinel, not a zero-frame cap - V is the stop
					rec = Capture.default.with_format(WebM).with_path(rec_name).with_fps(30).with_max_frames(0).with_scale(Full).with_timing(FixedStep)
					Task.spawn!(program_input, || RecCmd(Capture.start!(rec)))
				}
			}
		} else {}
		# on the curve view, 1/2/3 re-window the curve AND its CP fit — a full
		# reload through the same path as R, keeping what the user was looking at
		# on the curve view "range" MEANS the curve window — a directive saying
		# (view 1, range 30) re-windows the ladder and fit, same as the keys
		want_days =
			if view == 1 and directive.has_d and (directive.range == 30 or directive.range == 60 or directive.range == 90) directive.range
			else if view == 1 and clicked_chip > 0 (match U64.to_i64_try(clicked_chip) { Ok(cd9) => cd9
				Err(_) => model.curve_days })
			else if view == 1 (if d.key_pressed(Key1) 30 else if d.key_pressed(Key2) 60 else if d.key_pressed(Key3) 90 else model.curve_days)
			else model.curve_days
		# on the trace view, [ and ] walk the last dozen structured sessions
		shifted = d.key_down(KeyLeftShift) or d.key_down(KeyRightShift)
		want_sel =
			if view != 2 or shifted model.trace_sel
			else if d.key_pressed(KeyLeftBracket) (if model.trace_sel + 1 < List.len(model.trace_ids) (model.trace_sel + 1) else model.trace_sel)
			else if d.key_pressed(KeyRightBracket) (if model.trace_sel > 0 (model.trace_sel - 1) else model.trace_sel)
			else model.trace_sel
		# shift+[ summons/ages the ghost; shift+] youngs it and clears it when
		# it would pass the newest session. -1 is no ghost.
		n_ids = match U64.to_i64_try(List.len(model.trace_ids)) { Ok(ni) => ni
			Err(_) => 0 }
		want_ghost =
			if view != 2 or !shifted model.ghost_sel
			else if d.key_pressed(KeyLeftBracket) {
				start = if model.ghost_sel < 0 (match U64.to_i64_try(model.trace_sel) { Ok(ts9) => ts9 + 1
					Err(_) => 0 }) else model.ghost_sel + 1
				if start < n_ids start else model.ghost_sel
			}
			else if d.key_pressed(KeyRightBracket) (if model.ghost_sel >= 0 (model.ghost_sel - 1) else -1)
			else model.ghost_sel
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
			if view == 3 and Mouse.button_pressed(d.mouse, Left) and m.x >= 36.0 and (if model.detail_day != "" (m.x < Table.panel_edge(win.w)) else m.x < win.w - 40.0) and m.y >= 134.0 {
				total = List.len(model.data)
				w = Table.window_of(total, cursor_pre, Table.rows_fit(win.h))
				kept = w.kept
				rowcount = w.rows
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
		# moving the mouse over the form board's plot un-parks the crosshair:
		# the hover takes over while inside, and nothing lingers on the way
		# out. Only a cursor NOT re-parked this same frame (arrow, directive,
		# row click) clears - deliberate parks always win over drift.
		cursor3 =
			if view2 == 0 and cursor2 == model.cursor and cursor2 >= 0 and (m.x != model.mouse_x or m.y != model.mouse_y) and m.y > Theme.pad_t + 56.0 and m.y < win.h - Theme.pad_b and m.x >= Theme.pad_l and m.x <= win.w - Theme.pad_r {
				-1
			} else cursor2
		# reloads and trace switches SPAWN — Cmd panics in update!, and the
		# task lane is where Sqlite and text preparation park legally
		# a directive naming a session day resolves to its picker slot
		want_sel2 =
			if directive.has_d and directive.trace_day != "" {
				List.fold(List.map_with_index(model.trace_ids, |e, ei| { e, ei }), want_sel, |acc, x| if x.e.day == directive.trace_day x.ei else acc)
			} else want_sel
		# NoSwitch joins List.get's OutOfBounds in one inferred error union -
		# both branches are only ever matched as Err, and the compiler unifies
		# them without an annotation
		switched = if want_sel2 != model.trace_sel (List.get(model.trace_cache, want_sel2)) else Err(NoSwitch)
		_ = if want_sel2 != model.trace_sel and (match switched { Ok(_) => Bool.False
			Err(_) => Bool.True }) {
			# cache miss only - the normal path answers from memory this frame
			home2 = model.home
			ids2 = model.trace_ids
			Task.spawn!(program_input, || trace_task!(home2, ids2, want_sel2))
		} else {}
		# the trace camera: wheel zooms anchored at the cursor's moment, a held
		# left drag pans, 0 resets - and a session switch resets (the window
		# belonged to the old ride)
		wheel = Mouse.wheel_delta(d.mouse)
		zoom_raw =
			if view != 2 model.trace_zoom
			else if d.key_pressed(Key0) 1.0
			else if wheel.y > 0.1 (model.trace_zoom * 1.15)
			else if wheel.y < -0.1 (model.trace_zoom / 1.15)
			else model.trace_zoom
		trace_zoom2 = if want_sel2 != model.trace_sel (1.0) else F32.min(20.0, F32.max(1.0, zoom_raw))
		pan_raw =
			if view != 2 model.trace_pan
			else if d.key_pressed(Key0) or want_sel2 != model.trace_sel 0.0
			else {
				pw9 = win.w - Theme.pad_l - Theme.pad_r
				u9 = F32.min(1.0, F32.max(0.0, (m.x - Theme.pad_l) / pw9))
				if trace_zoom2 != model.trace_zoom {
					# hold the moment under the cursor still through the zoom
					t9 = model.trace_pan + u9 / model.trace_zoom
					t9 - u9 / trace_zoom2
				} else if Mouse.button_down(d.mouse, Left) and m.y > Theme.pad_t and m.y < win.h - Theme.pad_b {
					model.trace_pan - (m.x - model.mouse_x) / pw9 / trace_zoom2
				} else model.trace_pan
			}
		trace_pan2 = F32.min(1.0 - 1.0 / trace_zoom2, F32.max(0.0, pan_raw))
		want_ghost2 =
			if directive.has_d and directive.ghost_day == "none" (-1)
			else if directive.has_d and directive.ghost_day != "" {
				List.fold(List.map_with_index(model.trace_ids, |e, ei| { e, ei }), want_ghost, |acc, x| if x.e.day == directive.ghost_day (match U64.to_i64_try(x.ei) { Ok(gi) => gi
					Err(_) => acc }) else acc)
			} else want_ghost
		ghost_hit =
			if want_ghost2 != model.ghost_sel and want_ghost2 >= 0 {
				match I64.to_u64_try(want_ghost2) { Ok(gu9) => List.get(model.trace_cache, gu9)
					Err(_) => Err(OutOfBounds) }
			} else Err(NoSwitch)
		_ = if want_ghost2 != model.ghost_sel and want_ghost2 >= 0 and (match ghost_hit { Ok(_) => Bool.False
			Err(_) => Bool.True }) {
			home3 = model.home
			ids3 = model.trace_ids
			Task.spawn!(program_input, || ghost_task!(home3, ids3, want_ghost2))
		} else {}
		# any ghost change clears the drawn overlay THIS frame: a dismissal has
		# nothing to fetch, and a switch must not keep showing the old session
		# under the new selection - if the load fails, empty is the clean state
		ghost2 = match ghost_hit { Ok(gc) => gc.tr
			Err(_) => if want_ghost2 != model.ghost_sel ([]) else model.ghost }
		ghost_day2 = match ghost_hit {
			Ok(_) => match I64.to_u64_try(want_ghost2) { Ok(gu8) => (match List.get(model.trace_ids, gu8) { Ok(ge) => ge.day
				Err(_) => "" })
				Err(_) => "" }
			Err(_) => if want_ghost2 != model.ghost_sel ("") else model.ghost_day }
		ghost_dur2 = match ghost_hit { Ok(gc) => gc.du
			Err(_) => model.ghost_dur }
		# a cache-hit session switch lands its data in the same frame. A miss
		# (a task is flying) clears instead of keeping the old ride's trace
		# under the new day - the ghost's contract, applied to the live one.
		switching = want_sel2 != model.trace_sel
		trace2 = match switched { Ok(sc) => sc.tr
			Err(_) => if switching ([]) else model.trace }
		segs2m = match switched { Ok(sc) => sc.sg
			Err(_) => if switching ([]) else model.segs }
		trace_dur2 = match switched { Ok(sc) => sc.du
			Err(_) => if switching (1.0) else model.trace_dur }
		trace_day2 =
			if switching {
				match List.get(model.trace_ids, want_sel2) { Ok(se) => se.day
					Err(_) => model.trace_day }
			} else model.trace_day
		_ = if want_days != model.curve_days or d.key_pressed(KeyR) {
			f2 = model.font
			Task.spawn!(program_input, || match load_model!(f2, want_days) {
				Ok(m2) => Reloaded(m2)
				Err(_) => ReloadFailed
			})
		} else {}
		chip0h = win.w - 420.0
		# per-chip, not one wide band: the 8px gaps between chips are not
		# clickable and must not claim the pointer
		over_chip = (view2 == 0 or view2 == 1) and m.y >= 64.0 and m.y <= 86.0 and ((m.x >= chip0h and m.x <= chip0h + 46.0) or (m.x >= chip0h + 54.0 and m.x <= chip0h + 100.0) or (m.x >= chip0h + 108.0 and m.x <= chip0h + 154.0))
		row_count = Table.window_of(List.len(model.data), cursor2, Table.rows_fit(win.h)).rows
		over_row = view2 == 3 and m.x >= 36.0 and (if detail_day2 != "" (m.x < Table.panel_edge(win.w)) else m.x < win.w - 40.0) and m.y >= 134.0 and m.y < 134.0 + U64.to_f32(row_count) * 24.0
		over_nav = m.y >= 30.0 and m.y <= 54.0 and (List.fold(List.map_with_index(model.nav, |nv3, vi3| { nv3, vi3 }), Bool.False, |acc, x| {
			nx3 = win.w - 36.0 - U64.to_f32(List.len(model.nav) - x.vi3) * nav_pitch(win.w, List.len(model.nav))
			if m.x >= nx3 and m.x <= nx3 + nav_width(win.w, List.len(model.nav)) Bool.True else acc
		}))
		Mouse.set_cursor!(if over_chip or over_row or over_nav PointingHand else Default)
		# a view switch stamps this frame; render fades the new view in from it
		view_anim = if view != model.view model.tick + 1 else model.view_anim
		tick = model.tick + 1
		# no HOME means no database path means no bus — spawning would only
		# manufacture failing tasks every tick, forever
		_ = if tick % 60 == 0 and model.home != "" {
			homep = model.home
			Task.spawn!(program_input, || poll_task!(homep))
		} else {}
		# focus mirrors the screen: view, range, the crosshair day, the session
		cur_day =
			if cursor3 < 0 ""
			else {
				total3 = List.len(model.days)
				match I64.to_u64_try(cursor3) {
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
				3 => 3
				4 => 4
				5 => 5
				6 => 6
				_ => 7 },
			# the curve view's window IS its range; the other views report the
			# form board's
			range:
				if view2 == 1 want_days
				else match U64.to_i64_try(range) { Ok(ri) => ri
					Err(_) => 90 },
			cursor_day: cur_day,
			# both frame-true: a cached switch or summon lands this frame, and
			# the coach's readout must not trail it by one write
			trace_day: trace_day2,
			ghost_day: ghost_day2,
		}
		last_focus =
			if focus_now != model.last_focus and tick % 30 == 0 and model.home != "" {
				homef = model.home
				_ = Task.spawn!(program_input, || focus_task!(homef, focus_now))
				focus_now
			} else model.last_focus
		glow2 =
			match model.glow {
				Ready(g9) => if g9.gw == win.w and g9.gh == win.h (model.glow) else build_glow!(win)
				Unbuilt => build_glow!(win)
				# a refusal is sticky at the size it happened; a resize retries
				Unavailable(u9) => if u9.gw == win.w and u9.gh == win.h (model.glow) else build_glow!(win)
			}
		glow_on2 = if d.key_pressed(KeyG) (!model.glow_on) else model.glow_on
		Ok({ ..model, range, view: view2, cursor: cursor3, rec_status: program_input.capture, glow: glow2, glow_on: glow_on2, trace_zoom: trace_zoom2, trace_pan: trace_pan2, curve_days: want_days, trace_sel: want_sel2, ghost_sel: want_ghost2, ghost: ghost2, ghost_day: ghost_day2, ghost_dur: ghost_dur2, trace: trace2, segs: segs2m, trace_dur: trace_dur2, trace_day: trace_day2, tick, view_anim, last_focus, win, detail_day: detail_day2, detail: (if detail_day2 != model.detail_day [] else model.detail), mouse_x: m.x, mouse_y: m.y, mouse_in: m.y > (if view2 == 0 (Theme.pad_t + 56.0) else Theme.pad_t) and m.y < win.h - Theme.pad_b })
	}
}

# 12x12 vector marks, one per view: iconography drawn from primitives -
# no sprite sheet to ship, crisp at any DPI, colored with its label
nav_icon! : Draw.Frame, U8, F32, F32, Color.Rgba => {}
nav_icon! = |frame, v, x, y, c| {
	if v == 0 {
		# form: a spark line
		frame.line!({ start: { x: x, y: y + 9.0 }, end: { x: x + 4.0, y: y + 3.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.line!({ start: { x: x + 4.0, y: y + 3.0 }, end: { x: x + 8.0, y: y + 7.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.line!({ start: { x: x + 8.0, y: y + 7.0 }, end: { x: x + 12.0, y: y + 1.0 }, stroke: Draw.stroke(c, 1.5) })
	} else if v == 1 {
		# power: a bolt
		frame.line!({ start: { x: x + 8.0, y: y }, end: { x: x + 3.0, y: y + 7.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.line!({ start: { x: x + 3.0, y: y + 7.0 }, end: { x: x + 8.0, y: y + 7.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.line!({ start: { x: x + 8.0, y: y + 7.0 }, end: { x: x + 4.0, y: y + 12.0 }, stroke: Draw.stroke(c, 1.5) })
	} else if v == 2 {
		# trace: a square pulse
		frame.line!({ start: { x: x, y: y + 9.0 }, end: { x: x + 4.0, y: y + 9.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.line!({ start: { x: x + 4.0, y: y + 9.0 }, end: { x: x + 4.0, y: y + 2.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.line!({ start: { x: x + 4.0, y: y + 2.0 }, end: { x: x + 8.0, y: y + 2.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.line!({ start: { x: x + 8.0, y: y + 2.0 }, end: { x: x + 8.0, y: y + 9.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.line!({ start: { x: x + 8.0, y: y + 9.0 }, end: { x: x + 12.0, y: y + 9.0 }, stroke: Draw.stroke(c, 1.5) })
	} else if v == 3 {
		# table: three rows
		frame.rectangle!({ x: x, y: y + 1.0, width: 12.0, height: 2.0, style: Draw.filled(c) })
		frame.rectangle!({ x: x, y: y + 5.0, width: 12.0, height: 2.0, style: Draw.filled(c) })
		frame.rectangle!({ x: x, y: y + 9.0, width: 12.0, height: 2.0, style: Draw.filled(c) })
	} else if v == 4 {
		# plan: a calendar - a faint page under a solid header bar
		frame.rounded_rectangle!({ x: x, y: y + 1.0, width: 12.0, height: 11.0, radius: 2.0, segments: 3, style: Draw.filled(Color.with_alpha(c, 70)) })
		frame.rectangle!({ x: x, y: y + 1.0, width: 12.0, height: 3.0, style: Draw.filled(c) })
	} else if v == 5 {
		# heat: four cells
		frame.rectangle!({ x: x + 1.0, y: y + 1.0, width: 4.5, height: 4.5, style: Draw.filled(c) })
		frame.rectangle!({ x: x + 6.5, y: y + 1.0, width: 4.5, height: 4.5, style: Draw.filled(Color.with_alpha(c, 120)) })
		frame.rectangle!({ x: x + 1.0, y: y + 6.5, width: 4.5, height: 4.5, style: Draw.filled(Color.with_alpha(c, 120)) })
		frame.rectangle!({ x: x + 6.5, y: y + 6.5, width: 4.5, height: 4.5, style: Draw.filled(c) })
	} else if v == 6 {
		# zones: three stacked bars
		frame.rectangle!({ x: x + 1.0, y: y + 7.0, width: 3.0, height: 5.0, style: Draw.filled(c) })
		frame.rectangle!({ x: x + 5.0, y: y + 3.0, width: 3.0, height: 9.0, style: Draw.filled(Color.with_alpha(c, 150)) })
		frame.rectangle!({ x: x + 9.0, y: y + 5.0, width: 3.0, height: 7.0, style: Draw.filled(c) })
	} else {
		# ramp: the climb and its rider
		frame.line!({ start: { x: x, y: y + 11.0 }, end: { x: x + 12.0, y: y + 2.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.circle!({ center: { x: x + 9.0, y: y + 4.0 }, radius: 2.0, style: Draw.filled(c) })
	}
	{}
}

scene! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
scene! = |model, frame| {
	frame.rectangle!({ x: 0.0, y: 0.0, width: model.win.w, height: model.win.h, style: Draw.filled(Theme.bg) })
	frame.rounded_rectangle!({ x: 16.0, y: 16.0, width: model.win.w - 32.0, height: model.win.h - 32.0, radius: 14.0, segments: 10, style: Draw.filled(Theme.panel) })
	# depth without shaders: a whisper of vertical gradient over the panel,
	# then bottom-edge falloff - two gradient strips standing in for a vignette
	frame.rectangle_gradient_v!({ x: 16.0, y: 16.0, width: model.win.w - 32.0, height: (model.win.h - 32.0) * 0.4, color_top: Color.with_alpha(Color.from_hex_rgb(0x232332), 40), color_bottom: Color.with_alpha(Theme.panel, 0) })
	frame.rectangle_gradient_v!({ x: 16.0, y: model.win.h - 96.0, width: model.win.w - 32.0, height: 80.0, color_top: Color.with_alpha(Theme.bg, 0), color_bottom: Color.with_alpha(Theme.bg, 90) })
	model.title.draw!(frame, { pos: { x: 34.0, y: 30.0 }, color: Color.white, align: (Top, Left) })
	# the recording badge lives below the pills on every view: a red dot
	# while filming, a quiet confirmation once the file is written
	_ = match model.rec_status {
		Active(af) => {
			frame.circle!({ center: { x: model.win.w - 148.0, y: 64.0 }, radius: 4.0, style: Draw.filled(Theme.alarm_c) })
			Text.from("rec ${U64.to_str(af.frames)}f   V stops", model.font).size(11).draw!(frame, { pos: { x: model.win.w - 138.0, y: 58.0 }, color: Theme.alarm_c, align: (Top, Left) })
			{}
		}
		Finished(ff) => {
			Text.from("recording saved to captures/ (${U64.to_str(ff.bytes / 1024)}kb)", model.font).size(11).draw!(frame, { pos: { x: model.win.w - 40.0, y: 58.0 }, color: Theme.tsb_c, align: (Top, Right) })
			{}
		}
		Failed(ff2) => {
			why = match ff2.reason {
				PathInvalid | PathEscapesOutputDir => "bad path"
				AlreadyRecording => "already recording"
				BudgetExceeded | OutOfMemory => "out of memory - try again shorter"
				WriteFailed => "could not write captures/"
				EncodeFailed | UnsupportedFormat => "encoder refused webm"
				_ => "unknown"
			}
			Text.from("recording failed: ${why}   V retries", model.font).size(11).draw!(frame, { pos: { x: model.win.w - 40.0, y: 58.0 }, color: Theme.alarm_c, align: (Top, Right) })
			{}
		}
		Idle => {}
	}
	# the nav: every view, visible and clickable, active one filled - TAB
	# stays as the keyboard accelerator
	List.for_each!(List.map_with_index(model.nav, |nv, ni| { nv, ni }), |x| {
		nx = model.win.w - 36.0 - U64.to_f32(List.len(model.nav) - x.ni) * nav_pitch(model.win.w, List.len(model.nav))
		on2 = x.nv.v == model.view
		hov2 = model.mouse_x >= nx and model.mouse_x <= nx + nav_width(model.win.w, List.len(model.nav)) and model.mouse_y >= 30.0 and model.mouse_y <= 54.0
		style2 = if on2 (Draw.filled(Color.with_alpha(Theme.ctl_c, 60))) else if hov2 (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
		frame.rounded_rectangle!({ x: nx, y: 30.0, width: nav_width(model.win.w, List.len(model.nav)), height: 24.0, radius: 7.0, segments: 6, style: style2 })
		ic = if on2 Color.white else Theme.ink_muted
		if nav_iconic(model.win.w, List.len(model.nav)) {
			nav_icon!(frame, x.nv.v, nx + 8.0, 36.0, ic)
			x.nv.p.draw!(frame, { pos: { x: nx + 46.0, y: 35.0 }, color: ic, align: (Top, Center) })
		} else {
			x.nv.p.draw!(frame, { pos: { x: nx + 34.0, y: 35.0 }, color: ic, align: (Top, Center) })
		}
	})
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
	drawn =
		if model.view == 7 {
			Ramp.draw!(model, frame)
		} else if model.view == 6 {
			Zones.draw!(model, frame)
		} else if model.view == 5 {
			Heat.draw!(model, frame)
		} else if model.view == 4 {
			Plan.draw!(model, frame)
		} else if model.view == 3 {
			Table.draw!(model, frame)
		} else if model.view == 2 {
			Trace.draw!(model, frame)
		} else if model.view == 1 {
			Curve.draw!(model, frame)
		} else {
			Board.draw!(model, frame)
		}
	# the crossfade: for ten frames after a switch, a panel-colored veil
	# fades off the incoming view - ease-out, cheap, and one rectangle
	age = model.tick - model.view_anim
	if model.view_anim > 0 and age < 10 {
		fade = 10 - age
		a = match U64.to_u8_try(fade * fade * 2) { Ok(v) => v
			Err(_) => 0 }
		frame.rectangle!({ x: 16.0, y: 16.0, width: model.win.w - 32.0, height: model.win.h - 32.0, style: Draw.filled(Color.with_alpha(Theme.panel, a)) })
	} else {}
	drawn
}

# The frame's last word: with a working pipeline and the glow on, the scene
# renders into the offscreen target and comes back twice - the base image,
# then the bright parts blurred and added on top. Any other state draws the
# scene directly, exactly as the app rendered before shaders existed.
render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	match model.glow {
		Ready(g) =>
			if model.glow_on {
				# a refused scope means nothing was drawn - fall back to the
				# direct path; scene errors (Exit) pass through untouched
				match frame.with_render_texture!(g.rt, |f| scene!(model, f)) {
					Err(_) => scene!(model, frame)
					Ok(_) => {
						td = { texture: g.rt.texture(), source: g.rt.source(), dest: { x: 0.0, y: 0.0, width: model.win.w, height: model.win.h }, origin: { x: 0.0, y: 0.0 }, rotation: 0.0, tint: Color.white }
						frame.texture!(td)
						g.rx.set!(model.win.w)
						g.ry.set!(model.win.h)
						# the glow blits over the base; if either scope refuses,
						# the base image already stands and the discard is safe
						_ = frame.with_blend_mode!(Additive, |f2|
							f2.with_shader!(g.shader, |f3| {
								f3.texture!(td)
								Ok({})
							}))
						Ok({})
					}
				}
			} else scene!(model, frame)
		_ => scene!(model, frame)
	}
}
