import SwiftUI
import AppKit
import ZeroCore

@MainActor
enum RowActions {
    @ViewBuilder
    static func projectMenu(_ project: Project, model: AppModel) -> some View {
        Button("Capture into \(project.name)") {
            model.perform(.captureInto) { model.selectedProjectId = project.id }
        }
        Divider()
        Button(project.favourite ? "Unpin" : "Pin to the top") {
            model.perform(.favourite) {
                model.patchProject(project.id, API.PatchProject(favourite: !project.favourite))
                model.note(project.favourite ? "unpinned" : "kept at the top")
            }
        }

        Button("Hide until active again") {
            model.perform(.hide) { model.hideProject(project.id) }
        }
        Divider()
        Menu("Agent") {
            ForEach(model.availableAgents, id: \.self) { agent in
                Button(agent + (project.defaultAgent == agent ? "  ✓" : "")) {
                    model.perform(.defaultAgent) {
                        model.patchProject(project.id, API.PatchProject(defaultAgent: agent))
                        model.note("\(project.name) → \(agent)")
                    }
                }
            }
        }
        Menu("When a fix passes") {
            Button("Leave it on its branch" + (project.policy.autonomy == .manual ? "  ✓" : "")) {
                model.perform(.autonomy) {
                    model.patchProject(project.id, API.PatchProject(autonomy: "manual"))
                    model.note("fixes here wait on their branch")
                }
            }
            Button("Merge it for me" + (project.policy.autonomy == .auto ? "  ✓" : "")) {
                model.perform(.autonomy) {
                    model.patchProject(project.id, API.PatchProject(autonomy: "auto"))
                    model.note("verified fixes here will merge themselves")
                }
            }
        }
        Divider()
        Button("Finder") { model.perform(.openFinder) { model.open(path: project.path) } }
        Button("Terminal") { model.perform(.openTerminal) { model.openTerminal(at: project.path) } }
        Button("Agent view") { model.perform(.openAgentView) { model.openAgentView(project) } }
        Button("Copy path") {
            model.perform(.copyPath) { copy(project.path); model.note("copied the path") }
        }
        Divider()
        Button("Remove from Ouroboros") {
            model.perform(.forget) { model.forgetProject(project.id) }
        }
    }

    @ViewBuilder
    static func issueMenu(_ pip: IssuePip, model: AppModel) -> some View {
        if pip.canResume, let runId = pip.runId {
            Button("Resume in \(pip.agent)") { model.perform(.resume) { model.resumeRun(runId) } }
        }
        if pip.path != nil {
            Menu(pip.runId == nil ? "Start" : "Start again") {
                ForEach(model.availableAgents, id: \.self) { agent in
                    Button(agent) { model.perform(.fix) { model.open(pip, agent: agent) } }
                }
            }
        }
        Divider()

        ForEach(menuVerbs(pip), id: \.self) { verb in
            Button(menuTitle(verb, pip: pip)) { run(verb, pip: pip, model: model) }
        }
        if let runId = pip.runId {
            Divider()
            Button("Copy log command") { model.perform(.copyCommand) { model.openLog(runId) } }
            Button("Copy diff command") { model.perform(.copyCommand) { model.showDiff(runId) } }
            Button("Worktree") { model.perform(.openWorktree) { model.openWorktree(runId) } }
        }
        Divider()
        if let path = pip.path {
            Button("Open file") { model.perform(.openFile) { model.open(path: path) } }
        }
        Button("Copy title") {
            model.perform(.copyTitle) { copy(pip.title); model.note("copied the title") }
        }
        if pip.path != nil {
            Button("Delete") { model.perform(.delete) { model.deleteIssue(pip.id) } }
        }
    }

    static func menuVerbs(_ pip: IssuePip) -> [RowVerb] {
        var verbs = pip.state.verbs.filter { verb in
            switch verb {
            case .markDone: return pip.path != nil

            case .fix:      return false
            default:        return pip.runId != nil
            }
        }
        if pip.state.hasDiff, pip.runId != nil, !verbs.contains(.diff) { verbs.append(.diff) }
        return verbs
    }

    static func menuTitle(_ verb: RowVerb, pip: IssuePip) -> String {
        switch verb {
        case .fix:       return pip.runId == nil ? "Fix it" : "Fix it again"
        case .retry:     return "Retry"
        case .watch:     return "Watch the log"
        case .stop:      return "Stop"
        case .reply:     return "Reply"
        case .diff:      return "Diff"
        case .merge:     return "Merge"
        case .resolve:   return "Send \(pip.agent) back to it"
        case .rebase:    return "Rebase onto its base"
        case .discard:   return "Discard the branch"
        case .undoMerge: return "Undo the merge"
        case .markDone:  return "Mark done"
        default:         return verb.label
        }
    }

    static func run(_ verb: RowVerb, pip: IssuePip, model: AppModel) {
        model.perform(verb) {
            switch verb {
            case .fix:       model.open(pip)
            case .markDone:  model.markDone(pip)
            case .delete:    model.deleteIssue(pip.id)
            case .diff:      if let runId = pip.runId { model.openDiff(runId) }
            case .watch:     if let runId = pip.runId { model.watchRun(runId) }
            case .reply:     if let runId = pip.runId { model.startReply(to: runId) }
            case .rebase:    if let runId = pip.runId { model.rebaseRun(runId) }
            case .resolve:   if let runId = pip.runId { model.resolveRun(runId) }
            case .discard:   if let runId = pip.runId { model.discardRun(runId) }
            case .stop:      if let runId = pip.runId { model.runAction("stop", runId: runId) }
            case .retry:     if let runId = pip.runId { model.runAction("retry", runId: runId) }
            case .merge:
                if let runId = pip.runId {
                    model.runAction("merge", runId: runId)
                    model.note("merging \(pip.title)…")
                }
            case .undoMerge:
                if let runId = pip.runId {
                    model.runAction("undo", runId: runId)
                    model.note("taking that merge back…")
                }
            case .resume:    if let runId = pip.runId { model.resumeRun(runId) }
            case .openFile:  if let path = pip.path { model.open(path: path) }
            default:         break
            }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct VanishingRow: ViewModifier {
    let leaving: Bool

    @State private var natural: CGFloat?
    @State private var struck = false
    @State private var folded = false

    private static let strike = 0.20
    private static let fold = 0.18

    func body(content: Content) -> some View {
        content
            .opacity(struck ? 0.45 : 1)
            .offset(x: folded ? -7 : 0)
            .overlay(alignment: .leading) { cut }
            .background(ruler)

            .frame(height: leaving ? (folded ? 0 : natural) : nil, alignment: .top)
            .opacity(folded ? 0 : 1)
            .clipped()

            .allowsHitTesting(!leaving)
            .onChange(of: leaving) { _, isLeaving in
                guard isLeaving else { return }
                withAnimation(.easeOut(duration: VanishingRow.strike)) { struck = true }
                withAnimation(.easeIn(duration: VanishingRow.fold)
                    .delay(VanishingRow.strike)) { folded = true }
            }

            .onAppear { if leaving { struck = true; folded = true } }
    }

    private var cut: some View {
        Rectangle()
            .fill(LinearGradient(colors: [ouroOrange, ouroOrange.opacity(0.15)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 1)
            .scaleEffect(x: struck ? 1 : 0, anchor: .leading)
            .opacity(leaving ? 1 : 0)
    }

    private var ruler: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { if !leaving { natural = geo.size.height } }
                .onChange(of: geo.size.height) { _, height in
                    if !leaving { natural = height }
                }
        }
    }
}

extension View {
    func vanishing(_ leaving: Bool) -> some View {
        modifier(VanishingRow(leaving: leaving))
    }
}

struct WorkGlyph: View {
    let state: WorkState

    var body: some View {
        Group {
            switch state {
            case .filed:     ring(Color.primary.opacity(0.32))
            case .queued:    ring(state.tint.opacity(0.75))
            case .running:   spinner
            case .asking:    halo
            case .review:    target

            case .conflicts: symbol("exclamationmark", weight: .heavy, fade: 1)

            case .obsolete:  ring(Color.primary.opacity(0.22))
            case .merged:    symbol("checkmark", weight: .bold, fade: 0.7)
            case .failed:    symbol("xmark", weight: .heavy, fade: 1)
            case .stopped:   symbol("minus", weight: .bold, fade: 0.8)
            }
        }

        .frame(width: 9, height: 9)
    }

    private func ring(_ tint: Color) -> some View {
        Circle().strokeBorder(tint, lineWidth: 1).frame(width: 6.5, height: 6.5)
    }

    private var spinner: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(state.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 7.5, height: 7.5)
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 200))
        }
    }

    private var halo: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
            let phase = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2.6)
            ZStack {
                Circle()
                    .strokeBorder(state.tint.opacity(0.6 * (1 - phase)), lineWidth: 1)
                    .frame(width: 5 + 4 * phase, height: 5 + 4 * phase)
                Circle().fill(state.tint).frame(width: 4.5, height: 4.5)
            }
        }
    }

    private var target: some View {
        ZStack {
            Circle().strokeBorder(state.tint.opacity(0.5), lineWidth: 1)
                .frame(width: 8.5, height: 8.5)
            Circle().fill(state.tint).frame(width: 3.5, height: 3.5)
        }
    }

    private func symbol(_ name: String, weight: Font.Weight, fade: Double) -> some View {
        Image(systemName: name)
            .font(.system(size: 6.5, weight: weight))
            .foregroundStyle(state.tint.opacity(fade))
    }
}

struct IssueRow: View {
    let pip: IssuePip

    var project: String?

    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    private var leaving: Bool { model.isLeaving(pip.id) }

    var body: some View {
        HStack(spacing: 7) {
            WorkGlyph(state: pip.state)

            if let project {
                Text(project)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineLimit(1)
                    .fixedSize()
            }

            Text(pip.title)
                .font(.system(size: 11))
                .foregroundStyle(titleTint)
                .strikethrough(pip.state == .merged, color: Color.primary.opacity(0.35))
                .lineLimit(1)
                .truncationMode(.tail)

            if pip.attempts > 1 {
                Text("×\(pip.attempts)")
                    .font(.system(size: 8.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .help("\(pip.attempts) attempts at this issue; the newest is shown")
            }

            Spacer(minLength: 8)

            if hovering, !leaving { verbs }

            Text(pip.state.label)
                .font(.system(size: 9.5))
                .foregroundStyle(pip.state.isHollow ? Color.primary.opacity(0.45) : pip.state.tint)
                .fixedSize()

            Text(Ago.short(pip.at))
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(hovering ? 0.55 : 0.4))
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard pip.path != nil else { return }
            RowActions.run(.openFile, pip: pip, model: model)
        }
        .contextMenu { RowActions.issueMenu(pip, model: model) }
        .vanishing(leaving)
    }

    private var titleTint: Color {
        let lit = hovering && !leaving
        if pip.state == .merged { return Color.primary.opacity(lit ? 0.55 : 0.38) }
        return lit ? Color.primary : Color.primary.opacity(0.72)
    }

    @ViewBuilder
    private var verbs: some View {
        HStack(spacing: 2) {
            ForEach(offered, id: \.self) { verb in
                VerbButton(verb: verb, hint: hint(for: verb)) {
                    RowActions.run(verb, pip: pip, model: model)
                }
            }
        }
        .padding(.trailing, 1)
    }

    private var offered: [RowVerb] {
        pip.state.verbs.filter { verb in
            switch verb {
            case .markDone, .delete: return pip.path != nil
            case .fix:               return pip.canResume || pip.path != nil
            default:                 return pip.runId != nil
            }
        }
    }

    private func hint(for verb: RowVerb) -> String {
        switch verb {
        case .fix:       return pip.canResume ? "reopen this in \(pip.agent)"
                                             : "put an agent on it now"
        case .watch:     return "follow \(pip.agent)'s output"
        case .reply:     return "answer \(pip.agent)"
        case .diff:      return "what it changed"
        case .merge:     return "land it"
        case .resolve:   return "send \(pip.agent) back to sort it out"
        case .rebase:    return "put it back on top of its base"
        case .discard:   return "its work is already on the base"
        case .undoMerge: return "revert the merge"
        case .retry:     return "run it again"
        case .stop:      return "abandon this run"
        case .markDone:  return "done"
        default:         return verb.label
        }
    }
}

private struct VerbButton: View {
    let verb: RowVerb
    let hint: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: verb.symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                Text(verb.label)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(tint)

            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hovering ? tint.opacity(0.16) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(hovering ? tint.opacity(0.3) : Color.clear, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(hint)
    }

    private var tint: Color {
        switch verb {
        case .fix, .retry, .reply, .resolve: return ouroOrange
        case .merge:               return WorkState.merged.tint
        case .rebase:              return WorkState.conflicts.tint
        case .stop:                return WorkState.failed.tint
        default:                   return hovering ? Color.primary.opacity(0.75) : .secondary
        }
    }
}
