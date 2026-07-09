# The Ouroboros mark

The self-eating snake: one coiled body tapering into its own mouth. Every app that
integrates Ouroboros shows this mark on its entry points (the floating button at
minimum). It works like the Olympic rings: **the geometry is fixed, the dressing is
yours.** A user who knows the mark from one app must recognize it instantly in the next —
while each app themes it so it looks native there.

Reference outline: [`ouroboros-mark.svg`](ouroboros-mark.svg) (renders in
`currentColor`; the eye is true negative space). Reference implementation:
`swift/Sources/OuroborosUI/OuroborosMark.swift` (SwiftUI `Canvas`, exact same numbers).

## Canonical geometry (FIXED — do not redesign)

All values in a 100×100 viewBox, y-down, angles in degrees clockwise from +x
(screen space). Scale everything uniformly; never distort.

| Element | Value |
|---|---|
| Ring center / radius | (50, 50) / **R = 38** |
| Body width | **9** (constant from −33° to 210°) |
| Tail taper | linear **9 → 1.8** over **210° → 292°** |
| Tail tip | ends at **292°** (= −68°), entering the **open mouth** |
| **Fractures** | the band is broken by 7 slash cuts at **18°, 55°, 96°, 150°, 192°, 231°, 248°** with half-gaps **1.3, 2.2, 1.1, 2.6, 1.2, 2.0, 1.0**°; every cut face slants **+4.5°** (same direction — one shatter, not a dashed ring) |
| Head | open-jaw dart, polygon in the tangent frame at **−55°** (rotated −55°+90°), local points (x toward the body, −x toward the snout): **(−21,−2.2) (−12.5,−0.2) (−21.5,2.8) (−7,6.8) (11,4.8) (16,0) (11,−4.8) (−7,−6.8)** — the notch between the first three points is the mouth; the tail tip enters it |
| Eye | slit quad, local points **(−9.5,−4.6) (−3.4,−3.3) (−2.8,−1.2) (−8.9,−2.5)** — **negative space** (background shows through) |

Construction: the body is a filled tapered band (outer edge `R + w(θ)/2`, inner
`R − w(θ)/2`) cut into shards by the slash table — NOT stepped strokes, NOT a dashed
ring; the outermost cut faces stay clean (body start hides under the head, the tip stays
a point). The head is drawn on top; the thin tail tip must visibly reach between the jaws.

## Yours to theme (FREE)

- **Color(s)**: solid, gradient, texture — match the host app's accent/ink.
- **Weight feel**: glow, shadow, hover/pressed states, animation (e.g. slow rotation).
- **Rotation**: the whole mark may be rotated to sit better in a corner; keep the
  head-swallowing-tail relationship intact.
- **The eye**: required at rendered sizes ≥ 24 px; drop it below that (it aliases away
  anyway). It is always a hole (background color), never a painted dot of a third color.
- **Background container**: chip, circle, square, none — whatever the app's buttons do.

## Not allowed

- Changing the proportions, cut rhythm, slant direction, taper curve, or head shape.
- Healing the fractures into a solid ring, or regularizing them into dashes.
- Closing the mouth (the tail-into-jaws IS the identity).
- Replacing it with a generic snake/bug/warning glyph.
- Adding a third color for the eye, outlines around the silhouette, or text inside it.

## Legibility floor

The mark stays readable down to ~16 px (fractures degrade into texture; ring + head knot
survive). At 16–23 px: no eye. Below 14 px, don't use the mark; use text.
