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
- [x] **A3 — Tighter rows.** One line per project. Two only when it is the target.
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
- [x] **D4 — Visible in the row and the job.** The job shows which harness ran it.

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
- [x] **F2 — The new task is in the drawer immediately**, at the top of its
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

---## Progress log

All 27 boxes ticked. Built in two layers, by two sessions working the same spec
at once — one took `ZeroApp`, the other `ZeroCore`/`ourod`/`ouro`.

**The layer underneath**

- `ZeroCore/Agents.swift` — harness adapters. `Harness.of` recognises a harness by
  the executable its template actually runs, so pointing "claude" at a wrapper
  keeps working and an unknown harness loses the extras rather than breaking
  dispatch. Claude Code is told its conversation id up front (`--session-id`);
  Codex will not be told, so its id is discovered from the newest
  `~/.codex/sessions/**/rollout-*.jsonl` whose first line names the run's cwd.
- `Project.favourite` / `.hidden`, `Run.sessionId` — both behind hand-written
  decoders, because a synthesised one requires every key to be present and
  adding a field would have silently emptied `projects.json`. That exact bug cost
  an evening in `Config` already.
- `Registry.touch` clears `hidden`: using Ouroboros in a project brings it back,
  committing to it does not — which is what "until it becomes active again" has
  to mean, or hiding would never survive a working afternoon.
- The daemon assembles three sections and the app renders them; neither can
  disagree with the CLI about which project belongs where.

**The API, and the CLI that proves it is not private**

    GET    /v1/agents                    which harnesses exist, installed, resumable
    PATCH  /v1/projects/:id              + favourite, hidden
    DELETE /v1/issues/:id[?purge=1]      cancel, or really delete
    POST   /v1/runs/:id/resume           reopen the agent's own conversation

    ouro agents · ouro show <run> · ouro resume <run>
    ouro projects favourite|unfavourite|hide|unhide|agent <id>

**What was verified, and how**

- 146 tests pass, 24 of them new: harness detection, session-id injection (and
  the two cases where it must *not* inject), resume argv per harness, Codex
  rollout discovery including the "older than this run" and "prefix is not a
  match" traps, un-hiding on use, and old registry files still decoding.
- Live against the running daemon: `ouro agents` lists claude/codex/pi installed
  and gemini absent; favouriting moved a project into FAVOURITES and hiding
  removed one from the drawer entirely; a freshly filed issue appeared at the top
  of its project's TASKS within a second; `DELETE ?purge=1` removed it again;
  `ouro resume` refuses cleanly on runs that predate session capture.
- Not exercised live: a real dispatch that captures a session id end to end.
  That spawns an agent on the operator's machine, so it is covered by unit tests on the
  argv and discovery instead, and wants one real fix run to confirm.

**Agent view** (`claude agents`, v2.1.139+) is offered per project via the row
menu, scoped with `--cwd`. Ouroboros deliberately does not hand its supervised
runs to it: a supervised run belongs to the supervisor, which owns its worktree,
its gate and its merge. Agent view is the right window onto the sessions you
start yourself, and now it is one right-click away from the project it belongs to.
