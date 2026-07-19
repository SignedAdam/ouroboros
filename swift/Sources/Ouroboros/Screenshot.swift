import Foundation

/// A screenshot attached to an issue at submit time. The host app captures and
/// composites it (annotations already burned into `pngData`); the engine stores
/// the file and writes the prompt-facing description into the issue body —
/// including the verbatim text of any annotations, so the agent gets them as
/// real text in addition to pixels.
public struct IssueScreenshot: Sendable, Equatable {
    /// Final composited PNG (base capture + any pen strokes/text already drawn in).
    public let pngData: Data
    /// The text annotations the user typed onto the image, verbatim, in order.
    public let textNotes: [String]
    /// Whether the user drew any pen markings (strokes/circles) on the image.
    public let hasPenMarks: Bool

    public init(pngData: Data, textNotes: [String] = [], hasPenMarks: Bool = false) {
        self.pngData = pngData
        self.textNotes = textNotes
        self.hasPenMarks = hasPenMarks
    }
}

extension IssueStore {
    /// Directory screenshots live in — a sibling of the status folders
    /// (`.issues/attachments/` for the default layout), so a file never moves
    /// when its issue changes status.
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

    /// The `## Screenshot` section appended to the issue body. This is
    /// prompt-facing text: it tells the agent the screenshot exists, mentions
    /// pen markings only when there are any, and clones text annotations
    /// verbatim so they reach the agent as text, not just pixels.
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
