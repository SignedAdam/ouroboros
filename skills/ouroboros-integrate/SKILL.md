---
name: ouroboros-integrate
description: Implement Ouroboros — the in-app "report an issue → hand it to a coding agent in an isolated git worktree in a new terminal tab" flow — end to end in a host application. Use when asked to add Ouroboros, an issue reporter/fixer, or "the report-issue button" to an app. Covers installing or porting the engine for the app's language, wiring the composer, floating button, menu section, and issues browser, and verifying the result.
---

# Integrating Ouroboros into a host app

You are implementing the full Ouroboros flow in a host application. The end state is
non-negotiable; the route there depends on the app's language. Work through the phases in
order. This file is self-contained — every engine signature you need is here.

**The repo you are reading from** (call it `$OURO`) contains a version of Ouroboros per
language (`swift/`, `python/`, `go/`, …). `swift/` is the reference implementation with a
full test suite.

## The required end state (all of these, exactly)

1. **Composer** — a modal/popover with: a multi-line markdown *description*; a *title*
   field auto-suggested live from the description (stops overwriting once the user edits
   it); per-issue fix options (**"Run in a new worktree"** toggle, default ON; **"On
   finish: Merge into base | Open a PR"** choice, default Merge); **Cancel** / **Create
   Issue** buttons.
2. **Confirm step** — after Create: show the saved file path, then offer the fix per the
   *harness rule* below ("Fix it" / "Fix with X" buttons + "Not now").
3. **Floating button** — a small, always-visible in-app button (bottom-right corner over
   all screens unless the app's design dictates otherwise) that opens the composer. Its
   icon is **the Ouroboros mark** (see "The mark" below) — never a bug/warning glyph.
4. **Menu section** — on macOS, a top menu-bar menu named **"Ouroboros"** with at least:
   *Report Issue…* (⌘⇧I) and *Issues…* (⌘⇧O). Non-macOS apps: the closest app-level
   equivalent (command palette entries, an app menu, a tray menu).
5. **Issues browser** — opened by *Issues…*: lists all tracked issues (title, status,
   created date, newest first); selecting one shows its markdown body in an editor with
   Save; per-issue actions: **Fix with <harness>** (per the harness rule), **Mark done**,
   **Cancel** (status moves), and the file path visible.
6. **Settings** — user-editable: enable/disable each harness (Claude Code, Codex), the
   repo path issues are filed into (default: the app's own repo root), and the base
   branch (blank = auto-detect the repo's current HEAD).
7. **Housekeeping** — `.ouroboros/` gitignored in the target repo; issues live in
   `.issues/` (committed, not ignored).

**The harness rule.** A harness is *available* iff its settings toggle is ON **and** its
CLI is on PATH (`command -v claude` / `command -v codex` via a login shell — a
GUI-launched app does not inherit the user's shell PATH otherwise).
**⚠ Probe async, read cached.** The PATH probe blocks on the spawned process
(`waitUntilExit` / equivalent), and on macOS that *pumps the run loop* — calling it
synchronously from a SwiftUI `body`/render path re-enters the UI update cycle and
segfaults. Run the probe on a background thread at app launch and when the
composer/browser opens, store the result in observable state, and make the
"available harnesses" getter a pure read of that cache. Pin this with a test: with
the cache empty and the CLIs really installed, available must be empty (proves the
getter never probes live).
- 0 available → save the issue; show no fix offer (hint the user to Settings).
- 1 available → one primary button: **Fix it**.
- 2 available → one button per harness: **Fix with Claude** / **Fix with Codex**.
Exactly ONE harness is ever passed to a fix invocation.

## The mark (Olympic-rings rule)

Every integration shows the Ouroboros mark — the self-eating snake — on its entry points.
It works like the Olympic rings: **geometry fixed, dressing yours.** The canonical
construction (exact proportions, angles, taper, what's fixed vs. free) is
`$OURO/brand/README.md`, with a reference SVG at `$OURO/brand/ouroboros-mark.svg`
(renders in `currentColor`; the eye is negative space).

- **Swift apps**: use `OuroborosMark` from the vendored package's `OuroborosUI` product
  (add `.product(name: "OuroborosUI", package: "Ouroboros")`) — it implements the
  canonical geometry and takes the app's `foregroundStyle`. Theme the container
  (colors, hover, glow) to the app; do not redraw the shape.
- **Other languages**: port from the SVG / the constants table in `brand/README.md`.
- Theming freedom and hard limits are listed in `brand/README.md` — read it before
  styling. Never substitute a generic snake, bug, or warning icon.

## Phase 0 — Recon (do this before writing anything)

1. Identify the app's language + UI framework and where settings, modals, and menu
   commands live. Read 2–3 existing examples of each pattern in the codebase.
2. **Check for an existing Ouroboros integration** (search for `Ouroboros`, `IssueFixer`,
   `.issues`, `handToAgent`). If one exists: EXTEND it to the end state above — do not
   duplicate engines, settings keys, or entry points. Reuse its settings and composer;
   add what's missing (typically the floating button, menu section, issues browser).
   If the existing integration depends on an **external checkout** of the engine (a
   sibling-directory path-dep or symlink), **migrate it to the vendored copy** in Phase 1
   — the end state is always the app owning its copy.
3. Find the repo root the app should file issues into (usually the app's own repo).
   **Default rule for the repo-path setting:** hardcode the app repo's absolute dev-
   checkout path as the default (a bundled GUI app has no repo of its own at runtime, so
   "detect it" is not derivable) and make it editable in Settings.

## Phase 1 — Get the engine

### Swift (macOS app) — the package exists; install it

Copy the package in (the app owns its copy):
```sh
cp -R $OURO/swift <app>/Packages/Ouroboros
rm -rf <app>/Packages/Ouroboros/.build
```
Wire it in `Package.swift` — **SPM identity gotcha:** a path dependency's identity is its
*directory name*, so `Packages/Ouroboros` → `package: "Ouroboros"`:
```swift
dependencies: [ .package(path: "Packages/Ouroboros") ],
// on the app target AND any test target that imports it:
.product(name: "Ouroboros", package: "Ouroboros")
```
(A path-dep to a checkout of `$OURO/swift` also works during development; its identity is
then `swift` — prefer the copy.) Verify: `swift test` inside the copied package — all
green before you write a line of app code. Then confirm the host repo's `.gitignore`
covers `Packages/Ouroboros/.build/` (running the tests just recreated it); add a rule if
not, and commit the vendored copy.

The package also ships an **`OuroborosUI`** target (a plain default composer +
`MenuBarExtra` entry). Use it ONLY when the host app has no design system of its own;
an app with established components ignores `OuroborosUI` entirely and builds its own
surfaces against the engine (per Phase 3's styling rule). Don't link it "just in case."

### Python — port exists in spirit

A reference implementation ships in Vaux (`vaux/ouroboros/`: `issue.py`, `store.py`,
`agent.py`, `terminal.py`, `facade.py` + tests). If `$OURO/python/` has the port, use it;
otherwise port from `$OURO/swift/` (below) — the units map 1:1.

### Any other language — port the pattern

Port `$OURO/swift/Sources/Ouroboros/` unit-for-unit (it is ~500 lines total), with tests
mirroring `$OURO/swift/Tests/OuroborosTests/`. The five units and their contracts are in
the next section; keep every shell-out behind an injectable runner so tests spawn nothing.

## Phase 2 — Engine contracts (what you call, whatever the language)

Signatures below are the Swift names; mirror them idiomatically when porting.

```swift
// Titles & slugs (pure)
IssueText.suggestTitle(_ body: String) -> String   // first non-empty line → ≤9 words/≤60 chars
IssueText.slugify(_ title: String) -> String        // [a-z0-9]+ → '-', ≤40 chars, fallback "issue"

// Issues on disk: .issues/<status>/<Title>.md, status ∈ {new, planned, done, cancelled}
// File: YAML-ish frontmatter (title, created ISO-8601) + "## Title" + markdown body.
// Legacy files without frontmatter parse fine (title from heading/filename, created from mtime).
IssueStore(rootDir: String)                          // writes to .issues/new/
store.write(title: String, body: String) -> Issue?   // frontmatter stamped; dedups "Name 2.md"
store.list() -> [Issue]                               // all statuses, newest first
store.read(path: String) -> Issue?
store.updateBody(_ issue: Issue, body: String) -> Issue?
store.setStatus(_ issue: Issue, _ status: IssueStatus) -> Issue?   // moves the file

// Issue: title, slug, body, path, created: Date?, status: IssueStatus

// Fix options — per-issue, chosen in the composer every time
FixOptions(worktree: Bool = true, finish: .mergeIntoBase | .openPR)

// Agents
Agent.claudeCode  // argv template ["claude", "{prompt}"]
Agent.codex       // ["codex", "{prompt}"]
Agent.custom("bin", "flag", "{prompt}")

// Terminal spawn — two Ghostty modes plus fallbacks:
// .ghosttyCinemaWindow (RECOMMENDED DEFAULT on macOS): each fix opens its own
//   small Ghostty window (80×21) fronted by a marquee — the Ouroboros banner,
//   "fixing your issue: <title>", a live elapsed timer, and hotkeys
//   ([p] peek at the agent's last output, [a] watch the agent live,
//   [q] hide the window while the agent keeps running). When the agent
//   finishes, the window flashes "✔ done MM:SS" and closes itself.
// .ghosttyTmuxTab: fixes stack as tabs in a dedicated "ouroboros" tmux session
//   ("sessionName:" to rename) shown in one Ghostty window. Never touches the
//   user's own tmux session (hijacking their view reads as "a terminal spawned
//   on top of mine").
// Give the user a settings toggle between the two; default to cinema.
TerminalLauncher(kind: .ghosttyCinemaWindow | .ghosttyTmuxTab | .osDefault | .custom)

// The facade — construct once per fix, from settings:
Ouroboros(projectDir: repoRoot, agent: <one Agent>, terminal: TerminalLauncher(kind: .ghosttyTmuxTab),
          baseBranch: resolvedBase)                  // resolvedBase: setting, or `git rev-parse --abbrev-ref HEAD`
ouroboros.submit(title:body:) -> Issue?               // = store.write
ouroboros.handToAgent(issue, options: FixOptions)     // creates fix/<slug> worktree under
                                                      // .ouroboros/worktrees/ (when worktree=true), then spawns
```

The seed prompt is built inside the engine — it already tells the agent: decide if the
issue is actionable (else leave it blocked with a note), implement → verify → merge back
or open a PR, and **auto-resolve**: append a `## Resolution` section and move the issue
file to `.issues/done/` when the fix lands. You never construct the prompt yourself.

Run `handToAgent` off the UI thread (it shells out to git + tmux).

## Phase 3 — Wire the UI

Match the host app's design system for every surface (find the app's modal, button, and
form-field components and use them — never introduce foreign styling).

1. **Settings**: two harness toggles + repo path + base branch, persisted the way the app
   persists other settings.
2. **Composer** (two-phase): live title suggestion =
   `on description change: if !titleEdited { title = IssueText.suggestTitle(description) }`,
   with `titleEdited` set once the user types in the title field.
   **⚠ Echo trap:** in reactive frameworks (SwiftUI `onChange`, React controlled inputs),
   the *programmatic* suggestion write fires the title field's own change handler — if
   that handler naively sets `titleEdited = true`, live suggestions die after the first
   keystroke. Only mark the title dirty when the new value **differs from the suggestion
   you last wrote** (track `lastSuggested`; `titleEdited = (newTitle != lastSuggested)`),
   and cover this with the regression test named in Phase 4.
   Create = `submit(title.isEmpty ? suggestTitle(body) : title, body)`; require a
   non-empty body. Confirm phase per the harness rule; each fix button calls
   `handToAgent(issue, options)` with that ONE harness's agent, then closes.
3. **Floating button**: small, corner-anchored, above all routes/screens, opens the
   composer. Keep it unobtrusive (icon-only, ~32px, host-app accent color).
4. **Menu section**: macOS `CommandMenu("Ouroboros")` (SwiftUI) or equivalent with
   *Report Issue…* ⌘⇧I and *Issues…* ⌘⇧O. If an existing integration already bound ⌘⇧I
   elsewhere, MOVE it into this menu.
5. **Issues browser**: `store.list()` table (title / status / created); detail = markdown
   `body` in a text editor → Save = `updateBody`; actions = fix buttons (harness rule) +
   *Mark done* (`setStatus(.done)`) + *Cancel issue* (`setStatus(.cancelled)`). Label it
   **"Cancel issue"** — a bare "Cancel" in a modal reads as "close this dialog". Fix
   buttons here use the engine's default options (`FixOptions()` = worktree ON, merge
   into base); only the composer offers per-issue option toggles. Refresh the list after
   every action, and note `setStatus`/`updateBody` return an issue with a **new path** —
   re-key any selection state to the returned issue or the detail pane silently
   deselects.

## Phase 4 — Verify (all of it)

1. Engine tests green (package's own suite, or your port's).
2. App builds; app test suite passes (add tests for: harness rule 0/1/2, title
   suggestion + dirty flag **including the echo regression** — programmatically applied
   suggestions must NOT stop future suggestions —, settings persistence — mirror the
   app's testing idiom; if settings use a shared store like `UserDefaults.standard`,
   save/restore the keys around the test so state doesn't leak across runs).
3. Manual checklist — run the app:
   - floating button visible on every screen; opens the composer
   - menu bar shows **Ouroboros → Report Issue… (⌘⇧I), Issues… (⌘⇧O)**
   - type a description → title fills live; edit title → suggestions stop
   - Create Issue → file exists at `.issues/new/<Title>.md` with frontmatter
   - confirm step shows the right fix buttons for 0/1/2 enabled harnesses
   - Issues… lists the issue; edit body + Save persists; Mark done moves the file to
     `.issues/done/`
   - (if a harness is installed) Fix → a new Ghostty/tmux tab opens, agent running in
     `.ouroboros/worktrees/<slug>` on branch `fix/<slug>`
4. `git status` in the target repo: only intended files changed; `.ouroboros/` ignored.

## Failure modes to avoid

- Spawning via AppleScript/Accessibility — the engine's tmux route needs no permissions.
- Building the seed prompt by hand in the app — the engine owns it.
- A second settings store / second composer when one already exists — extend, don't fork.
- Passing multiple harnesses to one fix call — the UI picks exactly one.
- Skipping the login-shell PATH resolution — Finder-launched apps won't find `claude`.
