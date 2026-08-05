import Foundation
import CryptoKit
import Ouroboros

public struct IssueService: Sendable {
    public let registry: Registry
    public init(registry: Registry) { self.registry = registry }

    public static func store(for project: Project) -> IssueStore {
        IssueStore(rootDir: project.path)
    }

    public static func id(project: Project, path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(project.id)-\(hex.prefix(10))"
    }

    public static func dto(_ issue: Issue, project: Project) -> IssueDTO {
        IssueDTO(id: id(project: project, path: issue.path ?? issue.slug),
                 projectId: project.id,
                 projectName: project.name,
                 title: issue.title,
                 slug: issue.slug,
                 body: issue.body,
                 status: issue.status.rawValue,
                 created: issue.created,
                 path: issue.path ?? "")
    }

    public func list(project: Project) -> [IssueDTO] {
        IssueService.store(for: project).list().map { IssueService.dto($0, project: project) }
    }

    public func listAll(status: String? = nil) -> [IssueDTO] {
        var out: [IssueDTO] = []
        for project in registry.all() {
            out.append(contentsOf: list(project: project))
        }
        if let status { out = out.filter { $0.status == status } }
        return out.sorted { (a, b) in
            switch (a.created, b.created) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.title < b.title
            }
        }
    }

    public func find(_ issueId: String) -> (Project, Issue)? {
        for project in registry.all() {
            let store = IssueService.store(for: project)
            for issue in store.list() {
                guard let path = issue.path else { continue }
                let candidate = IssueService.id(project: project, path: path)
                if candidate == issueId || candidate.hasPrefix(issueId) {
                    return (project, issue)
                }
            }
        }
        return nil
    }

    @discardableResult
    public func create(project: Project, title: String, body: String,
                       screenshot: IssueScreenshot? = nil) -> IssueDTO? {
        let store = IssueService.store(for: project)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? IssueText.suggestTitle(body)
            : title
        guard let issue = store.write(title: cleanTitle, body: body, screenshot: screenshot) else {
            return nil
        }
        registry.touch(project.id)
        return IssueService.dto(issue, project: project)
    }

    @discardableResult
    public func setStatus(project: Project, issue: Issue, status: IssueStatus) -> IssueDTO? {
        guard let moved = IssueService.store(for: project).setStatus(issue, status) else { return nil }
        return IssueService.dto(moved, project: project)
    }

    @discardableResult
    public func updateBody(project: Project, issue: Issue, body: String) -> IssueDTO? {
        guard let updated = IssueService.store(for: project).updateBody(issue, body: body) else {
            return nil
        }
        return IssueService.dto(updated, project: project)
    }

    @discardableResult
    public func append(project: Project, issue: Issue, text: String) -> IssueDTO? {
        updateBody(project: project, issue: issue, body: issue.body + text)
    }
}

public struct IdeaStore: Sendable {
    public let root: String
    private var store: IssueStore { IssueStore(rootDir: root, subdir: "new") }

    public init(root: String = Paths.ideasDir) {
        self.root = root
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    static func id(path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return "i-" + digest.map { String(format: "%02x", $0) }.joined().prefix(10)
    }

    func toIdea(_ issue: Issue) -> Idea {
        let path = issue.path ?? ""
        var projectId: String?
        var body = issue.body

        if let first = body.components(separatedBy: "\n").first,
           first.lowercased().hasPrefix("project:") {
            projectId = String(first.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            body = body.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Idea(id: IdeaStore.id(path: path), title: issue.title, body: body,
                    projectId: projectId, created: issue.created ?? Date(),
                    source: "human", path: path)
    }

    public func list(includeDone: Bool = false) -> [Idea] {
        store.list()
            .filter { includeDone || $0.status == .new || $0.status == .planned }
            .map(toIdea)
    }

    public func find(_ id: String) -> (Idea, Issue)? {
        for issue in store.list() {
            guard let path = issue.path else { continue }
            let candidate = IdeaStore.id(path: path)
            if candidate == id || candidate.hasPrefix(id) { return (toIdea(issue), issue) }
        }
        return nil
    }

    @discardableResult
    public func create(title: String?, body: String, projectId: String? = nil,
                       source: String = "human") -> Idea? {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let projectId, !projectId.isEmpty { text = "project: \(projectId)\n\n" + text }
        let name = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? IssueText.suggestTitle(body)
        guard let issue = store.write(title: name, body: text) else { return nil }
        return toIdea(issue)
    }

    @discardableResult
    public func retire(_ issue: Issue) -> Bool {
        store.setStatus(issue, .done) != nil
    }

    @discardableResult
    public func drop(_ issue: Issue) -> Bool {
        store.setStatus(issue, .cancelled) != nil
    }
}

public final class ProposalStore: @unchecked Sendable {
    private let lock = NSLock()
    private let root: String

    public init(root: String = Paths.proposalsDir) {
        self.root = root
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    private func path(_ id: String) -> String {
        (root as NSString).appendingPathComponent("\(id).json")
    }

    public func all() -> [Proposal] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { Zero.readJSON(Proposal.self, from: (root as NSString).appendingPathComponent($0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func pending() -> [Proposal] { all().filter { $0.state == .pending } }

    public func get(_ id: String) -> Proposal? {
        if let exact = Zero.readJSON(Proposal.self, from: path(id)) { return exact }
        let matches = all().filter { $0.id.hasPrefix(id) }
        return matches.count == 1 ? matches.first : nil
    }

    public func upsert(_ proposal: Proposal) -> (Proposal, Bool) {
        lock.lock(); defer { lock.unlock() }
        if let existing = all().first(where: {
            $0.dedupeKey == proposal.dedupeKey && $0.state == .pending
        }) {
            return (existing, false)
        }
        Zero.writeJSON(proposal, to: path(proposal.id))
        return (proposal, true)
    }

    @discardableResult
    public func setState(_ id: String, _ state: Proposal.State) -> Proposal? {
        lock.lock(); defer { lock.unlock() }
        guard var proposal = get(id) else { return nil }
        proposal.state = state
        Zero.writeJSON(proposal, to: path(proposal.id))
        return proposal
    }
}
