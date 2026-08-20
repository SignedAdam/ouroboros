# Ouroboros

<p align="center">
  <img src="docs/capture-panel.png" alt="The Ouroboros Zero capture panel: a &quot;what's wrong?&quot; field over a live list of projects, each row showing what it is carrying and how long ago" width="700">
</p>

In-app issue capture → coding agent. Your app gets a floating button; anyone using the
app describes an issue; it's saved as a markdown file in `.issues/`; one click hands it
to Claude Code or Codex in an isolated git worktree, running live in its own terminal
window that closes when the agent finishes. File ten issues, fire ten agents, walk away.

⌥Space from anywhere, type the thing, and an agent is on it — across every repo you own.

## Install it in your app

Give your coding agent this prompt:

```text
Add Ouroboros to this app.
Clone https://github.com/SignedAdam/ouroboros (or use an existing checkout),
read skills/ouroboros-integrate/SKILL.md from that repo, and follow it exactly.
$OURO = the checkout path.
```

That skill file is self-contained: it detects your app's language, installs the Swift
package or ports the pattern, wires the UI (composer, floating button, menu, issues
browser, settings), applies the mark, and ends with a verification checklist.

Machine requirements for running fixes: `git`, an agent CLI (`claude` / `codex`),
Ghostty (Terminal.app fallback exists), `gh` only if you use PR-finish.

## Ouroboros Zero — the global control plane

The package above puts a report-issue button *inside one app*. [`zero/`](zero/) puts it
**everywhere**: a daemon that supervises every agent it dispatches, a CLI, and a menu-bar
app with an ⌥Space capture panel — one core with four faces, all clients of the same
local HTTP API. It refuses to let unverified work land.

```bash
cd zero && make install
ouro projects discover ~/dev          # register every repo under a root
ouro i "the login button does nothing" --fix
```

macOS only. See [`zero/README.md`](zero/README.md), and [`zero/OPERATOR.md`](zero/OPERATOR.md)
for the API an AI operator drives it through.

## Language support

[`swift/`](swift/) and [`zero/`](zero/) are fully implemented and used in production.

Reference ports for [`python/`](python/), [`go/`](go/), [`nextjs/`](nextjs/) and
[`react/`](react/) are not written yet. Those folders are placeholders.

You can still use Ouroboros in those stacks today. Point your coding agent at
[`skills/ouroboros-integrate/SKILL.md`](skills/ouroboros-integrate/SKILL.md) and it will
generate the pattern directly inside your target project.

If you want a canonical port in this repo:

- **Ask for one.** Open an issue with your stack. I will write the port for you.
- **Contribute one.** PRs are welcome. Keep it minimal and match the Swift implementation.

## Repo layout

- `skills/ouroboros-integrate/SKILL.md` — the entry point; everything an agent needs
- `swift/` — the Swift package: `Ouroboros` (engine, no UI deps) + `OuroborosUI`
- `zero/` — Ouroboros Zero: `ourod` (daemon), `ouro` (CLI), the menu-bar app
- `brand/` — the mark: geometry spec + reference SVGs
- `docs/` — design notes

## The loop

Composer → `.issues/new/<Title>.md` (frontmatter `title`/`created`; status = folder) →
seed prompt → agent in a `fix/<slug>` worktree in its own window → the agent appends a
`## Resolution` section and moves the file to `.issues/done/` when the fix lands.

## License

MIT — see [LICENSE](LICENSE). Use it in anything, commercial work included.

If Ouroboros ends up in something you ship, a link back is appreciated and never
required. The mark is yours to display too, if you want to show what's under the
floating button.
