# Ouroboros v2 — issue tracking + the integration skill

**Status:** approved direction (2026-07-03); design locked by Claude per delegation.

## Goals

1. **Issue tracking.** Ouroboros keeps track of submitted issues: metadata (created date),
   a status lifecycle, listing, markdown body editing, and **auto-resolution** (the fixing
   agent marks the issue done when its work lands).
2. **The integration skill.** The repo ships an agent skill (`skills/ouroboros-integrate/`)
   that tells a coding agent *exactly* how to implement Ouroboros in the host app's
   language — install or port, then wire inputs/outputs end to end.
3. **Required app end state** (what the skill drives an app to): a **floating in-app
   button** that opens the composer, a **macOS menu-bar section** ("Ouroboros") with
   Report Issue… and Issues…, the two-phase composer (per v1), and an **issues browser**
   (list + markdown editor + per-issue actions).

## Issue file format v2 (backward compatible)

```markdown
---
title: Fix login button
created: 2026-07-03T02:55:12Z
---

## Fix login button

body markdown…
```

- **Status = folder**, matching the existing convention (Lantern + Atlas):
  `.issues/new/`, `.issues/planned/`, `.issues/done/`, `.issues/cancelled/`.
  New issues are written to `new/`. Changing status moves the file.
- **Frontmatter** carries `title` and `created` (ISO-8601 UTC). Parsers MUST tolerate
  files with no frontmatter (legacy): fall back to the `## Title` heading (else the
  filename) and the file's modification date.
- Body remains everything after the `## Title` heading — plain markdown, user-editable.

## Engine API v2 (Swift; additive — v1 call sites keep compiling)

```swift
public enum IssueStatus: String, CaseIterable, Sendable { case new, planned, done, cancelled }

public struct Issue {            // extended; memberwise init keeps old arity via defaults
    // v1: title, slug, body, path
    public let created: Date?    // default nil
    public let status: IssueStatus  // default .new
}

public struct IssueStore {
    // v1 init(rootDir:subdir: ".issues/new") keeps working: subdir ending in "/new"
    // implies the issues root is its parent.
    public func list() -> [Issue]                    // all four folders, newest first
    public func read(path: String) -> Issue?
    @discardableResult
    public func updateBody(_ issue: Issue, body: String) -> Issue?   // rewrite, keep meta
    @discardableResult
    public func setStatus(_ issue: Issue, _ status: IssueStatus) -> Issue?  // move file
}
```

`write(title:body:)` now stamps frontmatter (`title`, `created`). A `now: @Sendable () -> Date`
seam (default `Date.init`) makes `created` testable.

## Auto-resolution (seed prompt v2)

Appended to the existing finish clauses:

- worktree+merge: after the clean merge, **append a `## Resolution` section** (1–3 lines:
  what changed, date) to the issue file and **move it to `.issues/done/`** (`git mv`),
  committing that move on the base branch.
- PR finishes: append the PR URL to the issue file; leave it in `new/` (a human or the
  merge flow moves it later).
- in-place+merge: same `## Resolution` + move-to-done, committed with the fix.
- Not-actionable (unchanged): note what's ambiguous, leave in `new/` — blocked.

## The skill

`skills/ouroboros-integrate/SKILL.md` — Claude-Code-style skill (YAML frontmatter +
markdown body). Self-contained: an agent with this file + this repo checkout + the target
app can do the whole job. Contents: language/framework detection; existing-integration
detection (extend, never duplicate); per-language install (swift = copy `swift/` in as
`Packages/Ouroboros`, or path-dep with the SPM-identity gotcha) or port (stub languages:
port the 5-unit pattern + tests from `swift/` reference); wiring steps (settings,
composer, floating button, menu section, issues browser); exact engine signatures; the
harness rule (0 enabled → no fix offered; 1 → "Fix it"; 2 → "Fix with X / Fix with Y");
PATH prerequisites; gitignore; a verification checklist (build + tests + manual).

README points agents at the skill as THE entry point; per-language stubs defer to it.

## Out of scope (v2)

- Watching agent progress / live status of in-flight fixes.
- Non-file issue backends (GitHub Issues sync etc.).
- Porting to the stub languages (the skill covers porting; the ports land on demand).
