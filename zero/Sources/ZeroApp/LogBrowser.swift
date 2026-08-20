import SwiftUI
import AppKit
import ZeroCore

@MainActor
final class LogBrowserController: NSObject, NSWindowDelegate {
    static let shared = LogBrowserController()
    private var window: NSWindow?
    private let model = LogBrowserModel()

    func show(filter: String? = nil) {
        if let filter, !filter.isEmpty {
            if filter.lowercased() == "errors" {
                model.level = .errorsOnly
                model.search = ""
            } else {
                model.search = filter
                model.level = .everything
            }
        }
        if window == nil { window = makeWindow() }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Ouroboros activity"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: LogBrowserView(model: model))
        window.setFrameAutosaveName("ouroboros.logs")
        return window
    }
}

enum LogLevelFilter: String, CaseIterable, Identifiable {
    case everything, warnings, errorsOnly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .everything: return "all"
        case .warnings:   return "warnings"
        case .errorsOnly: return "errors"
        }
    }

    var minimum: LogLevel? {
        switch self {
        case .everything: return nil
        case .warnings:   return .warn
        case .errorsOnly: return .error
        }
    }
}

@MainActor
final class LogBrowserModel: ObservableObject {
    @Published var lines: [LogEvent] = []
    @Published var expanded: Set<Int> = []
    @Published var level: LogLevelFilter = .everything
    @Published var search = ""
    @Published var loading = false
    @Published var exhausted = false
    @Published var failure: String?

    private let client = ZeroClient()
    private let page = 333

    var warnCount: Int { lines.filter { $0.level == .warn }.count }
    var errorCount: Int { lines.filter { $0.level == .error }.count }
    var span: String {
        guard let low = lines.first?.id, let high = lines.last?.id else { return "—" }
        return low == high ? "#\(low)" : "#\(low)–#\(high)"
    }

    func reload() {
        exhausted = false
        expanded = []
        load(before: nil, replacing: true)
    }

    func loadOlder() {
        guard !loading, !exhausted, let oldest = lines.first?.id, oldest > 1 else { return }
        load(before: oldest, replacing: false)
    }

    private func load(before: Int?, replacing: Bool) {
        loading = true
        var path = "/v1/logs?limit=\(page)"
        if let minimum = level.minimum { path += "&level=\(minimum.rawValue)" }
        let term = search.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            path += "&q=\(term.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? term)"
        }
        if let before { path += "&before=\(before)" }

        Task.detached { [client, path] in
            let result = try? client.get(path, as: API.LogList.self)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading = false
                guard let result else {
                    self.failure = "the daemon isn't answering"
                    return
                }
                self.failure = nil
                let fetched = result.lines.sorted { $0.id < $1.id }
                if replacing {
                    self.lines = fetched
                } else if fetched.isEmpty {
                    self.exhausted = true
                } else {
                    let known = Set(self.lines.map(\.id))
                    self.lines.insert(contentsOf: fetched.filter { !known.contains($0.id) }, at: 0)
                }
            }
        }
    }

    func toggle(_ id: Int) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

private enum Col {
    static let gutter: CGFloat = 46
    static let time: CGFloat = 70
    static let level: CGFloat = 26
    static let event: CGFloat = 152
    static let project: CGFloat = 104
    static let rule: CGFloat = 1

    static var messageInset: CGFloat {
        gutter + time + level + event + project + rule * 5
    }
}

private struct VRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: Col.rule)
    }
}

struct LogBrowserView: View {
    @ObservedObject var model: LogBrowserModel
    @State private var anchor: Int?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            header
            Divider()
            if let failure = model.failure {
                Spacer()
                Text(failure).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else if model.lines.isEmpty && !model.loading {
                Spacer()
                Text("nothing here yet")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else {
                rows
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 400)
        .onAppear { if model.lines.isEmpty { model.reload() } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(
                get: { model.level },
                set: { model.level = $0; model.reload() })) {
                    ForEach(LogLevelFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .labelsHidden()

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                TextField("filter", text: $model.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 190)
                    .onSubmit { model.reload() }
                if !model.search.isEmpty {
                    Button { model.search = ""; model.reload() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            .help("reload")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell("##", Col.gutter, align: .trailing)
            VRule()
            cell("TIME", Col.time)
            VRule()
            cell("", Col.level)
            VRule()
            cell("EVENT", Col.event)
            VRule()
            cell("PROJECT", Col.project)
            VRule()
            cell("MESSAGE", nil)
        }
        .frame(height: 20)
        .background(Color.primary.opacity(0.04))
    }

    private func cell(_ text: String, _ width: CGFloat?, align: Alignment = .leading) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .kerning(0.5)
            .padding(.horizontal, 6)
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    topSentinel
                    ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, event in
                        LogRow(event: event,
                               zebra: index.isMultiple(of: 2),
                               expanded: model.expanded.contains(event.id),
                               onTap: { model.toggle(event.id) })
                            .id(event.id)
                    }
                }
            }
            .onChange(of: model.lines.count) { _, _ in

                if let anchor {
                    proxy.scrollTo(anchor, anchor: .top)
                    self.anchor = nil
                } else if let last = model.lines.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var topSentinel: some View {
        Group {
            if model.exhausted {
                Text("beginning of the log")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            } else {
                Color.clear.frame(height: 1)
                    .onAppear {
                        anchor = model.lines.first?.id
                        model.loadOlder()
                    }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Text("\(model.lines.count) lines")
                .foregroundStyle(.secondary)
            dot
            Text(model.span).foregroundStyle(.tertiary)
            if model.warnCount > 0 {
                dot
                Text("\(model.warnCount) warn").foregroundStyle(LogLevel.warn.tint)
            }
            if model.errorCount > 0 {
                dot
                Text("\(model.errorCount) error\(model.errorCount == 1 ? "" : "s")")
                    .foregroundStyle(LogLevel.error.tint)
            }
            if model.loading {
                dot
                Text("loading older…").foregroundStyle(.tertiary)
            }

            Spacer()

            Text("↑ older").foregroundStyle(.tertiary)
            dot
            Text("click a line to expand").foregroundStyle(.tertiary)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    private var dot: some View {
        Text(" · ").foregroundStyle(.quaternary)
    }
}

private struct LogRow: View {
    let event: LogEvent
    let zebra: Bool
    let expanded: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("\(event.id)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 8)
                    .frame(width: Col.gutter, alignment: .trailing)
                    .frame(maxHeight: .infinity)
                    .background(Color.primary.opacity(0.05))
                VRule()

                text(LogRow.time.string(from: event.ts), size: 10, mono: true)
                    .foregroundStyle(.secondary)
                    .frame(width: Col.time, alignment: .leading)
                VRule()

                Text(event.level.glyph)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(event.level.tint)
                    .frame(width: Col.level)
                VRule()

                text(event.event, size: 10, mono: true)
                    .foregroundStyle(event.level == .info ? .primary : event.level.tint)
                    .frame(width: Col.event, alignment: .leading)
                VRule()

                text(event.project ?? "", size: 10, mono: false)
                    .foregroundStyle(.secondary)
                    .frame(width: Col.project, alignment: .leading)
                VRule()

                text(event.message, size: 11, mono: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 19)
            .background(background)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { hovering = $0 }

            if expanded { LogDetail(event: event) }
        }
    }

    private func text(_ value: String, size: CGFloat, mono: Bool) -> some View {
        Text(value)
            .font(.system(size: size, design: mono ? .monospaced : .default))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
    }

    private var background: Color {
        if expanded { return Color.accentColor.opacity(0.10) }
        if hovering { return Color.primary.opacity(0.06) }
        return zebra ? Color.primary.opacity(0.022) : .clear
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

private struct LogDetail: View {
    let event: LogEvent

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Col.messageInset)
            VStack(alignment: .leading, spacing: 3) {
                field("when", LogDetail.full.string(from: event.ts), style: .mono)
                field("event", event.event, style: .mono)
                field("level", event.level.rawValue, style: .tinted(event.level.tint))
                field("message", event.message, style: .plain)
                field("run", event.run, style: .mono)
                field("issue", event.issue, style: .path)
                field("path", event.path, style: .path)
                field("branch", event.branch, style: .mono)
                field("agent", event.agent, style: .plain)
                field("session", event.session, style: .mono)
                field("duration", event.durationMs.map(LogDetail.duration), style: .plain)
                field("exit", event.exitCode.map(String.init),
                      style: .tinted(event.exitCode == 0 ? LogLevel.info.tint : LogLevel.error.tint))

                if let detail = event.detail, !detail.isEmpty {
                    Divider().padding(.vertical, 3).frame(width: 320)
                    ForEach(detail.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        field(key, value, style: value.hasPrefix("/") ? .path : .plain)
                    }
                }
            }
            .padding(.vertical, 9)
            .padding(.leading, 10)
            Spacer(minLength: 0)
        }
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(event.level.tint.opacity(0.55))
                .frame(width: 2)
                .padding(.leading, Col.messageInset)
        }
    }

    enum Style {
        case plain, mono, path
        case tinted(Color)
    }

    @ViewBuilder
    private func field(_ key: String, _ value: String?, style: Style) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Text(key)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .trailing)
                render(value, style)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func render(_ value: String, _ style: Style) -> some View {
        switch style {
        case .plain:
            Text(value).font(.system(size: 11))
        case .mono:
            Text(value).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        case .path:
            Text(LogDetail.shorten(value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .help(value)
        case .tinted(let color):
            Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
        }
    }

    static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    static func shorten(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy · HH:mm:ss.SSS"
        return f
    }()
}

extension LogLevel {
    var tint: Color {
        switch self {
        case .debug: return .secondary
        case .info:  return Color(red: 0.47, green: 0.67, blue: 1.0)
        case .warn:  return Color(red: 1.0, green: 0.74, blue: 0.18)
        case .error: return Color(red: 1.0, green: 0.37, blue: 0.34)
        }
    }

    var glyph: String {
        switch self {
        case .debug: return "·"
        case .info:  return "●"
        case .warn:  return "!"
        case .error: return "✗"
        }
    }
}
