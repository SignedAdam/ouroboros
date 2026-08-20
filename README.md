```
  █▀█ █ █ █▀▄ █▀█ ██▄ █▀█ █▀▄ █▀█ ▄▀▀
  █ █ █ █ ██▀ █ █ █▄█ █ █ ██▀ █ █ ▀▀▄
  ▀▀▀ ▀▀▀ ▀ ▀ ▀▀▀ ▀▀▀ ▀▀▀ ▀ ▀ ▀▀▀ ▀▀
```

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)
![Swift 6.0](https://img.shields.io/badge/swift-6.0-orange.svg)

<p align="center">
  <img src="docs/capture-panel.png" alt="The Ouroboros Zero capture panel: a &quot;what's wrong?&quot; field above a list of projects, each row showing what it is carrying and how long ago" width="720">
</p>

Ouroboros is an issue tracker and dispatch system for local coding agents. It writes
issues to markdown files in your repository, hands them to Claude Code or Codex in
isolated git worktrees, and merges the result only if your verify command passes.

It exists in two forms that share the same engine: an embeddable Swift package for
one app, and a system-wide macOS app called Ouroboros Zero.

## Quickstart: Ouroboros Zero

Requirements: macOS 14+, git, an agent CLI (`claude` or `codex`), and Ghostty with a
Terminal.app fallback. `gh` only if you want pull requests.

```bash
git clone https://github.com/SignedAdam/ouroboros.git
cd ouroboros/zero
make install
```

That puts `ouro` and `ourod` in `~/.local/bin` and builds `Ouroboros Zero.app`. Then:

```bash
ouro setup ~/dev                                  # find and register your repos
ouro projects set <project> --verify "swift test" # the command that decides a fix is real
ouro i "the login button does nothing" --fix      # file it and put an agent on it
```

Press **⌥Space** anywhere to open the capture panel. Type the problem, pick the
project, `⏎` files it, `⌘⏎` files it and dispatches an agent.

## Quickstart: the Swift package

The package lives in [`swift/`](swift/), so it is vendored rather than fetched by URL.
Copy or submodule it into your app, then:

```swift
dependencies: [
    .package(path: "Packages/Ouroboros"),
]
```

Add `Ouroboros` for the engine, which has no UI dependencies. Add `OuroborosUI` as
well if you want the ready-made floating button and composer instead of building
your own. [`swift/INTEGRATION.md`](swift/INTEGRATION.md) is the wiring guide.

Or hand the whole job to an agent:

```text
Add Ouroboros to this app.
Clone https://github.com/SignedAdam/ouroboros (or use an existing checkout),
read skills/ouroboros-integrate/SKILL.md from that repo, and follow it exactly.
$OURO = the checkout path.
```

## How a run works

The agent never merges its own work.

```
  issue written to .issues/new/<Title>.md
            │
            ▼
  git worktree cut on fix/<slug> off main
            │
            ▼
  agent runs in its own terminal window
            │
            ▼
  agent commits to its branch and stops
            │
            ▼
  Ouroboros runs your verify command on that branch
            │
      ┌─────┴─────┐
      ▼           ▼
   passes       fails
      │           │
  merge and   keep the branch,
  resolve     land it in your
  the issue   inbox with the reason
```

The markdown file in `.issues/` is the source of truth, and it is committed, so the
state of the work travels with the repository rather than living in a database.

That gate is exactly as good as the verify command you set, and nothing more. It is
not a judgement about whether the fix is any good.

For a project that has a screen, an agent can also be given a small toolbelt
(screenshot, list windows, press key) so it can open the app and look rather than
trust the diff. Off by default, per project, since most projects have nothing to
drive.

## Architecture

Ouroboros Zero is a local HTTP API with a daemon in front of it. Four faces, one API:

| | |
|---|---|
| `ourod` | the daemon: registry, run supervisor, scheduler, gate, event bus |
| `ouro` | the CLI |
| Ouroboros Zero.app | menu-bar item and the ⌥Space capture panel |
| the API itself | for AI operators, see [`zero/OPERATOR.md`](zero/OPERATOR.md) |

The GUI has no private powers. Every button is an HTTP call an agent could make.

## Language support

[`swift/`](swift/) and [`zero/`](zero/) are fully implemented and used in production.

Reference ports for [`python/`](python/), [`go/`](go/), [`nextjs/`](nextjs/) and
[`react/`](react/) are not written yet. Those folders are placeholders.

You can still use Ouroboros in those stacks today. Point your coding agent at
[`skills/ouroboros-integrate/SKILL.md`](skills/ouroboros-integrate/SKILL.md) and it
will generate the pattern directly inside your target project.

If you want a canonical port in this repo:

- **Ask for one.** Open an issue with your stack. I will write the port for you.
- **Contribute one.** PRs are welcome. Keep it minimal and match the Swift implementation.

## Documentation

[`zero/README.md`](zero/README.md) is the full reference: every command, the inbox
states, configuration, conflict resolution, autonomy levels.

- [`skills/ouroboros-integrate/SKILL.md`](skills/ouroboros-integrate/SKILL.md): how an agent installs this into any app
- [`swift/INTEGRATION.md`](swift/INTEGRATION.md): wiring the package by hand
- [`zero/OPERATOR.md`](zero/OPERATOR.md): the HTTP API
- [`brand/`](brand/): the mark

## License

MIT, see [LICENSE](LICENSE). Use it in anything, commercial work included.

If Ouroboros ends up in something you ship, a link back is appreciated and never
required. The mark is yours to display too, if you want to show what is under the
floating button.

Built by Adam Albastov.
