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
| **Fractures** | the band is broken by **4 chevron cracks** at **30°, 95°, 160°, 225°**, half-gap **2.4°** each; every crack face is a **lightning break**: a mid-width vertex swung **−3.6°** (toward the crack on one face, into the shard on the other), the same direction on all cracks — cracks, never dashes |
| Head | sleek viper head, a smooth bezier path in the tangent frame at **−55°** (rotated −55°+90°; −x = snout, toward the incoming tail): `M -19.5 -0.8 C -13 -4.8 -6 -7.6 2 -8.0 C 8 -8.3 14 -6.0 16 -2.5 C 17.2 -0.8 17.2 0.8 16 2.5 C 14 6.0 8 8.3 2 8.0 C -4 7.7 -9 5.6 -12.8 3.6 L -17.5 4.6 C -14 2.2 -11 1.2 -8.2 0.9 C -11.5 0.2 -15.5 -0.4 -19.5 -0.8 Z` — the notch between snout and lower-jaw tip is the mouth; the tail tip enters it |
| Eye | slit triangle, local points **(−9.6,−4.6) (−3.2,−3.4) (−8.6,−2.4)** — **negative space** (background shows through) |

Construction: the body is a filled tapered band (outer edge `R + w(θ)/2`, inner
`R − w(θ)/2`) broken into shards by the chevron-crack table — NOT stepped strokes, NOT a
dashed ring; the outermost faces stay clean (body start hides under the head, the tip
stays a point). The head is drawn on top; the thin tail tip must visibly reach the mouth.

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
