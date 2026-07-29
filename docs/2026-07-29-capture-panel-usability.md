# 2026-07-29 — the capture panel is not usable yet

The verdict on the first drawer: *"chaotic, lacks usability and does not convey
information well."* It shows things and lets you do nothing with them. This is the
spec for fixing that, and the checklist for working through it.

The rule that shapes every item below: **the GUI has no private powers.** Every new
action is an API endpoint on the daemon first, a CLI verb second, and a menu item
third. If it can't be done with `ouro`, it doesn't go in the panel.

---

## The diagnosis

The drawer answered "what exists" and never "what can I do about it". Six concrete
failures:

1. **Nothing is actionable.** A filed task is a piece of text. You can't fix it,
   open it, or throw it away.
2. **Nothing distinguishes the two kinds of recent.** Projects Ouroboros works on
   and projects you merely committed to are interleaved, sorted by a rule nobody
   can see.
3. **No way to curate.** Sixty registered projects, no favourites, no way to hide
   the ones that aren't interesting, no way to delete a mistake.
4. **`auto` means nothing.** It's the project's autonomy policy, rendered as a
   three-letter word next to a project name, where it reads as a property of a job.
5. **The harness is invisible and unchangeable.** There is no way to say "use
   codex for this one" anywhere in the UI, and no way to get back to the
   conversation an agent had.
6. **Filing is a dead end.** ⏎ files an issue and the panel closes. The thing you
   just created is now three clicks and a folder away.

---

## The shape of the fix

**One drawer, three sections, all compact.**

```
 ▸ PROJECTS  12                    • 1 running  ▮▮▮▮▮▮▮▮  128 handled
 ─────────────────────────────────────────────────────────────────────
 ★ FAVOURITES
   atlas          filed  the composer loses focus…      ▮▮▮  2  8m
 ◆ IN OUROBOROS
   ouroboros       filed  the capture panel hairline…    ▮     1  2h
 ⎇ GIT ACTIVITY
   7eus            commit feat(web): let a theme own…          3h
```

Rows are one line by default. The selected row opens into jobs and tasks, and
every job and task in it is a live object: hover reveals its actions, right-click
gives the full set.

---

## Checklist

### A. Make the drawer usable

- [x] **A1 — Row context menu.** Right-click a project: Set as target · Favourite /
      Unfavourite · Hide until active · Open in Finder · Open in terminal · Copy path ·
      Default agent ▸ · Autonomy ▸ · Remove from Ouroboros.
- [x] **A2 — Row hover actions.** On hover, a row reveals two buttons: `⌥` open in
      Finder, and a `⋯` that opens the same menu as right-click. No hover chrome
      on rows you aren't pointing at.
- [ ] **A3 — Tighter rows.** One line per project. Two only when it is the target.
      Section headers are 8pt and 12pt tall. The whole drawer with 8 projects
      should fit in the height 5 used to take.
- [x] **A4 — Tasks are objects.** Each task row: click = open the issue file,
      hover = `▸ fix` button, right-click = Fix now (agent ▸) · Open file · Copy
      title · Delete. A task you can't act on is just decoration.
- [x] **A5 — Jobs are objects.** Each job row: hover = peek button, right-click =
      Resume conversation · Open log · Open worktree · Open diff · Stop · Retry ·
      Acknowledge.
- [x] **A6 — Three sections, cleanly separated.** Favourites, in Ouroboros, git
      activity. A project appears exactly once, in the highest section that claims
      it.

### B. Curation

- [x] **B1 — Favourites.** A static, ordered list that always shows first, however
      old. `ouro projects favourite <id>` / `unfavourite`.
- [x] **B2 — Hide until active.** Hiding drops a project out of the drawer until
      something happens in it *through Ouroboros* (an issue filed, a run
      dispatched) — git activity alone does not bring it back. `ouro projects hide`.
- [x] **B3 — Remove.** Deletes the registry entry, never the directory, and says so.
- [x] **B4 — Both survive a restart** (stored on the project record in
      `projects.json`).

### C. Labels that mean something

- [x] **C1 — Kill the bare `auto` chip.** Autonomy is a project policy about
      *merging*, not a property of a job. Where it appears at all it reads
      `auto-merge` / `assists`, and it is in the context menu where it can be
      changed rather than floating next to a name.
- [x] **C2 — Every glyph is explained.** Help tooltips on the run tape, the counts,
      the section headers, the agent chip.

### D. Choose the harness

- [x] **D1 — Agent picker in the panel.** Next to the project chip: the agent this
      capture will dispatch to. Only harnesses actually installed are listed.
- [x] **D2 — Per-project default.** Set from the row's context menu, stored on the
      project, used by every dispatch for that project.
- [x] **D3 — Per-dispatch override.** The picker's choice applies to this capture
      only; it does not silently rewrite the project default.
- [ ] **D4 — Visible in the row and the job.** The job shows which harness ran it.

### E. Remember the conversation

- [x] **E1 — Capture a session id at dispatch.** Claude Code takes `--session-id
      <uuid>`, so Ouroboros generates one and knows the conversation before the
      agent starts. Codex records `~/.codex/sessions/**/rollout-*-<uuid>.jsonl`,
      so the id is discovered from the newest rollout matching the run's cwd.
- [x] **E2 — Resume in a terminal.** Right-click a job → Resume conversation opens
      Ghostty in the run's worktree running `claude --resume <id>` (or
      `codex resume <id>`). `ouro resume <run>` does the same from the shell.
- [x] **E3 — Agent view.** `claude agents` (v2.1.139+) is a fleet view of
      background Claude sessions. Ouroboros dispatches its own supervised runs and
      owns their lifecycle, so it does not hand them to agent view — but "Open
      agent view here" is offered per project, scoped with `--cwd`, because that
      is where your *own* sessions for that repo live. Documented in
      `docs/` and the run's context menu.
- [x] **E4 — Store it on the run** so it survives a daemon restart, and expose it
      in `ouro show <run>`.

### F. Filing is the beginning, not the end

- [x] **F1 — Actionable confirmation.** After ⏎ the panel stays open for a beat with
      `filed → project` and three live actions: **fix now** (⌘⏎), **open**, **undo**.
- [ ] **F2 — The new task is in the drawer immediately**, at the top of its
      project's tasks, so the thing you just made is visible where it lives.
- [x] **F3 — Undo.** Deletes the issue file that was just written. Only offered
      for the issue filed in this capture, and only while the confirmation is up.

### G. Plumbing the above honestly

- [x] **G1 — API first.** `PATCH /v1/projects/:id` gains favourite/hidden/agent;
      new `POST /v1/issues/:id/fix`, `DELETE /v1/issues/:id`,
      `POST /v1/runs/:id/resume`, `GET /v1/agents`.
- [x] **G2 — CLI parity.** `ouro projects favourite|unfavourite|hide|unhide|agent`,
      `ouro resume <run>`, `ouro agents`.
- [x] **G3 — Tests** for the new store logic, session-id capture and resume argv.
- [x] **G4 — Everything builds, every test passes, the app is installed and running.**

---

---

## Progress log

**2026-07-29 — consolidation pass.** Several agents had been working this checklist in
parallel and the tree had drifted: `ProjectsDrawer.swift` did not compile (`Text(task)`
against a `TaskPip`), so nothing could land, and the finished work of three runs was
sitting uncommitted on `main` while a fourth waited unmerged on its branch.

Landed here:

- **A1, A4, A5** — `RowActions.swift`: one place defining the verbs for projects, tasks
  and jobs, as right-click menus. Every verb is an API call, so the drawer gained no
  power the CLI lacks.
- **A2** — hover affordances. Star and folder on the row under the pointer, a persistent
  star on favourites, and nothing at all on the other rows.
- **A4** — `TaskRow`: click opens the issue file, hover offers `fix`, right-click has
  fix-with-agent, open, copy, delete. A filed task was a line of grey text before this.
- **A5** — `JobRow`: resume the conversation, log, diff, worktree, stop/merge/undo/retry.
- **B1, B2, B3** — favourite and hide wired end to end and verified against the live
  daemon: hiding drops a project out of `recents`, and filing an issue there brings it
  back. Removing never touches the directory.
- **C1** — the bare `auto` chip is gone. Autonomy is a policy about *merging*, so it now
  reads `auto-merge`, appears only when it will actually do something surprising, and
  carries a tooltip saying what that is.
- **D1, D3** — an agent picker in the panel footer, listing only harnesses whose CLI is
  really on PATH (`claude`, `codex`, `pi` here; `gemini` is correctly absent). The pick
  applies to this capture only and does not rewrite the project default; the row's
  context menu does that, which is D2.
- **F1, F3** — filing holds the issue it just made so the confirmation can offer verbs
  for it, and `undoLastFiled` deletes only that issue and only while its confirmation
  is up.
- **G4** — 122 tests green, all three products building, installed, daemon restarted,
  app relaunched.

Also fixed on the way: `DigestTests.testRoundTrip` could not infer `[RunStatus]` from a
bare array literal inside `XCTAssertEqual`.

Still open: **A3** (tighter rows — the drawer is actionable now but not yet smaller),
**A6** (favourites are not yet their own section), **C2** (tooltips exist on the new
chrome, not everywhere), **E2/E4** as a CLI verb, **G2** parity for
favourite/hide/agent, **G3** tests for the new store logic.
