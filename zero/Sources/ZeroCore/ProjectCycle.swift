import Foundation

public enum ProjectCycle {
    public static func step(from current: String?, in order: [String], by steps: Int) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return steps < 0 ? order.last : order.first
        }

        let count = order.count
        let moved = (index + steps % count + count) % count
        return order[moved]
    }
}
