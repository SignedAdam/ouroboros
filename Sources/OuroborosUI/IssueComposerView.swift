import SwiftUI
import Ouroboros

public struct IssueComposerView: View {
    private let ouroboros: Ouroboros
    private let onClose: () -> Void

    @State private var body_ = ""
    @State private var title = ""
    @State private var titleDirty = false
    @State private var worktree = true
    @State private var finish: FixOptions.Finish = .mergeIntoBase
    @State private var saved: Issue?

    public init(ouroboros: Ouroboros, onClose: @escaping () -> Void) {
        self.ouroboros = ouroboros
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let saved {
                Text("Issue saved").font(.headline)
                Text(saved.path ?? "").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Not now") { onClose() }
                    Button("Fix it") {
                        ouroboros.handToAgent(saved, options: FixOptions(worktree: worktree, finish: finish))
                        onClose()
                    }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Describe the issue").font(.headline)
                TextEditor(text: $body_)
                    .frame(minHeight: 140)
                    .onChange(of: body_) { _, new in
                        if !titleDirty { title = IssueText.suggestTitle(new) }
                    }
                TextField("Title", text: $title)
                    .onChange(of: title) { _, _ in titleDirty = true }
                Toggle("Run in a new worktree", isOn: $worktree)
                Picker("On finish", selection: $finish) {
                    Text("Merge into base").tag(FixOptions.Finish.mergeIntoBase)
                    Text("Open a PR").tag(FixOptions.Finish.openPR)
                }.pickerStyle(.segmented)
                HStack {
                    Button("Cancel") { onClose() }
                    Button("Create Issue") {
                        let t = title.isEmpty ? IssueText.suggestTitle(body_) : title
                        if let issue = ouroboros.submit(title: t, body: body_) { saved = issue }
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
