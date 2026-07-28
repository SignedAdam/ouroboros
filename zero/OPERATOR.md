# Operating Ouroboros as an AI

This is the whole surface an autonomous agent needs to use Ouroboros the way a human
does. Nothing here is a special "agent mode" — the menu-bar app and the CLI make these
exact calls.

## Two ways in

**Shell** — simplest, and every command prints something an agent can read:

```bash
ouro i "the settings page 404s on save" --fix -p atlas
ouro inbox
ouro runs --status active
```

**HTTP over a unix socket** — `~/.ouroboros/ourod.sock`. Filesystem permissions are the
auth (`0600`, owner only).

```bash
curl --unix-socket ~/.ouroboros/ourod.sock \
     -H 'Content-Type: application/json' \
     -d '{"body":"the settings page 404s on save","project":"atlas","fix":true}' \
     http://localhost/v1/issues
```

An optional loopback listener (`"httpPort"` + `"token"` in config) exists for clients
that can't speak unix sockets. It is never bound to a non-loopback interface.

## The rule that matters: propose, don't execute

An agent that *notices* things — a screen watcher, a log monitor, a CI hook — should
file **proposals**, not runs. A proposal lands in the human's inbox as a decision.

```bash
curl --unix-socket ~/.ouroboros/ourod.sock -H 'Content-Type: application/json' \
  -d '{
        "project": "atlas",
        "title": "Account switcher truncates long workspace names",
        "body": "At 1280px the name clips mid-word instead of ellipsing.",
        "source": "sentinel",
        "dedupeKey": "atlas:account-switcher-truncation",
        "confidence": 0.7
      }' \
  http://localhost/v1/proposals
```

`dedupeKey` is not optional in spirit. Anything watching continuously will re-notice the
same thing dozens of times an hour; a repeat with a matching key that is still pending
returns `{"created": false}` and changes nothing. Without it you turn the inbox — the one
surface that is supposed to be sacred — into landfill by lunchtime.

Then a human runs `ouro accept <id>` (→ issue + dispatched run) or `ouro dismiss <id>`.

Dispatch runs directly only for projects the human has explicitly moved to
`--autonomy auto`. Check before you assume:

```bash
curl --unix-socket ~/.ouroboros/ourod.sock http://localhost/v1/projects
```

## Endpoints

### Read
```
GET  /v1/health                      is it up, how many runs, how big the inbox
GET  /v1/snapshot                    everything the panel shows, in one call
GET  /v1/projects                    · /v1/projects/{id}
GET  /v1/issues?project=&status=     · /v1/issues/{id}
GET  /v1/runs?status=&project=&limit= · /v1/runs/{id}
GET  /v1/runs/{id}/log?lines=        the agent's terminal output
GET  /v1/runs/{id}/diff              what the branch changed
GET  /v1/runs/{id}/prompt            exactly what the agent was told
GET  /v1/inbox                       what needs a human
GET  /v1/ideas   · /v1/proposals
GET  /v1/events                      SSE stream: run.*, issue.*, proposal.*
```

### Write
```
POST   /v1/issues                 {body, project?, cwd?, title?, fix?, agent?, finish?}
PATCH  /v1/issues/{id}            {body?, status?}
POST   /v1/issues/{id}/fix        {agent?, worktree?, finish?}          → Run
POST   /v1/runs                   {prompt, project, title?}            → freeform run
POST   /v1/runs/{id}/reply        {answer, agent?}                     → new Run
POST   /v1/runs/{id}/stop|merge|undo|retry|ack
POST   /v1/ideas                  {body, title?, project?, source?}
POST   /v1/ideas/{id}/promote     {project?, fix?}
POST   /v1/proposals              {title, body, source, project?, dedupeKey?, confidence?}
POST   /v1/proposals/{id}/accept|dismiss
POST   /v1/projects               {path, name?, autonomy?, verifyCmd?}
PATCH  /v1/projects/{id}          {name?, verifyCmd?, autonomy?, protectedPaths?, …}
POST   /v1/projects/discover      {root}
POST   /v1/projects/create        {name, dir?, description?, github?, roadmap?, agent?}
POST   /v1/setup                  {roots?}                             → adopt every repo found
POST   /v1/update                 {}                                   → pull, rebuild, restart
```

Omit `project` and pass `cwd` instead: Ouroboros walks up to the git root, matches the
registry, and registers an unknown repo on the spot.

Renaming a project is `PATCH /v1/projects/{id}` with `{"name": "…"}` — the id and the
directory don't move.

## Scaffolding a project

`POST /v1/projects` adopts a directory that exists. `POST /v1/projects/create` brings one
into being: `dir` (default `<projectsRoot>/<name>`), a README, a `.gitignore`, `git init`
and an initial commit — then optionally a GitHub repo and a run that writes
`docs/ROADMAP.md`. It answers 409 rather than touching a directory that is already there.

```bash
curl --unix-socket ~/.ouroboros/ourod.sock -H 'Content-Type: application/json' \
  -d '{
        "name": "webhook-replay",
        "description": "replay captured webhooks against the integrations backend",
        "github": "private",
        "roadmap": "ai"
      }' \
  http://localhost/v1/projects/create
```

You get back `{project, run?, message}`: the registered project, the roadmap run when
`roadmap` was `"ai"`, and one line saying what actually happened. A missing or
unauthenticated `gh` is reported in `message`, not raised — the directory and its history
are already real by then.

## First run and self-update

`POST /v1/setup` is what `ouro setup` calls: scan `roots` (or the configured
`autoDiscoverRoots`, or `projectsRoot`), register every repo under them, and report which
agent CLIs are on PATH. Already-adopted repos are not counted as new.

`POST /v1/update` pulls `--ff-only` in the checkout named by `repoPath` in
`~/.ouroboros/config.json` — falling back to the registered project called `ouroboros` —
runs `make install` there, and exits so the launcher starts the new binary. A dirty tree
or a diverged branch stops it before the build. The response goes out before the process
dies; when it carries `"restarting": true`, poll `/v1/health` until `pid` changes to know
the daemon came back.

## Parking an idea

The lowest-friction call in the system, and the one an agent mid-conversation should
reach for when it notices something worth building but off-topic:

```bash
ouro idea "a webhook replay tool for the integrations backend" -p shortimize
```

It writes markdown to `~/.ouroboros/ideas/new/`, pings Discord if a webhook is
configured, and can be promoted into a real issue later with
`ouro promote <id> -p <project> --fix`. Ideas are allowed to rot. That's the point of
keeping them out of the inbox.

## Watching work happen

```bash
curl -N --unix-socket ~/.ouroboros/ourod.sock http://localhost/v1/events
```

```
event: run.started
data: {"type":"run.started","runId":"r-ms44…","status":"running","message":"…"}
```

Types: `run.queued`, `run.started`, `run.running`, `run.verifying`, `run.awaiting`,
`run.succeeded`, `run.failed`, `run.abandoned`, `issue.created`, `idea.created`,
`proposal.created`.

## Answering a question

When a run reaches `awaiting`, the agent stopped and asked something. `GET /v1/runs/{id}`
carries it in `result.question`. Replying starts a fresh run in the *same worktree and
branch*, seeded with the original prompt plus the answer — so nothing is re-derived.

```bash
ouro reply r-ms44fbsz-fam3 "below the nav bar" -a codex
```

## What you cannot do

Deliberately, there is no endpoint to merge without a gate, to edit a repo directly, or
to mark a run succeeded. The only way work lands is: an agent commits to its own branch,
the project's verify command passes on that branch, and the finish mode allows it.

## Writing an agent that Ouroboros supervises

If you *are* the dispatched agent, your contract is in the seed prompt, and it is short:

1. Implement on the branch you were given.
2. Commit. Do not merge, push, switch branches, remove the worktree, or touch the issue
   file — Ouroboros does all of that after it verifies you.
3. Write `$OUROBOROS_RESULT_FILE` before you exit:

```json
{"outcome": "done",
 "summary": "One or two sentences, past tense.",
 "filesChanged": ["path/one"]}
```

`outcome` is `done`, `needs-input`, or `blocked`. For the latter two add `question` with
the single thing you need answered — asking is a good outcome, and it reaches the human
as an inbox item they can reply to in one line.

Skip the file and your work shows up as an unexplained branch.
