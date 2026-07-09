import SwiftUI

/// The Ouroboros mark — reference implementation of the canonical geometry in
/// `brand/README.md` (fixed proportions; color/theme is the host app's).
/// A fractured coil tapering into an open-jaw dart head; renders in the current
/// `foregroundStyle`; the slit eye is true negative space (erased, so the
/// background shows through). Scales with its frame; keep it ≥ 16 pt. The eye
/// auto-hides below 24 pt (`eye:` overrides).
public struct OuroborosMark: View {
    public var eye: Bool?

    public init(eye: Bool? = nil) { self.eye = eye }

    public var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let cx = size.width / 2, cy = size.height / 2
            func pt(_ deg: Double, _ r: Double) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: cx + r * cos(a) * s, y: cy + r * sin(a) * s)
            }

            // Canonical constants — brand/README.md. Do not tweak these here;
            // theming happens via foregroundStyle/frame, never the geometry.
            let R = 38.0, wBody = 9.0, wTip = 1.8
            let aStart = -33.0, aTaper = 210.0, aTip = 292.0, headAngle = -55.0
            let cuts: [(Double, Double)] = [(18, 1.3), (55, 2.2), (96, 1.1), (150, 2.6),
                                            (192, 1.2), (231, 2.0), (248, 1.0)]
            let slant = 4.5
            func w(_ a: Double) -> Double {
                a <= aTaper ? wBody : wBody + (wTip - wBody) * (a - aTaper) / (aTip - aTaper)
            }

            // Body: the tapered band broken into shards by same-direction slash cuts.
            var bounds: [Double] = [aStart]
            for (a, g) in cuts { bounds.append(a - g); bounds.append(a + g) }
            bounds.append(aTip)
            for i in stride(from: 0, to: bounds.count, by: 2) {
                let a0 = bounds[i], a1 = bounds[i + 1]
                let s0 = i > 0 ? slant : 0.0             // body start hides under the head
                let s1 = i + 2 < bounds.count ? slant : 0.0   // the tip stays a clean point
                let n = max(2, Int((a1 - a0) / 2))
                var shard = Path()
                for k in 0...n {
                    let a = a0 + s0 + (a1 + s1 - a0 - s0) * Double(k) / Double(n)
                    let p = pt(a, R + w(a) / 2)
                    if k == 0 { shard.move(to: p) } else { shard.addLine(to: p) }
                }
                for k in (0...n).reversed() {
                    let a = a0 - s0 + (a1 - s1 - a0 + s0) * Double(k) / Double(n)
                    shard.addLine(to: pt(a, R - w(a) / 2))
                }
                shard.closeSubpath()
                ctx.fill(shard, with: .style(.foreground))
            }

            // Head: open-jaw dart in the tangent frame; the tail tip enters the mouth.
            let hc = pt(headAngle, R)
            let headPts: [(Double, Double)] = [(-21, -2.2), (-12.5, -0.2), (-21.5, 2.8),
                                               (-7, 6.8), (11, 4.8), (16, 0),
                                               (11, -4.8), (-7, -6.8)]
            var headCtx = ctx
            headCtx.translateBy(x: hc.x, y: hc.y)
            headCtx.rotate(by: .degrees(headAngle + 90))
            var head = Path()
            head.move(to: CGPoint(x: headPts[0].0 * s, y: headPts[0].1 * s))
            for (x, y) in headPts.dropFirst() { head.addLine(to: CGPoint(x: x * s, y: y * s)) }
            head.closeSubpath()
            headCtx.fill(head, with: .style(.foreground))

            // Eye: a slit punched out — the background shows through.
            if eye ?? (min(size.width, size.height) >= 24) {
                let eyePts: [(Double, Double)] = [(-9.5, -4.6), (-3.4, -3.3),
                                                  (-2.8, -1.2), (-8.9, -2.5)]
                var eyeCtx = headCtx
                eyeCtx.blendMode = .clear
                var slit = Path()
                slit.move(to: CGPoint(x: eyePts[0].0 * s, y: eyePts[0].1 * s))
                for (x, y) in eyePts.dropFirst() { slit.addLine(to: CGPoint(x: x * s, y: y * s)) }
                slit.closeSubpath()
                eyeCtx.fill(slit, with: .color(.black))
            }
        }
    }
}
