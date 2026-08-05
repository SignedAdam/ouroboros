import Foundation

public struct IssueScreenshot: Sendable, Equatable {
    public let pngData: Data

    public let textNotes: [String]

    public let hasPenMarks: Bool

    public init(pngData: Data, textNotes: [String] = [], hasPenMarks: Bool = false) {
        self.pngData = pngData
        self.textNotes = textNotes
        self.hasPenMarks = hasPenMarks
    }
}

extension IssueStore {
    func attachmentsDir() -> String {
        var parts = subdir.split(separator: "/").map(String.init)
        if let last = parts.last, IssueStatus(rawValue: last) != nil {
            parts[parts.count - 1] = "attachments"
        } else {
            parts.append("attachments")
        }
        var path = rootDir
        for part in parts {
            path = (path as NSString).appendingPathComponent(part)
        }
        return path
    }

    static func screenshotSection(absolutePath: String, screenshot: IssueScreenshot) -> String {
        var lines = ["## Screenshot", "",
                     "A screenshot of the app at report time is attached: `\(absolutePath)` — read this image file."]
        if screenshot.hasPenMarks {
            lines.append("The user drew high-contrast pen markings on it pointing at the relevant elements.")
        }
        if !screenshot.textNotes.isEmpty {
            lines.append("Text annotations written on the image, verbatim:")
            for note in screenshot.textNotes {
                lines.append("- \"\(note)\"")
            }
        } else if screenshot.hasPenMarks {
            lines.append("There are no text annotations — infer the target element(s) from the markings.")
        }
        return lines.joined(separator: "\n")
    }
}
