import Foundation

public enum ToastPlacement {
    public static let inset: CGFloat = 20

    public static let margin: CGFloat = 4

    public static func resting(size: CGSize, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.maxX - size.width - inset, y: frame.minY + inset)
    }

    public static func clamp(_ origin: CGPoint, size: CGSize, into frame: CGRect) -> CGPoint {
        let lowX = frame.minX + margin
        let lowY = frame.minY + margin
        return CGPoint(x: min(max(origin.x, lowX), max(lowX, frame.maxX - size.width - margin)),
                       y: min(max(origin.y, lowY), max(lowY, frame.maxY - size.height - margin)))
    }

    public static func origin(remembered: CGPoint?, size: CGSize, screens: [CGRect]) -> CGPoint? {
        guard let preferred = screens.first else { return nil }
        guard let remembered else { return resting(size: size, in: preferred) }

        let card = CGRect(origin: remembered, size: size)
        let host = screens.max { covered(card, $0) < covered(card, $1) }
        if let host, covered(card, host) > 0 {
            return clamp(remembered, size: size, into: host)
        }
        return resting(size: size, in: preferred)
    }

    private static func covered(_ card: CGRect, _ frame: CGRect) -> CGFloat {
        let shared = card.intersection(frame)
        return shared.isNull ? 0 : shared.width * shared.height
    }
}
