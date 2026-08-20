# Ouroboros — Next.js

There is no Next.js code in this folder yet. If you want to use Ouroboros in a
Next.js app today, point your coding agent at
[`skills/ouroboros-integrate/SKILL.md`](../skills/ouroboros-integrate/SKILL.md)
and it will implement the pattern for you. If you would prefer a canonical
Next.js package here, open an issue and I will write it. If you want to build it
yourself, PRs are welcome.

## What a port looks like

Port the pattern (see the top-level `README.md` and `swift/` as the
reference) for a Next.js app: a client composer + a server action / route handler that
writes the issue file and spawns the agent (worktree + terminal) via a Node child process.
Keep the spawn behind an injectable runner and add an `INTEGRATION.md`.
