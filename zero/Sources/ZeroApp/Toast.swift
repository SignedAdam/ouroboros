import SwiftUI
import AppKit
import AVFoundation
import ZeroCore
import OuroborosUI

/// The one moment Ouroboros is allowed to interrupt you.
///
/// Everything else in this product is pull: you press a key when you want it,
/// the inbox waits until you look. A run landing is the exception, because it is
/// the only event that happens while your attention is genuinely elsewhere and
/// changes what is true about your code.
///
/// So: bottom-right, no focus stolen, no click required, gone in five seconds.
/// It never becomes key, so it cannot interrupt typing in another app.
@MainActor
final class ToastCenter: NSObject {
    static let shared = ToastCenter()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    /// Runs already announced, so a poll that re-sees the same landing is quiet.
    private var announced: Set<String> = []
    private var primed = false

    /// The first snapshot after launch is history, not news. Without this,
    /// starting the app replays every run that ever finished.
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
        present(ToastView(
            title: run.title,
            detail: run.note ?? run.result?.summary ?? run.projectName,
            project: run.projectName,
            good: landed))
        play(landed ? "landed" : nil)
    }

    // MARK: presentation

    private func present<Content: View>(_ content: Content) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Stays put across Space switches and never takes focus, so it can
        // appear over full-screen work without yanking you out of it.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        let hosting = NSHostingController(rootView: AnyView(content))
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)

        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 20,
                                         y: frame.minY + 20))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func play(_ name: String?) {
        guard let name,
              let url = Bundle.main.url(forResource: name, withExtension: "wav")
                ?? ToastCenter.developmentSound(name)
        else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.55
        player?.play()
    }

    /// Running straight out of `.build` there is no bundle to look in.
    private static func developmentSound(_ name: String) -> URL? {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name).wav")
        return FileManager.default.fileExists(atPath: here.path) ? here : nil
    }
}

struct ToastView: View {
    let title: String
    let detail: String
    let project: String
    let good: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            OuroborosMark()
                .foregroundStyle(good ? ouroOrange : Color(red: 1, green: 0.37, blue: 0.34))
                .frame(width: 20, height: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(good ? "landed" : "failed")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(good ? ouroOrange : Color(red: 1, green: 0.37, blue: 0.34))
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder((good ? ouroOrange : Color.red).opacity(0.22), lineWidth: 1))
        .onTapGesture { ToastCenter.shared.dismiss() }
    }
}
