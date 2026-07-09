import SwiftUI

/// The Ouroboros mark — reference implementation of the canonical geometry in
/// `brand/README.md` (fixed proportions; color/theme is the host app's).
/// "Pure cycle": a tapering, chevron-cracked band chasing its own vanishing
/// tail. No head, no eye — the geometry carries the figure.
///
/// Theming: renders in the current `foregroundStyle` (solids and gradients both
/// work — e.g. `.foregroundStyle(LinearGradient(...))` for the holographic
/// dressing), or pass `palette:` to give each of the 5 shards its own flat
/// color (the multicolor dressing). Scales with its frame; keep it ≥ 16 pt.
public struct OuroborosMark: View {
    public var palette: [Color]?

    public init(palette: [Color]? = nil) { self.palette = palette }

    public var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let cx = size.width / 2, cy = size.height / 2
            func pt(_ deg: Double, _ r: Double) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: cx + r * cos(a) * s, y: cy + r * sin(a) * s)
            }

            // Canonical constants — brand/README.md. Do not tweak these here;
            // theming happens via foregroundStyle/frame/palette, never the geometry.
            let R = 38.0, wBody = 9.0, wTip = 1.6
            let aStart = -40.0, aTaper = 200.0, aTip = 298.0
            let cuts = [30.0, 95.0, 160.0, 225.0], gap = 2.4, zig = 3.6
            func w(_ a: Double) -> Double {
                a <= aTaper ? wBody : wBody + (wTip - wBody) * (a - aTaper) / (aTip - aTaper)
            }

            // 5 shards: every face (including the thick terminus) is the same
            // chevron lightning break; the tail tip stays a clean point.
            var bounds: [Double] = [aStart]
            for a in cuts { bounds.append(a - gap); bounds.append(a + gap) }
            bounds.append(aTip)
            for i in stride(from: 0, to: bounds.count, by: 2) {
                let a0 = bounds[i], a1 = bounds[i + 1]
                let n = max(2, Int((a1 - a0) / 2.5))
                var shard = Path()
                for k in 0...n {
                    let a = a0 + (a1 - a0) * Double(k) / Double(n)
                    let p = pt(a, R + w(a) / 2)
                    if k == 0 { shard.move(to: p) } else { shard.addLine(to: p) }
                }
                if i + 2 < bounds.count { shard.addLine(to: pt(a1 - zig, R)) }
                for k in (0...n).reversed() {
                    let a = a0 + (a1 - a0) * Double(k) / Double(n)
                    shard.addLine(to: pt(a, R - w(a) / 2))
                }
                shard.addLine(to: pt(a0 - zig, R))
                shard.closeSubpath()
                if let palette, !palette.isEmpty {
                    ctx.fill(shard, with: .color(palette[(i / 2) % palette.count]))
                } else {
                    ctx.fill(shard, with: .style(.foreground))
                }
            }
        }
    }
}
