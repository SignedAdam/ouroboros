import Foundation
import ZeroCore

signal(SIGPIPE, SIG_IGN)

let argv = Array(CommandLine.arguments.dropFirst())
let args = Args.parse(argv)

if let home = args.flag("home") {
    Zero0.homeOverride = home
    setenv("OUROBOROS_HOME", home, 1)
}

func help() {
    Out.banner()
    let lines = [
        ("start here", ""),
        ("  ouro setup [~/dev]", "find your repos and register them"),
        ("", ""),
        ("capture", ""),
        ("  ouro i \"the login button does nothing\"", "file an issue where you're standing"),
        ("  ouro i \"…\" --fix", "file it and put an agent on it now"),
        ("  ouro idea \"a webhook replay tool\"", "park a thought (pings Discord)"),
        ("", ""),
        ("work", ""),
        ("  ouro", "what needs you, what's in flight"),
        ("  ouro inbox", "the needs-you queue"),
        ("  ouro fix [issue-id]", "dispatch an agent (newest issue if omitted)"),
        ("  ouro done <issue-id>", "confirm one is finished"),
        ("  ouro runs -w", "live table of every agent"),
        ("  ouro log <run> -f", "follow one agent's output"),
        ("  ouro diff <run>", "what it changed"),
        ("  ouro reply <run> \"use the second approach\"", "answer an agent's question"),
        ("  ouro merge <run> / undo <run>", "land it / take it back"),
        ("  ouro rebase <run>", "put its branch back on top of its base"),
        ("  ouro rm <issue-id>", "delete an issue — it goes"),
        ("  ouro stop <run> / retry <run> / ok <run>", ""),
        ("  ouro show <run>", "everything about one run, conversation id included"),
        ("  ouro resume <run>", "reopen that agent's conversation"),
        ("  ouro agents", "which harnesses this machine can dispatch to"),
        ("", ""),
        ("projects", ""),
        ("  ouro projects", "list"),
        ("  ouro projects add .", "register the repo you're in"),
        ("  ouro projects discover ~/dev", "register every repo under a root"),
        ("  ouro projects set <id> --verify \"swift build\" --autonomy auto", ""),
        ("  ouro projects favourite|hide <id>", "pin it / drop it from the panel"),
        ("  ouro projects agent <id> codex", "which harness this project uses"),
        ("  ouro rename <project> <new-name>", "call it something else"),
        ("  ouro new <name> --desc \"…\" --github private --roadmap ai", "start something"),
        ("", ""),
        ("ideas & proposals", ""),
        ("  ouro ideas / ouro promote <id> -p <project> [--fix]", ""),
        ("  ouro ideas drop <id>", "let one go"),
        ("  ouro accept <proposal> / ouro dismiss <proposal>", "AI-filed suggestions"),
        ("", ""),
        ("daemon", ""),
        ("  ouro daemon status|start|stop|restart|log", ""),
        ("  ouro update", "pull, rebuild, restart"),
        ("  ouro hotkey [combo]", "the global capture shortcut"),
    ]
    for (left, right) in lines {
        if left.isEmpty && right.isEmpty { print(""); continue }
        if right.isEmpty && !left.hasPrefix("  ") {
            print("  " + Ansi.bold(left)); continue
        }
        print(Ansi.pad(left, 48) + Ansi.dim(right))
    }
    print("")
    print("  " + Ansi.dim("flags: -p <project>  -t <title>  -a <agent>  --pr  --leave  --no-worktree"))
    print("")
}

switch args.command {
case "":
    if args.bool("help", "h") { help() } else if args.bool("version", "v") {
        print("ouroboros zero \(ZeroVersion.current)")
    } else {
        Commands.overview(args)
    }

case "setup", "init":                 Commands.setup(args)
case "i", "issue", "file":            Commands.issue(args)
case "issues", "ls":                  Commands.issues(args)
case "fix":                           Commands.fix(args)
case "done", "resolve":               Commands.done(args)
case "runs", "ps":                    Commands.runs(args)
case "log", "logs":                   Commands.log(args)
case "diff":                          Commands.diff(args)
case "merge-check", "mergecheck":     Commands.mergeCheck(args)
case "rm", "delete":                  Commands.deleteIssue(args)
case "reply", "stop", "merge", "undo", "retry", "rebase", "ok", "drop", "ack":
                                      Commands.runAction(args.command, args)
case "resume":                        Commands.resume(args)
case "show":                          Commands.show(args)
case "agents":                        Commands.agents(args)
case "inbox":                         Commands.inbox(args)
case "idea":                          Commands.idea(args)
case "ideas":                         Commands.ideas(args)
case "promote":                       Commands.promote(args)
case "accept", "dismiss":             Commands.proposalAction(args.command, args)
case "projects", "project", "p":      Commands.projects(args)
case "rename", "mv":                  Commands.rename(args)
case "new":                           Commands.newProject(args)
case "daemon", "d":                   Commands.daemon(args)
case "update", "upgrade":             Commands.update(args)
case "hotkey":                        Commands.hotkey(args)
case "run-shim":                      Shim.run(args)
case "version":                       print("ouroboros zero \(ZeroVersion.current)")
case "help":                          help()

default:
    Out.err("unknown command '\(args.command)'")
    help()
    exit(1)
}
