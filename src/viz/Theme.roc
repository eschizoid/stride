import rr.Color
import core.Sports

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
	# each hue holds clear of ALL FIVE ramp stops - grey (0x4d5a68), blue
	# (0x4f8ef7), teal (0x2dd4bf), tan (0xd8c27a) and red (0xe0645b): warm
	# orange, violet, spring green, magenta-pink, orchid, indigo, sienna,
	# olive - so no sport reads as a zone. The tan stop is why there is no
	# gold/amber here: that hue is the ramp's, so a sport must not wear it.
	sport_palette : List(Color.Rgba)
	sport_palette = [
		Color.from_hex_rgb(0xf2994a),
		Color.from_hex_rgb(0x9b6cff),
		Color.from_hex_rgb(0x54c98a),
		Color.from_hex_rgb(0xe86ab0),
		Color.from_hex_rgb(0xc678dd),
		Color.from_hex_rgb(0x6a5acd),
		Color.from_hex_rgb(0xb07d55),
		Color.from_hex_rgb(0x8a9a3b),
	]

	# a stable colour for a sport, from a hash of its NAME (byte sum) into the
	# palette — position-independent, so reordering the bar never re-colours a
	# sport, and the same sport matches across views. `sport_palette` is a
	# non-empty literal, so `h % 8` is always in range; the Err arm is the
	# type-required fallback for List.get, not a reachable branch.
	sport_color : Str -> Color.Rgba
	sport_color = |sport| {
		# the FAMILY'S position in the shared sports table, not a hash of the
		# name: the table has six rows against eight colours, so every family
		# the engine knows gets a distinct one. A byte-sum hash does not - it
		# put Ride and WeightTraining on the same colour, which is the two
		# sports a mixed athlete trains most. Position here is the table's own
		# order, fixed in source, so it is stable across renders in a way the
		# BAR's order (which sorts by volume) is not.
		canon = Sports.canonical(sport)
		rows = List.map_with_index(Sports.families, |f, i| { f, i })
		slot = match List.first(List.keep_if(rows, |x| List.contains(x.f.sports, canon))) {
			Ok(x) => x.i
			# a sport with no family row is its own population, and it takes
			# only the slots BEYOND the families' own: hashing it across the
			# whole palette would let Yoga or Crossfit wear Ride's colour,
			# which is the collision this function exists to prevent, moved
			# rather than removed. Unknowns may still collide with each other.
			# The spare range is the palette minus the table; keep the palette
			# longer than `Sports.families` or there is nowhere safe to put them.
			Err(_) => {
				h = List.fold(Str.to_utf8(sport), 0, |a, b| a + U8.to_u64(b))
				nfam = List.len(Sports.families)
				nfam + (h % (List.len(sport_palette) - nfam))
			}
		}
		match List.get(sport_palette, slot % List.len(sport_palette)) {
			Ok(c) => c
			Err(_) => ink_faint
		}
	}

	# every sport's colour is a palette member (never the ink_faint fallback,
	# which no in-range index reaches), and the map is FAMILY-keyed, so it is
	# stable across calls and across any reordering of what is drawn
	expect List.contains(sport_palette, sport_color("Ride"))
	expect List.contains(sport_palette, sport_color("WeightTraining"))

	# an unrecognised sport never wears a known family's colour: it draws from
	# the slots past the table's end
	expect sport_color("Yoga") != sport_color("Ride")
	expect sport_color("Crossfit") != sport_color("WeightTraining")
	expect List.contains(sport_palette, sport_color("Yoga"))

	# DISTINCT families get distinct colours - the property a byte-sum hash
	# did not hold, and the pair below is the one it collided on
	expect sport_color("Ride") != sport_color("WeightTraining")
	expect sport_color("Rowing") != sport_color("Ride")
	expect sport_color("Rowing") != sport_color("WeightTraining")
	expect sport_color("Run") != sport_color("Ride")

	# a family's members share its colour, so a Workout and a WeightTraining
	# session read as the same sport wherever both appear
	expect sport_color("Workout") == sport_color("WeightTraining")
	expect sport_color("GravelRide") == sport_color("Ride")
}
