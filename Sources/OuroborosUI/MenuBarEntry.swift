import SwiftUI
import Ouroboros

public struct OuroborosMenuBarEntry: Scene {
    private let ouroboros: Ouroboros
    @State private var showComposer = false

    public init(ouroboros: Ouroboros) { self.ouroboros = ouroboros }

    public var body: some Scene {
        MenuBarExtra("Report Issue", systemImage: "exclamationmark.bubble") {
            Button("Report Issue…") { showComposer = true }
        }
        Window("Report Issue", id: "ouroboros-composer") {
            if showComposer {
                IssueComposerView(ouroboros: ouroboros) { showComposer = false }
            }
        }
    }
}
