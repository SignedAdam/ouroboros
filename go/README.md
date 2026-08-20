# Ouroboros — Go

There is no Go code in this folder yet. If you want to use Ouroboros in a
Go project today, point your coding agent at
[`skills/ouroboros-integrate/SKILL.md`](../skills/ouroboros-integrate/SKILL.md)
and it will implement the pattern for you. If you would prefer a canonical
Go package here, open an issue and I will write it. If you want to build it
yourself, PRs are welcome.

## What a port looks like

Port the pattern (see the top-level `README.md` and `swift/` as the
reference) into a Go package: `Issue`/title heuristic, `IssueStore`, `Agent` + seed prompt,
`TerminalLauncher`, and an `Ouroboros` facade with `Submit` / `HandToAgent`. Keep shell-outs
behind an injectable runner and add an `INTEGRATION.md`.
