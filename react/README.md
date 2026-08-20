# Ouroboros — React

There is no React code in this folder yet. If you want to use Ouroboros in a
React app today, point your coding agent at
[`skills/ouroboros-integrate/SKILL.md`](../skills/ouroboros-integrate/SKILL.md)
and it will implement the pattern for you. If you would prefer a canonical
React package here, open an issue and I will write it. If you want to build it
yourself, PRs are welcome.

## What a port looks like

Port the pattern (see the top-level `README.md` and `swift/` as the
reference) for a React app. The composer is pure client UI; the file-write + agent spawn
need a local backend (an Electron/Tauri main process, or a small local server) since a
browser can't touch the filesystem or spawn processes. Add an `INTEGRATION.md` covering that
backend seam.
