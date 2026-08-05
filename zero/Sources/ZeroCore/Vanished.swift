import Foundation

public struct Vanished: Sendable, Equatable {
    public static let grace: TimeInterval = 5

    private var hiddenAt: [String: Date] = [:]

    public init() {}

    public var isEmpty: Bool { hiddenAt.isEmpty }
    public var count: Int { hiddenAt.count }

    public func contains(_ id: String) -> Bool { hiddenAt[id] != nil }

    public mutating func hide(_ id: String, at now: Date = Date()) {
        if hiddenAt[id] == nil { hiddenAt[id] = now }
    }

    public mutating func reconcile(live: Set<String>, now: Date = Date()) {
        guard !hiddenAt.isEmpty else { return }
        hiddenAt = hiddenAt.filter { id, at in
            live.contains(id) && now.timeIntervalSince(at) < Vanished.grace
        }
    }

    public func visible<Row: Identifiable>(_ rows: [Row]) -> [Row] where Row.ID == String {
        guard !hiddenAt.isEmpty else { return rows }
        return rows.filter { !contains($0.id) }
    }
}
