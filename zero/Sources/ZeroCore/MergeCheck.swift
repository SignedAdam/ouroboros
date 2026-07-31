import Foundation

// MARK: - would this actually merge?

/// The answer to "can this land", and the two commits it is an answer about.
///
/// Ouroboros used to call a run `ready` without ever having tried to merge it.
/// That is a verdict the code had not checked: a branch verified green in its
/// own worktree can still be unmergeable, and it becomes unmergeable without
/// anything happening to it — the base moves underneath.
///
/// So the verdict carries `baseSha` and `branchSha`. A merge verdict without
/// its operands is not a weaker verdict, it is a different kind of statement:
/// the same branch against `main` was three conflicts before a rebase and a
/// fast-forward after, and both answers were true when they were given. Naming
/// the pair is also what makes the cache safe — a verdict is reusable exactly
/// as long as neither side has moved.
public struct MergeVerdict: Codable, Sendable, Equatable {
    /// The refs, as asked.
    public var base: String
    public var branch: String
    /// The commits they resolved to. These, not the refs, are what was tested.
    public var baseSha: String
    public var branchSha: String
    public var clean: Bool
    /// Paths git could not merge on its own. Empty when `clean`.
    public var conflicts: [String]
    public var checkedAt: Date
    /// Set when the question could not be asked at all — no such ref, not a
    /// repo, git too old. Distinct from a confident "no".
    public var error: String?

    public init(base: String, branch: String, baseSha: String, branchSha: String,
                clean: Bool, conflicts: [String] = [], checkedAt: Date = Date(),
                error: String? = nil) {
        self.base = base
        self.branch = branch
        self.baseSha = baseSha
        self.branchSha = branchSha
        self.clean = clean
        self.conflicts = conflicts
        self.checkedAt = checkedAt
        self.error = error
    }

    /// A daemon older than this type sends nothing; every field defaults rather
    /// than failing the run it is attached to.
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
    }

    /// The pair this verdict is about. Two verdicts with the same key are the
    /// same verdict, however long ago either was taken.
    public var key: String { "\(baseSha)..\(branchSha)" }

    /// Still true of the repo as it stands now.
    public func describes(baseSha: String, branchSha: String) -> Bool {
        !self.baseSha.isEmpty && !self.branchSha.isEmpty
            && self.baseSha == baseSha && self.branchSha == branchSha
    }

    /// What the row says. Not a label for the UI to invent from `clean`,
    /// because "we could not tell" must not render as "it merges".
    public var state: String {
        if error != nil { return "unknown" }
        return clean ? "review" : "conflicts"
    }
}

// MARK: - asking git

/// Tests a merge without performing one, and remembers the answer.
///
/// `git merge-tree --write-tree` does the whole merge in the object database:
/// no worktree, no index, nothing to clean up and nothing to abort. Exit 0 is
/// clean, exit 1 is conflicts, anything else is a question that could not be
/// asked. `--name-only` reduces the conflict section to bare paths, which is
/// all a row needs.
///
/// Cached against the pair of shas, so the drawer can render a merge verdict
/// per row per frame without forking git. A pair that has been answered stays
/// answered: neither commit can change what it contains.
public final class MergeChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: MergeVerdict] = [:]

    public init() {}

    /// Requires git 2.38 or newer for `--write-tree`. Older git reports the
    /// verdict as unknown rather than guessing.
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

        // Already contained in the base: nothing to merge, and merge-tree would
        // answer "clean" for a branch that has in fact already landed. Saying so
        // explicitly keeps the two situations apart.
        if git.run(["merge-base", "--is-ancestor", branchSha, baseSha], timeout: 15).ok {
            let verdict = MergeVerdict(base: base, branch: branch,
                                       baseSha: baseSha, branchSha: branchSha,
                                       clean: true, checkedAt: now)
            store(key, verdict)
            return verdict
        }

        let result = git.run(["merge-tree", "--write-tree", "--name-only", baseSha, branchSha],
                             timeout: 60)
        let verdict: MergeVerdict
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
            // Exit 128 and friends: not a repo, unknown revision, a git that
            // has never heard of --write-tree. Not an answer.
            verdict = MergeVerdict(base: base, branch: branch,
                                   baseSha: baseSha, branchSha: branchSha,
                                   clean: false, checkedAt: now,
                                   error: MergeChecks.reason(result.output))
        }
        store(key, verdict)
        return verdict
    }

    /// The conflicted paths out of `merge-tree --name-only`.
    ///
    /// The output is the merged tree's oid, then one path per line, then a
    /// blank line, then git's own commentary — which mentions the same paths
    /// again in prose and must not be read as more of them.
    static func conflicts(in output: String) -> [String] {
        var paths: [String] = []
        for (offset, line) in output.split(separator: "\n",
                                           omittingEmptySubsequences: false).enumerated() {
            if offset == 0 { continue }                  // the tree oid
            if line.isEmpty { break }                    // end of the file list
            paths.append(String(line))
        }
        return paths
    }

    /// One line, so a failed check can say why without pasting git at someone.
    static func reason(_ output: String) -> String {
        let line = output.split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let text = line.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? "could not test the merge" : text
    }

    private func store(_ key: String, _ verdict: MergeVerdict) {
        lock.lock()
        cache[key] = verdict
        // A machine with sixty projects and a long history would otherwise
        // accumulate one entry per pair for ever. Nothing here is worth
        // remembering across a restart, let alone unboundedly.
        if cache.count > 512 { cache.removeAll() }
        lock.unlock()
    }

    private func sha(_ git: Git, _ ref: String) -> String {
        let result = git.run(["rev-parse", "--verify", "\(ref)^{commit}"], timeout: 10)
        return result.ok ? result.trimmed : ""
    }
}
