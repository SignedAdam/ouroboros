import SwiftUI
import AppKit
import AVFoundation
import ZeroCore
import OuroborosUI

struct ToastContent: Equatable {
    let title: String
    let detail: String
    let good: Bool
}

@MainActor
final class ToastState: ObservableObject {
    @Published var content: ToastContent
    @Published var dwell = ToastDwell()
    @Published var pinned = false
    @Published var hovering = false

    init(_ content: ToastContent) { self.content = content }
}

@MainActor
final class ToastCenter: NSObject {
    static let shared = ToastCenter()

    private var panel: NSPanel?
    private var state: ToastState?
    private var ticker: Task<Void, Never>?
    private var player: AVAudioPlayer?

    private var waiting: [ToastContent] = []
    private var grabbedAt: NSPoint?
    private var grabbedFrom: NSPoint?
    private var rememberedOrigin: NSPoint?

    private var announced: Set<String> = []
    private var primed = false

    func prime(with runs: [Run]) {
        guard !primed else { return }
        announced = Set(runs.map(\.id))
        primed = true
    }

    func observe(_ runs: [Run]) {
        guard primed else { return prime(with: runs) }
        for run in runs where run.status.isTerminal && !announced.contains(run.id) {
            announced.insert(run.id)
            show(run)
        }
    }

    func show(_ run: Run) {
        let landed = run.status == .succeeded
        play(landed ? "landed" : nil)
        let content = ToastContent(
            title: run.title,
            detail: run.note ?? run.result?.summary ?? run.projectName,
            good: landed)

        if state?.pinned == true, panel?.isVisible == true {
            waiting.append(content)
            waiting = Array(waiting.suffix(3))
        } else {
            present(content)
        }
    }

    func preview() {
        play("landed")
        present(ToastContent(
            title: "the capture panel has a bright hairline along its top edge",
            detail: "ouroboros · verified and merged into main",
            good: true))
    }

    private func present(_ content: ToastContent) {
        ticker?.cancel()
        panel?.orderOut(nil)
        grabbedAt = nil
        grabbedFrom = nil

        let state = ToastState(content)
        self.state = state

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        let hosting = ToastHostingView(rootView: AnyView(ToastView(state: state)))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        if let origin = ToastPlacement.origin(remembered: rememberedOrigin,
                                              size: panel.frame.size,
                                              screens: screenFrames()) {
            panel.setFrameOrigin(origin)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        startTicking()
    }

    private func screenFrames() -> [CGRect] {
        let others = NSScreen.screens.map(\.visibleFrame)
        guard let main = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return others }
        return [main] + others
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self, self.tick() else { return }
            }
        }
    }

    private func tick() -> Bool {
        guard let panel, let state else { return false }
        hover(grabbedAt != nil || panel.frame.contains(NSEvent.mouseLocation))
        guard state.dwell.hasExpired() else { return true }
        dismiss()
        return false
    }

    func hover(_ inside: Bool) {
        guard let state, state.hovering != inside else { return }
        state.hovering = inside
        guard !state.pinned else { return }
        if inside {
            state.dwell.pause()
        } else {
            state.dwell.resume(atLeast: ToastDwell.hoverFloor)
        }
    }

    func togglePin() {
        guard let state else { return }
        state.pinned.toggle()
        if state.pinned {
            state.dwell.pause()
        } else {
            state.dwell.restart()
            if state.hovering { state.dwell.pause() }
        }
    }

    func grab() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        guard let start = grabbedAt, let from = grabbedFrom else {
            grabbedAt = mouse
            grabbedFrom = panel.frame.origin
            return
        }
        panel.setFrameOrigin(NSPoint(x: from.x + mouse.x - start.x,
                                     y: from.y + mouse.y - start.y))
    }

    func letGo() {
        grabbedAt = nil
        grabbedFrom = nil
        rememberedOrigin = panel?.frame.origin
    }

    func dismiss() {
        ticker?.cancel()
        ticker = nil
        state = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                self?.showNextWaiting()
            }
        }
    }

    private func showNextWaiting() {
        guard panel == nil, !waiting.isEmpty else { return }
        present(waiting.removeFirst())
    }

    private func play(_ name: String?) {
        guard let name,
              let url = Bundle.module.url(forResource: name, withExtension: "wav")
                ?? Bundle.main.url(forResource: name, withExtension: "wav")
                ?? ToastCenter.developmentSound(name)
        else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.55
        player?.play()
    }

    private static func developmentSound(_ name: String) -> URL? {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name).wav")
        return FileManager.default.fileExists(atPath: here.path) ? here : nil
    }
}

final class ToastHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct ToastView: View {
    @ObservedObject var state: ToastState

    private var good: Bool { state.content.good }
    private var accent: Color { good ? ouroOrange : Color(red: 1, green: 0.37, blue: 0.34) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                OuroborosMark()
                    .foregroundStyle(accent)
                    .frame(width: 20, height: 20)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(good ? "landed" : "failed")
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(accent)
                    Text(state.content.title)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .lineLimit(1)
                    Text(state.content.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)

                buttons
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 11)

            clock
                .padding(.horizontal, 14)
                .padding(.bottom, 9)
        }
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(accent.opacity(state.pinned ? 0.5 : 0.22),
                              lineWidth: state.pinned ? 1.4 : 1))
        .animation(.easeOut(duration: 0.18), value: state.pinned)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in ToastCenter.shared.grab() }
                .onEnded { _ in ToastCenter.shared.letGo() })
        .onTapGesture {
            guard !state.pinned else { return }
            ToastCenter.shared.dismiss()
        }
    }

    private var clock: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(accent.opacity(0.12))
            countdown
        }
        .frame(height: 2.5)
        .help(state.pinned ? "pinned — this one stays until you close it"
                           : "how long this stays on screen")
    }

    @ViewBuilder private var countdown: some View {
        if state.pinned {
            Capsule()
                .fill(accent.opacity(0.3))
                .transition(.opacity)
        } else if state.dwell.isPaused {
            rail(state.dwell.fractionLeft()).opacity(0.5)
        } else {
            TimelineView(.animation) { tick in
                rail(state.dwell.fractionLeft(at: tick.date))
            }
        }
    }

    private func rail(_ left: Double) -> some View {
        GeometryReader { size in
            Capsule()
                .fill(accent.opacity(0.85))
                .frame(width: size.size.width * left)
        }
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            round("pin.fill", filled: state.pinned,
                  help: state.pinned ? "unpin — the clock starts over"
                                     : "pin — keep this up until you close it") {
                ToastCenter.shared.togglePin()
            }
            round("xmark", filled: false, help: "close") {
                ToastCenter.shared.dismiss()
            }
        }
        .opacity(state.hovering || state.pinned ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: state.hovering)
    }

    private func round(_ symbol: String,
                       filled: Bool,
                       help: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(filled ? accent : Color.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(filled ? accent.opacity(0.16)
                                                 : Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
