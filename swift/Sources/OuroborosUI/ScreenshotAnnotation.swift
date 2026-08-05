import AppKit
import SwiftUI
import Ouroboros

public struct ScreenshotNote: Equatable, Sendable {
    public var text: String
    public var position: CGPoint
    public init(text: String, position: CGPoint) {
        self.text = text
        self.position = position
    }
}

public struct ScreenshotMarkup: Equatable, Sendable {
    public var strokes: [[CGPoint]] = []
    public var notes: [ScreenshotNote] = []
    public var isEmpty: Bool { strokes.isEmpty && notes.isEmpty }
    public init() {}
}

public enum ScreenshotAnnotator {
    public static let penColor = NSColor(red: 1.0, green: 0.478, blue: 0.094, alpha: 1)

    @MainActor
    public static func captureAppWindow() -> NSImage? {
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView,
              view.bounds.width > 50,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    public static func composite(base: NSImage, markup: ScreenshotMarkup,
                                 accent: NSColor = ScreenshotAnnotator.penColor) -> Data? {
        let size = base.size
        guard size.width > 0, size.height > 0 else { return nil }
        let out = NSImage(size: size, flipped: true) { rect in
            base.draw(in: rect)
            let penWidth = max(2.5, size.width * 0.004)
            for stroke in markup.strokes where stroke.count > 1 {
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: CGPoint(x: stroke[0].x * size.width, y: stroke[0].y * size.height))
                for p in stroke.dropFirst() {
                    path.line(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                }
                NSColor.white.setStroke()
                path.lineWidth = penWidth * 2.0
                path.stroke()
                accent.setStroke()
                path.lineWidth = penWidth
                path.stroke()
            }
            let fontSize = max(12, size.width * 0.014)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: accent,
            ]
            for note in markup.notes {
                let text = NSAttributedString(string: note.text, attributes: attrs)
                let textSize = text.size()
                let pad = fontSize * 0.45
                var origin = CGPoint(x: note.position.x * size.width,
                                     y: note.position.y * size.height)
                origin.x = min(max(0, origin.x), size.width - textSize.width - pad * 2)
                origin.y = min(max(0, origin.y), size.height - textSize.height - pad * 2)
                let chip = CGRect(x: origin.x, y: origin.y,
                                  width: textSize.width + pad * 2, height: textSize.height + pad * 2)
                NSColor.black.withAlphaComponent(0.82).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
                text.draw(at: CGPoint(x: chip.minX + pad, y: chip.minY + pad))
            }
            return true
        }
        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

public struct AnnotatableScreenshotView: View {
    public let image: NSImage
    @Binding public var markup: ScreenshotMarkup
    public var editable: Bool
    public var accent: Color = Color(nsColor: ScreenshotAnnotator.penColor)
    public var border: Color = .white.opacity(0.16)

    public init(image: NSImage, markup: Binding<ScreenshotMarkup>, editable: Bool,
                accent: Color = Color(nsColor: ScreenshotAnnotator.penColor),
                border: Color = .white.opacity(0.16)) {
        self.image = image
        self._markup = markup
        self.editable = editable
        self.accent = accent
        self.border = border
    }

    @State private var currentStroke: [CGPoint] = []
    @State private var pendingNoteAt: CGPoint?
    @State private var pendingNoteText = ""
    @FocusState private var noteFocused: Bool

    private var aspect: CGFloat {
        image.size.height > 0 ? image.size.width / image.size.height : 16 / 10
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable()
                Canvas { ctx, canvasSize in
                    func scaled(_ pts: [CGPoint]) -> Path {
                        var path = Path()
                        guard let first = pts.first else { return path }
                        path.move(to: CGPoint(x: first.x * canvasSize.width, y: first.y * canvasSize.height))
                        for p in pts.dropFirst() {
                            path.addLine(to: CGPoint(x: p.x * canvasSize.width, y: p.y * canvasSize.height))
                        }
                        return path
                    }
                    let pen = max(1.5, canvasSize.width * 0.004)
                    for stroke in markup.strokes + (currentStroke.count > 1 ? [currentStroke] : []) {
                        let path = scaled(stroke)
                        ctx.stroke(path, with: .color(.white),
                                   style: StrokeStyle(lineWidth: pen * 2, lineCap: .round, lineJoin: .round))
                        ctx.stroke(path, with: .color(accent),
                                   style: StrokeStyle(lineWidth: pen, lineCap: .round, lineJoin: .round))
                    }
                }

                ForEach(Array(markup.notes.enumerated()), id: \.offset) { _, note in
                    Text(note.text)
                        .font(.system(size: max(9, size.width * 0.014), weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(Color.black.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .offset(x: note.position.x * size.width, y: note.position.y * size.height)
                }
                if editable, let at = pendingNoteAt {
                    TextField("note…", text: $pendingNoteText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(Color.black.opacity(0.92))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(accent, lineWidth: 1))
                        .frame(width: 180)
                        .offset(x: min(at.x * size.width, size.width - 190),
                                y: min(at.y * size.height, size.height - 28))
                        .focused($noteFocused)
                        .onSubmit { commitPendingNote(at: at) }
                        .onExitCommand { pendingNoteAt = nil; pendingNoteText = "" }
                        .onAppear { noteFocused = true }
                }
            }
            .contentShape(Rectangle())
            .gesture(editable ? drawGesture(in: size) : nil)
            .simultaneousGesture(editable ? doubleTap(in: size) : nil)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(border))
    }

    private func drawGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                guard pendingNoteAt == nil, size.width > 0, size.height > 0 else { return }
                currentStroke.append(CGPoint(x: v.location.x / size.width,
                                             y: v.location.y / size.height))
            }
            .onEnded { _ in
                if currentStroke.count > 1 { markup.strokes.append(currentStroke) }
                currentStroke = []
            }
    }

    private func doubleTap(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { v in
                guard size.width > 0, size.height > 0 else { return }
                pendingNoteText = ""
                pendingNoteAt = CGPoint(x: v.location.x / size.width,
                                        y: v.location.y / size.height)
            }
    }

    private func commitPendingNote(at: CGPoint) {
        let text = pendingNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { markup.notes.append(ScreenshotNote(text: text, position: at)) }
        pendingNoteAt = nil
        pendingNoteText = ""
    }
}
