import rr.Color
import rr.Draw
import rr.Text
import Labels
import Ui

Scene :: [].{
	# ── the text a view draws, through the placer ──────────────────────────
	# Every string a view writes is an Item: the string, its size, colour and
	# face, and the copy the window prepared at load when it prepared one. A
	# view turns its Items into labels (fixed text keeps one spot and is
	# placed first; a free label lists its spots and may be dropped; a kept
	# label lists its spots and never is), places them with Labels.place
	# against the shapes it draws, and draws the placements with draw!. The
	# gate reads the same placements through owned, so what it judges is
	# what the window draws.

	# the two faces: JetBrains Mono for data, Quicksand for prose
	Face : [Data, Prose]

	# a string's width at a pixel size in a face; the window measures with
	# the fonts it draws with, the gate with headless copies of their metrics
	Measure : Str, F32, Face -> F32

	Item : { text : Str, size : F32, color : Color.Rgba, face : Face, prep : [Fresh, Kept(Text.Prepared)] }

	# where a text is anchored and which of its edges the anchor names, the
	# way a Top-aligned draw call reads its position
	Anchor : { x : F32, y : F32, align : [Left, Center, Right] }

	measure_with : Text.Font, Text.Font -> Measure
	measure_with = |data, prose| |text, size, face| (
		match face {
			Data => data
			Prose => prose
		}
	).measure({ text, size, spacing: Text.default_spacing }).width

	# the window's own measure: the fonts the model draws with
	measure_of : Ui.Model -> Measure
	measure_of = |model| measure_with(model.font, model.prose)

	# an Item drawn fresh each frame in the data face
	data : Str, F32, Color.Rgba -> Item
	data = |text, size, color| { text, size, color, face: Data, prep: Fresh }

	# an Item the window prepared at load, measured from the string it was
	# prepared from
	prepared : Text.Prepared, Str, F32, Face, Color.Rgba -> Item
	prepared = |p, text, size, face, color| { text, size, color, face, prep: Kept(p) }

	spot_of : F32, Anchor -> Labels.Pt
	spot_of = |w, a| { x: Labels.left_of(a.x, w, a.align), y: a.y }

	# an Item's width: what the measure says of its string, and for a
	# prepared Item no less than the host measured when it prepared it, since
	# the prepared copy is what draws
	width : Measure, Item -> F32
	width = |measure, it| {
		w = measure(it.text, it.size, it.face)
		match it.prep {
			Kept(p) => F32.max(w, p.bounds().width)
			Fresh => w
		}
	}

	# fixed text: one spot, never dropped, placed before every other label
	fixed : Measure, Item, Anchor, Labels.Rect -> Labels.Label(Item)
	fixed = |measure, it, at, region| {
		w = width(measure, it)
		{ w, h: it.size, spots: [spot_of(w, at)], prio: 0, keep: Bool.True, region, item: it }
	}

	# a label that may be dropped: its spots in order of preference, placed
	# after every lower priority number
	free : Measure, Item, List(Anchor), U64, Labels.Rect -> Labels.Label(Item)
	free = |measure, it, ats, prio, region| {
		w = width(measure, it)
		{ w, h: it.size, spots: List.map(ats, |a| spot_of(w, a)), prio, keep: Bool.False, region, item: it }
	}

	# a label that tries its spots like a free one and, finding none clear,
	# takes its first anyway rather than vanish
	kept : Measure, Item, List(Anchor), U64, Labels.Rect -> Labels.Label(Item)
	kept = |measure, it, ats, prio, region| { ..free(measure, it, ats, prio, region), keep: Bool.True }

	draw! : Draw.Frame, Ui.Model, List(Labels.Placed(Item)) => {}
	draw! = |frame, model, placed|
		List.for_each!(
			placed,
			|p| {
				at = { pos: { x: p.box.x, y: p.box.y }, color: p.item.color, align: (Top, Left) }
				match p.item.prep {
					Kept(pr) => pr.draw!(frame, at)
					Fresh => {
						font = match p.item.face {
							Data => model.font
							Prose => model.prose
						}
						Text.from(p.item.text, font).size(p.item.size).draw!(frame, at)
					}
				}
			},
		)

	# the placements as the gate reads them, each named by its own text
	owned : List(Labels.Placed(Item)) -> List(Labels.Owned)
	owned = |ps| List.map(ps, |p| { key: "'${p.item.text}'", box: p.box, region: p.region })
}

# fixed text sits where its anchor and alignment put it, and a free label's
# spots are its anchors read the same way
expect {
	m = |text, size, _face| U64.to_f32(Str.count_utf8_bytes(text)) * size
	region = { x: 0.0, y: 0.0, w: 500.0, h: 500.0 }
	f = Scene.fixed(m, Scene.data("ab", 10.0, Color.white), { x: 100.0, y: 20.0, align: Right }, region)
	g = Scene.free(m, Scene.data("abcd", 10.0, Color.white), [{ x: 100.0, y: 20.0, align: Center }, { x: 0.0, y: 40.0, align: Left }], 3, region)
	f.spots == [{ x: 80.0, y: 20.0 }] and f.keep and f.w == 20.0 and f.h == 10.0
		and g.spots == [{ x: 80.0, y: 20.0 }, { x: 0.0, y: 40.0 }] and !(g.keep) and g.prio == 3
}
