import Foundation

public struct IssueStore: Sendable {
    public let rootDir: String
    public let subdir: String
    let now: @Sendable () -> Date

    public init(rootDir: String, subdir: String = ".issues/new",
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.rootDir = rootDir
        self.subdir = subdir
        self.now = now
    }

    /// Directory for a status: if `subdir`'s last component is a status raw value it is
    /// replaced by `s.rawValue`; otherwise `s.rawValue` is appended.
    func statusDir(_ s: IssueStatus) -> String {
        var parts = subdir.split(separator: "/").map(String.init)
        if let last = parts.last, IssueStatus(rawValue: last) != nil {
            parts[parts.count - 1] = s.rawValue
        } else {
            parts.append(s.rawValue)
        }
        var path = rootDir
        for part in parts {
            path = (path as NSString).appendingPathComponent(part)
        }
        return path
    }

    private func dir() -> String { statusDir(.new) }

    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func isoDate(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    private func filename(_ title: String) -> String {
        let t = IssueText.cleanTitle(title)
        if t.isEmpty { return "" }
        return t.lowercased().hasSuffix(".md") ? t : "\(t).md"
    }

    private func nextPath(_ title: String) -> String? {
        let fn = filename(title)
        if fn.isEmpty { return nil }
        return Self.availablePath(in: dir(), filename: fn)
    }

    /// First non-existing path for `filename` in `d`, deduping with " 2"/" 3"/… suffixes.
    static func availablePath(in d: String, filename fn: String) -> String? {
        let first = (d as NSString).appendingPathComponent(fn)
        if !FileManager.default.fileExists(atPath: first) { return first }
        let base = (fn as NSString).deletingPathExtension
        let ext = (fn as NSString).pathExtension
        for i in 2..<1000 {
            let candidate = (d as NSString).appendingPathComponent("\(base) \(i).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    public func write(title: String, body: String,
                      screenshot: IssueScreenshot? = nil) -> Issue? {
        let t = IssueText.cleanTitle(title)
        var b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !b.isEmpty, let path = nextPath(t) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        // Screenshot first: the body gains its `## Screenshot` section (absolute
        // path — the fixing agent may run from a worktree where the live repo's
        // uncommitted .issues/ files don't exist, so relative paths would dangle).
        if let screenshot {
            let slug = IssueText.slugify(t)
            let d = attachmentsDir()
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            if let pngPath = Self.availablePath(in: d, filename: "\(slug).png"),
               (try? screenshot.pngData.write(to: URL(fileURLWithPath: pngPath))) != nil {
                b += "\n\n" + Self.screenshotSection(absolutePath: pngPath, screenshot: screenshot)
            }
        }

        let created = now()
        let content = Self.render(title: t, created: created, body: b)
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return Issue(title: t, slug: IssueText.slugify(t), body: b, path: path,
                     created: created, status: .new)
    }

    static func render(title: String, created: Date, body: String) -> String {
        "---\ntitle: \(title)\ncreated: \(isoString(created))\n---\n\n## \(title)\n\n\(body)\n"
    }

    struct ParsedDoc {
        let title: String?
        let created: Date?
        let hadFrontmatter: Bool
        let body: String
    }

    /// Line-based parse of an issue document. Tolerates files with no frontmatter
    /// (legacy v1 `## Title\n\nbody`, or arbitrary markdown).
    static func parse(content: String) -> ParsedDoc {
        let lines = content.components(separatedBy: "\n")
        var fmTitle: String?
        var fmCreated: Date?
        var hadFrontmatter = false
        var bodySearchStart = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var close: Int?
            for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                close = i
                break
            }
            if let close {
                hadFrontmatter = true
                for line in lines[1..<close] {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if key == "title", !value.isEmpty { fmTitle = value }
                    if key == "created" { fmCreated = isoDate(value) }
                }
                bodySearchStart = close + 1
            }
        }
        var headingLine: Int?
        var headingTitle: String?
        for i in bodySearchStart..<lines.count where lines[i].hasPrefix("## ") {
            headingLine = i
            headingTitle = String(lines[i].dropFirst(3)).trimmingCharacters(in: .whitespaces)
            break
        }
        let bodyLines = headingLine.map { Array(lines[($0 + 1)...]) } ?? Array(lines[bodySearchStart...])
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = fmTitle ?? (headingTitle?.isEmpty == false ? headingTitle : nil)
        return ParsedDoc(title: title, created: fmCreated, hadFrontmatter: hadFrontmatter, body: body)
    }

    /// Parse one issue file. Status is inferred from the parent folder name (fallback `.new`).
    /// Legacy files (no frontmatter) derive title from the first `## ` heading (else the
    /// filename) and `created` from the file's modification date.
    public func read(path: String) -> Issue? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let parentName = (((path as NSString).deletingLastPathComponent) as NSString).lastPathComponent
        let status = IssueStatus(rawValue: parentName) ?? .new
        let parsed = Self.parse(content: content)
        let title = parsed.title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let created: Date?
        if parsed.hadFrontmatter {
            created = parsed.created
        } else {
            created = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return Issue(title: title, slug: IssueText.slugify(title), body: parsed.body, path: path,
                     created: created, status: status)
    }

    /// All issues across the four status folders (existing ones only),
    /// sorted created-descending; issues with no created date sort last.
    public func list() -> [Issue] {
        let fm = FileManager.default
        var issues: [Issue] = []
        for status in IssueStatus.allCases {
            let d = statusDir(status)
            guard let names = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for name in names.sorted() where name.lowercased().hasSuffix(".md") {
                let p = (d as NSString).appendingPathComponent(name)
                if let issue = read(path: p) { issues.append(issue) }
            }
        }
        return issues.sorted { a, b in
            switch (a.created, b.created) {
            case let (x?, y?): return x != y ? x > y : (a.path ?? "") < (b.path ?? "")
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):   return (a.path ?? "") < (b.path ?? "")
            }
        }
    }

    /// Rewrite the issue file in place with the new (trimmed) body, preserving the file's
    /// title and created date. On a legacy file (no frontmatter) the derived title and the
    /// file's modification date are promoted into frontmatter. Nil on empty body or
    /// missing path.
    @discardableResult
    public func updateBody(_ issue: Issue, body: String) -> Issue? {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, let path = issue.path, let existing = read(path: path) else { return nil }
        let created = existing.created ?? now()
        let content = Self.render(title: existing.title, created: created, body: b)
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return Issue(title: existing.title, slug: existing.slug, body: b, path: path,
                     created: created, status: existing.status)
    }

    /// Move the issue file to the folder for `status` (created if needed), deduping name
    /// collisions. Returns the issue with updated path + status; nil on missing path or
    /// a failed move.
    @discardableResult
    public func setStatus(_ issue: Issue, _ status: IssueStatus) -> Issue? {
        let fm = FileManager.default
        guard let path = issue.path, fm.fileExists(atPath: path) else { return nil }
        let destDir = statusDir(status)
        try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let fn = (path as NSString).lastPathComponent
        let straight = (destDir as NSString).appendingPathComponent(fn)
        if straight == path {   // already in that folder — nothing to move
            return Issue(title: issue.title, slug: issue.slug, body: issue.body, path: path,
                         created: issue.created, status: status)
        }
        guard let dest = Self.availablePath(in: destDir, filename: fn) else { return nil }
        do {
            try fm.moveItem(atPath: path, toPath: dest)
        } catch {
            return nil
        }
        return Issue(title: issue.title, slug: issue.slug, body: issue.body, path: dest,
                     created: issue.created, status: status)
    }
}
