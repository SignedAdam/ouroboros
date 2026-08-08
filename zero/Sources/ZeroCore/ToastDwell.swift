import Foundation

public struct ToastDwell: Sendable, Equatable {
    public static let standard: TimeInterval = 12

    public static let hoverFloor: TimeInterval = 3

    public let total: TimeInterval
    private var startedAt: Date
    private var pausedAt: Date?

    public init(total: TimeInterval = ToastDwell.standard, now: Date = Date()) {
        self.total = max(0.1, total)
        self.startedAt = now
    }

    public var isPaused: Bool { pausedAt != nil }

    public func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, total - (pausedAt ?? now).timeIntervalSince(startedAt))
    }

    public func fractionLeft(at now: Date = Date()) -> Double {
        min(1, max(0, remaining(at: now) / total))
    }

    public func hasExpired(at now: Date = Date()) -> Bool { remaining(at: now) <= 0 }

    public mutating func pause(at now: Date = Date()) {
        guard pausedAt == nil else { return }
        pausedAt = now
    }

    public mutating func resume(at now: Date = Date(), atLeast floor: TimeInterval = 0) {
        let left = max(remaining(at: now), min(floor, total))
        pausedAt = nil
        startedAt = now.addingTimeInterval(left - total)
    }

    public mutating func restart(at now: Date = Date()) {
        startedAt = now
        pausedAt = nil
    }
}
