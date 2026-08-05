import SwiftUI
import AppKit
import QuartzCore
import Carbon.HIToolbox
import ZeroCore
import OuroborosUI

private enum CaptureMotion {
    static let inDuration = 0.11
    static let outDuration = 0.08
    static let restingScale: CGFloat = 0.97
    static let exitScale: CGFloat = 0.98
}

@MainActor
final class CaptureChrome: ObservableObject {
    @Published var scale: CGFloat = CaptureMotion.restingScale
    @Published var slashSelection = 0

    @Published var modalOpen = false

    @Published var focusToken = 0
}

@MainActor
final class QuickCaptureController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var followTimer: Timer?
    private let chrome = CaptureChrome()
    let model: AppModel

    private var isClosing = false

    private var closeToken = 0
    private var shownAt = Date.distantPast
    private var menuDepth = 0
    private var userMoved = false

    init(model: AppModel) {
        self.model = model
        super.init()

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

        closeToken &+= 1
        isClosing = false
        userMoved = false
        chrome.slashSelection = 0
        chrome.scale = CaptureMotion.restingScale
        panel.alphaValue = 0

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

        model.draft = ""

        model.clearNote()

        model.optionsOpen = false

        withAnimation(.easeOut(duration: CaptureMotion.outDuration)) { chrome.scale = CaptureMotion.exitScale }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CaptureMotion.outDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in

            MainActor.assumeIsolated {
                guard let self, self.closeToken == token else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.chrome.scale = CaptureMotion.restingScale
                self.isClosing = false
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true
        panel.level = .floating

        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.delegate = self

        let view = QuickCaptureView(model: model, chrome: chrome,
                                    onClose: { [weak self] in self?.hide() })

        panel.contentViewController = NSHostingController(rootView: view)
        return panel
    }

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
        guard !chrome.modalOpen, panel?.attachedSheet == nil else { return event }
        switch Int(event.keyCode) {
        case kVK_Escape:
            hide()
            return nil
        case kVK_UpArrow, kVK_DownArrow:
            return slashNavigation(event)
        case kVK_Tab:
            if paletteIsUp { return slashNavigation(event) }
            model.cycleProject(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return nil
        default:
            return event
        }
    }

    private var paletteIsUp: Bool {
        model.draft.hasPrefix("/") && !SlashCommands.suggestions(for: model.draft).isEmpty
    }

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

    private func activeScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    private func recentre(_ panel: NSPanel, on screen: NSScreen?) {
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size

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
        if NSEvent.pressedMouseButtons != 0 { userMoved = true }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }

        Task { @MainActor in self.dismissIfFocusLeft() }
    }

    @objc private func menuOpened() { menuDepth += 1 }

    @objc private func menuClosed() {
        menuDepth = max(0, menuDepth - 1)

        if menuDepth == 0, let panel, panel.isVisible, !isClosing {
            chrome.focusToken &+= 1
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)

            guard Date().timeIntervalSince(self.model.lastVerbAt) > 0.5 else { return }
            guard !NSApp.isActive else { return }
            self.dismissIfFocusLeft()
        }
    }

    private func dismissIfFocusLeft() {
        guard let panel, panel.isVisible, !isClosing else { return }
        guard menuDepth == 0, !chrome.modalOpen, panel.attachedSheet == nil else { return }

        guard Date().timeIntervalSince(shownAt) > 0.2 else { return }
        guard !panel.isKeyWindow else { return }

        if let key = NSApp.keyWindow, key !== panel { return }
        hide()
    }
}

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
            card.zIndex(1)

            if matches.isEmpty {
                ProjectsDrawer(model: model, expanded: model.recentsExpanded) {
                    withAnimation(.easeOut(duration: 0.15)) { model.recentsExpanded.toggle() }
                }
                .padding(.top, -1)

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
                    Text(model.selectedProject?.name ?? "no project")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

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
                    Text(model.effectiveAgent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.agentOverride != nil ? ouroOrange : Color.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("which coding agent this capture will dispatch to")

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
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(QuickCaptureView.elapsed(since: startedAt))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .help("this runs in the daemon — closing the panel will not stop it")
                } else if let flash = model.flash {
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

            Button("") { submit(fix: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { onClose() }
    }
}

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

final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static var action: (() -> Void)?

    private(set) var activeCombo: String?

    private(set) static var current: String?

    static var fallbacks: [String] { HotkeyCombo.fallbacks }

    private(set) var attempted: [String] = []

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

    @discardableResult
    private func register(keyCode: UInt32,
                          modifiers: UInt32,
                          action: @escaping () -> Void) -> Bool {
        HotkeyManager.action = action

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
        let id = EventHotKeyID(signature: OSType(0x4F55_524F), id: 1)
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

    static func parse(_ combo: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        HotkeyCombo.parse(combo)
    }

    static func describe(_ combo: String) -> String {
        HotkeyCombo.describe(combo)
    }

    private static func name(keyCode: UInt32, modifiers: UInt32) -> String? {
        HotkeyCombo.name(keyCode: keyCode, modifiers: modifiers)
    }
}
