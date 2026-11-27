# stride-core: the words a new athlete is never shown bare.
#
# Both surfaces write for an athlete who knows training but not stride's
# insides. An internal term (a table, a protocol, a scoring step) or an
# acronym with no plain word beside it reads as noise to that athlete, so
# the terms below never stand bare in text either surface shows. One list and
# one matcher serve every guard: the window's label gate runs `bare` over
# every placed text, and each app's source guard runs `findings` over the
# string literals of every module that writes its words.
Words :: [].{
	# The internal terms, each in folded form: lower case, with every run of
	# characters other than letters, digits and `_` read as one space, so
	# "e/m/h" is the three words "e m h", and a superscript two read as the
	# digit, so "R²" is "r2". A term matches only as whole words, so "ctl" in
	# "ctl_c" or "atl" in "atlas" never does; each of its words also matches
	# its inflected forms (`forms`), so "quests" and "self-healing" do.
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
		sup = Str.join_with(Str.split_on(s, "²"), "2")
		folded = List.map(Str.to_utf8(sup), |b| if (b >= 'A' and b <= 'Z') b + 32 else if ((b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_') b else ' ')
		List.keep_if(Str.split_on(Str.from_utf8_lossy(folded), " "), |w| w != "")
	}

	# whether `term`, folded, stands in the text as consecutive whole words
	names : Str, Str -> Bool
	names = |s, term| has_run(words(s), words(term))

	# the forms a term's word stands for in a text: itself, its plural, and
	# its -ing and -ed forms, with a final "e" dropped before those suffixes
	forms : Str -> List(Str)
	forms = |w| {
		stem = if (Str.ends_with(w, "e")) Str.from_utf8_lossy(List.drop_last(Str.to_utf8(w), 1)) else w
		[w, "${w}s", "${w}es", "${stem}ing", "${stem}ed", "${w}d"]
	}

	has_run : List(Str), List(Str) -> Bool
	has_run = |ws, t| {
		k = List.len(t)
		if (k == 0 or k > List.len(ws)) Bool.False
		else if (List.all(List.map2(List.take_first(ws, k), t, |w, tw| List.contains(forms(tw), w)), |ok| ok)) Bool.True
		else has_run(List.drop_first(ws, 1), t)
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
	# blocks, import lines, SQL (a literal holding an upper-case statement
	# keyword), the columns a row decoder reads and SQL bind names hold no
	# text an athlete reads, so they are skipped.
	literals : Str -> List(Str)
	literals = |src| {
		code = Str.join_with(List.drop_if(drop_expects(Str.split_on(src, "\n")), |l| Str.starts_with(l, "import ")), "\n")
		end = List.fold(Str.to_utf8(code), start_scan, step)
		done = if (end.ml) close_ml(end) else end
		List.keep_if(done.out, |l| !(is_sql(l)) and !(is_bind(l)))
	}

	# A literal a row decoder reads a column by, a JSON reader reads a key by,
	# or a SQL bind name names a field, never text: the decoders are the
	# platform's typed readers (`Sql.f64("ctl")`, `r.i64("hr")`), a JSON
	# reader is any function whose name starts `json_` (`json_number(r,
	# "date")`, `json_f64("ctl")`), and a bind name is a colon and a
	# column-like word (`":ctl"`).
	decoder_arg : List(U8) -> Bool
	decoder_arg = |tail| {
		t = Str.from_utf8_lossy(tail)
		List.any(["str", "i64", "f64", "u64", "i32", "f32", "bool", "bytes", "nullable_str", "nullable_i64", "nullable_f64"], |d| Str.ends_with(t, ".${d}(")) or json_reader(t)
	}

	# code that ends in a call to a `json_` function, the literal its first
	# argument or its second after one name
	json_reader : Str -> Bool
	json_reader = |t|
		match List.last(Str.split_on(t, "json_")) {
			Ok(p) if p != t => {
				rest = List.drop_if(Str.to_utf8(p), |b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_' or b == '.')
				rest == ['('] or rest == ['(', ',']
			}
			_ => Bool.False
		}

	is_bind : Str -> Bool
	is_bind = |l|
		match Str.to_utf8(l) {
			[':', .. as rest] => !(List.is_empty(rest)) and List.all(rest, |b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_')
			_ => Bool.False
		}

	is_sql : Str -> Bool
	is_sql = |l| List.any(["SELECT", "INSERT ", "UPDATE ", "DELETE FROM", "CREATE ", "PRAGMA", "DROP "], |k| Str.contains(l, k))

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

	Scan : { frames : List(Frame), out : List(Str), tail : List(U8), comment : Bool, chr : Bool, esc : Bool, dollar : Bool, slash : Bool, ml : Bool, ml_gap : Bool, ml_buf : List(U8) }

	start_scan : Scan
	start_scan = { frames: [], out: [], tail: [], comment: Bool.False, chr: Bool.False, esc: Bool.False, dollar: Bool.False, slash: Bool.False, ml: Bool.False, ml_gap: Bool.False, ml_buf: [] }

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
			{ ..s, frames: List.drop_last(s.frames, 1), out: if (List.first(buf) == Ok(1)) s.out else List.append(s.out, Str.from_utf8_lossy(buf)) }
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
			{ ..s, frames: List.append(s.frames, Lit(if (decoder_arg(s.tail)) [1] else [])) }
		} else {
			kept = if (b == ' ' or b == '\t' or b == '\n' or b == '\r') s.tail else List.append(List.take_last(s.tail, 23), b)
			t = { ..s, tail: kept }
			match List.last(t.frames) {
				Ok(Interp(d)) =>
					if b == '{' {
						{ ..t, frames: List.append(List.drop_last(t.frames, 1), Interp(d + 1)) }
					} else if b == '}' {
						if (d == 0) { ..t, frames: List.drop_last(t.frames, 1) } else { ..t, frames: List.append(List.drop_last(t.frames, 1), Interp(d - 1)) }
					} else {
						t
					}
				_ => t
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
# a term's inflected forms and a superscript two are the term
expect Words.bare("two quests, three tiers") == ["tier", "quest"]
expect Words.bare("ladders on the buses") == ["bus", "ladder"]
expect Words.bare("a self-healing sync") == ["self heal"]
expect Words.bare("fit R² 0.84") == ["r2"]
expect Words.bare("the directives lifecycles") == ["directive", "directives", "lifecycle"]
expect Words.bare("a bushel of tiered rungs") == ["rung", "rungs", "tier"]
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
# a column a row decoder reads and a bind name are names, not text
expect Words.literals("a = Sql.f64(\"ctl\")(cols)(stmt)\nb = r.i64( \"tsb\" )\nc = { name: \":ctl\", value: x }\nd = \"ctl now\"") == ["ctl now"]
# ...and so is a key a json_ reader reads, while the text beside it stays
expect Words.literals("a = json_number(r, \"ctl\")\nb = json_f64(\"tsb\")\nc = Scene.data(\"ctl now\")") == ["ctl now"]
