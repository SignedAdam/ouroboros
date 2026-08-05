import Foundation

public enum RowVerb: String, CaseIterable, Sendable {
    case captureInto, favourite, hide, defaultAgent, autonomy
    case copyPath, copyTitle, copyCommand
    case delete, forget
    case merge, rebase, undoMerge, stop, clear, markDone

    case diff

    case reply

    case discard

    case openFile, openFinder, openTerminal, openAgentView, openWorktree
    case resume, fix, retry

    case watch

    case resolve

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

    public var beat: Double {
        switch self {
        case .fix, .retry, .resolve: return 0.5
        default:                     return 0
        }
    }

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

public extension WorkState {
    var verbs: [RowVerb] {
        switch self {
        case .filed:     return [.fix, .markDone]
        case .queued:    return [.watch, .stop]
        case .running:   return [.watch, .stop]
        case .asking:    return [.reply, .watch]
        case .review:    return [.diff, .merge, .markDone]
        case .conflicts: return [.resolve, .diff, .rebase]

        case .obsolete:  return [.diff, .discard]
        case .merged:    return [.diff, .undoMerge, .markDone]
        case .failed:    return [.diff, .retry, .markDone]
        case .stopped:   return [.retry, .markDone]
        }
    }

    var hasDiff: Bool {
        switch self {
        case .review, .conflicts, .obsolete, .merged, .failed, .stopped: return true
        case .filed, .queued, .running, .asking: return false
        }
    }
}
