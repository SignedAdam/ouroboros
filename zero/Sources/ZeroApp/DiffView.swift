import SwiftUI
import ZeroCore

/// What the agent actually did, so you can decide whether to merge it.
///
/// Read-only on purpose. This is the surface between "an agent says it fixed
/// it" and "I am letting that into main", and the only question it exists to
/// answer is whether the diff is what you wanted. Editing here would be editing
/// a branch through a keyhole.
///
/// It draws a `DiffReport` and nothing else: no git, no shelling out, no second
/// parser. The daemon read the branch once, and this reads the result. Present
/// it from anywhere with one call — it owns its own layout, scrolling and
/// dismissal, and takes a closure for the way out.
///
///     DiffView(report: report) { showingDiff = false }
///
struct DiffView: View {
    let report: DiffReport
    var onClose: () -> Void

    /// Which file the hunks are showing. Nil means the first one that has any.
    @State private var selected: String?

    private var files: [DiffFile] { report.files }

    private var current: DiffFile? {
        if let selected, let match = files.first(where: { $0.id == selected }) { return match }
        return files.first { !$0.hunks.isEmpty } ?? files.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)

            if report.isEmpty {
                empty
            } else {
                HSplit {
                    sidebar
                } detail: {
                    hunks
                }
            }
        }
        // Sized to sit on the capture panel, which is 560 wide. Wider than its
        // parent, because a diff needs the width and a sheet may have it — but
        // not so much wider that the panel disappears underneath it.
        .frame(minWidth: 660, idealWidth: 760, maxWidth: 1100,
               minHeight: 380, idealHeight: 520)
        .background(.regularMaterial)
        // Escape, and a button rather than `onKeyPress` so it works whatever
        // has focus inside the scroll views.
        .overlay {
            Button("", action: onClose)
                .keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0)
        }
    }

    // MARK: what this is

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(report.branch.isEmpty ? "no branch" : report.branch)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)

            // The two commits this is a diff of. A diff without its operands is
            // a claim about a moment nobody wrote down.
            if !report.baseSha.isEmpty {
                Text("\(short(report.baseSha)) → \(short(report.branchSha))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Text(report.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var empty: some View {
        Text("nothing on this branch")
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: the commits, then the files

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !report.commits.isEmpty {
                    rule("commits")
                    // Oldest first: a branch is read in the order it was
                    // written, which is the order it will be merged in.
                    ForEach(report.commits) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(commit.sha)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(ouroOrange.opacity(0.8))
                            Text(commit.subject)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.primary.opacity(0.8))
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)
                    }
                }

                rule("files")
                ForEach(files) { file in
                    FileRow(file: file,
                            selected: file.id == current?.id,
                            onSelect: { selected = file.id })
                }
            }
            .padding(.bottom, 10)
        }
        .frame(width: 236)
    }

    private func rule(_ word: String) -> some View {
        HStack(spacing: 8) {
            Text(word)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Rectangle().fill(Color.primary.opacity(0.13)).frame(height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 5)
    }

    // MARK: the change itself

    @ViewBuilder
    private var hunks: some View {
        if let file = current {
            if file.binary {
                note("binary")
            } else if file.hunks.isEmpty {
                note(file.change == .renamed ? "renamed, no edits" : "no changes")
            } else {
                // Both axes on one scroll view, not a horizontal one per hunk.
                // Code does not wrap — a wrapped diff line stops being a diff
                // line — and every hunk in a file has to move together: two
                // hunks at different horizontal offsets are two different
                // claims about where the edit is.
                //
                // The pane's width is measured and handed down, so a short line
                // still gets a full-width tint and a hunk header still reads as
                // a band rather than as a label the length of its own text.
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(file.hunks) { hunk in
                                HunkView(hunk: hunk, span: geo.size.width)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
        } else {
            note("nothing to show")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func short(_ sha: String) -> String { String(sha.prefix(7)) }
}

// MARK: - a file in the list

private struct FileRow: View {
    let file: DiffFile
    let selected: Bool
    var onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                // The change, as a mark. A list where every row is the same
                // shape makes you read every row.
                Text(mark)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(markTint)
                    .frame(width: 8)

                Text(name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: 6)

                if !file.binary {
                    Text("+\(file.added)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DiffPalette.added.opacity(file.added > 0 ? 0.9 : 0.3))
                    Text("-\(file.removed)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DiffPalette.removed.opacity(file.removed > 0 ? 0.9 : 0.3))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 3.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(background)
        .onHover { hovering = $0 }
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

    /// The last two components. A column this narrow cannot show
    /// `zero/Sources/ZeroApp/Resources/…` and the filename is what you scan.
    private var name: String {
        let parts = file.path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    private var mark: String {
        switch file.change {
        case .added:    return "+"
        case .deleted:  return "−"
        case .renamed:  return "→"
        case .modified: return "·"
        }
    }

    private var markTint: Color {
        switch file.change {
        case .added:    return DiffPalette.added
        case .deleted:  return DiffPalette.removed
        case .renamed:  return ouroOrange
        case .modified: return .secondary
        }
    }

    @ViewBuilder
    private var background: some View {
        if selected {
            ouroOrange.opacity(0.1)
        } else if hovering {
            Color.primary.opacity(0.05)
        }
    }
}

// MARK: - a hunk

private struct HunkView: View {
    let hunk: DiffHunk
    /// The width of the pane this is scrolling inside, so a band is a band even
    /// when its own content is two words long.
    let span: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Where in the file you are, and what encloses it. The one piece of
            // orientation a hunk out of context needs.
            HStack(spacing: 8) {
                Text("@\(hunk.newStart)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if !hunk.context.isEmpty {
                    Text(hunk.context)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(minWidth: span, alignment: .leading)
            .background(Color.primary.opacity(0.05))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunk.lines) { line in
                    LineView(line: line, span: span)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct LineView: View {
    let line: DiffLine
    let span: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // The marker is a column, not a character in the text: the code
            // then starts at the same x on every line and stays readable.
            Text(marker)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(tint.opacity(0.8))
                .frame(width: 16, alignment: .center)

            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(line.kind == .context
                                 ? Color.primary.opacity(0.6) : Color.primary.opacity(0.92))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .padding(.trailing, 14)
        }
        .padding(.vertical, 0.5)
        // A short line still gets the full width of the pane tinted; without
        // this the wash stops where the text does and the block of added lines
        // reads as a ragged edge instead of a block.
        .frame(minWidth: span, alignment: .leading)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .added:   return "+"
        case .removed: return "−"
        case .context: return ""
        }
    }

    private var tint: Color {
        switch line.kind {
        case .added:   return DiffPalette.added
        case .removed: return DiffPalette.removed
        case .context: return .secondary
        }
    }

    /// A wash rather than a block: strong enough to group at a glance, weak
    /// enough that the code on top of it is still the thing you are reading.
    @ViewBuilder
    private var background: some View {
        switch line.kind {
        case .added:   DiffPalette.added.opacity(0.13)
        case .removed: DiffPalette.removed.opacity(0.13)
        case .context: Color.clear
        }
    }
}

/// Added and removed, in the two colours this app already uses for landed and
/// failed. A diff is not the place to introduce a third green.
enum DiffPalette {
    static let added = Color(red: 0.49, green: 0.85, blue: 0.34)
    static let removed = Color(red: 1.0, green: 0.37, blue: 0.34)
}

/// A fixed-width list beside a flexible body, with a hairline between them.
/// `HSplit` rather than `HStack` only so the divider cannot be forgotten.
private struct HSplit<Side: View, Detail: View>: View {
    @ViewBuilder var side: () -> Side
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            side()
            Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1)
            detail()
        }
    }
}
