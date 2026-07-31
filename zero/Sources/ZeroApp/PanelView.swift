import SwiftUI
import ZeroCore
import OuroborosUI

let ouroOrange = Color(red: 1.0, green: 0.48, blue: 0.09)

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var replyingTo: String?
    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            capture
            Divider()
            // Deliberately NOT a ScrollView: a MenuBarExtra window sizes itself
            // to its content, so it offers a ScrollView no height at all and the
            // whole body collapses to nothing. Cap the rows instead and let the
            // window grow — a panel this size should never need scrolling.
            VStack(alignment: .leading, spacing: 0) {
                if !model.inbox.isEmpty { inboxSection }
                if !model.activeRuns.isEmpty { inFlightSection }
                projectsSection
            }
            Divider()
            footer
        }
        .frame(width: 400)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            OuroborosMark()
                .foregroundStyle(model.runningCount > 0 ? ouroOrange : Color.secondary)
                .frame(width: 18, height: 18)
            Text("ouroboros")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            if model.runningCount > 0 {
                Text("\(model.runningCount) running")
                    .font(.system(size: 11)).foregroundStyle(ouroOrange)
            }
            Circle()
                .fill(model.connected ? Color.green.opacity(0.8) : Color.red.opacity(0.8))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    // MARK: capture

    private var capture: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("what's wrong?", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...6)
                .onSubmit { model.file(fix: false) }

            HStack(spacing: 8) {
                Menu {
                    ForEach(model.projects) { project in
                        Button(project.name) { model.selectedProjectId = project.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(model.selectedProject?.name ?? "no project")
                    }
                    .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button("File") { model.file(fix: false) }
                    .disabled(model.draft.isEmpty || model.busy)
                Button("File & fix") { model.file(fix: true) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.draft.isEmpty || model.busy)
                    .buttonStyle(.borderedProminent)
                    .tint(ouroOrange)
            }
            .font(.system(size: 11))

            if let status = model.status {
                Text(status)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    // MARK: inbox

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("needs you")
            ForEach(model.inbox.prefix(6)) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(item.tint).frame(width: 6, height: 6).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                            Text("\(item.label) · \(item.projectName)")
                                .font(.system(size: 10)).foregroundStyle(item.tint)
                            if !item.detail.isEmpty {
                                Text(item.detail)
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        Spacer()
                    }
                    actions(for: item)
                    if replyingTo == item.id {
                        HStack(spacing: 6) {
                            TextField("your answer…", text: $replyText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .onSubmit { sendReply(item) }
                            Button("Send") { sendReply(item) }
                                .font(.system(size: 10))
                                .disabled(replyText.isEmpty)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider().opacity(0.4)
            }
            if model.inbox.count > 6 {
                Text("+\(model.inbox.count - 6) more — `ouro inbox`")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func actions(for item: InboxItem) -> some View {
        HStack(spacing: 10) {
            ForEach(item.actions, id: \.self) { action in
                Button(actionLabel(action)) { perform(action, item) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(action == "reply" || action == "merge" ? ouroOrange : Color.secondary)
            }
            Spacer()
        }
        .padding(.leading, 14)
    }

    private func actionLabel(_ action: String) -> String {
        switch action {
        case "reply":   return "Answer"
        case "merge":   return "Merge"
        case "undo":    return "Undo"
        case "retry":   return "Retry"
        case "diff":    return "Diff"
        case "log":     return "Log"
        case "fix":     return "Accept"
        case "dismiss": return "Dismiss"
        default:        return "Clear"
        }
    }

    private func perform(_ action: String, _ item: InboxItem) {
        if action == "reply" {
            replyingTo = replyingTo == item.id ? nil : item.id
            replyText = ""
            return
        }
        if let proposalId = item.proposalId {
            model.proposalAction(action == "fix" ? "accept" : "dismiss", id: proposalId)
            return
        }
        guard let runId = item.runId else { return }
        if action == "diff" || action == "log" {
            copyToPasteboard("ouro \(action) \(runId)")
            model.status = "copied: ouro \(action) \(runId)"
            return
        }
        model.runAction(action, runId: runId)
    }

    private func sendReply(_ item: InboxItem) {
        guard let runId = item.runId, !replyText.isEmpty else { return }
        model.runAction("reply", runId: runId, answer: replyText)
        replyingTo = nil
        replyText = ""
    }

    // MARK: in flight

    private var inFlightSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("in flight")
            ForEach(model.activeRuns) { run in
                HStack(spacing: 8) {
                    Circle().fill(run.status.tint).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.title).font(.system(size: 12)).lineLimit(1)
                        Text("\(run.status.label) · \(run.projectName) · \(run.agent)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(run.elapsedLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button {
                        model.runAction("stop", runId: run.id)
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
    }

    // MARK: projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("projects")
            if model.projects.isEmpty {
                Text("none yet — run `ouro projects discover ~/dev`")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            ForEach(model.projects.prefix(8)) { project in
                let running = model.activeRuns.filter { $0.projectId == project.id }.count
                Button {
                    model.selectedProjectId = project.id
                } label: {
                    HStack(spacing: 8) {
                        Text(project.name)
                            .font(.system(size: 12,
                                          weight: project.id == model.selectedProject?.id ? .semibold : .regular))
                        Text(project.policy.autonomy.label)
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer()
                        if running > 0 {
                            Text("●\(running)").font(.system(size: 10)).foregroundStyle(ouroOrange)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 4)
            }
        }
        .padding(.bottom, 8)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.8)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 5)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            // The key the app is really listening on, not a hard-coded one: the
            // configured combo is only a preference and any of them can be
            // taken, so a literal here goes stale the first time a fallback wins.
            Text(HotkeyCombo.captureHint(active: HotkeyManager.current))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
