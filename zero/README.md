# Ouroboros Zero

The global control plane. Ouroboros (the package next door) puts a report-issue button
*inside one app*. Zero puts it **everywhere**, supervises the agents it dispatches, and
refuses to let unverified work land.

```
◍ filed  receipts · the receipt total is wrong
  → claude dispatched  r-ms44fbsz-fam3
```

One core, four faces — all of them clients of the same local API:

| | |
|---|---|
| **`ourod`** | the daemon: registry, run supervisor, scheduler, gate, event bus |
| **`ouro`** | the CLI |
| **Ouroboros Zero.app** | menu-bar item + ⌥Space capture panel |
| *(the API itself)* | for AI operators — see [OPERATOR.md](OPERATOR.md) |

The GUI has **no private powers**: every button is an HTTP call an agent could make.

## Install

```bash
make install          # ouro + ourod → ~/.local/bin, and builds the .app
open "build/Ouroboros Zero.app"
```

Then:

```bash
ouro projects discover ~/dev            # register every repo under a root
ouro projects set <id> --verify "swift build"
ouro i "the login button does nothing" --fix
```

Requirements: `git`, an agent CLI (`claude` / `codex`), Ghostty (Terminal.app fallback),
`gh` only for PR finishes.

## The loop

```
ouro i "…" --fix
   ↓  issue written to <repo>/.issues/new/<Title>.md      ← the truth is a file
   ↓  run queued, scheduler grants a slot
   ↓  git worktree on fix/<slug> off main
   ↓  agent runs in its own terminal, wrapped by `ouro run-shim`
   ↓  agent commits on its branch and writes result.json — and STOPS
   ↓  Ouroboros runs the project's verify command ON THAT BRANCH
   ↓  green → merge, resolve the issue, remove the worktree
      red   → keep the branch, put it in your inbox with the reason
```

**The agent never lands its own work.** That single rule is what buys you the
verification gate, a reviewable branch for every fix, and one-command undo.

## The inbox

Five kinds of item, and nothing else — decisions only, never status:

| | |
|---|---|
| `needs you` | an agent stopped and asked a question → `ouro reply <run> "…"` |
| `failed` | the run or the gate went red → `ouro log` / `ouro retry` |
| `ready` | verified, waiting for permission to merge → `ouro merge <run>` |
| `landed` | merged or PR open → `ouro diff` / `ouro undo` |
| `proposal` | an AI operator suggested work → `ouro accept` / `ouro dismiss` |

If it doesn't need a human, it isn't in there. There are no unread badges.

## Commands

```
ouro setup [~/dev]                     find your repos and register them
ouro                                   what needs you, what's in flight
ouro i "…" [--fix] [-p proj] [--pr]    file an issue where you're standing
ouro fix [issue-id]                    dispatch (newest open issue if omitted)
ouro done <issue-id>                   confirm one is finished; clears its run
ouro runs -w                           live table of every agent
ouro log <run> -f  ·  ouro diff <run>
ouro reply <run> "…" [-a codex]        answer a question, optionally switch harness
ouro merge <run>  ·  ouro undo <run>  ·  ouro stop <run>  ·  ouro retry <run>
ouro inbox
ouro idea "…"  ·  ouro ideas  ·  ouro promote <id> -p proj [--fix]
ouro projects [add . | discover ~/dev | set <id> --verify "…" --autonomy auto]
ouro rename <project> <new-name>       call it something else
ouro new <name> --desc "…" --github private --roadmap ai
ouro daemon status|start|stop|restart|log
ouro update                            pull, rebuild, restart
```

`ouro i` infers the project from your cwd — walking up to the git root — and registers
an unknown repo on the spot. It should work the first time you type it in a new project.

## The capture panel

⌥Space from anywhere opens one field on the screen the mouse is on. ⏎ files what you
typed, ⌘⏎ files it and dispatches an agent, `esc` closes it.

The combo is `hotkey` in `~/.ouroboros/config.json` — default `opt+space`, and it has to
carry at least one modifier. macOS gives no way to ask whether another app already owns a
combo; registration just fails. So the app tries the configured one, then `opt+space`,
`cmd+shift+space`, `opt+cmd+space`, `opt+cmd+i`, and prints the one it actually got in
the panel's footer. `/hotkey cmd+shift+space` writes a new combo; it takes effect the
next time the app launches. If none of them register, the menu-bar item still works.

Typing `/` turns the field into a command line: ⇥ completes, ↑↓ pick, ⏎ runs.

| command | argument | what it does |
|---|---|---|
| `/add` | `[path]` | adopt a directory that already exists |
| `/new` | `<name> [description]` | scaffold one that doesn't exist yet |
| `/project` | `<name>` | capture into this project |
| `/open` | `[project]` | reveal the directory in Finder |
| `/fix` | `[issue-id]` | put an agent on an issue, newest open one if omitted |
| `/idea` | `<text>` | park it — no issue, no run |
| `/promote` | `[idea-id]` | turn a parked idea into an issue |
| `/task` | `<prompt>` | dispatch an agent on a one-off prompt |
| `/issues` | `[project]` | what's open |
| `/inbox` | | what needs you |
| `/runs` | | what's in flight |
| `/reply` | `[run] <answer>` | answer an agent's question |
| `/merge` | `[run]` | land a verified run |
| `/retry` | `[run]` | dispatch it again |
| `/undo` | `[run]` | revert a merged run |
| `/stop` | `[run]` | abandon a run mid-flight |
| `/rename` | `<old> <new>` | rename a registered project |
| `/verify` | `<cmd>` | the command that decides a fix is real |
| `/autonomy` | `<manual\|assist\|auto>` | how far agents may go alone |
| `/agent` | `<name>` | which harness this project uses |
| `/finish` | `<merge\|pr\|leave>` | what happens when a fix passes |
| `/discover` | `<root>` | register every repo under a root |
| `/forget` | `<project>` | unregister it — the files stay |
| `/setup` | `[roots]` | find and adopt your projects |
| `/update` | | pull and rebuild ouroboros itself |
| `/hotkey` | `<combo>` | the global capture shortcut |
| `/health` | | daemon, projects, runs, inbox |
| `/help` | | every command |
| `/quit` | | quit Ouroboros Zero |

Aliases resolve too — `/p`, `/ps`, `/land`, `/note`, `/?` and a few more; type `/` to see
them. `/add` and `/new` with no argument open a sheet instead. `/verify`, `/autonomy`,
`/agent` and `/finish` apply to the project in the footer picker and print its current
value when given no argument. `/reply`, `/merge`, `/retry` and `/undo` with no run id act
on the newest inbox item of that kind — `/merge` alone merges the one that is waiting —
and `/stop` alone takes the run in flight.

Text that doesn't resolve to a command is filed as an ordinary issue — `/tmp is full` is
a bug report, not a typo.

`/update`, like `ouro update`, runs `git pull --ff-only` in the checkout named by
`repoPath` in config.json (the registered project called `ouroboros` when that is unset),
then `make install` there, then restarts the daemon if the commit moved. A dirty tree or
a diverged branch stops it before anything is built.

## Autonomy

Per project, `manual` (default) → `assist` → `auto`. It sets the **default finish** for
issues dispatched without an explicit choice; an explicit `--merge` is always honoured.

```bash
ouro projects set atlas --autonomy auto --verify "swift build"
```

Auto-merge additionally requires the repo to be on its base branch with no uncommitted
changes to **tracked** files. Untracked junk (`__pycache__`, scratch files) does not
block it — git guards that case itself.

`protectedPaths` (migrations, deploy config) are stated in the seed prompt *and*
enforced against the branch diff afterwards.

## Configuration — `~/.ouroboros/config.json`

```jsonc
{
  "maxParallel": 3,                 // agents in flight across all projects
  "terminal": "cinema",             // cinema | tmux | silent | terminal
  "defaultAgent": "claude",
  "hotkey": "opt+space",            // capture combo; needs a modifier
  "repoPath": "~/dev/ouroboros",    // the checkout `ouro update` rebuilds from
  "discordWebhook": "https://…",    // inbox items ping here
  "notifyOn": ["question", "failed", "landed", "ready"],
  "agents": {
    "claude": ["claude", "{prompt}"]
  }
}
```

**Unattended runs.** The defaults use each harness's plain CLI, with its own settings and
its own permission prompts — Zero does not decide how much rope your agent gets. For
overnight work you'll want your harness's non-interactive / auto-approve flag; that is a
deliberate per-machine choice, so put it in `agents` yourself. Isolation comes from the
worktree and the gate, not from the flag.

## On-disk layout

```
~/.ouroboros/
  config.json  projects.json  ourod.sock  ourod.log
  runs/<id>/{run.json, log, result.json, prompt.txt}
  ideas/{new,done}/*.md

<repo>/.issues/{new,planned,done,cancelled}/*.md     ← committed; the real state
<repo>/.ouroboros/worktrees/<slug>                   ← gitignore this
```

Delete `~/.ouroboros` and you lose run history — never an issue. The markdown is the
truth; everything else is a cache.

## Gotchas

- **Don't start `ourod` from inside an agent session** that exports `ANTHROPIC_API_KEY` —
  every agent it spawns inherits it. Launching the app from Finder gives a clean
  environment. (`ouro daemon status` tells you what's running.)
- A long `OUROBOROS_HOME` falls back to a short `/tmp` socket path — `sockaddr_un` only
  holds 104 bytes.
- `ouro` and `ourod` must live in the **same directory**: the daemon finds the shim as
  its sibling, which is what makes runs work when launched from Finder with no PATH.

## Development

```bash
swift test        # 42 tests
make build        # release binaries
make app          # the .app bundle
```
