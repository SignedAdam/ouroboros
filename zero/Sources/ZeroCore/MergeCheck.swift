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
    /// Whether the branch still has anything to give. A branch whose work is
    /// already upstream conflicts exactly like one whose work is not, and the
    /// two want opposite things from a person. See `Staleness`.
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
        staleness = try c.decodeIfPresent(Staleness.self, forKey: .staleness)
    }

    /// Nothing left to give. Only ever a real answer: "we could not tell"
    /// must not become "throw the branch away".
    public var spent: Bool { error == nil && staleness?.spent == true }

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
        if spent { return "obsolete" }
        return clean ? "review" : "conflicts"
    }
}

// MARK: - has this branch anything left to give?

/// Whether a branch is spent, and the evidence for saying so.
///
/// `merge-tree` answers "would this go in". It cannot answer "is there anything
/// in here worth putting in", and the two look identical from outside: a branch
/// whose work somebody re-applied by hand still conflicts, still verified green,
/// and still asks a person to sit down and resolve something that is finished.
///
/// Two ways a branch can be spent, and they need different questions:
///
///   **cherry-picked or rebased upstream** — `git cherry` finds a patch-id
///   equivalent for every commit. Exact, and it is the answer whenever the
///   commits themselves went in.
///
///   **re-implemented upstream** — somebody read the branch and wrote the same
///   thing again, usually because the base moved so far that replaying it was
///   not worth attempting. No patch-id survives that, so `git cherry` says
///   nothing. What does survive is the content: the lines are on the base, in a
///   form the base has since carried on editing.
///
/// The second question is a measurement, so it is reported as one — the numbers
/// are on the struct and the row can say `551 of 590 lines already on main`
/// rather than asking anyone to take `obsolete` on trust.
public struct Staleness: Codable, Sendable, Equatable {
    /// Commits on the branch that are not on the base.
    public var commits: Int
    /// Of those, how many `git cherry` found already upstream.
    public var commitsUpstream: Int
    /// Lines the branch adds, measured from where it forked.
    public var added: Int
    /// Of those, how many the base's own copy of that same file already has.
    public var addedUpstream: Int
    /// Files the branch creates that the base has never seen. One of these and
    /// the branch is certainly not spent, whatever the line counts say — this
    /// is the guard that keeps a measurement from deleting somebody's work.
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

    /// At most one added line in ten may still be missing from the base. Stated
    /// here rather than buried in an `if`, because it is the one number in this
    /// file that is a judgement: patch-ids and file lists are exact, and how
    /// much drift still counts as "the same work" is not.
    ///
    /// The two branches this was built against sit at 93% and 13%, which is the
    /// margin the bar has to fall inside. It is deliberately not 100%: the base
    /// has usually gone on editing the very lines it took, so a re-applied
    /// branch is never a subset of it.
    public static let carriedOver = 0.9

    /// The whole point of the type, in one expression.
    public var spent: Bool {
        // Nothing on the branch at all is not "spent", it is "empty" — and
        // `merge-base --is-ancestor` has already answered that case.
        guard commits > 0 else { return false }
        // It still brings a file the base has never seen. Not spent, and no
        // amount of line-counting may say otherwise.
        guard newFiles == 0 else { return false }
        if commitsUpstream == commits { return true }
        guard added > 0 else { return false }
        return Double(addedUpstream) >= Double(added) * Staleness.carriedOver
    }

    /// Why, in the words the row and the CLI both print. Never a bare verdict:
    /// `obsolete` is a claim about somebody's work and it has to show its
    /// working.
    public var reason: String {
        if commits > 0, commitsUpstream == commits {
            return commits == 1
                ? "its commit is already on the base"
                : "all \(commits) commits are already on the base"
        }
        return "\(addedUpstream) of \(added) lines are already on the base"
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
            // Exit 128 and friends: not a repo, unknown revision, a git that
            // has never heard of --write-tree. Not an answer.
            verdict = MergeVerdict(base: base, branch: branch,
                                   baseSha: baseSha, branchSha: branchSha,
                                   clean: false, checkedAt: now,
                                   error: MergeChecks.reason(result.output))
        }
        // Asked for every verdict, not only the conflicting ones: a spent branch
        // can merge cleanly too, and offering `merge` on one produces an empty
        // commit and a row that then claims a fix landed.
        if verdict.error == nil {
            verdict.staleness = MergeChecks.staleness(git, base: baseSha, branch: branchSha)
        }
        store(key, verdict)
        return verdict
    }

    /// Has the base already got what this branch is carrying?
    ///
    /// Two reads, both cheap enough to do once per pair of commits: `git cherry`
    /// for the patch-id answer, and the branch's own additions against the
    /// base's copy of each file for the re-implemented one. See `Staleness`.
    static func staleness(_ git: Git, base: String, branch: String) -> Staleness {
        var out = Staleness()

        // `git cherry <upstream> <head>`: one line per commit, `-` when git
        // found the same patch upstream, `+` when it did not.
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

        // Files, with their status, so a branch that introduces something the
        // base has never seen is caught before any line is counted.
        let named = git.run(["diff", "--name-status", "--diff-filter=AMR",
                             forkPoint, branch], timeout: 60)
        guard named.ok else { return out }

        for line in named.output.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count >= 2 else { continue }
            // A rename reports old and new; the branch's version is the last.
            let path = fields[fields.count - 1]
            let onBase = git.run(["show", "\(base):\(path)"], timeout: 30)
            guard onBase.ok else { out.newFiles += 1; continue }

            var present: Set<String> = []
            for baseLine in onBase.output.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = baseLine.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { present.insert(trimmed) }
            }

            // `-U0`: the added lines and nothing else. Context would count lines
            // the branch never wrote as lines it contributed.
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
