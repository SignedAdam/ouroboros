import Foundation
import SwiftUI
import ZeroCore

struct ProjectsDrawer: View {
    @ObservedObject var model: AppModel
    var expanded: Bool
    var onToggle: () -> Void

    private let corner: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            needsYou
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

        .padding(.horizontal, 17)
    }

    @ViewBuilder
    private var needsYou: some View {
        let waiting = model.waitingOnYou
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(waiting) { row in
                    IssueRow(pip: row.pip, project: row.project)
                        .padding(.horizontal, 13)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 5)
            .background(alignment: .leading) {
                Rectangle()
                    .fill(LinearGradient(colors: [ouroOrange, ouroOrange.opacity(0.15)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 2)
                    .padding(.vertical, 4)
            }
        }
    }

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
                live
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var live: some View {
        if expanded {
            EmptyView()
        } else if model.stats.running > 0 {
            HStack(spacing: 5) {
                LiveDot()
                Text("\(model.stats.running) running")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(ouroOrange)
            }
            .fixedSize()
        } else if reviewable > 0 {
            Text("\(reviewable) to review")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(WorkState.review.tint)
                .fixedSize()
        }
    }

    private var reviewable: Int {
        model.recents.reduce(0) { $0 + $1.tally.review + $1.tally.asking }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.recents.isEmpty {
                Text(model.connected ? "no projects — /add one" : "daemon down")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            } else {
                let ours = model.visibleRecents.filter { $0.section != .git }
                let theirs = model.visibleRecents.filter { $0.section == .git }
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

private struct ProjectRow: View {
    let digest: ProjectDigest
    let selected: Bool
    var onSelect: () -> Void

    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    private var project: Project? {
        model.projects.first { $0.id == digest.id }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            SelectionRail(lit: selected, tall: selected && !issues.isEmpty)

            VStack(alignment: .leading, spacing: 3) {
                Button(action: onSelect) {
                    headline.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .contextMenu {
                    if let project { RowActions.projectMenu(project, model: model) }
                }

                if selected { work }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)

        .padding(.vertical, selected ? 5 : 3)
        .background(rowBackground)

        .padding(.horizontal, 5)
        .vanishing(model.isLeaving(digest.id))
    }

    private var headline: some View {
        HStack(spacing: 6) {
            Text(digest.name)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(1)

            if digest.favourite {
                Image(systemName: "star.fill")
                    .font(.system(size: 6.5))
                    .foregroundStyle(ouroOrange.opacity(0.8))
            }

            Spacer(minLength: 8)
            if hovering { hoverActions }

            note
            TallyBar(tally: digest.tally)
            age
        }
        .help(tooltip)
    }

    private var issues: [IssuePip] { model.issues(of: digest) }

    private var headlineNote: (text: String, tint: Color, loud: Bool)? {
        let tally = digest.tally
        if tally.asking > 0 {
            let text = tally.asking == 1 ? "needs you" : "\(tally.asking) need you"
            return (text, WorkState.asking.tint, true)
        }
        if tally.conflicts > 0 {
            return ("\(tally.conflicts) conflict\(tally.conflicts == 1 ? "" : "s")",
                    WorkState.conflicts.tint, true)
        }
        if tally.failed > 0 { return ("\(tally.failed) failed", WorkState.failed.tint, true) }
        if tally.review > 0 { return ("\(tally.review) to review", WorkState.review.tint, true) }
        if tally.running > 0 {
            return ("\(tally.running) running", WorkState.running.tint, false)
        }
        if tally.filed > 0 { return ("\(tally.filed) filed", Color.primary.opacity(0.45), false) }

        if tally.merged > 0 { return ("\(tally.merged) done", Color.primary.opacity(0.38), false) }
        if let kind = digest.pulse?.kind, !kind.isEmpty {
            return (kind, Color.primary.opacity(0.42), false)
        }
        return nil
    }

    @ViewBuilder
    private var note: some View {
        if let note = headlineNote {
            if note.loud {
                Text(note.text)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(note.tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule(style: .continuous).fill(note.tint.opacity(0.16)))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(note.tint.opacity(0.32), lineWidth: 0.5))
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text(note.text)
                    .font(.system(size: 9.5))
                    .foregroundStyle(note.tint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var tooltip: String {
        let tally = digest.tally
        var lines = [digest.name]
        let open = tally.openStates.map { "\($0.count) \($0.state.label)" }
        lines.append(open.isEmpty ? "nothing open" : open.joined(separator: " · "))
        if tally.total > 0 {
            lines.append("\(tally.merged) done · \(tally.total) total")
        } else if let pulse = digest.pulse, !pulse.text.isEmpty {
            lines.append("\(pulse.kind): \(pulse.text)")
        }
        return lines.joined(separator: "\n")
    }

    private var age: some View {
        Text(ageLabel)
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.primary.opacity(selected || hovering ? 0.6 : 0.42))
            .frame(width: 24, alignment: .trailing)
    }

    @ViewBuilder
    private var hoverActions: some View {
        if let project {
            HStack(spacing: 3) {
                Button {
                    model.perform(.favourite) {
                        model.patchProject(project.id,
                                           API.PatchProject(favourite: !project.favourite))
                    }
                } label: {
                    glyph(project.favourite ? "star.slash" : "star")
                }
                .help(project.favourite ? "unpin" : "pin to the top")

                Button {
                    model.perform(.openFinder) { model.open(path: project.path) }
                } label: {
                    glyph("folder")
                }
                .help("open in Finder")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
        }
    }

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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(
                    stops: [.init(color: ouroOrange.opacity(0.17), location: 0),
                            .init(color: ouroOrange.opacity(0.05), location: 0.5),
                            .init(color: ouroOrange.opacity(0.03), location: 1)],
                    startPoint: .leading, endPoint: .trailing))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(ouroOrange.opacity(0.18), lineWidth: 0.5))
        } else if hovering {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
    }

    private var ageLabel: String {
        if let lead = issues.first { return Ago.short(lead.at) }
        if let at = digest.pulse?.at { return Ago.short(at) }
        return ""
    }

    @ViewBuilder
    private var work: some View {
        VStack(alignment: .leading, spacing: 1) {
            let rest = model.remainingIssues(of: digest)
            if rest.isEmpty {
                if issues.isEmpty {
                    Text(digest.handled ? "nothing open" : "never run here — ⌘⏎ starts it")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            } else {
                ForEach(rest) { pip in
                    IssueRow(pip: pip)
                }
            }
        }

        .padding(.leading, 1)
        .padding(.top, 3)
        .padding(.bottom, 1)
    }
}

private struct LiveDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
            let phase = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2.2)
            Circle()
                .fill(ouroOrange)
                .frame(width: 5, height: 5)
                .opacity(0.5 + 0.5 * phase)
                .shadow(color: ouroOrange.opacity(0.65 * phase), radius: 3)
        }
    }
}

private struct SelectionRail: View {
    let lit: Bool

    let tall: Bool

    var body: some View {
        Capsule(style: .continuous)
            .fill(LinearGradient(gradient: Gradient(stops: stops),
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 2.5)
            .shadow(color: ouroOrange.opacity(0.5), radius: 3.5)
            .opacity(lit ? 1 : 0)
            .scaleEffect(y: lit ? 1 : 0.3, anchor: .top)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: lit)
    }

    private var stops: [Gradient.Stop] {
        guard tall else {
            return [.init(color: ouroOrange, location: 0),
                    .init(color: ouroOrange.opacity(0.7), location: 1)]
        }
        return [.init(color: ouroOrange, location: 0),
                .init(color: ouroOrange.opacity(0.9), location: 0.25),
                .init(color: ouroOrange.opacity(0.28), location: 1)]
    }
}

private struct TallyBar: View {
    let tally: Tally

    private let width: CGFloat = 34
    private let gap: CGFloat = 1.5

    private let minimum: CGFloat = 3

    private struct Slice: Identifiable {
        let state: WorkState
        let width: CGFloat
        var id: WorkState { state }
    }

    var body: some View {
        if tally.openStates.count > 1 { bar }
    }

    private var bar: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !alive)) { context in
            let phase = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2.2)
            HStack(spacing: gap) {
                ForEach(slices) { slice in
                    Capsule(style: .continuous)
                        .fill(slice.state.tint.opacity(opacity(of: slice.state, phase: phase)))
                        .frame(width: slice.width)
                }
            }

            .frame(width: width, height: 3.5, alignment: .leading)
        }
    }

    private var alive: Bool { tally.running + tally.queued + tally.asking > 0 }

    private func opacity(of state: WorkState, phase: Double) -> Double {
        guard state == .running || state == .queued || state == .asking else {
            return state.isHollow ? 0.4 : 0.9
        }
        return 0.55 + 0.45 * phase
    }

    private var slices: [Slice] {
        let states = tally.openStates
        guard !states.isEmpty else { return [] }
        let total = CGFloat(states.reduce(0) { $0 + $1.count })
        let usable = width - gap * CGFloat(states.count - 1)
        let slack = max(0, usable - minimum * CGFloat(states.count))
        return states.map {
            Slice(state: $0.state, width: minimum + slack * (CGFloat($0.count) / total))
        }
    }
}
