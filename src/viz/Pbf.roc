Pbf :: [].{
	# ── a protocol buffer reader (pure) ────────────────────────────────────
	# A message is a run of fields. Each field opens with a key varint, the
	# field number times eight plus the wire type, and its value follows:
	# a varint (wire type 0), eight little-endian bytes (1), a length varint
	# and that many bytes (2), or four bytes (5). Types 3 and 4 are the
	# retired groups, which a vector tile never carries, so they read as
	# malformed. A varint carries seven bits per byte, least significant
	# first, and a byte below 128 ends it; ten bytes hold any 64-bit value.
	#
	# A reader never copies a payload: a field names its bytes by where they
	# start and how many there are, inside the list it was read from.

	# a field's number and wire type; for a varint its value, and for the
	# other types where its payload starts and how long it is
	Field : { num : U64, wire : U64, value : U64, start : U64, len : U64 }

	# the varint starting at `at`, and where the byte after it is; a run
	# that ends with the list, or passes ten bytes, is malformed
	varint : List(U8), U64 -> Try({ v : U64, next : U64 }, [Malformed])
	varint = |bytes, at| {
		var $v = 0
		var $mult = 1
		var $i = at
		var $state = 0
		while $state == 0 {
			match List.get(bytes, $i) {
				Ok(b) => {
					low = U8.to_u64(b % 128)
					n = $i - at
					# the tenth byte holds the one bit left of a 64-bit value
					$v = if (n < 9) $v + low * $mult else if (low % 2 == 1) $v + $mult else $v
					$mult = if (n < 9) $mult * 128 else $mult
					$i = $i + 1
					$state = if (b < 128) 1 else if (n >= 9) 2 else 0
				}
				Err(_) => {
					$state = 2
				}
			}
		}
		if ($state == 1) Ok({ v: $v, next: $i }) else Err(Malformed)
	}

	# a signed number stored zigzagged: 0, -1, 1, -2, 2 ... as 0, 1, 2, 3, 4
	zigzag : U64 -> I64
	zigzag = |n| {
		half = U64.to_i64_wrap(n // 2)
		if (n % 2 == 0) half else 0 - half - 1
	}

	# every field of the message held in bytes [start, start + len)
	fields : List(U8), U64, U64 -> Try(List(Field), [Malformed])
	fields = |bytes, start, len| {
		end = start + len
		var $at = start
		var $out = []
		var $bad = Bool.False
		while !$bad and $at < end {
			match varint(bytes, $at) {
				Err(_) => {
					$bad = Bool.True
				}
				Ok(k) => {
					num = k.v // 8
					wire = k.v % 8
					if wire == 0 {
						match varint(bytes, k.next) {
							Ok(val) => {
								$out = List.append($out, { num, wire, value: val.v, start: k.next, len: val.next - k.next })
								$at = val.next
							}
							Err(_) => {
								$bad = Bool.True
							}
						}
					} else if wire == 2 {
						match varint(bytes, k.next) {
							Ok(n) => {
								$out = List.append($out, { num, wire, value: 0, start: n.next, len: n.v })
								$at = n.next + n.v
							}
							Err(_) => {
								$bad = Bool.True
							}
						}
					} else if wire == 1 {
						$out = List.append($out, { num, wire, value: 0, start: k.next, len: 8 })
						$at = k.next + 8
					} else if wire == 5 {
						$out = List.append($out, { num, wire, value: 0, start: k.next, len: 4 })
						$at = k.next + 4
					} else {
						$bad = Bool.True
					}
				}
			}
		}
		if ($bad or $at > end or end > List.len(bytes)) Err(Malformed) else Ok($out)
	}

	# a packed repeated field: back-to-back varints filling its payload
	packed : List(U8), U64, U64 -> Try(List(U64), [Malformed])
	packed = |bytes, start, len| {
		end = start + len
		var $at = start
		var $out = List.with_capacity(len)
		var $bad = Bool.False
		while !$bad and $at < end {
			match varint(bytes, $at) {
				Ok(r) => {
					$out = List.append($out, r.v)
					$at = r.next
				}
				Err(_) => {
					$bad = Bool.True
				}
			}
		}
		if ($bad or $at != end) Err(Malformed) else Ok($out)
	}

	# a payload as text; bytes that are not UTF-8 become replacement marks
	text : List(U8), Field -> Str
	text = |bytes, f| Str.from_utf8_lossy(List.sublist(bytes, { start: f.start, len: f.len }))

	# whether a payload holds exactly these bytes
	is_bytes : List(U8), Field, List(U8) -> Bool
	is_bytes = |bytes, f, want| f.len == List.len(want) and List.sublist(bytes, { start: f.start, len: f.len }) == want
}

# one byte holds 0 to 127; 300 is 0xAC 0x02, and the reader names the byte
# after it
expect Pbf.varint([0x08], 0) == Ok({ v: 8, next: 1 }) and Pbf.varint([0xFF, 0xAC, 0x02, 0x00], 1) == Ok({ v: 300, next: 3 })

# the largest value takes ten bytes, and the tenth carries its top bit
expect Pbf.varint([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01], 0) == Ok({ v: 18446744073709551615, next: 10 })

# a run cut off by the end of the list, or longer than ten bytes, is malformed
expect Pbf.varint([0x80, 0x80], 0) == Err(Malformed) and Pbf.varint(List.append(List.repeat(0x80, 10), 0x01), 0) == Err(Malformed)

# zigzag interleaves the signs, so small magnitudes of either sign stay small
expect List.map([0, 1, 2, 3, 4, 4294967294, 4294967295], Pbf.zigzag) == [0, -1, 1, -2, 2, 2147483647, -2147483648]

# a message of a varint, a string, a fixed64 and a fixed32 reads as four
# fields, each payload located inside the message
expect {
	msg = [0x08, 0x96, 0x01, 0x12, 0x03, 0x61, 0x62, 0x63, 0x19, 1, 2, 3, 4, 5, 6, 7, 8, 0x25, 9, 9, 9, 9]
	match Pbf.fields(msg, 0, List.len(msg)) {
		Ok(fs) => List.map(fs, |f| { num: f.num, wire: f.wire }) == [{ num: 1, wire: 0 }, { num: 2, wire: 2 }, { num: 3, wire: 1 }, { num: 4, wire: 5 }]
			and List.map(fs, |f| f.len) == [2, 3, 8, 4] and List.map(fs, |f| f.start) == [1, 5, 9, 18]
			and (List.first(fs) ?? { num: 0, wire: 0, value: 0, start: 0, len: 0 }).value == 150
			and Pbf.text(msg, List.get(fs, 1) ?? { num: 0, wire: 0, value: 0, start: 0, len: 0 }) == "abc"
			and Pbf.is_bytes(msg, List.get(fs, 1) ?? { num: 0, wire: 0, value: 0, start: 0, len: 0 }, [0x61, 0x62, 0x63])
			and (List.get(fs, 2) ?? { num: 0, wire: 0, value: 0, start: 0, len: 0 }).start == 9
		Err(_) => Bool.False
	}
}

# a field reaching past the message, a group, and a dangling key are malformed
expect Pbf.fields([0x12, 0x05, 0x61], 0, 3) == Err(Malformed) and Pbf.fields([0x0B, 0x00], 0, 2) == Err(Malformed) and Pbf.fields([0x08], 0, 1) == Err(Malformed)

# a packed field is its varints back to back, and one cut short, or one
# whose last varint runs past its payload, is malformed
expect Pbf.packed([0x09, 0x96, 0x01, 0x03], 0, 4) == Ok([9, 150, 3]) and Pbf.packed([0x09, 0x96], 0, 2) == Err(Malformed) and Pbf.packed([0x09, 0x96, 0x01], 0, 2) == Err(Malformed)
