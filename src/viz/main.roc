## Stride — the viz suite's window over ~/.stride/db.sqlite, read
## at launch. The modules beside this file carry the parts: Theme (geometry +
## palette), Db (every loader and its types), Ui (the Model), and one module
## per view. This file owns the app contract: the platform pin, Model/Msg,
## init!, update!, and the view dispatch — view_basename enumerates the views
## and the nav list is their order.
##
## NOTE the pin below: roc-ray 0.10.0-rc5 declares nightly-2026-09-07, not the
## engine's toolchain pin. The header carries its own compiler version, so
## `roc src/viz/main.roc` with a matching nightly is the whole build.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc5/8x22d4JXTKSiPvj3Bd3br2u7rEL3baUzEvmSBrCBDvqV.tar.zst", core: "../core/main.roc", roc: "nightly-2026-09-16-a49a16f" }

import rr.App
import rr.Assets
import rr.Capture
import rr.Camera
import rr.Cmd
import rr.Color
import rr.Draw
import rr.Files
import rr.Mouse
import rr.Sqlite
import rr.Task
import rr.Text
import rr.Texture
import core.Series
import core.Units
import Board
import Heat
import Plan
import Ramp
import Zones
import Table
import Curve
import Career
import Db
import DisplayScale
import Hud
import Theme
import Trace
import Ui

Model : Ui.Model

program = { init!, update!, render! }

init! : App.Init(Model, [AssetPathInvalid, AssetNotFound, AssetReadFailed, FontLoadFailed, ResourceLimit])
init! = App.init(
	App.default
		.with_title("Stride")
		.with_size({ width: Theme.win_w, height: Theme.win_h })
		.with_frame_pacing(Capped(60))
		.with_resizable(Bool.True)
		.with_min_size({ width: DisplayScale.min_width, height: DisplayScale.min_height })
		.with_output_dir("captures"),
	|_startup| {
		font = Draw.default_font!()
		load_model!(font, 90, Bool.True)
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

# The home directory on every platform, without an Env module: the platform
# has no Env, but Cmd captures stdout, so a shell answers. printenv serves
# unix; Windows ships no printenv, so cmd's own echo of %USERPROFILE% answers
# there — the same variable the CLI's home_dir! falls back to, so both
# surfaces resolve the identical ~/.stride/db.sqlite (Windows accepts the
# mixed-separator join, and the CLI writes that exact spelling already).
# cmd echoes the pattern back verbatim when the variable is unset, so that
# spelling means unresolved, not a home named %USERPROFILE%. A missing
# binary surfaces as Err from the spawn, never a crash - the degraded state
# #442 exhibited is this platform behaving that way.
# the mark, from the authored file: the repo's img/ in a dev checkout,
# ~/.stride/img when launched as the app bundle (the launcher seeds it the
# way it seeds fonts). Splash-only, so nothing loads it outside boot.
load_logo! : Str, Bool => [NoLogo, Logo(Texture.Texture)]
load_logo! = |home, boot|
	if !boot NoLogo
	else {
		bytes = match Files.read_bytes!("img/stride-icon.png") {
			Ok(b) => b
			Err(_) => if home == "" [] else match Files.read_bytes!("${home}/.stride/img/stride-icon.png") {
				Ok(b) => b
				Err(_) => []
			}
		}
		if List.is_empty(bytes) NoLogo
		else match Assets.texture_from_bytes!({ format: Png, bytes }) {
			Ok(t) => Logo(t)
			Err(_) => NoLogo
		}
	}

resolve_home! : {} => Str
resolve_home! = |{}| {
	unix = match Cmd.run_utf8!(Cmd.with_args(Cmd.new("printenv"), ["HOME"])) {
		Ok(out) => Str.trim(out.stdout)
		Err(_) => ""
	}
	if unix != "" unix
	else match Cmd.run_utf8!(Cmd.with_args(Cmd.new("cmd"), ["/C", "echo %USERPROFILE%"])) {
		Ok(out) => {
			win = Str.trim(out.stdout)
			if win == "%USERPROFILE%" "" else win
		}
		Err(_) => ""
	}
}

# boot=True builds the instant skeleton the splash renders over: no home
# resolution, no database, no engine call - the window opens on frame one
# and the real load runs in a spawned task that answers with Reloaded.
load_model! : Text.Font, I64, Bool => Try(Ui.Model, [ResourceLimit, ..])
load_model! = |font, curve_days, boot| {
		# ~/.stride/db.sqlite, resolved on every load. Resolution is one
		# printenv - cheap enough for the boot skeleton, which needs it to
		# find the seeded logo; only the database and engine work are slow.
		home = resolve_home!({})
		db_path = Str.concat(home, "/.stride/db.sqlite")
		loaded = if boot or home == "" {
			{ s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot resolve HOME" }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], cpv: [], st: 0 , tr: [], sg: [], du: 1.0, rd: { day: "", name: "", ago: -1, err: "" }, tids: [], nts: [], pl: [], wk: { this: 0, last: 0 }, pw: { done: 0, total: 0 }, bn: "", ht: [], hev: [], zw: [], rw: [], csp: [], cs: [], prs: [], tcache: [], un: Metric }
		} else match Sqlite.Db.open!(db_path) {
			Ok(db) => {
				Db.publish_caps!(db, caps_views, caps_fields)
				s = Db.load_series!(db)
				e = Db.load_event!(db)
				c = Db.load_curve!(db, curve_days)
				tids = Db.load_trace_ids!(db)
				# ONLY the selected session is cached at boot. Caching the whole
				# picker up front is what made the window take minutes to open on
				# a real database: not the SQL (0.2s for the whole stream corpus)
				# but the roc-ray SQLite binding, which marshals result rows one
				# at a time - and each session's downsampled trace is hundreds of
				# rows, so a hundred-odd sessions was ~100k rows before the first
				# frame. A switch or ghost summon to an un-cached session falls
				# through to the one-session load the cache-miss path already
				# spawns (trace_task! / ghost_task!), so the cost is paid per
				# session actually looked at, not for the whole picker at boot.
				un = Db.units!(db)
				tcache = load_tcache!(db, un, List.take_first(tids, 1))
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
				sfs = Db.load_spine_fams!(db)
				csp = Db.load_career_spines!(db, sfs)
				cs = Db.load_career_sports!(db)
				rw = Db.load_ramp_weeks!(db)
				prs = Db.load_prs!(db)
				nts = Db.load_day_notes!(db)
				cpv = Db.load_curve_prev!(db, curve_days)
				{ s, e, c, cpv, st, tr, sg, du, rd, tids, nts, pl, wk, pw, bn, ht, hev, zw, rw, csp, cs, prs, tcache, un }
			}
			Err(_) => { s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot open ${db_path}" }, e: { day: "", name: "", ahead: 0, err: "" }, c: [], cpv: [], st: 0 , tr: [], sg: [], du: 1.0, rd: { day: "", name: "", ago: -1, err: "" }, tids: [], nts: [], pl: [], wk: { this: 0, last: 0 }, pw: { done: 0, total: 0 }, bn: "", ht: [], hev: [], zw: [], rw: [], csp: [], cs: [], prs: [], tcache: [], un: Metric }
		}
		ev = Db.find_idx(loaded.s.days, loaded.e.day)
		# the fit shells out to the engine; the skeleton cannot afford it
		fit = if boot ({ cp: 0.0, w_prime: 0.0, r2: 0.0, points: 0.0, ok: Bool.False }) else Db.load_fit!(curve_days)
		fit_text =
			if fit.ok
				"CP ${Db.fmt_f(fit.cp)} W · W' ${Db.fmt_f(fit.w_prime / 1000.0)} kJ · fit r2 ${Db.fmt_f(fit.r2)} from ${Db.fmt_i(fit.points)} bests"
			else "CP fit unavailable - the engine did not answer"
		# Quicksand carries prose; JetBrains Mono carries data. Small labels
		# use an atlas close to their displayed size: shrinking title-sized
		# glyphs to captions loses thin strokes between samples. Titles and
		# KPI digits have their own larger atlases. Missing fonts fall back
		# to the platform's built-in face.
		head = brand_font!(home, "Quicksand-Medium.ttf", 24, font)
		title_font = brand_font!(home, "Quicksand-Medium.ttf", 48, font)
		mono_big = brand_font!(home, "JetBrainsMono-Regular.ttf", 48, font)
		mono = brand_font!(home, "JetBrainsMono-Regular.ttf", 24, font)
		mk! = |txt, sz| Text.from(txt, if sz >= 24 title_font else head).size(sz).prepare!()
		mkm! = |txt, sz| Text.from(txt, mono).size(sz).prepare!()
		mkb! = |txt, sz| Text.from(txt, mono_big).size(sz).prepare!()
		curve_lbls = List.map_try!(loaded.c, |c| {
			p = mkm!(I64.to_str(c.dur_s), 12)?
			Ok({ p, d: c.dur_s })
		})?
		ylabels = List.map_try!([-30, -20, -10, 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100], |v| {
			p = mkm!(I64.to_str(v), 12)?
			Ok({ p, v: I64.to_f32(v) })
		})?
		ends = List.map_try!(
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
		initial_layout = DisplayScale.layout(DisplayScale.default_percent, { w: I32.to_f32(Theme.win_w), h: I32.to_f32(Theme.win_h) })
		Ok({
			title: mk!("Stride", 30)?,
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
			curve_prev: loaded.cpv,
			curve_lbls: curve_lbls,
			fit_lbl: mk!(Db.ascii_safe(fit_text), 14)?,
			curve_title: mk!("power - this ${I64.to_str(curve_days)}d vs the ${I64.to_str(curve_days)}d before it", 15)?,
			curve_days,
			trace_ids: loaded.tids,
			trace_sel: 0.U64,
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
			units: loaded.un,
			trace_sport: "",
			curve_hint: mk!("1/2/3 or chips  window      hover a rung      TAB  session trace      R  reload      S  screenshot      V  record      ESC quit", 13)?,
			trace_hint: mk!("[ / ]  older/newer session      X  sport filter      shift+[ / shift+]  ghost older/newer      C  clear ghost      wheel zoom  drag pan  0 reset      TAB  data table      R  reload      S  screenshot      V  record      ESC quit", 13)?,
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
			trace_dur: loaded.du,
			fit_cp: if fit.ok (fit.cp) else 0.0,
			fit_r2: if fit.ok (fit.r2) else 0.0,
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
			career_spines: loaded.csp,
			career_sports: loaded.cs,
			spine_idx: 0,
			ramp_weeks: loaded.rw,
			prs: loaded.prs,
			rec_status: Idle,
			glow: Unbuilt,
			last_directive: { id: -1.I64, refused: "" },
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
				{ p: mk!("career", 13)?, v: 8.U8 },
			],
			status: mk!(if boot "" else loaded.s.err, 16)?,
			has_error: !boot and loaded.s.err != "",
			booting: boot,
			logo: load_logo!(home, boot),
			font: mono,
			hint: mk!("1/2/3 range   TAB view   hover or arrows to read a day   R reload   S screenshot   V record   G glow   ESC quit", 13)?,
			empty: mk!("no data yet - sync and analyze first, then reopen", 16)?,
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
ghost_task! : Str, List(TraceId), I64 => Msg
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
						tr = Db.load_trace!(db, entry.id, entry.chan)
						du = Db.load_dur!(db, entry.id)
						GhostSwitched({ tr, du, sel: gsel, day: entry.day })
					}
				}
		}
	}

# Same task lane, the live session: re-reads one session's trace, segments
# and duration and reports back as a message. Any failure keeps the session
# the window already had.
trace_task! : Str, [Metric, Imperial], List(TraceId), U64 => Msg
trace_task! = |home, units, ids, sel|
	if home == "" TraceSwitchFailed
	else match List.get(ids, sel) {
		Err(_) => TraceSwitchFailed
		Ok(entry) =>
			match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
				Err(_) => TraceSwitchFailed
				Ok(db) => {
					tr = Db.load_trace!(db, entry.id, entry.chan)
					sg = Db.load_segs!(db, entry.id)
					du = Db.load_dur!(db, entry.id)
					sp = if entry.chan == Db.pace_chan (Db.load_splits!(db, entry.id, Units.split_len(units))) else []
					TraceSwitched({ tr, sg, du, sel, day: entry.day, un: Db.trace_unit(entry.chan, units), sp })
				}
			}
	}

# One day's story, fetched when a table row is clicked. Units come from the
# model, not a fresh config read: the window's setting is what launch (or R)
# loaded, and one panel re-reading it mid-session would disagree with every
# other surface until the next reload.
detail_task! : Str, [Metric, Imperial], Str => Msg
detail_task! = |home, units, day|
	if home == "" DayDetail({ day, lines: [{ title: "no database path", stats: "", extra: "", zones: [] }] })
	else match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
		Err(_) => DayDetail({ day, lines: [{ title: "cannot open the database", stats: "", extra: "", zones: [] }] })
		Ok(db) => DayDetail({ day, lines: Db.load_day_detail!(db, units, day) })
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

# Every refusable field of a directive, named - a pure function rather than
# an inline block: this nightly miscompiles a large conditional binding
# captured by a task closure to its empty default (the #371 family), and a
# call is the shape that survives.
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
	List.fold(List.map_with_index(ids, |e, i| { e, i }), cur, |acc, x|
		if !(sport_ok(filt, x.e.sport)) acc
		else if older (if x.i > cur and (acc == cur or x.i < acc) x.i else acc)
		else if x.i < cur and (acc == cur or x.i > acc) x.i else acc)

# The newest session a filter admits, for snapping the selection when the
# filter changes under it. `fallback` stands when the filter admits nothing,
# so an empty result leaves the window on the session it already had.
first_admitted : List(TraceId), Str, U64 -> U64
first_admitted = |ids, filt, fallback|
	match List.first(List.keep_oks(List.map_with_index(ids, |e, i| { e, i }), |x| if sport_ok(filt, x.e.sport) (Ok(x.i)) else Err({}))) {
		Ok(h) => h
		Err(_) => fallback
	}

# The filter cycle: "" first, then each sport the menu actually holds, in the
# menu's own newest-first order. Built from the menu rather than from a fixed
# list of sports, so X can never land on a filter that admits nothing.
sport_cycle : List(TraceId) -> List(Str)
sport_cycle = |ids|
	List.fold(ids, [""], |acc, e| if e.sport != "" and !(List.contains(acc, e.sport)) (List.append(acc, e.sport)) else acc)

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
	sel_i = match U64.to_i64_try(sel) { Ok(v) => v
		Err(_) => -1 }
	List.fold(List.map_with_index(ids, |e, i| { e, i }), -1, |acc, x| {
		xi = match U64.to_i64_try(x.i) { Ok(v) => v
			Err(_) => -1 }
		if xi < 0 or xi == sel_i or !(ghost_matches(live, x.e)) acc
		else if older (if xi > cur and (acc < 0 or xi < acc) xi else acc)
		else if xi < cur and (acc < 0 or xi > acc) xi else acc
	})
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
			if gu == sel (-1)
			else match List.get(ids, gu) {
				Err(_) => -1
				Ok(ge) => if ghost_matches(entry_at(ids, sel), ge) ghost else -1
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
	if sport_ok(filt, entry_at(ids, sel).sport) filt else ""

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
	idx = List.fold(List.map_with_index(cyc, |s, i| { s, i }), 0.U64, |acc, x| if x.s == cur x.i else acc)
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

refusals_for : { has_d : Bool, id : I64, view : I64, range : I64, cursor_day : Str, trace_day : Str, ghost_day : Str }, I64, U64, U64, List(TraceId) -> Str
refusals_for = |dv, cdir, wsel, cur_sel, ids| {
	segs = List.keep_if([
		(if dv.view > 8 or dv.view < -1 ("view ${I64.to_str(dv.view)} unknown") else ""),
		(if dv.range != -1 and dv.range != 30 and dv.range != 60 and dv.range != 90 ("range ${I64.to_str(dv.range)} not 30/60/90") else ""),
		(if dv.cursor_day != "" and cdir == -2 ("cursor_day ${dv.cursor_day} not in the series") else ""),
		(if dv.trace_day != "" and wsel == cur_sel and (match List.get(ids, wsel) { Ok(te9) => te9.day != dv.trace_day
			Err(_) => Bool.True }) ("trace_day ${dv.trace_day} not in the picker") else ""),
		(if dv.ghost_day != "" and dv.ghost_day != "none" and !(List.any(ids, |ge9| ge9.day == dv.ghost_day)) ("ghost_day ${dv.ghost_day} not in the picker") else ""),
		# the session on screen cannot be its own ghost: the kind test below
		# stays quiet on it (a session trivially matches itself), and the
		# dismissal in ghost_for_sel is silent, so without this segment the
		# directive would report applied while drawing nothing
		(if dv.ghost_day != "" and dv.ghost_day != "none" and dv.ghost_day == entry_at(ids, wsel).day ("ghost_day ${dv.ghost_day} is the session on screen") else ""),
		# in the picker but the wrong KIND of session: naming what differs -
		# the sport, or failing that the unit - is what makes this actionable,
		# since "refused" alone reads as a missing day
		(if dv.ghost_day != "" and dv.ghost_day != "none" and List.any(ids, |ge8| ge8.day == dv.ghost_day) and !(List.any(ids, |ge7| ge7.day == dv.ghost_day and ghost_matches(entry_at(ids, wsel), ge7))) {
			live6 = entry_at(ids, wsel)
			gh6 = List.fold(ids, live6, |acc, g6| if g6.day == dv.ghost_day g6 else acc)
			if gh6.sport != live6.sport ("ghost_day ${dv.ghost_day} is ${gh6.sport}, the session is ${live6.sport}")
			else "ghost_day ${dv.ghost_day} is ${Db.chan_name(gh6.chan)}, the session is ${Db.chan_name(live6.chan)}"
		} else ""),
	], |s9| s9 != "")
	Str.join_with(segs, "; ")
}

expect {
	m = [
		{ id: 1, day: "d1", name: "n1", sport: "Ride", chan: Db.watts_chan },
		{ id: 2, day: "d2", name: "n2", sport: "Rowing", chan: Db.watts_chan },
	]
	dv = { has_d: Bool.True, id: 0, view: 2, range: -1, cursor_day: "", trace_day: "", ghost_day: "d1" }
	# naming the shown session as its own ghost is refused BY NAME - the kind
	# test cannot catch it (a session trivially matches itself) and the
	# dismissal downstream is silent
	refusals_for(dv, -2, 0, 0, m) == "ghost_day d1 is the session on screen"
	# the same day as a ghost for the OTHER session is a kind question, and
	# these two differ by sport
	and refusals_for(dv, -2, 1, 1, m) == "ghost_day d1 is Ride, the session is Rowing"
	# a clean directive refuses nothing
	and refusals_for({ has_d: Bool.True, id: 0, view: 2, range: -1, cursor_day: "", trace_day: "", ghost_day: "" }, -2, 0, 0, m) == ""
}

# Reports a directive's terminal outcome from the task lane.
mark_task! : Str, I64, Str => {}
mark_task! = |home, did, refused|
	match Sqlite.Db.open!(Str.concat(home, "/.stride/db.sqlite")) {
		Err(_) => {}
		Ok(db) => Db.mark_directive!(db, did, refused)
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
	MarkDone({}),
	Reloaded(Ui.Model),
	ReloadFailed,
	TraceSwitched({ tr : List(F32), sg : List(Db.Seg), du : F32, sel : U64, day : Str, un : Str, sp : List(Series.Split) }),
	TraceSwitchFailed,
	Directive({ dv : Db.Directive, note : Str }),
	Polled(Str),
	DirectiveNone,
	FocusWritten,
	FocusWriteFailed,
	DayDetail({ day : Str, lines : List(Db.DayLine) }),
]

# ONE nav density: every pill carries its 12x12 vector mark beside the
# label. A width-switched icon tier used to exist, and an information
# tier that switches off by width goes dark for whole classes of windows
# - at the 150% scale default its threshold asked for more logical width
# than common laptop displays report - so the pill grew to hold both
# instead. The constants are shared by the render and both hit-tests; at
# the 980 logical floor nine pills span x 260-938, clear of the title
# row's scale chip by ~15px at its widest rendering.
nav_pitch : F32
nav_pitch = 76.0

nav_width : F32
nav_width = 70.0

# One entry per pickable session, loaded eagerly: switching and ghost
# summons read this list instead of a task round-trip per keypress.
# Recursion because an effectful body cannot reassign an outer var.
load_tcache! : Sqlite.Db, [Metric, Imperial], List(TraceId) => List({ tr : List(F32), sg : List(Db.Seg), du : F32, un : Str, sp : List(Series.Split) })
load_tcache! = |db, units, ids|
	match List.first(ids) {
		Err(_) => []
		Ok(te) => {
			tr9 = Db.load_trace!(db, te.id, te.chan)
			sg9 = Db.load_segs!(db, te.id)
			du9 = Db.load_dur!(db, te.id)
			# splits only where a pace trace draws them - the panel is the
			# pace channel's companion, and the arrays are only read once
			sp9 = if te.chan == Db.pace_chan (Db.load_splits!(db, te.id, Units.split_len(units))) else []
			# the unit travels with the samples so a cache read needs no second
			# lookup into the picker row; prepend so picker order survives
			# without List.reverse, which this stdlib lacks
			List.prepend(load_tcache!(db, units, List.drop_first(ids, 1)), { tr: tr9, sg: sg9, du: du9, un: Db.trace_unit(te.chan, units), sp: sp9 })
		}
	}

# ONE view->basename map for every capture format: png and webm derive
# from it, so the "named for the view" invariant cannot drift per-path
# the focus row's view code, hoisted to a pure top-level function: a
# multi-arm conditional built inline inside a task closure is the shape the
# pinned compiler has miscompiled before - a call is the shape that survives.
focus_view_code : U8 -> I64
focus_view_code = |v|
	if v == 0 (0) else if v == 1 (1) else if v == 2 (2) else if v == 3 (3) else if v == 4 (4) else if v == 5 (5) else if v == 6 (6) else if v == 7 (7) else 8

view_basename : U8 -> Str
view_basename = |v|
	if v == 0 "form-board" else if v == 1 "power" else if v == 2 "session-trace" else if v == 3 "data-table" else if v == 4 "plan" else if v == 5 "heat" else if v == 6 "zones" else if v == 7 "ramp" else "career"

# what the bus accepts, as data (#439). caps_views derives from view_basename
# so the published list can never drift from the dispatch; caps_fields must
# move together with refusals_for - the accepts column states the same rules
# that function enforces, and both live in this file so an edit sees both.
caps_views : List({ id : I64, name : Str })
caps_views = List.map([0.U8, 1, 2, 3, 4, 5, 6, 7, 8], |v| { id: U8.to_i64(v), name: view_basename(v) })

caps_fields : List({ name : Str, kind : Str, accepts : Str })
caps_fields = [
	{ name: "view", kind: "integer", accepts: "0..8" },
	{ name: "range", kind: "integer", accepts: "30|60|90 (days; omitted leaves the range unchanged)" },
	{ name: "cursor_day", kind: "date", accepts: "YYYY-MM-DD present in the form-board series" },
	{ name: "trace_day", kind: "date", accepts: "YYYY-MM-DD among the trace picker's sessions" },
	{ name: "ghost_day", kind: "date", accepts: "YYYY-MM-DD among the trace picker's sessions, or 'none' to dismiss" },
]

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model0, program_input| {
	d = program_input.devices
	# task answers land as messages; fold them in before this frame's input.
	# A finished reload keeps the UI state the user has moved since spawning.
	model = List.fold(program_input.messages, model0, |acc, msg|
		match msg {
			Shot(_) => acc
			RecCmd(_) => acc
			MarkDone(_) => acc
			# also the boot task's failure exit: the splash must never spin
			# forever, so a dead load hands over to the skeleton's own screens
			ReloadFailed => { ..acc, booting: Bool.False }
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
			Reloaded(fresh) => { ..fresh, range: acc.range, view: acc.view, spine_idx: acc.spine_idx, cursor: acc.cursor, mouse_x: acc.mouse_x, mouse_y: acc.mouse_y, mouse_in: acc.mouse_in, tick: acc.tick, last_focus: acc.last_focus, win: acc.win, ui_percent: acc.ui_percent, ui_scale: acc.ui_scale, detail_day: acc.detail_day, detail: acc.detail, view_anim: acc.view_anim }
			TraceSwitched(sw) => { ..acc, trace: sw.tr, segs: sw.sg, trace_dur: sw.du, trace_sel: sw.sel, trace_day: sw.day, trace_unit: sw.un, trace_splits: sw.sp }
		})
	# the coach's word arrives beside the human's input and steers only what
	# it names: view, range, a day for the crosshair, a session for the trace
	directive0 = List.fold(program_input.messages, { has_d: Bool.False, id: -1.I64, view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "" }, |acc, msg|
		match msg {
			Directive(d2) => { has_d: Bool.True, id: d2.dv.id, view: d2.dv.view, range: d2.dv.range, cursor_day: d2.dv.cursor_day, trace_day: d2.dv.trace_day, ghost_day: d2.dv.ghost_day }
			_ => acc
		})
	# a re-delivered id means the mark was lost to a busy database (the row
	# stayed pending and was re-polled): re-report the recorded outcome and
	# apply NOTHING - re-applying fought the user's own input every second
	# for as long as a CLI write transaction held the lock
	is_redelivery = directive0.has_d and directive0.id == model.last_directive.id
	_ = if is_redelivery and model.home != "" {
		homer = model.home
		rid = model.last_directive.id
		rref = model.last_directive.refused
		Task.spawn!(program_input, || MarkDone(mark_task!(homer, rid, rref)))
	}
	directive = if is_redelivery ({ has_d: Bool.False, id: -1.I64, view: -1, range: -1, cursor_day: "", trace_day: "", ghost_day: "" }) else directive0
	if d.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		pixels = { w: I32.to_f32(program_input.window.size.width), h: I32.to_f32(program_input.window.size.height) }
		ctrl = d.key_down(KeyLeftControl) or d.key_down(KeyRightControl)
		ui_action = if !ctrl Keep else if d.key_pressed(KeyEqual) Larger else if d.key_pressed(KeyMinus) Smaller else if d.key_pressed(Key0) Reset else Keep
		ui_percent = DisplayScale.adjust(model.ui_percent, ui_action)
		layout = DisplayScale.layout(ui_percent, pixels)
		win = { w: layout.w, h: layout.h }
		m0 = DisplayScale.point(d.mouse.position(), layout.scale)
		# the range chips are buttons: a left click inside one selects it. Chip
		# geometry mirrors Board's row exactly - right-anchored at
		# win.w - 420 + i*54, y 64, each 46x22 - and must move with it.
		# nav clicks mirror the render geometry exactly (right-anchored pills)
		nav_click =
			if Mouse.button_pressed(d.mouse, Left) and m0.y >= 30.0 and m0.y <= 54.0 {
				nav_n = List.len(model.nav)
				List.fold(List.map_with_index(model.nav, |nv2, vi| { nv2, vi }), -1, |acc, x| {
					nx2 = win.w - 36.0 - U64.to_f32(nav_n - x.vi) * nav_pitch
					if m0.x >= nx2 and m0.x <= nx2 + nav_width (U8.to_i64(x.nv2.v)) else acc
				})
			} else -1
		view_input =
			if nav_click >= 0 (match I64.to_u8_try(nav_click) { Ok(v9) => v9
				Err(_) => model.view })
			else if d.key_pressed(KeyTab) (if model.view == 8 0 else model.view + 1) else model.view
		view = if directive.has_d and directive.view >= 0 and directive.view <= 8 (match I64.to_u8_try(directive.view) { Ok(v8) => v8
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
		}
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
		}
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
		# on the trace view, [ and ] walk the picker, X narrows it to one sport.
		# A filter change moves the selection itself, because the session the
		# window is showing may be one the new filter does not admit.
		shifted = d.key_down(KeyLeftShift) or d.key_down(KeyRightShift)
		want_sport = if view == 2 and !shifted and d.key_pressed(KeyX) (next_sport(model.trace_ids, model.trace_sport)) else model.trace_sport
		want_sel =
			if view != 2 or shifted model.trace_sel
			else if want_sport != model.trace_sport (first_admitted(model.trace_ids, want_sport, model.trace_sel))
			else if d.key_pressed(KeyLeftBracket) (next_admitted(model.trace_ids, model.trace_sel, want_sport, Bool.True))
			else if d.key_pressed(KeyRightBracket) (next_admitted(model.trace_ids, model.trace_sel, want_sport, Bool.False))
			else model.trace_sel
		# shift+[ summons/ages the ghost; shift+] youngs it and clears it when
		# it would pass the newest candidate. -1 is no ghost. next_ghost owns
		# the bounds, so running off either end dismisses rather than sticks;
		# it admits only sessions of the live one's kind, never the live
		# session's own index.
		want_ghost =
			if view != 2 model.ghost_sel
			# C clears in ONE press from any state - stepping the ghost off the
			# end also clears, but from deep in the menu that is many presses,
			# each one looking like nothing happened
			else if d.key_pressed(KeyC) (-1)
			else if !shifted model.ghost_sel
			else if d.key_pressed(KeyLeftBracket) {
				start = if model.ghost_sel < 0 (match U64.to_i64_try(model.trace_sel) { Ok(ts9) => ts9
					Err(_) => -1 }) else model.ghost_sel
				next_ghost(model.trace_ids, start, model.trace_sel, Bool.True)
			}
			else if d.key_pressed(KeyRightBracket) (if model.ghost_sel >= 0 (next_ghost(model.trace_ids, model.ghost_sel, model.trace_sel, Bool.False)) else -1)
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
			unitsd = model.units
			dayd = detail_day2
			Task.spawn!(program_input, || detail_task!(homed, unitsd, dayd))
		}
		view2 = view
		# a directive naming a day parks the crosshair there
		cursor2 = if row_hit.hit row_hit.cb else cursor_pre
		# moving the mouse over the form board's plot un-parks the crosshair:
		# the hover takes over while inside, and nothing lingers on the way
		# out. Only a cursor NOT re-parked this same frame (arrow, directive,
		# row click) clears - deliberate parks always win over drift. The
		# scale-equality guard is load-bearing: last frame's mouse_x/y were
		# computed at the PREVIOUS scale, so on a Ctrl +/- frame the same
		# physical pointer yields different logical coordinates and a still
		# mouse would read as drift - same hazard the trace drag guards below.
		cursor3 =
			if view2 == 0 and layout.scale == model.ui_scale and cursor2 == model.cursor and cursor2 >= 0 and (m.x != model.mouse_x or m.y != model.mouse_y) and m.y > Theme.pad_t + 56.0 and m.y < win.h - Theme.pad_b and m.x >= Theme.pad_l and m.x <= win.w - Theme.pad_r {
				-1
			} else cursor2
		# reloads and trace switches SPAWN — Cmd panics in update!, and the
		# task lane is where Sqlite and text preparation park legally
		# a directive naming a session day resolves to its picker slot
		want_sel2 =
			if directive.has_d and directive.trace_day != "" {
				List.fold(List.map_with_index(model.trace_ids, |e, ei| { e, ei }), want_sel, |acc, x| if x.e.day == directive.trace_day x.ei else acc)
			} else want_sel
		# NoSwitch joins List.get's OutOfBounds in one inferred error union
		switched = if want_sel2 != model.trace_sel (List.get(model.trace_cache, want_sel2)) else Err(NoSwitch)
		_ = if want_sel2 != model.trace_sel and (match switched { Ok(_) => Bool.False
			Err(_) => Bool.True }) {
			# cache miss only - the normal path answers from memory this frame
			home2 = model.home
			units2 = model.units
			ids2 = model.trace_ids
			Task.spawn!(program_input, || trace_task!(home2, units2, ids2, want_sel2))
		}
		# the trace camera: wheel zooms anchored at the cursor's moment, a held
		# left drag pans, 0 resets - and a session switch resets (the window
		# belonged to the old ride)
		wheel = Mouse.wheel_delta(d.mouse)
		zoom_raw =
			if view != 2 model.trace_zoom
			else if d.key_pressed(Key0) and !ctrl 1.0
			else if wheel.y > 0.1 (model.trace_zoom * 1.15)
			else if wheel.y < -0.1 (model.trace_zoom / 1.15)
			else model.trace_zoom
		trace_zoom2 = if want_sel2 != model.trace_sel (1.0) else F32.min(20.0, F32.max(1.0, zoom_raw))
		pan_raw =
			if view != 2 model.trace_pan
			else if (d.key_pressed(Key0) and !ctrl) or want_sel2 != model.trace_sel 0.0
			else {
				pw9 = win.w - Theme.pad_l - Theme.pad_r
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
			if directive.has_d and directive.ghost_day == "none" (-1)
			else if directive.has_d and directive.ghost_day != "" {
				List.fold(List.map_with_index(model.trace_ids, |e, ei| { e, ei }), want_ghost, |acc, x| if x.e.day == directive.ghost_day and ghost_matches(entry_at(model.trace_ids, want_sel2), x.e) (match U64.to_i64_try(x.ei) { Ok(gi) => gi
					Err(_) => acc }) else acc)
			} else want_ghost
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
				match I64.to_u64_try(want_ghost2) { Ok(gu9) => List.get(model.trace_cache, gu9)
					Err(_) => Err(OutOfBounds) }
			} else Err(NoSwitch)
		_ = if want_ghost2 != model.ghost_sel and want_ghost2 >= 0 and (match ghost_hit { Ok(_) => Bool.False
			Err(_) => Bool.True }) {
			home3 = model.home
			ids3 = model.trace_ids
			Task.spawn!(program_input, || ghost_task!(home3, ids3, want_ghost2))
		}
		# any ghost change clears the overlay this frame: a failed load leaves
		# no ghost rather than the previous one
		ghost2 = match ghost_hit { Ok(gc) => gc.tr
			Err(_) => if want_ghost2 != model.ghost_sel ([]) else model.ghost }
		ghost_day2 = match ghost_hit {
			Ok(_) => match I64.to_u64_try(want_ghost2) { Ok(gu8) => (match List.get(model.trace_ids, gu8) { Ok(ge) => ge.day
				Err(_) => "" })
				Err(_) => "" }
			Err(_) => if want_ghost2 != model.ghost_sel ("") else model.ghost_day }
		ghost_dur2 = match ghost_hit { Ok(gc) => gc.du
			Err(_) => model.ghost_dur }
		# a cache hit lands its data this frame; a miss clears rather than
		# drawing the previous ride under the new day
		switching = want_sel2 != model.trace_sel
		trace2 = match switched { Ok(sc) => sc.tr
			Err(_) => if switching ([]) else model.trace }
		segs2m = match switched { Ok(sc) => sc.sg
			Err(_) => if switching ([]) else model.segs }
		trace_splits2 = match switched { Ok(sc) => sc.sp
			Err(_) => if switching ([]) else model.trace_splits }
		trace_dur2 = match switched { Ok(sc) => sc.du
			Err(_) => if switching (1.0) else model.trace_dur }
		trace_day2 =
			if switching {
				match List.get(model.trace_ids, want_sel2) { Ok(se) => se.day
					Err(_) => model.trace_day }
			} else model.trace_day
		# the unit is re-derived from the picker row's CHANNEL, not read from
		# the cache entry, so it is right on a cache miss too - the axis must
		# never label a heart-rate trace in watts while the samples load
		trace_unit2 =
			if switching {
				match List.get(model.trace_ids, want_sel2) { Ok(se) => Db.trace_unit(se.chan, model.units)
					Err(_) => model.trace_unit }
			} else model.trace_unit
		_ = if want_days != model.curve_days or d.key_pressed(KeyR) {
			f2 = model.font
			Task.spawn!(program_input, || match load_model!(f2, want_days, Bool.False) {
				Ok(m2) => Reloaded(m2)
				Err(_) => ReloadFailed
			})
		}
		chip0h = win.w - 420.0
		# per-chip, not one wide band: the 8px gaps between chips are not
		# clickable and must not claim the pointer
		over_chip = (view2 == 0 or view2 == 1) and m.y >= 64.0 and m.y <= 86.0 and ((m.x >= chip0h and m.x <= chip0h + 46.0) or (m.x >= chip0h + 54.0 and m.x <= chip0h + 100.0) or (m.x >= chip0h + 108.0 and m.x <= chip0h + 154.0))
		row_count = Table.window_of(List.len(model.data), cursor2, Table.rows_fit(win.h)).rows
		over_row = view2 == 3 and m.x >= 36.0 and (if detail_day2 != "" (m.x < Table.panel_edge(win.w)) else m.x < win.w - 40.0) and m.y >= 134.0 and m.y < 134.0 + U64.to_f32(row_count) * 24.0
		over_nav = m.y >= 30.0 and m.y <= 54.0 and (List.fold(List.map_with_index(model.nav, |nv3, vi3| { nv3, vi3 }), Bool.False, |acc, x| {
			nx3 = win.w - 36.0 - U64.to_f32(List.len(model.nav) - x.vi3) * nav_pitch
			if m.x >= nx3 and m.x <= nx3 + nav_width Bool.True else acc
		}))
		Mouse.set_cursor!(if over_chip or over_row or over_nav PointingHand else Default)
		# a view switch stamps this frame; render fades the new view in from it
		# a click settles the career sweep instantly - zero means "no animation"
		# to every consumer of view_anim, so the twentieth arrival never pays
		# the first arrival's price
		# F cycles the career view's sport; harmless elsewhere
		spine_idx = if view == 8 and d.key_pressed(KeyF) (model.spine_idx + 1) else model.spine_idx
		view_anim = if view != model.view (model.tick + 1) else if view == 8 and Mouse.button_pressed(d.mouse, Left) (0) else model.view_anim
		tick = model.tick + 1
		# frame one of a boot: the window is already on screen showing the
		# splash - kick the real load exactly once, the same task R runs
		_ = if model.booting and model.tick == 0 {
			f0 = model.font
			Task.spawn!(program_input, || match load_model!(f0, 90, Bool.False) {
				Ok(m2) => Reloaded(m2)
				Err(_) => ReloadFailed
			})
		}
		# no HOME means no database path means no bus — spawning would only
		# manufacture failing tasks every tick, forever
		_ = if tick % 60 == 0 and model.home != "" {
			homep = model.home
			Task.spawn!(program_input, || poll_task!(homep))
		}
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
			view: focus_view_code(view2),
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
		# the directive's outcome, reported by THIS frame - the one that
		# applied it. Every refusable field is named on refusal; a fully
		# honoured directive closes with none. "applied" means the frame
		# accepted and acted; async completions it started (a reload, a
		# cache-miss fetch) may still fail and recover by their own rules.
		refused9 = if directive.has_d and directive.id >= 0 (refusals_for(directive, cursor_dir, want_sel2, model.trace_sel, model.trace_ids)) else ""
		_ = if directive.has_d and directive.id >= 0 and model.home != "" {
			homem = model.home
			did = directive.id
			refm = refused9
			Task.spawn!(program_input, || MarkDone(mark_task!(homem, did, refm)))
		}
		glow2 =
			match model.glow {
				Ready(g9) => if g9.gw == pixels.w and g9.gh == pixels.h (model.glow) else build_glow!(pixels)
				Unbuilt => build_glow!(pixels)
				# a refusal is sticky at the size it happened; a resize retries
				Unavailable(u9) => if u9.gw == pixels.w and u9.gh == pixels.h (model.glow) else build_glow!(pixels)
			}
		glow_on2 = if d.key_pressed(KeyG) (!model.glow_on) else model.glow_on
		Ok({ ..model, range, view: view2, cursor: cursor3, rec_status: program_input.capture, glow: glow2, glow_on: glow_on2, last_directive: (if directive.has_d and directive.id >= 0 ({ id: directive.id, refused: refused9 }) else model.last_directive), trace_zoom: trace_zoom2, trace_pan: trace_pan2, curve_days: want_days, trace_sel: want_sel2, ghost_sel: want_ghost2, ghost: ghost2, ghost_day: ghost_day2, ghost_dur: ghost_dur2, trace: trace2, segs: segs2m, trace_dur: trace_dur2, trace_day: trace_day2, trace_unit: trace_unit2, trace_splits: trace_splits2, trace_sport: want_sport2, tick, view_anim, spine_idx, last_focus, win, ui_percent, ui_scale: layout.scale, detail_day: detail_day2, detail: (if detail_day2 != model.detail_day [] else model.detail), mouse_x: m.x, mouse_y: m.y, mouse_in: m.y > (if view2 == 0 (Theme.pad_t + 56.0) else Theme.pad_t) and m.y < win.h - Theme.pad_b })
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
	Text.from("${Db.fmt_i(model.ui_scale * 100.0)}%  Ctrl +/-", model.font).size(11).draw!(frame, { pos: { x: 152.0, y: 40.0 }, color: Theme.ink_muted, align: (Top, Left) })
	# the recording badge lives below the pills on every view: a red dot
	# while filming, a quiet confirmation once the file is written
	_ = match model.rec_status {
		Active(af) => {
			frame.circle!({ center: { x: model.win.w - 148.0, y: 64.0 }, radius: 4.0, style: Draw.filled(Theme.alarm_c) })
			Text.from("rec ${U64.to_str(af.frames)}f   V stops", model.font).size(11).draw!(frame, { pos: { x: model.win.w - 138.0, y: 58.0 }, color: Theme.alarm_c, align: (Top, Left) })
		}
		Finished(ff) => {
			Text.from("recording saved to captures/ (${U64.to_str(ff.bytes / 1024)}kb)", model.font).size(11).draw!(frame, { pos: { x: model.win.w - 40.0, y: 58.0 }, color: Theme.tsb_c, align: (Top, Right) })
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
		}
		Idle => {}
	}
	# the nav: every view, visible and clickable, active one filled - TAB
	# stays as the keyboard accelerator
	List.for_each!(List.map_with_index(model.nav, |nv, ni| { nv, ni }), |x| {
		nx = model.win.w - 36.0 - U64.to_f32(List.len(model.nav) - x.ni) * nav_pitch
		on2 = x.nv.v == model.view
		hov2 = model.mouse_x >= nx and model.mouse_x <= nx + nav_width and model.mouse_y >= 30.0 and model.mouse_y <= 54.0
		style2 = if on2 (Draw.filled(Color.with_alpha(Theme.ctl_c, 60))) else if hov2 (Draw.filled(Color.with_alpha(Color.white, 18))) else Draw.filled(Theme.card)
		frame.rounded_rectangle!({ x: nx, y: 30.0, width: nav_width, height: 24.0, radius: 7.0, segments: 6, style: style2 })
		ic = if on2 Color.white else Theme.ink_muted
		nav_icon!(frame, x.nv.v, nx + 7.0, 36.0, ic)
		# the label centers in the span RIGHT of the mark, not the pill - a
		# pill-centered label would sit under the icon
		x.nv.p.draw!(frame, { pos: { x: nx + 44.0, y: 35.0 }, color: ic, align: (Top, Center) })
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
	}
	drawn =
		if model.view == 8 {
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
	# the crossfade: for ten frames after a switch, a panel-colored veil
	# fades off the incoming view - ease-out, cheap, and one rectangle
	age = model.tick - model.view_anim
	if model.view_anim > 0 and age < 10 {
		fade = 10 - age
		a = match U64.to_u8_try(fade * fade * 2) { Ok(v) => v
			Err(_) => 0 }
		frame.rectangle!({ x: 16.0, y: 16.0, width: model.win.w - 32.0, height: model.win.h - 32.0, style: Draw.filled(Color.with_alpha(Theme.panel, a)) })
	}
	drawn
}

# The boot splash: the stride route drawing itself while the real load runs
# in its task. The S sweeps bottom-left to top-right through the brand
# gradient with a comet at the pen, the mountain peak pops when a sweep
# completes, and the whole figure loops until Reloaded lands. Everything is
# geometry over the tick - no asset, nothing to load before the loader.
splash! : Ui.Model, Draw.Frame => Try({}, [Exit(I64), ..])
splash! = |model, frame| {
	# the splash clears to the TILE's own ground - RGB(1, 2, 9), a
	# representative pick from the interior of img/stride-icon.png away
	# from the mark - so the logo sits on a field of its own color rather
	# than framing itself in a slightly different black. The interior is a
	# DISTRIBUTION (the tile bakes a faint topo texture), so re-measuring
	# it is a judgement call clustered near (0, 2, 8); the corner padding
	# below is one exact value, and only that half re-measures
	# deterministically. The asset is RGB with no alpha channel
	# and carries TWO grounds: the tile's, and a lighter corner padding
	# outside the rounded corners, which a single clear cannot also match -
	# those four faint wedges are the residual #508 carries until the mark
	# ships as a transparent export. Nothing at runtime can read a
	# texture's pixels back, so a re-exported asset needs a re-measure.
	# The app views still clear to Theme.bg.
	frame.rectangle!({ x: 0.0, y: 0.0, width: model.win.w, height: model.win.h, style: Draw.filled(Color.rgb(1, 2, 9)) })
	cx = model.win.w / 2.0
	cy = model.win.h / 2.0 - 30.0
	pi = 3.14159265
	# brand gradient along the path: teal through blue to violet
	mixc = |t| {
		lerp = |a, b, k| {
			v = a + (b - a) * k
			match F32.round_to_u64_try(if v < 0.0 (0.0) else if v > 255.0 (255.0) else v) {
				Ok(u) => match U64.to_u8_try(u) { Ok(c8) => c8
					Err(_) => 255.U8 }
				Err(_) => 0.U8
			}
		}
		if t < 0.5 {
			k = t * 2.0
			Color.rgb(lerp(45.0, 79.0, k), lerp(212.0, 142.0, k), lerp(191.0, 247.0, k))
		} else {
			k = (t - 0.5) * 2.0
			Color.rgb(lerp(79.0, 166.0, k), lerp(142.0, 107.0, k), lerp(247.0, 250.0, k))
		}
	}
	# no drawn backdrop texture: the ground stays a flat field of the tile's
	# own color, so nothing competes with the mark or reads as stray lines
	# ending at an invisible edge
	_ = match model.logo {
		Logo(lt) => {
			# the authored mark itself - hand-drawn approximations kept
			# drifting from the artwork, so the artwork renders. It fades
			# in over the first moments and breathes gently while the
			# load works; the glow shader has nothing to add here.
			tf = U64.to_f32(model.tick)
			ar = if tf > 42.0 (255.0) else tf * 6.0
			a8 = match F32.to_u8_try(ar) { Ok(av) => av
				Err(_) => 255.U8 }
			sc = 1.0 + 0.015 * F32.sin(tf / 25.0)
			side = 264.0 * sc
			frame.texture!({ texture: lt, source: { x: 0.0, y: 0.0, width: lt.width, height: lt.height }, dest: { x: cx - side / 2.0, y: (cy - 16.0) - side / 2.0, width: side, height: side }, origin: { x: 0.0, y: 0.0 }, rotation: 0.0, tint: Color.with_alpha(Color.white, a8) })
			{}
		}
		NoLogo => splash_route!(model, frame, cx, cy, pi, mixc)
	}
	Text.from("Stride", model.font).size(30).draw!(frame, { pos: { x: cx, y: cy + 124.0 }, color: Color.white, align: (Top, Center) })
	dots = if model.tick % 90 < 30 "." else if model.tick % 90 < 60 ".." else "..."
	Text.from("loading your training story${dots}", model.font).size(13).draw!(frame, { pos: { x: cx, y: cy + 164.0 }, color: Theme.ink_muted, align: (Top, Center) })
	Ok({})
}

# the geometric fallback when the authored PNG cannot be found: the route
# drawing itself with a comet, the mountain popping in on completion
splash_route! : Ui.Model, Draw.Frame, F32, F32, F32, (F32 -> Color.Rgba) => {}
splash_route! = |model, frame, cx, cy, pi, mixc| {
	# two cubic beziers carry the S - a sine reads cramped and mirrored
	bez = |x0, y0, x1, y1, x2, y2, x3, y3, u| {
		v = 1.0 - u
		{
			x: v * v * v * x0 + 3.0 * v * v * u * x1 + 3.0 * v * u * u * x2 + u * u * u * x3,
			y: v * v * v * y0 + 3.0 * v * v * u * y1 + 3.0 * v * u * u * y2 + u * u * u * y3,
		}
	}
	# the route is ONE continuous smooth path, exactly as the mark draws it:
	# the S's two bends, then a rounded upward curl that turns back LEFT into
	# a squared-off ledge nested inside the peak's V. The route never touches
	# the mountain - the mountain is its own stroke, and it appears only when
	# the route completes. E is where the S hands over to the curl.
	ex = cx + 18.0
	ey = cy - 96.0
	n = 72
	pt = |i| {
		t = U64.to_f32(i) / U64.to_f32(n)
		if t < 0.36 {
			b = bez(cx - 85.0, cy + 85.0, cx + 85.0, cy + 78.0, cx + 98.0, cy + 18.0, cx + 2.0, cy - 6.0, t / 0.36)
			{ x: b.x, y: b.y, t }
		} else if t < 0.72 {
			b = bez(cx + 2.0, cy - 6.0, cx - 98.0, cy - 36.0, cx - 40.0, cy - 92.0, ex, ey, (t - 0.36) / 0.36)
			{ x: b.x, y: b.y, t }
		} else if t < 0.90 {
			# the curl: a semicircle from heading-right to heading-left
			a = pi * (t - 0.72) / 0.18
			{ x: ex + 14.0 * F32.sin(a), y: (ey - 14.0) + 14.0 * F32.cos(a), t }
		} else {
			{ x: ex - 30.0 * (t - 0.90) / 0.10, y: ey - 28.0, t }
		}
	}
	# reveal loops: 56 ticks of drawing, 34 of holding - frames run well below
	# 60fps while the load task works, so a longer cycle would never finish
	# inside the loading window and the mountain would never be seen
	cyc = model.tick % 90
	p_raw = U64.to_f32(cyc) / 56.0
	p1 = if p_raw > 1.0 (1.0) else p_raw
	p = 1.0 - (1.0 - p1) * (1.0 - p1)
	start = pt(0)
	# the start marker is a RING in the logo, not a dot
	frame.circle!({ center: { x: start.x, y: start.y }, radius: 9.0, style: Draw.filled(Theme.tsb_c) })
	frame.circle!({ center: { x: start.x, y: start.y }, radius: 5.0, style: Draw.filled(Theme.bg) })
	List.for_each!(List.map_with_index(List.repeat({}, n), |_u, i| i), |i| {
		a = pt(i)
		b = pt(i + 1)
		if b.t <= p {
			# a round cap at every joint: bare segment ends leave a notch
			# per joint that reads as a speckled edge under magnification
			frame.line!({ start: { x: a.x, y: a.y }, end: { x: b.x, y: b.y }, stroke: Draw.stroke(mixc(a.t), 6) })
			frame.circle!({ center: { x: b.x, y: b.y }, radius: 2.9, style: Draw.filled(mixc(b.t)) })
		}
	})
	# the mountain: apex, a left slope ending in a short downward foot, and
	# the long open right slope - separate from the route, arriving with a
	# pop once the route has finished drawing
	vio = mixc(1.0)
	ax = ex - 24.0
	ay = ey - 74.0
	if p >= 1.0 {
		l1 = { x: ax - 56.0, y: ay + 56.0 }
		frame.line!({ start: { x: ax, y: ay }, end: { x: l1.x, y: l1.y }, stroke: Draw.stroke(vio, 6) })
		frame.line!({ start: { x: l1.x, y: l1.y }, end: { x: l1.x, y: l1.y + 14.0 }, stroke: Draw.stroke(vio, 6) })
		frame.line!({ start: { x: ax, y: ay }, end: { x: ax + 72.0, y: ay + 72.0 }, stroke: Draw.stroke(vio, 6) })
		frame.circle!({ center: { x: ax, y: ay }, radius: 2.9, style: Draw.filled(vio) })
		frame.circle!({ center: { x: l1.x, y: l1.y }, radius: 2.9, style: Draw.filled(vio) })
		hold = U64.to_f32(cyc - 56) / 34.0
		pop = F32.sin(hold * pi)
		frame.circle!({ center: { x: ax, y: ay }, radius: 5.0 + pop * 9.0, style: Draw.filled(Color.with_alpha(vio, match F32.to_u8_try(70.0 * (1.0 - hold)) { Ok(pa) => pa
			Err(_) => 0 })) })
	} else {
		# the comet at the pen, the same one the career view rides
		head_i = match F32.round_to_u64_try(p * U64.to_f32(n)) { Ok(hi) => hi
			Err(_) => 0.U64 }
		hp = pt(head_i)
		frame.circle!({ center: { x: hp.x, y: hp.y }, radius: 11.0, style: Draw.filled(Color.with_alpha(Color.white, 26)) })
		frame.circle!({ center: { x: hp.x, y: hp.y }, radius: 6.0, style: Draw.filled(Color.with_alpha(mixc(p), 140)) })
		frame.circle!({ center: { x: hp.x, y: hp.y }, radius: 3.0, style: Draw.filled(Color.white) })
	}
	{}
}

# UI zoom transforms geometry directly into the framebuffer. The optional
# bloom target uses window coordinates, with the same camera inside it;
# only the additive halo is sampled from a texture, never the base text.
scaled_scene! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
scaled_scene! = |model, frame|
	frame.with_camera!(Camera.default.with_zoom(model.ui_scale), |f| scene!(model, f))

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| {
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
						g.rx.set!(g.gw)
						g.ry.set!(g.gh)
						_ = frame.with_blend_mode!(Additive, |f2|
							f2.with_shader!(g.shader, |f3| {
								f3.texture!(td)
								Ok({})
							}))
					}
				}
				Ok({})
			} else scaled_scene!(model, frame)
		_ => scaled_scene!(model, frame)
	}
}
