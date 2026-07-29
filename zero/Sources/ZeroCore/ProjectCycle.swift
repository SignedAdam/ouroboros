import Foundation

/// ⇥ and ⇧⇥ in the capture panel: walk the project the next sentence is going
/// to, without leaving the keyboard.
///
/// Picking a project used to mean the mouse — open the folder menu, find the
/// name, click it — which is the exact friction the panel exists to delete. The
/// list is already sorted by recency and already on screen under the field, so
/// the ring the tab key walks is the one you are looking at.
///
/// Like `SlashCommands` and `HotkeyCombo`, this lives in ZeroCore rather than
/// beside the view: it is index arithmetic with edge cases (an empty list, a
/// selection that isn't in the list, wrapping past both ends), and that is worth
/// testing without an event monitor and a window server in the way.
public enum ProjectCycle {

    /// The id `steps` places along `order` from `current`, wrapping at both ends.
    ///
    /// A `current` that isn't in `order` — you picked something from the full
    /// folder menu that is too old to be in the recents — enters the ring from
    /// whichever end you are walking towards: ⇥ lands on the most recent project,
    /// ⇧⇥ on the least. Nothing to walk returns nil, so the caller leaves the
    /// selection alone rather than clearing it.
    public static func step(from current: String?, in order: [String], by steps: Int) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return steps < 0 ? order.last : order.first
        }
        // Swift's % keeps the sign of the dividend, so -1 % 7 is -1 and ⇧⇥ off
        // the top of the list would index out of bounds. Bias into range first.
        let count = order.count
        let moved = (index + steps % count + count) % count
        return order[moved]
    }
}
