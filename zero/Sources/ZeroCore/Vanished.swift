import Foundation

/// The rows a list is already treating as gone.
///
/// Deleting something in the drawer is an API call and a two-second poll apart.
/// In between, the row has to be missing from the list or its exit has nothing
/// to play against — and a list that simply waits for the next snapshot loses
/// the row half a beat later, with nothing connecting it to the click.
///
/// So the drawer stops drawing the row itself, immediately, and this is the set
/// it is not drawing. The part worth a type is letting go again: an id is
/// dropped as soon as the daemon's own snapshot agrees it has gone, and in any
/// case after `grace`. A delete that failed server-side has to look like one —
/// better a row that comes back than a row nobody can see and nobody can fix.
public struct Vanished: Sendable, Equatable {
    /// How long a row may stay hidden while the daemon has not caught up. Long
    /// enough for a couple of poll cycles, short enough that a failed delete
    /// stops looking like a successful one.
    public static let grace: TimeInterval = 5

    private var hiddenAt: [String: Date] = [:]

    public init() {}

    public var isEmpty: Bool { hiddenAt.isEmpty }
    public var count: Int { hiddenAt.count }

    public func contains(_ id: String) -> Bool { hiddenAt[id] != nil }

    /// Stop drawing a row. Hiding one that is already on its way out does not
    /// restart its clock: two deletes of the same issue are one delete, and
    /// the second must not extend how long a stuck row stays invisible.
    public mutating func hide(_ id: String, at now: Date = Date()) {
        if hiddenAt[id] == nil { hiddenAt[id] = now }
    }

    /// Bring the list back in line with what the daemon says exists.
    ///
    /// `live` is every id the snapshot still mentions. One that is no longer
    /// there has really gone, so there is nothing left to hide; one that is
    /// still there keeps its row hidden until `grace` runs out, and then gets
    /// it back.
    public mutating func reconcile(live: Set<String>, now: Date = Date()) {
        guard !hiddenAt.isEmpty else { return }
        hiddenAt = hiddenAt.filter { id, at in
            live.contains(id) && now.timeIntervalSince(at) < Vanished.grace
        }
    }

    /// The rows still worth drawing, in the order they came in.
    public func visible<Row: Identifiable>(_ rows: [Row]) -> [Row] where Row.ID == String {
        guard !hiddenAt.isEmpty else { return rows }
        return rows.filter { !contains($0.id) }
    }
}
