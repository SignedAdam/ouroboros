import Foundation

public struct IssueStore: Sendable {
    public let rootDir: String
    public let subdir: String

    public init(rootDir: String, subdir: String = ".issues/new") {
        self.rootDir = rootDir
        self.subdir = subdir
    }

    private func dir() -> String {
        var path = rootDir
        for part in subdir.split(separator: "/") {
            path = (path as NSString).appendingPathComponent(String(part))
        }
        return path
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
        let content = "## \(t)\n\n\(b)\n"
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return Issue(title: t, slug: IssueText.slugify(t), body: b, path: path)
    }
}
