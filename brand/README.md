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

There is **no head and no eye** — the mark is purely geometric ("pure cycle"): a
tapering, chevron-cracked band whose thick face forever chases its own vanishing tail.

| Element | Value |
|---|---|
| Ring center / radius | (50, 50) / **R = 38** |
| Band | from **−40°** (the thick face) clockwise to **298°** (= −62°, the tail tip) — a 338° sweep |
| Body width | **9** (constant to 200°) |
| Tail taper | linear **9 → 1.6** over **200° → 298°**, ending in a clean point |
| Consumption gap | the **22° void** between the tail tip (−62°) and the thick face (−40°) — this is the "mouth"; never close or shrink it |
| **Fractures** | **4 chevron cracks** at **30°, 95°, 160°, 225°**, half-gap **2.4°**; every crack face is a **lightning break**: a mid-width vertex swung **−3.6°**, the same direction on every face — cracks, never dashes |
| Thick face | the SAME chevron face as the cracks (the terminus is just the deepest break in the cycle) |

Construction: the body is a filled tapered band (outer edge `R + w(θ)/2`, inner
`R − w(θ)/2`) broken into 5 shards by the crack table — NOT stepped strokes, NOT a
dashed ring. The tail tip stays a clean point aimed across the gap at the thick face.

## Yours to theme (FREE)

- **Color(s)**: solid, gradient, texture — match the host app's accent/ink. Two shipped
  reference dressings (same geometry, see the SVGs in this folder):
  - **Holographic** (`ouroboros-mark-holo.svg`): one iridescent pastel-spectral
    linear gradient sweeping diagonally across the whole mark.
  - **Multicolor** (`ouroboros-mark-multicolor.svg`): one flat color per shard,
    5 hues, no gradients — Olympic-rings energy.
- **Weight feel**: glow, shadow, hover/pressed states, animation (e.g. slow rotation).
- **Rotation**: the whole mark may be rotated to sit better in a corner; keep the
  thick-face-chasing-tail relationship intact.
- **Background container**: chip, circle, square, none — whatever the app's buttons do.

## Not allowed

- Changing the proportions, crack rhythm, chevron direction, or taper curve.
- Healing the fractures into a solid ring, or regularizing them into dashes.
- Closing or shrinking the consumption gap (the chase IS the identity).
- Adding a head, an eye, or any figurative element — the geometry carries the figure.
- Replacing it with a generic snake/bug/warning glyph, outlines around the silhouette,
  or text inside it.

## Legibility floor

The mark stays readable down to ~16 px (fractures degrade into texture; the ring + the
gap survive). Below 14 px, don't use the mark; use text.
