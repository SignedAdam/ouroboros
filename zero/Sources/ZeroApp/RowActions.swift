import SwiftUI
import AppKit
import ZeroCore

/// The verbs behind every row in the drawer.
///
/// the operator's complaint about the first drawer was that it showed things and let you
/// do nothing with them. The fix is not "add a menu": it is that every object on
/// screen has the same small, predictable set of verbs, reachable the same two
/// ways — right-click for all of them, hover for the one you want most often.
///
/// Every verb here is an API call. Nothing in this file knows how to move a file
/// or run git; it asks the daemon, exactly as `ouro` does from a shell.
@MainActor
enum RowActions {

    // MARK: projects

    @ViewBuilder
    static func projectMenu(_ project: Project, model: AppModel) -> some View {
        Button("Capture into \(project.name)") { model.selectedProjectId = project.id }
        Divider()
        Button(project.favourite ? "Remove from favourites" : "Add to favourites") {
            model.patchProject(project.id, API.PatchProject(favourite: !project.favourite))
        }
        // "Until active again" is the whole contract, so the menu says it rather
        // than leaving you to find out that hiding is not forgetting.
        Button("Hide until active again") {
            model.patchProject(project.id, API.PatchProject(hidden: true))
        }
        Divider()
        Menu("Default agent") {
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
        Button("Open in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
        Button("Open in terminal") { model.openTerminal(at: project.path) }
        Button("Open agent view here") { model.openAgentView(project) }
        Button("Copy path") { copy(project.path) }
        Divider()
        Button("Remove from Ouroboros") { model.forgetProject(project.id) }
    }

    // MARK: tasks (filed issues)

    @ViewBuilder
    static func taskMenu(_ task: TaskPip, project: String, model: AppModel) -> some View {
        Button("Fix it now") { model.fixIssue(task.id) }
        Menu("Fix it with") {
            ForEach(model.availableAgents, id: \.self) { agent in
                Button(agent) { model.fixIssue(task.id, agent: agent) }
            }
        }
        Divider()
        Button("Open the issue file") { NSWorkspace.shared.open(URL(fileURLWithPath: task.path)) }
        Button("Copy title") { copy(task.title) }
        Divider()
        Button("Delete") { model.deleteIssue(task.id) }
    }

    // MARK: jobs (runs)

    @ViewBuilder
    static func jobMenu(_ run: Run, model: AppModel) -> some View {
        // The reason a run carries a session id at all: the conversation is the
        // most useful artefact an agent leaves behind, and it used to be
        // unreachable the moment the window closed.
        if run.sessionId != nil {
            Button("Resume this conversation") { model.resumeRun(run.id) }
            Divider()
        }
        Button("Open the log") { model.openLog(run.id) }
        if run.branch != nil {
            Button("Show the diff") { model.showDiff(run.id) }
        }
        if run.worktreePath != nil {
            Button("Open the worktree") { model.openWorktree(run.id) }
        }
        Divider()
        if run.status.isActive {
            Button("Stop it") { model.runAction("stop", runId: run.id) }
        } else {
            if run.status == .succeeded && run.mergedInto == nil {
                Button("Merge it") { model.runAction("merge", runId: run.id) }
            }
            if run.mergedInto != nil {
                Button("Undo the merge") { model.runAction("undo", runId: run.id) }
            }
            Button("Run it again") { model.runAction("retry", runId: run.id) }
            Button("Clear from the inbox") { model.runAction("ack", runId: run.id) }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A filed issue, as a row you can act on.
///
/// Click opens the file, hover offers the one verb worth a single click, and
/// right-click has the rest. Before this, a filed task was a line of grey text.
struct TaskRow: View {
    let task: TaskPip
    let project: String
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 3, height: 3)
            Text(task.title)
                .font(.system(size: 10))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering {
                Button("fix") { model.fixIssue(task.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ouroOrange)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: task.path)) }
        .contextMenu { RowActions.taskMenu(task, project: project, model: model) }
        .help("click opens the file · right-click for everything else")
    }
}

/// One run, as a row you can act on.
struct JobRow: View {
    let run: Run
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(run.status.tint)
                .frame(width: 4, height: 4)
            Text(run.title)
                .font(.system(size: 10))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(run.agent)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            if hovering, run.sessionId != nil {
                Button("open") { model.resumeRun(run.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ouroOrange)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { RowActions.jobMenu(run, model: model) }
        .help(run.sessionId != nil
              ? "right-click to resume the conversation this agent had"
              : "right-click for the log, diff and worktree")
    }
}
