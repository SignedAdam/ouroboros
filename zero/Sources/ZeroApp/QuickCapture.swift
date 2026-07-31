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
        // The only way anything below the panel can close it. A row verb that
        // opens another window calls `handOff`, which ends up here; everything
        // else leaves the panel exactly where it is. See `RowVerb`.
        model.dismissCapture = { [weak self] in self?.hide() }
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
        // Same argument for the receipt: "copied the title" is about the panel
        // you just closed, not the one you are about to open.
        model.clearNote()
        // And the options row, which is a detour you took once. The settings it
        // wrote are on the project; the disclosure is not.
        model.optionsOpen = false

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
        case kVK_UpArrow, kVK_DownArrow:
            return slashNavigation(event)
        case kVK_Tab:
            // The palette gets first claim on ⇥: finishing the command you are
            // half-way through typing beats switching project under it. The rest
            // of the time — which is nearly always — ⇥ walks the drawer, so the
            // project a capture lands in is one key away instead of a trip to
            // the folder menu with the mouse. ⇧⇥ walks back up.
            if paletteIsUp { return slashNavigation(event) }
            model.cycleProject(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return nil
        default:
            return event
        }
    }

    /// The slash palette is on screen, so it owns the navigation keys.
    private var paletteIsUp: Bool {
        model.draft.hasPrefix("/") && !SlashCommands.suggestions(for: model.draft).isEmpty
    }

    /// Only swallows the key when the palette is actually up — Tab and the
    /// arrows have to keep their normal meaning the rest of the time.
    private func slashNavigation(_ event: NSEvent) -> NSEvent? {
        guard paletteIsUp else { return event }
        let matches = SlashCommands.suggestions(for: model.draft)

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
        // The menu took the keyboard for as long as it was up. If the panel is
        // still here — which, after a verb that keeps it, is most of the time —
        // the field wants it back, or the next thing you type goes nowhere.
        if menuDepth == 0, let panel, panel.isVisible, !isClosing {
            chrome.focusToken &+= 1
        }
        // A menu can close because the user clicked straight into another app,
        // and the panel gets no second resignKey for that. Only act when we
        // really did lose the foreground — a menu dismissed normally hands key
        // back to the panel a beat later, and must not close it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            // A verb ran, so this menu closed because something was picked from
            // it. What happens to the panel is that verb's decision and
            // `RowVerb.handsOff` has already made it — never a side effect of
            // where the keyboard happened to land. Deciding this on
            // `NSApp.isActive` alone is what made "Delete" sometimes take the
            // whole panel with it: a nonactivating panel summoned over another
            // app is perfectly usable without this app ever being the active
            // one, and then every menu pick looked like a click somewhere else.
            guard Date().timeIntervalSince(self.model.lastVerbAt) > 0.5 else { return }
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
                // Task and job rows reach the model through the environment
                // rather than threading it down four levels of view.
                .environmentObject(model)
            }
        }
        .frame(width: 560)
        .scaleEffect(chrome.scale)
        .onAppear { model.refresh() }
        .onChange(of: model.draft) { _, _ in
            if chrome.slashSelection != 0 { chrome.slashSelection = 0 }
        }
        .onChange(of: slash.wizard?.id) { _, id in chrome.modalOpen = id != nil }
        // A sheet, not a window: escape closes the diff and puts you back on
        // this drawer with the same project still open, which is what §4 of the
        // brief asks for and what a separate window could not do.
        .onChange(of: model.showingDiff == nil) { _, gone in
            chrome.modalOpen = !gone
            if gone { chrome.focusToken &+= 1 }
        }
        .sheet(item: $model.showingDiff) { report in
            DiffView(report: report) { model.showingDiff = nil }
        }
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
                    // No folder glyph. The name is already the name of a
                    // directory; an icon in front of it adds a pixel of noise
                    // and not one bit of information.
                    Text(model.selectedProject?.name ?? "no project")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Which harness this capture goes to. There was no way to say
                // "use codex for this one" anywhere in the product before, and
                // the answer was buried in a JSON file.
                Menu {
                    ForEach(model.availableAgents, id: \.self) { agent in
                        Button(agent + (agent == model.effectiveAgent ? "  ✓" : "")) {
                            model.agentOverride = agent
                        }
                    }
                    if model.agentOverride != nil {
                        Divider()
                        Button("Use this project's default") { model.agentOverride = nil }
                    }
                } label: {
                    // A `cpu` glyph here read as a disk and meant nothing. The
                    // word "claude" is already unambiguous.
                    Text(model.effectiveAgent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.agentOverride != nil ? ouroOrange : Color.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("which coding agent this capture will dispatch to")

                // A command in flight owns this slot. `/update` pulls, builds
                // and reinstalls — minutes of nothing, which reads exactly like
                // a panel that ignored you. A spinner and a number that moves
                // are the difference between "working" and "hung".
                if slash.working {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                        Text(slash.status ?? "working…")
                            .font(.system(size: 11))
                            .foregroundStyle(ouroOrange)
                            .lineLimit(1)
                        if let startedAt = slash.startedAt {
                            // Redraws itself once a second; nothing else in the
                            // panel has a reason to re-render while we wait.
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(QuickCaptureView.elapsed(since: startedAt))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .help("this runs in the daemon — closing the panel will not stop it")
                } else if let flash = model.flash {
                    // The panel's one line of feedback, and now the only one: a
                    // verb that keeps the panel open has to be able to say what
                    // it did, or the click reads as having done nothing.
                    Text(flash.text)
                        .font(.system(size: 11))
                        .foregroundStyle(flash.bad
                                         ? Color(red: 1.0, green: 0.37, blue: 0.34)
                                         : ouroOrange)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }

                Spacer()

                optionsToggle

                // Only what you can actually do this second.
                //
                // Three permanent hints read as one run-on string, and the
                // worst of them was `/ commands`: a slash set in body text is
                // punctuation, not a key, so it looked like the tail of a
                // sentence rather than something to press. Two changes fix it
                // without a word of explanation. Every key is drawn as a key —
                // a cap you press, which makes `/` unmistakably a keystroke.
                // And the row is now conditional: an empty field cannot be
                // filed (`submit` refuses it), so filing is not offered, and
                // the one hint nobody would ever discover is alone on the line.
                // Type a character and it swaps for the two that are now true.
                // For the two seconds a receipt is up it gets the row to itself.
                // The hints are a reference you can read at any time; "copied
                // the ti…" is a sentence that failed halfway through, and a
                // receipt nobody can read is worse than no receipt at all.
                if model.flash == nil {
                    HStack(spacing: 14) {
                        if !matches.isEmpty {
                            hint("⏎", "run", accent: true)
                            hint("⇥", "complete")
                            hint("↑↓", "pick")
                        } else if draftIsEmpty {
                            hint("/", "commands")
                        } else {
                            hint("⏎", "file")
                            hint("⌘⏎", "fix", accent: true)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: draftIsEmpty)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            if model.optionsOpen { DispatchOptions(model: model) }

            // The invisible hotkey for "file and put an agent on it".
            Button("") { submit(fix: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)

            // And for the options row. ⌘, is the one key on this platform that
            // already means "the settings for the thing in front of you".
            Button("") { toggleOptions() }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(ouroOrange.opacity(0.25), lineWidth: 1))
    }

    private var draftIsEmpty: Bool {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The way in to the dispatch options, and the only cost they add to the
    /// fast path: one chevron, no word. Collapsed every time the panel opens,
    /// because the answers are remembered on the project and a row you have to
    /// close again is a step the ⏎ path never asked for.
    private var optionsToggle: some View {
        Button(action: toggleOptions) {
            Image(systemName: "chevron.up")
                .font(.system(size: 8, weight: .black))
                .rotationEffect(.degrees(model.optionsOpen ? 180 : 0))
                .foregroundStyle(model.optionsOpen ? ouroOrange : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("dispatch options  ⌘,")
    }

    private func toggleOptions() {
        withAnimation(.easeOut(duration: 0.13)) { model.optionsOpen.toggle() }
        if model.optionsOpen { model.loadBranches() }
    }

    /// A key, drawn as a key, and what it does.
    ///
    /// The cap is the entire point: `⏎` and `⌘⏎` read as keys whatever you set
    /// them in, because no sentence contains them — but `/` does, and set flat
    /// it was read as punctuation by the person it was written for. Give it an
    /// outline and a fill and it stops being a slash and becomes a keystroke,
    /// which is the whole instruction, without a word of instruction.
    private func hint(_ key: String, _ verb: String, accent: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(accent ? ouroOrange : Color.primary.opacity(0.65))
                .frame(minWidth: 9)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accent ? ouroOrange.opacity(0.13) : Color.primary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(accent ? ouroOrange.opacity(0.32) : Color.primary.opacity(0.14),
                                  lineWidth: 0.5))
            Text(verb)
                .font(.system(size: 10))
                .foregroundStyle(accent ? ouroOrange.opacity(0.8) : Color.secondary)
        }
        .fixedSize()
    }

    static func elapsed(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s"
    }

    private func submit(fix: Bool) {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if text.hasPrefix("/") {
            Task {
                let handled = await slash.run(text)
                model.note(slash.status ?? (handled ? "done" : "not a command"), bad: !handled)
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
        model.note(fix ? "dispatched → \(project)" : "filed → \(project)")
        closeAfterFlash()
    }

    private func closeAfterFlash() {
        // Close on a short beat so the confirmation is actually seen. `hide`
        // drops the note, so the next capture opens clean.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { onClose() }
    }
}

/// How the next dispatch out of this panel will be run: its own worktree or
/// not, what happens when it passes, and what it branches off.
///
/// The engine has supported all three since the beginning and none of them was
/// reachable while filing — the answers lived in `ouro projects set` and in a
/// JSON file. So they are here, one row, closed until you ask for it with ⌘,.
///
/// It writes to the **project**, not to the capture, and that is the whole
/// design: how a repo wants its fixes handled is a property of the repo, not of
/// the sentence you happen to be typing. Answer once and every later capture
/// into it inherits the answer. The defaults are exactly what they were, so ⏎
/// and ⌘⏎ are the same two keystrokes they have always been.
private struct DispatchOptions: View {
    @ObservedObject var model: AppModel

    private var project: Project? { model.selectedProject }

    var body: some View {
        HStack(spacing: 14) {
            if let project {
                worktree(project)
                finish(project)
                base(project)
            } else {
                Text("no project")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 11)
        .padding(.top, 1)
        .transition(.opacity)
    }

    /// On by default, and the reason the gate can exist at all: an agent in its
    /// own tree cannot touch what you have open. Off is for the small fixes
    /// where a worktree costs more than it saves.
    private func worktree(_ project: Project) -> some View {
        let on = project.policy.worktreeDefault
        return Button {
            model.setOption(API.PatchProject(worktreeDefault: !on),
                            note: on ? "fixes here run in the repo"
                                     : "fixes here get their own worktree")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("worktree")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(on ? ouroOrange : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("run the agent in its own checkout")
    }

    private func finish(_ project: Project) -> some View {
        Menu {
            ForEach([Finish.merge, .pr, .leave], id: \.self) { choice in
                Button(DispatchOptions.word(choice)
                       + (project.policy.finishDefault == choice ? "  ✓" : "")) {
                    model.setOption(API.PatchProject(finishDefault: choice.rawValue),
                                    note: DispatchOptions.receipt(choice))
                }
            }
        } label: {
            label("finish", DispatchOptions.word(project.policy.finishDefault))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("what happens when a fix passes the gate")
    }

    /// The branch a fix is cut from and merged back into. A list, not a field:
    /// the repo already knows its branches, and a base you have to spell is a
    /// base you can get wrong.
    private func base(_ project: Project) -> some View {
        Menu {
            if model.branches.isEmpty {
                Text("no branches")
            }
            ForEach(model.branches, id: \.self) { branch in
                Button(branch + (currentBase(project) == branch ? "  ✓" : "")) {
                    model.setOption(API.PatchProject(baseBranch: branch),
                                    note: "off \(branch)")
                }
            }
        } label: {
            label("base", currentBase(project))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("the branch fixes here are cut from")
    }

    private func currentBase(_ project: Project) -> String {
        project.baseBranch ?? model.branches.first ?? "main"
    }

    /// A quiet noun and the answer. The noun is not a label explaining itself —
    /// three values on one line need to say which is which.
    private func label(_ noun: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(noun)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    static func word(_ finish: Finish) -> String {
        switch finish {
        case .merge: return "merge"
        case .pr:    return "pull request"
        case .leave: return "leave it"
        }
    }

    static func receipt(_ finish: Finish) -> String {
        switch finish {
        case .merge: return "verified fixes here will merge themselves"
        case .pr:    return "verified fixes here open a pull request"
        case .leave: return "fixes here wait on their branch"
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
