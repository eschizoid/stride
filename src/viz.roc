## Stride Form Board — a native window over the engine's PMC series, read LIVE
## from ~/.stride/db.sqlite (daily_load + events). Fitness (blue, filled),
## fatigue (violet), form (teal — the brand accent), daily load as a bottom
## rug, y-axis labels, current values at the line ends, and the next planned
## event as a dashed marker. Keys 1/2/3 set the range (30/60/90 days), the
## mouse reads any day off the chart, ESC quits.
##
## NOTE the pin below: roc-ray's platform needs nightly-2026-08-23, not the
## engine's toolchain pin. The header carries its own compiler version, so
## `roc src/viz.roc` with a matching nightly is the whole build.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Color
import rr.Draw
import rr.Text
import rr.Sqlite
import rr.Cmd

Point : { ctl : F32, atl : F32, tsb : F32, tss : F32 }
YLabel : { p : Text.Prepared, v : F32 }
EndLabel : { p : Text.Prepared, sel : U8 }

Model : {
	title : Text.Prepared,
	sub : Text.Prepared,
	leg_fit : Text.Prepared,
	leg_fat : Text.Prepared,
	leg_form : Text.Prepared,
	ylabels : List(YLabel),
	ends : List(EndLabel),
	ev_label : Text.Prepared,
	ev_found : Bool,
	ev_idx : U64,
	data : List(Point),
	status : Text.Prepared,
	has_error : Bool,
	font : Text.Font,
	hint : Text.Prepared,
	range : U64,
	mouse_x : F32,
	mouse_in : Bool,
}



win_w : I32
win_w = 980
win_h : I32
win_h = 600
pad_l : F32
pad_l = 64
pad_r : F32
pad_r = 86
pad_t : F32
pad_t = 110
pad_b : F32
pad_b = 44

program = { init!, update!, render! }

# integer tenths -> "41.9" / "-8.9"
fmt1 : I64 -> Str
fmt1 = |t| {
	sign = if t < 0 "-" else ""
	a = if t < 0 0 - t else t
	"${sign}${I64.to_str(a // 10)}.${I64.to_str(a % 10)}"
}

Loaded : { data : List(Point), days : List(Str), last : { c : I64, a : I64, t : I64 }, err : Str }

load_series! : Sqlite.Db => Loaded
load_series! = |db| {
	q = "SELECT day, CAST(ROUND(ctl*10) AS INTEGER) AS c10, CAST(ROUND(atl*10) AS INTEGER) AS a10, CAST(ROUND(tsb*10) AS INTEGER) AS t10, CAST(ROUND(tss*10) AS INTEGER) AS s10 FROM (SELECT day, ctl, atl, tsb, tss FROM daily_load ORDER BY day DESC LIMIT 90) ORDER BY day ASC"
	match Sqlite.query!({ db, query: q, bindings: [] }) {
		Err(_) => { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "query failed" }
		Ok(rows) => {
			decoded = List.map_try(rows, |r| {
				d = r.str("day") ? |_| "bad day"
				c = r.i64("c10") ? |_| "bad ctl"
				a = r.i64("a10") ? |_| "bad atl"
				t = r.i64("t10") ? |_| "bad tsb"
				s = r.i64("s10") ? |_| "bad tss"
				Ok({ d, c, a, t, s })
			})
			match decoded {
				Err(why) => { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: why }
				Ok(raw) => {
					data = List.map(raw, |r| { ctl: I64.to_f32(r.c) / 10.0, atl: I64.to_f32(r.a) / 10.0, tsb: I64.to_f32(r.t) / 10.0, tss: I64.to_f32(r.s) / 10.0 })
					days = List.map(raw, |r| r.d)
					last = match List.last(raw) {
						Ok(l) => { c: l.c, a: l.a, t: l.t }
						Err(_) => { c: 0, a: 0, t: 0 }
					}
					{ data, days, last, err: "" }
				}
			}
		}
	}
}

Event : { day : Str, name : Str }

load_event! : Sqlite.Db => Event
load_event! = |db|
	match Sqlite.query!({ db, query: "SELECT event_date, name FROM events ORDER BY event_date DESC LIMIT 1", bindings: [] }) {
		Err(_) => { day: "", name: "" }
		Ok(rows) => match List.first(rows) {
			Err(_) => { day: "", name: "" }
			Ok(r) => {
				d = match r.str("event_date") { Ok(x) => x
					Err(_) => "" }
				nm = match r.str("name") { Ok(x) => x
					Err(_) => "" }
				{ day: d, name: nm }
			}
		}
	}

find_idx = |days, target|
	List.fold(
		List.map_with_index(days, |d, i| { day: d, index: i }),
		{ found: Bool.False, idx: 0.U64 },
		|acc, x| if x.day == target ({ found: Bool.True, idx: x.index }) else acc,
	)

init! : App.Init(Model, [AssetPathInvalid, AssetNotFound, AssetReadFailed, FontLoadFailed, ResourceLimit])
init! = App.init(
	App.default
		.with_title("Stride Form Board")
		.with_size({ width: win_w, height: win_h })
		.with_frame_pacing(Capped(60)),
	|_startup| {
		font = Draw.default_font!()
		# ~/.stride/db.sqlite, resolved at launch — the platform has no Env
		# module, but Cmd captures stdout, so the shell answers for HOME.
		home = match Cmd.run_utf8!(Cmd.with_args(Cmd.new("printenv"), ["HOME"])) {
			Ok(out) => Str.trim(out.stdout)
			Err(_) => ""
		}
		db_path = Str.concat(home, "/.stride/db.sqlite")
		loaded = match Sqlite.Db.open!(db_path) {
			Ok(db) => {
				s = load_series!(db)
				e = load_event!(db)
				{ s, e }
			}
			Err(_) => { s: { data: [], days: [], last: { c: 0, a: 0, t: 0 }, err: "cannot open ${db_path}" }, e: { day: "", name: "" } }
		}
		ev = find_idx(loaded.s.days, loaded.e.day)
		mk! = |txt, sz| Text.from(txt, font).size(sz).prepare!()
		ylabels = List.map_try([0, 10, 20, 30, 40, 50], |v| {
			p = mk!(I64.to_str(v), 12)?
			Ok({ p, v: I64.to_f32(v) })
		})?
		ends = List.map_try(
			[
				{ s: "CTL ${fmt1(loaded.s.last.c)}", k: 0.U8 },
				{ s: "ATL ${fmt1(loaded.s.last.a)}", k: 1.U8 },
				{ s: "TSB ${fmt1(loaded.s.last.t)}", k: 2.U8 },
			],
			|e| {
				p = mk!(e.s, 13)?
				Ok({ p, sel: e.k })
			},
		)?
		Ok({
			title: mk!("Stride Form Board", 30)?,
			sub: mk!("last 90 days, live from stride", 15)?,
			leg_fit: mk!("Fitness", 15)?,
			leg_fat: mk!("Fatigue", 15)?,
			leg_form: mk!("Form", 15)?,
			ylabels,
			ends,
			ev_label: mk!(loaded.e.name, 13)?,
			ev_found: ev.found,
			ev_idx: ev.idx,
			data: loaded.s.data,
			status: mk!(loaded.s.err, 16)?,
			has_error: loaded.s.err != "",
			font,
			hint: mk!("1 / 2 / 3  range 30 / 60 / 90 days      hover to read a day      ESC quit", 13)?,
			range: 90.U64,
			mouse_x: 0.0,
			mouse_in: Bool.False,
		})
	},
)

Msg : []

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
		m = d.mouse.position()
		Ok({ ..model, range, mouse_x: m.x, mouse_in: m.y > 100.0 })
	}
}

lo_of : List(Point) -> F32
lo_of = |pts| List.fold(pts, 0.0, |acc, p| F32.min(acc, p.tsb)) - 6.0
hi_of : List(Point) -> F32
hi_of = |pts| List.fold(pts, 1.0, |acc, p| F32.max(acc, F32.max(p.ctl, p.atl))) + 8.0

clamp_idx : F32, U64 -> U64
clamp_idx = |raw, hi_idx|
	if raw <= 0.0 (0.U64)
	else match F32.round_to_u64_try(raw) {
		Ok(i) => if i >= hi_idx (hi_idx) else i
		Err(_) => hi_idx
	}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	ink_muted = Color.from_hex_rgb(0x8593a2)
	ink_faint = Color.from_hex_rgb(0x4d5a68)
	ctl_c = Color.from_hex_rgb(0x4f8ef7)
	atl_c = Color.from_hex_rgb(0xa66bfa)
	tsb_c = Color.from_hex_rgb(0x2dd4bf)

	frame.rectangle!({ x: 0.0, y: 0.0, width: I32.to_f32(win_w), height: I32.to_f32(win_h), style: Draw.filled(Color.from_hex_rgb(0x0b0b0e)) })
	frame.rounded_rectangle!({ x: 16.0, y: 16.0, width: I32.to_f32(win_w) - 32.0, height: I32.to_f32(win_h) - 32.0, radius: 14.0, segments: 10, style: Draw.filled(Color.from_hex_rgb(0x131318)) })

	model.title.draw!(frame, { pos: { x: 34.0, y: 30.0 }, color: Color.white, align: (Top, Left) })
	model.leg_fit.draw!(frame, { pos: { x: 36.0, y: 70.0 }, color: ctl_c, align: (Top, Left) })
	model.leg_fat.draw!(frame, { pos: { x: 118.0, y: 70.0 }, color: atl_c, align: (Top, Left) })
	model.leg_form.draw!(frame, { pos: { x: 206.0, y: 70.0 }, color: tsb_c, align: (Top, Left) })
	model.sub.draw!(frame, { pos: { x: 280.0, y: 70.0 }, color: ink_muted, align: (Top, Left) })

	if model.has_error {
		model.status.draw!(frame, { pos: { x: 36.0, y: 120.0 }, color: atl_c, align: (Top, Left) })
		Ok({})
	} else if List.len(model.data) < 2 {
		Ok({})
	} else {
		full = model.data
		take = U64.min(model.range, List.len(full))
		data = List.take_last(full, take)
		lo = lo_of(data)
		hi = hi_of(data)
		n = List.len(data)
		span = hi - lo
		pw = I32.to_f32(win_w) - pad_l - pad_r
		ph = I32.to_f32(win_h) - pad_t - pad_b
		xf = |i| pad_l + pw * U64.to_f32(i) / U64.to_f32(n - 1)
		yf = |v| pad_t + ph * (1.0 - (v - lo) / span)

		# grid + y labels
		List.for_each!(model.ylabels, |yl| {
			gy = yf(yl.v)
			frame.line!({ start: { x: pad_l, y: gy }, end: { x: I32.to_f32(win_w) - pad_r, y: gy }, stroke: Draw.stroke(Color.with_alpha(Color.white, 18), 1) })
			yl.p.draw!(frame, { pos: { x: 30.0, y: gy - 8.0 }, color: ink_faint, align: (Top, Left) })
		})
		frame.line!({ start: { x: pad_l, y: yf(0.0) }, end: { x: I32.to_f32(win_w) - pad_r, y: yf(0.0) }, stroke: Draw.stroke(Color.with_alpha(Color.white, 55), 1) })

		# daily load (TSS) as a faint rug in its OWN scale along the bottom band,
		# never on the fitness/form axis: load peaks well above 50 and would
		# rocket off the top if it shared the axis (two measures, one axis = wrong).
		bw = F32.max(1.5, pw / U64.to_f32(n) - 1.4)
		tss_max = F32.max(1.0, List.fold(data, 1.0, |acc, p| F32.max(acc, p.tss)))
		rug_base = pad_t + ph
		rug_band = ph * 0.22
		List.for_each!(List.map_with_index(data, |p, i| { i, s: p.tss }), |c|
			if c.s > 0.0 {
				bh = (c.s / tss_max) * rug_band
				frame.rectangle!({ x: xf(c.i) - bw / 2.0, y: rug_base - bh, width: bw, height: bh, style: Draw.filled(Color.with_alpha(ink_muted, 55)) })
			} else {})

		# soft fill under fitness
		List.for_each!(List.map_with_index(data, |p, i| { i, v: p.ctl }), |cur|
			match List.get(data, cur.i + 1) {
				Ok(_) => frame.rectangle!({ x: xf(cur.i), y: yf(cur.v), width: (pw / U64.to_f32(n - 1)) + 1.0, height: yf(0.0) - yf(cur.v), style: Draw.filled(Color.with_alpha(ctl_c, 12)) })
				Err(_) => {}
			})

		# event marker: dashed vertical + label
		if model.ev_found {
			ex = xf(model.ev_idx)
			List.for_each!(List.map_with_index(List.repeat({}, 40), |_u, k| k), |k| {
				y0 = pad_t + U64.to_f32(k) * 12.0
				if y0 + 6.0 <= pad_t + ph {
					frame.line!({ start: { x: ex, y: y0 }, end: { x: ex, y: y0 + 6.0 }, stroke: Draw.stroke(Color.with_alpha(Color.white, 70), 1) })
				} else {}
			})
			model.ev_label.draw!(frame, { pos: { x: ex - 6.0, y: pad_t + 4.0 }, color: ink_muted, align: (Top, Right) })
		} else {}

		draw_line! = |sel, col| {
			pts = List.map_with_index(data, |p, i| { i, v: sel(p) })
			List.for_each!(pts, |cur|
				match List.get(pts, cur.i + 1) {
					Ok(nxt) => frame.line!({ start: { x: xf(cur.i), y: yf(cur.v) }, end: { x: xf(nxt.i), y: yf(nxt.v) }, stroke: Draw.stroke(col, 2) })
					Err(_) => {}
				})
		}
		draw_line!(|p| p.tsb, tsb_c)
		draw_line!(|p| p.atl, atl_c)
		draw_line!(|p| p.ctl, ctl_c)

		# current-value labels at the line ends
		last = match List.last(data) {
			Ok(l) => l
			Err(_) => { ctl: 0.0, atl: 0.0, tsb: 0.0, tss: 0.0 }
		}
		ex2 = I32.to_f32(win_w) - pad_r + 8.0
		List.for_each!(model.ends, |e| {
			v = if e.sel == 0 last.ctl else if e.sel == 1 last.atl else last.tsb
			col = if e.sel == 0 ctl_c else if e.sel == 1 atl_c else tsb_c
			e.p.draw!(frame, { pos: { x: ex2, y: yf(v) - 7.0 }, color: col, align: (Top, Left) })
		})

		# hover: nearest day gets a crosshair + dots (readout printed at top-right)
		if model.mouse_in and model.mouse_x >= pad_l and model.mouse_x <= I32.to_f32(win_w) - pad_r {
			frac = (model.mouse_x - pad_l) / pw
			hi_idx = n - 1
			raw = frac * U64.to_f32(hi_idx)
			hovered = clamp_idx(raw, hi_idx)
			hx = xf(hovered)
			frame.line!({ start: { x: hx, y: pad_t }, end: { x: hx, y: pad_t + ph }, stroke: Draw.stroke(Color.with_alpha(Color.white, 60), 1) })
			match List.get(data, hovered) {
				Ok(hp) => {
					frame.circle!({ center: { x: hx, y: yf(hp.ctl) }, radius: 3.5, style: Draw.filled(ctl_c) })
					frame.circle!({ center: { x: hx, y: yf(hp.atl) }, radius: 3.5, style: Draw.filled(atl_c) })
					frame.circle!({ center: { x: hx, y: yf(hp.tsb) }, radius: 3.5, style: Draw.filled(tsb_c) })
				}
				Err(_) => {}
			}
		} else {}

		model.hint.draw!(frame, { pos: { x: 34.0, y: I32.to_f32(win_h) - 30.0 }, color: ink_faint, align: (Top, Left) })
		Ok({})
	}
}
