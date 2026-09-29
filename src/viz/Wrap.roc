Wrap :: [].{
	# Word wrap for the window's prose. A card or a cell has a width in
	# monospace columns; a string longer than that wraps into more lines and,
	# past the lines its view budgeted, ends in an ellipsis. Every surface
	# that shows the athlete's own words (activity names, the coach's
	# prescription) goes through here, so one rule decides what gets cut.

	# greedy word wrap: every line at most n bytes, words never split (a word
	# longer than n gets its own overlong line). Bytes stand in for columns:
	# a multi-byte name wraps early, never past the edge.
	wrap : Str, U64 -> List(Str)
	wrap = |s, n| {
		words = Str.split_on(s, " ")
		folded = List.fold(words, { lines: [], cur: "" }, |acc, w|
			if acc.cur == "" { lines: acc.lines, cur: w }
			else if Str.count_utf8_bytes(acc.cur) + 1 + Str.count_utf8_bytes(w) <= n { lines: acc.lines, cur: "${acc.cur} ${w}" }
			else { lines: List.append(acc.lines, acc.cur), cur: w })
		if folded.cur == "" folded.lines else List.append(folded.lines, folded.cur)
	}

	# monospace columns that fit a span of pixels at the given glyph advance;
	# floors at 24 so a tiny window still wraps instead of over-packing
	cols_for : F32, F32 -> U64
	cols_for = |px, adv|
		match F32.to_u64_try((px / adv).max(24.0)) { Ok(c) => c
			Err(_) => 24 }

	# the wrapped lines, at most k of them. Past the cap the last kept line
	# ends in "..." and still fits its columns, so the reader sees as much of
	# the text as the view has room for and knows there is more. k of 0
	# reads as 1: a view always gets at least the one line it draws.
	fit : Str, U64, U64 -> List(Str)
	fit = |s, cols, k| {
		lines = wrap(s, cols)
		keep = if k == 0 1 else k
		if List.len(lines) <= keep lines
		else {
			kept = List.take_first(lines, keep)
			last = match List.last(kept) { Ok(l) => l
				Err(_) => "" }
			# bytes the last line may keep beside the three-dot tail
			room = if cols > 3 (cols - 3) else 0
			cut = if Str.count_utf8_bytes(last) <= room last else Str.from_utf8_lossy(List.take_first(Str.to_utf8(last), room))
			List.append(List.drop_last(kept, 1), "${cut}...")
		}
	}
}

expect Wrap.wrap("", 10) == []
expect Wrap.wrap("one two three", 30) == ["one two three"]
expect Wrap.wrap("one two three", 7) == ["one two", "three"]
expect Wrap.wrap("abcdefghijkl", 5) == ["abcdefghijkl"]
expect Wrap.cols_for(240.0, 6.6) == 36
expect Wrap.cols_for(10.0, 6.6) == 24
expect Wrap.fit("one two three four", 9, 4) == ["one two", "three", "four"]
expect Wrap.fit("one two three four", 9, 2) == ["one two", "three..."]
expect Wrap.fit("one two three four", 9, 0) == ["one tw..."]
expect Wrap.fit("Maybe overtraining time trial", 24, 1) == ["Maybe overtraining ti..."]
expect Wrap.fit("a b", 2, 1) == ["..."]
