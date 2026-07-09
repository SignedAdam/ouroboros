# The Ouroboros mark

Use this as the reference when designing a button or icon that triggers Ouroboros.

Files:

- [`ouroboros-mark.svg`](ouroboros-mark.svg) — the mark; renders in `currentColor`
- [`ouroboros-mark-holo.svg`](ouroboros-mark-holo.svg) — holographic dressing
- [`ouroboros-mark-multicolor.svg`](ouroboros-mark-multicolor.svg) — one flat color per shard
- Swift: `OuroborosUI.OuroborosMark` (optional `palette:` for per-shard colors)

## Geometry (fixed)

Values in a 100×100 viewBox, y-down, degrees clockwise from +x. Scale uniformly; never
distort. No head, no eye.

| Element | Value |
|---|---|
| Ring center / radius | (50, 50) / R = 38 |
| Band | −40° (thick face) clockwise to 298° (tail tip); 338° sweep |
| Body width | 9, constant to 200° |
| Taper | linear 9 → 1.6 over 200° → 298°, ending in a point |
| Gap | 22° between tail tip (−62°) and thick face (−40°) |
| Cracks | 4 chevrons at 30°, 95°, 160°, 225°; half-gap 2.4°; mid-width vertex swung −3.6°, same direction on every face |
| Thick face | the same chevron as the cracks |

Construction: a filled tapered band (outer edge `R + w(θ)/2`, inner `R − w(θ)/2`) broken
into 5 shards by the crack table. Not strokes, not dashes.

## Theming (free)

- Color: solid, gradient, or per-shard palette.
- Effects: glow, shadow, hover/pressed states, animation.
- Rotation of the whole mark.
- Container: chip, circle, square, none.

## Don't

- Change proportions, crack rhythm, chevron direction, or taper.
- Heal the cracks, or regularize them into dashes.
- Close or shrink the gap.
- Add a head, eye, outline, text, or any figurative element.
- Substitute a generic snake/bug/warning icon.

## Size

Readable down to ~16 px. Below 14 px, use text instead.
