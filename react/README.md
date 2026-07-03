# Ouroboros — React

⏳ **Planned.** Port the pattern (see the top-level `README.md` and `swift/` as the
reference) for a React app. The composer is pure client UI; the file-write + agent spawn
need a local backend (an Electron/Tauri main process, or a small local server) since a
browser can't touch the filesystem or spawn processes. Add an `INTEGRATION.md` covering that
backend seam.
