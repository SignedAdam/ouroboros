# 2026-07-31 — rebuild the drawer

The operator, on the current state: *"This makes no sense whatsoever. Looking at this, I fail to
even imagine what I had asked you for this to get implemented."*

That is the bar this document has to clear. Not "add the missing feature" — work out what
the drawer is **for**, and build that.

---

## What it is for

One sentence: **the drawer is where you see what Ouroboros is doing and pick up where you
left off.** Everything below follows from that. If a pixel does not serve it, cut the pixel.

---

## The complaints, verbatim and specific

1. **`manual` / `auto` on a project row is meaningless.** "dont even know what this is."
   It is the autonomy policy, which is a setting, not a status. It does not belong on a row.
   **Replace it** with the thing that actually earns that space: the project's latest
   Ouroboros job, or its latest git activity. On the **right-hand side** of the row.

2. **Grouping is right, execution is wrong.** Two groups in this order: projects with recent
   Ouroboros activity first, then projects with recent git activity. It does group today,
   but it is *"super chonky and also ugly"*.

3. **No design consideration.** The divider label `IN OUROBOROS` is **grey text on a grey
   background** — unreadable. And the labels are *"self-describing overly verbose bs"*.
   Kill the explanatory tone. Short, high-contrast, or gone.

4. **Fold state must be remembered.** It must NOT start folded shut. It must reopen in
   whatever state it was left in. (Claude broke this today by defaulting it closed; the
   preference already persists, the default was simply wrong.)

5. **The `jobs` count is incomprehensible.** A row shows `2` or `3` "jobs" and none of it
   means anything. `jobs` is a horrible name. Whatever this becomes, a bare integer next to
   a project is not it.

6. **The thing actually wanted, which does not exist yet.** The operator, reconstructing what they
   must originally have asked for:

   > "We definitely need a way to visualize recently started issues and their status and
   > the ability to open them instantly in claude code/codex and mark them off as confirmed
   > done, etc. And a way to see unfixed but filed issues. We need this, but it should be
   > ergonomic, aesthetic, and well designed with UX and UI in mind."

   So, concretely, the drawer must let him:
   - see recently started issues and their status
   - open any of them instantly in Claude Code or Codex
   - mark one off as confirmed done
   - see issues that are filed but not yet fixed, distinctly from ones in flight

---

## Direction

**The right column carries the reason the row is in the list.** In the Ouroboros group that
is the latest job and its state (`fixed 2h`, `running`, `failed 3d`). In the git group it is
the last commit (`3h`). One fact, right-aligned, past tense, quiet.

**Two groups, minimal chrome.** If a header is needed it is high-contrast and one word.
Prefer distinguishing the groups by a gap and by what the right column says. `IN OUROBOROS`
and `GIT ACTIVITY` are both too loud and too dim at the same time.

**Issues are the point, not projects.** Projects are the index; issues are the content.
Selecting a project reveals its issues, and every issue row supports, at minimum: open in
the agent, mark done, and a visible state (filed / running / needs you / landed). Filed-but-
never-dispatched must be visually distinct from in-flight — those are the ones that rot.

**Copy rules.** No sentence where a word will do. No label that explains itself. No tooltip
carrying information the row should have shown. The operator reads the interface, not the manual.

**Density.** One line per project. One line per issue. The capture field is the product; the
drawer is support.

---

## Constraints

- The GUI has no private powers: every action is an existing daemon endpoint, or a new one
  plus its `ouro` verb. Never a shell-out from the app.
- `swift build` clean for all three products, `swift test` green (149 tests at the time of
  writing), `make install`, daemon restarted, app relaunched.
- Do not touch the recording scripts, the toast sound, or anything under `docs/` other than
  this file's checklist.

## Checklist

- [x] **1** — `manual`/`auto` gone from project rows.
- [x] **2** — Right column shows latest job (Ouroboros group) or last commit (git group).
- [x] **3** — Two groups, ordered, compact, not chonky.
- [x] **4** — Group labels readable or removed. No grey-on-grey.
- [x] **5** — Verbose/self-describing copy replaced with short labels.
- [x] **6** — Fold state remembered, and does not default to shut.
- [x] **7** — The bare `jobs` integer is gone.
- [x] **8** — Issues visible with their status.
- [x] **9** — Open an issue's conversation in Claude Code / Codex from its row.
- [x] **10** — Mark an issue confirmed done from its row.
- [x] **11** — Filed-but-unfixed issues visible and distinct from in-flight.
- [x] **12** — Builds, tests, installed, relaunched.

---

## Progress log — 2026-07-31

Twelve boxes, and the drawer was looked at after every change rather than at the
end. Screenshots of the panel window only, driven through the hotkey.

**The shape underneath changed first.** `TaskPip` and `RunPip` are gone, and with
them the TASKS / JOBS split. There is one type, `IssuePip`, and one vocabulary,
`WorkState`: `filed · queued · running · needs you · ready · landed · failed ·
stopped`. `WorkState.of(run)` uses the same `mergedInto != nil || prUrl != nil`
test the inbox uses, so the drawer and `ouro inbox` cannot disagree about whether
a fix landed. `ProjectDigest` now carries `issues` (ranked: moving first, then
waiting on you, then merely written down, then finished) and `openCount`, and
`lead` is the one fact the row's right-hand side prints.

Resolving an issue *moves its file*, so the path a run recorded at dispatch is
stale by the time it lands. The digest ties a run back to its issue by basename,
which survives the move — without that, every landed fix shows as an orphan with
no id to tick off. There is a test for exactly that.

**The drawer.** One line per project, one per issue. `manual`/`auto` is gone from
the rows entirely; autonomy lives in the right-click menu where it can be
changed. The right column carries one fact — the state of the project's latest
work, or `commit` for a repo Ouroboros has never run in — with its age in the
last 22 points. Favourites no longer cost a section header: a 6.5pt star sits
after the name. Two groups, and the only header left is the word `git` on a
hairline at `.secondary`, which is legible on this surface where the old
quaternary `IN OUROBOROS` was not.

An issue row reads without hovering: a dot (hollow = nobody was dispatched,
filled = something happened), the title, the state, the age. Hovering adds two
verbs and no more — `fix` or `open`, and a tick. `open` resumes the conversation
the harness kept; naming a harness in the context menu always means "start a
fresh one with that". The tick is `PATCH /v1/issues/:id {status:done}` plus an
ack on the run behind it, which is exactly what the new `ouro done <issue-id>`
does, so the GUI keeps its promise of having no private powers.

**Fold.** Default flipped to open, and verified the hard way: deleted the
preference, relaunched → open; clicked the rail shut → `recentsExpanded 0` on
disk; relaunched → still shut.

**What bit.** The issue rows used to be inside the project row's `Button` label,
and a plain Button on macOS swallows every click landing in it — the hover verbs
would have been painted and dead. They are siblings of the button now. The first
click test also missed because an 8pt SF Symbol is not a target: every hover verb
now carries its own padding and `contentShape`, which matters more than usual
here because the capture panel is movable by its background, so a miss *drags the
window*.

**Verified live**, against the running daemon: `ouro done` moves the file and
clears the run; the drawer picked up a real dispatch and rendered it `running` in
orange, at both the project row and the issue row; the star button (which is
nested inside the project button's label, the harder case) flipped `favourite` in
`projects.json` on a click and the pinned row rendered its star.

**Not verified end to end:** a click on an issue row's own `fix` / `open` / tick.
The operator came back to the keyboard mid-test and I stopped driving the screen rather
than spawn agent terminals over their work. The API path is proven from the CLI and
the layout bug that would have blocked it is fixed, but the button itself has not
been clicked in anger.

**Also not done:** no `/done` slash command — the tick and `ouro done` cover the
requirement, and adding a third face felt like scope.
