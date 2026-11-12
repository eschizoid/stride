import rr.Color
import rr.Draw
import Labels
import Scene
import Theme

Scroll :: [].{
	# A list taller than its room scrolls a whole row at a time. Its state is
	# one offset, the index of the first row drawn, kept between 0 and the
	# last offset at which the list's final row still shows, so a scroll can
	# never run past either end. Rows may differ in height: `last_offset`
	# reads them from the end, and `shown` counts how many fit from an offset.

	# the offset after `delta` rows (negative scrolls up), clamped to [0, last]
	step : U64, I64, U64 -> U64
	step = |off, delta, last| {
		moved = (U64.to_i64_try(off) ?? 0) + delta
		if (moved <= 0) 0 else (I64.to_u64_try(moved) ?? 0).min(last)
	}

	# the largest offset that still ends on the final row: the first row from
	# which every remaining row fits in `room`; 0 when the whole list fits
	last_offset : List(F32), F32 -> U64
	last_offset = |heights, room| {
		n = List.len(heights)
		walk = List.fold_rev(heights, { used: 0.0, first: n, open: Bool.True }, |h, acc|
			if (acc.open and acc.used + h <= room) { used: acc.used + h, first: acc.first - 1, open: Bool.True } else { ..acc, open: Bool.False })
		if (walk.first >= n) (if (n == 0) 0 else n - 1) else walk.first
	}

	# how many rows starting at `off` fit in `room`, at least one when any remain
	shown : List(F32), U64, F32 -> U64
	shown = |heights, off, room| {
		rest = List.drop_first(heights, off)
		fit = List.fold(rest, { used: 0.0, n: 0, open: Bool.True }, |acc, h|
			if (acc.open and acc.used + h <= room) { used: acc.used + h, n: acc.n + 1, open: Bool.True } else { ..acc, open: Bool.False })
		if (fit.n == 0 and !(List.is_empty(rest))) 1 else fit.n
	}

	# the edge hints: rows hidden above the first shown and below the last
	hidden : U64, U64, U64 -> { above : U64, below : U64 }
	hidden = |off, n_shown, total| { above: off.min(total), below: total - (off + n_shown).min(total) }

	# the thumb of a scrollbar `track` tall: its top and height, in the
	# proportion of the rows shown, never shorter than 12
	thumb : F32, U64, U64, U64 -> { y : F32, h : F32 }
	thumb = |track, off, n_shown, total|
		if (total == 0) { y: 0.0, h: track } else {
			h = (track * U64.to_f32(n_shown) / U64.to_f32(total)).max(12.0).min(track)
			y = (track - h) * (if (total <= n_shown) 0.0 else U64.to_f32(off) / U64.to_f32(total - n_shown))
			{ y, h }
		}

	# the scrollbar on the list's right edge; nothing at all when the list
	# fits
	draw! : Draw.Frame, { x : F32, top : F32, bottom : F32, hint_x : F32 }, U64, U64, U64 => {}
	draw! = |frame, at, off, n_shown, total| {
		h = hidden(off, n_shown, total)
		if (h.above == 0 and h.below == 0) {} else {
			track = at.bottom - at.top
			t = thumb(track, off, n_shown, total)
			frame.rounded_rectangle!({ x: at.x, y: at.top, width: 3.0, height: track, radius: 1.5, segments: 4, style: Draw.filled(Color.with_alpha(Theme.ink_faint, 60)) })
			frame.rounded_rectangle!({ x: at.x, y: at.top + t.y, width: 3.0, height: t.h, radius: 1.5, segments: 4, style: Draw.filled(Theme.ink_muted) })
		}
	}

	# the `N more above` / `N more below` hints at the list's top and bottom
	# edges, as fixed text in the region given
	hints : Scene.Measure, { x : F32, top : F32, bottom : F32, hint_x : F32 }, U64, U64, U64, Labels.Rect -> List(Labels.Label(Scene.Item))
	hints = |measure, at, off, n_shown, total, region| {
		h = hidden(off, n_shown, total)
		line = |n, word, y| if (n > 0) [Scene.fixed(measure, Scene.data("${U64.to_str(n)} more ${word}", 10.0, Theme.ink_faint), { x: at.hint_x, y, align: Left }, region)] else []
		List.concat(line(h.above, "above", at.top - 14.0), line(h.below, "below", at.bottom + 2.0))
	}
}

# a step never leaves [0, last]
expect Scroll.step(0, -3, 10) == 0 and Scroll.step(9, 3, 10) == 10 and Scroll.step(4, 1, 10) == 5 and Scroll.step(4, -1, 10) == 3
# equal rows: 20 rows of 26 in room for 7 end on offset 13; a list that fits never scrolls
expect Scroll.last_offset(List.repeat(26.0, 20), 182.0) == 13 and Scroll.last_offset(List.repeat(26.0, 5), 182.0) == 0
# uneven rows count from the end: the last two (30 + 40) fit in 75, the third does not
expect Scroll.last_offset([50.0, 20.0, 30.0, 40.0], 75.0) == 2
# rows shown from an offset, and at least one when a row is taller than the room
expect Scroll.shown(List.repeat(26.0, 20), 0, 182.0) == 7 and Scroll.shown(List.repeat(26.0, 20), 15, 182.0) == 5 and Scroll.shown([300.0], 0, 182.0) == 1
# the hints count what is cut at each edge, and vanish when all rows show
expect Scroll.hidden(3, 7, 20) == { above: 3, below: 10 } and Scroll.hidden(0, 5, 5) == { above: 0, below: 0 }
# the thumb sits at the top at offset 0 and at the bottom at the last offset
expect {
	top = Scroll.thumb(140.0, 0, 7, 20)
	bot = Scroll.thumb(140.0, 13, 7, 20)
	top.y == 0.0 and top.h == 49.0 and bot.y == 91.0
}
