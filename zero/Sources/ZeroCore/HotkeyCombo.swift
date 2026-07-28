import Foundation
import Carbon.HIToolbox

/// The text form of the global capture shortcut — "opt+space",
/// "cmd+shift+space" — and its translation to and from the Carbon key code and
/// modifier mask `RegisterEventHotKey` wants.
///
/// Pure string↔number work with no window, no event handler and no app: it is
/// what `/hotkey` writes into `config.json` and what the panel renders in its
/// footer, so the daemon, the CLI and the tests can all read a combo without
/// the AppKit machinery that eventually registers one.
public enum HotkeyCombo {

    /// Tried in order after the configured combo. Ordered by how little else on
    /// a Mac wants them.
    public static let fallbacks = ["opt+space", "cmd+shift+space", "opt+cmd+space", "opt+cmd+i"]

    /// The combos to attempt, in order: the configured one first, then the
    /// fallbacks it does not already name. `RegisterEventHotKey` just fails when
    /// another app already owns a combo and there is no way to ask beforehand,
    /// so the app walks this list and reports which one it is really listening on.
    public static func chain(preferred: String?) -> [String] {
        var chain: [String] = []
        if let preferred {
            let wanted = preferred.trimmingCharacters(in: .whitespaces).lowercased()
            if !wanted.isEmpty { chain.append(wanted) }
        }
        for fallback in fallbacks where !chain.contains(fallback) {
            chain.append(fallback)
        }
        return chain
    }

    /// "opt+space", "cmd+shift+space", "ctrl+alt+k" → Carbon key code and mask.
    /// Bare keys are rejected: a global hotkey with no modifier would swallow
    /// that key everywhere on the machine.
    public static func parse(_ combo: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var key: String?
        for token in combo.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }) {
            switch String(token) {
            case "opt", "alt", "option":   modifiers |= UInt32(optionKey)
            case "cmd", "command":         modifiers |= UInt32(cmdKey)
            case "ctrl", "control":        modifiers |= UInt32(controlKey)
            case "shift":                  modifiers |= UInt32(shiftKey)
            case let other:                key = other
            }
        }
        guard modifiers != 0, let key, let code = keyCode(for: key) else { return nil }
        return (UInt32(code), modifiers)
    }

    /// "opt+space" → "⌥Space", in the order macOS writes modifiers.
    public static func describe(_ combo: String) -> String {
        guard let parsed = parse(combo) else { return combo }
        var glyphs = ""
        if parsed.modifiers & UInt32(controlKey) != 0 { glyphs += "⌃" }
        if parsed.modifiers & UInt32(optionKey)  != 0 { glyphs += "⌥" }
        if parsed.modifiers & UInt32(shiftKey)   != 0 { glyphs += "⇧" }
        if parsed.modifiers & UInt32(cmdKey)     != 0 { glyphs += "⌘" }
        return glyphs + glyph(for: Int(parsed.keyCode))
    }

    /// The canonical spelling of a registered combo, so the app can report the
    /// key it actually got rather than the one that was asked for.
    public static func name(keyCode: UInt32, modifiers: UInt32) -> String? {
        guard let key = keyName(for: Int(keyCode)) else { return nil }
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if modifiers & UInt32(optionKey)  != 0 { parts.append("opt") }
        if modifiers & UInt32(shiftKey)   != 0 { parts.append("shift") }
        if modifiers & UInt32(cmdKey)     != 0 { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    static func glyph(for code: Int) -> String {
        guard let key = keyName(for: code) else { return "?" }
        switch key {
        case "space":  return "Space"
        case "return": return "↩"
        case "escape": return "⎋"
        case "tab":    return "⇥"
        case "period": return "."
        case "comma":  return ","
        case "slash":  return "/"
        default:       return key.uppercased()
        }
    }

    /// An array rather than a dictionary because the reverse lookup — code back
    /// to name — has to be deterministic.
    static let keys: [(name: String, code: Int)] = [
        ("space", kVK_Space), ("return", kVK_Return), ("escape", kVK_Escape),
        ("tab", kVK_Tab), ("period", kVK_ANSI_Period), ("comma", kVK_ANSI_Comma),
        ("slash", kVK_ANSI_Slash),
        ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
        ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
        ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
        ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
        ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
        ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
        ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
        ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
        ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
    ]

    static let aliases: [String: String] = [
        "esc": "escape", "enter": "return", "ret": "return", "spc": "space",
        ".": "period", ",": "comma", "/": "slash",
    ]

    static func keyCode(for name: String) -> Int? {
        let resolved = aliases[name] ?? name
        return keys.first { $0.name == resolved }?.code
    }

    static func keyName(for code: Int) -> String? {
        keys.first { $0.code == code }?.name
    }
}
