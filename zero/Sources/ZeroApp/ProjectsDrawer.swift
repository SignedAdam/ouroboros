import SwiftUI
import ZeroCore

/// The drawer that latches onto the bottom of the capture panel.
///
/// It answers one question — what is Ouroboros doing, and where would I pick up
/// again — and it answers it in one line per project. Projects are the index;
/// the work is the content, so opening a project is what reveals its issues.
///
/// It is deliberately a *second surface*: narrower than the panel, dimmer, with
/// its own edge, tucked under the panel's bottom lip like a card behind a card.
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
                Text("projects")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 10)
                // One fact, and always the most urgent one available. A footer
                // carrying four numbers is a footer nobody reads.
                Text(summary)
                    .font(.system(size: 9.5))
                    .foregroundStyle(model.stats.running > 0 ? ouroOrange : Color.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        let stats = model.stats
        if stats.running > 0 { return "\(stats.running) running" }
        if stats.tasks > 0 { return "\(stats.tasks) open" }
        if stats.fixed > 0 { return "\(stats.fixed) fixed" }
        return stats.projects > 0 ? "\(stats.projects) projects" : "none yet"
    }

    // MARK: the list

    /// Two groups. Projects Ouroboros works on come first and carry no header at
    /// all — they are the default, and a label over the top of a list you are
    /// already looking at is a label that explains itself. The git group gets one
    /// word, at a weight you can actually read.
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.recents.isEmpty {
                Text(model.connected ? "no projects — /add one" : "daemon down")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            } else {
                let ours = model.recents.filter { $0.section != .git }
                let theirs = model.recents.filter { $0.section == .git }
                ForEach(ours) { row($0) }
                if !theirs.isEmpty {
                    groupRule
                    ForEach(theirs) { row($0) }
                }
            }
        }
        .padding(.top, 3)
        .padding(.bottom, 7)
    }

    private func row(_ digest: ProjectDigest) -> some View {
        ProjectRow(digest: digest,
                   selected: digest.id == model.selectedProject?.id,
                   onSelect: { model.selectedProjectId = digest.id })
    }

    /// A gap, a word, a hairline. The old header was grey small-caps on a grey
    /// surface, which is a decoration that costs a line and reads as nothing.
    private var groupRule: some View {
        HStack(spacing: 8) {
            Text("git")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.13))
                .frame(height: 1)
        }
        .padding(.horizontal, 13)
        .padding(.top, 9)
        .padding(.bottom, 4)
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
        // The issue rows are siblings of the project's button, never inside its
        // label: a plain Button swallows every click landing in it, so nesting
        // them would leave `fix`, `open` and the tick painted but dead.
        VStack(alignment: .leading, spacing: 3) {
            Button(action: onSelect) {
                headline.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .contextMenu {
                if let project { RowActions.projectMenu(project, model: model) }
            }

            // One line each, except the one you are aiming at. Eight projects at
            // three lines apiece was the "chonky" this rebuild is answering; the
            // work belongs to the project you actually asked about.
            if selected { work }
        }
        .padding(.leading, 11)
        .padding(.trailing, 13)
        .padding(.vertical, selected ? 5 : 3)
        .background(rowBackground)
    }

    private var headline: some View {
        HStack(spacing: 6) {
            // The only marker in the list. Not a bullet: a rail, lit for the
            // project this capture is going to.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(selected ? ouroOrange : Color.clear)
                .frame(width: 2, height: 12)

            Text(digest.name)
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium,
                              design: .rounded))
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(1)

            // A pin needs no section of its own: the star on the row says the
            // same thing in six points instead of twelve.
            if digest.favourite {
                Image(systemName: "star.fill")
                    .font(.system(size: 6.5))
                    .foregroundStyle(ouroOrange.opacity(0.8))
            }

            Spacer(minLength: 8)
            if hovering { hoverActions }

            // The reason this row is in the list, right-aligned, one fact: the
            // state of its latest work, or — for a project Ouroboros has never
            // been used in — the repo's own last move.
            Text(reason)
                .font(.system(size: 9.5))
                .foregroundStyle(reasonTint)
                .lineLimit(1)
                .fixedSize()

            Text(age)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 22, alignment: .trailing)
        }
    }

    /// The row says what it can do before you commit to a click. Only under the
    /// pointer, so a list of ten does not become a wall of buttons.
    @ViewBuilder
    private var hoverActions: some View {
        if let project {
            HStack(spacing: 3) {
                Button {
                    model.patchProject(project.id, API.PatchProject(favourite: !project.favourite))
                } label: {
                    glyph(project.favourite ? "star.slash" : "star")
                }
                .help(project.favourite ? "unpin" : "pin to the top")

                Button { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) } label: {
                    glyph("folder")
                }
                .help("open in Finder")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
        }
    }

    /// Padding and a hit shape, or the target is the glyph itself — and a miss
    /// on this panel drags the window rather than doing nothing.
    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
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

    // MARK: the right-hand fact

    /// Past tense, quiet, and it always names what it is counting. This slot
    /// used to hold `manual` / `auto`, which is a merge policy — a setting, not
    /// a status, and never a thing that happened to this project.
    private var reason: String {
        if let lead = digest.lead {
            if lead.state == .filed && digest.openCount > 1 { return "\(digest.openCount) filed" }
            return lead.state.label
        }
        return digest.pulse?.kind ?? ""
    }

    private var reasonTint: Color {
        // Colour is for the three things worth interrupting for. A git commit
        // is not one of them.
        guard let lead = digest.lead else { return Color.secondary.opacity(0.65) }
        switch lead.state {
        case .running, .queued, .asking: return ouroOrange
        case .failed, .ready: return lead.state.tint
        default: return .secondary
        }
    }

    private var age: String {
        if let lead = digest.lead { return Ago.short(lead.at) }
        if let at = digest.pulse?.at { return Ago.short(at) }
        return ""
    }

    // MARK: the open project

    /// Only the selected project spends the vertical space. Clicking a row is a
    /// deliberate act, so the height changes when you ask it to and never under
    /// a moving cursor.
    @ViewBuilder
    private var work: some View {
        VStack(alignment: .leading, spacing: 1) {
            if digest.issues.isEmpty {
                Text(digest.handled ? "nothing open" : "never run here — ⌘⏎ starts it")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(digest.issues) { pip in
                    IssueRow(pip: pip)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.top, 2)
        .padding(.bottom, 1)
    }
}
