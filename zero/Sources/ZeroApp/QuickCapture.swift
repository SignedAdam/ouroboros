import SwiftUI
import AppKit
import QuartzCore
import Carbon.HIToolbox
import ZeroCore
import OuroborosUI

/// Launcher motion, not window motion: fast enough that it reads as "already
/// there" rather than as an animation you have to wait out.
private enum CaptureMotion {
    static let inDuration = 0.11
    static let outDuration = 0.08
    static let restingScale: CGFloat = 0.97
    static let exitScale: CGFloat = 0.98
}

/// The two pieces of state that have to cross the AppKit/SwiftUI line.
///
/// `slashSelection` lives here rather than in the view because a focused
/// `TextField` consumes the arrow keys long before SwiftUI's `onKeyPress` ever
/// sees them — the controller's local event monitor is the only place they
/// arrive first.
@MainActor
final class CaptureChrome: ObservableObject {
    @Published var scale: CGFloat = CaptureMotion.restingScale
    @Published var slashSelection = 0
    /// True while a sheet is up, so losing key doesn't read as a click outside.
    @Published var modalOpen = false
    /// Bumped on every show; the field takes focus again even though `onAppear`
    /// fires only once for a panel that is reused.
    @Published var focusToken = 0
}

/// A Spotlight-shaped capture box, summoned from anywhere with the global key.
///
/// This is the whole thesis in one window: the gap between noticing something
/// and an agent working on it should be one keystroke and one sentence. It is
/// deliberately NOT the menu-bar panel — reaching for the menu bar means
/// leaving whatever you were doing, and that is the friction the product exists
/// to delete.
@MainActor
final class QuickCaptureController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var followTimer: Timer?
    private let chrome = CaptureChrome()
    let model: AppModel

    private var isClosing = false
    /// Bumped by every show and hide, so a close that is still animating out
    /// can tell that it has been overtaken and must not order the panel away.
    private var closeToken = 0
    private var shownAt = Date.distantPast
    private var menuDepth = 0
    private var userMoved = false

    init(model: AppModel) {
        self.model = model
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(menuOpened),
                           name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuClosed),
                           name: NSMenu.didEndTrackingNotification, object: nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible && !isClosing ? hide() : show() }

    func show() {
        model.refresh()
        if panel == nil { panel = makePanel() }
        guard let panel else { return }

        closeToken &+= 1                    // overtakes a close that is still fading
        isClosing = false
        userMoved = false
        chrome.slashSelection = 0
        chrome.scale = CaptureMotion.restingScale
        panel.alphaValue = 0                // set before ordering front, or the
                                            // first frame flashes at full size

        recentre(panel, on: activeScreen())

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        shownAt = Date()
        chrome.focusToken &+= 1

        NSAnimationContext.runAnimationGroup { context in
            context.duration = CaptureMotion.inDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        withAnimation(.easeOut(duration: CaptureMotion.inDuration)) { chrome.scale = 1 }

        installMonitors()
    }

    func hide() {
        guard let panel, panel.isVisible, !isClosing else { return }
        isClosing = true
        closeToken &+= 1
        let token = closeToken
        teardownMonitors()

        // The field starts empty every time, like every other launcher. Letting
        // a dismissed draft survive is not a kindness: a leftover "/he" silently
        // turns the NEXT capture into "/hethe login button is broken", which
        // parses as a slash command and dispatches nothing. Losing a half-typed
        // sentence is cheap; a capture that quietly does the wrong thing is not.
        model.draft = ""

        withAnimation(.easeOut(duration: CaptureMotion.outDuration)) { chrome.scale = CaptureMotion.exitScale }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CaptureMotion.outDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit runs this on the main thread; `assumeIsolated` states that
            // rather than hopping through a Task, which would land a frame later
            // and let the panel flash back at full alpha.
            MainActor.assumeIsolated {
                // orderOut only after the fade, or the animation is never seen.
                guard let self, self.closeToken == token else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.chrome.scale = CaptureMotion.restingScale
                self.isClosing = false
            }
        }
    }

    // MARK: - panel

    private func makePanel() -> NSPanel {
        // Borderless, never `.titled`. A titled window draws AppKit's own theme
        // frame *over* the content: a near-white 1px hairline that reads as a
        // bright line across the top edge. It survives a hidden title, a
        // transparent titlebar and a clear background, because it belongs to the
        // frame rather than to anything we draw. Borderless has no theme frame,
        // so the only edge left is the orange stroke the view puts there on
        // purpose. `KeyablePanel` already overrides `canBecomeKey`, which is what
        // a borderless panel needs in order to take the keyboard.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // We dismiss on resignKey ourselves; letting AppKit hide the panel on
        // deactivate as well would snatch it away mid-fade.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.delegate = self

        let view = QuickCaptureView(model: model, chrome: chrome,
                                    onClose: { [weak self] in self?.hide() })
        // A hosting *controller*, not a bare hosting view: the window has to
        // grow when the slash palette appears, and only the controller keeps the
        // window sized to its SwiftUI content.
        panel.contentViewController = NSHostingController(rootView: view)
        return panel
    }

    // MARK: - keys

    private func installMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followActiveScreen() }
        }
    }

    private func teardownMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        followTimer?.invalidate()
        followTimer = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // A sheet owns the keyboard while it is up, escape included.
        guard !chrome.modalOpen, panel?.attachedSheet == nil else { return event }
        switch Int(event.keyCode) {
        case kVK_Escape:
            hide()
            return nil
        case kVK_UpArrow, kVK_DownArrow, kVK_Tab:
            return slashNavigation(event)
        default:
            return event
        }
    }

    /// Only swallows the key when the palette is actually up — Tab and the
    /// arrows have to keep their normal meaning the rest of the time.
    private func slashNavigation(_ event: NSEvent) -> NSEvent? {
        guard model.draft.hasPrefix("/") else { return event }
        let matches = SlashCommands.suggestions(for: model.draft)
        guard !matches.isEmpty else { return event }

        let current = min(max(0, chrome.slashSelection), matches.count - 1)
        switch Int(event.keyCode) {
        case kVK_UpArrow:
            chrome.slashSelection = max(0, current - 1)
        case kVK_DownArrow:
            chrome.slashSelection = min(matches.count - 1, current + 1)
        default:
            model.draft = "/" + matches[current].name + " "
            chrome.slashSelection = 0
        }
        return nil
    }

    // MARK: - placement

    private func activeScreen() -> NSScreen? {
        // Centre on the screen the mouse is on — with two monitors, "centre of
        // the main screen" is the wrong screen half the time.
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    private func recentre(_ panel: NSPanel, on screen: NSScreen?) {
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        // Launcher height: a little above the middle, not the middle. The panel
        // then grows *downward* from wherever its top edge lands, so the only
        // thing that has to be clamped is a panel tall enough — drawer open,
        // several lines typed — to poke out of the top of the screen.
        let wanted = frame.midY + frame.height * 0.12
        let headroom = frame.maxY - 12 - size.height
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: max(frame.minY + 12, min(wanted, headroom))))
    }

    private func followActiveScreen() {
        guard let panel, panel.isVisible, !isClosing, !userMoved else { return }
        guard let screen = activeScreen() else { return }
        let middle = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard !screen.frame.contains(middle) else { return }
        recentre(panel, on: screen)
    }

    @objc private func screensChanged() {
        guard let panel, panel.isVisible, !userMoved else { return }
        recentre(panel, on: activeScreen())
    }

    func windowDidMove(_ notification: Notification) {
        // Only a drag counts as the user placing the panel: it also "moves" when
        // it grows downward for the palette, and when we recentre it ourselves.
        if NSEvent.pressedMouseButtons != 0 { userMoved = true }
    }

    // MARK: - dismissal

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        // Whatever stole key has not been installed yet, so decide next turn.
        Task { @MainActor in self.dismissIfFocusLeft() }
    }

    @objc private func menuOpened() { menuDepth += 1 }

    @objc private func menuClosed() {
        menuDepth = max(0, menuDepth - 1)
        // A menu can close because the user clicked straight into another app,
        // and the panel gets no second resignKey for that. Only act when we
        // really did lose the foreground — a menu dismissed normally hands key
        // back to the panel a beat later, and must not close it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !NSApp.isActive else { return }
            self.dismissIfFocusLeft()
        }
    }

    private func dismissIfFocusLeft() {
        guard let panel, panel.isVisible, !isClosing else { return }
        guard menuDepth == 0, !chrome.modalOpen, panel.attachedSheet == nil else { return }
        // Activation itself can shuffle key around for a frame or two.
        guard Date().timeIntervalSince(shownAt) > 0.2 else { return }
        guard !panel.isKeyWindow else { return }
        // A window of OURS taking key — the menu-bar popover, a sheet — is not
        // the user clicking away.
        if let key = NSApp.keyWindow, key !== panel { return }
        hide()
    }
}

/// A borderless-ish panel still has to take the keyboard, or you can't type
/// into the one field it exists for.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct QuickCaptureView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var chrome: CaptureChrome
    @StateObject private var slash: SlashRunner
    var onClose: () -> Void
    @State private var flash: String?
    @State private var flashIsError = false

    init(model: AppModel, chrome: CaptureChrome, onClose: @escaping () -> Void) {
        self.model = model
        self.chrome = chrome
        self.onClose = onClose
        _slash = StateObject(wrappedValue: SlashRunner(model: model))
    }

    private var matches: [SlashCommand] {
        model.draft.hasPrefix("/") ? SlashCommands.suggestions(for: model.draft) : []
    }

    private var selection: Int {
        guard !matches.isEmpty else { return 0 }
        return min(max(0, chrome.slashSelection), matches.count - 1)
    }

    private var hotkeyLabel: String {
        HotkeyManager.current.map(HotkeyManager.describe) ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the drawer, so the panel's own edge covers the drawer's
            // first row of pixels and the two read as one joined object.
            card.zIndex(1)

            // A slash command is a different mode: the palette answers the
            // question the drawer would have answered.
            if matches.isEmpty {
                ProjectsDrawer(model: model, expanded: model.recentsExpanded) {
                    withAnimation(.easeOut(duration: 0.15)) { model.recentsExpanded.toggle() }
                }
                .padding(.top, -1)
            }
        }
        .frame(width: 560)
        .scaleEffect(chrome.scale)
        .onAppear { model.refresh() }
        .onChange(of: model.draft) { _, _ in
            if chrome.slashSelection != 0 { chrome.slashSelection = 0 }
        }
        .onChange(of: slash.wizard?.id) { _, id in chrome.modalOpen = id != nil }
        .sheet(item: $slash.wizard) { request in
            ProjectWizardSheet(request: request, model: model, onClose: { slash.wizard = nil })
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                OuroborosMark()
                    .foregroundStyle(ouroOrange)
                    .frame(width: 22, height: 22)
                    .padding(.top, 1)

                GrowingField(text: $model.draft,
                             placeholder: "what's wrong?",
                             font: .rounded(19),
                             maxLines: 7,
                             focusToken: chrome.focusToken,
                             onSubmit: { submit(fix: false) })
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // The palette brings its own card, so it floats inside the panel
            // rather than sitting in a divided section of it.
            if !matches.isEmpty {
                SlashPalette(matches: matches, selection: selection)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Menu {
                    ForEach(model.projects) { project in
                        Button(project.name) { model.selectedProjectId = project.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(model.selectedProject?.name ?? "no project")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if let flash {
                    Text(flash)
                        .font(.system(size: 11))
                        .foregroundStyle(flashIsError
                                         ? Color(red: 1.0, green: 0.37, blue: 0.34)
                                         : ouroOrange)
                        .lineLimit(1)
                }

                Spacer()

                if matches.isEmpty {
                    Text("⏎ file").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("⌘⏎ file & fix").font(.system(size: 10)).foregroundStyle(ouroOrange)
                    Text("/ commands").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("⏎ run").font(.system(size: 10)).foregroundStyle(ouroOrange)
                    Text("⇥ complete").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("↑↓ pick").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("esc").font(.system(size: 10)).foregroundStyle(.secondary)

                if !hotkeyLabel.isEmpty {
                    Text(hotkeyLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            // The invisible hotkey for "file and put an agent on it".
            Button("") { submit(fix: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(ouroOrange.opacity(0.25), lineWidth: 1))
    }

    private func submit(fix: Bool) {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if text.hasPrefix("/") {
            Task {
                let handled = await slash.run(text)
                let fallback: String? = handled ? nil : "not a command"
                flashIsError = !handled
                flash = slash.status ?? fallback
                guard handled else { return }
                model.draft = ""
                // A wizard is a conversation, not a confirmation: its sheet needs
                // the panel to stay under it.
                if slash.wizard == nil { closeAfterFlash() }
            }
            return
        }

        let project = model.selectedProject?.name ?? ""
        model.file(fix: fix)
        flashIsError = false
        flash = fix ? "dispatched → \(project)" : "filed → \(project)"
        closeAfterFlash()
    }

    private func closeAfterFlash() {
        // Close on a short beat so the confirmation is actually seen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            flash = nil
            onClose()
        }
    }
}

/// Global hotkey via Carbon. Chosen over an `NSEvent` global monitor on
/// purpose: `RegisterEventHotKey` needs no Accessibility permission, so the
/// feature works the first time the app is launched instead of after a trip
/// through System Settings.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static var action: (() -> Void)?

    /// The combo that actually took, which is not necessarily the configured
    /// one — see `register(preferred:action:)`.
    private(set) var activeCombo: String?

    /// Mirror of `activeCombo`. The capture panel is built a long way from the
    /// AppDelegate that owns the manager, and still has to show the true key.
    private(set) static var current: String?

    /// Tried in order after the configured combo. Ordered by how little else on
    /// a Mac wants them.
    static var fallbacks: [String] { HotkeyCombo.fallbacks }

    /// The combos the last `register(preferred:action:)` walked, in order. Kept
    /// so a total failure can say what it tried rather than "it didn't work".
    private(set) var attempted: [String] = []

    /// `RegisterEventHotKey` just fails when another app already owns a combo,
    /// and there is no way to ask beforehand — so walk a list and report back
    /// which one the app is actually listening on.
    @discardableResult
    func register(preferred: String?, action: @escaping () -> Void) -> String? {
        let chain = HotkeyCombo.chain(preferred: preferred)
        attempted = chain

        for combo in chain {
            guard let parsed = HotkeyManager.parse(combo) else { continue }
            if register(keyCode: parsed.keyCode, modifiers: parsed.modifiers, action: action) {
                activeCombo = combo
                HotkeyManager.current = combo
                return combo
            }
        }
        activeCombo = nil
        HotkeyManager.current = nil
        return nil
    }

    /// One attempt at one combo. Private and without defaults on purpose: the
    /// only supported way in is `register(preferred:action:)`, so nobody can
    /// silently pin the app to a hard-coded key again.
    @discardableResult
    private func register(keyCode: UInt32,
                          modifiers: UInt32,
                          action: @escaping () -> Void) -> Bool {
        HotkeyManager.action = action

        // One handler for the process however many combos get tried: installing
        // it per attempt would fire the action once per install.
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotkeyManager.action?() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
            guard installed == noErr else { return false }
        }

        if let previous = hotKeyRef {
            UnregisterEventHotKey(previous)
            hotKeyRef = nil
        }
        let id = EventHotKeyID(signature: OSType(0x4F55_524F), id: 1)   // 'OURO'
        let registered = RegisterEventHotKey(keyCode, modifiers, id,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            hotKeyRef = nil
            return false
        }
        activeCombo = HotkeyManager.name(keyCode: keyCode, modifiers: modifiers)
        HotkeyManager.current = activeCombo
        return true
    }

    // MARK: - combos

    // The combo grammar itself — "opt+space" ↔ (key code, modifier mask), and
    // the ⌥⇧⌘ rendering — is `HotkeyCombo` in ZeroCore. It is pure string work
    // that the daemon and the CLI read too, and it is the part worth testing
    // without an event handler in the way. These forward so every caller in the
    // app keeps saying `HotkeyManager.parse` / `.describe`.

    /// "opt+space", "cmd+shift+space", "ctrl+alt+k" → Carbon key code and mask.
    /// Bare keys are rejected: a global hotkey with no modifier would swallow
    /// that key everywhere on the machine.
    static func parse(_ combo: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        HotkeyCombo.parse(combo)
    }

    /// "opt+space" → "⌥Space", in the order macOS writes modifiers.
    static func describe(_ combo: String) -> String {
        HotkeyCombo.describe(combo)
    }

    private static func name(keyCode: UInt32, modifiers: UInt32) -> String? {
        HotkeyCombo.name(keyCode: keyCode, modifiers: modifiers)
    }
}
