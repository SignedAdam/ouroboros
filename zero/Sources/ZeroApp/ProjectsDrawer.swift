import SwiftUI
import ZeroCore

/// The drawer that latches onto the bottom of the capture panel.
///
/// It is deliberately a *second surface*: narrower than the panel, dimmer,
/// with its own edge, tucked under the panel's bottom lip like a card behind a
/// card. The capture box is about the sentence you are typing; this is about
/// everywhere that sentence could go. Folded, it is a single line — a footer
/// that tells you what Ouroboros has been doing while you were not looking.
/// Unfolded, the same line stays put and the projects unroll beneath it.
struct ProjectsDrawer: View {
    @ObservedObject var model: AppModel
    var expanded: Bool
    var onToggle: () -> Void

    /// Matches the panel's 14pt radius, one point tighter — the drawer is the
    /// smaller card, and a smaller card wants a smaller curve.
    private let corner: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rail
            if expanded {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                    .padding(.horizontal, 11)
                list
            }
        }
        .background(surface)
        .clipShape(
            UnevenRoundedRectangle(bottomLeadingRadius: corner,
                                   bottomTrailingRadius: corner, style: .continuous))
        .overlay(DrawerEdge(radius: corner).stroke(ouroOrange.opacity(0.16), lineWidth: 1))
        // Wider than the panel's own corner radius, so the drawer's square top
        // corners land inside the straight part of the panel's bottom edge and
        // the join has no notch in it.
        .padding(.horizontal, 17)
    }

    // MARK: the footer line

    private var rail: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .black))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 7)
                Text("OTHER PROJECTS")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.9)
                    .foregroundStyle(.secondary)
                if !model.recents.isEmpty {
                    Text("\(model.recents.count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
                Spacer(minLength: 10)
                ledger
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The far end of the footer: what Ouroboros has actually done. The tape is
    /// the last dozen runs as coloured ticks, which answers "is this thing
    /// working?" before you have read a single word of it.
    @ViewBuilder
    private var ledger: some View {
        let stats = model.stats
        HStack(spacing: 8) {
            if stats.running > 0 {
                HStack(spacing: 4) {
                    Circle().fill(ouroOrange).frame(width: 4, height: 4)
                    Text("\(stats.running) running")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(ouroOrange)
                }
            }
            if !stats.tape.isEmpty {
                RunTape(tape: stats.tape)
            }
            if stats.handled > 0 {
                HStack(spacing: 3) {
                    Text("\(stats.handled)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("handled")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            } else if stats.projects > 0 {
                Text("\(stats.projects) projects")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
        .fixedSize()
    }

    // MARK: the list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.recents.isEmpty {
                Text(model.connected
                     ? "no projects yet — type /add to point Ouroboros at a directory"
                     : "the daemon isn't running — `ouro daemon start`")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            } else {
                ForEach(model.recents) { digest in
                    ProjectRow(digest: digest,
                               selected: digest.id == model.selectedProject?.id,
                               onSelect: { model.selectedProjectId = digest.id })
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: the surface

    /// Material, a shade of recess, and a short gradient at the very top so the
    /// panel above reads as *resting on* this rather than merely next to it.
    private var surface: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.regularMaterial)
            Rectangle().fill(Color.black.opacity(0.07))
            LinearGradient(colors: [Color.black.opacity(0.18), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 6)
        }
    }
}

/// Three sides. The fourth is where the panel sits, and a line there would read
/// as a seam between two things instead of the join between one.
private struct DrawerEdge: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.maxY),
                          control: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - radius),
                          control: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return path
    }
}

/// Runs as ticks, oldest to newest. The whole system's on the footer; a
/// project's own four are on its row.
private struct RunTape: View {
    let tape: [RunStatus]
    var height: CGFloat = 9

    init(tape: some Sequence<RunStatus>, height: CGFloat = 9) {
        self.tape = Array(tape)
        self.height = height
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(tape.enumerated()), id: \.offset) { _, status in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(status.tint.opacity(status.isTerminal ? 0.7 : 1))
                    .frame(width: 3, height: height)
            }
        }
    }
}

// MARK: - a project

private struct ProjectRow: View {
    let digest: ProjectDigest
    let selected: Bool
    var onSelect: () -> Void

    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    /// The registry record behind the digest. The digest is a display shape; the
    /// verbs need the real project.
    private var project: Project? {
        model.projects.first { $0.id == digest.id }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 9) {
                // The only marker in the list. Not a bullet: a rail, lit for the
                // project this capture is going to.
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(selected ? ouroOrange : Color.clear)
                    .frame(width: 2)

                VStack(alignment: .leading, spacing: 2) {
                    headline
                    if let pulse = digest.pulse { pulseLine(pulse) }
                    if selected { detail.padding(.top, 5) }
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 13)
            .padding(.vertical, 6)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if let project { RowActions.projectMenu(project, model: model) }
        }
        .help("right-click to favourite, hide, set the agent, or open it")
    }

    /// The hover affordance: the row says what it can do before you commit to a
    /// click. Only on the row under the pointer, so a list of ten does not turn
    /// into a wall of buttons.
    @ViewBuilder
    private var hoverActions: some View {
        if hovering, let project {
            HStack(spacing: 7) {
                Button {
                    model.patchProject(project.id, API.PatchProject(favourite: !project.favourite))
                } label: {
                    Image(systemName: project.favourite ? "star.fill" : "star")
                }
                .help(project.favourite ? "remove from favourites" : "keep this one at the top")

                Button { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) } label: {
                    Image(systemName: "folder")
                }
                .help("open in Finder")
            }
            .buttonStyle(.plain)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        } else if let project, project.favourite {
            Image(systemName: "star.fill")
                .font(.system(size: 8))
                .foregroundStyle(ouroOrange.opacity(0.7))
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if selected {
            ouroOrange.opacity(0.08)
        } else if hovering {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
    }

    private var headline: some View {
        HStack(spacing: 6) {
            Text(digest.name)
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium,
                              design: .rounded))
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(1)

            // Was a bare "auto" chip, which read as a property of a job and
            // meant nothing to anyone who had not read the source. Autonomy is a
            // policy about MERGING, so it says what it will do to your code, and
            // only when it is going to do something surprising.
            if digest.autonomy == .auto {
                Text("auto-merge")
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(ouroOrange.opacity(0.85))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(ouroOrange.opacity(0.12), in: Capsule())
                    .help("verified fixes merge into this project without asking")
            }

            if digest.running > 0 {
                HStack(spacing: 3) {
                    Circle().fill(ouroOrange).frame(width: 4, height: 4)
                    Text("\(digest.running)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ouroOrange)
                }
                .help("\(digest.running) agent\(digest.running == 1 ? "" : "s") working here right now")
            }

            Spacer(minLength: 4)
            hoverActions

            Spacer(minLength: 8)

            // Every row wears its own history, in the same ticks the footer
            // uses for the whole system. Four of them says more about a project
            // than any number would.
            if !digest.jobs.isEmpty {
                RunTape(tape: digest.jobs.prefix(4).map(\.status).reversed(), height: 7)
            }

            if digest.taskCount > 0 && !selected {
                Text("\(digest.taskCount) task\(digest.taskCount == 1 ? "" : "s")")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if let at = digest.pulse?.at {
                Text(Ago.short(at))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    /// What happened here last, in the language of what happened.
    private func pulseLine(_ pulse: Pulse) -> some View {
        HStack(spacing: 5) {
            Text(pulse.kind)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(pulse.kind == "filed" ? ouroOrange.opacity(0.9) : Color.secondary)
            if !pulse.text.isEmpty {
                Text(pulse.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // MARK: the open project

    /// Only the selected project spends the vertical space. Clicking a row is a
    /// deliberate act, so the height changes when you ask it to and never under
    /// a moving cursor.
    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !digest.jobs.isEmpty {
                section("JOBS", count: digest.jobs.count) {
                    ForEach(digest.jobs.prefix(2)) { job in
                        HStack(spacing: 6) {
                            Circle().fill(job.status.tint).frame(width: 4, height: 4)
                            Text(job.title)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(job.status.label)
                                .font(.system(size: 9))
                                .foregroundStyle(job.status.tint.opacity(0.9))
                            if let seconds = job.seconds {
                                Text(ProjectRow.elapsed(seconds))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.quaternary)
                            }
                        }
                    }
                }
            }

            if !digest.tasks.isEmpty {
                section("TASKS", count: digest.taskCount) {
                    ForEach(digest.tasks.prefix(2)) { task in
                        TaskRow(task: task, project: digest.id)
                    }
                }
            }

            if digest.jobs.isEmpty && digest.tasks.isEmpty {
                Text(digest.handled
                     ? "nothing open here"
                     : "Ouroboros has never run here — ⌘⏎ starts it")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// A label and a hairline that owns the rows under it — cheaper than a box,
    /// and the count lives in the label so "and 3 more" never costs a line.
    private func section<Content: View>(_ title: String, count: Int,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(0.7)
                Text("\(count)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.quaternary)

            HStack(alignment: .top, spacing: 7) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
                VStack(alignment: .leading, spacing: 2) { content() }
            }
        }
    }

    static func elapsed(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }
}
