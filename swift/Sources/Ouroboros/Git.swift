import Foundation

public struct GitRunner: Sendable {
    public let run: @Sendable (_ args: [String], _ cwd: String?) -> (status: Int32, output: String)
    public init(run: @escaping @Sendable (_ args: [String], _ cwd: String?) -> (status: Int32, output: String)) {
        self.run = run
    }
    public static let live = GitRunner { args, cwd in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

public struct Worktree: Sendable, Equatable {
    public let path: String
    public let branch: String
}

public struct WorktreeManager: Sendable {
    let runner: GitRunner
    public init(runner: GitRunner = .live) { self.runner = runner }

    /// Creates a worktree at <repo>/<worktreeRoot>/<slug> on a new branch <prefix><slug>
    /// off `base`. Dedups branch+path with -2, -3 suffixes when the branch exists.
    public func create(repo: String, base: String, slug: String,
                       worktreeRoot: String = ".ouroboros/worktrees",
                       branchPrefix: String = "fix/") -> Worktree? {
        let baseDir = ((repo as NSString).appendingPathComponent(worktreeRoot))
        for attempt in 0..<50 {
            let suffix = attempt == 0 ? "" : "-\(attempt + 1)"
            let branch = "\(branchPrefix)\(slug)\(suffix)"
            let path = (baseDir as NSString).appendingPathComponent("\(slug)\(suffix)")
            if FileManager.default.fileExists(atPath: path) { continue }
            let result = runner.run(["worktree", "add", "-b", branch, path, base], repo)
            if result.status == 0 { return Worktree(path: path, branch: branch) }
            // Only retry with the next suffix when the branch already exists; bail otherwise.
            if !result.output.lowercased().contains("already exists") { return nil }
        }
        return nil
    }
}
