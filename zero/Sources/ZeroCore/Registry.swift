import Foundation

/// The project registry. `projects.json` is a *cache of intent* — which
/// directories the operator considers projects — not a source of truth about their
/// contents. Issues always come from the repos themselves.
public final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var projects: [Project]
    private let file: String

    public init(file: String = Paths.registryFile) {
        self.file = file
        self.projects = Zero.readJSON([Project].self, from: file) ?? []
    }

    /// Projects you have actually used come first, most recent first; everything
    /// else follows alphabetically.
    ///
    /// The subtlety is that `ouro setup` registers every repo under `~/dev` in
    /// one go. If registration counted as use, all 57 would sort by the
    /// microsecond they happened to be written, and the capture panel would
    /// default to whichever one won that race. It picked `zzworld`.
    public func all() -> [Project] {
        lock.lock(); defer { lock.unlock() }
        return projects.sorted { a, b in
            switch (a.lastUsed, b.lastUsed) {
            case let (x?, y?):
                return x != y ? x > y : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    public func find(_ idOrName: String) -> Project? {
        lock.lock(); defer { lock.unlock() }
        let needle = idOrName.lowercased()
        if let exact = projects.first(where: { $0.id.lowercased() == needle }) { return exact }
        if let byName = projects.first(where: { $0.name.lowercased() == needle }) { return byName }
        // Unambiguous prefix — `ouro i -p monda` should work.
        let matches = projects.filter {
            $0.id.lowercased().hasPrefix(needle) || $0.name.lowercased().hasPrefix(needle)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public func byPath(_ path: String) -> Project? {
        let normalized = Registry.normalize(path)
        lock.lock(); defer { lock.unlock() }
        return projects.first { Registry.normalize($0.path) == normalized }
    }

    /// The project that *contains* this path — how `ouro i` figures out where
    /// you are without being told.
    public func containing(_ path: String) -> Project? {
        let normalized = Registry.normalize(path)
        lock.lock()
        let candidates = projects
        lock.unlock()
        var best: Project?
        for p in candidates {
            let root = Registry.normalize(p.path)
            if normalized == root || normalized.hasPrefix(root + "/") {
                if best == nil || root.count > Registry.normalize(best!.path).count { best = p }
            }
        }
        return best
    }

    @discardableResult
    public func upsert(_ project: Project) -> Project {
        lock.lock()
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        } else {
            projects.append(project)
        }
        let snapshot = projects
        lock.unlock()
        Zero.writeJSON(snapshot, to: file)
        return project
    }

    @discardableResult
    public func remove(_ id: String) -> Bool {
        lock.lock()
        let before = projects.count
        projects.removeAll { $0.id == id }
        let snapshot = projects
        let changed = projects.count != before
        lock.unlock()
        if changed { Zero.writeJSON(snapshot, to: file) }
        return changed
    }

    public func touch(_ id: String) {
        lock.lock()
        if let idx = projects.firstIndex(where: { $0.id == id }) {
            projects[idx].lastUsed = Date()
        }
        let snapshot = projects
        lock.unlock()
        Zero.writeJSON(snapshot, to: file)
    }

    /// Register a directory. Fills in name, base branch and a guessed verify
    /// command so a freshly-added project is immediately usable.
    @discardableResult
    public func register(path rawPath: String, name: String? = nil,
                         policy: Policy? = nil) -> Project? {
        let path = Registry.normalize(rawPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        if let existing = byPath(path) { return existing }

        let display = name ?? (path as NSString).lastPathComponent
        let git = Git(path)
        let base = git.isRepo ? git.defaultBranch : nil
        var project = Project(
            id: Registry.slug(display, taken: all().map(\.id)),
            name: display,
            path: path,
            baseBranch: base,
            verifyCmd: Registry.guessVerifyCommand(path),
            roadmapPath: Registry.findRoadmap(path),
            policy: policy ?? Policy()
        )
        // Deliberately no `lastUsed`: adopting a directory is not using it.
        // `touch()` sets it when you actually file something.
        return upsert(project)
    }

    // MARK: - recency

    /// When this repo last saw git activity.
    ///
    /// Deliberately a `stat`, not `git log -1`. With ~60 registered projects the
    /// subprocess version costs a second or two and the capture panel has to
    /// open instantly. `.git/logs/HEAD` is touched by every commit, checkout,
    /// merge and rebase, so its mtime is the same signal for one syscall.
    public static func gitActivity(at path: String) -> Date? {
        let fm = FileManager.default
        let git = (path as NSString).appendingPathComponent(".git")
        for candidate in ["logs/HEAD", "HEAD", ""] {
            let full = candidate.isEmpty ? git : (git as NSString).appendingPathComponent(candidate)
            if let date = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date {
                return date
            }
        }
        return nil
    }

    /// Projects you have actually pointed Ouroboros at, most recent first.
    public func recentlyUsed(limit: Int = 5) -> [Project] {
        Array(all().filter { $0.lastUsed != nil }.prefix(limit))
    }

    /// Projects you have been *working in*, whether or not Ouroboros knows about
    /// it yet. This is the half that makes the panel feel like it is paying
    /// attention: the repo you committed to an hour ago is right there.
    public func recentlyTouchedByGit(limit: Int = 5, excluding: Set<String> = []) -> [Project] {
        all()
            .filter { !excluding.contains($0.id) }
            .compactMap { project -> (Project, Date)? in
                guard let date = Registry.gitActivity(at: project.path) else { return nil }
                return (project, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Scan a parent directory (e.g. `~/dev`) for git repos, one level deep.
    public static func discover(in parent: String, limit: Int = 400) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: parent) else { return [] }
        var found: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            if found.count >= limit { break }
            let p = (parent as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.fileExists(atPath: (p as NSString).appendingPathComponent(".git")) {
                found.append(p)
            }
        }
        return found
    }

    // MARK: helpers

    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func slug(_ name: String, taken: [String]) -> String {
        var out = ""
        var lastDash = false
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        let base = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let root = base.isEmpty ? "project" : String(base.prefix(40))
        if !taken.contains(root) { return root }
        for i in 2...999 where !taken.contains("\(root)-\(i)") { return "\(root)-\(i)" }
        return root + "-x"
    }

    /// One command that says whether the tree is healthy. Guessed from the
    /// manifest files present; always user-overridable.
    public static func guessVerifyCommand(_ path: String) -> String? {
        let fm = FileManager.default
        func has(_ f: String) -> Bool {
            fm.fileExists(atPath: (path as NSString).appendingPathComponent(f))
        }
        if has("Package.swift") { return "swift build" }
        if has("Cargo.toml") { return "cargo check" }
        if has("go.mod") { return "go build ./..." }
        if has("Makefile") { return "make build" }
        if has("pnpm-lock.yaml") { return "pnpm build" }
        if has("package.json") { return "npm run build --if-present" }
        if has("pyproject.toml") { return "python -m compileall -q ." }
        return nil
    }

    public static func findRoadmap(_ path: String) -> String? {
        let candidates = ["docs/ROADMAP.md", "ROADMAP.md", "docs/roadmap.md"]
        for c in candidates {
            let full = (path as NSString).appendingPathComponent(c)
            if FileManager.default.fileExists(atPath: full) { return full }
        }
        return nil
    }
}
