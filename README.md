# Ouroboros

**One pattern, every language.** An in-app "report an issue → hand it straight to a coding
agent in an isolated git worktree in a new terminal tab" flow. File ten issues, fire ten
agents, walk away. It feels magical.

This repo holds a self-contained implementation of that pattern **per language**. Point a
coding agent at this repo, tell it your app's language, and it copies that version's pattern
into your app.

## How to use this repo (for a coding agent)

**Read and follow [`skills/ouroboros-integrate/SKILL.md`](skills/ouroboros-integrate/SKILL.md).**
It is the single entry point: it detects your app's language, tells you whether to install
an existing package (Swift) or port the pattern, and walks the full wiring — composer,
floating button, menu section, issues browser, settings — through to a verification
checklist. (If your agent runtime supports installable skills, copy that folder into your
project's `.claude/skills/`; reading the file directly works just as well.)

The per-language folders below hold the implementations the skill installs or references;
`swift/INTEGRATION.md` has extra Swift-specific detail.

## Languages

| Folder | Status | Notes |
|---|---|---|
| [`swift/`](swift/) | ✅ Ready | Swift / SwiftUI, macOS. Pure engine (`Ouroboros`) + optional default UI (`OuroborosUI`). 26 unit tests. In production use in Monday. |
| [`python/`](python/) | ⏳ Planned | A reference implementation exists today in Vaux (`vaux/ouroboros/`); port it here. |
| [`go/`](go/) | ⏳ Planned | |
| [`nextjs/`](nextjs/) | ⏳ Planned | |
| [`react/`](react/) | ⏳ Planned | |

## The pattern (language-agnostic)

Five small units, mirrored in every language:

1. **Issue** — model + a local title heuristic (first line → ~9 words) + slug.
2. **Store** — issues as markdown files under `.issues/<status>/` (status ∈ new/planned/
   done/cancelled = the folder), with frontmatter metadata (`title`, `created`), listing,
   body editing, status moves, and dedup. Fixing agents auto-resolve: they append a
   `## Resolution` section and move the file to `done/`.
3. **Agent** — build the agent command + a **seed prompt** telling it: this is one issue
   from an in-app composer; decide if it's actionable, then (in a worktree) implement →
   verify → merge back or open a PR; else leave it blocked with a note.
4. **Terminal launcher** — spawn the agent in a new terminal tab (default: a `tmux`
   window in the active session, i.e. a new Ghostty tab). Pluggable per environment.
5. **Facade** — `submit(title, body)` → `handToAgent(issue, options)`.

Per-issue options the UI exposes each time: **run in a new worktree?** and **merge into
base vs. open a PR**.

Keep the units small, pure, and behind injectable runners so they test without spawning
anything — each language folder does exactly that.
