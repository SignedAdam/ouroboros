import Foundation

public final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var projects: [Project]
    private let file: String

    public init(file: String = Paths.registryFile) {
        self.file = file
        self.projects = Zero.readJSON([Project].self, from: file) ?? []
    }

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

            projects[idx].hidden = false
        }
        let snapshot = projects
        lock.unlock()
        Zero.writeJSON(snapshot, to: file)
    }

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

        return upsert(project)
    }

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

    public func recentlyUsed(limit: Int = 5) -> [Project] {
        Array(all().filter { $0.lastUsed != nil }.prefix(limit))
    }

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
