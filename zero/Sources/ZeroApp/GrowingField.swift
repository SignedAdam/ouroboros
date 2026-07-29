import SwiftUI
import AppKit

/// The capture box's one field, which grows with what you type.
///
/// This is an `NSTextView` rather than SwiftUI's `TextField(axis: .vertical)`
/// because the panel sizes the *window* to its content, and that only works if
/// the field can state its height exactly. A field that reports one line's
/// worth of height and then wraps to three is how you end up typing into a slot
/// that scrolls your own sentence out of sight — which is what it did.
///
/// Growth stops at `maxLines`; past that the field scrolls, because a capture
/// box that can grow to fill the screen is no longer a capture box.
struct GrowingField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var maxLines: Int
    /// Bumped by the panel every time it is summoned; the field takes the
    /// keyboard again even though it was never torn down.
    var focusToken: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Built on an explicit TextKit 1 stack. A plain `NSTextView()` gets
        // TextKit 2, whose `layoutManager` is nil — and measuring the text is
        // the entire reason this view exists, so a text view that cannot be
        // measured is not one we can use.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = CaptureTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = font
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(ouroOrange)
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        // A bug report is half code and half punctuation; curly quotes and
        // em-dashes substituted into it are corruption, not typography.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // No inset and no padding, so the text starts exactly where the layout
        // says it does and the placeholder can be drawn at the same origin.
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? CaptureTextView else { return }

        textView.onSubmit = onSubmit
        textView.placeholder = placeholder
        if textView.font != font { textView.font = font }
        if textView.string != text {
            textView.string = text
            // Text arriving from outside is a completion (`/help ` from the
            // palette) or a reset — either way the caret belongs at the end.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
        }

        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            // The panel is ordered front in the same turn, so the window may not
            // have the field yet; one hop is enough, with one retry for the
            // first show of a freshly built view.
            DispatchQueue.main.async {
                if textView.window?.makeFirstResponder(textView) != true {
                    DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
                }
            }
        }
    }

    /// The whole point: an exact height for the text as it is right now,
    /// clamped to `maxLines`.
    ///
    /// Measured off `text` in the coordinator's own layout stack rather than
    /// off the live text view, because SwiftUI asks this question *before* it
    /// hands the new text to `updateNSView` — measuring the view would report
    /// the height of the previous keystroke forever.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? {
        let proposed = proposal.width ?? nsView.bounds.width
        // A stack does not only ask "how tall at this width". It also asks with
        // no width at all, and with none to spare — and laying text out into an
        // infinite container is how a NaN comes back and takes the process with
        // it. Both of those are answered by the text's own width.
        let placing = proposed.isFinite && proposed > 40
        let measured = context.coordinator.measure.measure(
            text, font: font, width: placing ? proposed : 100_000)
        let lines = min(max(1, measured.lines), max(1, maxLines))
        return CGSize(width: placing ? proposed : min(ceil(measured.width), 100_000),
                      height: ceil(measured.lineHeight * CGFloat(lines)))
    }

    /// A layout stack with no view attached, kept for the sole purpose of
    /// answering "how many lines is this, at this width".
    final class TextMeasure {
        private let storage = NSTextStorage()
        private let layout = NSLayoutManager()
        private let container = NSTextContainer(
            size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))

        init() {
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
        }

        func measure(_ text: String, font: NSFont,
                     width: CGFloat) -> (lines: Int, width: CGFloat, lineHeight: CGFloat) {
            let line = layout.defaultLineHeight(for: font)
            // A trailing newline is a line you are about to type on; the layout
            // manager only counts it when a text view asks it to.
            let trailing = text.hasSuffix("\n") ? 1 : 0
            storage.setAttributedString(NSAttributedString(
                string: text.isEmpty ? " " : text, attributes: [.font: font]))
            container.size = NSSize(width: max(1, width),
                                    height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            guard used.height.isFinite, used.width.isFinite else { return (1, width, line) }
            return (Int((used.height / max(line, 1)).rounded(.up)) + trailing, used.width, line)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingField
        var focusToken = -1
        let measure = TextMeasure()

        init(_ parent: GrowingField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // Past `maxLines` the field scrolls, and the caret has to stay in
            // the part of it you can see.
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }
}

extension NSFont {
    /// SwiftUI's `.rounded` design, on the AppKit side of the field, so the
    /// placeholder and the text you type are the same typeface as the panel.
    static func rounded(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// Return files the issue; every other way of asking for a newline inserts one.
final class CaptureTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholder = ""

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                super.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else {
                onSubmit?()
            }
        case #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            super.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // Swallowed. Tab completes a slash command (handled before the field
            // ever sees it) and otherwise means nothing here — it must not put a
            // stray tab in the middle of an issue.
            break
        default:
            super.doCommand(by: selector)
        }
    }

    /// Drawn here rather than layered behind in SwiftUI so it sits on the text's
    /// own origin — a placeholder a pixel off its own text is the kind of thing
    /// you can see without being able to name.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: [
            .font: font,
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
}
