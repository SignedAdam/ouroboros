import Foundation

/// Every verb a row in the capture panel offers, and the one thing the panel
/// has to know about each of them: does it hand you to another window?
///
/// The rule, and the reason this is a type rather than a `hide()` sprinkled
/// through the menus: **a verb that puts another window in front of you closes
/// the panel; a verb whose whole result is visible inside the panel keeps it
/// open.** Deleting an issue is not a reason to dismiss the box you were about
/// to type into — you can see the row go, and you are probably about to delete
/// the next one. Opening the issue file *is*, because a floating capture box on
/// top of the editor you just asked for is only something else to dismiss.
///
/// Every case is spelled out on one side or the other, with no `default:`, so
/// adding a verb forces the decision instead of inheriting one.
public enum RowVerb: String, CaseIterable, Sendable {

    // Verbs whose result is the panel itself changing.
    case captureInto, favourite, hide, defaultAgent, autonomy
    case copyPath, copyTitle, copyCommand
    case delete, forget
    case merge, rebase, undoMerge, stop, clear, markDone
    /// The diff is a sheet on the panel, so escape puts you back on the same
    /// drawer with the same project still open.
    case diff
    /// Puts `/reply <run>` in the field you are already looking at.
    case reply
    /// Let a spent branch go: the base already has its work. The row goes on
    /// the click, like a delete, and nothing else appears.
    case discard

    // Verbs that open something else.
    case openFile, openFinder, openTerminal, openAgentView, openWorktree
    case resume, fix, retry
    /// The run's log, live, in its own terminal.
    case watch
    /// Send the agent that wrote the branch back in to rebase and fix it. It
    /// dispatches a supervised run, exactly as `fix` does.
    case resolve

    /// True when another window is about to take the screen, so the capture
    /// panel steps aside rather than floating over it.
    public var handsOff: Bool {
        switch self {
        case .captureInto, .favourite, .hide, .defaultAgent, .autonomy,
             .copyPath, .copyTitle, .copyCommand,
             .delete, .forget,
             .merge, .rebase, .undoMerge, .stop, .clear, .markDone,
             .diff, .reply, .discard:
            return false
        case .openFile, .openFinder, .openTerminal, .openAgentView, .openWorktree,
             .resume, .fix, .retry, .watch, .resolve:
            return true
        }
    }

    /// The beat between the click and the panel going away. Zero for anything
    /// that opens a window of its own — the new window is the confirmation.
    /// Dispatching an agent gets long enough to read which one took the job,
    /// because its terminal can take a second to appear and a panel that
    /// vanishes onto an unchanged screen reads as a click that did nothing.
    public var beat: Double {
        switch self {
        case .fix, .retry, .resolve: return 0.5
        default:                     return 0
        }
    }

    /// The word on the button. One word, lower case, never a sentence — and
    /// spelled out for every case rather than falling back to `rawValue`, which
    /// would put `copyPath` on a row in front of somebody.
    public var label: String {
        switch self {
        case .fix:           return "fix"
        case .retry:         return "retry"
        case .resume:        return "open"
        case .watch:         return "watch"
        case .stop:          return "stop"
        case .reply:         return "reply"
        case .diff:          return "diff"
        case .merge:         return "merge"
        case .rebase:        return "rebase"
        case .resolve:       return "resolve"
        case .discard:       return "discard"
        case .undoMerge:     return "undo"
        case .markDone:      return "done"
        case .delete:        return "delete"
        case .forget:        return "remove"
        case .hide:          return "hide"
        case .favourite:     return "pin"
        case .captureInto:   return "capture"
        case .defaultAgent:  return "agent"
        case .autonomy:      return "finish"
        case .copyPath:      return "copy path"
        case .copyTitle:     return "copy title"
        case .copyCommand:   return "copy"
        case .openFile:      return "file"
        case .openFinder:    return "finder"
        case .openTerminal:  return "terminal"
        case .openAgentView: return "agents"
        case .openWorktree:  return "worktree"
        case .clear:         return "clear"
        }
    }

    /// The SF Symbol beside it. Small, and only ever the one that means the
    /// verb — a glyph you have to be taught is a glyph that costs more than the
    /// word it sits next to.
    public var symbol: String {
        switch self {
        case .fix:          return "hammer"
        case .retry:        return "arrow.clockwise"
        case .resume:       return "bubble.left.and.text.bubble.right"
        case .watch:        return "eye"
        case .stop:         return "stop.fill"
        case .reply:        return "arrowshape.turn.up.left"
        case .diff:         return "plus.forwardslash.minus"
        case .merge:        return "arrow.triangle.merge"
        case .rebase:       return "arrow.triangle.branch"
        // Not a hammer: `fix` already owns that, and this is the same agent
        // being sent back to its own work rather than a new one starting.
        case .resolve:      return "arrow.uturn.backward.badge.clock"
        case .discard:      return "xmark.bin"
        case .undoMerge:    return "arrow.uturn.backward"
        case .markDone:     return "checkmark"
        case .delete:       return "trash"
        case .openFile:     return "doc.text"
        case .openFinder:   return "folder"
        case .openTerminal: return "terminal"
        case .openWorktree: return "shippingbox"
        case .openAgentView: return "rectangle.stack"
        case .favourite:    return "star"
        case .hide:         return "eye.slash"
        case .forget:       return "minus.circle"
        case .captureInto:  return "square.and.pencil"
        case .copyPath, .copyTitle, .copyCommand: return "doc.on.doc"
        case .defaultAgent: return "cpu"
        case .autonomy:     return "slider.horizontal.3"
        case .clear:        return "xmark"
        }
    }
}

// MARK: - which verbs a row offers

public extension WorkState {
    /// The verbs on a row in this state. Two or three, never more: a row with
    /// six buttons is a row nobody reads, and everything left out is one
    /// right-click away.
    ///
    /// It is a function of state and nothing else, so the same sentence never
    /// offers `merge` in one place and not in another. `conflicts` is the whole
    /// argument for the table existing — it is the one state where the obvious
    /// verb is known to fail, so it is not offered.
    ///
    /// `resolve` comes first on `conflicts` because it is the only verb there
    /// that ends the situation. `rebase` is the fallback for when a person
    /// would rather do it themselves, and it stays last.
    var verbs: [RowVerb] {
        switch self {
        case .filed:     return [.fix, .markDone]
        case .queued:    return [.watch, .stop]
        case .running:   return [.watch, .stop]
        case .asking:    return [.reply, .watch]
        case .review:    return [.diff, .merge, .markDone]
        case .conflicts: return [.resolve, .diff, .rebase]
        // Nothing to rescue and nothing to merge. Read it if you want to see
        // what it was, then let it go.
        case .obsolete:  return [.diff, .discard]
        case .merged:    return [.diff, .undoMerge, .markDone]
        case .failed:    return [.diff, .retry, .markDone]
        case .stopped:   return [.retry, .markDone]
        }
    }

    /// There is a branch to read. `filed` never had one; `queued` has not
    /// written one yet.
    var hasDiff: Bool {
        switch self {
        case .review, .conflicts, .obsolete, .merged, .failed, .stopped: return true
        case .filed, .queued, .running, .asking: return false
        }
    }
}
