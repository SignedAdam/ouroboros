import SwiftUI

/// The Ouroboros mark — reference implementation of the canonical geometry in
/// `brand/README.md` (fixed proportions; color/theme is the host app's).
/// Renders in the current `foregroundStyle`; the eye is true negative space
/// (erased, so the background shows through). Scales with its frame; keep it
/// ≥ 16 pt. The eye auto-hides below 24 pt (`eye:` overrides).
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
            let aStart = -45.0, aTaper = 210.0, aTip = 287.0, headAngle = -55.0
            func w(_ a: Double) -> Double {
                a <= aTaper ? wBody : wBody + (wTip - wBody) * (a - aTaper) / (aTip - aTaper)
            }

            // Body: one filled tapered band (outer edge out, inner edge back).
            var angles = Array(stride(from: aStart, through: aTip, by: 3.0))
            if angles.last != aTip { angles.append(aTip) }
            var band = Path()
            band.move(to: pt(angles[0], R + w(angles[0]) / 2))
            for a in angles.dropFirst() { band.addLine(to: pt(a, R + w(a) / 2)) }
            for a in angles.reversed() { band.addLine(to: pt(a, R - w(a) / 2)) }
            band.closeSubpath()
            ctx.fill(band, with: .style(.foreground))

            // Head: ellipse on the ring, lying along the tangent, over the tail tip.
            let hc = pt(headAngle, R)
            var headCtx = ctx
            headCtx.translateBy(x: hc.x, y: hc.y)
            headCtx.rotate(by: .degrees(headAngle + 90))
            headCtx.fill(Path(ellipseIn: CGRect(x: -15 * s, y: -10.5 * s,
                                                width: 30 * s, height: 21 * s)),
                         with: .style(.foreground))

            // Eye: a punched hole — the background shows through.
            if eye ?? (min(size.width, size.height) >= 24) {
                var eyeCtx = ctx
                eyeCtx.blendMode = .clear
                let ec = CGPoint(x: hc.x + 3.4 * s, y: hc.y - 4.6 * s)
                eyeCtx.fill(Path(ellipseIn: CGRect(x: ec.x - 2.9 * s, y: ec.y - 2.9 * s,
                                                   width: 5.8 * s, height: 5.8 * s)),
                            with: .color(.black))
            }
        }
    }
}
