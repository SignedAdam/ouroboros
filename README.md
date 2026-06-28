# Ouroboros

In-app issue capture → coding agent. A user describes an issue in your app, you save it
as a markdown file, and (optionally) hand it straight to a coding agent (Claude Code,
Codex, …) running in an isolated git worktree in a new terminal tab. It feels magical:
file ten issues, fire ten agents, walk away.

This is the Swift port of the engine that powers the issue-fixer in Vaux. It is a pure,
UI-free package — drop it into any macOS Swift app and build whatever UI you like on top
(or use the included default `OuroborosUI`).

## The engine (pure, no UI deps)

Five small units, all `Sendable`, all shell-outs behind injectable runners (so they test
headlessly and spawn nothing):

| Type | Responsibility |
|---|---|
| `Issue` / `IssueText` | the issue model + `suggestTitle` (local heuristic: first line → 9 words/60 chars), `slugify`, `cleanTitle` |
| `IssueStore` | writes `.issues/new/<Title>.md` as `## Title\n\nbody`, dedups collisions |
| `Agent` / `seedPrompt` | builds the agent argv + the seed prompt (worktree-or-in-place × merge-or-PR); presets `.claudeCode`, `.codex`, `.gemini`, `.pi`, `.custom(…)` |
| `WorktreeManager` | `git worktree add` on a `fix/<slug>` branch off your base, with dedup |
| `TerminalLauncher` | pluggable spawn: `.ghosttyTmuxTab` (new tab in your active tmux session inside Ghostty), `.osDefault` (Terminal.app), `.custom` |
| `Ouroboros` (facade) | `submit(title:body:)` → `handToAgent(_:options:)` |

## Quick start

```swift
import Ouroboros

let ouroboros = Ouroboros(
    projectDir: "/path/to/your/repo",          // where .issues/ lives and the agent runs
    agent: .claudeCode,                         // or .codex
    terminal: TerminalLauncher(kind: .ghosttyTmuxTab),
    baseBranch: "main"                          // fixes merge back / PR into this
)

// 1) Save the issue.
guard let issue = ouroboros.submit(title: "Fix the login button", body: "It does nothing") else { return }

// 2) Optionally hand it to the agent. Per-issue options:
ouroboros.handToAgent(issue, options: FixOptions(worktree: true, finish: .mergeIntoBase))
```

`FixOptions`:
- `worktree: Bool` — run the fix in a fresh isolated worktree (default `true`). Off → work in place on the current branch.
- `finish: .mergeIntoBase | .openPR` — when the agent is done, merge back into `baseBranch`, or open a PR with `gh`.

## Live title suggestion

As the user types the description, suggest a title and let them override it:

```swift
// onChange(of: description):
if !titleEdited { title = IssueText.suggestTitle(description) }
```

## Optional default UI

`OuroborosUI` ships a `MenuBarExtra`-based entry point and a basic SwiftUI composer so a
brand-new app gets the whole flow for free:

```swift
import OuroborosUI

// in your App's body:
OuroborosMenuBarEntry(ouroboros: ouroboros)
```

Apps with their own design system should build their own composer against the engine
instead (see `INTEGRATION.md`).

## Requirements

- macOS 14+, Swift 6.
- On PATH (resolved via a login shell, so a Finder-launched app finds homebrew): the
  agent CLI you use (`claude` / `codex`), plus `tmux` and Ghostty for `.ghosttyTmuxTab`,
  and `gh` if you use `finish: .openPR`.

## Integrating into your app

See [`INTEGRATION.md`](INTEGRATION.md) — written for a coding agent to follow.
