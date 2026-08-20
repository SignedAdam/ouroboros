import Foundation

/// Turns a harness's newline-delimited JSON events into lines a person can read
/// while the agent is still working. A line that is not a recognised event goes
/// through untouched, so a harness that prints plain text still reads the same.
public struct AgentStream {
    private var pending: [UInt8] = []
    private var lastSpoken = ""

    public init() {}

    /// A harness that draws a progress bar never sends a newline, so hold back only
    /// so much before letting it through as it came.
    static let holdLimit = 8192

    public mutating func feed(_ chunk: Data) -> Data {
        pending.append(contentsOf: chunk)
        var out = Data()
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeFirst(newline + 1)
            if let text = readable(line) { out.append(Data((text + "\n").utf8)) }
        }
        if pending.count > AgentStream.holdLimit {
            out.append(Data(pending))
            pending = []
        }
        return out
    }

    public mutating func finish() -> Data {
        guard !pending.isEmpty else { return Data() }
        let line = String(decoding: pending, as: UTF8.self)
        pending = []
        guard let text = readable(line) else { return Data() }
        return Data((text + "\n").utf8)
    }

    /// The readable form of one line, or nil when the line carries nothing worth showing.
    public mutating func readable(_ line: String) -> String? {
        let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
        guard let event = AgentStream.decode(text) else { return text }
        let rendered = lines(for: event)
        return rendered.isEmpty ? nil : rendered.joined(separator: "\n")
    }

    private static func decode(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let object = parsed as? [String: Any], object["type"] is String else { return nil }
        return object
    }

    private mutating func lines(for event: [String: Any]) -> [String] {
        switch event["type"] as? String {
        case "assistant": return spoken(event)
        case "user":      return toolResults(event)
        case "result":    return ending(event)
        default:          return []
        }
    }

    private mutating func spoken(_ event: [String: Any]) -> [String] {
        var out: [String] = []
        for block in AgentStream.content(of: event) {
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lastSpoken = text
                out.append(text)
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                let detail = AgentStream.summarise(block["input"] as? [String: Any] ?? [:])
                out.append(detail.isEmpty ? "  → \(name)" : "  → \(name)  \(detail)")
            default:
                continue
            }
        }
        return out
    }

    private func toolResults(_ event: [String: Any]) -> [String] {
        var out: [String] = []
        for block in AgentStream.content(of: event)
        where block["type"] as? String == "tool_result" {
            let text = AgentStream.flatten(block["content"])
            let failed = block["is_error"] as? Bool ?? false
            if text.isEmpty {
                if failed { out.append("    ! it failed") }
                continue
            }
            out.append("    " + (failed ? "! " : "") + AgentStream.condense(text, limit: 110))
        }
        return out
    }

    private func ending(_ event: [String: Any]) -> [String] {
        let subtype = event["subtype"] as? String ?? "success"
        let failed = (event["is_error"] as? Bool ?? false) || subtype != "success"
        let text = (event["result"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if failed {
            return ["  ! " + AgentStream.condense(text.isEmpty ? subtype : text, limit: 400)]
        }
        guard !text.isEmpty, text != lastSpoken else { return [] }
        return [text]
    }

    private static func content(of event: [String: Any]) -> [[String: Any]] {
        guard let message = event["message"] as? [String: Any] else { return [] }
        return message["content"] as? [[String: Any]] ?? []
    }

    static func summarise(_ input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "pattern", "query", "url",
                    "description", "prompt", "skill", "notebook_path"] {
            if let value = input[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return condense(value, limit: 110)
            }
        }
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return condense(String(decoding: data, as: UTF8.self), limit: 110)
    }

    static func flatten(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    static func condense(_ text: String, limit: Int) -> String {
        var flat = ""
        var space = false
        for character in text {
            if character.isWhitespace {
                if !space && !flat.isEmpty { flat.append(" ") }
                space = true
            } else {
                flat.append(character)
                space = false
            }
        }
        flat = flat.trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}
