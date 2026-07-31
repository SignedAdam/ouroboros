import Foundation

// MARK: - a branch's work, as data

/// What an agent did on its branch, structured.
///
/// The GUI has to show commits, per-file counts and tinted hunks. Handing it a
/// blob of `git diff` text and asking it to parse the same unified format the
/// daemon just produced would be two parsers for one format, and the second one
/// would live in a view. So the parsing happens once, here, and every face —
/// the diff surface, `ouro diff --json`, an AI operator — reads the same shape.
///
/// Always names **which two commits it compared**. A diff, like a merge verdict,
/// is meaningless without its operands: `main...branch` said one thing before
/// the branch was rebased and another after, and both answers were correct at
/// the moment they were given.
public struct DiffReport: Codable, Sendable, Equatable {
    public var runId: String
    /// The refs as the run recorded them, for reading.
    public var base: String
    public var branch: String
    /// The commits those refs actually pointed at, for trusting.
    public var baseSha: String
    public var branchSha: String
    /// Oldest first: a branch is read in the order it was written.
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

    /// "3 commits · 8 files · +214 -37", or as much of it as is true.
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
    /// Short sha. The long one is never read and costs a column.
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
    /// Where it came from, when it moved.
    public var oldPath: String?
    public var change: Change
    public var added: Int
    public var removed: Int
    /// No hunks worth drawing. Say so rather than showing an empty file.
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
    /// Position in its file, so a list of hunks has stable identity without
    /// hashing their contents.
    public var index: Int
    public var oldStart: Int
    public var newStart: Int
    /// What git puts after the second `@@` — usually the enclosing function.
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
    /// Without the leading +/-/space. A view that wants the marker back can add
    /// one; a view that wants to select the code should not have to strip it.
    public var text: String

    public var id: Int { index }

    public init(index: Int, kind: Kind, text: String) {
        self.index = index
        self.kind = kind
        self.text = text
    }
}

// MARK: - reading git's unified diff

/// Turns `git diff` output into `DiffFile`s.
///
/// Written against what git actually emits rather than against the format's
/// grammar: the `diff --git a/x b/x` line is ambiguous when a path contains a
/// space, so paths are taken from the `---` / `+++` lines, which are one path
/// each, and only fall back to the header when one of them is `/dev/null`.
public enum UnifiedDiff {

    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: Builder?

        // Empty lines are kept — a context line that is blank arrives as a bare
        // "" from any tool that trims trailing whitespace — so the patch's own
        // final newline has to go first, or every file ends with a line that
        // was never in it.
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

    /// One file's worth of state while the lines go past.
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

            // Anything else before the first @@ is git's own metadata (index,
            // mode, similarity) and is not part of the patch body.
            guard !hunks.isEmpty else { return }
            body(line)
        }

        private mutating func startHunk(_ line: String) {
            // "@@ -12,7 +12,9 @@ func thing() {"
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
            // "\ No newline at end of file" is a note about the previous line,
            // not a line of the file.
            guard !line.hasPrefix("\\") else { return }
            let kind: DiffLine.Kind
            switch line.first {
            case "+": kind = .added;   added += 1
            case "-": kind = .removed; removed += 1
            case " ": kind = .context
            case nil: kind = .context      // a genuinely empty context line
            default:  return               // trailing junk between files
            }
            hunks[hunks.count - 1].lines.append(
                DiffLine(index: lineIndex, kind: kind, text: String(line.dropFirst())))
            lineIndex += 1
        }

        /// `--- a/x` → `x`, `+++ /dev/null` → nil. Git quotes paths that need
        /// it; a quoted path is unquoted rather than shown with its escapes.
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
            // A rename with no edits has no ---/+++ pair at all.
            let path = newName ?? renameTo ?? oldName ?? renameFrom ?? fallbackPath()
            guard let path else { return nil }
            let from = renameFrom ?? (change == .renamed ? oldName : nil)
            return DiffFile(path: path,
                            oldPath: from == path ? nil : from,
                            change: change,
                            added: added, removed: removed,
                            binary: binary, hunks: hunks)
        }

        /// Last resort for a header with no bodies — "diff --git a/x b/x" with
        /// both halves the same path, which is the only case it can be read
        /// unambiguously.
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

// MARK: - building one from a repo

public enum DiffReports {
    /// `base...branch` — what the branch added, not what has happened on the
    /// base since. Three dots is the whole reason a stale branch still reads
    /// correctly.
    public static func build(runId: String, repo: String,
                             base: String, branch: String) -> DiffReport {
        let git = Git(repo)
        var report = DiffReport(runId: runId, base: base, branch: branch)
        report.baseSha = sha(git, base)
        report.branchSha = sha(git, branch)

        // %x1f is the ASCII unit separator: a commit subject can contain
        // anything, including whatever character seemed safe.
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
