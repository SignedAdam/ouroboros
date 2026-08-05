import Foundation

public struct MergeVerdict: Codable, Sendable, Equatable {
    public var base: String
    public var branch: String

    public var baseSha: String
    public var branchSha: String
    public var clean: Bool

    public var conflicts: [String]
    public var checkedAt: Date

    public var error: String?

    public var staleness: Staleness?

    public init(base: String, branch: String, baseSha: String, branchSha: String,
                clean: Bool, conflicts: [String] = [], checkedAt: Date = Date(),
                error: String? = nil, staleness: Staleness? = nil) {
        self.base = base
        self.branch = branch
        self.baseSha = baseSha
        self.branchSha = branchSha
        self.clean = clean
        self.conflicts = conflicts
        self.checkedAt = checkedAt
        self.error = error
        self.staleness = staleness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        baseSha = try c.decodeIfPresent(String.self, forKey: .baseSha) ?? ""
        branchSha = try c.decodeIfPresent(String.self, forKey: .branchSha) ?? ""
        clean = try c.decodeIfPresent(Bool.self, forKey: .clean) ?? false
        conflicts = try c.decodeIfPresent([String].self, forKey: .conflicts) ?? []
        checkedAt = try c.decodeIfPresent(Date.self, forKey: .checkedAt) ?? Date()
        error = try c.decodeIfPresent(String.self, forKey: .error)
        staleness = try c.decodeIfPresent(Staleness.self, forKey: .staleness)
    }

    public var spent: Bool { error == nil && staleness?.spent == true }

    public var key: String { "\(baseSha)..\(branchSha)" }

    public func describes(baseSha: String, branchSha: String) -> Bool {
        !self.baseSha.isEmpty && !self.branchSha.isEmpty
            && self.baseSha == baseSha && self.branchSha == branchSha
    }

    public var state: String {
        if error != nil { return "unknown" }
        if spent { return "obsolete" }
        return clean ? "review" : "conflicts"
    }
}

public struct Staleness: Codable, Sendable, Equatable {
    public var commits: Int

    public var commitsUpstream: Int

    public var added: Int

    public var addedUpstream: Int

    public var newFiles: Int

    public init(commits: Int = 0, commitsUpstream: Int = 0, added: Int = 0,
                addedUpstream: Int = 0, newFiles: Int = 0) {
        self.commits = commits
        self.commitsUpstream = commitsUpstream
        self.added = added
        self.addedUpstream = addedUpstream
        self.newFiles = newFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commits = try c.decodeIfPresent(Int.self, forKey: .commits) ?? 0
        commitsUpstream = try c.decodeIfPresent(Int.self, forKey: .commitsUpstream) ?? 0
        added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        addedUpstream = try c.decodeIfPresent(Int.self, forKey: .addedUpstream) ?? 0
        newFiles = try c.decodeIfPresent(Int.self, forKey: .newFiles) ?? 0
    }

    public static let carriedOver = 0.9

    public var spent: Bool {
        guard commits > 0 else { return false }

        guard newFiles == 0 else { return false }
        if commitsUpstream == commits { return true }
        guard added > 0 else { return false }
        return Double(addedUpstream) >= Double(added) * Staleness.carriedOver
    }

    public var reason: String {
        if commits > 0, commitsUpstream == commits {
            return commits == 1
                ? "its commit is already on the base"
                : "all \(commits) commits are already on the base"
        }
        return "\(addedUpstream) of \(added) lines are already on the base"
    }
}

public final class MergeChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: MergeVerdict] = [:]

    public init() {}

    public func verdict(repo: String, base: String, branch: String,
                        now: Date = Date()) -> MergeVerdict {
        let git = Git(repo)
        let baseSha = sha(git, base)
        let branchSha = sha(git, branch)

        guard !baseSha.isEmpty, !branchSha.isEmpty else {
            return MergeVerdict(base: base, branch: branch,
                                baseSha: baseSha, branchSha: branchSha,
                                clean: false, checkedAt: now,
                                error: "no such branch")
        }

        let key = "\(baseSha)..\(branchSha)"
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit, hit.error == nil { return hit }

        if git.run(["merge-base", "--is-ancestor", branchSha, baseSha], timeout: 15).ok {
            let verdict = MergeVerdict(base: base, branch: branch,
                                       baseSha: baseSha, branchSha: branchSha,
                                       clean: true, checkedAt: now)
            store(key, verdict)
            return verdict
        }

        let result = git.run(["merge-tree", "--write-tree", "--name-only", baseSha, branchSha],
                             timeout: 60)
        var verdict: MergeVerdict
        switch result.status {
        case 0:
            verdict = MergeVerdict(base: base, branch: branch,
                                   baseSha: baseSha, branchSha: branchSha,
                                   clean: true, checkedAt: now)
        case 1:
            verdict = MergeVerdict(base: base, branch: branch,
                                   baseSha: baseSha, branchSha: branchSha,
                                   clean: false,
                                   conflicts: MergeChecks.conflicts(in: result.output),
                                   checkedAt: now)
        default:
            verdict = MergeVerdict(base: base, branch: branch,
                                   baseSha: baseSha, branchSha: branchSha,
                                   clean: false, checkedAt: now,
                                   error: MergeChecks.reason(result.output))
        }

        if verdict.error == nil {
            verdict.staleness = MergeChecks.staleness(git, base: baseSha, branch: branchSha)
        }
        store(key, verdict)
        return verdict
    }

    static func staleness(_ git: Git, base: String, branch: String) -> Staleness {
        var out = Staleness()

        let cherry = git.run(["cherry", base, branch], timeout: 60)
        if cherry.ok {
            for line in cherry.output.split(separator: "\n") {
                guard let mark = line.first, mark == "+" || mark == "-" else { continue }
                out.commits += 1
                if mark == "-" { out.commitsUpstream += 1 }
            }
        }

        let fork = git.run(["merge-base", base, branch], timeout: 20)
        guard fork.ok, !fork.trimmed.isEmpty else { return out }
        let forkPoint = fork.trimmed

        let named = git.run(["diff", "--name-status", "--diff-filter=AMR",
                             forkPoint, branch], timeout: 60)
        guard named.ok else { return out }

        for line in named.output.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count >= 2 else { continue }

            let path = fields[fields.count - 1]
            let onBase = git.run(["show", "\(base):\(path)"], timeout: 30)
            guard onBase.ok else { out.newFiles += 1; continue }

            var present: Set<String> = []
            for baseLine in onBase.output.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = baseLine.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { present.insert(trimmed) }
            }

            let patch = git.run(["diff", "-U0", forkPoint, branch, "--", path], timeout: 60)
            guard patch.ok else { continue }
            for patchLine in patch.output.split(separator: "\n") {
                guard patchLine.hasPrefix("+"), !patchLine.hasPrefix("+++") else { continue }
                let text = patchLine.dropFirst().trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                out.added += 1
                if present.contains(text) { out.addedUpstream += 1 }
            }
        }
        return out
    }

    static func conflicts(in output: String) -> [String] {
        var paths: [String] = []
        for (offset, line) in output.split(separator: "\n",
                                           omittingEmptySubsequences: false).enumerated() {
            if offset == 0 { continue }
            if line.isEmpty { break }
            paths.append(String(line))
        }
        return paths
    }

    static func reason(_ output: String) -> String {
        let line = output.split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let text = line.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? "could not test the merge" : text
    }

    private func store(_ key: String, _ verdict: MergeVerdict) {
        lock.lock()
        cache[key] = verdict

        if cache.count > 512 { cache.removeAll() }
        lock.unlock()
    }

    private func sha(_ git: Git, _ ref: String) -> String {
        let result = git.run(["rev-parse", "--verify", "\(ref)^{commit}"], timeout: 10)
        return result.ok ? result.trimmed : ""
    }
}
