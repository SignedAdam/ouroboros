import SwiftUI
import AppKit

struct GrowingField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var maxLines: Int

    var focusToken: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
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

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

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

            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
        }

        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken

            DispatchQueue.main.async {
                if textView.window?.makeFirstResponder(textView) != true {
                    DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? {
        let proposed = proposal.width ?? nsView.bounds.width

        let placing = proposed.isFinite && proposed > 40
        let measured = context.coordinator.measure.measure(
            text, font: font, width: placing ? proposed : 100_000)
        let lines = min(max(1, measured.lines), max(1, maxLines))
        return CGSize(width: placing ? proposed : min(ceil(measured.width), 100_000),
                      height: ceil(measured.lineHeight * CGFloat(lines)))
    }

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

            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }
}

extension NSFont {
    static func rounded(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

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
            break
        default:
            super.doCommand(by: selector)
        }
    }

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
