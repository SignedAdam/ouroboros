import Foundation

public struct DiffReport: Codable, Sendable, Equatable, Identifiable {
    public var runId: String

    public var id: String { runId }

    public var base: String
    public var branch: String

    public var baseSha: String
    public var branchSha: String

    public var commits: [DiffCommit]
    public var files: [DiffFile]

    public init(runId: String, base: String, branch: String,
                baseSha: String = "", branchSha: String = "",
                commits: [DiffCommit] = [], files: [DiffFile] = []) {
        self.runId = runId
        self.base = base
        self.branch = branch
        self.baseSha = baseSha
        self.branchSha = branchSha
        self.commits = commits
        self.files = files
    }

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }
    public var isEmpty: Bool { commits.isEmpty && files.isEmpty }

    public var summary: String {
        guard !isEmpty else { return "no changes" }
        var parts: [String] = []
        if !commits.isEmpty { parts.append(count(commits.count, "commit")) }
        if !files.isEmpty { parts.append(count(files.count, "file")) }
        if added > 0 || removed > 0 { parts.append("+\(added) -\(removed)") }
        return parts.joined(separator: " · ")
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

public struct DiffCommit: Codable, Sendable, Equatable, Identifiable {
    public var sha: String
    public var subject: String
    public var id: String { sha }

    public init(sha: String, subject: String) {
        self.sha = sha
        self.subject = subject
    }
}

public struct DiffFile: Codable, Sendable, Equatable, Identifiable {
    public enum Change: String, Codable, Sendable {
        case added, modified, deleted, renamed
    }

    public var path: String

    public var oldPath: String?
    public var change: Change
    public var added: Int
    public var removed: Int

    public var binary: Bool
    public var hunks: [DiffHunk]

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, change: Change = .modified,
                added: Int = 0, removed: Int = 0, binary: Bool = false,
                hunks: [DiffHunk] = []) {
        self.path = path
        self.oldPath = oldPath
        self.change = change
        self.added = added
        self.removed = removed
        self.binary = binary
        self.hunks = hunks
    }
}

public struct DiffHunk: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public var oldStart: Int
    public var newStart: Int

    public var context: String
    public var lines: [DiffLine]

    public var id: Int { index }

    public init(index: Int, oldStart: Int, newStart: Int,
                context: String = "", lines: [DiffLine] = []) {
        self.index = index
        self.oldStart = oldStart
        self.newStart = newStart
        self.context = context
        self.lines = lines
    }
}

public struct DiffLine: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case context, added, removed }

    public var index: Int
    public var kind: Kind

    public var text: String

    public var id: Int { index }

    public init(index: Int, kind: Kind, text: String) {
        self.index = index
        self.kind = kind
        self.text = text
    }
}

public enum UnifiedDiff {
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: Builder?

        var body = text
        if body.hasSuffix("\n") { body.removeLast() }

        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)

            if line.hasPrefix("diff --git ") {
                if let done = current?.build() { files.append(done) }
                current = Builder(header: line)
                continue
            }
            guard current != nil else { continue }
            current?.take(line)
        }
        if let done = current?.build() { files.append(done) }
        return files
    }

    private struct Builder {
        let header: String
        var oldName: String?
        var newName: String?
        var renameFrom: String?
        var renameTo: String?
        var change: DiffFile.Change = .modified
        var binary = false
        var hunks: [DiffHunk] = []
        var added = 0
        var removed = 0
        private var lineIndex = 0

        init(header: String) { self.header = header }

        mutating func take(_ line: String) {
            if line.hasPrefix("new file mode") { change = .added; return }
            if line.hasPrefix("deleted file mode") { change = .deleted; return }
            if line.hasPrefix("rename from ") {
                renameFrom = String(line.dropFirst("rename from ".count)); change = .renamed; return
            }
            if line.hasPrefix("rename to ") {
                renameTo = String(line.dropFirst("rename to ".count)); change = .renamed; return
            }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                binary = true; return
            }
            if line.hasPrefix("--- ") { oldName = path(from: String(line.dropFirst(4))); return }
            if line.hasPrefix("+++ ") { newName = path(from: String(line.dropFirst(4))); return }
            if line.hasPrefix("@@") { startHunk(line); return }

            guard !hunks.isEmpty else { return }
            body(line)
        }

        private mutating func startHunk(_ line: String) {
            guard let close = line.range(of: "@@", range: line.index(line.startIndex,
                                                                     offsetBy: 2)..<line.endIndex)
            else { return }
            let ranges = line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let context = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)

            var oldStart = 0
            var newStart = 0
            for field in ranges.split(separator: " ") {
                let number = field.dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 0
                if field.hasPrefix("-") { oldStart = number }
                if field.hasPrefix("+") { newStart = number }
            }
            lineIndex = 0
            hunks.append(DiffHunk(index: hunks.count, oldStart: oldStart,
                                  newStart: newStart, context: context))
        }

        private mutating func body(_ line: String) {
            guard !line.hasPrefix("\\") else { return }
            let kind: DiffLine.Kind
            switch line.first {
            case "+": kind = .added;   added += 1
            case "-": kind = .removed; removed += 1
            case " ": kind = .context
            case nil: kind = .context
            default:  return
            }
            hunks[hunks.count - 1].lines.append(
                DiffLine(index: lineIndex, kind: kind, text: String(line.dropFirst())))
            lineIndex += 1
        }

        private func path(from field: String) -> String? {
            var value = field
            if let tab = value.firstIndex(of: "\t") { value = String(value[..<tab]) }
            value = value.trimmingCharacters(in: .whitespaces)
            guard value != "/dev/null" else { return nil }
            if value.hasPrefix("\"") { value = unquote(value) }
            if value.hasPrefix("a/") || value.hasPrefix("b/") { value = String(value.dropFirst(2)) }
            return value.isEmpty ? nil : value
        }

        private func unquote(_ value: String) -> String {
            var out = ""
            var escaped = false
            for character in value.dropFirst().dropLast() {
                if escaped { out.append(character); escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                out.append(character)
            }
            return out
        }

        func build() -> DiffFile? {
            let path = newName ?? renameTo ?? oldName ?? renameFrom ?? fallbackPath()
            guard let path else { return nil }
            let from = renameFrom ?? (change == .renamed ? oldName : nil)
            return DiffFile(path: path,
                            oldPath: from == path ? nil : from,
                            change: change,
                            added: added, removed: removed,
                            binary: binary, hunks: hunks)
        }

        private func fallbackPath() -> String? {
            let rest = header.dropFirst("diff --git ".count)
            let halves = rest.split(separator: " ")
            guard halves.count == 2, halves[0].hasPrefix("a/"), halves[1].hasPrefix("b/") else {
                return nil
            }
            let left = String(halves[0].dropFirst(2))
            let right = String(halves[1].dropFirst(2))
            return left == right ? left : right
        }
    }
}

public enum DiffReports {
    public static func build(runId: String, repo: String,
                             base: String, branch: String) -> DiffReport {
        let git = Git(repo)
        var report = DiffReport(runId: runId, base: base, branch: branch)
        report.baseSha = sha(git, base)
        report.branchSha = sha(git, branch)

        let log = git.run(["log", "--reverse", "--format=%h%x1f%s", "\(base)..\(branch)"],
                          timeout: 30)
        if log.ok {
            report.commits = log.output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\u{1f}", maxSplits: 1,
                                       omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return DiffCommit(sha: String(parts[0]), subject: String(parts[1]))
            }
        }

        let diff = git.run(["diff", "\(base)...\(branch)"], timeout: 60)
        if diff.ok { report.files = UnifiedDiff.parse(diff.output) }
        return report
    }

    private static func sha(_ git: Git, _ ref: String) -> String {
        let result = git.run(["rev-parse", ref], timeout: 10)
        return result.ok ? result.trimmed : ""
    }
}
