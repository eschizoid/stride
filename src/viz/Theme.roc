import rr.Color

Theme :: [].{
	# window geometry — every view maps through the same paddings
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

	# the stride brand palette: near-black ground, blue fitness, violet fatigue,
	# teal form (the logo triad's accent)
	bg : Color.Rgba
	bg = Color.from_hex_rgb(0x0b0b0e)
	panel : Color.Rgba
	panel = Color.from_hex_rgb(0x131318)
	card : Color.Rgba
	card = Color.from_hex_rgb(0x1b1b22)
	ink_muted : Color.Rgba
	ink_muted = Color.from_hex_rgb(0x8593a2)
	ink_faint : Color.Rgba
	ink_faint = Color.from_hex_rgb(0x4d5a68)
	ctl_c : Color.Rgba
	ctl_c = Color.from_hex_rgb(0x4f8ef7)
	atl_c : Color.Rgba
	atl_c = Color.from_hex_rgb(0xa66bfa)
	tsb_c : Color.Rgba
	tsb_c = Color.from_hex_rgb(0x2dd4bf)
}
