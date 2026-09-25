import rr.Color

Theme :: [].{
	# window geometry — every view maps through the same paddings
	win_w : I32
	win_w = 1470
	win_h : I32
	win_h = 900
	pad_l : F32
	pad_l = 64
	pad_r : F32
	pad_r = 86
	pad_t : F32
	pad_t = 110
	pad_b : F32
	# the hint line owns the last 30px of the window; the plot floor leaves
	# room for the x-axis labels above it
	pad_b = 56

	# the stride brand palette: near-black ground, blue fitness, violet fatigue,
	# teal form (the logo triad's accent)
	bg : Color.Rgba
	bg = Color.from_hex_rgb(0x0b0b0e)
	panel : Color.Rgba
	panel = Color.from_hex_rgb(0x131318)
	card : Color.Rgba
	card = Color.from_hex_rgb(0x1b1b22)
	ink_muted : Color.Rgba
	ink_muted = Color.from_hex_rgb(0xb1bccb)
	ink_faint : Color.Rgba
	ink_faint = Color.from_hex_rgb(0x8998aa)
	ctl_c : Color.Rgba
	ctl_c = Color.from_hex_rgb(0x4f8ef7)
	atl_c : Color.Rgba
	atl_c = Color.from_hex_rgb(0xa66bfa)
	tsb_c : Color.Rgba
	tsb_c = Color.from_hex_rgb(0x2dd4bf)
	# the ramp's hot end, reused wherever something broke a rule
	alarm_c : Color.Rgba
	alarm_c = Color.from_hex_rgb(0xe0645b)
	# the reward pair: gold for earned things (levels, records, a finished
	# week), ember under the gold wherever a flame burns
	gold_c : Color.Rgba
	gold_c = Color.from_hex_rgb(0xffc857)
	ember_c : Color.Rgba
	ember_c = Color.from_hex_rgb(0xff6b35)
	# the intensity ramp for time-in-zone bars: easy cool to hard hot
	zone_ramp : List(Color.Rgba)
	zone_ramp = [Color.from_hex_rgb(0x4d5a68), Color.from_hex_rgb(0x4f8ef7), Color.from_hex_rgb(0x2dd4bf), Color.from_hex_rgb(0xd8c27a), Color.from_hex_rgb(0xe0645b)]

	# sport IDENTITY colours, deliberately a DIFFERENT hue set from zone_ramp:
	# the composition bar used to recycle the intensity ramp by position, so a
	# colour meant "this sport" in one place and "hard effort" in another, and
	# two sports could share one colour. These are keyed to the sport NAME
	# (sport_color) so a sport wears the same colour every render, and the set
	# avoids the ramp's blue/teal/red so a reader never confuses the two scales.
	sport_palette : List(Color.Rgba)
	sport_palette = [
		Color.from_hex_rgb(0x5b8ff9),
		Color.from_hex_rgb(0xf2994a),
		Color.from_hex_rgb(0x9b8cff),
		Color.from_hex_rgb(0x54c98a),
		Color.from_hex_rgb(0xe86a92),
		Color.from_hex_rgb(0x39c0c8),
		Color.from_hex_rgb(0xc9a227),
		Color.from_hex_rgb(0xb07d55),
	]

	# a stable colour for a sport, from a hash of its NAME (byte sum) into the
	# palette — position-independent, so reordering the bar never re-colours a
	# sport, and the same sport matches across views. `sport_palette` is a
	# non-empty literal, so `h % 8` is always in range; the Err arm is the
	# type-required fallback for List.get, not a reachable branch.
	sport_color : Str -> Color.Rgba
	sport_color = |sport| {
		h = List.fold(Str.to_utf8(sport), 0, |a, b| a + U8.to_u64(b))
		match List.get(sport_palette, h % List.len(sport_palette)) {
			Ok(c) => c
			Err(_) => ink_faint
		}
	}

	# every sport's colour is a palette member (never the ink_faint fallback,
	# which no in-range index reaches), and the map is name-keyed so it is
	# stable across calls and reorderings
	expect List.contains(sport_palette, sport_color("Ride"))
	expect List.contains(sport_palette, sport_color("WeightTraining"))
}
