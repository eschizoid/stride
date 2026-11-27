# stride-core: the words a new athlete is never shown bare.
#
# Both surfaces write for an athlete who knows training but not stride's
# insides. An internal term (a table, a protocol, a scoring step) or an
# acronym with no plain word beside it reads as noise to that athlete, so
# the terms below never stand bare in text either surface shows. One list and
# one matcher serve every guard: the window's label gate runs `bare` over
# every placed text, and each app's source guard runs `findings` over the
# string literals of the modules that write its screens.
Words :: [].{
	# The internal terms, each in folded form: lower case, with every run of
	# characters other than letters, digits and `_` read as one space, so
	# "e/m/h" is the three words "e m h". A term matches only as whole words,
	# so "ctl" in "ctl_c" or "atl" in "atlas" never does.
	jargon : List(Str)
	jargon = [
		"ctl",
		"atl",
		"tsb",
		"rung",
		"rungs",
		"spine",
		"directive",
		"directives",
		"provenance",
		"priced",
		"unpriced",
		"tier",
		"bus",
		"self heal",
		"escape hatch",
		"lifecycle",
		"junk",
		"ladder",
		"aero eff",
		"r2",
		"e m h",
		"quest",
		"lvl",
		"polarized",
		"x cycles",
	]

	# The one place an acronym may stand: right after the plain word it
	# abbreviates, in parentheses, which is how a text shows its meaning.
	glosses : List(Str)
	glosses = ["fitness (ctl)", "fatigue (atl)", "form (tsb)"]

	# a text's words, folded as `jargon` states
	words : Str -> List(Str)
	words = |s| {
		folded = List.map(Str.to_utf8(s), |b| if (b >= 'A' and b <= 'Z') b + 32 else if ((b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_') b else ' ')
		List.keep_if(Str.split_on(Str.from_utf8_lossy(folded), " "), |w| w != "")
	}

	# whether `term`, folded, stands in the text as consecutive whole words
	names : Str, Str -> Bool
	names = |s, term| has_run(words(s), words(term))

	has_run : List(Str), List(Str) -> Bool
	has_run = |ws, t| {
		k = List.len(t)
		if (k == 0 or k > List.len(ws)) Bool.False else if (List.take_first(ws, k) == t) Bool.True else has_run(List.drop_first(ws, 1), t)
	}

	# the internal terms a text uses bare: every term it names once its
	# glosses are taken out
	bare : Str -> List(Str)
	bare = |s| {
		lowered = Str.from_utf8_lossy(List.map(Str.to_utf8(s), |b| if (b >= 'A' and b <= 'Z') b + 32 else b))
		plain = List.fold(glosses, lowered, |acc, g| Str.join_with(Str.split_on(acc, g), " "))
		ws = words(plain)
		List.keep_if(jargon, |t| has_run(ws, words(t)))
	}

	# ── string literals in Roc source ──────────────────────────────────────
	# The text of every string literal a module's code holds: a `${...}`
	# interpolation reads as one space and its own literals stand alone, a
	# multiline literal's `\\` lines join into one, and an escape reads as
	# the character it stands for. Comments, character literals, `expect`
	# blocks and SQL (a literal holding an upper-case statement keyword) hold
	# no text an athlete reads, so they are skipped.
	literals : Str -> List(Str)
	literals = |src| {
		code = Str.join_with(drop_expects(Str.split_on(src, "\n")), "\n")
		end = List.fold(Str.to_utf8(code), start_scan, step)
		done = if (end.ml) close_ml(end) else end
		List.keep_if(done.out, |l| !(is_sql(l)))
	}

	is_sql : Str -> Bool
	is_sql = |l| List.any(["SELECT", "INSERT INTO", "UPDATE ", "DELETE FROM", "CREATE ", "PRAGMA", "DROP "], |k| Str.contains(l, k))

	# the lines left once every `expect` is taken out: an expect line and
	# every line after it that is blank, indented deeper, or closes or
	# continues it at its own depth
	drop_expects : List(Str) -> List(Str)
	drop_expects = |lines|
		(
			List.fold(
				lines,
				{ kept: [], skip: Bool.False, depth: 0 },
				|acc, line| {
					d = indent(line)
					rest = Str.trim_start(line)
					inside = acc.skip and (rest == "" or d > acc.depth or (d == acc.depth and List.any(["}", ")", "]", "and ", "or "], |c| Str.starts_with(rest, c))))
					if inside {
						acc
					} else if Str.starts_with(rest, "expect ") or rest == "expect" {
						{ kept: acc.kept, skip: Bool.True, depth: d }
					} else {
						{ kept: List.append(acc.kept, line), skip: Bool.False, depth: 0 }
					}
				},
			)
		).kept

	indent : Str -> U64
	indent = |line| List.len(Str.to_utf8(line)) - List.len(Str.to_utf8(Str.trim_start(line)))

	# The scanner's state: `frames` holds the open literals and the
	# interpolations inside them, innermost last; an empty stack is code.
	Frame : [Lit(List(U8)), Interp(U64)]

	Scan : { frames : List(Frame), out : List(Str), comment : Bool, chr : Bool, esc : Bool, dollar : Bool, slash : Bool, ml : Bool, ml_gap : Bool, ml_buf : List(U8) }

	start_scan : Scan
	start_scan = { frames: [], out: [], comment: Bool.False, chr: Bool.False, esc: Bool.False, dollar: Bool.False, slash: Bool.False, ml: Bool.False, ml_gap: Bool.False, ml_buf: [] }

	close_ml : Scan -> Scan
	close_ml = |s| { ..s, out: List.append(s.out, Str.from_utf8_lossy(s.ml_buf)), ml: Bool.False, ml_gap: Bool.False, ml_buf: [] }

	escaped : U8 -> U8
	escaped = |b| if (b == 'n') '\n' else if (b == 't') '\t' else b

	step : Scan, U8 -> Scan
	step = |s, b|
		if s.ml {
			# a multiline literal runs to the line's end; the next line
			# carries it on when its first text is another `\\`
			if s.ml_gap {
				if s.slash {
					if (b == '\\') { ..s, slash: Bool.False, ml_gap: Bool.False, ml_buf: List.append(s.ml_buf, '\n') } else code_step({ ..close_ml(s), slash: Bool.False }, b)
				} else if b == '\\' {
					{ ..s, slash: Bool.True }
				} else if b == ' ' or b == '\t' or b == '\n' or b == '\r' {
					s
				} else {
					code_step(close_ml(s), b)
				}
			} else if b == '\n' {
				{ ..s, ml_gap: Bool.True }
			} else {
				{ ..s, ml_buf: List.append(s.ml_buf, b) }
			}
		} else {
			match List.last(s.frames) {
				Ok(Lit(buf)) => lit_step(s, buf, b)
				_ => code_step(s, b)
			}
		}

	# a byte inside a quoted literal
	lit_step : Scan, List(U8), U8 -> Scan
	lit_step = |s, buf, b| {
		top = |nb| List.append(List.drop_last(s.frames, 1), Lit(nb))
		if s.esc {
			{ ..s, esc: Bool.False, frames: top(List.append(buf, escaped(b))) }
		} else if s.dollar {
			if (b == '{') { ..s, dollar: Bool.False, frames: List.append(top(List.append(buf, ' ')), Interp(0)) } else lit_step({ ..s, dollar: Bool.False, frames: top(List.append(buf, '$')) }, List.append(buf, '$'), b)
		} else if b == '\\' {
			{ ..s, esc: Bool.True }
		} else if b == '$' {
			{ ..s, dollar: Bool.True }
		} else if b == '"' {
			{ ..s, frames: List.drop_last(s.frames, 1), out: List.append(s.out, Str.from_utf8_lossy(buf)) }
		} else {
			{ ..s, frames: top(List.append(buf, b)) }
		}
	}

	# a byte of code: top level, or inside an interpolation
	code_step : Scan, U8 -> Scan
	code_step = |s, b|
		if s.comment {
			if (b == '\n') { ..s, comment: Bool.False } else s
		} else if s.chr {
			if s.esc {
				{ ..s, esc: Bool.False }
			} else if b == '\\' {
				{ ..s, esc: Bool.True }
			} else if b == '\'' {
				{ ..s, chr: Bool.False }
			} else {
				s
			}
		} else if s.slash {
			if (b == '\\') { ..s, slash: Bool.False, ml: Bool.True, ml_gap: Bool.False, ml_buf: [] } else code_step({ ..s, slash: Bool.False }, b)
		} else if b == '#' {
			{ ..s, comment: Bool.True }
		} else if b == '\'' {
			{ ..s, chr: Bool.True }
		} else if b == '\\' {
			{ ..s, slash: Bool.True }
		} else if b == '"' {
			{ ..s, frames: List.append(s.frames, Lit([])) }
		} else {
			match List.last(s.frames) {
				Ok(Interp(d)) =>
					if b == '{' {
						{ ..s, frames: List.append(List.drop_last(s.frames, 1), Interp(d + 1)) }
					} else if b == '}' {
						if (d == 0) { ..s, frames: List.drop_last(s.frames, 1) } else { ..s, frames: List.append(List.drop_last(s.frames, 1), Interp(d - 1)) }
					} else {
						s
					}
				_ => s
			}
		}

	# every literal of a module's source that uses an internal term bare,
	# named by the module and the terms it uses
	findings : Str, Str -> List(Str)
	findings = |file, src|
		List.keep_oks(
			literals(src),
			|l| {
				found = bare(l)
				if (List.is_empty(found)) Err(Clean) else Ok("${file}: \"${l}\" uses ${Str.join_with(found, ", ")}")
			},
		)
}

expect Words.words("Fitness (CTL): 56, e/m/h") == ["fitness", "ctl", "56", "e", "m", "h"]
expect Words.bare("fitness (CTL): 56   fatigue (ATL): 70   form (TSB): -14") == []
expect Words.bare("+2.7 ctl in the last 7 days") == ["ctl"]
expect Words.bare("CTL 46.0") == ["ctl"]
expect Words.bare("trend r2 e/m/h") == ["r2", "e m h"]
expect Words.bare("spd/hr (aero-eff)") == ["aero eff"]
expect Words.bare("showing all sports (X cycles)") == ["x cycles"]
expect Words.bare("the ctl_c color in the atlas") == []
expect Words.bare("X changes the sport") == []
expect Words.names("120 TSS", "tss") and !(Words.names("tssx", "tss"))

# a literal's text, its interpolations read as a space, its escapes as the
# characters they stand for
expect Words.literals("x = \"fit \${y} \\\"now\\\"\"") == ["fit   \"now\""]
# an interpolation's own literal stands alone, and the outer one carries on
expect Words.literals("x = \"a \${if b \"yes\" else \"no\"} c\"") == ["yes", "no", "a   c"]
# comments, character literals, SQL and expect blocks hold no text
expect Words.literals("# \"ctl\"\nx = '\"'\ny = \"SELECT ctl FROM daily_load\"\nexpect f(\"ctl\")\nz = \"kept\"") == ["kept"]
expect Words.literals("expect {\n\ta = \"ctl\"\n\ta == b\n}\nz = \"kept\"") == ["kept"]
# a multiline literal's lines join into one
expect Words.literals("x =\n\t\\\\one\n\t\\\\two\ny = 1") == ["one\ntwo"]
expect Words.findings("M.roc", "a = \"fitness (CTL) 5\"\nb = \"hold 340 ctl\"") == ["M.roc: \"hold 340 ctl\" uses ctl"]
