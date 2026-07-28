import SwiftUI
import AppKit
import ZeroCore
import OuroborosUI

@main
struct OuroborosZeroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.model)
        } label: {
            // Ambient status, no numbers: the mark lights up while agents work.
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// `MenuBarExtra`'s label is rendered into a template image, so a `Canvas`
/// (which the brand mark uses) can't be drawn there directly — it has to be
/// rasterised first. Rendering once per state change keeps that cheap.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let image = MenuBarIcon.render(active: model.runningCount > 0,
                                              needsYou: !model.inbox.isEmpty) {
                Image(nsImage: image)
            } else {
                Image(systemName: "circle.dashed")
            }
        }
    }

    static var cache: [String: NSImage] = [:]

    static func render(active: Bool, needsYou: Bool) -> NSImage? {
        let key = "\(active)-\(needsYou)"
        if let cached = cache[key] { return cached }

        let side: CGFloat = 18
        let color: Color = active ? ouroOrange
            : needsYou ? Color(red: 1.0, green: 0.74, blue: 0.18)
            : .primary
        let view = OuroborosMark()
            .foregroundStyle(color)
            .frame(width: side, height: side)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
        // Only the idle mark is a template — the coloured states must keep their
        // colour so "something is running" reads at a glance.
        image.isTemplate = !active && !needsYou
        cache[key] = image
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var hotkey = HotkeyManager()
    private var quickCapture: QuickCaptureController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        model.ensureDaemon()
        model.start()

        let capture = QuickCaptureController(model: model)
        quickCapture = capture

        // The configured combo is a preference, not a promise: another app may
        // already own it, and Carbon only tells you by failing. The manager walks
        // its fallbacks and hands back the one it really got — which is also the
        // one the capture panel's footer shows, so the app never advertises a key
        // that does nothing.
        let preferred = Config.load().hotkey
        let wanted = preferred.trimmingCharacters(in: .whitespaces).lowercased()
        if let combo = hotkey.register(preferred: preferred, action: { [weak capture] in
            capture?.toggle()
        }) {
            if combo != wanted {
                NSLog("ouroboros: \(wanted.isEmpty ? "no hotkey configured" : wanted) is taken — "
                      + "capture is on \(combo); change it with /hotkey")
            }
        } else {
            NSLog("ouroboros: no capture hotkey could be registered — tried "
                  + "\(hotkey.attempted.joined(separator: ", ")); use the menu bar instead")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quickCapture?.hide()
    }
}
