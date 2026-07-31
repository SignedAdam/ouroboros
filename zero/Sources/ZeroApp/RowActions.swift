import SwiftUI
import AppKit
import ZeroCore

/// The verbs behind every row in the drawer.
///
/// Every object on screen has the same small, predictable set of verbs, reached
/// the same two ways — right-click for all of them, hover for the one or two you
/// want most often. Every verb is an API call: nothing in this file knows how to
/// move a file or run git, it asks the daemon exactly as `ouro` does.
@MainActor
enum RowActions {

    // MARK: projects

    @ViewBuilder
    static func projectMenu(_ project: Project, model: AppModel) -> some View {
        Button("Capture into \(project.name)") { model.selectedProjectId = project.id }
        Divider()
        Button(project.favourite ? "Unpin" : "Pin to the top") {
            model.patchProject(project.id, API.PatchProject(favourite: !project.favourite))
        }
        // "Until active again" is the whole contract, so the menu says it rather
        // than leaving you to find out that hiding is not forgetting.
        Button("Hide until active again") {
            model.patchProject(project.id, API.PatchProject(hidden: true))
        }
        Divider()
        Menu("Agent") {
            ForEach(model.availableAgents, id: \.self) { agent in
                Button(agent + (project.defaultAgent == agent ? "  ✓" : "")) {
                    model.patchProject(project.id, API.PatchProject(defaultAgent: agent))
                }
            }
        }
        Menu("When a fix passes") {
            Button("Leave it on its branch" + (project.policy.autonomy == .manual ? "  ✓" : "")) {
                model.patchProject(project.id, API.PatchProject(autonomy: "manual"))
            }
            Button("Merge it for me" + (project.policy.autonomy == .auto ? "  ✓" : "")) {
                model.patchProject(project.id, API.PatchProject(autonomy: "auto"))
            }
        }
        Divider()
        Button("Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
        Button("Terminal") { model.openTerminal(at: project.path) }
        Button("Agent view") { model.openAgentView(project) }
        Button("Copy path") { copy(project.path) }
        Divider()
        Button("Remove from Ouroboros") { model.forgetProject(project.id) }
    }

    // MARK: work

    /// One menu for every state, because to the person who typed the sentence
    /// there is one object here, not an issue and a run.
    @ViewBuilder
    static func issueMenu(_ pip: IssuePip, model: AppModel) -> some View {
        if pip.canResume, let runId = pip.runId {
            Button("Resume in \(pip.agent)") { model.resumeRun(runId) }
        }
        if pip.path != nil {
            Menu(pip.runId == nil ? "Start" : "Start again") {
                ForEach(model.availableAgents, id: \.self) { agent in
                    Button(agent) { model.open(pip, agent: agent) }
                }
            }
        }
        if let runId = pip.runId {
            Divider()
            if pip.state == .ready {
                Button("Merge") { model.runAction("merge", runId: runId) }
            }
            if pip.state.isLive {
                Button("Stop") { model.runAction("stop", runId: runId) }
            } else {
                Button("Retry") { model.runAction("retry", runId: runId) }
            }
            if pip.state == .landed {
                Button("Undo the merge") { model.runAction("undo", runId: runId) }
            }
            Button("Copy log command") { model.openLog(runId) }
            Button("Copy diff command") { model.showDiff(runId) }
            Button("Worktree") { model.openWorktree(runId) }
        }
        Divider()
        if let path = pip.path {
            Button("Open file") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
        Button("Copy title") { copy(pip.title) }
        if pip.path != nil {
            Button("Mark done") { model.markDone(pip) }
            Button("Delete") { model.deleteIssue(pip.id) }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One piece of work, as a row you can act on.
///
/// Reads without hovering: a dot says how it is going, the title says what it
/// is, the right edge names the state. Hovering adds the two verbs worth a
/// single click — get an agent onto it, and tick it off.
struct IssueRow: View {
    let pip: IssuePip
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            // Hollow means nobody has been dispatched. That single distinction
            // is the difference between work in flight and work rotting.
            Circle()
                .strokeBorder(pip.state.tint, lineWidth: pip.state.isHollow ? 1 : 2.5)
                .frame(width: 5, height: 5)

            Text(pip.title)
                .font(.system(size: 11))
                .foregroundStyle(hovering ? Color.primary : Color.primary.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)

            if pip.attempts > 1 {
                Text("×\(pip.attempts)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }

            Spacer(minLength: 8)

            if hovering { verbs }

            Text(pip.state.label)
                .font(.system(size: 9.5))
                .foregroundStyle(pip.state.isHollow ? Color.secondary : pip.state.tint)
                .fixedSize()

            Text(Ago.short(pip.at))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 22, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard let path = pip.path else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        .contextMenu { RowActions.issueMenu(pip, model: model) }
    }

    /// Two, never more. Everything else is a right-click away.
    ///
    /// Each one carries its own padding and hit shape: a bare 8pt glyph is a
    /// target you miss, and a miss here drags the whole panel, because the
    /// capture window is movable by its background.
    @ViewBuilder
    private var verbs: some View {
        HStack(spacing: 4) {
            if pip.canResume || pip.path != nil {
                Button { model.open(pip) } label: {
                    Text(pip.canResume ? "open" : "fix")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ouroOrange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pip.canResume ? "reopen this conversation in \(pip.agent)"
                                    : "put an agent on it now")
            }
            if pip.path != nil {
                Button { model.markDone(pip) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("done")
            }
        }
        .padding(.trailing, 3)
    }
}
