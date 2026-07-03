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
        let d = dir()
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
    public func write(title: String, body: String) -> Issue? {
        let t = IssueText.cleanTitle(title)
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !b.isEmpty, let path = nextPath(t) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
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
}
