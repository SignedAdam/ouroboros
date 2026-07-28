import Foundation
import ZeroCore

/// `ouro run-shim <run-id> --home <home> -- <agent argv…>`
///
/// The thin wrapper that turns "we launched a terminal and hoped" into a
/// supervised run. It lives *inside* the agent's terminal window, so it is the
/// only thing that can truthfully say when the agent started, when it exited,
/// and with what code.
///
/// Two rules it must never break:
///   1. The agent keeps a real interactive TTY. You watch these windows and
///      sometimes types into them; a shim that swallowed the terminal would
///      destroy the best part of the product. `script(1)` gives us a tee
///      without taking the pty away.
///   2. It reports even when the daemon is down — `shim.json` on disk is the
///      fallback the daemon reconciles at startup.
enum Shim {

    static func run(_ args: Args) -> Never {
        guard let runId = args.positional.first else {
            Out.die("usage: ouro run-shim <run-id> --home <dir> -- <command…>")
        }
        let home = args.flag("home") ?? Paths.home
        let agentArgv = args.rest
        guard !agentArgv.isEmpty else { Out.die("run-shim: nothing to run after --") }

        let runDir = ((home as NSString).appendingPathComponent("runs") as NSString)
            .appendingPathComponent(runId)
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        let logPath = (runDir as NSString).appendingPathComponent("log")
        let shimPath = (runDir as NSString).appendingPathComponent("shim.json")
        setenv("OUROBOROS_HOME", home, 1)
        let client = ZeroClient(socketPath: Paths.socket)

        let selfPid = ProcessInfo.processInfo.processIdentifier
        report(client, runId, "started", ShimReport(phase: "started", pid: selfPid), to: shimPath)

        // No pty, ever. The obvious design was `script(1)` — it hands the agent a
        // real terminal and tees to a log, so you get both. In practice it gives
        // you neither: it dies with "tcgetattr: Operation not supported on
        // socket" whenever stdin isn't a terminal, and when it *does* get one,
        // harnesses in print mode (`claude -p`) sit forever waiting on a stdin
        // that will never produce anything. Runs hung at 0 bytes of output.
        //
        // So the shim owns the plumbing itself: the agent gets /dev/null on
        // stdin and a pipe on stdout, and we tee that pipe to the terminal AND
        // the log. Live output in the window, a complete log on disk, identical
        // behaviour in cinema / tmux / silent mode, and nothing to hang on.
        //
        // A supervised run is unattended by definition anyway. You watch these
        // windows; you don't type into them. When an agent genuinely needs a
        // human it writes `needs-input`, and the answer comes back through
        // `ouro reply` — a channel that outlives the window.
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)
        let pipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: agentArgv[0])
        process.arguments = Array(agentArgv.dropFirst())
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        if !agentArgv[0].hasPrefix("/") {
            // Resolve through a login shell: a Finder-launched daemon hands us
            // a bare `claude` with no Homebrew PATH behind it.
            if let resolved = Shell.which(agentArgv[0]) {
                process.executableURL = URL(fileURLWithPath: resolved)
            }
        }

        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                FileHandle.standardOutput.write(chunk)
                logHandle?.write(chunk)
            }
            drained.signal()
        }
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var env = ProcessInfo.processInfo.environment
        env["OUROBOROS_HOME"] = home
        env["OUROBOROS_RUN_ID"] = runId
        env["OUROBOROS_RESULT_FILE"] = (runDir as NSString).appendingPathComponent("result.json")
        // The toolbelt goes on PATH ahead of everything else, and its spec goes in
        // an env var, so an agent can verify a UI change by looking at the UI
        // instead of inferring it from a diff.
        let tools = (home as NSString).appendingPathComponent("tools")
        if FileManager.default.fileExists(atPath: tools) {
            env["PATH"] = tools + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            env["OUROBOROS_TOOLS"] = tools
        }
        process.environment = env

        var forwarded: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { if process.isRunning { process.terminate() } }
            source.resume()
            forwarded.append(source)
        }

        do {
            try process.run()
        } catch {
            report(client, runId, "exited", ShimReport(phase: "exited", exitCode: 127), to: shimPath)
            Out.die("run-shim: could not start \(agentArgv[0]): \(error)")
        }

        process.waitUntilExit()
        _ = drained.wait(timeout: .now() + 5)   // don't lose the agent's last lines
        try? logHandle?.close()
        let code = process.terminationStatus
        report(client, runId, "exited", ShimReport(phase: "exited", pid: selfPid, exitCode: code),
               to: shimPath)

        outro(runDir: runDir, exitCode: code)
        exit(code)
    }

    private static func report(_ client: ZeroClient, _ runId: String, _ phase: String,
                               _ payload: ShimReport, to path: String) {
        Zero.writeJSON(payload, to: path)   // always, first — the daemon may be down
        let route = "/v1/runs/\(runId)/shim/\(phase)"
        if phase == "started" {
            _ = try? client.post(route, API.ShimStarted(pid: payload.pid ?? 0),
                                 as: API.Message.self)
        } else {
            _ = try? client.post(route, API.ShimExited(exitCode: payload.exitCode ?? 0),
                                 as: API.Message.self)
        }
    }

    /// A closing beat in the cinema window. The window dies with this process,
    /// so without a pause the run just vanishes and you learn nothing.
    private static func outro(runDir: String, exitCode: Int32) {
        let resultPath = (runDir as NSString).appendingPathComponent("result.json")
        let result = Zero.readJSON(AgentResult.self, from: resultPath)
        print("")
        switch result?.outcome {
        case "done":
            print("  " + Ansi.green("✓ agent finished") + Ansi.dim(" — ouroboros is verifying the branch"))
            if let summary = result?.summary { print("  " + Ansi.dim(Fmt.truncate(summary, 90))) }
        case "needs-input", "blocked":
            print("  " + Ansi.yellow("? the agent needs a decision"))
            if let question = result?.question { print("  " + Ansi.dim(Fmt.truncate(question, 90))) }
            print("  " + Ansi.dim("it's in your inbox: ouro inbox"))
        default:
            if exitCode == 0 {
                print("  " + Ansi.dim("agent exited without writing a result — ouroboros will check the branch"))
            } else {
                print("  " + Ansi.red("✗ agent exited \(exitCode)"))
            }
        }
        print("")
        Thread.sleep(forTimeInterval: 2.5)
    }
}
