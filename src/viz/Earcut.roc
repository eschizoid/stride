Earcut :: [].{
	# ── polygon triangulation by ear clipping (pure) ───────────────────────
	# The window fills triangles and convex polygons only, so a lake or a
	# park arrives here as rings and leaves as triangles. Points are whole
	# tile units, and every test is exact integer arithmetic: a cross product
	# of two tile-sized vectors passes what an F32 holds exactly.
	#
	# A ring's orientation is the sign of twice its area, the sum of
	# x(i) y(i+1) - x(i+1) y(i) round the ring. With y pointing down, as on
	# screen and in a vector tile, a positive ring runs clockwise as drawn.
	# The outline is made positive and every hole negative, each hole is
	# joined to the outline by a two-way cut (a bridge) so that one ring
	# remains, and an ear (a corner whose triangle holds no other point) is
	# cut off until three points are left.

	P : { x : I64, y : I64 }

	# twice the signed area of a ring
	area2 : List(P) -> I64
	area2 = |ring| {
		n = List.len(ring)
		var $s = 0
		var $i = 0
		while $i < n {
			a = List.get(ring, $i) ?? { x: 0, y: 0 }
			b = List.get(ring, ($i + 1) % n) ?? { x: 0, y: 0 }
			$s = $s + a.x * b.y - b.x * a.y
			$i = $i + 1
		}
		$s
	}

	# which side of the line a -> b the point c lies: positive for a corner
	# that turns the way a positive ring turns
	cross : P, P, P -> I64
	cross = |a, b, c| (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)

	# whether p lies inside the positive triangle a b c or on its edge
	inside : P, P, P, P -> Bool
	inside = |a, b, c, p| cross(a, b, p) >= 0 and cross(b, c, p) >= 0 and cross(c, a, p) >= 0

	reversed : List(P) -> List(P)
	reversed = |ring| List.fold(ring, [], |acc, p| List.prepend(acc, p))

	# the ring turned so that its area has the sign wanted
	oriented : List(P), Bool -> List(P)
	oriented = |ring, positive| {
		a = area2(ring)
		if ((positive and a < 0) or (!positive and a > 0)) reversed(ring) else ring
	}

	# The hole joined to the ring by a cut from the hole's rightmost point
	# M. A ray from M due east meets the ring first at some edge; of that
	# edge's two ends the one further east is visible from M unless a ring
	# point lies inside the triangle M, the hit, that end, and then the
	# point inside seen at the smallest angle from the ray is. The ring then
	# runs out along the cut, round the hole, and back. A hole the ray never
	# meets the ring from lies outside it and is dropped.
	bridge : List(P), List(P) -> List(P)
	bridge = |ring, hole| {
		nr = List.len(ring)
		mi = List.fold(List.map_with_index(hole, |p, i| { p, i }), { p: { x: -9223372036854775807, y: 0 }, i: 0 }, |best, e| if (e.p.x > best.p.x) e else best)
		m = mi.p
		# the nearest crossing east of M, as a fraction num / den along x, kept
		# exact by comparing cross-multiplied
		var $hit = Err(NoHit)
		var $i = 0
		while $i < nr {
			a = List.get(ring, $i) ?? m
			b = List.get(ring, ($i + 1) % nr) ?? m
			if (a.y <= m.y and b.y > m.y) or (b.y <= m.y and a.y > m.y) {
				# x of the crossing = a.x + (m.y - a.y) (b.x - a.x) / (b.y - a.y)
				den = b.y - a.y
				num = a.x * den + (m.y - a.y) * (b.x - a.x)
				# normalise to a positive denominator
				nn = if (den < 0) 0 - num else num
				dd = if (den < 0) 0 - den else den
				if nn >= m.x * dd {
					closer = match $hit {
						Ok(h) => nn * h.dd < h.nn * dd
						Err(_) => Bool.True
					}
					if closer {
						$hit = Ok({ nn, dd, i: $i })
					}
				}
			}
			$i = $i + 1
		}
		match $hit {
			Err(_) => ring
			Ok(h) => {
				a = List.get(ring, h.i) ?? m
				b = List.get(ring, (h.i + 1) % nr) ?? m
				end = if (b.x > a.x) (h.i + 1) % nr else h.i
				pe = List.get(ring, end) ?? m
				# the hit itself, rounded east so the triangle never shrinks
				hx = I64.div_ceil_by(h.nn, h.dd)
				hp = { x: hx, y: m.y }
				# the triangle M, hit, end in positive order
				tri = if (cross(m, hp, pe) >= 0) { a: m, b: hp, c: pe } else { a: m, b: pe, c: hp }
				var $best = end
				var $best_t = { dx: pe.x - m.x, dy: (pe.y - m.y).abs() }
				var $j = 0
				while $j < nr {
					p = List.get(ring, $j) ?? m
					if $j != end and p.x > m.x and p != pe and inside(tri.a, tri.b, tri.c, p) {
						t = { dx: p.x - m.x, dy: (p.y - m.y).abs() }
						# a smaller angle from the ray: dy / dx lower, the nearer on a tie
						smaller = t.dy * $best_t.dx < $best_t.dy * t.dx or (t.dy * $best_t.dx == $best_t.dy * t.dx and t.dx < $best_t.dx)
						if smaller {
							$best = $j
							$best_t = t
						}
					}
					$j = $j + 1
				}
				pv = List.get(ring, $best) ?? m
				around = List.concat(List.drop_first(hole, mi.i), List.take_first(hole, mi.i + 1))
				List.join([List.take_first(ring, $best + 1), around, [pv], List.drop_first(ring, $best + 1)])
			}
		}
	}

	# the rightmost x of a ring, the order holes are joined in
	max_x : List(P) -> I64
	max_x = |ring| List.fold(ring, -9223372036854775807, |m, p| if (p.x > m) p.x else m)

	# The triangles of an outline and its holes, three points each, every
	# one negative: drawn with y down they run counter-clockwise, the order
	# the window's triangle fill keeps (it culls the other). Holes are joined
	# rightmost first, so a later cut never crosses an earlier hole. A
	# corner with no turn is dropped as it is met; a ring with no ear left,
	# which only a self-crossing ring can be, stops with the triangles found.
	triangulate : List(P), List(List(P)) -> List(P)
	triangulate = |outline, holes| {
		ordered = List.sort_with(List.map(holes, |h| oriented(h, Bool.False)), |a, b| if (max_x(a) > max_x(b)) Before else if (max_x(a) < max_x(b)) After else Same)
		ring = List.fold(ordered, oriented(outline, Bool.True), |r, h| if (List.len(h) < 3) r else bridge(r, h))
		clip(ring)
	}

	clip : List(P) -> List(P)
	clip = |ring| {
		n = List.len(ring)
		if n < 3 {
			[]
		} else {
			var $next = List.map_with_index(ring, |_, i| (i + 1) % n)
			var $prev = List.map_with_index(ring, |_, i| (i + n - 1) % n)
			var $left = n
			var $i = 0
			var $stall = 0
			var $out = List.with_capacity(3 * n)
			pt = |k| List.get(ring, k) ?? { x: 0, y: 0 }
			while $left > 3 and $stall <= $left {
				p = List.get($prev, $i) ?? 0
				q = List.get($next, $i) ?? 0
				a = pt(p)
				b = pt($i)
				c = pt(q)
				turn = cross(a, b, c)
				ear =
					if turn <= 0 {
						Bool.False
					} else {
						# no other point inside the triangle: walk the rest of the ring
						var $k = List.get($next, q) ?? 0
						var $clear = Bool.True
						while $clear and $k != p {
							v = pt($k)
							if v != a and v != b and v != c and inside(a, b, c, v) {
								$clear = Bool.False
							}
							$k = List.get($next, $k) ?? p
						}
						$clear
					}
				if turn == 0 or ear {
					if ear {
						$out = List.concat($out, [c, b, a])
					}
					$next = List.set($next, p, q) ?? []
					$prev = List.set($prev, q, p) ?? []
					$left = $left - 1
					$i = q
					$stall = 0
				} else {
					$i = q
					$stall = $stall + 1
				}
			}
			if $left == 3 {
				p = List.get($prev, $i) ?? 0
				q = List.get($next, $i) ?? 0
				a = pt(p)
				b = pt($i)
				c = pt(q)
				if (cross(a, b, c) > 0) List.concat($out, [c, b, a]) else $out
			} else {
				$out
			}
		}
	}

	# total twice-area of a triangle list, each triangle counted by size
	tri_area2 : List(P) -> I64
	tri_area2 = |ts| {
		List.fold(List.chunks_of(ts, 3), 0, |s, t| s - area2(t))
	}
}

square : List(Earcut.P)
square = [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }]

# a square drawn clockwise with y down has positive twice-area, and its
# reverse negative
expect Earcut.area2(square) == 200 and Earcut.area2(Earcut.reversed(square)) == -200

# a square cuts into two triangles that cover it exactly, each negative,
# whichever way the square was given
expect {
	a = Earcut.triangulate(square, [])
	b = Earcut.triangulate(Earcut.reversed(square), [])
	List.len(a) == 6 and Earcut.tri_area2(a) == 200 and Earcut.tri_area2(b) == 200
		and List.all(List.chunks_of(a, 3), |t| Earcut.area2(t) < 0)
}

# a concave L of six corners cuts into four triangles covering its area
expect {
	l = [{ x: 0, y: 0 }, { x: 20, y: 0 }, { x: 20, y: 10 }, { x: 10, y: 10 }, { x: 10, y: 20 }, { x: 0, y: 20 }]
	t = Earcut.triangulate(l, [])
	List.len(t) == 12 and Earcut.tri_area2(t) == Earcut.area2(l)
}

# a square with a square hole: the triangles cover the ring between them
# and none covers the hole's centre
expect {
	outer = [{ x: 0, y: 0 }, { x: 30, y: 0 }, { x: 30, y: 30 }, { x: 0, y: 30 }]
	hole = [{ x: 10, y: 10 }, { x: 20, y: 10 }, { x: 20, y: 20 }, { x: 10, y: 20 }]
	t = Earcut.triangulate(outer, [hole])
	centre = { x: 15, y: 15 }
	covers = List.any(
		List.chunks_of(t, 3),
		|tri| {
			a = List.get(tri, 2) ?? centre
			b = List.get(tri, 1) ?? centre
			c = List.get(tri, 0) ?? centre
			Earcut.cross(a, b, centre) > 0 and Earcut.cross(b, c, centre) > 0 and Earcut.cross(c, a, centre) > 0
		},
	)
	Earcut.tri_area2(t) == 1800 - 200 and !covers
}

# two holes side by side are both cut out
expect {
	outer = [{ x: 0, y: 0 }, { x: 50, y: 0 }, { x: 50, y: 20 }, { x: 0, y: 20 }]
	h1 = [{ x: 5, y: 5 }, { x: 15, y: 5 }, { x: 15, y: 15 }, { x: 5, y: 15 }]
	h2 = [{ x: 30, y: 5 }, { x: 40, y: 5 }, { x: 40, y: 15 }, { x: 30, y: 15 }]
	Earcut.tri_area2(Earcut.triangulate(outer, [h1, h2])) == 2000 - 200 - 200
}

# a corner with no turn is dropped and adds no triangle, and fewer than
# three points make none
expect {
	t = Earcut.triangulate([{ x: 5, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }, { x: 0, y: 0 }], [])
	Earcut.tri_area2(t) == 200 and List.len(t) == 6 and Earcut.triangulate([{ x: 0, y: 0 }, { x: 1, y: 1 }], []) == []
}
