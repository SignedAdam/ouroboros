import Foundation

public enum IssueStatus: String, CaseIterable, Sendable { case new, planned, done, cancelled }

public struct Issue: Sendable, Equatable {
    public let title: String
    public let slug: String
    public let body: String
    public let path: String?
    public let created: Date?
    public let status: IssueStatus
    public init(title: String, slug: String, body: String, path: String? = nil,
                created: Date? = nil, status: IssueStatus = .new) {
        self.title = title
        self.slug = slug
        self.body = body
        self.path = path
        self.created = created
        self.status = status
    }
}

public enum IssueText {
    public static let nameMaxWords = 9
    public static let nameMaxChars = 60

    /// Collapse whitespace, replace path separators, trim spaces/dots.
    public static func cleanTitle(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let replaced = collapsed.replacingOccurrences(of: "/", with: "-")
                                .replacingOccurrences(of: "\\", with: "-")
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// First non-empty line → first 9 words / 60 chars, cleaned. Empty in → empty out.
    public static func suggestTitle(_ body: String) -> String {
        let firstLine = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        let words = firstLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return "" }
        var name = words.prefix(nameMaxWords).joined(separator: " ")
        if name.count > nameMaxChars {
            let cut = String(name.prefix(nameMaxChars))
            if let lastSpace = cut.range(of: " ", options: .backwards) {
                name = String(cut[..<lastSpace.lowerBound])
            } else {
                name = cut
            }
        }
        return cleanTitle(name)
    }

    /// Lowercase, non-alphanumerics → '-', strip leading/trailing '-', cap 40, fallback "issue".
    public static func slugify(_ title: String) -> String {
        var out = ""
        var lastDash = false
        for ch in title.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        let stripped = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let capped = String(stripped.prefix(40))
        return capped.isEmpty ? "issue" : capped
    }
}
