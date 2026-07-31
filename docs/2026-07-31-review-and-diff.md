# 2026-07-31 — say what you mean, and show the diff

The operator, looking at the drawer after the rebuild:

> "Some say 'landed' some say 'ready'. these statuses are too confusing and not self
> evident. I suppose 'ready' are actually ready to be reviewed?"

He is right, and the words are the smaller half of it. He then asked whether he could
safely merge the two he saw marked ready. The answer was no: the one genuinely-ready run
conflicts with `main` in three files, because it branched before the drawer rebuild landed
and both touched the same views.

**Ouroboros said "ready" about a branch it had never tried to merge.** That is the bug this
document is really about. Everything else here is the interface catching up to it.

---

## 1. The words

`filed · queued · running · needs you · ready · landed · failed · stopped` is eight states,
two of which are jargon. Replace the two that fail the read-aloud test:

| now | becomes | why |
|---|---|---|
| `ready` | `review` | it is waiting on **you**, and that has to be the first word |
| `landed` | `merged` | says where it went, in a word everyone already owns |

The rest stay. `filed`, `running`, `failed`, `stopped` are already plain.

**A state must never be a verdict the code has not checked.** `review` is only `review` if
the branch still merges. See §2.

## 2. `review` has to be earned

Before a run is shown as `review`, test the merge without performing it:

```
git merge-tree --write-tree <base> <branch>
```

Non-destructive, no worktree, no index. Exit status and `CONFLICT` lines are the answer.

- merges clean → `review`
- does not → **`conflicts`**, its own state, tinted like a failure, and the row offers
  `rebase` rather than a merge that will fail.

Cache the result against the pair of commit shas so the drawer is not shelling out per
render. Recompute when either side moves.

## 3. "you need to check these"

> "We should definitely put those separately in a 'you need to check these'."

The drawer buries the two states that want a human inside per-project lists. Lift them out:
a group at the **top** of the drawer, above the projects, holding every `review`,
`conflicts` and `needs you` item across all projects. It is empty most of the time, and
when it is empty it takes zero height — no placeholder, no header.

This is the same set `ouro inbox` prints. It must be the same code path.

## 4. The diff

> "we need a git diff viewer :) and maybe more info about the commits made, files touched."

`ouro diff <run>` already exists. The GUI has none of it. Add a diff surface, opened from a
`diff` verb on any row where a diff exists — `review`, `conflicts`, `merged`, and `failed`
where the agent committed before dying.

It shows, in this order:
- **the commits**, subject and short sha, oldest first
- **files touched**, with `+n / -n` per file
- **the hunks**, syntax-uncoloured but with added and removed lines tinted

Read-only. It is for deciding whether to merge, not for editing. Escape closes it and
returns to the drawer with the same project still open.

It gets its content from a daemon endpoint — `GET /v1/runs/:id/diff`, returning structured
data, not a blob of text the GUI has to parse. `ouro diff` gains `--json` from the same
endpoint.

## 5. Dispatch options

> "do we have a way to file&fix a task and immediately merge it back to a target branch?
> Like, when i start the task, it should have some options: work in new issue? work in new
> git worktree? merge back to main automatically (or leave pending for my review?)"

The engine already supports all three — `finish` is `.merge | .pr | .leave`, worktrees are
on by default with `--no-worktree`, and base branch is per-run. **None of it is reachable
when filing.** Surface it at capture time:

- a compact options row on the capture panel, collapsed by default, opened with a key
- three choices only: **worktree** on/off, **finish** merge/PR/leave, **base** branch
- it remembers per project, because the answer is a property of the project, not the moment
- the defaults stay exactly as they are today, so the fast path does not grow a step

Anything more belongs in `ouro projects set`, which already has it.

## 6. The row verbs

> "add on hover effects on all the buttons 'fix', 'open', 'diff' and style them and give
> small elegant icons."

Each verb gets an SF Symbol and a label, a hover background, and a real hit target.
Suggested glyphs: `fix` → `hammer`, `open` → `bubble.left.and.text.bubble.right`, `diff` →
`plus.forwardslash.minus`, done → `checkmark`. Small, low-contrast until hovered.

Which verbs appear is a function of state, and only ever two or three at a time:

| state | verbs |
|---|---|
| `filed` | fix · done |
| `running` | watch · stop |
| `needs you` | reply · watch |
| `review` | diff · merge · done |
| `conflicts` | diff · rebase |
| `merged` | diff · undo · done |
| `failed` | diff · retry · done |

## 7. Stop the hover growth

> "when i scroll over items in ouroboros, you slightly grow the hovered text size. Stop
> doing that, it layout shifts everything."

Nothing may change size on hover. Hover changes **colour and background**, never metrics.
Audit every `.font` that reads a hover or selected flag — including the project row, whose
weight currently jumps from `.medium` to `.semibold` on selection, moving every glyph after
it on the line.

## 8. Deleting an issue does not delete it

> "i just deleted one of the older issues and it wont vanish."

`ouroboros-2d9abf1ca8` ("the capture panel has a bright hairline…") is still listed, with
status `cancelled`. Delete sets `cancelled` and the drawer renders cancelled issues.

Decide and implement one rule: **delete removes it**, and `cancelled` is reserved for a run
that was stopped. A cancelled *issue* is not a state the drawer shows. Make sure the row
disappears on the click, not on the next poll — the `Vanished` machinery on the pending
branch (§9) exists for exactly this.

## 9. Land the pending branch first

`r-ms8p7hby-ci78` is verified and conflicts with `main` in `ProjectsDrawer.swift`,
`QuickCapture.swift` and `RowActions.swift`. It adds `RowVerbs.swift` and `Vanished.swift`,
which §6 and §8 both want. **Rebase it onto `main` and land it before starting**, and take
its `Vanished` work as the foundation rather than reinventing it. Its tests come with it.

---

## Constraints

- The GUI has no private powers: every action is a daemon endpoint plus an `ouro` verb.
- No em-dashes in UI copy. No label that explains itself. Lower case.
- `swift build` clean, `swift test` green, `make install`, daemon restarted.
- **Do not launch the app from `.build/debug`.** Three stale copies were running earlier,
  each with its own menu bar icon and its own daemon, showing months-old UI. Install, then
  run the installed `.app`, and kill any stray first.
- **Do not drive the screen.** The operator is at the keyboard. No presence, no synthetic keys, no
  screenshots. Verify through tests, the CLI and the daemon API. Say plainly what you could
  not check without clicking.

## Checklist

Three states, not two. **done** · **blocked** (needs a file another session owns)
· **not started**.

- [~] **1** — `ready`→`review`, `landed`→`merged` done in the engine, the CLI, the
  inbox, the notifier, the config and the README. **Blocked:** the two `WorkState`
  cases in `Digest.swift`. One rename, spelled out in the log.
- [x] **2** — Merge-tested, engine half: `ZeroCore/MergeCheck.swift`, on the run's
  serialized state and on the daemon, and the inbox no longer offers a merge it has
  tested and knows will fail. **Blocked:** `conflicts` as a `WorkState` case, and its
  tint, both in `Digest.swift`.
- [ ] **3** — Not started. Drawer.
- [x] **4** — `GET /v1/runs/:id/diff` returns structured data; `ouro diff --json`.
- [x] **5** — `ZeroApp/DiffView.swift`: commits, files with `+n/-n`, tinted hunks,
  escape closes. **Not wired to a row** — that call site is in the drawer.
- [ ] **6** — Not started. Capture panel.
- [ ] **7** — Not started. Drawer rows.
- [ ] **8** — Not started. Drawer and capture panel.
- [ ] **9** — Not started. Drawer rows plus `AppModel`.
- [~] **10** — `r-ms8p7hby-ci78` rebased onto `748ef29` and verified, **not landed**.
  `main` has since moved to `2542a82` and it no longer fast-forwards. See the log.
- [~] **11** — `swift build` clean, `swift test` green at **194**. Deliberately
  **not installed**. See the log.

---

## Progress log — 2026-07-31

**Item 10 is done on the branch and stopped short of landing.** Everything after
it is untouched, for one reason: a second agent is editing this working tree
right now, and three of the files it holds uncommitted are three of the four the
merge has to write.

**The rebase.** `r-ms8p7hby-ci78` branched at `dbb7984`, one commit before the
drawer rebuild. A mechanical rebase was not worth attempting: `748ef29` deleted
`TaskPip`, `RunPip`, `TaskRow`, `JobRow` and the TASKS / JOBS split, which is
most of what the branch's three commits touch, so all three would have conflicted
and all three intermediate trees would have been uncompilable. Replayed instead,
onto main, as one commit — `9b13301` — with the drawer rebuild's structure as the
base and the branch's `leaving` / `vanished` behaviour layered on. The original
tip is kept at the tag `ouro-prerebase-r-ms8p7hby` (`9f72c56`).

`Vanished` and `RowVerb` came across verbatim, tests included, as instructed. What
had to be re-derived is everything that named the dead types:

- `tasks(of:)` and `jobs(of:)` became `issues(of:)`, over the one `IssuePip` list.
- `openTaskCount(of:)` became `openCount(of:)`, and it now subtracts only the
  vanished issues that were still `filed` — `openCount` counts nothing else, and
  deleting a running issue must not decrement it.
- `recents(in:)` became `visibleRecents`, because the rebuilt drawer groups by
  `section != .git` rather than walking `ProjectSection.ordered`.
- `ProjectRow.lead` now reads through `model.issues(of:)` instead of
  `digest.lead`, so the row's right-hand fact stops counting a row the moment its
  exit finishes rather than at the next poll.
- The receipt takes the footer row from the three key hints, which is where the
  branch's third commit put it; the hints themselves were rewritten by `748ef29`.

One deliberate addition: `RowVerb.markDone`. The tick and the "Mark done" menu item
had no verb of their own and would have had to borrow `.clear`, which means
something else. `RowVerbTests` asserts the case count precisely so that adding a
verb forces this decision, so the counts moved with it — 23 cases, 8 that hand
off, 15 that keep the panel.

`swift build` clean for all three products, `swift test` green: **163 tests**, the
151 on main plus the branch's 12.

**Why it did not land.** Between 12:02 and 12:08 another agent wrote
`ProjectsDrawer.swift`, `RowActions.swift`, `QuickCapture.swift`, `Digest.swift`
and `DigestTests.swift` in this checkout — a different brief (`Tally`, `TallyBar`,
`SelectionRail`, `WorkGlyph`, a live count on the drawer rail), none of it
committed, and at one point referencing a `LiveDot` that does not exist yet.

The merge itself is trivial — the branch is a strict descendant of main, so it is
a fast-forward. What blocks it is that three of the files it must update are dirty
with someone else's work:

```
zero/Sources/ZeroApp/ProjectsDrawer.swift
zero/Sources/ZeroApp/QuickCapture.swift
zero/Sources/ZeroApp/RowActions.swift
```

`git merge` refuses that outright, and every way around it is worse. Stashing
displaces another session's only copy. A ref-only merge via `commit-tree` is the
real trap: it leaves their files on disk unchanged, so their next `git add -A`
silently reverts item 10 with nothing to show it happened.

So nothing was forced. Their work is snapshotted at
`/tmp/ouro-concurrent-backup/` — the three files plus a full `git diff` patch — as
insurance, not as a substitute for their session.

**To land it**, once this tree is clean:

```
ouro merge r-ms8p7hby-ci78
```

That is the product's own path and it keeps the run's record straight — it sets
`mergedInto`, moves the issue file to `done/`, commits that move and removes the
worktree. A hand `git merge` does none of it, and would leave the run reading
`ready` for ever, which is precisely the lie §2 of this document is about.

**Items 1 to 9: not started.** Every one of them lives in the contested files —
1 and 2 in `Digest.swift`, 3 and 5 to 8 in the drawer and the row views, 9 across
`AppModel` and the daemon. Writing into them while another agent rewrites them
produces a mess neither session can untangle, and the first casualty would be the
work that is not committed. Item 4 (`GET /v1/runs/:id/diff` and `ouro diff
--json`) is the one that is genuinely clear of the collision — the route already
exists at `Daemon.swift:479` returning `API.TextResponse`, and turning it
structured touches only `API.swift`, `Daemon.swift` and `OuroCLI/Commands.swift`.
It was left alone too, because shipping one item out of nine into a tree in this
state is not worth the review cost.

**Nothing was installed.** `make install` builds from this checkout, which
currently contains another agent's half-finished UI. It would have put that on
the operator's menu bar. The installed app and daemon that were running at the start are
the same two still running, untouched: no strays were created and none were left.

**Not verified without the screen:** the exit animation itself. `Vanished` is
covered by its seven tests and the verb table by five, but a strike-through that
plays over 420ms is a thing you look at. The delete path underneath it is proven
from the CLI.

---

## Progress log, second pass — 2026-07-31

Scope narrowed to what a second live session was not holding. Five files were off
limits for the whole of this pass:

```
zero/Sources/ZeroApp/ProjectsDrawer.swift   zero/Sources/ZeroCore/Digest.swift
zero/Sources/ZeroApp/RowActions.swift       zero/Tests/ZeroCoreTests/DigestTests.swift
zero/Sources/ZeroApp/QuickCapture.swift
```

None of them was opened. Nothing was stashed, reverted or bulk-added, and nothing
was committed.

### `main` moved, and item 10 now needs a second rebase

Partway through, the other session committed `2542a82` — the tally bar, the
selection rail, the state glyphs. That is why the tree is clean again.

It also means **`ouro merge r-ms8p7hby-ci78` will now fail.** `9b13301` was rebased
onto `748ef29`, which is no longer the tip; `2542a82` rewrote the same three files.
Asked without performing it, using the tool §2 of this document is about:

```
$ git merge-tree --write-tree --name-only main fix/when-i-open-ouroboros-and-right-click-so
→ exit 1, conflicts in ProjectsDrawer.swift, QuickCapture.swift, RowActions.swift
```

`performMerge` would hit that, `git merge --abort`, and mark a verified run failed.
The branch needs re-resolving against the new drawer before it can land. It is
untouched on its branch, and `ouro-prerebase-r-ms8p7hby` still points at the
original three commits.

There is a small joke in this: the first rebase turned three conflicts into a
fast-forward, and thirty minutes later the base moved and turned it back into three
conflicts. Same branch, same command, three different truthful answers in one
afternoon. That is the argument for §2 in one paragraph, and it is why
`MergeVerdict` carries `baseSha` and `branchSha` and is cached under the pair.

### Item 4 — the diff, as data

`GET /v1/runs/:id/diff` returns a `DiffReport`: the two shas, the commits oldest
first, the files with `+n/-n` and a change kind, and the hunks with a kind per
line. `?format=text` still returns git's own patch.

`ZeroCore/DiffReport.swift` holds the model and the parser. The parser is written
against what git emits rather than the format's grammar — `diff --git a/x b/x` is
ambiguous when a path has a space in it, so paths come off the `---` / `+++` lines
and only fall back to the header. Covered: new files, deletions, renames, renames
with no edits at all, binary files, `\ No newline at end of file`, empty context
lines, and paths with spaces.

One real bug came out of writing the tests: a patch's own final newline was being
read as an empty context line, so **every file gained a phantom blank line at the
end of its last hunk**. Fixed, and pinned by a test.

`ouro diff --json` prints the endpoint's bytes rather than re-encoding a decoded
value, so what a script reads and what the diff surface reads cannot drift.

`ouro diff` keeps its output. The one-line shape summary goes to **stderr**, not
stdout: `ouro diff > patch` has always produced something `git apply` accepts, and
a summary line on stdout would have quietly stopped that being true. Verified by
piping stdout alone into `git apply --check`.

### Item 2 — the merge test

`ZeroCore/MergeCheck.swift`. `git merge-tree --write-tree --name-only <base>
<branch>`: no worktree, no index, nothing to abort. Exit 0 clean, 1 conflicts,
anything else is a question that could not be asked — and that third answer is
kept distinct, because "we could not tell" must never render as "it merges".

`MergeVerdict` names both operands and is cached under `baseSha..branchSha`, so a
verdict is reused exactly as long as neither side has moved. A branch already
contained in its base is answered before git is asked, or an already-merged branch
would come back "clean" for the wrong reason.

Exposed three ways: `Run.merge` on the serialized run (so the drawer can read it
without shelling out), `GET /v1/runs/:id/merge-check`, and `ouro merge-check`.

The daemon tests every run a client might render as waiting for you, once, and both
the snapshot and the inbox read that same result. **The inbox stops lying**: a run
whose branch no longer merges says so and names the files, and it no longer offers
`merge` — an action known to fail reads as a verdict, which is how this document
started.

Proven live, against a throwaway daemon on its own `OUROBOROS_HOME`:

```
! conflicts with main  74e23cf0..854d19bd
    shared.txt
→ branch rebased, same run id
✓ merges into main     74e23cf0..bd2cf133
```

The inbox flipped back to offering `merge` on its own, because the pair changed and
the cached verdict stopped describing the repo.

### Item 5 — the diff surface

`ZeroApp/DiffView.swift`, self-contained: commits, then files with their counts,
then hunks with added and removed lines tinted in the green and red this app
already uses. Read-only. Escape closes, via a `.cancelAction` button so it works
whatever has focus. Long lines scroll horizontally rather than wrapping, because a
wrapped diff line stops being a diff line.

Deliberately **not wired to a row** — every call site is in `ProjectsDrawer` or
`RowActions`. It presents from one call:

```swift
DiffView(report: report) { showingDiff = false }
```

### Item 1 — the words

`ready` → `review`, `landed` → `merged`, done in `InboxItem.Kind` and every
consumer outside the off-limits five: the CLI's marks and labels, the notifier's
headlines and colours, the inbox builder and its ranking, the slash commands, the
app's inbox tint and label, the default `notifyOn`, and the README.

The compatibility is the part that would have broken quietly. `notifyOn:
["question","failed","landed","ready"]` is in the live `config.json` right now, and
runs on disk were written with the old words. `Kind.canonical` maps both, the
decoder goes through it, and `Notifier` normalises `notifyOn` — so an untouched
config keeps asking for exactly the notifications it always did. A word from
neither vocabulary is still an error; leniency about two renames is not leniency
about anything.

**Outstanding, one change, blocked on `Digest.swift`:**

```swift
public enum WorkState: String, Codable, Sendable, CaseIterable {
    case ready      →  case review
    case landed     →  case merged
```

plus `rank`, and `label`'s `asking` special case. Then the two `WorkState` arms in
`AppModel.swift`'s `extension WorkState` (`.ready` / `.landed` in `tint`) and the
`.ready` / `.landed` references in `ProjectsDrawer.swift` and `RowActions.swift`.
§2's `conflicts` wants to be a `WorkState` case in the same edit, reading
`run.merge` — the data is already on the run and already tested.

### Verification

`swift build` clean for `ouroboros-zero`, `ouro` and `ourod`. `swift test` green:
**194**, up from 154 on `2542a82` — 40 new, covering the diff parser, the merge
verdict against real throwaway repositories, and the old-spelling compatibility.
Both run in the real checkout, not only in the scratch worktree.

Endpoints exercised against a real daemon built from this branch, on a sandbox
`OUROBOROS_HOME` with its own socket, so the live daemon was never touched. The
sandbox and the scratch worktree are gone; `git worktree list` is back to the
checkout plus the three run worktrees.

**Not installed, on purpose.** `make install` would have replaced the menu-bar app
mid-session for someone using it.

**Not verified without the screen:** `DiffView` has never been rendered. It
compiles and its data is real, but no pixel of it has been looked at, and it has no
call site yet by instruction. Treat its layout as unreviewed.
