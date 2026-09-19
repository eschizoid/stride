DisplayScale :: [].{
	default_percent : I64
	default_percent = 150
	min_width : I32
	min_width = 980
	min_height : I32
	min_height = 600

	adjust : I64, [Larger, Smaller, Reset, Keep] -> I64
	adjust = |percent, action|
		match action {
			Larger => I64.min(200, percent + 25)
			Smaller => I64.max(100, percent - 25)
			Reset => default_percent
			Keep => percent
		}

	# Drawing and hit-testing share logical coordinates. Fit the requested
	# scale to the minimum layout so resizing cannot hide the navigation.
	layout : I64, { w : F32, h : F32 } -> { scale : F32, w : F32, h : F32 }
	layout = |percent, pixels| {
		available = F32.min(pixels.w / I32.to_f32(min_width), pixels.h / I32.to_f32(min_height))
		scale = F32.max(1.0, F32.min(I64.to_f32(percent) / 100.0, available))
		{ scale, w: pixels.w / scale, h: pixels.h / scale }
	}

	point : { x : F32, y : F32 }, F32 -> { x : F32, y : F32 }
	point = |p, scale| { x: p.x / scale, y: p.y / scale }
}

expect DisplayScale.adjust(200, Larger) == 200
expect DisplayScale.adjust(100, Smaller) == 100
expect DisplayScale.adjust(150, Larger) == 175
expect DisplayScale.adjust(175, Smaller) == 150
expect DisplayScale.adjust(200, Reset) == 150
expect DisplayScale.adjust(125, Keep) == 125
expect {
	l = DisplayScale.layout(150, { w: 1470, h: 900 })
	(l.scale - 1.5).abs() < 0.001 and (l.w - 980).abs() < 0.001 and (l.h - 600).abs() < 0.001
}
expect {
	l = DisplayScale.layout(200, { w: 1470, h: 900 })
	(l.scale - 1.5).abs() < 0.001
}
expect {
	l = DisplayScale.layout(150, { w: 980, h: 600 })
	(l.scale - 1).abs() < 0.001
}
expect {
	l = DisplayScale.layout(200, { w: 1960, h: 750 })
	(l.scale - 1.25).abs() < 0.001 and (l.h - 600).abs() < 0.001
}
expect {
	l = DisplayScale.layout(200, { w: 1225, h: 1200 })
	(l.scale - 1.25).abs() < 0.001 and (l.w - 980).abs() < 0.001
}
expect {
	# The same point hits the same button at every supported zoom.
	List.all([1.0, 1.25, 1.5, 1.75, 2.0], |scale| {
		p = DisplayScale.point({ x: 420 * scale, y: 75 * scale }, scale)
		(p.x - 420).abs() < 0.001 and (p.y - 75).abs() < 0.001
	})
}
