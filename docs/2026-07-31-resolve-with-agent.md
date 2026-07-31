# 2026-07-31 — the agent that wrote it resolves it

The operator, looking at two runs sitting in `conflicts`:

> "we need 'fix with agent' which opens THAT same session conversation and tells the agent
> automatically, to look into the conflict and if obvious/easy, fix it. if not, ask the user
> to decide and give direction."

A `conflicts` row currently offers `diff` and `rebase`. `rebase` hands the work back to
you, which is the one outcome Ouroboros exists to avoid.

---

## Why resume rather than dispatch fresh

The agent that wrote the lines is the only party that knows why it wrote them. A fresh
agent reading `<<<<<<<` is inferring intent from syntax. The original one is remembering a
decision it made an hour ago, and can say "I moved that check into `WorkState.of` because
the inbox and the drawer were disagreeing" instead of guessing which side to keep.

Both runs in `conflicts` today already carry a conversation id, so this costs nothing to
attempt and degrades cleanly when the harness has lost the session.

## 1. Obsolete is not conflicting

`r-ms8p7hby-ci78` shows `conflicts`. Its work is already on `main` — `Vanished.swift` and
`RowVerbs.swift` are both there, re-applied by hand rather than merged. The branch survived,
so `merge-tree` still reports conflicts, and the drawer asks you to resolve something that
is finished.

A state that is a guess rather than a check is the bug this whole line of work started with.
Before calling a branch `conflicts`, ask whether it is spent:

```
git cherry <base> <branch>
```

Every line prefixed `-` means that commit's change is already upstream. All `-` means the
branch has nothing left to give.

- nothing left → **`obsolete`**, its own state, offering `discard` (delete the branch, drop
  the worktree, close the run) and `diff`.
- something left, does not merge → `conflicts`, as now.

`obsolete` is quiet, not a warning. Nothing went wrong.

## 2. `resolve`

A verb on `conflicts` rows, sitting first: `resolve · diff · rebase`.

It dispatches a **new supervised run that resumes the original conversation** in that run's
existing worktree, on its existing branch. Same supervision as any run: shim, log, verify
gate, inbox. It is not a special case, it is a run whose first message is a conflict report.

The seed message says, in this order:

- your branch no longer merges into `<base>`
- the two commits compared, by sha
- the conflicting files
- rebase onto `<base>` and resolve
- where the resolution is obvious, take it
- **where it is not, stop and ask.** Do not guess, and do not pick a side to make the
  build pass. Say what the two sides each want and what you need decided.

Asking is already wired: an agent that asks lands in the needs-you group and you answer
with `ouro reply <run> "…"`. No new mechanism.

When it finishes, the verify command runs and the merge is re-tested, so the run comes back
as `review` if it worked and `conflicts` again if it did not. It never merges itself.

## 3. The plumbing

`Agents.resumeArgv` only builds an interactive `claude --resume <id>`. Resolving needs a
non-interactive variant carrying a prompt:

- claude → `claude --resume <id> -p "<seed>"`
- codex → `codex resume <id> "<seed>"`

Returning nil for a harness that cannot resume is fine, and the row must then say so rather
than offering a verb that does nothing.

If the harness has forgotten the session — a resume that exits non-zero without output —
fall back to a fresh agent with the same seed plus the issue body, and **say in the run
which one it was**. A resolution by an agent that never saw the original reasoning is worth
less, and you should be able to tell them apart.

## 4. Endpoint and verb

`POST /v1/runs/:id/resolve` → returns the new run's id, or an error naming why not
(not conflicted, no branch, harness cannot resume). `ouro resolve <run>`. The drawer verb
calls the endpoint. No private powers.

---

## Constraints

- The agent never lands its own work. `resolve` produces a branch that merges, not a merge.
- Every UI action is an endpoint plus an `ouro` verb.
- Copy follows the house style: lower case, no em-dashes, no label that explains itself.
- `swift build` clean for three products, `swift test` green — **223 now, do not regress**.
- One app, one daemon when you finish. Never launch from `.build/debug`.

## Checklist

- [x] **1** — Staleness check and `obsolete` as its own state. `git cherry` is in it
  and is not enough on its own — see the log.
- [x] **2** — `obsolete` rows offer `diff` + `discard`; discard removes the branch and
  the worktree, closes the run, and refuses on anything still carrying work.
- [x] **3** — `Agents.resumeArgv(…prompt:)`, non-interactive per harness.
- [x] **4** — `POST /v1/runs/:id/resolve` + `ouro resolve <run>`, and `discard` beside it.
- [x] **5** — `SupervisedPrompt.resolve`, in §2's order, with the instruction to ask.
- [x] **6** — Fresh-agent fallback, recorded as `resumeMode` on the run. Its trigger is
  not the one this document specified; see the log.
- [x] **7** — `resolve` first on `conflicts`: `resolve · diff · rebase`.
- [x] **8** — Re-verified and merge-re-tested on finish. Proven live: `conflicts` →
  `resolve` → `review`.
- [x] **9** — 36 new tests: staleness against real repositories, the verdict-to-state
  transitions, resume argv per harness, the seed, and the lost-session detection.
- [x] **10** — `swift build` clean for all three, `swift test` **259**, installed,
  daemon restarted, app relaunched. One app, one daemon.

## The test bed

Two real runs, deliberately left unresolved:

- `r-ms8p7hby-ci78` — should be detected **obsolete**, not conflicted.
- `r-ms8v9hq9-5xj6` — "merged items should get a strikethrough", genuinely conflicts in
  `RowActions.swift` and `Digest.swift`. This is the one `resolve` has to actually fix.

Do not resolve them by hand. They are the proof.

---

## Progress log — 2026-07-31

All ten. The one that mattered is item 8, and it was proven the only way it can be:
`resolve` was run for real on `r-ms8v9hq9-5xj6` and the branch it produced merges.

### Item 1 — and `git cherry` does not answer this

§1 says `git cherry <base> <branch>` decides whether a branch is spent. It was the
first thing tried, against the branch this document names, and it says the opposite:

```
$ git cherry main fix/when-i-open-ouroboros-and-right-click-so
+ 9b13301
```

`+` — not upstream. `git cherry` compares patch-ids, and nothing about that branch's
patch is on `main`. The third pass of the review-and-diff document says why in its own
words: the branch was **read and re-implemented**, not replayed, because the base had
moved twice underneath it. `Vanished.swift` and `VanishedTests.swift` came across
byte-identical; the other six files were re-derived and `main` has gone on editing
them since. There is no patch left to recognise.

So the check is two questions, and the type says which is which:

- **`git cherry`** — every commit has a patch-equivalent upstream. Exact. It is the
  right answer whenever the commits themselves went in, which is the common case
  (`ouro merge`, a cherry-pick, a rebase-and-land), and it is implemented as specified.
- **content** — for every file the branch touched, how many of the lines it adds does
  the base's own copy already have. This is the re-implemented case, and it is a
  measurement, so it is reported as one. `Staleness` carries the numbers and the row
  prints them: `551 of 590 lines are already on the base`.

`Staleness.carriedOver = 0.9` is the one judgement in `MergeCheck.swift` and it is
named, commented and tested rather than buried in an `if`. The two branches this was
built against sit at **93%** and **13%** — a seven-fold margin, which is the room the
bar has to fall inside. It is deliberately not 100%: the base has usually gone on
editing the very lines it took, so a re-applied branch is never a subset of it. Of the
39 lines `main` was missing, every one is a line `main` has superseded — `case merge,
undoMerge, stop` where `main` now reads `case merge, rebase, undoMerge, stop`,
`XCTAssertEqual(RowVerb.allCases.count, 23)` where `main` says 27. Not one of them is
work still owed.

**The guard that makes a measurement safe to act on:** a branch that creates a file the
base has never seen is never spent, whatever the ratio says. That is exact, it is
checked first, and it is what stops `discard` ever being pointed at real work.

Both live branches, through the installed daemon:

```
$ ouro merge-check r-ms8p7hby-ci78
! nothing left on fix/when-i-open-ouroboros-and-right-click-so  b241a487..9b133019
    551 of 590 lines are already on the base
    ouro discard r-ms8p7hby-ci78

$ ouro merge-check r-ms8v9hq9-5xj6
! conflicts with main  b241a487..e1a21e73
    zero/Sources/ZeroApp/RowActions.swift
    zero/Sources/ZeroCore/Digest.swift
    ouro resolve r-ms8v9hq9-5xj6   ·   ouro rebase r-ms8v9hq9-5xj6
```

`obsolete` is asked **before** `conflicts`, because a spent branch conflicts exactly
like a live one. It is also asked before `review`: a spent branch can merge cleanly
too, and offering `merge` there produces an empty commit and a row claiming a fix
landed. It stays out of the needs-you group — letting a branch go is housekeeping, and
a group that means "you need to check these" must not fill up with things nobody does.

### Item 2 — `discard`

`POST /v1/runs/:id/discard`, `ouro discard <run>`. Worktree removed, branch deleted,
run closed. Two things it does that the spec did not ask for and both earn their lines:

- **It refuses unless the branch is spent.** This is the one verb here that destroys
  something, so it is not allowed to act on a guess: `fix/live still has work on it —
  resolve or rebase it instead`.
- **It writes the tip sha into the run's note.** A deleted branch nobody wrote down is
  a deleted branch nobody can get back.

The run goes to `abandoned`, not `succeeded`-with-no-branch. Left succeeded it would
have flipped straight to `review` and offered a merge of nothing, which is the same
class of lie as calling an untested branch ready.

Proven against a throwaway daemon on its own `OUROBOROS_HOME`, with a re-applied
branch built for the purpose — the real `r-ms8p7hby-ci78` was **not** discarded. It is
the evidence for item 1 and it is yours to let go of.

### Items 3 to 5 — resume, and what it is told

`Agents.resumeArgv(harness:template:sessionId:prompt:)` sits beside the interactive
one rather than replacing it:

```
claude → claude --resume <id> -p "<seed>"
codex  → codex exec resume <id> "<seed>"
```

**One deliberate departure from §3**, which specifies `codex resume <id> "<seed>"`.
That is the TUI. A supervised run gets `/dev/null` on stdin, so a harness that opens
its interactive shape reads EOF and hangs with an empty log — the exact trap the `-p`
in `Config.defaultAgents` exists to avoid, and the comment there records that it cost
an evening. `codex exec resume` is the same conversation without a TUI. A test asserts
both shapes are the non-interactive ones, by name.

The seed is `SupervisedPrompt.resolve`, in §2's order: no longer merges, the two shas,
the files, rebase and resolve, obvious → take it, not obvious → **stop and ask**. The
last one is pinned by its own test, including the sentence that has to be there —
*do not pick a side to make the build pass* — because a green build on the wrong half
of a conflict is worse than an unresolved branch, since it looks finished.

A resumed agent is not read its own issue back. A fresh one is, and is told plainly
that it is reading somebody else's work.

### Item 6 — and the fallback's trigger is not silence

§3 says the fallback fires on "a resume that exits non-zero without output". It does
not. Probed:

```
$ claude --resume 00000000-1111-2222-3333-444444444444 -p "say hi"
No conversation found with session ID: 00000000-1111-2222-3333-444444444444
exit=1
```

It exits 1 and **says so in a sentence**. Reading only for silence would have meant the
fallback never fired once — every lost session would have gone into the inbox as "the
agent exited 1 without committing anything", which is exactly the unhelpful failure the
`diagnose` function already exists to stop. `Supervisor.lostTheConversation` reads for
the harnesses' own wording and keeps silence as a second shape, since a harness can
still die before printing.

**A second bug, found by running it rather than reading it.** The check was first
written into the `!hasWork` arm of `finalize`, next to the other "the agent did
nothing" cases. That arm is unreachable for a resolve run: the branch it is handed
already has commits, so `hasWork` is true however little the agent did. It is now step
2 of `finalize`, before the work test, guarded by `resumeMode == "resumed"` and by the
agent having written no result file.

End to end against the sandbox, with a stub harness standing in for a `claude` that has
forgotten the session:

```
r-ms8xtvwy-ga69 | abandoned | resumeMode: resumed
    claude could not reopen that conversation — starting fresh
r-ms8xtw8g-8j6j | awaiting  | resumeMode: fresh
    main renamed the field this branch adds; keep the branch's name or main's?
```

The fresh agent asked, and the question is in the inbox with `ouro reply` under it.
`resumeMode` is on the run and on the wire, so a resolution by an agent that never saw
the original reasoning is tellable from one by the agent that did.

### Item 8 — the live run

```
$ ouro resolve r-ms8v9hq9-5xj6
✓ claude is back on fix/merged-items-should-get-a-strikethrough-  r-ms8xa1ix-z56n
```

Nine minutes, headless (`terminal: silent`), nothing on screen. It rebased
`e1a21e7` (on `95921e0`) onto `b241a48` as `b863d2e`, resolved both files, ran
`swift build && swift test` itself — 224 green — and stopped. The gate re-ran it, the
merge was re-tested, and the run came back `review`:

```
$ ouro merge-check r-ms8xa1ix-z56n
✓ merges into main  b241a487..b863d2ea
```

**It did not merge itself**, and it was not asked to: `finish` is inherited from the
run being rescued, which was `leave`. It is sitting in the inbox with `ouro merge`
under it. That is your click.

The half worth reading is its own summary, because it is the argument for resuming
rather than dispatching fresh, in the agent's own words:

> Rebased onto main and resolved both conflicts by keeping each side: **my
> `WorkState.isMerged` helper was dropped** because main's rename made `.landed` into a
> case literally called `.merged`, so the rows now test `pip.state == .merged` directly
> […] The redundant test class went away and its one uncovered case — an open PR counts
> as merged — moved into main's `WorkStateWordsTests`.

"My helper was dropped, because the rename made it redundant" is not a sentence a fresh
agent can write. It would have seen two definitions of the same idea in a conflict
marker and had to guess which was wanted; this one knew it had written the helper an
hour earlier and that `main` had since made it unnecessary. It also noticed its own
test class had become a duplicate and folded the one case that was not, which is
tidying nobody asked for and nobody would have got from a stranger.

### Item 7 — the verbs

`conflicts` is `resolve · diff · rebase`. `resolve` first because it is the only one
that ends the situation, `rebase` last because handing the work back to you is the
outcome this product exists to avoid. `obsolete` is `diff · discard`. Both pinned,
including that no other state offers either verb — `discard` deletes a branch, and
`obsolete` is the only state that has checked there is nothing on it.

`RowVerbTests` asserts exact case counts on purpose, so the two new verbs forced the
decision: **29 cases, 10 that hand off, 19 that keep the panel**. `resolve` hands off
and gets `fix`'s half-second beat, because it starts an agent. No test was deleted.

**One name was taken.** `ouro resolve` was an alias for `ouro done`. It is its own verb
now; `done` is unaffected and was always the primary spelling.

### Verification

`swift build` clean for `ouroboros-zero`, `ouro` and `ourod`. `swift test` **259**, up
from 223 — 36 new, no deletions. The staleness tests build real repositories and ask
real git, including the case that nearly slipped through: a cherry-pick onto an
unchanged parent produces the *identical commit object*, so the branch is simply an
ancestor and there is nothing to measure. The base has to move first.

`make install`, daemon restarted, app relaunched with `open -g` from
`zero/build/Ouroboros Zero.app`. One app, one daemon, checked with
`ps -Ao pid,args | grep "[o]uroboros-zero"`. The sandbox daemon and its repo are gone;
`git worktree list` is the checkout plus the same four run worktrees it started with.

**Not verified without the screen.** No pixel of any of this has been looked at. The
`obsolete` row's glyph, its grey, the `resolve` button on a conflicting row and the
orange it is drawn in are all unreviewed — they are three lines each on top of
machinery that was looked at in the previous pass, and every one of them is driven by
the same tested tables as the states beside it, but that is an argument, not a
screenshot. `xmark.bin` in particular is the one SF Symbol here nobody has confirmed
renders.

**Left standing on purpose.** `r-ms8p7hby-ci78` still has its branch, its worktree and
its tag `ouro-prerebase-r-ms8p7hby`. It reads `obsolete`, which is the point of item 1,
and discarding it would have deleted the only live example.
