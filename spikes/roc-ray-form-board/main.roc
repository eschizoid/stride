## SPIKE — Stride Form Board as a native RocRay window. Draws 90 days of the
## engine's PMC series (fitness/fatigue/form) that the coach normally renders to
## an artifact. Data is baked in for the spike; the real app reads it from the
## stride SQLite. See eschizoid/stride ADR 0015 / #372. ESC exits.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Color
import rr.Draw
import rr.Text

Point : { ctl : F32, atl : F32, tsb : F32 }

Model : { title : Text.Prepared, sub : Text.Prepared, data : List(Point) }

vw = 960
vh = 560
padl = 54
padr = 70
padt = 96
padb = 40

program = { init!, update!, render! }

init! : App.Init(Model, [AssetPathInvalid, AssetNotFound, AssetReadFailed, FontLoadFailed, ResourceLimit])
init! = App.init(
	App.default
		.with_title("Stride Form Board")
		.with_size({ width: vw, height: vh })
		.with_frame_pacing(Capped(60))
		.with_default_font({ path: "examples/live_plot/assets/fonts/LiberationSans-Regular.ttf", size: 30 }),
	|startup| {
		font = startup.default_font!()?
		Ok({
			title: Text.from("Stride Form Board", font).size(30).prepare!()?,
			sub: Text.from("Fitness, fatigue and form  -  90 days  -  Bike the Drive ridden", font).size(16).prepare!()?,
			data: [{ ctl: 22.8, atl: 30.4, tsb: -7.6 }, { ctl: 22.3, atl: 26.3, tsb: -4.0 }, { ctl: 21.8, atl: 22.8, tsb: -1.1 }, { ctl: 22.0, atl: 24.1, tsb: -2.1 }, { ctl: 21.9, atl: 23.3, tsb: -1.4 }, { ctl: 21.4, atl: 20.2, tsb: 1.2 }, { ctl: 22.1, atl: 24.1, tsb: -2.0 }, { ctl: 23.2, atl: 30.3, tsb: -7.1 }, { ctl: 22.7, atl: 26.3, tsb: -3.6 }, { ctl: 22.9, atl: 26.8, tsb: -4.0 }, { ctl: 23.6, atl: 30.5, tsb: -6.9 }, { ctl: 24.7, atl: 35.8, tsb: -11.1 }, { ctl: 24.1, atl: 31.0, tsb: -6.9 }, { ctl: 24.8, atl: 33.8, tsb: -9.1 }, { ctl: 25.2, atl: 35.1, tsb: -9.9 }, { ctl: 24.6, atl: 30.4, tsb: -5.8 }, { ctl: 24.8, atl: 30.6, tsb: -5.8 }, { ctl: 25.8, atl: 35.7, tsb: -9.9 }, { ctl: 25.2, atl: 31.0, tsb: -5.8 }, { ctl: 25.3, atl: 30.8, tsb: -5.5 }, { ctl: 26.5, atl: 36.8, tsb: -10.3 }, { ctl: 27.1, atl: 38.7, tsb: -11.7 }, { ctl: 26.5, atl: 33.6, tsb: -7.1 }, { ctl: 26.6, atl: 33.5, tsb: -6.9 }, { ctl: 26.4, atl: 31.6, tsb: -5.1 }, { ctl: 26.1, atl: 29.1, tsb: -3.0 }, { ctl: 26.3, atl: 30.0, tsb: -3.6 }, { ctl: 25.7, atl: 26.0, tsb: -0.2 }, { ctl: 26.7, atl: 31.3, tsb: -4.6 }, { ctl: 27.5, atl: 35.1, tsb: -7.7 }, { ctl: 26.8, atl: 30.4, tsb: -3.6 }, { ctl: 26.9, atl: 30.5, tsb: -3.6 }, { ctl: 27.4, atl: 32.9, tsb: -5.5 }, { ctl: 26.8, atl: 28.5, tsb: -1.8 }, { ctl: 27.9, atl: 34.5, tsb: -6.7 }, { ctl: 28.9, atl: 39.3, tsb: -10.4 }, { ctl: 28.7, atl: 37.2, tsb: -8.5 }, { ctl: 28.1, atl: 32.3, tsb: -4.2 }, { ctl: 29.0, atl: 37.1, tsb: -8.1 }, { ctl: 29.8, atl: 40.6, tsb: -10.7 }, { ctl: 29.9, atl: 39.5, tsb: -9.6 }, { ctl: 29.2, atl: 34.3, tsb: -5.1 }, { ctl: 30.2, atl: 39.5, tsb: -9.3 }, { ctl: 29.5, atl: 34.2, tsb: -4.7 }, { ctl: 30.6, atl: 39.9, tsb: -9.2 }, { ctl: 31.6, atl: 44.1, tsb: -12.5 }, { ctl: 30.9, atl: 38.3, tsb: -7.4 }, { ctl: 30.1, atl: 33.2, tsb: -3.0 }, { ctl: 31.2, atl: 38.8, tsb: -7.6 }, { ctl: 32.0, atl: 42.4, tsb: -10.4 }, { ctl: 31.3, atl: 36.8, tsb: -5.5 }, { ctl: 31.6, atl: 37.9, tsb: -6.3 }, { ctl: 32.6, atl: 42.5, tsb: -10.0 }, { ctl: 33.4, atl: 45.9, tsb: -12.5 }, { ctl: 32.6, atl: 39.8, tsb: -7.2 }, { ctl: 33.5, atl: 44.0, tsb: -10.5 }, { ctl: 33.8, atl: 44.2, tsb: -10.4 }, { ctl: 34.2, atl: 44.9, tsb: -10.7 }, { ctl: 33.4, atl: 38.9, tsb: -5.5 }, { ctl: 34.7, atl: 45.5, tsb: -10.8 }, { ctl: 35.3, atl: 47.7, tsb: -12.4 }, { ctl: 35.6, atl: 47.6, tsb: -12.0 }, { ctl: 35.8, atl: 47.4, tsb: -11.6 }, { ctl: 36.0, atl: 47.1, tsb: -11.0 }, { ctl: 36.2, atl: 46.5, tsb: -10.3 }, { ctl: 35.3, atl: 40.3, tsb: -5.0 }, { ctl: 35.4, atl: 40.0, tsb: -4.6 }, { ctl: 36.1, atl: 43.4, tsb: -7.2 }, { ctl: 37.2, atl: 48.5, tsb: -11.4 }, { ctl: 36.3, atl: 42.1, tsb: -5.8 }, { ctl: 37.3, atl: 46.7, tsb: -9.4 }, { ctl: 38.0, atl: 49.7, tsb: -11.7 }, { ctl: 37.1, atl: 43.1, tsb: -6.0 }, { ctl: 37.5, atl: 44.3, tsb: -6.9 }, { ctl: 38.3, atl: 47.9, tsb: -9.6 }, { ctl: 38.8, atl: 49.7, tsb: -10.9 }, { ctl: 37.9, atl: 43.1, tsb: -5.2 }, { ctl: 38.7, atl: 46.9, tsb: -8.2 }, { ctl: 39.1, atl: 47.8, tsb: -8.7 }, { ctl: 40.0, atl: 52.2, tsb: -12.2 }, { ctl: 40.4, atl: 52.3, tsb: -12.0 }, { ctl: 40.9, atl: 54.0, tsb: -13.0 }, { ctl: 41.2, atl: 54.0, tsb: -12.8 }, { ctl: 40.3, atl: 46.8, tsb: -6.6 }, { ctl: 40.3, atl: 46.4, tsb: -6.0 }, { ctl: 41.1, atl: 49.8, tsb: -8.7 }, { ctl: 41.7, atl: 52.3, tsb: -10.5 }, { ctl: 40.7, atl: 45.3, tsb: -4.6 }, { ctl: 40.7, atl: 44.4, tsb: -3.7 }, { ctl: 41.9, atl: 50.9, tsb: -8.9 }],
		})
	},
)

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input|
	if program_input.devices.key_pressed(KeyEscape) { Err(Exit(0)) } else { Ok(model) }

# Spike: fixed bounds covering this block's range (tsb floor ~ -13, ctl peak ~ 42).
# The real app computes these from the data.
plot_lo : F32
plot_lo = -18.0
plot_hi : F32
plot_hi = 52.0

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.rectangle!({ x: 0, y: 0, width: vw, height: vh, style: Draw.filled(Color.from_hex_rgb(0x14181d)) })
	frame.rounded_rectangle!({ x: 16, y: 16, width: vw - 32, height: vh - 32, radius: 14, segments: 10, style: Draw.filled(Color.from_hex_rgb(0x1b2129)) })

	n = List.len(model.data)
	span = plot_hi - plot_lo
	pw = U64.to_f32(vw - padl - padr)
	ph = U64.to_f32(vh - padt - padb)
	xf : U64 -> F32
	xf = |i| padl + pw * U64.to_f32(i) / U64.to_f32(n - 1)
	yf : F32 -> F32
	yf = |v| padt + ph * (1.0 - (v - plot_lo) / span)

	frame.line!({ start: { x: padl, y: yf(0.0) }, end: { x: vw - padr, y: yf(0.0) }, stroke: Draw.stroke(Color.with_alpha(Color.white, 40), 1) })

	ctl = Color.from_hex_rgb(0x3987e5)
	atl = Color.from_hex_rgb(0xd95926)
	tsb = Color.from_hex_rgb(0x199e70)

	draw! : (Point -> F32), Color.Rgba => Try({}, [Exit(I64), ..])
	draw! = |sel, col|
		List.for_each_try!(List.range({ start: At(0), end: Before(n - 1) }), |i| {
			a = List.get(model.data, i)?
			c = List.get(model.data, i + 1)?
			frame.line!({ start: { x: xf(i), y: yf(sel(a)) }, end: { x: xf(i + 1), y: yf(sel(c)) }, stroke: Draw.stroke(col, 2) })
			Ok({})
		})
	_ = draw!(|p| p.ctl, ctl)
	_ = draw!(|p| p.atl, atl)
	_ = draw!(|p| p.tsb, tsb)

	model.title.draw!(frame, { pos: { x: 34, y: 30 }, color: Color.white, align: (Top, Left) })
	model.sub.draw!(frame, { pos: { x: 34, y: 66 }, color: Color.from_hex_rgb(0x8593a2), align: (Top, Left) })
	Ok({})
}
