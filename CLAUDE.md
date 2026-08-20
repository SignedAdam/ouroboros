# Ouroboros — working rules

Read this before changing anything here. It is short on purpose.

## Comments

**This codebase has no comments.** Not a style preference — a decision, applied
across every file, and it gets re-applied when it drifts.

Code and function names carry the meaning. If a line needs explaining, the fix is
a better name or a smaller function, not a sentence above it. Commentary written
while the code was fresh goes stale the moment the code moves, and a stale comment
is worse than none: it is a confident, wrong description of what you are reading.

Do not add:
- `///` doc comments on types, properties, or functions
- `//` narration above or beside a line
- `// MARK:` section dividers
- commented-out code — delete it, git remembers

The only two exceptions in the repo, both cases where code genuinely cannot speak:

1. `// swift-tools-version:` in each `Package.swift` — the compiler parses it. The
   build fails without it.
2. `zero/Makefile`, the `install` target — `rm` before `cp` rather than `cp -f`,
   because overwriting a code-signed Mach-O in place invalidates its signature and
   macOS SIGKILLs it on the next exec. It surfaces as agents that launch and vanish
   with an empty log, nothing resembling a signing error. The line looks arbitrary
   without a word, so it gets one.

If you believe you have found a third exception, it has to clear that bar: the
information cannot live in a name, and getting it wrong causes a real failure.

## Never commit

`.issues/` and `.personal/` are local working notes. Both are gitignored. The
repository is public — do not add real hostnames, server addresses, private project
names, or personal details to code, tests, docs, or commit messages. Sample projects
in fixtures are `acme`, `atlas`, `orbit`, `lantern`, `harbor`.

## Before you call it done

```bash
cd zero  && swift build && swift test
cd swift && swift build && swift test
```

Both suites green, or it is not done. Run them from a clean tree: `swift test`
writes into `.build/`, so two suites running at once will fight over it.
