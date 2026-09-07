## Stride Form Board — a native window over the engine's PMC series, read LIVE
## from the stride SQLite (daily_load: day, ctl, atl, tsb). No baked data, no
## file: the app is a second consumer of the database, exactly as ADR 0015 says.
## Draws fitness (blue), fatigue (orange), form (green). ESC quits.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Color
import rr.Draw
import rr.Text
import rr.Sqlite

Point : { ctl : F32, atl : F32, tsb : F32 }

Model : { title : Text.Prepared, sub : Text.Prepared, data : List(Point), status : Str }

db_path : Str
db_path = "/Users/mariano/.stride/db.sqlite"

# window is I32 (Draw.with_size); plot geometry is F32.
win_w : I32
win_w = 980
win_h : I32
win_h = 600
pad_l : F32
pad_l = 60
pad_r : F32
pad_r = 74
pad_t : F32
pad_t = 104
pad_b : F32
pad_b = 44

program = { init!, update!, render! }

# Last 90 days of daily_load, oldest first. SQLite does the numeric boundary:
# values arrive as tenths in I64 (this compiler has no F64->F32 narrowing), and
# I64.to_f32 / 10 restores the one-decimal fidelity the board displays anyway.
load_series! : Sqlite.Db => Try(List(Point), Str)
load_series! = |db| {
	q = "SELECT day, CAST(ROUND(ctl*10) AS INTEGER) AS c10, CAST(ROUND(atl*10) AS INTEGER) AS a10, CAST(ROUND(tsb*10) AS INTEGER) AS t10 FROM (SELECT day, ctl, atl, tsb FROM daily_load ORDER BY day DESC LIMIT 90) ORDER BY day ASC"
	rows = Sqlite.query!({ db, query: q, bindings: [] }) ? |_| "query failed"
	List.map_try(rows, |r| {
		c = r.i64("c10") ? |_| "bad ctl"
		a = r.i64("a10") ? |_| "bad atl"
		t = r.i64("t10") ? |_| "bad tsb"
		Ok({ ctl: I64.to_f32(c) / 10.0, atl: I64.to_f32(a) / 10.0, tsb: I64.to_f32(t) / 10.0 })
	})
}

init! : App.Init(Model, [AssetPathInvalid, AssetNotFound, AssetReadFailed, FontLoadFailed, ResourceLimit])
init! = App.init(
	App.default
		.with_title("Stride Form Board")
		.with_size({ width: win_w, height: win_h })
		.with_frame_pacing(Capped(60))
		.with_default_font({ path: "examples/live_plot/assets/fonts/LiberationSans-Regular.ttf", size: 30 }),
	|startup| {
		font = startup.default_font!()?
		loaded = match Sqlite.Db.open!(db_path) {
			Ok(db) => match load_series!(db) {
				Ok(pts) => { data: pts, status: "" }
				Err(why) => { data: [], status: why }
			}
			Err(_) => { data: [], status: "cannot open " }
		}
		Ok({
			title: Text.from("Stride Form Board", font).size(30).prepare!()?,
			sub: Text.from("Fitness (blue)  -  Fatigue (orange)  -  Form (green)  -  last 90 days, live from stride", font).size(15).prepare!()?,
			data: loaded.data,
			status: loaded.status,
		})
	},
)

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input|
	if program_input.devices.key_pressed(KeyEscape) { Err(Exit(0)) } else { Ok(model) }

# min/max over the loaded data so the plot self-scales
lo_of : List(Point) -> F32
lo_of = |pts| List.fold(pts, 0.0, |acc, p| F32.min(acc, p.tsb)) - 6.0
hi_of : List(Point) -> F32
hi_of = |pts| List.fold(pts, 1.0, |acc, p| F32.max(acc, F32.max(p.ctl, p.atl))) + 8.0

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.rectangle!({ x: 0.0, y: 0.0, width: I32.to_f32(win_w), height: I32.to_f32(win_h), style: Draw.filled(Color.from_hex_rgb(0x14181d)) })
	frame.rounded_rectangle!({ x: 16.0, y: 16.0, width: I32.to_f32(win_w) - 32.0, height: I32.to_f32(win_h) - 32.0, radius: 14.0, segments: 10, style: Draw.filled(Color.from_hex_rgb(0x1b2129)) })

	model.title.draw!(frame, { pos: { x: 34.0, y: 30.0 }, color: Color.white, align: (Top, Left) })
	model.sub.draw!(frame, { pos: { x: 34.0, y: 66.0 }, color: Color.from_hex_rgb(0x8593a2), align: (Top, Left) })

	n = List.len(model.data)
	if n < 2 {
		Ok({})
	} else {
		lo = lo_of(model.data)
		hi = hi_of(model.data)
		span = hi - lo
		pw = I32.to_f32(win_w) - pad_l - pad_r
		ph = I32.to_f32(win_h) - pad_t - pad_b
		xf = |i| pad_l + pw * U64.to_f32(i) / U64.to_f32(n - 1)
		yf = |v| pad_t + ph * (1.0 - (v - lo) / span)

		# gridlines + y labels at 0/10/20/30/40/50
		List.for_each!([0.0, 10.0, 20.0, 30.0, 40.0, 50.0], |g| {
			gy = yf(g)
			frame.line!({ start: { x: pad_l, y: gy }, end: { x: I32.to_f32(win_w) - pad_r, y: gy }, stroke: Draw.stroke(Color.with_alpha(Color.white, 20), 1) })
		})
		# zero rule, brighter
		frame.line!({ start: { x: pad_l, y: yf(0.0) }, end: { x: I32.to_f32(win_w) - pad_r, y: yf(0.0) }, stroke: Draw.stroke(Color.with_alpha(Color.white, 55), 1) })

		ctl_c = Color.from_hex_rgb(0x3987e5)
		atl_c = Color.from_hex_rgb(0xd95926)
		tsb_c = Color.from_hex_rgb(0x199e70)

		# area fill under fitness
		List.for_each!(List.map_with_index(model.data, |p, i| { i, v: p.ctl }), |cur|
			match List.get(model.data, cur.i + 1) {
				Ok(_) => frame.rectangle!({ x: xf(cur.i), y: yf(cur.v), width: (pw / U64.to_f32(n - 1)) + 1.0, height: yf(0.0) - yf(cur.v), style: Draw.filled(Color.with_alpha(ctl_c, 22)) })
				Err(_) => {}
			})

		draw_line! = |sel, col| {
			pts = List.map_with_index(model.data, |p, i| { i, v: sel(p) })
			List.for_each!(pts, |cur|
				match List.get(pts, cur.i + 1) {
					Ok(nxt) => frame.line!({ start: { x: xf(cur.i), y: yf(cur.v) }, end: { x: xf(nxt.i), y: yf(nxt.v) }, stroke: Draw.stroke(col, 2) })
					Err(_) => {}
				})
		}
		draw_line!(|p| p.tsb, tsb_c)
		draw_line!(|p| p.atl, atl_c)
		draw_line!(|p| p.ctl, ctl_c)
		Ok({})
	}
}
