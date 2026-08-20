import Foundation

public struct Preferences: Sendable {
    public static let heading = "## How the person you work for likes it"

    public let file: String

    public init(home: String = Paths.home) {
        self.file = (home as NSString).appendingPathComponent("preferences.md")
    }

    public init(file: String) {
        self.file = file
    }

    public func text() -> String {
        let raw = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { text().isEmpty }

    public var lines: [String] {
        text().components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @discardableResult
    public func write(_ raw: String) -> Bool {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = (file as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard !body.isEmpty else {
            try? FileManager.default.removeItem(atPath: file)
            return true
        }
        do {
            try (body + "\n").write(toFile: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func append(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return true }
        let current = text()
        return write(current.isEmpty ? line : current + "\n" + line)
    }

    @discardableResult
    public func clear() -> Bool { write("") }

    public func section() -> String? { Preferences.section(text()) }

    public static func section(_ raw: String) -> String? {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return """
        \(heading)

        These are standing preferences from the person who runs this Ouroboros. They hold for \
        every run, this one included. Where they contradict the work you were given above, \
        the work wins.

        \(body)
        """
    }

    public func appended(to prompt: String) -> String {
        guard !prompt.contains(Preferences.heading), let section = section() else { return prompt }
        return prompt + "\n\n" + section + "\n"
    }
}
