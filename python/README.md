# Ouroboros — Python

There is no Python code in this folder yet. If you want to use Ouroboros in a
Python project today, point your coding agent at
[`skills/ouroboros-integrate/SKILL.md`](../skills/ouroboros-integrate/SKILL.md)
and it will implement the pattern for you. If you would prefer a canonical
Python package here, open an issue and I will write it. If you want to build it
yourself, PRs are welcome.

## What a port looks like

The units mirror the Swift package one-to-one: `issue.py`, `store.py`,
`agent.py`, `terminal.py`, `facade.py`, with tests under `tests/test_ouroboros_*.py`.
Port from `swift/` and add an `INTEGRATION.md` mirroring `swift/INTEGRATION.md`.
