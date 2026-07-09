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
| Body stroke width | **9** (constant from −45° to 210°) |
| Tail taper | linear **9 → 1.8** over **210° → 287°** |
| Tail tip | ends at **287°** (= −73°), tucked **under** the head — being swallowed |
| Head | ellipse **rx 15, ry 10.5**, center ON the ring at **−55°**, rotated to the tangent (−55°+90°) |
| Eye | circle **r 2.9** at head-center + **(+3.4, −4.6)** — **negative space** (background shows through) |
| Mouth gap | the arc from tip (−73°) to body start (−45°) is covered by the head; no visible break in the silhouette except where the taper vanishes |

Construction: the body is a single filled band (outer edge at `R + w(θ)/2`, inner at
`R − w(θ)/2`, `w(θ)` per the taper above) — NOT stepped stroke segments; the head is
drawn on top so the tail tip disappears into it.

## Yours to theme (FREE)

- **Color(s)**: solid, gradient, texture — match the host app's accent/ink.
- **Weight feel**: glow, shadow, hover/pressed states, animation (e.g. slow rotation).
- **Rotation**: the whole mark may be rotated to sit better in a corner; keep the
  head-swallowing-tail relationship intact.
- **The eye**: required at rendered sizes ≥ 24 px; drop it below that (it aliases away
  anyway). It is always a hole (background color), never a painted dot of a third color.
- **Background container**: chip, circle, square, none — whatever the app's buttons do.

## Not allowed

- Changing the proportions, gap position, taper curve, or head shape.
- Closing the coil into a plain ring (the taper-into-mouth IS the identity).
- Replacing it with a generic snake/bug/warning glyph.
- Adding a third color for the eye, outlines around the silhouette, or text inside it.

## Legibility floor

The mark stays readable down to ~16 px (ring + head knot). At 16–23 px: no eye. Below
14 px, don't use the mark; use text.
