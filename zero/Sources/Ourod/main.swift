import Foundation
import ZeroCore

signal(SIGPIPE, SIG_IGN)

Paths.ensure()

if let pidText = try? String(contentsOfFile: Paths.pidFile, encoding: .utf8),
   let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
   pid > 0, kill(pid, 0) == 0, pid != ProcessInfo.processInfo.processIdentifier {
    FileHandle.standardError.write(Data("ourod is already running (pid \(pid))\n".utf8))
    exit(1)
}

let daemon = Daemon()

do {
    try daemon.start()
} catch {
    FileHandle.standardError.write(Data("ourod failed to start: \(error)\n".utf8))
    exit(1)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        daemon.log("shutting down")
        daemon.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

RunLoop.main.run()
