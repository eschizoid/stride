Wrap :: [].{
	# Word wrap for the window's prose. A card or a cell has a width in
	# monospace columns; a string longer than that wraps into more lines and,
	# past the lines its view budgeted, ends in an ellipsis. The surfaces that
	# wrap or cut the athlete's own words (activity names in the form board's
	# card and the table's session column, the coach's prescription in the
	# plan card) go through here, so one rule decides what gets cut.

	# greedy word wrap: every line at most n bytes, except a single code
	# point wider than n, which is taken whole so the split makes progress.
	# Words are kept whole where they fit and split at a code point boundary
	# where they do not, so a device-written token with no spaces still
	# stays inside its column. Bytes stand in for columns: a multi-byte name
	# wraps early, never past the edge. A run of spaces is one separator, and
	# a leading or trailing run is dropped.
	wrap : Str, U64 -> List(Str)
	wrap = |s, n| {
		words = List.keep_if(Str.split_on(s, " "), |w| w != "")
		pieces = List.keep_if(List.join_map(words, |w| chunk(w, n)), |p| p != "")
		folded = List.fold(pieces, { lines: [], cur: "" }, |acc, w|
			if acc.cur == "" { lines: acc.lines, cur: w }
			else if Str.count_utf8_bytes(acc.cur) + 1 + Str.count_utf8_bytes(w) <= n { lines: acc.lines, cur: "${acc.cur} ${w}" }
			else { lines: List.append(acc.lines, acc.cur), cur: w })
		if folded.cur == "" folded.lines else List.append(folded.lines, folded.cur)
	}

	# a word as pieces of at most n bytes, each ending on a code point
	# boundary, except a first code point wider than n, which is taken whole;
	# n of 0 reads as 1 so the split always makes progress. The split can
	# leave an empty last piece, which wrap drops.
	chunk : Str, U64 -> List(Str)
	chunk = |w, n| {
		bytes = Str.to_utf8(w)
		step = if n == 0 1 else n
		if List.len(bytes) <= step [w]
		else {
			at0 = boundary(bytes, step)
			# a first code point wider than the budget is taken whole: a
			# line must carry at least one glyph to make progress
			at = if at0 == 0 (first_point_len(bytes)) else at0
			List.prepend(chunk(Str.from_utf8_lossy(List.drop_first(bytes, at)), step), Str.from_utf8_lossy(List.take_first(bytes, at)))
		}
	}

	# the largest cut at or before `at`, an index into `bytes`, that does not
	# land inside a code point: a UTF-8 continuation byte has its top two
	# bits set to 10, so the cut backs off past every one of them, down to 0
	# when the first code point alone is wider than `at`
	boundary : List(U8), U64 -> U64
	boundary = |bytes, at|
		List.fold(List.map_with_index(List.repeat({}, at + 1), |_u, k| at - k), at + 1, |acc, i|
			if acc != at + 1 acc
			else if i == 0 0
			else match List.get(bytes, i) {
				Ok(b) => if b >= 128 and b < 192 acc else i
				Err(_) => i
			})

	# the UTF-8 lead-byte table: a code point is 1 byte below 0x80, 2 below
	# 0xE0, 3 below 0xF0, else 4
	first_point_len : List(U8) -> U64
	first_point_len = |bytes|
		match List.first(bytes) {
			Ok(b) => if b < 128 1 else if b < 224 2 else if b < 240 3 else 4
			Err(_) => 1
		}

	# monospace columns that fit a span of pixels at the given glyph advance;
	# floors at 24 so a tiny window still wraps instead of over-packing
	cols_for : F32, F32 -> U64
	cols_for = |px, adv|
		match F32.to_u64_try((px / adv).max(24.0)) { Ok(c) => c
			Err(_) => 24 }

	# the wrapped lines, at most k of them. Past the cap the last kept line
	# is cut on a code point boundary and ends in "...", still within its
	# columns when there are at least three, so the reader sees as much of
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
			lb = Str.to_utf8(last)
			cut = if List.len(lb) <= room last else Str.from_utf8_lossy(List.take_first(lb, boundary(lb, room)))
			List.append(List.drop_last(kept, 1), "${cut}...")
		}
	}
}

expect Wrap.wrap("", 10) == []
expect Wrap.wrap("one two three", 30) == ["one two three"]
expect Wrap.wrap("one two three", 7) == ["one two", "three"]
expect Wrap.wrap("abcdefghijkl", 5) == ["abcde", "fghij", "kl"]
expect Wrap.wrap("aa supercalifragilistic", 10) == ["aa", "supercalif", "ragilistic"]
expect Wrap.wrap("one  two ", 4) == ["one", "two"]
expect Wrap.wrap("Tréning à vélo", 5) == ["Trén", "ing", "à", "vélo"]
expect Wrap.cols_for(240.0, 6.7) == 35
expect Wrap.cols_for(220.0, 6.7) == 32
expect Wrap.cols_for(10.0, 6.7) == 24
expect Wrap.fit("one two three four", 9, 4) == ["one two", "three", "four"]
expect Wrap.fit("one two three four", 9, 2) == ["one two", "three..."]
expect Wrap.fit("one two three four", 9, 0) == ["one tw..."]
expect Wrap.fit("Maybe overtraining time trial", 24, 1) == ["Maybe overtraining ti..."]
expect Wrap.fit("supercalifragilistic", 10, 1) == ["superca..."]
expect Wrap.fit("abcdeéf ghij", 9, 1) == ["abcde..."]
expect Wrap.fit("a b", 2, 1) == ["..."]
