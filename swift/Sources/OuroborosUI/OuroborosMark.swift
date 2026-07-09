import SwiftUI

/// The Ouroboros mark — reference implementation of the canonical geometry in
/// `brand/README.md` (fixed proportions; color/theme is the host app's).
/// A chevron-cracked coil tapering into a sleek bezier viper head; renders in
/// the current `foregroundStyle`; the slit eye is true negative space (erased,
/// so the background shows through). Scales with its frame; keep it ≥ 16 pt.
/// The eye auto-hides below 24 pt (`eye:` overrides).
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
            func lp(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }

            // Canonical constants — brand/README.md. Do not tweak these here;
            // theming happens via foregroundStyle/frame, never the geometry.
            let R = 38.0, wBody = 9.0, wTip = 1.8
            let aStart = -33.0, aTaper = 210.0, aTip = 292.0, headAngle = -55.0
            let cuts = [30.0, 95.0, 160.0, 225.0], gap = 2.4, zig = 3.6
            func w(_ a: Double) -> Double {
                a <= aTaper ? wBody : wBody + (wTip - wBody) * (a - aTaper) / (aTip - aTaper)
            }

            // Body: tapered band broken into shards by chevron (lightning) cracks —
            // each crack face has a mid-width vertex swung -zig°, same direction on
            // every crack, so they read as breaks, never dashes.
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
                if i > 0 { shard.addLine(to: pt(a0 - zig, R)) }
                shard.closeSubpath()
                ctx.fill(shard, with: .style(.foreground))
            }

            // Head: sleek viper bezier in the tangent frame; the tail enters the mouth.
            let hc = pt(headAngle, R)
            var headCtx = ctx
            headCtx.translateBy(x: hc.x, y: hc.y)
            headCtx.rotate(by: .degrees(headAngle + 90))
            var head = Path()
            head.move(to: lp(-19.5, -0.8))
            head.addCurve(to: lp(2, -8.0), control1: lp(-13, -4.8), control2: lp(-6, -7.6))
            head.addCurve(to: lp(16, -2.5), control1: lp(8, -8.3), control2: lp(14, -6.0))
            head.addCurve(to: lp(16, 2.5), control1: lp(17.2, -0.8), control2: lp(17.2, 0.8))
            head.addCurve(to: lp(2, 8.0), control1: lp(14, 6.0), control2: lp(8, 8.3))
            head.addCurve(to: lp(-12.8, 3.6), control1: lp(-4, 7.7), control2: lp(-9, 5.6))
            head.addLine(to: lp(-17.5, 4.6))
            head.addCurve(to: lp(-8.2, 0.9), control1: lp(-14, 2.2), control2: lp(-11, 1.2))
            head.addCurve(to: lp(-19.5, -0.8), control1: lp(-11.5, 0.2), control2: lp(-15.5, -0.4))
            head.closeSubpath()
            headCtx.fill(head, with: .style(.foreground))

            // Eye: a slit triangle punched out — the background shows through.
            if eye ?? (min(size.width, size.height) >= 24) {
                var eyeCtx = headCtx
                eyeCtx.blendMode = .clear
                var slit = Path()
                slit.move(to: lp(-9.6, -4.6))
                slit.addLine(to: lp(-3.2, -3.4))
                slit.addLine(to: lp(-8.6, -2.4))
                slit.closeSubpath()
                eyeCtx.fill(slit, with: .color(.black))
            }
        }
    }
}
