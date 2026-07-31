import Foundation
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
            // Above the projects and above the fold, because what is waiting on
            // you is not a property of any one project and must not be found by
            // opening them one at a time. Empty is the normal case, and empty
            // costs nothing: no header, no placeholder, no height.
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
        // Wider than the panel's own corner radius, so the drawer's square top
        // corners land inside the straight part of the panel's bottom edge and
        // the join has no notch in it.
        .padding(.horizontal, 17)
    }

    // MARK: what needs you

    /// Everything waiting on a person, across every project, lifted out of the
    /// per-project lists that used to bury it.
    ///
    /// The set comes from `AppModel.waitingOnYou`, which reads the inbox — the
    /// same `Inbox.build` that `ouro inbox` prints — so the drawer and the CLI
    /// cannot come to different conclusions about what is outstanding.
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
                // The one mark the group gets. A word over the top of it would
                // be a label explaining a list you have already read.
                Rectangle()
                    .fill(LinearGradient(colors: [ouroOrange, ouroOrange.opacity(0.15)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 2)
                    .padding(.vertical, 4)
            }
        }
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
                live
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Only what is true of the machine as a whole, and only while it is true.
    ///
    /// This slot used to always say something — "11 open", "6 projects" —
    /// counted over the handful of projects the drawer happens to be showing.
    /// A number that looks global and is not is worse than no number: it was
    /// read as a total, and there are far more projects than the drawer lists.
    /// Work in flight and work waiting on a review are genuinely countable, so
    /// they are all this says, and the rest of the time it says nothing.
    @ViewBuilder
    private var live: some View {
        // And only while the list is folded away. Open, every row says this for
        // itself, and the rail repeating "1 to review" directly above the row
        // that says "1 to review" is the same fact printed twice.
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

    /// Counted from the digests rather than `stats`, which folds review and
    /// merged together under `fixed` and so cannot tell "waiting for you" from
    /// "already in".
    private var reviewable: Int {
        model.recents.reduce(0) { $0 + $1.tally.review + $1.tally.asking }
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
                // Through the model, so a project that has just been hidden or
                // forgotten keeps its slot until its exit has played.
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
        // The rail is a sibling of the whole row rather than a leading item in
        // the headline, so it runs the full height — down past the name and
        // through the open project's work, which is what makes the issues below
        // read as hanging off this project instead of floating under it.
        HStack(alignment: .top, spacing: 7) {
            SelectionRail(lit: selected, tall: selected && !issues.isEmpty)

            // The issue rows are siblings of the project's button, never inside
            // its label: a plain Button swallows every click landing in it, so
            // nesting them would leave `fix`, `open` and the tick painted but
            // dead.
            VStack(alignment: .leading, spacing: 3) {
                Button(action: onSelect) {
                    headline.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .contextMenu {
                    if let project { RowActions.projectMenu(project, model: model) }
                }

                // One line each, except the one you are aiming at. Eight
                // projects at three lines apiece was the "chonky" this rebuild
                // is answering; the work belongs to the project you asked about.
                if selected { work }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)
        // Vertical only, and only when the row opens to show its work — which
        // is a deliberate click, not a cursor passing over. Nothing on the
        // headline's own line may change size: see `headline`.
        .padding(.vertical, selected ? 5 : 3)
        .background(rowBackground)
        // Inset from the drawer's edge so selection is a *shape* sitting in the
        // list rather than a band painted across it.
        .padding(.horizontal, 5)
        .vanishing(model.isLeaving(digest.id))
    }

    private var headline: some View {
        HStack(spacing: 6) {
            // Fixed weight. It used to go `.medium` → `.semibold` on selection,
            // which changes how wide the name is and shunts the star, the chip,
            // the bar and the age along the line every time you pick a row.
            // Selection is said with colour and with the rail, never with
            // metrics.
            Text(digest.name)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
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

            // Two facts, in the order you would want them: the one thing worth
            // a word, then how much else is in there.
            note
            TallyBar(tally: digest.tally)
            age
        }
        .help(tooltip)
    }

    /// Through the model rather than straight off the digest, so a row that has
    /// just been deleted is gone from here the moment its exit finishes, not
    /// whenever the next poll lands.
    private var issues: [IssuePip] { model.issues(of: digest) }

    // MARK: what this project is carrying

    /// The one thing about this project worth spending a word on.
    ///
    /// Priority is the order you would want to be interrupted in: a question,
    /// then a break, then a review, then work in flight — and only if none of
    /// that is true, whatever last happened here. `loud` is the difference
    /// between a chip you cannot miss and a word you can ignore.
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
        // Nothing open, but Ouroboros has worked here. Better than the pulse,
        // which would say "filed" about an issue that has since been closed.
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
                // Work that is waiting on *you* gets a body, not just a colour.
                // A tinted word among tinted words is a word; a filled chip in a
                // list of plain text is the thing your eye lands on first.
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

    /// The exact numbers, for the one person in ten who wants them. Everything
    /// the row compresses into a chip and a bar, spelled out.
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

    /// Grey on grey was unreadable — `.quaternary` over a material that is
    /// already a wash of the same value. An explicit opacity of the label
    /// colour holds its own on the drawer's surface, and lifts under the
    /// pointer so the row you are aiming at is the one you can read.
    private var age: some View {
        Text(ageLabel)
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.primary.opacity(selected || hovering ? 0.6 : 0.42))
            .frame(width: 24, alignment: .trailing)
    }

    /// The row says what it can do before you commit to a click. Only under the
    /// pointer, so a list of ten does not become a wall of buttons.
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

    /// Light falling off the rail, not a block of colour behind the row. The
    /// gradient runs out well before the right-hand numbers, which keeps them
    /// legible and makes the rail read as the source of the highlight.
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

    // MARK: the open project

    /// Only the selected project spends the vertical space. Clicking a row is a
    /// deliberate act, so the height changes when you ask it to and never under
    /// a moving cursor.
    @ViewBuilder
    private var work: some View {
        VStack(alignment: .leading, spacing: 1) {
            let rest = model.remainingIssues(of: digest)
            if rest.isEmpty {
                // Only when there is genuinely nothing. A project whose whole
                // list has been lifted into the group above says nothing at
                // all — "nothing open" over a row you can see two inches higher
                // would be the panel contradicting itself.
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
        // The rail is already outside this block and carries the indent; a
        // second one here would push the work a full tab in from its project.
        .padding(.leading, 1)
        .padding(.top, 3)
        .padding(.bottom, 1)
    }
}

/// A dot that breathes, and only exists while something is genuinely running.
/// Its motion is the whole message: on a folded drawer this is the only thing
/// telling you the machine is busy on your behalf.
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

// MARK: - the marker

/// Where the capture is going to land.
///
/// A flat 2×12 rectangle said "selected" and nothing else. This says the same
/// thing with a direction: brightest level with the project's name, falling
/// away down the length of its work, with enough bloom that the row reads as
/// lit rather than merely marked. It ignites rather than appearing, because
/// ⇥ walks this list and a marker that jumps is a marker you have to re-find.
private struct SelectionRail: View {
    let lit: Bool
    /// The project is open, so the rail has issues to run past and the falloff
    /// has somewhere to go. On a single line it would just look like it faded.
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

// MARK: - the backlog as a shape

/// How much work is in a project, in thirty-four points.
///
/// The chip beside it names the single most urgent thing; this says how much
/// else there is, and roughly of what — which is the difference between "one
/// review" and "one review and eleven filed sentences nobody has looked at".
///
/// Only open work is drawn. Landed fixes accumulate forever, and in a bar they
/// dominate the one red sliver that actually wanted attention.
private struct TallyBar: View {
    let tally: Tally

    private let width: CGFloat = 34
    private let gap: CGFloat = 1.5
    /// No segment ever thinner than this: a single failed run in a project of
    /// forty would otherwise round to a hairline and disappear.
    private let minimum: CGFloat = 3

    private struct Slice: Identifiable {
        let state: WorkState
        let width: CGFloat
        var id: WorkState { state }
    }

    var body: some View {
        // One kind of work is not a composition, and a single segment fills the
        // whole track — which reads as a progress bar at 100%, the exact
        // opposite of "five sentences nobody has looked at". The chip beside it
        // already says "5 filed" in words, so the bar stays out of it.
        if tally.openStates.count > 1 { bar }
    }

    private var bar: some View {
        // A project with work in flight breathes. Driven off the timeline
        // rather than a repeating animation, so a poll that redraws the drawer
        // twice a second cannot restart it mid-cycle.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !alive)) { context in
            let phase = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2.2)
            HStack(spacing: gap) {
                ForEach(slices) { slice in
                    Capsule(style: .continuous)
                        .fill(slice.state.tint.opacity(opacity(of: slice.state, phase: phase)))
                        .frame(width: slice.width)
                }
            }
            // One height, always. The bar used to grow half a point when its row
            // was selected, which is a metric that moves under a click for no
            // information at all.
            .frame(width: width, height: 3.5, alignment: .leading)
        }
    }

    private var alive: Bool { tally.running + tally.queued + tally.asking > 0 }

    private func opacity(of state: WorkState, phase: Double) -> Double {
        // Waiting work sits at a fixed weight; moving work pulses. Hollow
        // states — filed, stopped — stay faint, because "nobody is on this"
        // should not compete with "someone is on this right now".
        guard state == .running || state == .queued || state == .asking else {
            return state.isHollow ? 0.4 : 0.9
        }
        return 0.55 + 0.45 * phase
    }

    /// Every segment gets `minimum`, and what is left over is shared out by
    /// count. Seven segments plus their gaps come to 30 points inside a 34-point
    /// track, so the widths always fit and the bar never wobbles between rows.
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
