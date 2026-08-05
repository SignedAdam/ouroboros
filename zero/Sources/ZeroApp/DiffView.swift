import SwiftUI
import ZeroCore

struct DiffView: View {
    let report: DiffReport
    var onClose: () -> Void

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

        .frame(minWidth: 660, idealWidth: 760, maxWidth: 1100,
               minHeight: 380, idealHeight: 520)
        .background(.regularMaterial)

        .overlay {
            Button("", action: onClose)
                .keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(report.branch.isEmpty ? "no branch" : report.branch)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)

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

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !report.commits.isEmpty {
                    rule("commits")

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

    @ViewBuilder
    private var hunks: some View {
        if let file = current {
            if file.binary {
                note("binary")
            } else if file.hunks.isEmpty {
                note(file.change == .renamed ? "renamed, no edits" : "no changes")
            } else {
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

private struct FileRow: View {
    let file: DiffFile
    let selected: Bool
    var onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
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

private struct HunkView: View {
    let hunk: DiffHunk

    let span: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

    @ViewBuilder
    private var background: some View {
        switch line.kind {
        case .added:   DiffPalette.added.opacity(0.13)
        case .removed: DiffPalette.removed.opacity(0.13)
        case .context: Color.clear
        }
    }
}

enum DiffPalette {
    static let added = Color(red: 0.49, green: 0.85, blue: 0.34)
    static let removed = Color(red: 1.0, green: 0.37, blue: 0.34)
}

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
