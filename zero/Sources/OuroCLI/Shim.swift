import Foundation
import ZeroCore

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
        Shim.scrubInheritedSession(&env)
        env["OUROBOROS_HOME"] = home
        env["OUROBOROS_RUN_ID"] = runId
        env["OUROBOROS_RESULT_FILE"] = (runDir as NSString).appendingPathComponent("result.json")

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
        _ = drained.wait(timeout: .now() + 5)
        try? logHandle?.close()
        let code = process.terminationStatus
        report(client, runId, "exited", ShimReport(phase: "exited", pid: selfPid, exitCode: code),
               to: shimPath)

        outro(runDir: runDir, exitCode: code)
        exit(code)
    }

    static func scrubInheritedSession(_ env: inout [String: String]) {
        let insideAgentSession = env["CLAUDECODE"] != nil
            || env["CLAUDE_CODE_SESSION_ID"] != nil
            || env["CLAUDE_CODE_ENTRYPOINT"] != nil

        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_JOB") {
            env.removeValue(forKey: key)
        }
        for key in ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"] {
            env.removeValue(forKey: key)
        }
        guard insideAgentSession else { return }
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                    "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL"] {
            env.removeValue(forKey: key)
        }
    }

    private static func report(_ client: ZeroClient, _ runId: String, _ phase: String,
                               _ payload: ShimReport, to path: String) {
        Zero.writeJSON(payload, to: path)
        let route = "/v1/runs/\(runId)/shim/\(phase)"
        if phase == "started" {
            _ = try? client.post(route, API.ShimStarted(pid: payload.pid ?? 0),
                                 as: API.Message.self)
        } else {
            _ = try? client.post(route, API.ShimExited(exitCode: payload.exitCode ?? 0),
                                 as: API.Message.self)
        }
    }

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
