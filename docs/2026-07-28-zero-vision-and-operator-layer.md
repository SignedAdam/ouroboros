# Ouroboros Zero — vision, architecture, and the operator layer

**Status:** design draft, 2026-07-28. Expands the original brainstorm notes into a buildable shape.
**Supersedes:** nothing. Extends `2026-07-03-v2-tracking-and-skill.md` (the embedded library stays).

---

## 1. The read — what this actually is

**Thesis.** Coding stopped being the bottleneck. Specifying and dispatching work became the
bottleneck. Ouroboros Zero exists to drive the cost of *dispatch* to zero, so throughput is
limited only by how fast you can think.

Every item in the brainstorm is the same move — collapse the gap between a thought and that
thought being work in flight:

| The gap | Collapsed by |
|---|---|
| "I see a bug in my app" → agent fixing it | Ouroboros v1/v2 (floating button) — **done** |
| "I notice anything, anywhere, in any project" → agent fixing it | Zero (menu-bar item) |
| "I have an idea" → it's somewhere I'll actually see it | Ideas + Discord |
| "New idea" → repo, roadmap, agent working | Project wizard |
| "Project exists" → it builds itself overnight | Roadmap + loop (claude-loop, absorbed) |
| "An AI notices something" → work in flight without me | Operator API + Sentinel |

The name is already correct: output feeds input. Fixes generate issues, issues generate
roadmap tasks, roadmap tasks generate fixes. Zero is the machine that closes the circle.

### The psychology, named

These aren't aspirations — they're already visible in the existing code, and they are the real
spec. Violating one of them kills the product regardless of feature count.

1. **Never steal attention.** The single most consistent decision in the codebase.
   `TerminalLauncher` has a whole comment about how agents must never open a window in the
   user's own tmux session ("a terminal spawned on top of mine"). Cinema windows close
   themselves. Launch scripts use `zsh -f` so the user's rc-file session picker can't hijack a
   finished tab. **Rule: Ouroboros is invisible until summoned, and never demands anything.**
   No badge counts, no nags, no modal that appears because a background agent finished.

2. **Capture must cost under five seconds.** The value of the floating button isn't that it
   files issues — it's that it files issues *without leaving the app you're in*. Anything that
   makes you pick a project from a list, name a branch, or choose an agent before you can type
   is a regression. **Everything after "describe the thing" must have a working default.**

3. **Walking away requires trust, and trust requires legibility.** "File ten issues, fire ten
   agents, walk away" is only true if coming back is legible. Today it isn't — a fix is
   fire-and-forget into a terminal. At one concurrent agent that's fine. At ten across five
   projects it's unusable. **Run supervision is not a nice-to-have; it's what makes the
   headline claim true.**

4. **Files are the substrate, not a database.** `.issues/*.md`, `ROADMAP.md`, cycle notes.
   This is why agents can participate as first-class citizens — they read and write markdown
   natively, and git tracks everything. The temptation with a global app is a SQLite database
   of issues. **Resist it. The index is a cache; the markdown is the truth.** Anything Zero
   knows must be reconstructible by `find`-ing the disk.

5. **Ambient, not administrative.** This is not a project-management tool. Those get adopted
   and then abandoned, half-maintained, in every dev directory. The
   difference is that a PM tool asks you to maintain it. Ouroboros must *consume* intent and
   emit work.

### The failure modes to design against

- **It becomes a second job.** An inbox with 200 unread items that guilt-trips. Mitigation:
  the inbox contains *decisions only* — things that cannot proceed without a human. Ideas are
  allowed to rot silently. No unread badges. Auto-archive after N days.
- **Review becomes the new bottleneck.** If capture friction goes to zero, you file 40
  issues a day, and 40 branches land unreviewed. This is the real risk and it is *created* by
  the product working. Mitigation: the verification gate and the optional reviewer pass
  (§13) are not phase-8 polish — they're what makes volume safe.
- **The GUI grows private powers.** The moment the menu-bar app can do something the API
  can't, the AI-operator story dies. Mitigation: §3's invariant, enforced by building the GUI
  *on* the API.

---

## 2. Where we are, precisely

**Have:**
- Engine: `IssueStore` (v2 frontmatter format, four status folders, list/read/updateBody/setStatus),
  `Agent` (argv templates for claude/codex/gemini/pi), `WorktreeManager` (`fix/<slug>` off base,
  dedup suffixes), `TerminalLauncher` (tmux-tab and cinema modes), `seedPrompt` (four
  worktree × finish variants with auto-resolution), screenshot capture + annotation.
- `skills/ouroboros-integrate/SKILL.md` — drives an agent to wire it into any app.
- The mark, the brand.
- `claude-loop` — roadmap schema, `/loop` prompt, cycle-note discipline. Proven, published,
  but currently a *convention*, not a system: nothing parses the roadmap, nothing supervises
  the loop, nothing can pause it.

**Missing for Zero — the gap list:**
- No global surface. Ouroboros only exists inside apps that integrated it.
- No process model. `handToAgent` launches a terminal and returns `true`. Nobody knows what
  happened after that.
- No cross-project view. `IssueStore` is scoped to one `rootDir`.
- No headless entry point. Everything is a Swift API call from inside a GUI app.
- No notion of ideas, projects-as-objects, or roadmaps-as-objects.
- No API, no CLI.

---

## 3. The shape: one core, many faces

```
        ┌──────────────┐  ┌──────────┐  ┌───────────────┐  ┌──────────────┐
        │ Zero         │  │  ouro    │  │  MCP façade   │  │  Sentinel    │
        │ (menu bar)   │  │  (CLI)   │  │ (agent tools) │  │ (watcher)    │
        └──────┬───────┘  └────┬─────┘  └───────┬───────┘  └──────┬───────┘
               └───────────────┴────────────────┴─────────────────┘
                                       │  local API (unix socket + loopback HTTP)
                              ┌────────┴─────────┐
                              │      ourod       │   registry · index · run supervisor
                              │    (daemon)      │   scheduler · event bus · loop driver
                              └────────┬─────────┘
                                       │
        ┌──────────────────────────────┼──────────────────────────────┐
        │  ~/.ouroboros/  (state)      │   <project>/.issues/*.md     │  (truth)
        │  registry, runs, ideas, index│   <project>/docs/ROADMAP.md  │
        └──────────────────────────────┴──────────────────────────────┘
                                       │
                              ┌────────┴─────────┐
                              │ embedded package │  in-app composer (Atlas, …)
                              └──────────────────┘  posts to daemon if up, else direct
```

**Two invariants.**

1. **No private powers.** Every capability the menu-bar app has is an API call. The GUI is a
   client. This is what "an operator API for AI to use it fully" actually requires — not an API
   bolted on beside the app, but the app built on the API.
2. **The daemon is optional for writes.** `ouro i "…"` writes the markdown file even if `ourod`
   is dead. Files are truth; the daemon adds supervision, not authority. Degrade, never block.

**Embedded package's new role:** unchanged UX, but `submit` and `handToAgent` first try the
daemon (so in-app issues land in the global index and their runs are supervised). If the socket
isn't there, it does exactly what it does today. Atlas keeps working, untouched.

---

## 4. Data model

Five objects. Everything else is a view over them.

```
Project   id, name, path, baseBranch, defaultAgent, verifyCmd, roadmapPath,
          policy{ autonomy, maxParallel, allowLoop, protectedPaths[] }, lastUsed

Item      id, kind: idea|issue, project?, title, body, status, created,
          path (the .md on disk), attachments[], source: human|app|cli|operator,
          dedupeKey?, links[]                       # an idea is an issue without a home yet

Run       id, project, item?, kind: fix|cycle|scaffold|plan|freeform, agent,
          cwd, worktree?, branch?, base, finish: merge|pr|leave,
          status: queued|running|awaiting|verifying|succeeded|failed|abandoned,
          started, ended, exitCode, logPath, resultPath,
          result{ summary, prUrl?, commits[], filesChanged[], question? }

Roadmap   project, phases[ { n, title, goal, tasks[ {id,title,status,notes} ] } ],
          decompositionQueue[], derived: progress, currentTask

Proposal  id, project?, title, body, source (operator name), confidence,
          dedupeKey, evidence[] (screenshots, file refs), state: pending|accepted|dismissed
```

**Ideas and issues are the same object at different confidence levels.** Don't build two
systems. `promote` sets `kind` and assigns a project; that's the whole operation.

### On-disk layout

```
~/.ouroboros/
  ourod.sock            # the API
  config.toml           # global prefs, agent definitions, notification targets
  registry.json         # projects (cache of the source of truth: the dirs themselves)
  index.db              # SQLite — pure cache over .issues/ + roadmaps. Deletable.
  ideas/*.md            # global ideas without a project yet
  runs/<run-id>/
    run.json            # status transitions, written by the shim
    log                 # full tee'd output
    result.json         # written by the AGENT, per the seed prompt
  tokens.json           # operator capability tokens

<project>/
  .issues/{new,planned,done,cancelled}/*.md   # unchanged, committed
  .issues/attachments/*.png                   # unchanged
  docs/ROADMAP.md                             # claude-loop schema
  docs/cycles/NN_cycle_*.md                   # claude-loop discipline
  .ouroboros/                                 # gitignored: worktrees, run symlinks
```

---

## 5. The three loops

Zero's job is to make these one machine rather than three habits.

- **Fix loop** — issue → agent in a worktree → verified → merged → issue moved to `done`.
  *Exists today.* Zero adds supervision, global reach, and the inbox.
- **Capture loop** — thought → idea → issue → project. *New.* The wizard is just the far end
  of this: an idea big enough that promoting it creates a repo instead of a file.
- **Build loop** — roadmap → cycles → shipped app. *Exists as claude-loop discipline.* Zero
  adds parsing, driving, pausing, and guardrails.

They share one substrate (markdown), one supervisor (`ourod`), one inbox, one notification
path. A roadmap task that fails becomes an issue. An issue too big to fix becomes a roadmap
phase. That's the circle.

---

## 6. Run supervision — the missing primitive

This is the highest-leverage single change in the whole document. Everything else depends on it.

**The shim.** Keep cinema mode exactly as it is — the splash, the live TTY, the self-closing
window. Change one line: instead of `exec <agent> <prompt>`, run
`exec ouro run-shim <run-id> -- <agent> <prompt>`. The shim:

- writes `run.json` status transitions (`running` → `succeeded`/`failed`)
- tees the TTY to `runs/<id>/log` (keeps the interactive terminal intact)
- records exit code and duration
- on exit, triggers the **verification gate**

Same aesthetic, fully observable. Works identically in tmux-tab mode.

**Structured results, not output parsing.** The seed prompt gains a final instruction: write
`$OURO_RUN_DIR/result.json` with `{outcome, summary, pr_url, files_changed[], question?}`
before finishing. This is harness-agnostic (claude, codex, pi, gemini all can write a file) and
infinitely more robust than scraping terminal output for markers.

**`awaiting` status.** The seed prompt already says "if it is NOT clearly actionable, note
what's ambiguous and stop". Extend it: write `result.json` with `outcome: "needs-input"` and
the question. The shim sees it, marks the run `awaiting`, and the run appears in the inbox as
a question with a text field. `ouro reply <run> "…"` (or the inbox UI) resumes it — a new run
seeded with the original context plus the answer.

**The verification gate.** A run is not `succeeded` because the process exited 0. After exit,
`ourod` runs the project's `verifyCmd` (`swift build`, `pnpm test`, `go build ./...`) in the
worktree. Green → `succeeded`, and the finish action (merge / PR) proceeds. Red → `failed`,
branch preserved, lands in the inbox with the build output. This is the difference between
"ten agents ran" and "ten fixes landed".

**The scheduler.** Runs are queued, not spawned immediately. Global `maxParallel` (default ~4)
and per-project limits. Ten issues filed in a burst become an orderly queue instead of ten
agents thrashing one machine and racing on the same base branch.

---

## 7. The Needs-You inbox

The psychological centerpiece, and the thing that produces the Jarvis feeling.

The inversion: instead of you pulling status from ten terminals, the system pushes you the
*only* items that cannot proceed without a human. The job becomes draining a queue that is
usually empty.

Exactly five things can be in the inbox:

1. **Question** — a run is `awaiting`; the agent needs a decision. → reply inline.
2. **Failed** — a run failed or the verification gate went red. → view diff / retry / drop.
3. **Landed** — a fix merged, or a PR is open. → review / undo / dismiss. (Auto-dismiss after
   N days if a project is configured `autoTrust`.)
4. **Proposal** — an operator (Sentinel, another agent) suggests work. → fix it / dismiss.
5. **Loop stopped** — a build loop hit a guardrail or finished its roadmap. → resume / inspect.

Nothing else. Not "issue filed", not "run started". Notifications mirror the inbox and nothing
else: Discord (the webhook already exists) for everything, macOS notification only for
*Question* and *Failed*, opt-in. **Never a window that takes focus.**

---

## 8. Ouroboros Zero — the app

A menu-bar item (the "control center menu"). The mark, subtly animating while runs are in
flight — ambient status, no numbers.

**Click → the panel:**
- **Quick capture** at the top, focused, ready to type. One field. Project pre-inferred.
- **Projects** below — recent-first, each with a live badge (`2 running`, `1 needs you`).
- **Inbox** if non-empty.
- **New Project…** button.

**Global hotkey → quick capture from anywhere.** Captures context automatically:
- screenshot of the frontmost window (the annotation kit already exists),
- the frontmost app / terminal cwd → **infers the project** (see below),
- optional voice: hold the hotkey, talk for fifteen seconds, get a transcribed issue. (The
  `.whisper` dir in the old Ouroboros repo suggests this was already on your mind. Talking is
  the lowest-friction capture that exists, and it fits principle #2 better than typing.)

**Project inference — the "no picker" unlock.** In order: (a) frontmost terminal's cwd → walk
up to the git root → match registry; (b) frontmost app's bundle → registry mapping; (c) last
used. Show the inferred project as a small chip you can click to change. You should almost
never have to.

**Triage pass (optional, per project).** Before dispatch, a cheap model turns the ten-second
brain-dump into a well-formed issue: repro steps, likely files (from a quick repo grep), and
*at most one* clarifying question shown inline in the composer while you are still there.
The current seed prompt opens with "It may be ill-defined — decide first whether it is clear
enough" — that's a workaround for a problem better solved at capture time, while the human is
still in the room. This is cheap and should measurably raise the fix success rate.

**Fleet view** — a separate window: a grid of live agent panes, cinema mode multiplied. Not
functionally necessary. It is the Jarvis image, it makes ten concurrent agents *feel* good
rather than chaotic, and it costs little on top of the shim's log tee.

**Project wizard** (from the brainstorm, made concrete):
- Step 1: name; suggested directory (editable); description; toggles — *create directory*,
  *create GitHub repo* (public/private), *initial agent* (Claude Code / Codex / none).
- Step 2: **roadmap** — "Let AI draft it" / "I'll write it" / "Skip". Drafting spawns a
  **plan run**: an agent that writes `docs/ROADMAP.md` in the claude-loop schema (phases with
  concrete tasks; later phases as one-line decomposition stubs), tuned to the stack. You
  review and edit it in the wizard before accepting.
- Step 3: **kick off** — "Start the build loop" / "Open a shell with <agent>" / "Just finish".
- Always: the project is registered, so it's at the top of the panel next time.

Note the wizard ships **no boilerplate**. Phase 1 of the roadmap *is* "repo layout and
skeleton" — exactly as described in the brainstorm. Templates rot; an agent reading the
roadmap doesn't.

---

## 9. The CLI

`ouro` is a thin client of the API. It is not a convenience wrapper — it's a co-equal face,
and it's the surface a shell-native agent will actually use.

```
ouro                              # interactive: recent projects → quick issue
ouro i "login button does nothing"        # file into the inferred project
ouro i -p atlas "…" --fix                # file and dispatch in one shot
ouro i --stdin --title "…"                # for agents / pipes

ouro fix <issue> [--agent codex] [--no-worktree] [--pr] [--watch]
ouro runs [-w]                    # table; -w = live
ouro log <run> [-f]
ouro reply <run> "use the second approach"
ouro stop <run>

ouro inbox                        # the needs-you queue
ouro ok <run> | ouro drop <run>

ouro idea "webhook replay tool"   # global or -p project
ouro ideas | ouro promote <idea> [-p project | --new-project]

ouro new <name> [--headless --desc … --github private --roadmap ai --loop]
ouro projects [add <path> | rm <id> | set <id> verify="swift build"]

ouro roadmap [-p project]         # progress view: phases, current task, % done
ouro loop start|pause|resume|stop|status [-p project]

ouro watch on|off                 # the Sentinel
ouro serve mcp                    # MCP façade on stdio
```

`ouro i` is the money command — it should be muscle memory, and it should work from inside any
repo with zero flags.

---

## 10. The operator API

**Principles.**
1. **Total coverage.** Anything the GUI does, the API does. Enforced by construction.
2. **Local-first.** Unix socket at `~/.ouroboros/ourod.sock`; optional loopback HTTP with a
   bearer token for tools that can't do sockets. Never bound to a non-loopback interface by
   default.
3. **Capability scopes.** Tokens carry scopes: `issues:read`, `issues:write`, `runs:read`,
   `runs:spawn`, `projects:write`, `loops:control`. **A screen-watching agent should not get
   `runs:spawn`.** It gets `proposals:write`. Autonomy is a dial, per project, that you turn
   up once you trust a given operator — not a default.
4. **Propose vs. execute.** The central safety primitive. An operator posts a *proposal*; it
   lands in the inbox. A project with `policy.autonomy: auto` promotes matching proposals to
   runs automatically. Same API, different trust level, one config line apart.
5. **Idempotency and dedup are mandatory.** A screen watcher will notice the same misaligned
   button forty times in an hour. Every write takes a `dedupeKey`; the daemon suppresses
   repeats and near-duplicates (title similarity + same project + open state). Without this
   the Sentinel is unusable on day one.
6. **Streaming.** `GET /v1/events` (SSE) so operators and the GUI react rather than poll.

**Endpoints.**

```
GET    /v1/projects                     POST /v1/projects           # register or create
GET    /v1/projects/{id}                PATCH /v1/projects/{id}     # policy, verifyCmd
GET    /v1/projects/{id}/roadmap        POST /v1/projects/{id}/roadmap/draft

GET    /v1/issues?project=&status=&q=   POST /v1/issues             # +attachments, dedupeKey
GET    /v1/issues/{id}                  PATCH /v1/issues/{id}       # body, status
POST   /v1/issues/{id}/fix              → Run

GET    /v1/runs?status=&project=        GET  /v1/runs/{id}          # + log tail
POST   /v1/runs/{id}/stop               POST /v1/runs/{id}/reply
POST   /v1/runs                         # freeform run: arbitrary prompt in a project

GET    /v1/inbox                        POST /v1/inbox/{id}/resolve

GET    /v1/ideas                        POST /v1/ideas
POST   /v1/ideas/{id}/promote           # → issue, or → new project

POST   /v1/proposals                    # operators suggest; dedupeKey required
POST   /v1/proposals/{id}/accept|dismiss

POST   /v1/loops                        POST /v1/loops/{id}/pause|resume|stop
GET    /v1/events                       # SSE: run.*, issue.*, inbox.*, loop.*
POST   /v1/capture                      # screenshot + context → issue draft
GET    /v1/health
```

**MCP façade.** `ouro serve mcp` exposes the same surface as MCP tools, so Claude Code and
Codex can call Ouroboros natively without shelling out. Ship both: CLI for shell-native
agents, MCP for tool-native ones. Both are thin — they share the client library.

This is the piece that makes the brainstorm's throwaway line real: *"I want to be able to
easily give ideas to my AI agents… I want them to put that idea in a centralized place."* That
becomes one MCP tool call, or `ouro idea "…"`, from inside any agent session, in any repo.
Discord ping included, because the daemon owns notification.

---

## 11. The Sentinel — the screen-watching operator

The future the brainstorm gestures at: *"an AI agent is watching my screen and finding things
to fix or improve, and just uses Ouroboros."*

**Build it as an external client of the public API, not inside the daemon.** It's the first
real proof that the operator layer is complete, and keeping it outside means it can be
rewritten, swapped, or turned off without touching the core.

**Loop:**
1. Sample: screenshot + frontmost app + window title + (if a terminal/editor) cwd. Every N
   seconds, or on a change trigger.
2. **Cheap gate.** A small model answers one question: *is anything here worth acting on?*
   Almost always no. This is what makes the cost sane.
3. **Expensive pass.** On a yes, a strong model writes a proposal: what's wrong, which
   project, evidence (the crop), suggested fix.
4. `POST /v1/proposals` with a `dedupeKey` derived from (project, area, normalized title).
5. It lands in the inbox — or, for projects you have dialed to `auto`, becomes a run.

**Guardrails, non-negotiable:**
- Off by default; a visible, unambiguous indicator when on. (`aura`'s presence overlay is the
  right precedent — the same honesty principle.)
- **App/domain blocklist** — password managers, banking, DMs, anything not in a registered
  project. Blocklist evaluated *before* the screenshot is retained, not after.
- Screenshots retained only as long as the proposal is pending, then deleted.
- Hard rate limits: max proposals/hour, max/project/day. Silence is the correct default output.
- `runs:spawn` withheld until you explicitly grant it per project.

The bar for this feature is high: a proposal you dismiss is worse than nothing, because
dismissal costs attention — the one resource the whole product protects. Ship it last, tune
precision hard, and be willing to let it produce two proposals a day.

---

## 12. Loops absorbed — roadmaps as objects

claude-loop is a proven discipline that currently lives only as a prompt. Absorbing it means
three additions:

**Parse.** `ourod` reads `docs/ROADMAP.md` into the `Roadmap` object (the schema is already
regular: `## Phase N`, `- id: / title: / status: / notes:`, decomposition queue). This yields
progress — phases done, current task, % complete — visible in the panel and via
`ouro roadmap`. For "walk away and trust", a progress bar over a roadmap is worth more than
any log.

**Drive.** Today the agent self-schedules via `ScheduleWakeup`. That's elegant but it ties
loops to Claude Code, and a self-scheduling loop can't be paused from a menu bar. Alternative:
`ourod` owns the clock — spawn a cycle run, wait for exit + verification, spawn the next.
Harness-agnostic (works with Codex/pi), pausable, observable, and cycle boundaries become real
events. **Recommendation: daemon-driven, with self-paced as a per-project fallback.** See §15.

**Guardrail.** A loop running overnight needs stop conditions, and they belong in project
policy, not in a prompt:
- `maxCycles`, `maxWallClock`
- stop after K consecutive failed verifications
- stop if the same task has been `in-progress` for N cycles (thrash detection)
- `protectedPaths` — migrations, deploy configs, prod secrets: the loop must open a proposal
  instead of editing. (Your own README already says irreversible ops should hand off to a
  human; this is that rule, enforced rather than requested.)
- On any stop: inbox item + Discord.

---

## 13. Guardrails and trust

Volume is only safe if these exist. They are what let you say yes to ten agents.

- **Verification gate** (§6) — exit code 0 is not success; `verifyCmd` green is.
- **Reviewer pass** (optional, per project) — a second agent reviews the diff before merge and
  can block. Cheap insurance on a fix that merges to `main` unattended.
- **Undo** — every run is a branch. "Undo this fix" = revert the merge commit, restore the
  issue to `new`. One click. Trust comes from reversibility more than from correctness.
- **Autonomy dial, per project** — `manual` (always ask) → `assist` (auto-fix, ask to merge) →
  `auto` (fix and merge, tell me after). You set a new project to `manual` and a mature one
  to `auto`. Nothing is globally autonomous.
- **Budget awareness** — token/cost per run recorded, surfaced per day. Ten agents is fun
  until it's invisible spend.
- **Resolution memory** — resolutions accumulate in the issue files. When a new issue touches
  an area with prior resolutions, seed the prompt with them. The tail-eating property, made
  literal, and it compounds.

---

## 14. What we should do

Ordered so that **every phase is independently useful** and the operator layer exists from the
start — the AI can use Ouroboros before the GUI exists.

| Phase | What lands | Why here |
|---|---|---|
| **0** | Headless core: extract `IssueStore`/`Agent`/`Worktree`/`seedPrompt` behind a `Core` module; define `~/.ouroboros/` layout; project registry. | Everything else is a client of this. |
| **1** | `ourod` skeleton + `ouro` CLI: projects, `ouro i`, `ouro fix`, run records. Unix socket API for exactly these. | **Day-one value**: global issue filing from any repo, from the terminal. Ships before any UI. |
| **2** | **Run supervision**: the shim, `result.json`, statuses, verification gate, scheduler, `ouro runs/log/reply`, SSE events. | The keystone. Makes concurrency real. |
| **3** | **Inbox** + notifications (Discord). `ouro inbox`. | Turns supervision into the Jarvis feeling. |
| **4** | **Zero, the app**: menu-bar panel, quick capture + hotkey, project inference, project list, inbox. Built entirely on the API. | The surface from the brainstorm's first section. |
| **5** | **Ideas**: store, `ouro idea`, promote, Discord ideas channel, MCP tool. | Small, self-contained, high daily value. |
| **6** | **Project wizard**: headless first (`ouro new --headless`), then GUI. GitHub repo, AI roadmap draft, kick-off. | Depends on runs (the plan run) and projects. |
| **7** | **Roadmaps + loops**: parse, progress view, daemon-driven cycles, guardrails, pause/resume. | Absorbs claude-loop. Depends on run supervision. |
| **8** | **Operator hardening**: tokens/scopes, proposals + dedup, MCP façade complete, reviewer pass, undo. | Makes it safe to hand the keys to an AI. |
| **9** | **Sentinel**. | Last, deliberately. Precision-tuned. |

**Dogfood it.** Build Ouroboros Zero itself with claude-loop — a `docs/ROADMAP.md` in
`ouroboros-mono` with these phases, and a loop walking it. By phase 7 the loop driving Zero's
own development is running *inside* Zero. That's the best possible proof, and it's also just
the fastest way to build it.

**Suggested first move:** phases 0–2 as a single roadmap. That's the smallest slice that
changes daily life (`ouro i` from any repo) *and* establishes the spine everything else hangs
on.

---

## 15. Open decisions

Recommendations given; each genuinely changes the shape.

1. **Language for `ourod` + `ouro`.** → **Swift.** The engine, the tests, and the menu-bar app
   are already Swift; SPM builds executable targets fine; one language across daemon, CLI, and
   GUI means the client library is shared, not duplicated. Go would be more portable, but this
   is a Mac-first tool and portability isn't the goal. *Cost: no easy Linux daemon later.*

2. **Who owns the loop clock?** → **Daemon-driven cycles**, with agent self-pacing as a
   per-project fallback. Buys pause/resume, harness independence, and real cycle events.
   *Cost: reimplements something that already works; the `/loop` skill's context-cache
   benefits need re-checking under daemon-spawned cycles.*

3. **Default autonomy for operators.** → **Propose-only.** Ship the dial, default it to
   `manual`, let the operator turn it up per project as trust accrues. *Cost: the first weeks of the
   Sentinel feel less magical than the vision.*

4. **Does the index belong on this machine only?** A given setup may also include a home
   server or a small VPS. A hosted mirror would allow filing issues from a phone, from Discord, or from
   a remote agent — genuinely appealing, and the Discord webhook already exists. → **Defer,
   but design the API so a relay is possible** (it already is: the daemon is the only writer).
   A Discord bot that accepts `!idea …` and `!issue atlas …` is a ~100-line phase-5b add-on
   and probably the highest joy-per-line feature in this document.

5. **Where does the embedded package end and Zero begin?** → Embedded stays as the *in-app*
   capture surface for shipped apps (Atlas). Zero owns everything global. They share the file
   format and the daemon. No merge, no fork.

---

## 16. Out of scope (for now)

- Multi-user / team anything. This is a single-operator machine.
- Non-file issue backends (GitHub Issues sync, Linear). The markdown *is* the format.
- Sandboxing agents beyond git worktrees.
- Windows/Linux GUI.
- A web dashboard. The menu bar plus the CLI is the whole interface.

---

## Appendix — where the brainstorm's items landed

| Brainstorm | Section |
|---|---|
| Global control-center menu, quick issue for known projects | §8 |
| First-start: main dev dir + more project dirs | §4 registry, §8 |
| Issue options (PR / merge / worktree / terminal / auto-close) | Exists in `FixOptions`; surfaced §8, defaults per §2.2 |
| Dispatch to pi / codex / oh-my-pi | `Agent` templates; §6 scheduler |
| Give ideas to AI agents → centralized + Discord ping | §5, §10 (MCP tool), phase 5 |
| Easy new project start / wizard | §8, phase 6 |
| Roadmap, phases, loop prompt | §12, phase 7 |
| "Bring it all together in one place" | §3, §7 |
| **New:** CLI | §9, phase 1 |
| **New:** operator API | §10, phase 8 |
| **New:** screen-watching agent | §11, phase 9 |
| **New:** run supervision, inbox, verification gate | §6, §7, §13 |
