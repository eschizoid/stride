## Stride — the viz suite's window over ~/.stride/db.sqlite, read
## at launch. The modules beside this file carry the parts: Theme (geometry +
## palette), Db (every loader and its types), Ui (the Model), and one module
## per view. This file owns the app contract: the platform pin, Model/Msg,
## init!, update!, and the view dispatch — view_basename enumerates the views
## and the nav list is their order.
##
## The header names no compiler, and neither does roc-ray: the window builds on
## the repo's one nightly pin, the same compiler the engine builds on. It names
## the http package roc-ray's requests and responses are written in, for the
## street map's tile fetches.
app [Model, program] { core: "../core/package.roc", http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst", rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.12.2/A8Dt5CorYsEtHFh8h7SfMtpzSy73UWbaB5Twy9JoYS1U.tar.zst" }

import rr.App
import rr.Assets
import rr.Capture
import rr.Camera
import rr.Color
import rr.Draw
import rr.Mouse
import rr.Shader
import rr.Sqlite
import rr.Task
import rr.Text
import rr.Texture
import rr.Time
import rr.Window
import core.Bus
import core.Series
import core.Units
import http.Request
import http.Response
import Board
import Heat
import Geo
import Map
import Motion
import Mvt
import Plan
import Ramp
import Zones
import Table
import Curve
import Career
import Chrome
import Days
import Weeks
import Db
import Scroll
import Strength
import DisplayScale
import Hud
import Labels
import Gate
import Scene
import Theme
import Tiles
import Trace
import Ui

Model : Ui.Model

program = { init!, update!, render! }

# What the window may touch, declared in the source the way this platform
# requires. The athlete's own directory is the one grant that cannot be
# written here as a literal: it lives under a home directory known only at
# run time, and a declaration is decided from the text of the path. So the
# launcher resolves it and passes it as the first argument, and the config is
# built from argv. Launched without one, the window still opens — it declares
# nothing beyond the launch directory, the two programs and the tile origin,
# and says on its face that it has no database.
#
# The launch-directory grant is read-only: for `just viz` that is the checkout
# (the dev-run assets/fonts and img), and for the packaged launchers, which
# change to the home directory before they exec, it is the athlete's home.
# The engine is named exactly, and `sh` beside it for the one script that asks
# `date` for the zone offset under the configured timezone; the same `sh`
# reports the working directory a capture's path is reported under. Captures
# need no grant: the platform writes them beneath the configured output
# directory, `capture_dir`, relative to the working directory. The one network
# origin is OpenFreeMap's, which serves the street map's TileJSON and its
# tiles (Tiles); a redirect to any other origin is refused.
stride_dir_of : List(Str) -> Str
stride_dir_of = |args| match List.get(args, 1) {
	Ok(a) => a
	Err(_) => ""
}

# the directory the window was launched from, as the launcher passed it
# second, read in init! (the one place argv may be read). It is the model's
# cwd until load asks `pwd` for the real working directory, and stays the
# cwd if that fails; "" when the launcher passed none
launch_dir_of : List(Str) -> Str
launch_dir_of = |args| match List.get(args, 2) {
	Ok(a) => a
	Err(_) => ""
}

config_for_args : List(Str) -> App.Config
config_for_args = |args| {
	base =
		App.default
			.with_title("Stride")
			.with_size({ width: Theme.win_w, height: Theme.win_h })
			.with_frame_pacing(Capped(60))
			.with_resizable(Bool.True)
			# ESC is handled by update!, not by raylib's own exit key: quitting first
			# clears the focus row so a coach never reads a closed window as live, and
			# only a frame the window drives can spawn that write before it exits
			.with_exit_key(NoExitKey)
			.with_min_size({ width: DisplayScale.min_width, height: DisplayScale.min_height })
			.with_output_dir(capture_dir)
			.with_permission(WorkingDirectory(ReadOnly))
			.with_permission(Command("stride"))
			.with_permission(Command("sh"))
			.with_permission(HttpOrigin("https://tiles.openfreemap.org"))
	dir = stride_dir_of(args)
	if (dir == "") base else base.with_permission(Directory(dir, ReadWrite))
}

# the launcher's two arguments land where the loaders read them, and the
# config grants exactly the five facilities the window uses: the athlete's
# directory read-write, the launch directory read-only, the two programs and
# the tile origin, whose URL is the one Tiles fetches from; launched with no
# directory it grants four
expect {
	args = ["stride-viz", "/h/.stride", "/h"]
	p = config_for_args(args).permissions()
	stride_dir_of(args) == "/h/.stride" and launch_dir_of(args) == "/h"
		and stride_dir_of(["stride-viz"]) == "" and launch_dir_of(["stride-viz", "/h/.stride"]) == ""
		and List.contains(p, Command("stride")) and List.contains(p, Command("sh"))
		and List.contains(p, Directory("/h/.stride", ReadWrite)) and List.contains(p, WorkingDirectory(ReadOnly))
		and List.contains(p, HttpOrigin("https://tiles.openfreemap.org")) and Tiles.origin_url == "https://tiles.openfreemap.org"
		and List.len(p) == 5 and List.len(config_for_args(["stride-viz"]).permissions()) == 4
}

# the path a capture reports is the working directory joined to the very
# output dir the platform is configured with, so the two cannot name
# different directories
expect {
	out = config_for_args(["stride-viz", "/h/.stride", "/elsewhere"]).output_dir()
	capture_path("/w", "form-board.png") == Str.concat("/w/", Str.concat(out, "/form-board.png"))
		and capture_path("", "form-board.png") == Str.concat(out, "/form-board.png")
}

# the athlete's directory and the authority to reach it, together: every
# loader below opens its own handle from these, because a Dir may be opened
# in init! or in a task and never in update!, and each task does its own open.
Access : { io : App.Io, dir : Str }

init! : App.Init(Model, [AssetPathInvalid, AssetNotFound, AssetReadFailed, FontLoadFailed, ResourceLimit])
init! = App.init_for_args(
	config_for_args,
	|io| {
		font = Draw.default_font!()
		args = io.args!()
		load_model!({ io, dir: stride_dir_of(args) }, launch_dir_of(args), font, 90, "", Bool.True)
	},
)

# The database the engine writes, opened from the declared directory. Opening
# creates nothing that matters: the directory is the athlete's own and the
# engine made it long before the window ran.
open_db! : Access => Try(Sqlite.Db, [NoStrideDir, Unreachable])
open_db! = |acc|
	if (acc.dir == "") Err(NoStrideDir)
	else match acc.io.files().open_dir!(acc.dir) {
		Err(_) => Err(Unreachable)
		Ok(d) => match acc.io.sqlite().open!(d, "db.sqlite") {
			Ok(db) => Ok(db)
			Err(_) => Err(Unreachable)
		}
	}

# a file the athlete's directory holds, or [] when it does not
stride_bytes! : Access, Str => List(U8)
stride_bytes! = |acc, rel|
	if (acc.dir == "") []
	else match acc.io.files().open_dir_read!(acc.dir) {
		Err(_) => []
		Ok(d) => match d.read_bytes!(rel) {
			Ok(b) => b
			Err(_) => []
		}
	}

# a file the checkout holds, or [] when it does not
checkout_bytes! : Access, Str, Str => List(U8)
checkout_bytes! = |acc, sub, name|
	match acc.io.files().open_dir_read!(sub) {
		Err(_) => []
		Ok(d) => match d.read_bytes!(name) {
			Ok(b) => b
			Err(_) => []
		}
	}

# One brand face at one size, from wherever it lives: the repo's assets/ in a
# dev checkout, ~/.stride/fonts when launched from a packaged app, and the
# platform default font when neither answers — the board must open regardless.
brand_font! : Access, Str, I32, Text.Font => Text.Font
brand_font! = |acc, name, size, fallback| {
	from_checkout = checkout_bytes!(acc, "assets/fonts", name)
	bytes = if (!List.is_empty(from_checkout)) from_checkout else stride_bytes!(acc, "fonts/${name}")
	if (List.is_empty(bytes)) fallback
	else match Draw.font_from_bytes!({ format: Ttf, bytes, size }) {
		Ok(f) => f
		Err(_) => fallback
	}
}

# an authored PNG from img/: the repo's in a dev checkout, ~/.stride/img
# when launched from a packaged app (each package's launcher seeds it the
# way it seeds fonts). Err when neither place has it or it does not decode.
img_texture! : Access, Str => Try(Texture.Texture, [NoImage])
img_texture! = |acc, name| {
	from_checkout = checkout_bytes!(acc, "img", name)
	bytes = if (!List.is_empty(from_checkout)) from_checkout else stride_bytes!(acc, Str.concat("img/", name))
	if (List.is_empty(bytes)) Err(NoImage)
	else match Assets.texture_from_bytes!({ format: Png, bytes }) {
		Ok(t) => Ok(t)
		Err(_) => Err(NoImage)
	}
}

# the mark is splash-only, so nothing loads it outside boot
load_logo! : Access, Bool => [NoLogo, Logo(Texture.Texture)]
load_logo! = |acc, boot|
	if (!boot) NoLogo
	else match img_texture!(acc, "stride-icon.png") {
		Ok(t) => Logo(t)
		Err(_) => NoLogo
	}

# the flame loads once at boot; Reloaded carries the boot model's texture
# forward, so a later load has nothing to read
load_flame! : Access, Bool => [NoFlame, Flame(Texture.Texture)]
load_flame! = |acc, boot|
	if (!boot) NoFlame
	else match img_texture!(acc, "flame.png") {
		Ok(t) => Flame(t)
		Err(_) => NoFlame
	}

# The empty shape every loader falls back to: the boot skeleton the splash
# renders over, and the answer when there is no database to read. The series
# error is the only part that varies, and it is what the board prints on its
# face, so a window that cannot reach the athlete's data says why.
skeleton : Str -> _
skeleton = |err|
	{ s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], cpv: [], st: 0, tr: [], sg: [], du: 1.0, rd: { day: "", name: "", ago: -1, err: "" }, tids: [], nts: [], pl: [], wk: { this: 0, last: 0 }, pw: { done: 0, total: 0 }, bn: NoDirective, ht: [], hev: [], zw: [], ph: "", b20: -1, tg: [], rw: [], csp: [], ctm: [], cs: [], cfm: [], prs: [], tcache: [], un: Metric, cf: "", keys: { power: [], pace: [] }, ptg: [], sv: Db.empty_strength_view, thr: 0.0 }

# Everything the window knows, rebuilt from the local stride sources in one
# call: the database for every series, plus the engine's power-curve
# command for the CP fit. boot=True builds the instant skeleton the splash
# renders over, with no database and no engine call, so the window opens
# on frame one; the real load runs in a spawned task that answers with
# Reloaded, at launch and again on R.
load_model! : Access, Str, Text.Font, I64, Str, Bool => Try(Ui.Model, [ResourceLimit])
load_model! = |acc, cwd, font, curve_days, curve_family, boot| {
	loaded = if boot {
		skeleton("")
	} else match open_db!(acc) {
		Ok(db) => {
			Db.publish_caps!(db, caps_views, caps_fields)
			s = Db.load_series!(db)
			e = Db.load_event!(db)
			tm = Db.today_mod!(acc.io.commands(), db)
			# the curve the window opens on: the one asked for, or at launch the
			# athlete's most-trained family's (Db.default_curve)
			keys = Db.load_curve_keys!(db)
			cf = if (curve_family == "") Db.default_curve(keys, Db.load_top_family!(db, tm)) else curve_family
			c = Db.load_curve!(db, curve_days, tm, cf)
			tids = Db.load_trace_ids!(db)
			# ONLY the newest session is cached by the load. The roc-ray
			# SQLite binding marshals result rows one at a time, and each
			# session's downsampled trace is a long run of rows, so caching
			# the whole picker would delay the load by every session's rows.
			# A switch or ghost summon to an uncached session falls through
			# to the one-session load the cache-miss path spawns (trace_task!
			# / ghost_task!), so the cost is paid per session looked at.
			un = Db.units!(db)
			tcache = load_tcache!(db, un, List.take_first(tids, 1))
			tr = match List.first(tcache) {
				Ok(t0) => t0.tr
				Err(_) => []
			}
			sg = match List.first(tcache) {
				Ok(t0) => t0.sg
				Err(_) => []
			}
			du = match List.first(tcache) {
				Ok(t0) => t0.du
				Err(_) => 1.0
			}
			st = Db.load_stale!(db)
			pl = Db.load_plan_at!(db, tm)
			wk = Db.load_week_tss!(db)
			pw = Db.load_plan_week_at!(db, tm)
			bn = Db.load_bus_note!(db)
			rd = Db.load_ridden!(db)
			ht = Db.load_heat!(db)
			hev = Db.load_event_days!(db)
			zw = Db.load_zone_weeks!(db)
			b20 = Db.load_best20_age!(db, curve_days, tm, cf)
			thr = Db.load_threshold!(db, cf)
			tg = Db.load_targets_at!(db, tm)
			ptg = Db.load_pace_targets_at!(db, tm)
			ph = Db.load_plan_horizon!(db)
			cs = Db.load_career_sports!(db)
			sfs = Career.cycle_fams(Db.load_spine_fams!(db), cs)
			csp = Db.load_career_spines!(db, sfs, tm)
			ctm = Db.load_test_months!(db)
			cfm = Db.load_fam_months!(db)
			rw = Db.load_ramp_weeks!(db)
			prs = Db.load_prs!(db, cf)
			nts = Db.load_day_notes!(db)
			cpv = Db.load_curve_prev!(db, curve_days, tm, cf)
			sv = Db.load_strength_view!(db, tm)
			{ s, e, c, cpv, st, tr, sg, du, rd, tids, nts, pl, wk, pw, bn, ht, hev, zw, ph, b20, tg, rw, csp, ctm, cs, cfm, prs, tcache, un, cf, keys, ptg, sv, thr }
		}
		Err(NoStrideDir) => skeleton("no stride directory — the launcher passes it as the first argument")
		Err(Unreachable) => skeleton("cannot open ${acc.dir}/db.sqlite")
	}
	# the curve on screen: what the load chose, the ride power curve when
	# the database could not answer, and still unchosen while booting; then
	# the fit, which runs the engine, so the skeleton skips it
	cf = if (boot) curve_family else if (loaded.cf == "") "Ride" else loaded.cf
	ft = if (boot) ({ fit: { cp: 0.0, w_prime: 0.0, r2: 0.0, points: 0.0, ok: Bool.False }, test: { value: 0.0, kind: "none", date: "none" } }) else Db.load_fit!(acc.io.commands(), curve_days, cf)
	fit = ft.fit
	fit_text = Curve.anchor_caption_for(cf, loaded.un, fit, ft.test, loaded.b20)
	# the board projects as far as the written plan reaches, never past the
	# next event (load_plan_horizon! caps it there), and reads the numbers
	# and the day-by-day series from the engine's own walk
	proj = if (boot or loaded.ph == "") Db.no_projection else Db.load_projection!(acc.io.commands(), loaded.ph)
	proj_days = if (proj.ok) proj.days else []
	# the event marker finds its day among the measured days and then the
	# projected ones, so an event the plan reaches is marked where it falls
	ev = Db.find_idx(List.concat(loaded.s.days, List.map(proj_days, |d| d.day)), loaded.e.day)
	# the lines end on the projection's last day when there is one
	line_data = List.concat(loaded.s.data, List.map(proj_days, Board.proj_point))
	# Quicksand carries prose; JetBrains Mono carries data. Small labels
	# use an atlas close to their displayed size: shrinking title-sized
	# glyphs to captions loses thin strokes between samples. Titles and
	# KPI digits have their own larger atlases. Missing fonts fall back
	# to the platform's built-in face.
	head = brand_font!(acc, "Quicksand-Medium.ttf", 24, font)
	title_font = brand_font!(acc, "Quicksand-Medium.ttf", 48, font)
	mono_big = brand_font!(acc, "JetBrainsMono-Regular.ttf", 48, font)
	mono = brand_font!(acc, "JetBrainsMono-Regular.ttf", 24, font)
	mk! = |txt, sz| Text.from(txt, if (sz >= 24) title_font else head).size(sz).prepare!()
	mkm! = |txt, sz| Text.from(txt, mono).size(sz).prepare!()
	mkb! = |txt, sz| Text.from(txt, mono_big).size(sz).prepare!()
	# a prose copy that keeps the string and size it was prepared from
	mkt! = |txt, sz| mk!(txt, sz).map_ok(|p| { p, s: txt, size: sz })
	curve_lbls = List.map_try!(
		loaded.c,
		|c| {
			p = mkm!(I64.to_str(c.dur_s), 12)?
			Ok({ p, d: c.dur_s })
		},
	)?
	ylabels = List.map_try!(
		[-30, -20, -10, 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
		|v| {
			p = mkm!(Board.y_text(v), 12)?
			Ok({ p, v: I64.to_f32(v) })
		},
	)?
	ends = List.map_try!(
		[
			{ s: Board.end_text(line_data, 0), k: 0.U8 },
			{ s: Board.end_text(line_data, 1), k: 1.U8 },
			{ s: Board.end_text(line_data, 2), k: 2.U8 },
		],
		|e| {
			p = mkm!(e.s, 13)?
			Ok({ p, sel: e.k })
		},
	)?
	as_of = Board.as_of(loaded.s.days)
	# the event tile prefers the future; an event inside the last week still
	# gets its "done" moment, in words that fit any sport; otherwise the slot
	# says so
	ev_tile =
		if loaded.e.day != "" {
			{ top: loaded.e.name, sub: if (loaded.e.ahead == 0) ("today, ${loaded.e.day}") else "in ${I64.to_str(loaded.e.ahead)}d, ${loaded.e.day}" }
		} else if loaded.rd.ago >= 0 and loaded.rd.ago <= 7 {
			{ top: loaded.rd.name, sub: "done, ${I64.to_str(loaded.rd.ago)}d ago" }
		} else {
			{ top: "no event planned", sub: "stride event add <date> <name>" }
		}
	ev_name = Board.ev_name(head, ev_tile.top)
	initial_layout = DisplayScale.layout(DisplayScale.default_percent, { w: I32.to_f32(Theme.win_w), h: I32.to_f32(Theme.win_h) })
	Ok({
		title: mk!(Chrome.wordmark, 30)?,
		subs: [
			{ p: mk!(Board.sub_text(30, as_of), 15)?, r: 30.U64, chip: mkm!("30d", 12)? },
			{ p: mk!(Board.sub_text(60, as_of), 15)?, r: 60.U64, chip: mkm!("60d", 12)? },
			{ p: mk!(Board.sub_text(90, as_of), 15)?, r: 90.U64, chip: mkm!("90d", 12)? },
		],
		leg_fit: mk!("Fitness", 15)?,
		leg_fat: mk!("Fatigue", 15)?,
		leg_form: mk!("Form", 15)?,
		ylabels,
		ends,
		ev_label: mkt!(loaded.e.name, 13)?,
		ev_found: ev.found,
		ev_idx: ev.idx,
		ev_warn: mkt!(if (loaded.e.err != "") loaded.e.err else loaded.rd.err, 13)?,
		ev_warn_found: loaded.e.err != "" or loaded.rd.err != "",
		stale: mk!(Board.stale_text(loaded.s.days), 13)?,
		stale_found: loaded.st > 0,
		view: 0,
		curve: loaded.c,
		curve_prev: loaded.cpv,
		curve_lbls: curve_lbls,
		fit_lbl: mk!(Db.ascii_safe(fit_text), 14)?,
		curve_title: mk!(Curve.title_text(cf, curve_days), 15)?,
		curve_days,
		curve_family: cf,
		show_short: Curve.show_short_at_boot,
		curve_keys: loaded.keys,
		pace_targets: loaded.ptg,
		trace_ids: loaded.tids,
		trace_sel: 0.U64,
		trace_gen: 0.U64,
		trace_refetch: Bool.False,
		trace_loading: Bool.False,
		ghost_loading: Bool.False,
		trace_day: match List.first(loaded.tids) {
			Ok(x) => x.day
			Err(_) => ""
		},
		trace_unit: match List.first(loaded.tcache) {
			Ok(t1) => t1.un
			Err(_) => "W"
		},
		trace_splits: match List.first(loaded.tcache) {
			Ok(t2) => t2.sp
			Err(_) => []
		},
		trace_sets: match List.first(loaded.tcache) {
			Ok(t2) => t2.st
			Err(_) => { rows: [], pasted: Bool.False }
		},
		units: loaded.un,
		trace_sport: "",
		curve_hint: mk!(Curve.hint_text, 13)?,
		trace_hint: mk!(Trace.hint_text, 13)?,
		table_hint: mk!(Table.hint_text, 13)?,
		table_title: mk!(Table.title_text, 15)?,
		table_head: List.map_try!(Table.head_texts, |t| mk!(t, 13))?,
		kpis: [
			{ v: mkb!(Board.kpi_value(loaded.s.data, 0), 27)?, cap: mk!(Board.kpi_caption(0), 11)?, sel: 0.U8 },
			{ v: mkb!(Board.kpi_value(loaded.s.data, 1), 27)?, cap: mk!(Board.kpi_caption(1), 11)?, sel: 1.U8 },
			{ v: mkb!(Board.kpi_value(loaded.s.data, 2), 27)?, cap: mk!(Board.kpi_caption(2), 11)?, sel: 2.U8 },
		],
		ev_tile_name: List.map_try!(ev_name.lines, |l| mkt!(l, ev_name.size))?,
		ev_tile_proj: List.map_try!(Board.proj_lines(loaded.ph, loaded.e.day, proj), |l| mkt!(l, 10))?,
		proj: proj_days,
		proj_key: mkt!(Board.proj_key_text(proj.considered, proj.projected), 11)?,
		ev_tile_sub: mkt!(ev_tile.sub, 11)?,
		zero_note: mk!(Board.zero_text, 11)?,
		ridden_found: loaded.rd.ago >= 0 and loaded.rd.ago <= 7 and loaded.e.day != "",
		ridden_note: mkt!(Board.ev_line(head, loaded.rd.name, " done, ${I64.to_str(loaded.rd.ago)}d ago", 10.0), 10)?,
		curve_empty: mk!("no rides in the selected window - the curve has nothing to draw", 16)?,
		trace: loaded.tr,
		ghost: [],
		ghost_dur: 1.0,
		ghost_sel: -1,
		ghost_gen: 0.U64,
		quitting: Bool.False,
		quit_tick: 0.U64,
		focus_cleared: Bool.False,
		quit_mark_pending: -1.I64,
		ghost_day: "",
		trace_zoom: 1.0,
		lifts_off: 0,
		last_off: 0,
		week_off: 0,
		week_cursor: "",
		trace_pan: 0.0,
		trace_cache: loaded.tcache,
		segs: loaded.sg,
		trace_dur: loaded.du,
		fit_cp: Curve.anchor_line(cf, fit, ft.test),
		curve_info: { fit, test: ft.test, thr: loaded.thr, best20_age: loaded.b20 },
		plan_targets: loaded.tg,
		cp_lbl: mkm!(Curve.anchor_tag(cf, loaded.un, fit, ft.test), 12)?,
		data: loaded.s.data,
		days: loaded.s.days,
		stride_dir: acc.dir,
		cwd: if (boot) cwd else Db.working_dir!(acc.io.commands(), cwd),
		tick: 0,
		last_active: 0,
		view_anim: 0,
		last_focus: { view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, detail_day: "", sport: "", family: "", curve_family: "", curve_short: -1, map_id: -1 },
		day_notes: loaded.nts,
		plan: loaded.pl,
		week_tss: loaded.wk,
		plan_week: loaded.pw,
		bus_note: loaded.bn,
		heat: loaded.ht,
		strength: loaded.sv,
		heat_events: loaded.hev,
		zone_weeks: loaded.zw,
		career_spines: loaded.csp,
		career_tests: loaded.ctm,
		career_sports: loaded.cs,
		career_fam_months: loaded.cfm,
		spine_idx: 0,
		ramp_weeks: loaded.rw,
		prs: loaded.prs,
		rec_status: Idle,
		pending_capture: NoCapture,
		rec_path: "",
		glow: Unbuilt,
		last_directive: { id: -1.I64, refused: "", result: "" },
		glow_on: Bool.False,
		map: Db.no_map,
		map_load: Unloaded,
		map_gen: 0,
		map_stale: Bool.False,
		map_cam: Map.unpainted,
		map_moved: Bool.False,
		map_drag: Idle,
		map_card: Closed,
		map_rt: NoTarget,
		map_paint: Bool.False,
		map_painted: Map.unpainted,
		map_painted_view: 0,
		map_heat: Unbuilt,
		map_play: { secs: 0.0, paused: Bool.False },
		map_speed: Unbuilt,
		map_marks: Stale,
		map_tiles: [],
		map_source: Unasked,
		map_planned: { cam: Map.unpainted, tick: 0 },
		map_plan_due: Bool.True,
		map_cache_err: "",
		ramp_title: mk!(Ramp.title_text, 15)?,
		ramp_hint: mk!(Ramp.hint_text, 13)?,
		zones_title: mk!(Zones.title_text, 15)?,
		zones_hint: mk!(Zones.hint_text, 13)?,
		heat_title: mk!(Heat.title_text, 15)?,
		heat_hint: mk!(Heat.hint_text, 13)?,
		plan_title: mk!(Plan.title_text, 15)?,
		plan_hint: mk!(Plan.hint_text, 13)?,
		nav: List.map_try!(Chrome.nav_views, |v| Ok({ p: mk!(Chrome.nav_name(v), 13)?, v }))?,
		status: mkt!(if (boot) "" else loaded.s.err, 16)?,
		has_error: !boot and loaded.s.err != "",
		booting: boot,
		# a freshly loaded model is never mid-reload; the flag is raised in
		# update! when a chip/R spawns the next load and cleared when it lands
		reloading: Bool.False,
		logo: load_logo!(acc, boot),
		flame: load_flame!(acc, boot),
		font: mono,
		prose: head,
		hint: mk!(Board.hint_text, 13)?,
		empty: mk!(Board.empty_text, 16)?,
		range: 90.U64,
		mouse_x: 0.0,
		mouse_y: 0.0,
		win: { w: initial_layout.w, h: initial_layout.h },
		ui_percent: DisplayScale.default_percent,
		ui_scale: initial_layout.scale,
		detail_day: "",
		detail: [],
		mouse_in: Bool.False,
		cursor: -1,
		cursor_ahead: 0,
	})
}

# The offscreen pipeline for the glow pass: a window-sized framebuffer, a
# 25-tap bloom shader compiled from source (no asset to ship), and its two
# resolution uniforms. Any refusal degrades to Unavailable, and the window
# then draws without the glow.
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

build_glow! : { w : F32, h : F32 } => [Unbuilt, Unavailable({ gw : F32, gh : F32 }), Ready({ rt : Draw.RenderTexture, shader : Shader({ res_x : F32, res_y : F32 }), gw : F32, gh : F32 })]
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
							match Shader.from_source!({ vertex_source: "", fragment_source: glow_frag }, { res_x: win.w, res_y: win.h }) {
								Err(_) => Unavailable({ gw: win.w, gh: win.h })
								Ok(shader) => Ready({ rt, shader, gw: win.w, gh: win.h })
							}
					}
				_ => Unavailable({ gw: win.w, gh: win.h })
			}
		_ => Unavailable({ gw: win.w, gh: win.h })
	}

# An offscreen target of the given pixels, for the map's picture and
# heat's texture. A refusal is remembered at its size, and the view then
# draws every line straight to the frame.
build_map_rt! : { w : F32, h : F32 } => [NoTarget, Refused({ w : F32, h : F32 }), Target({ rt : Draw.RenderTexture, w : F32, h : F32 })]
build_map_rt! = |px|
	match (F32.round_to_u64_try(px.w), F32.round_to_u64_try(px.h)) {
		(Ok(wu), Ok(hu)) =>
			match (U64.to_i32_try(wu), U64.to_i32_try(hu)) {
				(Ok(wi), Ok(hi)) =>
					match Draw.RenderTexture.load!({ width: wi, height: hi }) {
						Ok(rt) => Target({ rt, w: px.w, h: px.h })
						Err(_) => Refused({ w: px.w, h: px.h })
					}
				_ => Refused({ w: px.w, h: px.h })
			}
		_ => Refused({ w: px.w, h: px.h })
	}

# The picture's target and the shader its names are blended in through
# (Map.text_frag), the shader a resized picture already holds kept; a GPU
# that refuses the shader gets its names blended the usual way.
picture_rt! : { w : F32, h : F32 }, [NoText, Text(Shader({ gain : F32 }))] => [NoTarget, Refused({ w : F32, h : F32 }), Target({ rt : Draw.RenderTexture, w : F32, h : F32, text : [NoText, Text(Shader({ gain : F32 }))] })]
picture_rt! = |px, kept|
	match build_map_rt!(px) {
		Target(t) => {
			text = match kept {
				Text(s) => Text(s)
				NoText =>
					match Shader.from_source!({ vertex_source: "", fragment_source: Map.text_frag }, { gain: 1.0 }) {
						Ok(s) => Text(s)
						Err(_) => NoText
					}
			}
			Target({ rt: t.rt, w: t.w, h: t.h, text })
		}
		NoTarget => NoTarget
		Refused(r) => Refused(r)
	}

# Heat's texture of summed passes, window-sized, and the shader that
# tone-maps it (Motion.heat_frag). A refusal of either is remembered at
# its size, and heat mode then draws the routes as routes mode does.
build_map_heat! : { w : F32, h : F32 } => [Unbuilt, Unavailable({ w : F32, h : F32 }), Ready({ rt : Draw.RenderTexture, shader : Shader({ top : F32 }), w : F32, h : F32 })]
build_map_heat! = |px|
	match build_map_rt!(px) {
		Target(t) =>
			match Shader.from_source!({ vertex_source: "", fragment_source: Motion.heat_frag }, { top: Motion.heat_top }) {
				Ok(shader) => Ready({ rt: t.rt, shader, w: px.w, h: px.h })
				Err(_) => Unavailable({ w: px.w, h: px.h })
			}
		_ => Unavailable({ w: px.w, h: px.h })
	}

# whether two cameras show the same picture: the same zoom, and centres
# closer than a hundredth of a pixel
same_cam : Geo.Cam, Geo.Cam -> Bool
same_cam = |a, b| (a.mpp - b.mpp).abs() <= a.mpp * 0.00001 and (a.cx - b.cx).abs() <= a.mpp * 0.01 and (a.cy - b.cy).abs() <= a.mpp * 0.01

expect same_cam({ cx: 10.0, cy: 20.0, mpp: 2.0 }, { cx: 10.001, cy: 20.0, mpp: 2.0 }) and !(same_cam({ cx: 10.0, cy: 20.0, mpp: 2.0 }, { cx: 10.5, cy: 20.0, mpp: 2.0 })) and !(same_cam({ cx: 10.0, cy: 20.0, mpp: 2.0 }, { cx: 10.0, cy: 20.0, mpp: 2.5 })) and !(same_cam(Map.unpainted, { cx: 0.0, cy: 0.0, mpp: 1.0 }))

# Whether this frame plans the tiles: when something the plan reads has
# changed (a tile's answer, the source, the map), when the map has just come
# on screen, when the window was resized, when the camera has moved since the
# last plan, and once a second besides, which is when a failed tile's or the
# source's retry can come due. A frame on a still map plans nothing.
plan_now : { due : Bool, was_map : Bool, resized : Bool, cam : Geo.Cam, planned : { cam : Geo.Cam, tick : U64 }, tick : U64 } -> Bool
plan_now = |p| p.due or !p.was_map or p.resized or !(same_cam(p.cam, p.planned.cam)) or p.tick - p.planned.tick >= ticks_per_second

# a still map plans once a second, and at once when anything it reads moves
expect {
	cam = { cx: 10.0, cy: 20.0, mpp: 2.0 }
	still = { due: Bool.False, was_map: Bool.True, resized: Bool.False, cam, planned: { cam, tick: 100 }, tick: 130 }
	!(plan_now(still)) and plan_now({ ..still, tick: 100 + ticks_per_second }) and plan_now({ ..still, due: Bool.True }) and plan_now({ ..still, was_map: Bool.False })
		and plan_now({ ..still, resized: Bool.True }) and plan_now({ ..still, cam: { ..cam, mpp: 1.6 } }) and plan_now({ ..still, cam: { ..cam, cx: 15.0 } })
}

# Runs INSIDE a spawned task (Sqlite parks there legally): loads the ghost
# session's trace and duration (no segments - the ghost is a line, not a
# block chart). The caller already cleared the drawn overlay when the
# selection moved, so a failure leaves no ghost, never a stale one.
ghost_task! : Access, List(TraceId), I64, U64 => Msg
ghost_task! = |acc, ids, gsel, gen|
	if (acc.dir == "") GhostSwitchFailed(gen)
	else match I64.to_u64_try(gsel) {
		Err(_) => GhostSwitchFailed(gen)
		Ok(gu) => match List.get(ids, gu) {
			Err(_) => GhostSwitchFailed(gen)
			Ok(entry) =>
				match open_db!(acc) {
					Err(_) => GhostSwitchFailed(gen)
					Ok(db) => {
						tr = Db.load_trace!(db, entry.id, entry.chan)
						du = Db.load_dur!(db, entry.id)
						GhostSwitched({ tr, du, gen, day: entry.day })
					}
				}
		}
	}

# whether the map has yet to land: its load waiting to start or running
map_unread : [Unloaded, Loading, Loaded] -> Bool
map_unread = |l|
	match l {
		Loaded => Bool.False
		_ => Bool.True
	}

# What R does to the map's load. One map load runs at a time: a map at rest
# is read again, and one still being read is marked stale rather than read
# a second time beside it.
map_on_reload : [Unloaded, Loading, Loaded] -> { load : [Unloaded, Loading, Loaded], stale : Bool }
map_on_reload = |l|
	match l {
		Loading => { load: Loading, stale: Bool.True }
		_ => { load: Unloaded, stale: Bool.False }
	}

# what a landing load leaves: a map marked stale while it was read is read
# once more, any other is loaded
map_on_landing : Bool -> [Unloaded, Loading, Loaded]
map_on_landing = |stale| if (stale) Unloaded else Loaded

# whether this frame works out the routes' speed bands: playback shows a
# landed map whose bands are not yet built
speed_due : U8, [Unloaded, Loading, Loaded], [Unbuilt, Built({ tick : U64, longest : F32 })] -> Bool
speed_due = |view, load, speed|
	match (load, speed) {
		(Loaded, Unbuilt) => view == 12
		_ => Bool.False
	}

# Whether playback's clock may run, given the bands' state and the tick of
# the last frame. The frame that works the bands out lasts as long as that
# work, and the frame after it measures its step from that frame's tick, so
# the clock holds through both and its first step is an ordinary one.
speed_ready : [Unbuilt, Built({ tick : U64, longest : F32 })], U64 -> Bool
speed_ready = |speed, last|
	match speed {
		Built(b) => b.tick < last
		Unbuilt => Bool.False
	}

# how a tile task's store went: no store tried, the tile kept, or why it
# could not be
CacheWrite : [Untouched, Stored, Failed(Str)]

# A tile's answer lands in its slot (Tiles.land) and has the tiles planned
# again. One that brings a tile repaints the picture, so the view sharpens
# as each arrives; one that brings none leaves the picture as it is. A
# store that failed is named on the map until a later store succeeds, so a
# cache that cannot be written shows rather than being fetched into again
# and again.
tile_landed : Ui.Model, Tiles.Answer, CacheWrite, U64 -> Ui.Model
tile_landed = |m0, ans, cache, tick| {
	m = match cache {
		Untouched => m0
		Stored => { ..m0, map_cache_err: "" }
		Failed(e) => { ..m0, map_cache_err: e }
	}
	match ans {
		Read(_) => { ..m, map_tiles: Tiles.land(m.map_tiles, ans, tick), map_painted: Map.unpainted, map_plan_due: Bool.True }
		Absent(_) => { ..m, map_tiles: Tiles.land(m.map_tiles, ans, tick), map_plan_due: Bool.True }
	}
}

# a tile that lands is drawn and repaints the picture; a miss is recorded
# and repaints nothing; either has the tiles planned again. A failed store
# is named, a later store clears it, and an answer with no store leaves it
expect {
	k = { z: 9, x: 130, y: 189 }
	painted = { cx: 1.0, cy: 2.0, mpp: 3.0 }
	m = { ..Gate.empty_model({ w: 980.0, h: 600.0 }), map_painted: painted, map_plan_due: Bool.False, map_tiles: [{ key: k, state: Fetching, refresh: Done, used: 0 }] }
	got = Read({ key: k, tile: Mvt.empty, fresh: Bool.True, tried: Bool.True })
	read = tile_landed(m, got, Untouched, 7)
	miss = tile_landed(m, Absent({ key: k, tried: Bool.True }), Untouched, 7)
	failed = tile_landed(m, got, Failed("could not keep a street-map tile: disk I/O error"), 7)
	read.map_painted == Map.unpainted and Tiles.drawn(read.map_tiles, k) == Ok(Mvt.empty) and miss.map_painted == painted and List.map(miss.map_tiles, |s| s.state) == [Failed(7)] and read.map_plan_due and miss.map_plan_due
		and failed.map_cache_err == "could not keep a street-map tile: disk I/O error" and Tiles.drawn(failed.map_tiles, k) == Ok(Mvt.empty)
		and (tile_landed(failed, got, Untouched, 8)).map_cache_err == failed.map_cache_err and (tile_landed(failed, got, Stored, 8)).map_cache_err == ""
}

# R during a read never starts a second one; the read that lands then
# starts exactly one more, and a map at rest is read again at once
expect map_on_reload(Loading) == { load: Loading, stale: Bool.True } and map_on_reload(Loaded) == { load: Unloaded, stale: Bool.False } and map_on_reload(Unloaded) == { load: Unloaded, stale: Bool.False } and map_on_landing(Bool.True) == Unloaded and map_on_landing(Bool.False) == Loaded

# playback alone works the bands out, once a map has landed and only while
# none are built
expect speed_due(12, Loaded, Unbuilt) and !(speed_due(12, Loaded, Built({ tick: 3, longest: 60.0 }))) and !(speed_due(12, Loading, Unbuilt)) and !(speed_due(12, Unloaded, Unbuilt)) and !(speed_due(10, Loaded, Unbuilt)) and !(speed_due(11, Loaded, Unbuilt))

# the clock holds until the bands are built, through the frame after the
# one that built them, and runs from the frame after that
expect !(speed_ready(Unbuilt, 9)) and !(speed_ready(Built({ tick: 9, longest: 60.0 }), 9)) and speed_ready(Built({ tick: 9, longest: 60.0 }), 10)

# the longest route's seconds are read from the routes until the bands are
# built, and kept beside them after
expect {
	m = { ..Gate.empty_model({ w: 980.0, h: 600.0 }), map: Gate.map_fixture }
	(Map.longest(m) - 600.0).abs() < 0.001 and (Map.longest({ ..m, map_speed: Built({ tick: 4, longest: 90.0 }) }) - 90.0).abs() < 0.001
}

# a marker's polygon departs from its circle by under half a pixel at the
# largest UI scale the window takes, for the halo and for both dots
expect {
	k = (DisplayScale.layout(DisplayScale.adjust(DisplayScale.default_percent + 1000, Larger), { w: 99999.0, h: 99999.0 })).scale
	(Map.strays(1.0, 2, 4.0) - 4.9348).abs() < 0.001 and k >= 2.0 and Map.strays(5.0, Map.halo_sides, k) < 0.5 and Map.strays(2.4, Map.dot_sides, k) < 0.5 and Map.strays(2.0, Map.dot_sides, k) < 0.5
}

# a capture in any map mode waits for the map to land, and one on another
# view does not wait on it
expect List.all([10, 11, 12], |v| !(view_settled({ view: v, view_anim: 0, tick: 5, trace_loading: Bool.False, ghost_loading: Bool.False, reloading: Bool.False, map_loading: map_unread(Loading) }))) and view_settled({ view: 10, view_anim: 0, tick: 5, trace_loading: Bool.False, ghost_loading: Bool.False, reloading: Bool.False, map_loading: map_unread(Loaded) }) and view_settled({ view: 0, view_anim: 0, tick: 5, trace_loading: Bool.False, ghost_loading: Bool.False, reloading: Bool.False, map_loading: map_unread(Loading) })

# The picker row of a session the map's card opens, read off the frame loop
# when the picker does not hold it: the picker holds the newest sessions,
# and a route can be older than all of them.
map_open_task! : Access, I64 => Msg
map_open_task! = |acc, id|
	match open_db!(acc) {
		Ok(db) => MapOpened({ id, row: Db.load_trace_one!(db, id) })
		Err(_) => MapOpened({ id, row: Err(NoTrace) })
	}

# Every route, read off the main loop: a full backfill is
# hundreds of megabytes of stored answers to decode, which would hold every
# view behind the splash. A database the task cannot open answers with
# the reason, so the map names it.
map_task! : Access, U64 => Msg
map_task! = |acc, gen|
	match open_db!(acc) {
		Ok(db) => MapLoaded({ map: Db.load_map!(db), gen })
		Err(NoStrideDir) => MapLoaded({ map: { ..Db.no_map, err: "no stride directory" }, gen })
		Err(Unreachable) => MapLoaded({ map: { ..Db.no_map, err: "cannot open ${acc.dir}/db.sqlite" }, gen })
	}

# One street-map tile, as a task: from the cache when the copy there is
# younger than Tiles.max_age_secs, else from OpenFreeMap by the template the
# source named, stored, and decoded; a stale copy stands in when the network
# does not answer, and is drawn as it is when no template is known yet, the
# answer saying so. Its reads and its fetch are parked off the frame loop,
# but tasks run on the frame thread, so its decode still holds the frames
# while it runs. The database is closed before the fetch, so a slow network
# never holds one of the window's connections.
tile_task! : Access, Tiles.Key, Str => Msg
tile_task! = |acc, k, template| {
	cached = match open_db!(acc) {
		Ok(db) => {
			c = Db.read_tile!(db, k)
			_ = db.close!()
			c
		}
		Err(_) => Err(Absent)
	}
	copy = match cached {
		Ok(c) =>
			match Mvt.drawable(c.data) {
				Ok(t) => Ok({ tile: t, fresh: Tiles.fresh(c.age) })
				Err(_) => Err(Unreadable)
			}
		Err(_) => Err(Absent)
	}
	untouched = |a| TileAnswer({ ans: a, cache: Untouched })
	match copy {
		Ok(cp) if cp.fresh => untouched(Read({ key: k, tile: cp.tile, fresh: Bool.True, tried: Bool.False }))
		_ =>
			if template == "" {
				match copy {
					Ok(cp) => untouched(Read({ key: k, tile: cp.tile, fresh: Bool.False, tried: Bool.False }))
					Err(_) => untouched(Absent({ key: k, tried: Bool.False }))
				}
			} else {
				match fetch_tile!(acc, template, k) {
					Ok(f) => TileAnswer({ ans: Read({ key: k, tile: f.tile, fresh: Bool.True, tried: Bool.True }), cache: f.cache })
					Err(_) =>
						match copy {
							Ok(cp) => untouched(Read({ key: k, tile: cp.tile, fresh: Bool.False, tried: Bool.True }))
							Err(_) => untouched(Absent({ key: k, tried: Bool.True }))
						}
				}
			}
	}
}

# A tile from the network, its answer read by Tiles.body_of. What decodes
# is stored before it is drawn, and how the store went comes back beside
# it: a tile the cache could not take is still drawn, and the map names
# the failure. Anything that does not decode is not stored.
fetch_tile! : Access, Str, Tiles.Key => Try({ tile : Mvt.Tile, cache : CacheWrite }, [NotFetched])
fetch_tile! = |acc, template, k|
	match acc.io.http().send!(Request.from_method(GET).with_uri(Tiles.url(template, k))) {
		Ok(resp) =>
			match Tiles.body_of(Response.status(resp), Response.body(resp)) {
				Ok(body) =>
					match Mvt.drawable(body) {
						Ok(t) => {
							cache = match open_db!(acc) {
								Ok(db) => {
									stored = Db.store_tile!(db, k, Tiles.build_of(template), body)
									_ = db.close!()
									match stored {
										Ok(_) => Stored
										Err(e) => Failed(e)
									}
								}
								Err(_) => Failed("could not keep a street-map tile: cannot open ${acc.dir}/db.sqlite")
							}
							Ok({ tile: t, cache })
						}
						Err(_) => Err(NotFetched)
					}
				Err(_) => Err(NotFetched)
			}
		Err(_) => Err(NotFetched)
	}

# the TileJSON, read once a tile needs the network, for the template of
# the current planet build (Tiles.template_of)
source_task! : Access => Msg
source_task! = |acc|
	match acc.io.http().send!(Request.from_method(GET).with_uri(Tiles.tilejson_url)) {
		Ok(resp) =>
			if Response.status(resp) == 200 {
				match Tiles.template_of(Str.from_utf8_lossy(Response.body(resp))) {
					Ok(t) => SourceRead(Ok(t))
					Err(_) => SourceRead(Err(NoTemplate))
				}
			} else {
				SourceRead(Err(NoTemplate))
			}
		Err(_) => SourceRead(Err(NoTemplate))
	}

# how long a failed tile, or a TileJSON that could not be read, waits
# before it is asked for again
tile_retry_ticks : U64
tile_retry_ticks = 30 * ticks_per_second

# Same task lane, the live session: re-reads one session's trace, segments
# and duration and reports back as a message. Any failure keeps the session
# the window already had.
trace_task! : Access, [Metric, Imperial], List(TraceId), U64, U64 => Msg
trace_task! = |acc, units, ids, sel, gen|
	if (acc.dir == "") TraceSwitchFailed(gen)
	else match List.get(ids, sel) {
		Err(_) => TraceSwitchFailed(gen)
		Ok(entry) =>
			match open_db!(acc) {
				Err(_) => TraceSwitchFailed(gen)
				Ok(db) => {
					tr = Db.load_trace!(db, entry.id, entry.chan)
					sg = Db.load_segs!(db, entry.id)
					du = Db.load_dur!(db, entry.id)
					sp = if (entry.chan == Db.pace_chan) (Db.load_splits!(db, entry.id, Db.split_len_for(units, entry.sport))) else []
					st = if (Trace.strength_session(entry.sport)) (Db.load_sets!(db, entry.id)) else { rows: [], pasted: Bool.False }
					TraceSwitched({ tr, sg, du, gen, day: entry.day, un: Db.trace_unit(entry.chan, units, entry.sport), sp, st })
				}
			}
	}

# One day's story, fetched when a table row is clicked. Units come from the
# model, not a fresh config read: the window's setting is what launch (or R)
# loaded, and one panel re-reading it mid-session would disagree with every
# other surface until the next reload.
detail_task! : Access, [Metric, Imperial], Str => Msg
detail_task! = |acc, units, day|
	if (acc.dir == "") DayDetail({ day, lines: [{ title: "no database path", stats: "", extra: "", zones: [] }] })
	else match open_db!(acc) {
		Err(_) => DayDetail({ day, lines: [{ title: "cannot open the database", stats: "", extra: "", zones: [] }] })
		Ok(db) => DayDetail({ day, lines: Db.load_day_detail!(db, units, day) })
	}

# The coach's poll: read and consume the newest directive once a second,
# from a spawned task, where Sqlite may wait. Every poll also refreshes the
# coach corner's note, so the plan view shows the directive that arrived
# last rather than the one read at launch. `last_id` is the directive the
# window last applied: a row polled again before its acknowledgement landed
# carries that id, and is not applied again, so it needs no picker read.
poll_task! : Access, I64 => Msg
poll_task! = |acc, last_id|
	if (acc.dir == "") DirectiveNone
	else match open_db!(acc) {
		Err(_) => DirectiveNone
		Ok(db) => {
			note = Db.load_bus_note!(db)
			match Db.poll_directive!(db) {
				Some(dv) => {
					# one picker read, only when a session is named - 'none'
					# dismisses the ghost and names nothing - and only on
					# first delivery
					names_session = dv.trace_day != "" or dv.trace_id >= 0 or dv.ghost_id >= 0 or (dv.ghost_day != "" and dv.ghost_day != "none")
					ids = if (names_session and dv.id != last_id) (Fresh(Db.load_trace_ids!(db))) else Kept
					Directive({ dv, note, ids })
				}
				None => Polled(note)
			}
		}
	}

# A picker row: the session's id, day, name and sport, and the channel its
# trace draws.
TraceId : { id : I64, day : Str, name : Str, sport : Str, chan : Str }

# An empty filter admits every sport, which is what makes "" the whole menu.
sport_ok : Str, Str -> Bool
sport_ok = |filt, sp| filt == "" or filt == sp

# The nearest picker index past `cur` in one direction whose sport the filter
# admits. `older` walks toward earlier sessions, which is toward HIGHER indices:
# the menu is newest-first. Returning `cur` when nothing further qualifies makes
# a key press at either end a no-op rather than a wrap-around jump.
next_admitted : List(TraceId), U64, Str, Bool -> U64
next_admitted = |ids, cur, filt, older|
	List.fold(
		List.map_with_index(ids, |e, i| { e, i }),
		cur,
		|acc, x|
			if (!(sport_ok(filt, x.e.sport))) acc
			else if (older) (if (x.i > cur and (acc == cur or x.i < acc)) x.i else acc)
			else if (x.i < cur and (acc == cur or x.i > acc)) x.i else acc,
	)

# The newest session a filter admits, for snapping the selection when the
# filter changes under it. `fallback` stands when the filter admits nothing,
# so an empty result leaves the window on the session it already had.
first_admitted : List(TraceId), Str, U64 -> U64
first_admitted = |ids, filt, fallback|
	match List.first(List.keep_oks(List.map_with_index(ids, |e, i| { e, i }), |x| if (sport_ok(filt, x.e.sport)) (Ok(x.i)) else Err({}))) {
		Ok(h) => h
		Err(_) => fallback
	}

# The filter cycle: "" first, then each sport the menu actually holds, in the
# menu's own newest-first order. Built from the menu rather than from a fixed
# list of sports, so X can never land on a filter that admits nothing.
sport_cycle : List(TraceId) -> List(Str)
sport_cycle = |ids|
	List.fold(ids, [""], |acc, e| if (e.sport != "" and !(List.contains(acc, e.sport))) (List.append(acc, e.sport)) else acc)

# A ghost candidate must be the SAME KIND of session as the live one: same
# sport AND same measured channel. The two tests guard different lies. The
# channel alone keeps the axis honest — heart rate drawn on a watts scale is
# a plausible-looking three-digit fraud — but an honest axis is not yet a
# meaningful comparison: a strength workout and a road ride both plot bpm,
# and overlaying them answers no question, because "is this better than
# last time" only means anything against the same kind of session. The
# sport alone is not enough either, since one sport spans both units — a
# metered ride is watts, the same rider's road ride without a meter is
# heart rate — and those two cannot share a scale.
ghost_matches : TraceId, TraceId -> Bool
ghost_matches = |live, cand| live.sport == cand.sport and live.chan == cand.chan

# The next compatible ghost candidate past `cur`, or -1 for none. Candidates
# of another kind are stepped over, and so is the live session's own index —
# ghost_matches is reflexive, and a session compared against itself is the
# one pairing that answers nothing. Running out of candidates dismisses the
# ghost rather than freezing on the last compatible one.
next_ghost : List(TraceId), I64, U64, Bool -> I64
next_ghost = |ids, cur, sel, older| {
	live = entry_at(ids, sel)
	sel_i = match U64.to_i64_try(sel) {
		Ok(v) => v
		Err(_) => -1
	}
	List.fold(
		List.map_with_index(ids, |e, i| { e, i }),
		-1,
		|acc, x| {
			xi = match U64.to_i64_try(x.i) {
				Ok(v) => v
				Err(_) => -1
			}
			if (xi < 0 or xi == sel_i or !(ghost_matches(live, x.e))) acc
			else if (older) (if (xi > cur and (acc < 0 or xi < acc)) xi else acc)
			else if (xi < cur and (acc < 0 or xi > acc)) xi else acc
		},
	)
}

# The picker entry at `sel`. The fallback's empty channel matches no real
# session, so an out-of-range LIVE selection admits no ghost; the ghost's own
# index is bounds-checked directly where it is judged, never through this
# fallback, because the fallback compares equal to itself.
entry_at : List(TraceId), U64 -> TraceId
entry_at = |ids, sel|
	match List.get(ids, sel) {
		Ok(te) => te
		Err(_) => { id: 0, day: "", name: "", sport: "", chan: "" }
	}

# the activity id at a picker slot, -1 when the slot is empty: the focus row
# writes -1 as NULL, so an empty picker reports no session rather than id 0
id_at : List(TraceId), U64 -> I64
id_at = |ids, sel|
	match List.get(ids, sel) {
		Ok(te) => te.id
		Err(_) => -1
	}

expect id_at([{ id: 7, day: "d", name: "n", sport: "Ride", chan: "w" }], 0) == 7
expect id_at([], 0) == -1

# The window's clock. A tick is a sixtieth of a second of the host's
# simulation time, which follows the wall clock and, under a FixedStep
# recording, advances by exactly one recorded frame's worth per cycle, so a
# recording stays regenerable. Every duration and animation below counts
# ticks, so none depends on how often the window draws, and the frame rate
# is free to drop while the window idles.
ticks_per_second : U64
ticks_per_second = 60

tick_at : Time.Cycle -> U64
tick_at = |t| t.simulation_nanos * ticks_per_second / 1_000_000_000

expect tick_at({ ..Time.first_cycle, simulation_nanos: 0 }) == 0
expect tick_at({ ..Time.first_cycle, simulation_nanos: 999_999_999 }) == 59
expect tick_at({ ..Time.first_cycle, simulation_nanos: 1_000_000_000 }) == 60
expect tick_at({ ..Time.first_cycle, simulation_nanos: 2_000_000_000 }) == 120

# A periodic action fires on the cycle whose tick crosses a multiple of its
# period. One cycle can advance the clock by several ticks or by none, so a
# test for an exact multiple would skip some periods and repeat others.
crossed : U64, U64, U64 -> Bool
crossed = |prev, now, period| now / period > prev / period

expect crossed(59, 60, 60)
expect crossed(55, 66, 60)
expect !crossed(60, 60, 60)
expect !crossed(60, 119, 60)
expect crossed(0, 1800, 1800)

# the focus heartbeat in ticks: Db.focus_beat_secs of wall clock, and the
# expect below holds the two together
focus_beat_ticks : U64
focus_beat_ticks = ticks_per_second * 30

expect focus_beat_ticks == ticks_per_second * (
	match I64.to_u64_try(Db.focus_beat_secs) {
		Ok(b) => b
		Err(_) => 0
	}
)

# The frame rate. Drawing every frame keeps the CPU and GPU busy even while
# nothing on screen changes, so the window draws at full rate only while
# something moves or the athlete is using it, and at the idle rate
# otherwise. The idle rate still runs update! several times a second, which
# is what lands a bus directive within about a second of its write. Input
# keeps the full rate for linger_ticks after it stops, so the next move of a
# hand that paused is answered at once. raylib ends each frame's wait with a
# short spin that costs CPU at any frame rate, so an idle rate lower than
# this one saves little more.
full_fps : I32
full_fps = 60

idle_fps : I32
idle_fps = 5

linger_ticks : U64
linger_ticks = 2 * ticks_per_second

# how long a view switch animates: the longest arrival a view draws (the
# career sweep), which also covers the crossfade and view_settled's wait
view_anim_ticks : U64
view_anim_ticks = 120

expect U64.to_f32(view_anim_ticks) >= Career.dur

frame_rate : { busy : Bool, tick : U64, last_active : U64 } -> I32
frame_rate = |p| if (p.busy or p.tick - p.last_active < linger_ticks) full_fps else idle_fps

expect frame_rate({ busy: Bool.True, tick: 1000, last_active: 0 }) == full_fps
expect frame_rate({ busy: Bool.False, tick: 1000, last_active: 900 }) == full_fps
expect frame_rate({ busy: Bool.False, tick: 1000, last_active: 880 }) == idle_fps
expect idle_fps >= 2

# A ghost is chosen against one selection and outlives it: stepping the
# solid session, a directive, or a filter snap all move the live trace
# while the ghost index stays where it was. Compatibility is therefore a
# property of the PAIR, re-judged against each frame's own selection - a
# pairing of two kinds cannot survive a switch, a ghost sitting ON the
# selection is dismissed rather than drawn under itself, and the ghost
# index is bounds-checked here directly because entry_at's fallback would
# compare equal to itself. -1 dismisses.
ghost_for_sel : List(TraceId), U64, I64 -> I64
ghost_for_sel = |ids, sel, ghost|
	match I64.to_u64_try(ghost) {
		Err(_) => -1
		Ok(gu) =>
			if (gu == sel) (-1)
			else match List.get(ids, gu) {
				Err(_) => -1
				Ok(ge) => if (ghost_matches(entry_at(ids, sel), ge)) ghost else -1
			}
	}

expect {
	m = [
		{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan },
		{ id: 2, day: "d2", name: "n2", sport: "WeightTraining", chan: Db.hr_chan },
		{ id: 3, day: "d3", name: "n3", sport: "Ride", chan: Db.watts_chan },
	]
	# a compatible pair survives the re-judgment
	ghost_for_sel(m, 0, 2) == 2
		# the solid session moved to the workout: the ride ghost is dismissed
		and ghost_for_sel(m, 1, 2) == -1
		# and the reverse pairing dies the same way
		and ghost_for_sel(m, 0, 1) == -1
		# no ghost stays no ghost
		and ghost_for_sel(m, 0, -1) == -1
		# a ghost ON the selection is a session compared against itself
		and ghost_for_sel(m, 2, 2) == -1
		# an out-of-range ghost cannot ride entry_at's self-equal fallback
		and ghost_for_sel(m, 0, 99) == -1
		and ghost_for_sel([], 5, 3) == -1
}

# The filter and the selection are stored as a pair, and a directive can move
# the selection without consulting the filter. Reconciled the same way the
# ghost pair is: a filter the shown session violates resets to the whole
# menu, so the header can never claim "Rowing only" over a Ride.
sport_for_sel : List(TraceId), U64, Str -> Str
sport_for_sel = |ids, sel, filt|
	if (sport_ok(filt, entry_at(ids, sel).sport)) filt else ""

expect {
	m = [
		{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan },
		{ id: 2, day: "d2", name: "n2", sport: "Rowing", chan: Db.watts_chan },
	]
	# a filter the shown session satisfies survives
	sport_for_sel(m, 1, "Rowing") == "Rowing"
		# a directive landed a Ride under a Rowing filter: the filter resets
		and sport_for_sel(m, 0, "Rowing") == ""
		# the whole-menu filter admits anything, itself included
		and sport_for_sel(m, 0, "") == ""
}

expect {
	# a metered ride, an unmetered ride, another metered ride, a metered row
	m = [
		{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan },
		{ id: 2, day: "d2", name: "n2", sport: "Ride", chan: Db.hr_chan },
		{ id: 3, day: "d3", name: "n3", sport: "Ride", chan: Db.watts_chan },
		{ id: 4, day: "d4", name: "n4", sport: "Rowing", chan: Db.watts_chan },
	]
	# stepping older from the watts ride at 0 SKIPS the bpm ride at 1
	next_ghost(m, 0, 0, Bool.True) == 2
		# ...and stops short of the row at 3: same watts, different sport
		and next_ghost(m, 2, 0, Bool.True) == -1
		# the bpm ride's only company is itself
		and next_ghost(m, 1, 1, Bool.True) == -1
		# the row matches nothing else in the menu, in either direction
		and next_ghost(m, 3, 3, Bool.False) == -1
		# stepping newer from cur=2 with the live session AT 0: its own index is
		# skipped, so the walk ends instead of landing the ghost on the live trace
		and next_ghost(m, 2, 0, Bool.False) == -1
		# and the honest newer step, live at 2, finds the ride at 0
		and next_ghost(m, 2, 2, Bool.False) == 0
		and entry_at(m, 1).chan == Db.hr_chan
		# an out-of-range selection matches no real session
		and next_ghost(m, 0, 99, Bool.True) == -1
}

next_sport : List(TraceId), Str -> Str
next_sport = |ids, cur| {
	cyc = sport_cycle(ids)
	idx = List.fold(List.map_with_index(cyc, |s, i| { s, i }), 0.U64, |acc, x| if (x.s == cur) x.i else acc)
	match List.get(cyc, (idx + 1) % List.len(cyc)) {
		Ok(s9) => s9
		Err(_) => ""
	}
}

expect {
	sport_ok("", "Ride")
		and sport_ok("Ride", "Ride")
		and !(sport_ok("Ride", "Rowing"))
}

expect {
	# a mixed menu, newest first, as the picker orders it
	m = [{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan }, { id: 2, day: "d2", name: "n2", sport: "Rowing", chan: Db.watts_chan }, { id: 3, day: "d3", name: "n3", sport: "Ride", chan: Db.watts_chan }]
	# unfiltered, "older" is simply the next index
	next_admitted(m, 0, "", Bool.True) == 1
		# filtered to Ride, the Rowing entry between them is skipped entirely
		and next_admitted(m, 0, "Ride", Bool.True) == 2
		# and the same skip walking back toward newer sessions
		and next_admitted(m, 2, "Ride", Bool.False) == 0
		# nothing older than the last admitted entry: the selection holds rather
		# than wrapping
		and next_admitted(m, 2, "Ride", Bool.True) == 2
		and next_admitted(m, 0, "", Bool.False) == 0
}

expect {
	m = [{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan }, { id: 2, day: "d2", name: "n2", sport: "Rowing", chan: Db.watts_chan }, { id: 3, day: "d3", name: "n3", sport: "Ride", chan: Db.watts_chan }]
	first_admitted(m, "Rowing", 0) == 1
		and first_admitted(m, "", 2) == 0
		# a filter the menu cannot satisfy leaves the selection where it was
		and first_admitted(m, "Run", 2) == 2
}

expect {
	m = [{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan }, { id: 2, day: "d2", name: "n2", sport: "Rowing", chan: Db.watts_chan }, { id: 3, day: "d3", name: "n3", sport: "Ride", chan: Db.watts_chan }]
	sport_cycle(m) == ["", "Ride", "Rowing"]
		and next_sport(m, "") == "Ride"
		and next_sport(m, "Ride") == "Rowing"
		# the cycle closes back to the unfiltered menu
		and next_sport(m, "Rowing") == ""
}

expect {
	# an empty menu still cycles, so X on a database with no streams is a
	# no-op rather than a filter nothing can satisfy
	sport_cycle([]) == [""]
		and next_sport([], "") == ""
}

# The selection after the picker is re-read: the same SESSION, found by id
# in the fresh list, wherever it now sits. A session synced since the old
# read shifts every position after it, so carrying the old index forward
# would silently select a neighbour. `found` says whether the shown session
# is still there; when it is not, the selection falls to the newest entry -
# the only index every non-empty picker has - and the caller must fetch
# that entry, because the samples on screen belong to a session no index
# names any more. An empty picker keeps zero.
sel_following_id : List(TraceId), U64, List(TraceId) -> { sel : U64, found : Bool }
sel_following_id = |old, old_sel, fresh| {
	cur_id = match List.get(old, old_sel) {
		Ok(e) => e.id
		Err(_) => -1
	}
	List.fold(List.map_with_index(fresh, |e, i| { e, i }), { sel: 0, found: Bool.False }, |s, x| if (x.e.id == cur_id) ({ sel: x.i, found: Bool.True }) else s)
}

# A directive's session, resolved against the picker. A day names its
# NEWEST session - the picker is newest-first, and the first match is the
# one the athlete most likely means on a day that carries two; an id names
# one session exactly. Absent, the selection stays where it was.
# A session the map opened that the picker lacks, placed where the
# picker's newest-first order puts it: before the first row from an
# earlier day, or from the same day with a lower id, since Strava numbers
# a day's sessions in the order they were uploaded. The picker re-reads
# only on R or a session-naming directive, so every session the map opens
# meanwhile is placed this way. Every index from that place on moves up
# one: the selection and the ghost move with their sessions, and the
# trace cache, aligned to the picker by index, keeps only the entries
# before it.
with_opened : Ui.Model, TraceId -> Ui.Model
with_opened = |m, row|
	if List.any(m.trace_ids, |e| e.id == row.id) {
		m
	} else {
		k = day_key(row.day)
		at = (List.find_first_index(m.trace_ids, |e| day_key(e.day) < k or (day_key(e.day) == k and e.id < row.id))) ?? List.len(m.trace_ids)
		ids = List.concat(List.append(List.take_first(m.trace_ids, at), row), List.drop_first(m.trace_ids, at))
		{ ..m, trace_ids: ids, trace_cache: List.take_first(m.trace_cache, at), trace_sel: if (m.trace_sel >= at) m.trace_sel + 1 else m.trace_sel, ghost_sel: if (m.ghost_sel >= U64.to_i64_wrap(at)) m.ghost_sel + 1 else m.ghost_sel }
	}

# a YYYY-MM-DD day as the number its digits spell, which orders as the days do
day_key : Str -> I64
day_key = |day| List.fold(Str.to_utf8(day), 0, |acc, b| if (b >= 48 and b <= 57) acc * 10 + U8.to_i64(b - 48) else acc)

# two sessions the map opens land in newest-first order whichever opens
# first, the shown session and the ghost keep their sessions, and the cache
# keeps only the entries before the first place a session landed
expect {
	row = |id, day| { id, day, name: "", sport: "Ride", chan: "w" }
	picker = [row(50, "2026-11-15"), row(40, "2026-11-10"), row(30, "2026-11-10"), row(20, "2026-06-01")]
	entry = { tr: [], sg: [], du: 0.0, un: "", sp: [], st: { rows: [], pasted: Bool.False } }
	base = { ..Gate.empty_model(Gate.default_size), trace_ids: picker, trace_sel: 3, ghost_sel: 2, trace_cache: List.repeat(entry, 4) }
	mid = row(35, "2026-11-10")
	old = row(10, "2025-10-10")
	may = row(15, "2026-05-31")
	a = with_opened(with_opened(with_opened(base, old), may), mid)
	b = with_opened(with_opened(with_opened(base, mid), may), old)
	List.map(a.trace_ids, |e| e.id) == [50, 40, 35, 30, 20, 15, 10]
		and List.map(b.trace_ids, |e| e.id) == [50, 40, 35, 30, 20, 15, 10]
		and (List.get(a.trace_ids, a.trace_sel)).map_ok(|e| e.id) == Ok(20) and (List.get(b.trace_ids, b.trace_sel)).map_ok(|e| e.id) == Ok(20)
		and (List.get(a.trace_ids, (I64.to_u64_try(a.ghost_sel)) ?? 0)).map_ok(|e| e.id) == Ok(30) and List.len(with_opened(base, old).trace_cache) == 4 and List.len(a.trace_cache) == 2 and List.len(with_opened(base, may).trace_ids) == 5 and List.len(with_opened(with_opened(base, may), may).trace_ids) == 5
		and day_key("2026-05-31") < day_key("2026-11-10")
}

sel_for_day : List(TraceId), Str, U64 -> U64
sel_for_day = |ids, day, fallback|
	match List.find_first_index(ids, |e| e.day == day) {
		Ok(i) => i
		Err(_) => fallback
	}

sel_for_id : List(TraceId), I64, U64 -> U64
sel_for_id = |ids, id, fallback|
	match List.find_first_index(ids, |e| e.id == id) {
		Ok(i) => i
		Err(_) => fallback
	}

# a day with two sessions resolves to the newest - index 0 of a
# newest-first picker - not to whichever the fold visited last
expect {
	a = { id: 10, day: "2026-09-26", name: "morning", sport: "Ride", chan: "w" }
	b = { id: 11, day: "2026-09-26", name: "evening", sport: "Ride", chan: "w" }
	c = { id: 12, day: "2026-09-27", name: "c", sport: "Ride", chan: "w" }
	sel_for_day([c, b, a], "2026-09-26", 7) == 1
		and sel_for_day([c, b, a], "2026-09-27", 7) == 0
		and sel_for_day([c, b, a], "2026-01-01", 7) == 7
		and sel_for_id([c, b, a], 10, 7) == 2
		and sel_for_id([c, b, a], 99, 7) == 7
}

# The ghost the same way, with the kind test the keyboard path applies: the
# newest session of that day that is the shown session's kind, or the
# fallback. Given as an I64 index because -1 is "no ghost".
ghost_for_day : List(TraceId), TraceId, Str, I64 -> I64
ghost_for_day = |ids, live, day, fallback|
	match List.find_first_index(ids, |e| e.day == day and ghost_matches(live, e)) {
		Ok(i) => match U64.to_i64_try(i) {
			Ok(gi) => gi
			Err(_) => fallback
		}
		Err(_) => fallback
	}

ghost_for_id : List(TraceId), TraceId, I64, I64 -> I64
ghost_for_id = |ids, live, id, fallback|
	match List.find_first_index(ids, |e| e.id == id and ghost_matches(live, e)) {
		Ok(i) => match U64.to_i64_try(i) {
			Ok(gi) => gi
			Err(_) => fallback
		}
		Err(_) => fallback
	}

# on a day carrying a rowing session (newer) and a ride (older), a ride on
# screen ghosts the ride, not the newer session of the wrong kind
expect {
	live = { id: 1, day: "d0", name: "live", sport: "Ride", chan: "w" }
	row = { id: 20, day: "2026-09-26", name: "row", sport: "Rowing", chan: "w" }
	ride = { id: 21, day: "2026-09-26", name: "ride", sport: "Ride", chan: "w" }
	ghost_for_day([live, row, ride], live, "2026-09-26", -1) == 2
		and ghost_for_day([live, row, ride], live, "2026-01-01", -1) == -1
		and ghost_for_id([live, row, ride], live, 21, -1) == 2
		# the right id but the wrong kind is no ghost
		and ghost_for_id([live, row, ride], live, 20, -1) == -1
}

# Where the ghost stands after a picker re-read: no ghost stays no ghost
# (keep, nothing to clear); a ghost whose session is still listed follows
# it to its new index; a ghost whose session is gone is dismissed, and
# `keep` false tells the fold to clear its samples, day and duration and
# to open a new ghost generation. Follows sel_following_id for the same
# reason the trace does - an index is a position, a session is an id.
ghost_after_reread : I64, List(TraceId), List(TraceId) -> { sel : I64, keep : Bool }
ghost_after_reread = |ghost_sel, old, fresh|
	match I64.to_u64_try(ghost_sel) {
		Err(_) => { sel: -1, keep: Bool.True }
		Ok(gu) => {
			gr = sel_following_id(old, gu, fresh)
			if (gr.found) (
				match U64.to_i64_try(gr.sel) {
					Ok(gs) => { sel: gs, keep: Bool.True }
					Err(_) => { sel: -1, keep: Bool.False }
				}
			) else { sel: -1, keep: Bool.False }
		}
	}

# no ghost: nothing moves and nothing is cleared
expect ghost_after_reread(-1, [], [{ id: 1, day: "d", name: "n", sport: "Ride", chan: "w" }]) == { sel: -1, keep: Bool.True }

# the ghost's session shifted one slot down behind a newer session: it
# follows, and stays drawn
expect {
	a = { id: 10, day: "2026-09-01", name: "a", sport: "Ride", chan: "w" }
	b = { id: 11, day: "2026-09-02", name: "b", sport: "Ride", chan: "w" }
	c = { id: 12, day: "2026-09-03", name: "c", sport: "Ride", chan: "w" }
	ghost_after_reread(1, [b, a], [c, b, a]) == { sel: 2, keep: Bool.True }
}

# the ghost's session is gone from the re-read: dismissed, and cleared
expect {
	a = { id: 10, day: "2026-09-01", name: "a", sport: "Ride", chan: "w" }
	b = { id: 11, day: "2026-09-02", name: "b", sport: "Ride", chan: "w" }
	ghost_after_reread(1, [b, a], [b]) == { sel: -1, keep: Bool.False }
}

# the shown session keeps its identity across a re-read that inserted a
# newer session ahead of it, and is reported found
expect {
	a = { id: 10, day: "2026-09-01", name: "a", sport: "Ride", chan: "watts" }
	b = { id: 11, day: "2026-09-02", name: "b", sport: "Ride", chan: "watts" }
	c = { id: 12, day: "2026-09-03", name: "c", sport: "Ride", chan: "watts" }
	# shown: b at index 0 of [b, a]; fresh read gained c at the top
	sel_following_id([b, a], 0, [c, b, a]) == { sel: 1, found: Bool.True }
}

# a shown session deleted since the read falls to the newest entry and is
# reported NOT found, so the caller fetches rather than relabels
expect {
	a = { id: 10, day: "2026-09-01", name: "a", sport: "Ride", chan: "watts" }
	b = { id: 11, day: "2026-09-02", name: "b", sport: "Ride", chan: "watts" }
	sel_following_id([b, a], 0, [a]) == { sel: 0, found: Bool.False }
		and sel_following_id([b, a], 1, [b]) == { sel: 0, found: Bool.False }
}

# an old index past the old list (nothing was shown) and an empty fresh
# picker both resolve to zero, not found, rather than out of range
expect {
	a = { id: 10, day: "2026-09-01", name: "a", sport: "Ride", chan: "watts" }
	sel_following_id([], 0, [a]) == { sel: 0, found: Bool.False }
		and sel_following_id([a], 0, []) == { sel: 0, found: Bool.False }
}

# a capture's refusal, the judgements joined: the vocabulary first, then the
# recorder's state - a start while one runs and a stop while none does are
# refused by name, since the host would ignore them and the status would
# claim a file - then a capture still waiting on the host, whose row a
# newer capture would otherwise close without its file
capture_refusal_for : Str, Bool, Bool -> Str
capture_refusal_for = |kind, rec_active, cap_pending|
	Str.join_with(
		List.keep_if(
			[
				Bus.capture_refusal(kind),
				(if (kind == "webm_start" and rec_active) ("capture webm_start: a recording is already running") else ""),
				(if (kind == "webm_stop" and !rec_active) ("capture webm_stop: no recording is running") else ""),
				(if (kind != "" and cap_pending and Bus.capture_refusal(kind) == "") ("capture ${kind}: an earlier capture is still pending") else ""),
			],
			|s8| s8 != "",
		),
		"; ",
	)

# Every refusable field of a directive, named. A pure function rather than an
# inline block: on the pinned compiler, a large conditional binding captured
# by a task closure compiles to its empty default, and a call compiles
# correctly.
refusals_for : { has_d : Bool, id : I64, view : I64, range : I64, cursor_day : Str, trace_day : Str, ghost_day : Str, trace_id : I64, ghost_id : I64, capture : Str, family : Str, short : I64 }, Str, U64, U64, List(TraceId), Bool, Bool -> Str
refusals_for = |dv, cwhy, wsel, cur_sel, ids, rec_active, cap_pending| {
	segs = List.keep_if(
		[
			(if (dv.view > 12 or dv.view < -1) ("view ${I64.to_str(dv.view)} unknown") else ""),
			(if (dv.range != -1 and dv.range != 30 and dv.range != 60 and dv.range != 90) ("range ${I64.to_str(dv.range)} not 30/60/90") else ""),
			(if (dv.cursor_day != "" and cwhy != "") ("cursor_day ${dv.cursor_day} not in the series: ${cwhy}") else ""),
			# a day beside an id is not judged: the resolver reads the id and never
			# the day, so the refusal names only what was consulted
			(
				if (
					dv.trace_day != "" and dv.trace_id < 0 and wsel == cur_sel and (
						match List.get(ids, wsel) {
							Ok(te9) => te9.day != dv.trace_day
							Err(_) => Bool.True
						}
					)
				) ("trace_day ${dv.trace_day} not in the picker") else ""
			),
			# an id resolves by identity, so "not in the picker" is exact: no
			# session with that id, rather than no session on that day
			(
				if (
					dv.trace_id >= 0 and wsel == cur_sel and (
						match List.get(ids, wsel) {
							Ok(te8) => te8.id != dv.trace_id
							Err(_) => Bool.True
						}
					)
				) ("trace_id ${I64.to_str(dv.trace_id)} not in the picker") else ""
			),
			(if (dv.ghost_day != "" and dv.ghost_day != "none" and dv.ghost_id < 0 and !(List.any(ids, |ge9| ge9.day == dv.ghost_day))) ("ghost_day ${dv.ghost_day} not in the picker") else ""),
			# the session on screen cannot be its own ghost: the kind test below
			# stays quiet on it (a session trivially matches itself), and the
			# dismissal in ghost_for_sel is silent, so without this segment the
			# directive would report applied while drawing nothing
			(if (dv.ghost_day != "" and dv.ghost_day != "none" and dv.ghost_id < 0 and dv.ghost_day == entry_at(ids, wsel).day) ("ghost_day ${dv.ghost_day} is the session on screen") else ""),
			# in the picker but the wrong KIND of session: naming what differs -
			# the sport, or failing that the unit - is what makes this actionable,
			# since "refused" alone reads as a missing day
			(
				if dv.ghost_day != "" and dv.ghost_day != "none" and dv.ghost_id < 0 and List.any(ids, |ge8| ge8.day == dv.ghost_day) and !(List.any(ids, |ge7| ge7.day == dv.ghost_day and ghost_matches(entry_at(ids, wsel), ge7))) {
					live6 = entry_at(ids, wsel)
					gh6 = List.fold(ids, live6, |acc, g6| if (g6.day == dv.ghost_day) g6 else acc)
					if (gh6.sport != live6.sport) ("ghost_day ${dv.ghost_day} is ${gh6.sport}, the session is ${live6.sport}")
					else "ghost_day ${dv.ghost_day} is ${Db.chan_name(gh6.chan)}, the session is ${Db.chan_name(live6.chan)}"
				} else ""
			),
			# the same three judgements for a ghost named by id. A ghost_day of
			# 'none' dismisses regardless of ghost_id, so an id beside it is not
			# judged at all - the resolver never reads it either
			(if (dv.ghost_id >= 0 and dv.ghost_day != "none" and !(List.any(ids, |gi9| gi9.id == dv.ghost_id))) ("ghost_id ${I64.to_str(dv.ghost_id)} not in the picker") else ""),
			(if (dv.ghost_id >= 0 and dv.ghost_day != "none" and dv.ghost_id == entry_at(ids, wsel).id) ("ghost_id ${I64.to_str(dv.ghost_id)} is the session on screen") else ""),
			(
				if dv.ghost_id >= 0 and dv.ghost_day != "none" and dv.ghost_id != entry_at(ids, wsel).id and List.any(ids, |gi8| gi8.id == dv.ghost_id) and !(List.any(ids, |gi7| gi7.id == dv.ghost_id and ghost_matches(entry_at(ids, wsel), gi7))) {
					live5 = entry_at(ids, wsel)
					gh5 = List.fold(ids, live5, |acc, g5| if (g5.id == dv.ghost_id) g5 else acc)
					if (gh5.sport != live5.sport) ("ghost_id ${I64.to_str(dv.ghost_id)} is ${gh5.sport}, the session is ${live5.sport}")
					else "ghost_id ${I64.to_str(dv.ghost_id)} is ${Db.chan_name(gh5.chan)}, the session is ${Db.chan_name(live5.chan)}"
				} else ""
			),
			(capture_refusal_for(dv.capture, rec_active, cap_pending)),
			(Bus.family_refusal(dv.family)),
			(Bus.short_refusal(dv.short)),
		],
		|s9| s9 != "",
	)
	Str.join_with(segs, "; ")
}

# a curve key the athlete has data for: one of the loaded power families or
# pace keys
curve_on_record : Db.CurveKeys, Str -> Bool
curve_on_record = |keys, f| List.contains(keys.power, f) or List.contains(keys.pace, f)

# the window's half of a family's judgement: Bus.family_refusal has already
# named a key outside the vocabulary, and a valid key with nothing on record
# is refused here by name, with the curves that are
curve_refusal : Db.CurveKeys, Str -> Str
curve_refusal = |keys, f|
	if (f == "" or Bus.family_refusal(f) != "" or curve_on_record(keys, f)) ""
	else {
		have = List.concat(keys.power, keys.pace)
		what = if (Str.starts_with(f, Bus.pace_prefix)) "pace" else "power"
		if (List.is_empty(have)) "family ${f}: no ${what} on record" else "family ${f}: no ${what} on record (have ${Str.join_with(have, ", ")})"
	}

expect curve_refusal({ power: ["Ride", "Rowing"], pace: ["pace:Rowing"] }, "Run") == "family Run: no power on record (have Ride, Rowing, pace:Rowing)"
expect curve_refusal({ power: ["Ride"], pace: [] }, "pace:Swim") == "family pace:Swim: no pace on record (have Ride)"
expect curve_refusal({ power: ["Ride"], pace: ["pace:Run"] }, "pace:Run") == "" and curve_refusal({ power: [], pace: [] }, "") == ""
# a key outside the vocabulary is the static refusal's, never named twice
expect curve_refusal({ power: [], pace: [] }, "Bike") == ""

# two refusals joined the way the segments are
join_refusal : Str, Str -> Str
join_refusal = |a, b| if (a == "") b else if (b == "") a else "${a}; ${b}"

# why a directive's screenshot names no file: the host declined it, or the
# host answered and no file of the shot's is there (dir_shot_task!)
ShotError : [Host(Capture.ScreenshotError), NoFile]

# why a screenshot named no file, in the status row's words
shot_error_text : ShotError -> Str
shot_error_text = |e|
	match e {
		Host(PathInvalid) => "capture png failed: the path is invalid"
		Host(PathEscapesOutputDir) => "capture png failed: the path leaves ./captures"
		Host(AlreadyPending) => "capture png failed: a screenshot is already pending"
		Host(WriteFailed) => "capture png failed: the file could not be written"
		Host(Busy) => "capture png failed: the host is busy"
		Host(Unavailable) => "capture png failed: capture is unavailable here"
		Host(PermissionDenied) => "capture png failed: the host refused the capture"
		NoFile => "capture png failed: the host answered but wrote no file"
	}

# what a stat finds at a capture's path: nothing (or something that is not
# a file), or a file's size and when it last changed, in nanoseconds
FileSeen : [Absent, Seen({ size : U64, at : I128 })]

# a shot wrote its file when one is there after it, not empty, and not the
# file that stood there before it: a write moves the modification time
shot_wrote : FileSeen, FileSeen -> Bool
shot_wrote = |before, after|
	match after {
		Absent => Bool.False
		Seen(a) =>
			a.size > 0
				and match before {
					Absent => Bool.True
					Seen(b) => b.at != a.at
				}
	}

expect {
	file = |size, at| Seen({ size, at })
	shot_wrote(Absent, file(120, 5))
		and shot_wrote(file(120, 5), file(130, 9))
		and !shot_wrote(Absent, Absent)
		and !shot_wrote(file(120, 5), Absent)
		and !shot_wrote(file(120, 5), file(120, 5))
		and !shot_wrote(Absent, file(0, 5))
		and shot_error_text(NoFile) == "capture png failed: the host answered but wrote no file"
		and shot_error_text(Host(Busy)) == "capture png failed: the host is busy"
}

# the file at `rel` under the window's working directory, the directory
# the platform resolves its capture directory against
file_seen! : App.Io, Str => FileSeen
file_seen! = |io, rel|
	match io.files().working_directory_read!() {
		Err(_) => Absent
		Ok(d) =>
			match d.metadata!(rel) {
				Ok(md) => if (md.kind == File) Seen({ size: md.size_bytes, at: md.modified.nanos_since_epoch() }) else Absent
				Err(_) => Absent
			}
	}

# A directive's screenshot, and whether it is the file the row will name:
# the host parks the task until its write is done, then a stat must find a
# file there that the stat before the shot did not, since a host with no
# framebuffer answers Ok without writing and a file an earlier capture left
# would otherwise pass for this one's
dir_shot_task! : App.Io, I64, Str => Msg
dir_shot_task! = |io, id, name| {
	rel = capture_path("", name)
	before = file_seen!(io, rel)
	res = match io.capture().screenshot!(name) {
		Ok(_) => if (shot_wrote(before, file_seen!(io, rel))) Ok({}) else Err(NoFile)
		Err(e) => Err(Host(e))
	}
	DirShot({ id, res })
}

# whether a capture's mark is still waiting on the host
capture_is_pending : Ui.PendingCapture -> Bool
capture_is_pending = |p|
	match p {
		NoCapture => Bool.False
		_ => Bool.True
	}

# whether this frame polls the bus: once a second, against a database the
# window has, while no capture waits on the host (a newer row would
# supersede the one whose file is still being written), and never while
# the boot load is in flight: a directive is judged against the model it
# steers, and the boot skeleton holds no series, no picker and no view
# drawn yet, so a row written at launch waits for the loaded window
polls_bus : { second : Bool, has_dir : Bool, capture_pending : Bool, booting : Bool } -> Bool
polls_bus = |p| p.second and p.has_dir and !p.capture_pending and !p.booting

expect {
	at = { second: Bool.True, has_dir: Bool.True, capture_pending: Bool.False, booting: Bool.False }
	polls_bus(at) and !polls_bus({ ..at, booting: Bool.True }) and !polls_bus({ ..at, second: Bool.False }) and !polls_bus({ ..at, has_dir: Bool.False }) and !polls_bus({ ..at, capture_pending: Bool.True })
}

# where the platform writes captures, relative to the window's working
# directory: the platform refuses an absolute output dir, so the absolute path
# a capture row reports is that working directory (resolved at load, see
# load_model!) joined to this. The config and the report name the same
# directory because both read it from here.
capture_dir : Str
capture_dir = "captures"

# the file a capture of this name will be, under the working directory
# `here`; relative when the working directory is unknown
capture_path : Str, Str -> Str
capture_path = |here, name| {
	rel = Str.concat(capture_dir, Str.concat("/", name))
	if (here == "") rel else Str.concat(here, Str.concat("/", rel))
}

# a host that has not answered a capture within ten seconds never will, and
# the row closes rather than stays pending
capture_timeout_ticks : U64
capture_timeout_ticks = 10 * ticks_per_second

# A PNG waits for its view to settle before the host is asked, and a view
# waiting on a load (the map's runs tens of seconds on a full backfill)
# settles late, so the armed wait has its own, longer limit and its own
# reason; the host's ten seconds start when the shot is asked for.
settle_timeout_ticks : U64
settle_timeout_ticks = 180 * ticks_per_second

# what one frame does about a pending capture: the host's screenshot answer
# for the directive (not the S key's), the recorder's status, whether the
# view has settled, and the frame's tick decide the next state and the one
# effect the frame runs. A PNG is armed until the view has settled (a view
# switch's crossfade and draw-in have finished, no trace fetch is in flight,
# and on the map view the map has landed) so the file shows the view and not
# the transition. A mark's result names a file only once it exists: a PNG's
# when its shot wrote one (dir_shot_task!), a recording's when the stop
# finished with bytes written. A start closes once the recorder reads
# Active, with no result since its file is not written until the stop, and
# a refusal the host latched for the next input closes it with the reason;
# a stop closes on Finished or Failed. The armed wait ends at
# settle_timeout_ticks and every wait on the host at capture_timeout_ticks,
# each with no result
CaptureEvent : { shot : [NoShot, ShotDone(I64, Try({}, ShotError))], rec : Capture.Status, settled : Bool, tick : U64 }

CaptureAction : [Nothing, TakeShot({ id : I64, name : Str }), Mark({ id : I64, refused : Str, result : Str })]

capture_step : Ui.PendingCapture, CaptureEvent -> { next : Ui.PendingCapture, act : CaptureAction }
capture_step = |p, ev| {
	timed_out = |c| ev.tick - c.since >= capture_timeout_ticks
	give_up = |c, kind| { next: NoCapture, act: Mark({ id: c.id, refused: join_refusal(c.refused, "capture ${kind} failed: no answer from the host within 10 seconds"), result: "" }) }
	match p {
		NoCapture => { next: NoCapture, act: Nothing }
		ArmedShot(c) =>
			if (ev.tick - c.since >= settle_timeout_ticks) ({ next: NoCapture, act: Mark({ id: c.id, refused: join_refusal(c.refused, "capture png failed: the view was still loading after 180 seconds"), result: "" }) })
			else if (ev.settled) ({ next: AwaitingShot({ ..c, since: ev.tick }), act: TakeShot({ id: c.id, name: c.name }) })
			else { next: p, act: Nothing }
		AwaitingShot(c) =>
			match ev.shot {
				ShotDone(sid, res) if sid == c.id =>
					match res {
						Ok(_) => { next: NoCapture, act: Mark({ id: c.id, refused: c.refused, result: c.path }) }
						Err(e) => { next: NoCapture, act: Mark({ id: c.id, refused: join_refusal(c.refused, shot_error_text(e)), result: "" }) }
					}
				_ => if (timed_out(c)) (give_up(c, "png")) else { next: p, act: Nothing }
			}
		AwaitingStart(c) =>
			match ev.rec {
				Active(_) => { next: NoCapture, act: Mark({ id: c.id, refused: c.refused, result: "" }) }
				# the frame after the start reads the host's answer to it: an accepted
				# start reads Active, a rejected one the Failed the host latched, and
				# either overwrites what an earlier recording left
				Failed(f) => { next: NoCapture, act: Mark({ id: c.id, refused: join_refusal(c.refused, Str.concat("capture webm_start failed: ", rec_failure_text(f.reason))), result: "" }) }
				_ => if (timed_out(c)) (give_up(c, "webm_start")) else { next: p, act: Nothing }
			}
		AwaitingStop(c) =>
			match ev.rec {
				Finished(f) => if (f.bytes > 0) { next: NoCapture, act: Mark({ id: c.id, refused: c.refused, result: c.path }) } else { next: NoCapture, act: Mark({ id: c.id, refused: join_refusal(c.refused, "capture webm_stop failed: the recording wrote no file"), result: "" }) }
				Failed(f) => { next: NoCapture, act: Mark({ id: c.id, refused: join_refusal(c.refused, Str.concat("capture webm_stop failed: ", rec_failure_text(f.reason))), result: "" }) }
				_ => if (timed_out(c)) (give_up(c, "webm_stop")) else { next: p, act: Nothing }
			}
	}
}

# ESC closes a pending capture rather than leave its row pending: a window
# that quits cannot answer, and an unmarked row would be applied again by
# the next launch and refused as headless by every tick in between
capture_abandon : Ui.PendingCapture -> CaptureAction
capture_abandon = |p| {
	closed = |c, kind| Mark({ id: c.id, refused: join_refusal(c.refused, "capture ${kind} failed: the window closed before the host answered"), result: "" })
	match p {
		NoCapture => Nothing
		ArmedShot(c) => closed(c, "png")
		AwaitingShot(c) => closed(c, "png")
		AwaitingStart(c) => closed(c, "webm_start")
		AwaitingStop(c) => closed(c, "webm_stop")
	}
}

# the outcome a re-delivery re-reports: a capture's mark for the last
# directive replaces what the frame that applied it recorded
last_directive_after : { id : I64, refused : Str, result : Str }, CaptureAction -> { id : I64, refused : Str, result : Str }
last_directive_after = |ld, act|
	match act {
		Mark(m) if m.id == ld.id => { id: m.id, refused: m.refused, result: m.result }
		_ => ld
	}

expect {
	c = { id: 7, refused: "range 45 not 30/60/90", path: "/h/captures/table.png", name: "table.png", since: 1 }
	ld = { id: 7, refused: "range 45 not 30/60/90", result: "" }
	capture_abandon(NoCapture) == Nothing
		and capture_abandon(ArmedShot(c)) == Mark({ id: 7, refused: "range 45 not 30/60/90; capture png failed: the window closed before the host answered", result: "" })
		and capture_abandon(AwaitingStop({ ..c, refused: "" })) == Mark({ id: 7, refused: "capture webm_stop failed: the window closed before the host answered", result: "" })
		and last_directive_after(ld, Mark({ id: 7, refused: "range 45 not 30/60/90", result: "/h/captures/table.png" })) == { id: 7, refused: "range 45 not 30/60/90", result: "/h/captures/table.png" }
		and last_directive_after(ld, Mark({ id: 8, refused: "", result: "/h/captures/table.png" })) == ld
		and last_directive_after(ld, Nothing) == ld
}

# why the recorder refused or died, in the status row's words
rec_failure_text : Capture.FailureReason -> Str
rec_failure_text = |r|
	match r {
		PathInvalid => "the path is invalid"
		PathEscapesOutputDir => "the path leaves ./captures"
		AlreadyRecording => "a recording is already running"
		BudgetExceeded => "the recording budget is spent"
		UnsupportedFormat => "the format is unsupported here"
		OutOfMemory => "the host ran out of memory"
		WriteFailed => "the file could not be written"
		EncodeFailed => "the encoder failed"
		Unknown => "the host gave no reason"
	}

# the view has settled when its arrival animation is over (settle_ticks),
# no trace or ghost fetch is in flight, no reload is, and on the map view
# the map has landed
view_settled : { view : U8, view_anim : U64, tick : U64, trace_loading : Bool, ghost_loading : Bool, reloading : Bool, map_loading : Bool } -> Bool
view_settled = |m| (m.view_anim == 0 or m.tick - m.view_anim >= settle_ticks(m.view)) and !m.trace_loading and !m.ghost_loading and !m.reloading and !(Map.is_map(m.view) and m.map_loading)

# how long a view animates after it arrives: the career view's sweep
# (Career.sweep_ticks), and the crossfade and the form board's draw-in, half
# a second, for every other view. A capture waits this out, so it writes
# the settled frame and never one mid-animation.
settle_ticks : U8 -> U64
settle_ticks = |v| if (v == 8) Career.sweep_ticks else ticks_per_second / 2

expect {
	m = [
		{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan },
		{ id: 2, day: "d2", name: "n2", sport: "Rowing", chan: Db.watts_chan },
	]
	dv = { has_d: Bool.True, id: 0, view: 2, range: -1, cursor_day: "", trace_day: "", ghost_day: "d1", trace_id: -1, ghost_id: -1, capture: "", family: "", short: -1 }
	# naming the shown session as its own ghost is refused BY NAME - the kind
	# test cannot catch it (a session trivially matches itself) and the
	# dismissal downstream is silent
	refusals_for(dv, "", 0, 0, m, Bool.False, Bool.False) == "ghost_day d1 is the session on screen"
		# the same day as a ghost for the OTHER session is a kind question, and
		# these two differ by sport
		and refusals_for(dv, "", 1, 1, m, Bool.False, Bool.False) == "ghost_day d1 is Ride, the session is Rowing"
		# a clean directive refuses nothing
		and refusals_for({ has_d: Bool.True, id: 0, view: 2, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, capture: "", family: "", short: -1 }, "", 0, 0, m, Bool.False, Bool.False) == ""
}

# a session named by id is judged by identity: absent, the one on screen, or
# the wrong kind - each spelled out, and none of them a day question
expect {
	m = [
		{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan },
		{ id: 2, day: "d2", name: "n2", sport: "Rowing", chan: Db.watts_chan },
	]
	blank = { has_d: Bool.True, id: 0, view: 2, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, capture: "", family: "", short: -1 }
	# an id no picker entry carries; the selection did not move, so it is
	# judged against the shown session and refused by name
	refusals_for({ ..blank, trace_id: 9 }, "", 0, 0, m, Bool.False, Bool.False) == "trace_id 9 not in the picker"
		# the same absent id while the selection MOVED (wsel differs from
		# cur_sel) is not judged against the shown session at all - the move is
		# the answer - so nothing is refused; this is the guard's own case
		and refusals_for({ ..blank, trace_id: 9 }, "", 1, 0, m, Bool.False, Bool.False) == ""
		and refusals_for({ ..blank, ghost_id: 9 }, "", 0, 0, m, Bool.False, Bool.False) == "ghost_id 9 not in the picker"
		and refusals_for({ ..blank, ghost_id: 1 }, "", 0, 0, m, Bool.False, Bool.False) == "ghost_id 1 is the session on screen"
		and refusals_for({ ..blank, ghost_id: 1 }, "", 1, 1, m, Bool.False, Bool.False) == "ghost_id 1 is Ride, the session is Rowing"
		# 'none' dismisses; an id beside it is never judged, so nothing is refused
		# - not an absent id, not the shown session's own id, not one of the
		# wrong kind (each would otherwise name its own refusal)
		and refusals_for({ ..blank, ghost_day: "none", ghost_id: 9 }, "", 0, 0, m, Bool.False, Bool.False) == ""
		and refusals_for({ ..blank, ghost_day: "none", ghost_id: 1 }, "", 0, 0, m, Bool.False, Bool.False) == ""
		and refusals_for({ ..blank, ghost_day: "none", ghost_id: 1 }, "", 1, 1, m, Bool.False, Bool.False) == ""
}

# a day beside an id: the id takes precedence in the resolver, so the
# refusal names the id alone (the day was never consulted); the same day
# alone is still judged, and a day beside a RESOLVED id refuses nothing
expect {
	m = [
		{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan },
		{ id: 2, day: "d2", name: "n2", sport: "Rowing", chan: Db.watts_chan },
	]
	blank = { has_d: Bool.True, id: 0, view: 2, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, capture: "", family: "", short: -1 }
	refusals_for({ ..blank, trace_day: "d9", trace_id: 9 }, "", 0, 0, m, Bool.False, Bool.False) == "trace_id 9 not in the picker"
		and refusals_for({ ..blank, trace_day: "d9" }, "", 0, 0, m, Bool.False, Bool.False) == "trace_day d9 not in the picker"
		and refusals_for({ ..blank, trace_day: "d9", trace_id: 1 }, "", 0, 0, m, Bool.False, Bool.False) == ""
		and refusals_for({ ..blank, ghost_day: "d9", ghost_id: 9 }, "", 0, 0, m, Bool.False, Bool.False) == "ghost_id 9 not in the picker"
		and refusals_for({ ..blank, ghost_day: "d9" }, "", 0, 0, m, Bool.False, Bool.False) == "ghost_day d9 not in the picker"
		and refusals_for({ ..blank, ghost_day: "d1", ghost_id: 2 }, "", 0, 0, m, Bool.False, Bool.False) == "ghost_id 2 is Rowing, the session is Ride"
		and refusals_for({ ..blank, ghost_day: "d2", ghost_id: 9 }, "", 0, 0, m, Bool.False, Bool.False) == "ghost_id 9 not in the picker"
}

# a capture is judged by its vocabulary and by the recorder's state: a
# misspelt kind is named with the vocabulary, a start while a recording runs
# and a stop while none does are refused by name, and a PNG is always
# askable; the capture refusal joins the others with the separator. A
# cursor_day refusal names the reason Board.cursor_at gave, and a day it
# took is not refused
expect {
	m = [
		{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan },
	]
	blank = { has_d: Bool.True, id: 0, view: 2, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, capture: "", family: "", short: -1 }
	refusals_for({ ..blank, capture: "gif" }, "", 0, 0, m, Bool.False, Bool.False) == "capture gif not png/webm_start/webm_stop"
		and refusals_for({ ..blank, capture: "png" }, "", 0, 0, m, Bool.False, Bool.False) == ""
		and refusals_for({ ..blank, capture: "png" }, "", 0, 0, m, Bool.True, Bool.False) == ""
		and refusals_for({ ..blank, capture: "png" }, "", 0, 0, m, Bool.False, Bool.True) == "capture png: an earlier capture is still pending"
		and refusals_for({ ..blank, capture: "gif" }, "", 0, 0, m, Bool.False, Bool.True) == "capture gif not png/webm_start/webm_stop"
		and refusals_for({ ..blank, capture: "webm_start" }, "", 0, 0, m, Bool.False, Bool.False) == ""
		and refusals_for({ ..blank, capture: "webm_start" }, "", 0, 0, m, Bool.True, Bool.False) == "capture webm_start: a recording is already running"
		and refusals_for({ ..blank, capture: "webm_stop" }, "", 0, 0, m, Bool.True, Bool.False) == ""
		and refusals_for({ ..blank, capture: "webm_stop" }, "", 0, 0, m, Bool.False, Bool.False) == "capture webm_stop: no recording is running"
		and refusals_for({ ..blank, range: 45, capture: "webm_stop" }, "", 0, 0, m, Bool.False, Bool.False) == "range 45 not 30/60/90; capture webm_stop: no recording is running"
		and refusals_for({ ..blank, cursor_day: "2026-12-20" }, "past the projection's last day, 2026-12-15", 0, 0, m, Bool.False, Bool.False) == "cursor_day 2026-12-20 not in the series: past the projection's last day, 2026-12-15"
		and refusals_for({ ..blank, cursor_day: "2026-11-20" }, "", 0, 0, m, Bool.False, Bool.False) == ""
}

expect join_refusal("", "b") == "b" and join_refusal("a", "") == "a" and join_refusal("a", "b") == "a; b"
# the deferred mark, pinned: a PNG arms until the view has settled, then
# takes the shot; the answer for its id marks with the path, a failure or a
# shot that wrote no file joins the reason to what the directive's other
# fields refused, with no result; an answer for another id (the S key's)
# is not the directive's; every wait gives up at the timeout with no result
expect {
	c = { id: 3, refused: "", path: "/h/captures/power.png", name: "power.png", since: 100 }
	ev = { shot: NoShot, rec: Idle, settled: Bool.False, tick: 101 }
	armed = capture_step(ArmedShot(c), ev)
	taken = capture_step(ArmedShot(c), { ..ev, settled: Bool.True })
	ok = capture_step(AwaitingShot(c), { ..ev, shot: ShotDone(3, Ok({})) })
	bad = capture_step(AwaitingShot({ ..c, refused: "range 45 not 30/60/90" }), { ..ev, shot: ShotDone(3, Err(Host(Busy))) })
	other = capture_step(AwaitingShot(c), { ..ev, shot: ShotDone(4, Ok({})) })
	empty = capture_step(AwaitingShot(c), { ..ev, shot: ShotDone(3, Err(NoFile)) })
	late = capture_step(AwaitingShot(c), { ..ev, tick: 700 })
	armed == { next: ArmedShot(c), act: Nothing }
		and taken == { next: AwaitingShot({ ..c, since: 101 }), act: TakeShot({ id: 3, name: "power.png" }) }
		and ok == { next: NoCapture, act: Mark({ id: 3, refused: "", result: "/h/captures/power.png" }) }
		and bad == { next: NoCapture, act: Mark({ id: 3, refused: "range 45 not 30/60/90; capture png failed: the host is busy", result: "" }) }
		and empty == { next: NoCapture, act: Mark({ id: 3, refused: "capture png failed: the host answered but wrote no file", result: "" }) }
		and other == { next: AwaitingShot(c), act: Nothing }
		and late == { next: NoCapture, act: Mark({ id: 3, refused: "capture png failed: no answer from the host within 10 seconds", result: "" }) }
}

# an armed PNG outlasts the host's ten seconds while its view loads, and
# gives up at the settle limit naming the load, not the host
expect {
	c = { id: 7, refused: "", path: "/h/captures/map.png", name: "map.png", since: 100 }
	ev = { shot: NoShot, rec: Idle, settled: Bool.False, tick: 100 + capture_timeout_ticks + 1 }
	capture_step(ArmedShot(c), ev) == { next: ArmedShot(c), act: Nothing }
		and capture_step(ArmedShot(c), { ..ev, tick: 100 + settle_timeout_ticks }) == { next: NoCapture, act: Mark({ id: 7, refused: "capture png failed: the view was still loading after 180 seconds", result: "" }) }
		and settle_timeout_ticks == 180 * ticks_per_second
}
# a start marks on Active with no result, its file not yet written, and a
# Failed read at the tick the wait began (the frame after the start, which
# is when the step first runs) marks the host's reason; a stop marks its
# file on a Finished that wrote bytes, the reason on one that wrote none
# or on Failed, and waits on Active
expect {
	c = { id: 5, refused: "", path: "/h/captures/power.webm", name: "power.webm", since: 100 }
	ev = { shot: NoShot, rec: Idle, settled: Bool.True, tick: 101 }
	fr = { frames: 0, dropped: 0 }
	started = capture_step(AwaitingStart(c), { ..ev, rec: Active(fr) })
	refused = capture_step(AwaitingStart(c), { ..ev, tick: 100, rec: Failed({ frames: 0, reason: AlreadyRecording }) })
	stopped = capture_step(AwaitingStop(c), { ..ev, rec: Finished({ frames: 9, bytes: 1 }) })
	unwritten = capture_step(AwaitingStop(c), { ..ev, rec: Finished({ frames: 9, bytes: 0 }) })
	died = capture_step(AwaitingStop(c), { ..ev, rec: Failed({ frames: 9, reason: EncodeFailed }) })
	waiting = capture_step(AwaitingStop(c), { ..ev, rec: Active(fr) })
	gone = capture_step(AwaitingStart(c), { ..ev, tick: 700 })
	started == { next: NoCapture, act: Mark({ id: 5, refused: "", result: "" }) }
		and refused == { next: NoCapture, act: Mark({ id: 5, refused: "capture webm_start failed: a recording is already running", result: "" }) }
		and stopped == { next: NoCapture, act: Mark({ id: 5, refused: "", result: "/h/captures/power.webm" }) }
		and unwritten == { next: NoCapture, act: Mark({ id: 5, refused: "capture webm_stop failed: the recording wrote no file", result: "" }) }
		and died == { next: NoCapture, act: Mark({ id: 5, refused: "capture webm_stop failed: the encoder failed", result: "" }) }
		and waiting == { next: AwaitingStop(c), act: Nothing }
		and gone == { next: NoCapture, act: Mark({ id: 5, refused: "capture webm_start failed: no answer from the host within 10 seconds", result: "" }) }
		and capture_is_pending(AwaitingStop(c)) and !capture_is_pending(NoCapture)
		and capture_path("", "power.png") == "captures/power.png" and capture_path("/h", "power.png") == "/h/captures/power.png"
		and view_settled({ view: 0, view_anim: 0, tick: 5, trace_loading: Bool.False, ghost_loading: Bool.False, reloading: Bool.False, map_loading: Bool.False })
		and !view_settled({ view: 0, view_anim: 100, tick: 129, trace_loading: Bool.False, ghost_loading: Bool.False, reloading: Bool.False, map_loading: Bool.False })
		and view_settled({ view: 0, view_anim: 100, tick: 130, trace_loading: Bool.False, ghost_loading: Bool.False, reloading: Bool.False, map_loading: Bool.False })
		and !view_settled({ view: 0, view_anim: 100, tick: 130, trace_loading: Bool.True, ghost_loading: Bool.False, reloading: Bool.False, map_loading: Bool.False })
		and !view_settled({ view: 0, view_anim: 100, tick: 130, trace_loading: Bool.False, ghost_loading: Bool.True, reloading: Bool.False, map_loading: Bool.False })
		and !view_settled({ view: 0, view_anim: 0, tick: 130, trace_loading: Bool.False, ghost_loading: Bool.False, reloading: Bool.True, map_loading: Bool.False })
		and !view_settled({ view: 8, view_anim: 100, tick: 130, trace_loading: Bool.False, ghost_loading: Bool.False, reloading: Bool.False, map_loading: Bool.False })
		and !view_settled({ view: 8, view_anim: 100, tick: 100 + Career.sweep_ticks - 1, trace_loading: Bool.False, ghost_loading: Bool.False, reloading: Bool.False, map_loading: Bool.False })
		and view_settled({ view: 8, view_anim: 100, tick: 100 + Career.sweep_ticks, trace_loading: Bool.False, ghost_loading: Bool.False, reloading: Bool.False, map_loading: Bool.False })
}

# Reports a directive's terminal outcome from the task lane.
mark_task! : Access, I64, Str, Str => I64
mark_task! = |acc, did, refused, result| {
	_ = match open_db!(acc) {
		Err(_) => {}
		Ok(db) => Db.mark_directive!(db, did, refused, result)
	}
	did
}

# After ESC the window leaves once the focus clear (and the mark of a
# capture ESC closed) has landed, or once half a second has passed without
# it: a database that will not answer must not hold the window open. Ticks
# only grow, so the difference cannot wrap.
exits_now : Bool, U64, U64 -> Bool
exits_now = |cleared, tick, quit_tick| cleared or tick - quit_tick >= ticks_per_second / 2

# the clear landing ends the wait at once; without it the wait ends half a
# second (30 ticks) after ESC and not before
expect exits_now(Bool.True, 100, 100)
expect !exits_now(Bool.False, 129, 100)
expect exits_now(Bool.False, 130, 100)
expect exits_now(Bool.False, 5000, 100)

# The window's last word: delete the focus row on the way out. Either
# outcome ends the quit - a clear that failed changes nothing the staleness
# window will not retire on its own.
clear_focus_task! : Access => Msg
clear_focus_task! = |acc|
	match open_db!(acc) {
		Err(_) => FocusCleared
		Ok(db) => match Db.clear_focus!(db) {
			Ok(_) => FocusCleared
			Err(_) => FocusCleared
		}
	}

# The window's answer: upsert what the human is looking at
focus_task! : Access, Db.Focus => Msg
focus_task! = |acc, f|
	if (acc.dir == "") FocusWriteFailed
	else match open_db!(acc) {
		Err(_) => FocusWriteFailed
		Ok(db) => match Db.write_focus!(db, f) {
			Ok(_) => FocusWritten
			Err(_) => FocusWriteFailed
		}
	}

# What a curve change (its window or its family) depends on: the curve over
# the window and over the window before it, the window's 20-minute best,
# the curve's record rungs and threshold, and the CP fit. Everything else
# the model holds (the series, the heat, the career, the plan, the trace)
# is the same whatever the window says, so a chip click reads only these.
# R still runs the full loader, which is what R is for.
CurveWindow : { days : I64, fam : Str, prs : List(Db.PrRung), c : List(Db.CurvePt), cpv : List(Db.CurvePt), lbls : List({ p : Text.Prepared, d : I64 }), title : Text.Prepared, fit_lbl : Text.Prepared, cp_lbl : Text.Prepared, fit_cp : F32, info : Db.CurveInfo }

load_curve_window! : Access, Text.Font, I64, Str => Try(CurveWindow, [ResourceLimit])
load_curve_window! = |acc, font, curve_days, curve_family| {
	read = match open_db!(acc) {
		Ok(db) => {
			tm = Db.today_mod!(acc.io.commands(), db)
			{ c: Db.load_curve!(db, curve_days, tm, curve_family), cpv: Db.load_curve_prev!(db, curve_days, tm, curve_family), b20: Db.load_best20_age!(db, curve_days, tm, curve_family), prs: Db.load_prs!(db, curve_family), un: Db.units!(db), thr: Db.load_threshold!(db, curve_family) }
		}
		Err(_) => { c: [], cpv: [], b20: -1, prs: [], un: Metric, thr: 0.0 }
	}
	ft = Db.load_fit!(acc.io.commands(), curve_days, curve_family)
	fit = ft.fit
	fit_text = Curve.anchor_caption_for(curve_family, read.un, fit, ft.test, read.b20)
	# the same two faces the full loader prepares these labels with, so a
	# window switch cannot re-set the curve in a different type
	head = brand_font!(acc, "Quicksand-Medium.ttf", 24, font)
	mono = brand_font!(acc, "JetBrainsMono-Regular.ttf", 24, font)
	mk! = |txt, sz| Text.from(txt, head).size(sz).prepare!()
	mkm! = |txt, sz| Text.from(txt, mono).size(sz).prepare!()
	lbls = List.map_try!(
		read.c,
		|x| {
			p = mkm!(I64.to_str(x.dur_s), 12)?
			Ok({ p, d: x.dur_s })
		},
	)?
	Ok({
		days: curve_days,
		fam: curve_family,
		prs: read.prs,
		c: read.c,
		cpv: read.cpv,
		lbls,
		title: mk!(Curve.title_text(curve_family, curve_days), 15)?,
		fit_lbl: mk!(Db.ascii_safe(fit_text), 14)?,
		cp_lbl: mkm!(Curve.anchor_tag(curve_family, read.un, fit, ft.test), 12)?,
		fit_cp: Curve.anchor_line(curve_family, fit, ft.test),
		info: { fit, test: ft.test, thr: read.thr, best20_age: read.b20 },
	})
}

# Reload work is Cmd, Sqlite and text preparation: all of it legal in a
# task and none of it in update!, where the platform panics on Cmd.
# update! only ever spawns; results come back through these messages.
Msg : [
	# a window change's answer, carrying the window it answers so a reply
	# that arrives after the athlete has already clicked another chip is
	# recognised as stale and dropped rather than painted over the newer one
	CurveReloaded(CurveWindow),
	CurveReloadFailed(I64, Str),
	# a fetch reply names the generation it was spawned under, not the picker
	# index it read: the model applies it only while that generation is still
	# current, so a reply for a superseded switch lands nowhere
	GhostSwitched({ tr : List(F32), du : F32, gen : U64, day : Str }),
	GhostSwitchFailed(U64),
	Shot(Try({}, Capture.ScreenshotError)),
	# a directive's screenshot answer, tagged with its row so the S key's cannot close it
	DirShot({ id : I64, res : Try({}, ShotError) }),
	RecCmd(Try({}, [PermissionDenied])),
	MarkDone(I64),
	Reloaded(Ui.Model),
	ReloadFailed,
	TraceSwitched({ tr : List(F32), sg : List(Db.Seg), du : F32, gen : U64, day : Str, un : Str, sp : List(Series.Split), st : Db.StrengthLog }),
	MapLoaded({ map : Db.MapData, gen : U64 }),
	# the picker row of a session the map opened that the picker did not
	# hold, or NoTrace when its stream holds nothing the trace can plot
	MapOpened({ id : I64, row : Try(TraceId, [NoTrace]) }),
	TileAnswer({ ans : Tiles.Answer, cache : CacheWrite }),
	SourceRead(Try(Str, [NoTemplate])),
	TraceSwitchFailed(U64),
	# `ids` is the picker as the database holds it at poll time, read only when
	# the directive names a session: what a session-naming directive is judged
	# against, so a session synced since boot is steerable and one deleted
	# since is refused, rather than either being judged against a boot-time
	# cache. Kept means the directive named no session and nothing was read.
	Directive({ dv : Db.Directive, note : Db.BusNote, ids : [Kept, Fresh(List(TraceId))] }),
	Polled(Db.BusNote),
	DirectiveNone,
	FocusWritten,
	FocusWriteFailed,
	FocusCleared,
	DayDetail({ day : Str, lines : List(Db.DayLine) }),
]

# One cache entry per picker row it is given, in the same order: trace,
# segments, duration, unit, splits and sets. The load passes only the
# newest row. Recursion because an effectful body cannot reassign an
# outer var.
load_tcache! : Sqlite.Db, [Metric, Imperial], List(TraceId) => List({ tr : List(F32), sg : List(Db.Seg), du : F32, un : Str, sp : List(Series.Split), st : Db.StrengthLog })
load_tcache! = |db, units, ids|
	match List.first(ids) {
		Err(_) => []
		Ok(te) => {
			tr9 = Db.load_trace!(db, te.id, te.chan)
			sg9 = Db.load_segs!(db, te.id)
			du9 = Db.load_dur!(db, te.id)
			# splits only where a pace trace draws them - the panel is the
			# pace channel's companion, and the arrays are only read once
			sp9 = if (te.chan == Db.pace_chan) (Db.load_splits!(db, te.id, Db.split_len_for(units, te.sport))) else []
			st9 = if (Trace.strength_session(te.sport)) (Db.load_sets!(db, te.id)) else { rows: [], pasted: Bool.False }
			# the unit travels with the samples so a cache read needs no second
			# lookup into the picker row; prepend so picker order survives
			# without List.reverse, which this stdlib lacks
			List.prepend(load_tcache!(db, units, List.drop_first(ids, 1)), { tr: tr9, sg: sg9, du: du9, un: Db.trace_unit(te.chan, units, te.sport), sp: sp9, st: st9 })
		}
	}

# the focus row's view code, a pure top-level function: on the pinned
# compiler a multi-arm conditional built inline inside a task closure
# miscompiles, and a call compiles correctly
focus_view_code : U8 -> I64
focus_view_code = |v|
	if (v == 0) (0) else if (v == 1) (1) else if (v == 2) (2) else if (v == 3) (3) else if (v == 4) (4) else if (v == 5) (5) else if (v == 6) (6) else if (v == 7) (7) else if (v == 8) (8) else if (v == 9) (9) else if (v == 10) (10) else if (v == 11) (11) else 12

# ONE view->basename map for every capture format: png and webm derive
# from it, so a capture is named for its view in both
view_basename : U8 -> Str
view_basename = |v|
	if (v == 0) "form-board" else if (v == 1) "power" else if (v == 2) "session-trace" else if (v == 3) "data-table" else if (v == 4) "plan" else if (v == 5) "heat" else if (v == 6) "zones" else if (v == 7) "ramp" else if (v == 8) "career" else if (v == 9) "lifts" else if (v == 10) "map" else if (v == 11) "map-heat" else "map-play"

# The first load asks for no family, so load_model! opens the curve on the
# athlete's most-trained family (Db.default_curve) rather than a fixed sport.
boot_curve_family : Str
boot_curve_family = ""

expect boot_curve_family == ""

# the highest view number a directive may name, the one caps_views ends on
last_view : I64
last_view = 12

expect List.last(caps_views) == Ok({ id: last_view, name: "map-play" })

# every map mode is a view a directive may name, and the number past the
# last is not
expect {
	dv = { has_d: Bool.True, id: 0, view: 10, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, capture: "", family: "", short: -1 }
	List.all([10, 11, 12], |v| refusals_for({ ..dv, view: v }, "", 0, 0, [], Bool.False, Bool.False) == "") and refusals_for({ ..dv, view: 13 }, "", 0, 0, [], Bool.False, Bool.False) == "view 13 unknown"
}

# what the bus accepts, as data. caps_views derives from view_basename
# so the published list can never drift from the dispatch; caps_fields must
# move together with refusals_for - the accepts column states the same rules
# that function enforces, and both live in this file so an edit sees both.
caps_views : List({ id : I64, name : Str })
caps_views = List.map([0.U8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], |v| { id: U8.to_i64(v), name: view_basename(v) })

caps_fields : List({ name : Str, kind : Str, accepts : Str })
caps_fields = [
	{ name: "view", kind: "integer", accepts: "0..12 (3, 4 and 5 are the day tab's log, week and year modes; 10, 11 and 12 the map tab's routes, heat and play)" },
	{ name: "range", kind: "integer", accepts: "30|60|90 (days; omitted leaves the range unchanged)" },
	{ name: "cursor_day", kind: "date", accepts: "YYYY-MM-DD the view shows: a day of the measured series, or on the form board a projected day past it; a refusal names why" },
	{ name: "trace_day", kind: "date", accepts: "YYYY-MM-DD among the trace picker's sessions; picks that day's newest session, trace_id names one exactly" },
	{ name: "ghost_day", kind: "date", accepts: "YYYY-MM-DD among the trace picker's sessions, or 'none' to dismiss; picks that day's newest session of the shown session's kind" },
	{ name: "trace_id", kind: "integer", accepts: "an activity id among the trace picker's sessions; when both are given it takes precedence over trace_day" },
	{ name: "ghost_id", kind: "integer", accepts: "an activity id among the trace picker's sessions, of the same kind as the session shown; takes precedence over ghost_day, and 'none' in ghost_day still dismisses" },
	{ name: "capture", kind: "text", accepts: "'png' writes the view the directive lands on, once it has settled, to captures/<view>.png under the window's working directory; 'webm_start' and 'webm_stop' begin and end a WebM recording of it; the row stays pending until the host answers, then result names the file by its absolute path once it exists: a written PNG, or the recording a stop finished; a start closes with no result" },
	{ name: "family", kind: "text", accepts: "a sport family's head ('Ride', 'Rowing', 'Run', ...) switches the power view to that family's power curve, record book and CP fit; 'pace:' and a sport type ('pace:Run', 'pace:Swim', 'pace:Rowing') switches it to that sport's pace curve and critical-speed fit; refused by name when the athlete has no such data; omitted leaves it unchanged" },
	{ name: "short", kind: "integer", accepts: "1 shows the power or pace curve's short rungs (under 5 minutes), 0 folds them when none was pushed all-out; any other value is refused by name; omitted leaves it unchanged" },
]

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model0, program_input, io| {
	d = program_input.devices
	# never behind the last cycle's tick: every age below is a U64 difference
	# against a stamp taken from an earlier tick
	tick = U64.max(tick_at(program_input.time), model0.tick)
	# task answers land as messages; fold them in before this frame's input.
	# A finished reload keeps the UI state the user has moved since spawning.
	model = List.fold(
		program_input.messages,
		model0,
		|acc, msg|
			match msg {
				Shot(_) => acc
				DirShot(_) => acc
				RecCmd(_) => acc
				MarkDone(mid) => if (mid == acc.quit_mark_pending) ({ ..acc, quit_mark_pending: -1 }) else acc
				# also the boot task's failure exit: the splash must never spin
				# forever, so a dead load hands over to the skeleton's own screens.
				# A failed reload lowers the reloading flag as a landed one does, so
				# the power view's loading note never stays on screen after it.
				ReloadFailed => { ..acc, booting: Bool.False, reloading: Bool.False }
				# only the answer to the CURRENT window and family lands: a click
				# moves curve_days or curve_family first, so an older reply no
				# longer matches and is dropped whole, its reloading flag
				# included, which the newer request still owns; a failure is
				# matched the same way
				CurveReloaded(w) =>
					if (w.days != acc.curve_days or w.fam != acc.curve_family) acc
					else { ..acc, prs: w.prs, curve: w.c, curve_prev: w.cpv, curve_lbls: w.lbls, curve_title: w.title, fit_lbl: w.fit_lbl, cp_lbl: w.cp_lbl, fit_cp: w.fit_cp, curve_info: w.info, reloading: Bool.False }
				CurveReloadFailed(days, fam) => if (days != acc.curve_days or fam != acc.curve_family) acc else { ..acc, reloading: Bool.False }
				# a failed fetch lowers the loading flag only if it was the current
				# fetch: a failure for a superseded switch must not clear the flag
				# the newer fetch still owns
				TraceSwitchFailed(g) => if (g != acc.trace_gen) acc else { ..acc, trace_loading: Bool.False }
				GhostSwitchFailed(gg) => if (gg != acc.ghost_gen) acc else { ..acc, ghost_loading: Bool.False }
				# only the reply for the current ghost generation lands: a slow load
				# for a pick since replaced, or since dismissed, applies nowhere
				GhostSwitched(gw) => if (gw.gen == acc.ghost_gen) ({ ..acc, ghost: gw.tr, ghost_dur: gw.du, ghost_day: gw.day, ghost_loading: Bool.False }) else acc
				DirectiveNone => acc
				Polled(note) => { ..acc, bus_note: note }
				FocusWritten => acc
				FocusCleared => { ..acc, focus_cleared: Bool.True }
				# only the answer for the day still open lands; a result for a day
				# the user closed or switched away from is dropped
				DayDetail(dd) => if (dd.day == acc.detail_day) ({ ..acc, detail: dd.lines }) else acc
				# a dropped write must not leave the coach stale: resetting
				# last_focus makes the next throttle tick try again
				FocusWriteFailed => { ..acc, last_focus: { view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, detail_day: "", sport: "", family: "", curve_family: "", curve_short: -1, map_id: -1 } }
				# a session-naming directive replaces the picker with the one it
				# was read against, so the refusal below and the selection it
				# resolves both see the database as it is. The trace cache is
				# index-aligned to the picker, so it empties with the re-read,
				# and the selection follows the shown session by id rather than
				# by position, since a session synced since boot shifts every
				# position after it. The shown samples stay unless the shown
				# session itself is gone: the header names sessions by index, so
				# leaving those samples under the index the selection fell to
				# would label one session with another's name - trace_refetch
				# makes the next frame fetch what the selection now names. A
				# redelivered directive (its id already applied) changes nothing.
				Directive(d2) =>
					match d2.ids {
						Kept => { ..acc, bus_note: d2.note }
						Fresh(fresh) =>
							if (d2.dv.id == acc.last_directive.id) { ..acc, bus_note: d2.note }
							else {
								r = sel_following_id(acc.trace_ids, acc.trace_sel, fresh)
								# refetch only when the shown session is gone: the fallback
								# is a different session whose samples are not in memory.
								# A session merely moved to another index needs nothing -
								# a fetch still in flight for it is matched by generation,
								# not by index, and its samples land under the new index;
								# samples already drawn are that session's by id.
								# The ghost follows its session by id the same way, and a
								# ghost whose session is gone is dismissed - its samples,
								# day and duration cleared together - rather than left
								# pointing at whatever session now holds its old index.
								# A dismissal here opens a new ghost generation exactly as
								# a keyboard dismissal does, so a ghost fetch still in
								# flight for the vanished session lands nowhere instead
								# of resurrecting its samples beside a cleared selection.
								g = ghost_after_reread(acc.ghost_sel, acc.trace_ids, fresh)
								{ ..acc, bus_note: d2.note, trace_ids: fresh, trace_cache: [], trace_sel: r.sel, trace_refetch: !r.found and !(List.is_empty(fresh)), ghost_sel: g.sel, ghost_loading: (if (g.keep) acc.ghost_loading else Bool.False), ghost: (if (g.keep) acc.ghost else []), ghost_day: (if (g.keep) acc.ghost_day else ""), ghost_dur: (if (g.keep) acc.ghost_dur else 0.0), ghost_gen: (if (g.keep) acc.ghost_gen else acc.ghost_gen + 1) }
							}
					}
				Reloaded(fresh) => {
					merged = { ..fresh, map: acc.map, map_tiles: acc.map_tiles, map_source: acc.map_source, map_cache_err: acc.map_cache_err, map_planned: acc.map_planned, map_plan_due: acc.map_plan_due, map_heat: acc.map_heat, map_play: acc.map_play, map_speed: acc.map_speed, map_marks: acc.map_marks, map_gen: acc.map_gen, map_load: (map_on_reload(acc.map_load)).load, map_stale: (map_on_reload(acc.map_load)).stale, map_cam: acc.map_cam, map_moved: acc.map_moved, map_card: acc.map_card, map_rt: acc.map_rt, range: acc.range, view: acc.view, spine_idx: acc.spine_idx, cursor: acc.cursor, cursor_ahead: acc.cursor_ahead, mouse_x: acc.mouse_x, mouse_y: acc.mouse_y, mouse_in: acc.mouse_in, tick: acc.tick, last_active: acc.last_active, last_focus: acc.last_focus, win: acc.win, ui_percent: acc.ui_percent, ui_scale: acc.ui_scale, detail_day: acc.detail_day, detail: acc.detail, view_anim: acc.view_anim, pending_capture: acc.pending_capture, rec_path: acc.rec_path, rec_status: acc.rec_status, last_directive: acc.last_directive, quit_mark_pending: acc.quit_mark_pending, flame: acc.flame }
					# R reads the curve it was pressed on, and it is the slow path.
					# A chip clicked while it ran has since moved curve_days or
					# curve_family and landed its own curve; when the two disagree
					# that slice is the newer answer and is kept, with the chip's
					# reloading flag, since its request may still be in flight,
					# while R refreshes everything else. A model still booting has
					# chosen no curve yet and takes the one the load chose.
					if (acc.curve_family == "" or (fresh.curve_days == acc.curve_days and fresh.curve_family == acc.curve_family)) merged
					else { ..merged, curve_family: acc.curve_family, prs: acc.prs, curve: acc.curve, curve_prev: acc.curve_prev, curve_lbls: acc.curve_lbls, curve_title: acc.curve_title, curve_days: acc.curve_days, fit_lbl: acc.fit_lbl, cp_lbl: acc.cp_lbl, fit_cp: acc.fit_cp, curve_info: acc.curve_info, reloading: acc.reloading }
				}
				# only the reply for the current trace generation lands: two switches
				# faster than the first fetch resolves would otherwise let the first,
				# stale answer overwrite the second. A dropped stale reply leaves the
				# loading flag up, since the newer fetch is still coming. The reply
				# carries samples, never a selection - trace_sel belongs to the frame
				# that switches, and a picker re-read may have moved the session
				# since the fetch read its index; the samples are still that
				# session's, so they land under whatever index it holds now.
				TraceSwitched(sw) => if (sw.gen != acc.trace_gen) acc else { ..acc, trace: sw.tr, segs: sw.sg, trace_dur: sw.du, trace_day: sw.day, trace_unit: sw.un, trace_splits: sw.sp, trace_sets: sw.st, trace_loading: Bool.False }
				# the map lands only from the newest load and is repainted, its
				# speed bands not yet worked out; one R marked stale while it was
				# read is read once more (map_on_landing)
				MapLoaded(ml) => if (ml.gen != acc.map_gen) acc else { ..acc, map: ml.map, map_speed: Unbuilt, map_marks: Stale, map_load: map_on_landing(acc.map_stale), map_stale: Bool.False, map_painted: Map.unpainted, map_plan_due: Bool.True }
				# a session the map opened joins the picker where newest-first
				# order puts it (with_opened); the frame body opens a card still
				# waiting on it, and a card whose session has no trace says so
				MapOpened(mo) =>
					match mo.row {
						Ok(row) => with_opened(acc, row)
						Err(_) =>
							match acc.map_card {
								Open(o) => if (o.id == mo.id) { ..acc, map_card: Open({ ..o, state: NoTrace }) } else acc
								Closed => acc
							}
					}
				TileAnswer(ta) => tile_landed(acc, ta.ans, ta.cache, tick)
				# the template a tile fetch needs, or the tick the TileJSON could
				# not be read at, after which it is asked for again
				SourceRead(Ok(t)) => { ..acc, map_source: Known(t), map_plan_due: Bool.True }
				SourceRead(Err(_)) => { ..acc, map_source: Unreachable(tick), map_plan_due: Bool.True }
			},
	)
	# the coach's word arrives beside the human's input and steers only what
	# it names: view, range, a day for the crosshair, a session for the trace
	directive0 = List.fold(
		program_input.messages,
		{ has_d: Bool.False, id: -1.I64, view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, capture: "", family: "", short: -1 },
		|acc, msg|
			match msg {
				Directive(d2) => { has_d: Bool.True, id: d2.dv.id, view: d2.dv.view, range: d2.dv.range, cursor_day: d2.dv.cursor_day, trace_day: d2.dv.trace_day, ghost_day: d2.dv.ghost_day, trace_id: d2.dv.trace_id, ghost_id: d2.dv.ghost_id, capture: d2.dv.capture, family: d2.dv.family, short: d2.dv.short }
				_ => acc
			},
	)
	# a re-delivered id means the mark was lost to a busy database (the row
	# stayed pending and was polled again): re-report the recorded outcome
	# and apply NOTHING, since applying it again would undo the athlete's own
	# input every second for as long as a CLI write transaction held the lock
	is_redelivery = directive0.has_d and directive0.id == model.last_directive.id
	# ...unless the outcome is a capture's, still waiting on the host: the
	# row stays pending until the file is known. The re-mark carries the
	# result the capture produced, so a capture whose mark was lost does not
	# close as a plain applied
	_ = if is_redelivery and model.stride_dir != "" and !capture_is_pending(model.pending_capture) {
		accr = { io, dir: model.stride_dir }
		rid = model.last_directive.id
		rref = model.last_directive.refused
		rres = model.last_directive.result
		Task.spawn!(program_input, || MarkDone(mark_task!(accr, rid, rref, rres)))
	}
	# the pending capture's step for this frame: the directive's own
	# screenshot answer (the S key's is untagged and cannot close it), the
	# recorder's status, and whether the view has settled
	shot_done = List.fold(
		program_input.messages,
		NoShot,
		|acc9, msg9| match msg9 {
			DirShot(r9) => ShotDone(r9.id, r9.res)
			_ => acc9
		},
	)
	cap_step = capture_step(model.pending_capture, { shot: shot_done, rec: program_input.capture, settled: view_settled({ view: model.view, view_anim: model.view_anim, tick, trace_loading: model.trace_loading, ghost_loading: model.ghost_loading, reloading: model.reloading, map_loading: map_unread(model.map_load) or (capture_is_pending(model.pending_capture) and !(Map.tiles_settled(model))) }), tick })
	pending1 = cap_step.next
	_ = match cap_step.act {
		Nothing => {}
		TakeShot(t1) => {
			_ = Task.spawn!(program_input, || dir_shot_task!(io, t1.id, t1.name))
			{}
		}
		Mark(m1) => {
			_ = if model.stride_dir != "" {
				accs = { io, dir: model.stride_dir }
				Task.spawn!(program_input, || MarkDone(mark_task!(accs, m1.id, m1.refused, m1.result)))
			}
			{}
		}
	}
	# the outcome a re-delivery re-reports, once the capture has answered
	last_directive1 = last_directive_after(model.last_directive, cap_step.act)
	directive = if (is_redelivery) ({ has_d: Bool.False, id: -1.I64, view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "", trace_id: -1, ghost_id: -1, capture: "", family: "", short: -1 }) else directive0
	if model.quitting {
		# the wait for the focus clear is short, and answered at full rate
		Window.set_target_fps!(full_fps)
		if (exits_now(model.focus_cleared and model.quit_mark_pending < 0, tick, model.quit_tick)) (Err(Exit(0)))
		else Ok({ ..model, tick, pending_capture: pending1, last_directive: last_directive1 })
	} else if d.key_pressed(KeyEscape) and !(Map.card_up(model)) {
		if (model.stride_dir == "") (Err(Exit(0)))
		else {
			accq = { io, dir: model.stride_dir }
			_ = Task.spawn!(program_input, || clear_focus_task!(accq))
			# a capture still waiting closes now, by name: the window will not
			# be here to answer for it
			quit_mark = match capture_abandon(pending1) {
				Mark(mq) => {
					_ = Task.spawn!(program_input, || MarkDone(mark_task!(accq, mq.id, mq.refused, mq.result)))
					mq.id
				}
				_ => -1.I64
			}
			Ok({ ..model, quitting: Bool.True, quit_tick: tick, tick, pending_capture: NoCapture, last_directive: last_directive1, quit_mark_pending: quit_mark })
		}
	} else {
		pixels = { w: I32.to_f32(program_input.window.size.width), h: I32.to_f32(program_input.window.size.height) }
		ctrl = d.key_down(KeyLeftControl) or d.key_down(KeyRightControl)
		ui_action = if (!ctrl) Keep else if (d.key_pressed(KeyEqual)) Larger else if (d.key_pressed(KeyMinus)) Smaller else if (d.key_pressed(Key0)) Reset else Keep
		ui_percent = DisplayScale.adjust(model.ui_percent, ui_action)
		layout = DisplayScale.layout(ui_percent, pixels)
		win = { w: layout.w, h: layout.h }
		m0 = DisplayScale.point(d.mouse.position(), layout.scale)
		# the map's press and what it does to the card (Map.press_step,
		# Map.act), judged against the view the athlete was looking at. A
		# session the picker holds opens on the trace this frame; one it
		# lacks has its picker row read first, and opens in the frame that
		# row lands in, while its card still waits on it.
		map_step = if (Map.is_map(model.view)) (Map.press_step(model.map_drag, { down: Mouse.button_down(d.mouse, Left), pressed: Mouse.button_pressed(d.mouse, Left), on_map: Map.on_map(win, m0.x, m0.y), x: m0.x, y: m0.y })) else { press: Idle, click: Err(NoClick) }
		map_act = Map.act({ ..model, win }, map_step.click, { enter: d.key_pressed(KeyEnter) or d.key_pressed(KeyKpEnter), esc: d.key_pressed(KeyEscape) }, Scene.measure_of(model))
		map_listed = map_act.open >= 0 and List.any(model.trace_ids, |e| e.id == map_act.open)
		map_landed = List.fold(
			program_input.messages,
			-1,
			|acc, msg|
				match msg {
					MapOpened(mo) =>
						match mo.row {
							Ok(_) => mo.id
							Err(_) => acc
						}
					_ => acc
				},
		)
		map_open = if (map_listed) map_act.open else if (Map.is_map(model.view) and map_landed >= 0 and map_landed == Map.waiting_on(model.map_card)) map_landed else -1
		_ = if map_act.open >= 0 and !map_listed {
			acco = { io, dir: model.stride_dir }
			oid = map_act.open
			Task.spawn!(program_input, || map_open_task!(acco, oid))
		}
		map_card2 = if (map_open >= 0) (Map.with_state(map_act.card, Ready)) else if (map_act.open >= 0) (Map.with_state(map_act.card, Opening)) else map_act.card
		# nav clicks mirror the render geometry exactly (right-anchored pills)
		nav_click =
			if Mouse.button_pressed(d.mouse, Left) and m0.y >= 30.0 and m0.y <= 54.0 {
				nav_n = List.len(model.nav)
				List.fold(
					List.map_with_index(model.nav, |nv2, vi| { nv2, vi }),
					-1,
					|acc, x| {
						nx2 = Chrome.nav_x(win.w, nav_n, x.vi)
						if (m0.x >= nx2 and m0.x <= nx2 + Chrome.nav_width) (U8.to_i64(x.nv2.v)) else acc
					},
				)
			} else -1
		# the tabs' mode chips: week, log and year switch the day tab between
		# the plan, table and heat views, and zones and load switch the weeks
		# tab the same way, without leaving the tab
		day_mode = if (Days.is_day(model.view) and Mouse.button_pressed(d.mouse, Left)) (Days.mode_at(m0.x, m0.y)) else if (Weeks.is_week(model.view) and Mouse.button_pressed(d.mouse, Left)) (Weeks.mode_at(m0.x, m0.y)) else if (Map.is_map(model.view) and Mouse.button_pressed(d.mouse, Left)) (Map.mode_at(m0.x, m0.y)) else -1
		view_input =
			if (nav_click >= 0) (
				match I64.to_u8_try(nav_click) {
					Ok(v9) => if (v9 == 6) (Weeks.from_pill(v9, model.view)) else if (v9 == 10) (Map.from_pill(v9, model.view)) else Days.from_pill(v9, model.view)
					Err(_) => model.view
				}
			)
			else if (day_mode >= 0) (
				match I64.to_u8_try(day_mode) {
					Ok(dm) => dm
					Err(_) => model.view
				}
			)
			else if (map_open >= 0) 2
			else if (d.key_pressed(KeyTab)) (Days.next_view(model.view)) else model.view
		view = if (directive.has_d and directive.view >= 0 and directive.view <= last_view) (
			match I64.to_u8_try(directive.view) {
				Ok(v8) => v8
				Err(_) => view_input
			}
		) else view_input
		# the range chips are buttons: a left click inside one selects it,
		# hit-tested against the frame-true view render will draw. Chip
		# geometry mirrors Board's row exactly - right-anchored at
		# win.w - 420 + i*54, y 64, each 46x22 - and must move with it.
		clicked_chip =
			if (view == 0 or view == 1) and Mouse.button_pressed(d.mouse, Left) and m0.y >= 64.0 and m0.y <= 86.0 {
				chip0 = win.w - 420.0
				if (m0.x >= chip0 and m0.x <= chip0 + 46.0) (30.U64)
				else if (m0.x >= chip0 + 54.0 and m0.x <= chip0 + 100.0) (60.U64)
				else if (m0.x >= chip0 + 108.0 and m0.x <= chip0 + 154.0) (90.U64)
				else 0.U64
			} else 0.U64
		# 1/2/3 answer to whichever view is showing: the form board's range, or
		# the curve's window — never both at once
		range =
			# a directive's range lands on the view the directive lands on —
			# judged against THIS frame's visible view (post-directive, post-TAB),
			# never the prior frame's. The curve keeps its own window (want_days
			# below), never the form-board range.
			if (directive.has_d and view != 1 and (directive.range == 30 or directive.range == 60 or directive.range == 90)) (
				match I64.to_u64_try(directive.range) {
					Ok(rr) => rr
					Err(_) => model.range
				}
			) else
			# chips clicked on the power view re-window the curve (below), not this
				if (view != 1 and clicked_chip > 0) clicked_chip
				# keys judge the same frame-true view the directive rule does — a
				# TAB and a range key in one frame land the range where TAB went
				else if (view == 1) model.range
				else if (d.key_pressed(Key1)) 30.U64
				else if (d.key_pressed(Key2)) 60.U64
				else if (d.key_pressed(Key3)) 90.U64
				else model.range
		# the day cursor the form board and the data table share (chart
		# crosshair, table scroll); the other views leave it parked. It counts
		# days back from the series' latest day, the last ANALYZED day and not
		# necessarily today (0 = that column, -1 = off); LEFT walks older,
		# RIGHT newer, and the board clamps to its window. On the board RIGHT
		# walks on from the latest measured day into the projected days it
		# draws (Board.step); the table holds measured days only, so there
		# RIGHT from the latest turns the cursor off
		walked =
			if (view != 0 and view != 3) { back: model.cursor, ahead: model.cursor_ahead }
			else {
				here = { back: model.cursor, ahead: if (view == 0) model.cursor_ahead else 0 }
				projected = if (view == 0) List.len(Board.shown_proj(model)) else 0
				if (d.key_pressed(KeyLeft)) Board.step(here, Older, projected)
				else if (d.key_pressed(KeyRight)) Board.step(here, Newer, projected)
				else { back: model.cursor, ahead: model.cursor_ahead }
			}
		cursor = walked.back
		# a wheel notch or an up/down arrow scrolls the lifts list or the plan's
		# week ladder one row, clamped to the list's ends (Scroll). On the lifts
		# view a wheel over a session card that has lines to scroll moves the
		# card instead (Strength.wheels_card); anywhere else it moves the list.
		# A resize or reload that shortens a list pulls its offset back in
		notch = Mouse.wheel_delta(d.mouse)
		wheel_by = if (notch.y < -0.1) 1 else if (notch.y > 0.1) (-1) else 0
		scroll_by = if (wheel_by != 0) wheel_by else if (d.key_pressed(KeyDown)) 1 else if (d.key_pressed(KeyUp)) (-1) else 0
		on_card = model.view == 9 and wheel_by != 0 and Strength.wheels_card({ ..model, win }, m0.x, m0.y)
		lifts_last = Strength.lifts_last(model)
		last_last = Strength.last_last(model)
		week_last = Plan.week_last(model)
		lifts_off2 = if (model.view == 9 and scroll_by != 0 and !on_card) Scroll.step(model.lifts_off, scroll_by, lifts_last) else model.lifts_off.min(lifts_last)
		last_off2 = if (on_card) Scroll.step(model.last_off, wheel_by, last_last) else model.last_off.min(last_last)
		week_off2 = if (model.view == 4 and scroll_by != 0) Scroll.step(model.week_off, scroll_by, week_last) else model.week_off.min(week_last)
		# a click on a week's bar in either weeks mode picks it for both
		week_cursor2 = if (Weeks.is_week(model.view) and Mouse.button_pressed(d.mouse, Left) and m0.y > Weeks.chip_bottom) (Weeks.pick(model.week_cursor, Weeks.hovered_week({ ..model, mouse_x: m0.x, mouse_y: m0.y, win }))) else model.week_cursor
		m = m0
		# S writes a PNG of the CURRENT view into ./captures. Spawned rather
		# than called inline: a screenshot waits for the end of a frame, and
		# update! is not one. The file carries the view's own name, so view 1,
		# the power view, captures as power.png and power.webm.
		# img/power-curve.png in the docs is a committed illustration, not a
		# capture.
		_ = if d.key_pressed(KeyS) {
			shot_name = Str.concat(view_basename(view), ".png")
			Task.spawn!(program_input, || Shot(io.capture().screenshot!(shot_name)))
		}
		# V toggles a recording of whatever is on screen: WebM, full scale,
		# 30fps, FixedStep timing, so the same session records the same
		# frames every time. Named for the view it started on.
		_ = if d.key_pressed(KeyV) {
			match program_input.capture {
				Active(_) => Task.spawn!(program_input, || RecCmd(io.capture().stop!()))
				_ => {
					rec_name = Str.concat(view_basename(view), ".webm")
					# max_frames 0 is the platform's "record until Capture.stop"
					# sentinel, not a zero-frame cap - V is the stop
					rec = Capture.default.with_format(WebM).with_path(rec_name).with_fps(30).with_max_frames(0).with_scale(Full).with_timing(FixedStep)
					Task.spawn!(program_input, || RecCmd(io.capture().start!(rec)))
				}
			}
		}
		# on the curve view "range" MEANS the curve window: a directive saying
		# (view 1, range 30), a range chip and 1/2/3 all re-window the ladder
		# and its CP fit, keeping what the user was looking at
		want_days =
			if (view == 1 and directive.has_d and (directive.range == 30 or directive.range == 60 or directive.range == 90)) directive.range
			else if (view == 1 and clicked_chip > 0) (
				match U64.to_i64_try(clicked_chip) {
					Ok(cd9) => cd9
					Err(_) => model.curve_days
				}
			)
			else if (view == 1) (if (d.key_pressed(Key1)) 30 else if (d.key_pressed(Key2)) 60 else if (d.key_pressed(Key3)) 90 else model.curve_days)
			else model.curve_days
		# the power view's curve: a directive's (a refused one changes nothing),
		# or the curve or mode chip clicked on the power view
		clicked_family = if (view == 1 and Mouse.button_pressed(d.mouse, Left) and m0.y >= 64.0 and m0.y <= 86.0) (Curve.chip_at(Curve.chips_for(win.w, model.curve_keys, model.curve_family, model.curve_days), m0.x)) else ""
		want_family =
			if (directive.has_d and directive.family != "" and Bus.family_refusal(directive.family) == "" and curve_on_record(model.curve_keys, directive.family)) directive.family
			else if (clicked_family != "") clicked_family
			else model.curve_family
		# the short chip toggles the folded short rungs; a directive's `short`
		# (1 shows, 0 folds) sets it outright
		clicked_short = view == 1 and Mouse.button_pressed(d.mouse, Left) and m0.y >= 64.0 and m0.y <= 86.0 and Curve.chip_at(Curve.short_chips(win.w, model.curve_keys, model.curve_family, Curve.layout(model).foldable, model.show_short), m0.x) == Curve.short_chip_key
		want_short =
			if (directive.has_d and Bus.short_refusal(directive.short) == "" and directive.short >= 0) directive.short == 1
			else if (clicked_short) !(model.show_short)
			else model.show_short
		# on the trace view, [ and ] walk the picker, X narrows it to one sport.
		# A filter change moves the selection itself, because the session the
		# window is showing may be one the new filter does not admit.
		shifted = d.key_down(KeyLeftShift) or d.key_down(KeyRightShift)
		want_sport = if (view == 2 and !shifted and d.key_pressed(KeyX)) (next_sport(model.trace_ids, model.trace_sport)) else model.trace_sport
		want_sel =
			if (view != 2 or shifted) model.trace_sel
			else if (want_sport != model.trace_sport) (first_admitted(model.trace_ids, want_sport, model.trace_sel))
			else if (d.key_pressed(KeyLeftBracket)) (next_admitted(model.trace_ids, model.trace_sel, want_sport, Bool.True))
			else if (d.key_pressed(KeyRightBracket)) (next_admitted(model.trace_ids, model.trace_sel, want_sport, Bool.False))
			else model.trace_sel
		# shift+[ summons/ages the ghost; shift+] youngs it and clears it when
		# it would pass the newest candidate. -1 is no ghost. next_ghost owns
		# the bounds, so running off either end dismisses rather than sticks;
		# it admits only sessions of the live one's kind, never the live
		# session's own index.
		want_ghost =
			if (view != 2) model.ghost_sel
			# C clears in ONE press from any state - stepping the ghost off the
			# end also clears, but from deep in the menu that is many presses,
			# each one looking like nothing happened
			else if (d.key_pressed(KeyC)) (-1)
			else if (!shifted) model.ghost_sel
			else if d.key_pressed(KeyLeftBracket) {
				start = if (model.ghost_sel < 0) (
					match U64.to_i64_try(model.trace_sel) {
						Ok(ts9) => ts9
						Err(_) => -1
					}
				) else model.ghost_sel
				next_ghost(model.trace_ids, start, model.trace_sel, Bool.True)
			}
			else if (d.key_pressed(KeyRightBracket)) (if (model.ghost_sel >= 0) (next_ghost(model.trace_ids, model.ghost_sel, model.trace_sel, Bool.False)) else -1)
			else model.ghost_sel
		# the cursor a directive's day asks for on the view it lands on
		# (Board.cursor_at): a measured day of the series, or a projected day
		# when that view draws the projection. cursor_dir is its days-back
		# index, or -2 when there is no directive day or the day is refused,
		# both of which leave the cursor alone; cursor_why is the refusal's
		# reason, "" when nothing was refused
		dir_cursor = if (directive.has_d and directive.cursor_day != "") (Board.cursor_at(model, directive.cursor_day, view)) else Err("")
		cursor_dir =
			match dir_cursor {
				Ok(c) => c.back
				Err(_) => -2
			}
		cursor_why =
			match dir_cursor {
				Ok(_) => ""
				Err(why) => why
			}
		# the pre-click cursor: arrows and directives applied, row
		# clicks not yet - the scroll state a click resolves against; the
		# hover resolves against the post-click state it is about to draw
		cursor_pre = if (cursor_dir >= 0) cursor_dir else cursor
		ahead_pre =
			match dir_cursor {
				Ok(c) => c.ahead
				Err(_) => walked.ahead
			}
		row_hit =
			if view == 3 and Mouse.button_pressed(d.mouse, Left) and m.x >= 36.0 and m.x < Table.table_edge(win.w, model.detail_day) and m.y >= Table.rows_top {
				total = List.len(model.data)
				# the page laid out for the pre-click state: rows have their own heights, so the
				# hit is looked up by span rather than divided out of a pitch
				match Table.row_at(Table.page_for(model, cursor_pre), m.y) {
					Row(dayidx) =>
						match U64.to_i64_try(total - 1 - dayidx) {
							Ok(cb) => { hit: Bool.True, cb }
							Err(_) => { hit: Bool.False, cb: -1 }
						}
					None => { hit: Bool.False, cb: -1 }
				}
			} else { hit: Bool.False, cb: -1 }
		# a clicked row opens the day's detail panel (same row again closes
		# it); rows keep their place, and the crosshair follows so tabbing to
		# the board lines up
		clicked_day =
			if row_hit.hit {
				total4 = List.len(model.days)
				match I64.to_u64_try(row_hit.cb) {
					Err(_) => ""
					Ok(cb4) =>
						if (cb4 >= total4) ""
						else match List.get(model.days, total4 - 1 - cb4) {
							Ok(dy) => dy
							Err(_) => ""
						}
				}
			} else ""
		detail_day2 = if (row_hit.hit) (if (clicked_day == model.detail_day) "" else clicked_day) else model.detail_day
		# spawn unconditionally: detail_task! answers "no database path" itself,
		# so a missing directory shows that instead of loading... forever
		_ = if row_hit.hit and detail_day2 != "" {
			accd = { io, dir: model.stride_dir }
			unitsd = model.units
			dayd = detail_day2
			Task.spawn!(program_input, || detail_task!(accd, unitsd, dayd))
		}
		view2 = view
		# a clicked table row parks the crosshair on its day, a measured one;
		# otherwise the cursor stands where the arrows and a directive put it
		cursor2 = if (row_hit.hit) row_hit.cb else cursor_pre
		ahead2 = if (row_hit.hit) 0 else ahead_pre
		# moving the mouse over the form board's plot un-parks the crosshair:
		# the hover takes over while inside, and nothing lingers on the way
		# out. Only a cursor NOT re-parked this same frame (arrow, directive,
		# row click) clears, so a deliberate park always wins over drift. The
		# scale must also be unchanged: last frame's mouse_x/y were computed
		# at the PREVIOUS scale, so on a Ctrl +/- frame the same physical
		# pointer yields different logical coordinates and a still mouse
		# would read as drift, the hazard the trace drag guards below too.
		cursor3 =
			if view2 == 0 and layout.scale == model.ui_scale and cursor2 == model.cursor and ahead2 == model.cursor_ahead and cursor2 >= 0 and (m.x != model.mouse_x or m.y != model.mouse_y) and m.y > Theme.pad_t + Board.band_h and m.y < win.h - Theme.pad_b and m.x >= Theme.pad_l and m.x <= win.w - Theme.pad_r {
				-1
			} else cursor2
		# a view that draws no projection holds the latest measured day in
		# place of a projected one (Board.held)
		ahead3 = (Board.held({ back: cursor3, ahead: ahead2 }, view2)).ahead
		# TAB on the power view with a rung hovered opens the session that set
		# that rung's window best (TAB already moves the power view to the trace),
		# and the map's card opens the session whose route was clicked.
		# A directive's session wins over both: an id names one session exactly
		# and wins over a day, and a day names whichever session of that day
		# sorts first, which is the newest. Reloads and trace switches SPAWN -
		# Cmd panics in update!, and the task lane is where Sqlite and text
		# preparation park legally
		tab_source = if (model.view == 1 and d.key_pressed(KeyTab)) (Curve.hovered_source(model)) else -1
		want_sel2 =
			if (directive.has_d and directive.trace_id >= 0) (sel_for_id(model.trace_ids, directive.trace_id, want_sel))
			else if (directive.has_d and directive.trace_day != "") (sel_for_day(model.trace_ids, directive.trace_day, want_sel))
			else if (map_open >= 0) (sel_for_id(model.trace_ids, map_open, want_sel))
			else if (tab_source >= 0) (sel_for_id(model.trace_ids, tab_source, want_sel))
			else want_sel
		# a switch is the selection moving, or a refetch the picker re-read
		# asked for: the shown session is gone and the index it fell to
		# names a session whose samples are not on screen. NoSwitch joins
		# List.get's OutOfBounds in one inferred error union
		moving = want_sel2 != model.trace_sel or model.trace_refetch
		switched = if (moving) (List.get(model.trace_cache, want_sel2)) else Err(NoSwitch)
		# a switch that misses the cache fetches off the main loop and blanks the
		# plot until it lands; a switch that HITS answers from memory this frame,
		# so only the miss is a load in flight
		trace_fetch = moving and (
			match switched {
				Ok(_) => Bool.False
				Err(_) => Bool.True
			}
		)
		# every switch opens a new generation, fetch or not: a hit also retires
		# whatever fetch the previous selection still had in flight
		trace_gen2 = if (moving) (model.trace_gen + 1) else model.trace_gen
		_ = if trace_fetch {
			acc2 = { io, dir: model.stride_dir }
			units2 = model.units
			ids2 = model.trace_ids
			Task.spawn!(program_input, || trace_task!(acc2, units2, ids2, want_sel2, trace_gen2))
		}
		# the trace camera: wheel zooms anchored at the cursor's moment, a held
		# left drag pans, 0 resets - and a session switch resets (the window
		# belonged to the old ride)
		wheel = Mouse.wheel_delta(d.mouse)
		zoom_raw =
			if (view != 2) model.trace_zoom
			else if (d.key_pressed(Key0) and !ctrl) 1.0
			else if (wheel.y > 0.1) (model.trace_zoom * 1.15)
			else if (wheel.y < -0.1) (model.trace_zoom / 1.15)
			else model.trace_zoom
		trace_zoom2 = if (moving) (1.0) else F32.min(20.0, F32.max(1.0, zoom_raw))
		pan_raw =
			if (view != 2) model.trace_pan
			else if ((d.key_pressed(Key0) and !ctrl) or moving) 0.0
			else {
				pw9 = win.w - Theme.pad_l - Trace.right_pad(model)
				u9 = F32.min(1.0, F32.max(0.0, (m.x - Theme.pad_l) / pw9))
				if trace_zoom2 != model.trace_zoom {
					# hold the moment under the cursor still through the zoom
					t9 = model.trace_pan + u9 / model.trace_zoom
					t9 - u9 / trace_zoom2
				} else if layout.scale == model.ui_scale and Mouse.button_down(d.mouse, Left) and m.y > Theme.pad_t and m.y < win.h - Theme.pad_b {
					model.trace_pan - (m.x - model.mouse_x) / pw9 / trace_zoom2
				} else model.trace_pan
			}
		trace_pan2 = F32.min(1.0 - 1.0 / trace_zoom2, F32.max(0.0, pan_raw))
		# a directive naming a ghost of another kind is refused rather than
		# honoured: ghost_matches is the same test the keyboard path applies
		want_ghost_raw =
			if (directive.has_d and directive.ghost_day == "none") (-1)
			else if (directive.has_d and directive.ghost_id >= 0) (ghost_for_id(model.trace_ids, entry_at(model.trace_ids, want_sel2), directive.ghost_id, want_ghost))
			else if (directive.has_d and directive.ghost_day != "") (ghost_for_day(model.trace_ids, entry_at(model.trace_ids, want_sel2), directive.ghost_day, want_ghost))
			else want_ghost
		# whatever chose the ghost, the PAIR is re-judged against this frame's
		# selection: a ghost summoned beside one session must not outlive a
		# switch to a session of another kind
		want_ghost2 = ghost_for_sel(model.trace_ids, want_sel2, want_ghost_raw)
		# the filter is re-judged against the same frame-true selection: a
		# directive can land a session the filter excludes, and the reset
		# keeps the header honest instead of claiming a sport the trace is not
		want_sport2 = sport_for_sel(model.trace_ids, want_sel2, want_sport)
		ghost_hit =
			if want_ghost2 != model.ghost_sel and want_ghost2 >= 0 {
				match I64.to_u64_try(want_ghost2) {
					Ok(gu9) => List.get(model.trace_cache, gu9)
					Err(_) => Err(OutOfBounds)
				}
			} else Err(NoSwitch)
		# any ghost change - a new pick, a cache hit, or a dismissal - opens a
		# new generation, so a load still in flight for the old pick lands nowhere
		ghost_gen2 = if (want_ghost2 != model.ghost_sel) (model.ghost_gen + 1) else model.ghost_gen
		ghost_fetch = want_ghost2 != model.ghost_sel and want_ghost2 >= 0 and (
			match ghost_hit {
				Ok(_) => Bool.False
				Err(_) => Bool.True
			}
		)
		_ = if ghost_fetch {
			acc3 = { io, dir: model.stride_dir }
			ids3 = model.trace_ids
			Task.spawn!(program_input, || ghost_task!(acc3, ids3, want_ghost2, ghost_gen2))
		}
		# the flag a capture waits on: raised with the fetch, lowered by its
		# answer, and dropped by a change that needs no fetch (a hit, a dismissal)
		ghost_loading2 = if (ghost_fetch) Bool.True else if (want_ghost2 != model.ghost_sel) Bool.False else model.ghost_loading
		# any ghost change clears the overlay this frame: a failed load leaves
		# no ghost rather than the previous one
		ghost2 = match ghost_hit {
			Ok(gc) => gc.tr
			Err(_) => if (want_ghost2 != model.ghost_sel) ([]) else model.ghost
		}
		ghost_day2 = match ghost_hit {
			Ok(_) => match I64.to_u64_try(want_ghost2) {
				Ok(gu8) => (
					match List.get(model.trace_ids, gu8) {
						Ok(ge) => ge.day
						Err(_) => ""
					}
				)
				Err(_) => ""
			}
			Err(_) => if (want_ghost2 != model.ghost_sel) ("") else model.ghost_day
		}
		ghost_dur2 = match ghost_hit {
			Ok(gc) => gc.du
			Err(_) => model.ghost_dur
		}
		# a cache hit lands its data this frame; a miss clears rather than
		# drawing the previous ride under the new day
		switching = moving
		trace2 = match switched {
			Ok(sc) => sc.tr
			Err(_) => if (switching) ([]) else model.trace
		}
		segs2m = match switched {
			Ok(sc) => sc.sg
			Err(_) => if (switching) ([]) else model.segs
		}
		trace_splits2 = match switched {
			Ok(sc) => sc.sp
			Err(_) => if (switching) ([]) else model.trace_splits
		}
		trace_sets2 = match switched {
			Ok(sc) => sc.st
			Err(_) => if (switching) ({ rows: [], pasted: Bool.False }) else model.trace_sets
		}
		trace_dur2 = match switched {
			Ok(sc) => sc.du
			Err(_) => if (switching) (1.0) else model.trace_dur
		}
		trace_day2 =
			if switching {
				match List.get(model.trace_ids, want_sel2) {
					Ok(se) => se.day
					Err(_) => model.trace_day
				}
			} else model.trace_day
		# the unit is re-derived from the picker row's CHANNEL, not read from
		# the cache entry, so it is right on a cache miss too - the axis must
		# never label a heart-rate trace in watts while the samples load
		trace_unit2 =
			if switching {
				match List.get(model.trace_ids, want_sel2) {
					Ok(se) => Db.trace_unit(se.chan, model.units, se.sport)
					Err(_) => model.trace_unit
				}
			} else model.trace_unit
		reload_spawned = want_days != model.curve_days or want_family != model.curve_family or d.key_pressed(KeyR)
		# R is the full reload: every table, for an athlete who just synced. A
		# chip is a curve change, and takes load_curve_window!'s path.
		_ = if d.key_pressed(KeyR) {
			f2 = model.font
			acc2r = { io, dir: model.stride_dir }
			cwd2 = model.cwd
			Task.spawn!(
				program_input,
				|| match load_model!(acc2r, cwd2, f2, want_days, want_family, Bool.False) {
					Ok(m2) => Reloaded(m2)
					Err(_) => ReloadFailed
				},
			)
		} else if want_days != model.curve_days or want_family != model.curve_family {
			f3 = model.font
			acc3r = { io, dir: model.stride_dir }
			Task.spawn!(
				program_input,
				|| match load_curve_window!(acc3r, f3, want_days, want_family) {
					Ok(w) => CurveReloaded(w)
					Err(_) => CurveReloadFailed(want_days, want_family)
				},
			)
		}
		chip0h = win.w - 420.0
		# per-chip, not one wide band: the 8px gaps between chips are not
		# clickable and must not claim the pointer
		over_chip = m.y >= 64.0 and m.y <= 86.0 and (((view2 == 0 or view2 == 1) and ((m.x >= chip0h and m.x <= chip0h + 46.0) or (m.x >= chip0h + 54.0 and m.x <= chip0h + 100.0) or (m.x >= chip0h + 108.0 and m.x <= chip0h + 154.0) or (view2 == 1 and Curve.chip_at(List.concat(Curve.chips_for(win.w, model.curve_keys, model.curve_family, model.curve_days), Curve.short_chips(win.w, model.curve_keys, model.curve_family, Curve.layout(model).foldable, model.show_short)), m.x) != ""))) or (view2 == 8 and Career.kind_chip_at(Career.kind_chips(model), m.x).is_ok()) or (Days.is_day(view2) and Days.mode_at(m.x, m.y) >= 0) or (Weeks.is_week(view2) and Weeks.mode_at(m.x, m.y) >= 0) or (Map.is_map(view2) and Map.mode_at(m.x, m.y) >= 0))
		over_row = view2 == 3 and m.x >= 36.0 and m.x < Table.table_edge(win.w, detail_day2) and (
			match Table.row_at(Table.page_for(model, cursor2), m.y) {
				Row(_) => Bool.True
				None => Bool.False
			}
		)
		over_nav = m.y >= 30.0 and m.y <= 54.0 and (
			List.fold(
				List.map_with_index(model.nav, |nv3, vi3| { nv3, vi3 }),
				Bool.False,
				|acc, x| {
					nx3 = Chrome.nav_x(win.w, List.len(model.nav), x.vi3)
					if (m.x >= nx3 and m.x <= nx3 + Chrome.nav_width) Bool.True else acc
				},
			)
		)
		Mouse.set_cursor!(if (over_chip or over_row or over_nav) PointingHand else Default)
		# a click on a kind chip shows that kind's arc of the same family, and
		# F cycles the career view's arc; both act on the career view only
		clicked_kind = if (view == 8 and Mouse.button_pressed(d.mouse, Left) and m.y >= Career.kind_chip_top and m.y <= Career.kind_chip_bottom) (Career.kind_chip_at(Career.kind_chips(model), m.x)) else Err(None)
		spine_idx =
			match clicked_kind {
				Ok(i) => i
				Err(_) => if (view == 8 and d.key_pressed(KeyF)) (model.spine_idx + 1) else model.spine_idx
			}
		# a view switch stamps this tick, and render fades the new view in
		# from it; a click on the career view settles its sweep at once, since
		# zero means "no animation" to every consumer of view_anim
		view_anim = if (view != model.view) (tick) else if (view == 8 and Mouse.button_pressed(d.mouse, Left)) (0) else model.view_anim
		# the first cycle of a boot: the window is already on screen showing
		# the splash, so the real load starts here, once, as the task R runs
		_ = if model.booting and program_input.time.cycle_count == 0 {
			f0 = model.font
			acc0r = { io, dir: model.stride_dir }
			cwd0 = model.cwd
			Task.spawn!(
				program_input,
				|| match load_model!(acc0r, cwd0, f0, 90, boot_curve_family, Bool.False) {
					Ok(m2) => Reloaded(m2)
					Err(_) => ReloadFailed
				},
			)
		}
		# focus mirrors the screen: view, range, the crosshair day (a
		# projected one when the cursor has walked on into them), the session
		cur_day =
			if (cursor3 < 0) ""
			else if (ahead3 > 0) Board.ahead_day(model, ahead3)
			else {
				total3 = List.len(model.days)
				match I64.to_u64_try(cursor3) {
					Err(_) => ""
					Ok(cb3) =>
						if (cb3 >= total3) ""
						else match List.get(model.days, total3 - 1 - cb3) {
							Ok(dy) => dy
							Err(_) => ""
						}
				}
			}
		focus_now = {
			view: focus_view_code(view2),
			# the curve view's window IS its range; the other views report the
			# form board's
			range: if (view2 == 1) want_days
			else match U64.to_i64_try(range) {
				Ok(ri) => ri
				Err(_) => 90
			},
			cursor_day: cur_day,
			# both frame-true: a cached switch or summon lands this frame, and
			# the coach's readout must not trail it by one write
			trace_day: trace_day2,
			ghost_day: ghost_day2,
			# the ids answer "which session" where a day cannot, on a day that
			# carries two; -1 (no session) writes as NULL
			trace_id: id_at(model.trace_ids, want_sel2),
			ghost_id: (
				match I64.to_u64_try(want_ghost2) {
					Ok(gu5) => id_at(model.trace_ids, gu5)
					Err(_) => -1
				}
			),
			# beyond the session: the table's open panel day (drawn on the table
			# view only, so named there only), the trace's sport
			# filter and the career view's family, each '' (NULL) when none
			detail_day: (if (view2 == 3) detail_day2 else ""),
			sport: want_sport2,
			family: Career.spine_at(model.career_spines, spine_idx).fam,
			curve_family: want_family,
			curve_short: Curve.focus_short(Curve.layout(model).foldable, want_short),
			# the session the map's card is up for, named while a map mode shows it
			map_id: Map.map_focus({ ..model, view: view2, map_card: map_card2 }),
		}
		# written when what the human sees changed, at most twice a second,
		# and on a heartbeat regardless: updated_at is the coach's liveness
		# signal, and a window idle on one view for an hour is still a window
		last_focus =
			if model.stride_dir != "" and ((focus_now != model.last_focus and crossed(model.tick, tick, ticks_per_second / 2)) or crossed(model.tick, tick, focus_beat_ticks)) {
				accf = { io, dir: model.stride_dir }
				_ = Task.spawn!(program_input, || focus_task!(accf, focus_now))
				focus_now
			} else model.last_focus
		# the directive's outcome, reported by THIS frame - the one that
		# applied it. Every refusable field is named on refusal; a fully
		# honoured directive closes with none. "applied" means the frame
		# accepted and acted; async completions it started (a reload, a
		# cache-miss fetch) may still fail and recover by their own rules.
		rec_active = match program_input.capture {
			Active(_) => Bool.True
			_ => Bool.False
		}
		cap_pending = capture_is_pending(pending1)
		refused9 = if (directive.has_d and directive.id >= 0) (join_refusal(refusals_for(directive, cursor_why, want_sel2, model.trace_sel, model.trace_ids, rec_active, cap_pending), curve_refusal(model.curve_keys, directive.family))) else ""
		# a capture the refusals let through waits on the host for its mark;
		# the test is the predicate that produced the refusal, so refusal text
		# elsewhere in the row cannot suppress it. The file is named for the
		# view the directive lands on; the start is called from this frame,
		# so the frame after it reads the host's answer
		cap_ok = directive.has_d and directive.id >= 0 and directive.capture != "" and capture_refusal_for(directive.capture, rec_active, cap_pending) == ""
		cap_name = view_basename(view2)
		_ = if cap_ok and directive.capture == "webm_start" {
			rec9 = Capture.default.with_format(WebM).with_path(Str.concat(cap_name, ".webm")).with_fps(30).with_max_frames(0).with_scale(Full).with_timing(FixedStep)
			_ = io.capture().start!(rec9)
			{}
		}
		_ = if (cap_ok and directive.capture == "webm_stop") (Task.spawn!(program_input, || RecCmd(io.capture().stop!())))
		v_starts = d.key_pressed(KeyV) and !rec_active
		rec_path2 =
			if (cap_ok and directive.capture == "webm_start") (capture_path(model.cwd, Str.concat(cap_name, ".webm")))
			else if (v_starts) (capture_path(model.cwd, Str.concat(view_basename(view), ".webm")))
			else model.rec_path
		wait9 = |name9, path9| { id: directive.id, refused: refused9, path: path9, name: name9, since: tick }
		pending2 =
			if (cap_ok and directive.capture == "png") (ArmedShot(wait9(Str.concat(cap_name, ".png"), capture_path(model.cwd, Str.concat(cap_name, ".png")))))
			else if (cap_ok and directive.capture == "webm_start") (AwaitingStart(wait9(Str.concat(cap_name, ".webm"), rec_path2)))
			else if (cap_ok and directive.capture == "webm_stop") (AwaitingStop(wait9("", model.rec_path)))
			else pending1
		# the bus poll, once a second (polls_bus says when)
		_ = if polls_bus({ second: crossed(model.tick, tick, ticks_per_second), has_dir: model.stride_dir != "", capture_pending: capture_is_pending(pending2), booting: model.booting }) {
			accp = { io, dir: model.stride_dir }
			lastp = model.last_directive.id
			Task.spawn!(program_input, || poll_task!(accp, lastp))
		}
		# every other directive is marked by this frame, the one that applied it
		_ = if directive.has_d and directive.id >= 0 and model.stride_dir != "" and !cap_ok {
			accm = { io, dir: model.stride_dir }
			did = directive.id
			refm = refused9
			Task.spawn!(program_input, || MarkDone(mark_task!(accm, did, refm, "")))
		}
		# the map camera: the wheel zooms at the cursor, a left press that
		# began on the map carries the map with it while held (Map.press_step),
		# and 0 returns to the opening view. A UI resize moves every logical
		# point, so a drag spanning one is not carried.
		map_r = Map.rect(win)
		map_cam0 = Map.cam({ ..model, win })
		on_map = m.x >= map_r.x and m.x <= map_r.x + map_r.w and m.y >= map_r.y and m.y <= map_r.y + map_r.h
		map_drag2 = if (Map.is_map(view2)) map_step.press else Idle
		map_dragged = match (model.map_drag, map_drag2) {
			(Held(a), Held(b)) => if (layout.scale == model.ui_scale) Ok({ dx: b.x - a.x, dy: b.y - a.y }) else Err(NotCarried)
			_ => Err(NotCarried)
		}
		map_did_drag = match map_dragged {
			Ok(_) => Bool.True
			Err(_) => Bool.False
		}
		map_zoom = if (Map.is_map(view2) and on_map and wheel.y > 0.1) 1.25 else if (Map.is_map(view2) and on_map and wheel.y < -0.1) 0.8 else 1.0
		map_fit = Map.is_map(view2) and d.key_pressed(Key0) and !ctrl
		map_cam1 = match map_dragged {
			Ok(dd) => Geo.pan(map_cam0, dd.dx, dd.dy)
			Err(_) => map_cam0
		}
		map_cam2 = if (map_zoom != 1.0) Geo.zoom_at(map_cam1, map_r, map_zoom, m.x, m.y) else map_cam1
		map_moved2 = if (map_fit) Bool.False else model.map_moved or map_did_drag or map_zoom != 1.0
		map_shown = Map.cam({ ..model, win, map_moved: map_moved2, map_cam: map_cam2 })
		# the picture is allocated the first time the map shows and follows
		# the framebuffer's pixels, the window's size times the display's
		# scale (Map.paint_picture!); it is repainted whenever what it holds
		# is not what the view shows, except mid-drag, where the old picture
		# slides with the cursor and the release repaints it
		dpi = Window.scale!()
		picture_px = { w: pixels.w * dpi.x, h: pixels.h * dpi.y }
		map_rt2 =
			if !(Map.is_map(view2)) {
				model.map_rt
			} else {
				match model.map_rt {
					Target(t) => if (t.w == picture_px.w and t.h == picture_px.h) model.map_rt else picture_rt!(picture_px, t.text)
					Refused(r) => if (r.w == picture_px.w and r.h == picture_px.h) model.map_rt else picture_rt!(picture_px, NoText)
					NoTarget => picture_rt!(picture_px, NoText)
				}
			}
		map_fresh = match (model.map_rt, map_rt2) {
			(Target(a), Target(b)) => a.w != b.w or a.h != b.h
			(_, Target(_)) => Bool.True
			_ => Bool.False
		}
		map_zoomed = (map_shown.mpp - model.map_painted.mpp).abs() > map_shown.mpp * 0.00001
		map_resized = layout.scale != model.ui_scale or win.w != model.win.w or win.h != model.win.h
		map_idle = match map_drag2 {
			Idle => Bool.True
			Held(_) => Bool.False
		}
		# the map loads in a task once the boot load has landed, and again
		# after R; the newest load is the one that lands
		map_spawn = !(model.booting) and (
			match model.map_load {
				Unloaded => Bool.True
				_ => Bool.False
			}
		)
		map_gen2 = if (map_spawn) model.map_gen + 1 else model.map_gen
		_ = if map_spawn {
			accm2 = { io, dir: model.stride_dir }
			Task.spawn!(program_input, || map_task!(accm2, map_gen2))
		}
		# the street map's tiles: while a map mode shows a landed map with
		# something on it, a frame plan_now picks plans the tiles the camera
		# wants (Tiles.plan), starts a task for each one it picks, and reads
		# the TileJSON first when a tile needs the network and no template is
		# known
		tiles_on = Map.is_map(view2) and !(map_unread(model.map_load)) and Map.has_data(model)
		planning = tiles_on and plan_now({ due: model.map_plan_due, was_map: Map.is_map(model.view), resized: map_resized, cam: map_shown, planned: model.map_planned, tick })
		tile_plan =
			if planning {
				want = List.map(Tiles.wanted(Map.cells({ ..model, win }, map_shown)), |c| c.key)
				Tiles.plan(model.map_tiles, want, model.map_source, tick, tile_retry_ticks)
			} else {
				{ slots: model.map_tiles, start: [], ask: Bool.False }
			}
		template = match model.map_source {
			Known(t) => t
			_ => ""
		}
		List.for_each!(
			tile_plan.start,
			|k| {
				acct = { io, dir: model.stride_dir }
				Task.spawn!(program_input, || tile_task!(acct, k, template))
			},
		)
		map_source2 =
			if tile_plan.ask {
				accs2 = { io, dir: model.stride_dir }
				Task.spawn!(program_input, || source_task!(accs2))
				Asking
			} else {
				model.map_source
			}
		# heat's texture and shader are built the first time heat shows and
		# follow the window's pixels; a refusal is kept at its size
		map_heat2 =
			if view2 != 11 {
				model.map_heat
			} else {
				match model.map_heat {
					Ready(h) => if (h.w == pixels.w and h.h == pixels.h) model.map_heat else build_map_heat!(pixels)
					Unavailable(u) => if (u.w == pixels.w and u.h == pixels.h) model.map_heat else build_map_heat!(pixels)
					Unbuilt => build_map_heat!(pixels)
				}
			}
		map_heat_fresh = match (model.map_heat, map_heat2) {
			(Ready(a), Ready(b)) => a.w != b.w or a.h != b.h
			(_, Ready(_)) => Bool.True
			_ => Bool.False
		}
		# playback's speed bands are worked out in the frame that first shows
		# it a landed map (speed_due), and that frame repaints the picture
		speed_now = speed_due(view2, model.map_load, model.map_speed)
		map2 = if (speed_now) Db.with_bands(model.map) else model.map
		map_speed2 = if (speed_now) Built({ tick, longest: Map.longest_of(map2) }) else model.map_speed
		# playback's clock steps only while the play mode shows, and holds
		# until the map has landed with its bands (Motion.step_clock, speed_ready)
		map_play2 =
			if view2 != 12 {
				model.map_play
			} else {
				Motion.step_clock(model.map_play, { opening: model.view != 12, landed: !(map_unread(model.map_load)) and speed_ready(model.map_speed, model.tick), toggle: d.key_pressed(KeyP), dt: U64.to_f32(tick - model.tick) / U64.to_f32(ticks_per_second) })
			}
		# paused playback places its markers once and keeps them
		# (Motion.step_marks); running, each frame places its own
		map_marks2 = Motion.step_marks(model.map_marks, { view: view2, paused: map_play2.paused, was_view: model.view, was_paused: model.map_play.paused, rebuilt: speed_now }, |_| Map.markers({ ..model, map: map2, map_speed: map_speed2, map_play: map_play2 }))
		map_paint2 = Map.is_map(view2) and (speed_now or map_fresh or map_heat_fresh or view2 != model.map_painted_view or map_zoomed or map_resized or (map_idle and !(same_cam(map_shown, model.map_painted))) or Map.card_key({ ..model, win, map_card: model0.map_card }, Scene.measure_of(model)) != Map.card_key({ ..model, win, map_card: map_card2 }, Scene.measure_of(model)))
		glow2 =
			match model.glow {
				Ready(g9) => if (g9.gw == pixels.w and g9.gh == pixels.h) (model.glow) else build_glow!(pixels)
				Unbuilt => build_glow!(pixels)
				# a refusal is sticky at the size it happened; a resize retries
				Unavailable(u9) => if (u9.gw == pixels.w and u9.gh == pixels.h) (model.glow) else build_glow!(pixels)
			}
		glow_on2 = if (d.key_pressed(KeyG)) (!model.glow_on) else model.glow_on
		# full rate while anything on screen still moves: the splash, a
		# loading note, a view's arrival, a capture, a recording, playback
		# running, or a street-map tile on its way
		busy = (view2 == 12 and !(map_play2.paused)) or Tiles.running(tile_plan.slots) > 0 or model.booting or reload_spawned or model.reloading or trace_fetch or model.trace_loading or ghost_loading2 or rec_active or capture_is_pending(pending2) or (view_anim > 0 and tick - view_anim < view_anim_ticks)
		# the athlete at work: any key, click, wheel notch or pointer move,
		# a resize, or a directive from the coach
		pointer = d.mouse.delta()
		used = !List.is_empty(d.events) or List.any(d.keys, |k| k != 0) or pointer.x != 0.0 or pointer.y != 0.0 or wheel.x != 0.0 or wheel.y != 0.0 or Mouse.button_down(d.mouse, Left) or Mouse.button_down(d.mouse, Right) or win.w != model.win.w or win.h != model.win.h or directive.has_d
		last_active = if (used) tick else model.last_active
		Window.set_target_fps!(frame_rate({ busy, tick, last_active }))
		Ok({ ..model, map: map2, map_speed: map_speed2, map_marks: map_marks2, map_tiles: tile_plan.slots, map_source: map_source2, map_planned: (if (planning) { cam: map_shown, tick } else model.map_planned), map_plan_due: model.map_plan_due and !planning, map_heat: map_heat2, map_play: map_play2, map_painted_view: (if (map_paint2) view2 else model.map_painted_view), map_load: (if (map_spawn) Loading else model.map_load), map_gen: map_gen2, map_cam: map_cam2, map_moved: map_moved2, map_drag: map_drag2, map_card: map_card2, map_rt: map_rt2, map_paint: map_paint2, map_painted: (if (map_paint2) map_shown else model.map_painted), lifts_off: lifts_off2, last_off: last_off2, week_off: week_off2, week_cursor: week_cursor2, last_active, reloading: (if (reload_spawned) Bool.True else model.reloading), range, view: view2, cursor: cursor3, cursor_ahead: ahead3, rec_status: program_input.capture, pending_capture: pending2, rec_path: rec_path2, glow: glow2, glow_on: glow_on2, last_directive: (if (directive.has_d and directive.id >= 0) ({ id: directive.id, refused: refused9, result: "" }) else last_directive1), trace_zoom: trace_zoom2, trace_pan: trace_pan2, curve_days: want_days, curve_family: want_family, show_short: want_short, trace_sel: want_sel2, trace_refetch: Bool.False, trace_gen: trace_gen2, trace_loading: (if (trace_fetch) Bool.True else if (moving) Bool.False else model.trace_loading), ghost_sel: want_ghost2, ghost_gen: ghost_gen2, ghost_loading: ghost_loading2, ghost: ghost2, ghost_day: ghost_day2, ghost_dur: ghost_dur2, trace: trace2, segs: segs2m, trace_dur: trace_dur2, trace_day: trace_day2, trace_unit: trace_unit2, trace_splits: trace_splits2, trace_sets: trace_sets2, trace_sport: want_sport2, tick, view_anim, spine_idx, last_focus, win, ui_percent, ui_scale: layout.scale, detail_day: detail_day2, detail: (if (detail_day2 != model.detail_day) [] else model.detail), mouse_x: m.x, mouse_y: m.y, mouse_in: m.y > (if (view2 == 0) (Theme.pad_t + Board.band_h) else if (view2 == 1) Curve.plot_top else Theme.pad_t) and m.y < win.h - Theme.pad_b })
	}
}

# 12x12 vector marks, one per view: iconography drawn from primitives -
# no sprite sheet to ship, crisp at any DPI, colored with its label. Each
# arm tests for its own view number and the chain has no catch-all: the
# caller paints and labels every pill, so a view with no arm shows a
# labelled pill with an empty mark slot.
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
	} else if v == 7 {
		# ramp: the climb and its rider
		frame.line!({ start: { x: x, y: y + 11.0 }, end: { x: x + 12.0, y: y + 2.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.circle!({ center: { x: x + 9.0, y: y + 4.0 }, radius: 2.0, style: Draw.filled(c) })
	} else if v == 8 {
		# career: a flag on its pole, the only mark that pairs one off-centre
		# block with a stem
		frame.line!({ start: { x: x + 2.5, y: y + 12.0 }, end: { x: x + 2.5, y: y + 1.0 }, stroke: Draw.stroke(c, 1.5) })
		frame.rectangle!({ x: x + 3.5, y: y + 1.5, width: 6.5, height: 5.0, style: Draw.filled(c) })
	} else if v == 9 {
		# strength: a dumbbell, two plates on a bar
		frame.line!({ start: { x: x + 2.0, y: y + 6.5 }, end: { x: x + 10.0, y: y + 6.5 }, stroke: Draw.stroke(c, 1.5) })
		frame.rectangle!({ x: x, y: y + 3.0, width: 3.0, height: 7.0, style: Draw.filled(c) })
		frame.rectangle!({ x: x + 9.0, y: y + 3.0, width: 3.0, height: 7.0, style: Draw.filled(c) })
	} else if v == 10 {
		# map: a route wandering to its pin, the only mark that ends on a dot
		frame.line_strip!({ points: [{ x: x, y: y + 11.0 }, { x: x + 4.0, y: y + 6.0 }, { x: x + 7.0, y: y + 9.0 }, { x: x + 10.0, y: y + 4.0 }], stroke: Draw.stroke(c, 1.5) })
		frame.circle!({ center: { x: x + 10.0, y: y + 3.0 }, radius: 2.2, style: Draw.filled(c) })
	}
}

scene! : Model, Draw.Frame => Try({}, [Exit(I64)])
scene! = |model, frame| {
	frame.rectangle!({ x: 0.0, y: 0.0, width: model.win.w, height: model.win.h, style: Draw.filled(Theme.bg) })
	frame.rounded_rectangle!({ x: 16.0, y: 16.0, width: model.win.w - 32.0, height: model.win.h - 32.0, radius: 14.0, segments: 10, style: Draw.filled(Theme.panel) })
	# depth without shaders: a whisper of vertical gradient over the panel,
	# then bottom-edge falloff - two gradient strips standing in for a vignette
	frame.rectangle_gradient_v!({ x: 16.0, y: 16.0, width: model.win.w - 32.0, height: (model.win.h - 32.0) * 0.4, color_top: Color.with_alpha(Color.from_hex_rgb(0x232332), 40), color_bottom: Color.with_alpha(Theme.panel, 0) })
	frame.rectangle_gradient_v!({ x: 16.0, y: model.win.h - 96.0, width: model.win.w - 32.0, height: 80.0, color_top: Color.with_alpha(Theme.bg, 0), color_bottom: Color.with_alpha(Theme.bg, 90) })
	# the recording badge lives below the pills on every view: a red dot
	# while filming, a quiet confirmation once the file is written
	_ = match Chrome.rec_text(model) {
		Ok(r) => if r.dot {
			frame.circle!({ center: { x: model.win.w - 148.0, y: 64.0 }, radius: 4.0, style: Draw.filled(Theme.alarm_c) })
		}
		Err(_) => {}
	}
	# the nav: one pill per tab, each visible and clickable, the active
	# tab's pill filled; TAB walks the same pills from the keyboard
	List.for_each!(
		List.map_with_index(model.nav, |nv, ni| { nv, ni }),
		|x| {
			pill = Chrome.nav_pill(model.win.w, List.len(model.nav), x.ni)
			on2 = x.nv.v == Map.group(Weeks.group(Days.group(model.view)))
			hov2 = model.mouse_x >= pill.x and model.mouse_x <= pill.x + pill.w and model.mouse_y >= pill.y and model.mouse_y <= pill.y + pill.h
			style2 = if (on2) (Draw.filled(Color.with_alpha(Theme.ctl_c, 60))) else if (hov2) (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
			frame.rounded_rectangle!({ x: pill.x, y: pill.y, width: pill.w, height: pill.h, radius: 7.0, segments: 6, style: style2 })
			nav_icon!(frame, x.nv.v, pill.x + 7.0, 36.0, if (on2) Color.white else Theme.ink_muted)
		},
	)
	# the legend belongs to the form board only: it sits on the row the
	# other views put their titles in. A 14x3 rounded swatch before each name.
	if model.view == 0 {
		List.for_each!(Chrome.legend, |sw| frame.rounded_rectangle!({ x: sw.x, y: 77.0, width: 14.0, height: 3.0, radius: 1.5, segments: 4, style: Draw.filled(sw.c) }))
	}
	# the chrome's text, over the shapes above, from the same definitions
	# every view registers as fixed text
	Scene.draw!(frame, model, Chrome.placed(model, Scene.measure_of(model)))
	# a tab's mode chips, under the view, which writes their labels
	if Days.is_day(model.view) {
		Days.draw_chips!(model, frame)
	}
	if Weeks.is_week(model.view) {
		Weeks.draw_chips!(model, frame)
	}
	drawn =
		if Map.is_map(model.view) {
			Map.draw!(model, frame)
		} else if model.view == 9 {
			Strength.draw!(model, frame)
		} else if model.view == 8 {
			Career.draw!(model, frame)
		} else if model.view == 7 {
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
	# the XP rail rides the panel's left edge on every view - under the
	# crossfade veil, so it arrives with the view rather than over it
	Hud.rail!(model, frame)
	# the crossfade: for ten ticks after a switch, a panel-colored veil
	# fades off the incoming view - ease-out, cheap, and one rectangle
	age = model.tick - model.view_anim
	if model.view_anim > 0 and age < 10 {
		fade = 10 - age
		a = match U64.to_u8_try(fade * fade * 2) {
			Ok(v) => v
			Err(_) => 0
		}
		frame.rectangle!({ x: 16.0, y: 16.0, width: model.win.w - 32.0, height: model.win.h - 32.0, style: Draw.filled(Color.with_alpha(Theme.panel, a)) })
	}
	drawn
}

# The boot splash, shown while the real load runs in its task and until
# Reloaded lands: the authored mark, img/stride-icon.png, above the words
# Chrome.splash places. The mark fades in over the first moments and
# breathes gently while the load works; the glow shader has nothing to add
# here. Without the PNG the splash is the words alone on the same ground:
# nothing is drawn in the mark's place.
splash! : Ui.Model, Draw.Frame => Try({}, [Exit(I64)])
splash! = |model, frame| {
	# The splash clears to RGB(1, 2, 9), the ground of img/stride-icon.png's
	# interior away from the mark, so the logo sits on a field of its own
	# color rather than in a slightly different black; the clear is the only
	# ground, with no backdrop drawn over it. The asset is RGB with no alpha
	# and has a lighter padding outside its rounded corners, which a single
	# clear cannot match, so faint corner wedges show. Nothing at runtime can
	# read a texture's pixels back, so this value is measured by hand and
	# must be measured again when the asset changes. The app views clear to
	# Theme.bg.
	frame.rectangle!({ x: 0.0, y: 0.0, width: model.win.w, height: model.win.h, style: Draw.filled(Color.rgb(1, 2, 9)) })
	_ = match model.logo {
		Logo(lt) => {
			cx = model.win.w / 2.0
			cy = model.win.h / 2.0 - 30.0
			tf = U64.to_f32(model.tick)
			ar = if (tf > 42.0) (255.0) else tf * 6.0
			a8 = match F32.to_u8_try(ar) {
				Ok(av) => av
				Err(_) => 255.U8
			}
			sc = 1.0 + 0.015 * F32.sin(tf / 25.0)
			side = 264.0 * sc
			frame.texture!({ texture: lt, source: { x: 0.0, y: 0.0, width: lt.width, height: lt.height }, dest: { x: cx - side / 2.0, y: (cy - 16.0) - side / 2.0, width: side, height: side }, origin: { x: 0.0, y: 0.0 }, rotation: 0.0, tint: Color.with_alpha(Color.white, a8) })
			{}
		}
		NoLogo => {}
	}
	Scene.draw!(frame, model, Chrome.splash(model, Scene.measure_of(model), splash_slow_note(model.tick)))
	Ok({})
}

# A boot load that outlives splash_slow_secs says so on the splash and names
# the way out, so a stuck load never reads as a window still working. The
# boot task cannot be cancelled from the frame loop; R spawns a fresh load and
# ESC quits.
splash_slow_secs : U64
splash_slow_secs = 20

splash_slow_note : U64 -> Str
splash_slow_note = |tick|
	if (tick < splash_slow_secs * ticks_per_second) "" else "still loading after ${U64.to_str(tick // ticks_per_second)} s - R retries, ESC quits"

expect splash_slow_note(0) == ""
expect splash_slow_note(splash_slow_secs * ticks_per_second - 1) == ""
expect splash_slow_note(splash_slow_secs * ticks_per_second) == "still loading after 20 s - R retries, ESC quits"

# UI zoom transforms geometry directly into the framebuffer. The optional
# bloom target uses window coordinates, with the same camera inside it;
# only the additive halo is sampled from a texture, never the base text.
scaled_scene! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit])
scaled_scene! = |model, frame|
	frame.with_camera!(Camera.default.with_zoom(model.ui_scale), |f| scene!(model, f))

# The map's picture, repainted on the frames update! marks, before anything
# draws to the screen: a scope opened inside the glow's own offscreen pass
# would nest one target in another. In heat mode the routes are drawn on the
# same frames into heat's own texture with added colours, so a pixel's count
# is the segments drawn over it. A refused scope leaves the last picture
# standing.
paint_map! : Model, Draw.Frame => {}
paint_map! = |model, frame|
	if Map.is_map(model.view) and model.map_paint {
		match model.map_rt {
			Target(t) => {
				_ = frame.with_render_texture!(
					t.rt,
					|f| {
						f.clear!(Color.transparent)
						Ok(Map.paint_picture!(model, f))
					},
				)
				{}
			}
			_ => {}
		}
		match model.map_heat {
			Ready(h) if model.view == 11 => {
				_ = frame.with_render_texture!(
					h.rt,
					|f| {
						f.clear!(Color.transparent)
						f.with_blend_mode!(AddColors, |g| g.with_camera!(Camera.default.with_zoom(model.ui_scale), |k| Ok(Map.paint_heat!(model, model.map_painted, k))))
					},
				)
				{}
			}
			_ => {}
		}
	}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit])
render! = |model, frame| {
	if !(model.booting) {
		paint_map!(model, frame)
	}
	if model.booting {
		frame.with_camera!(Camera.default.with_zoom(model.ui_scale), |f| splash!(model, f))
	} else match model.glow {
		Ready(g) =>
			if model.glow_on {
				scaled_scene!(model, frame)?
				# a refused scope leaves the sharp base standing alone -
				# glow degrades, never the image under it
				_ = match frame.with_render_texture!(g.rt, |f| scaled_scene!(model, f)) {
					Err(_) => {}
					Ok(_) => {
						td = { texture: g.rt.texture(), source: g.rt.source(), dest: { x: 0.0, y: 0.0, width: g.gw, height: g.gh }, origin: { x: 0.0, y: 0.0 }, rotation: 0.0, tint: Color.white }
						_ = frame.with_blend_mode!(
							Additive,
							|f2|
								f2.with_shader!(
									g.shader,
									|f3| {
										f3.texture!(td)
										Ok({})
									},
								),
						)
					}
				}
				Ok({})
			} else scaled_scene!(model, frame)
		_ => scaled_scene!(model, frame)
	}
}
