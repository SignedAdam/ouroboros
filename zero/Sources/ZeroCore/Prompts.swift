import Foundation
import Ouroboros

/// The seed prompt for a *supervised* run.
///
/// This differs from the engine's `seedPrompt` in one decisive way: the agent
/// does not finish the job. It implements, commits on its branch, and stops.
/// Ouroboros then runs the verification gate and only merges if the gate is
/// green. The old prompt had the agent merge itself, which meant bad code was
/// already on `main` by the time anyone could check — and it made "did this
/// work?" unanswerable, because the evidence had been cleaned up.
public enum SupervisedPrompt {

    public struct Context {
        public var title: String
        public var body: String
        public var issuePath: String?
        public var branch: String
        public var base: String
        public var worktree: Bool
        public var verifyCmd: String?
        public var resultPath: String
        public var protectedPaths: [String]
        public var extraContext: String?
        /// Path to the installed toolbelt, when there is one.
        public var toolsPath: String?

        public init(title: String, body: String, issuePath: String? = nil, branch: String,
                    base: String, worktree: Bool, verifyCmd: String? = nil, resultPath: String,
                    protectedPaths: [String] = [], extraContext: String? = nil,
                    toolsPath: String? = nil) {
            self.toolsPath = toolsPath
            self.title = title
            self.body = body
            self.issuePath = issuePath
            self.branch = branch
            self.base = base
            self.worktree = worktree
            self.verifyCmd = verifyCmd
            self.resultPath = resultPath
            self.protectedPaths = protectedPaths
            self.extraContext = extraContext
        }
    }

    public static func fix(_ ctx: Context) -> String {
        var out = """
        You are running inside Ouroboros, which is supervising this run.

        A person filed this issue from a quick capture box. It may be under-specified — \
        decide FIRST whether it is clear enough to implement.

        ## \(ctx.title)

        \(ctx.body)

        """

        if let issuePath = ctx.issuePath {
            out += "\n(Issue file: \(issuePath))\n"
        }
        if let extra = ctx.extraContext, !extra.isEmpty {
            out += "\n\(extra)\n"
        }

        if let tools = ctx.toolsPath {
            out += """

            You have a toolbelt on PATH. `\(tools)/TOOLS.md` is its complete spec, one
            line per tool, and it is the only thing you need to read to use them:

              list-windows      what is actually on screen right now (assertable)
              take-screenshot   save a screenshot of a display, region or window
              record-screen     record a region to mp4
              press-key         send a keystroke      type-text   type text
              open-app          open an app without bringing it to the front
              focus-app         bring an app to the front     quit-app   quit it
              ouro              the Ouroboros CLI (`ouro idea "…"` parks a thought)

            If this issue touches anything with a UI, a diff does not prove the fix.
            Open it, assert with `list-windows --assert` that what you think is on
            screen really is, screenshot it, and look. Drive only your own app.

            """
        }

        out += ctx.worktree
            ? "\nYou are in a dedicated git worktree on branch `\(ctx.branch)`, cut from `\(ctx.base)`.\n"
            : "\nYou are working directly in the repository, on branch `\(ctx.branch)`.\n"

        out += """

        How this run ends — follow it exactly:

        1. If the issue is NOT clearly actionable, do not guess and do not implement half of it.
           Write the result file described in step 4 with outcome "needs-input" and ONE specific
           question that would unblock you, then stop. Asking is a good outcome, not a failure.

        2. Otherwise, implement it fully.
        """

        if let verify = ctx.verifyCmd, !verify.isEmpty {
            out += """

           Ouroboros will independently run `\(verify)` on your branch after you exit, and will
           throw the work away if it fails — so run it yourself and get it green first.
        """
        }

        if !ctx.protectedPaths.isEmpty {
            out += """


        3. These paths are protected in this project and must NOT be edited:
           \(ctx.protectedPaths.joined(separator: ", "))
           If the fix genuinely requires touching one, stop with outcome "blocked" and say why.
        """
        }

        out += """


        \(ctx.protectedPaths.isEmpty ? "3" : "4"). Commit your work on `\(ctx.branch)` with a clear message.
           Then STOP. Specifically, do NOT:
             · merge, rebase onto, or push anything
             · switch branches or remove this worktree
             · move or resolve the issue file
           Ouroboros verifies your branch and does all of that itself. Leaving the branch intact
           is what makes the work reviewable and reversible.

        \(ctx.protectedPaths.isEmpty ? "4" : "5"). Last thing before you exit, write this file:

           \(ctx.resultPath)

           containing exactly one JSON object:

           {"outcome": "done", "summary": "<1-2 sentences, past tense, what you changed>", \
        "filesChanged": ["path/one", "path/two"]}

           `outcome` is one of "done", "needs-input", "blocked". For "needs-input" or "blocked",
           include a "question" field with the single thing you need answered.
           This file is how Ouroboros reports back to the human — if you skip it, your work
           shows up as an unexplained branch.
        """

        return out
    }

    /// Re-dispatch after a human answered the agent's question. The original
    /// prompt is replayed verbatim so the second agent starts from the same
    /// place, with the answer appended.
    public static func reply(original: String, question: String?, answer: String,
                             resultPath: String) -> String {
        var out = original
        out += "\n\n---\n\nA previous run of this issue stopped and asked a question.\n"
        if let question, !question.isEmpty {
            out += "\nIts question: \(question)\n"
        }
        out += """

        The human answered:

        \(answer)

        Continue from there and finish the job under the same rules as above. Write your result
        to \(resultPath) when you are done.
        """
        return out
    }

    /// What a `resolve` run is told.
    ///
    /// The whole reason this is a resume and not a fresh dispatch is that the
    /// agent already knows why it wrote those lines. So this says as little as
    /// possible about the work and everything about the situation: which two
    /// commits stopped agreeing, which files, and what it is allowed to decide
    /// on its own.
    public struct ConflictContext {
        public var branch: String
        public var base: String
        public var branchSha: String
        public var baseSha: String
        public var files: [String]
        public var resultPath: String
        public var verifyCmd: String?
        /// The issue this branch was about. Sent only to a fresh agent — the
        /// one being resumed wrote it and does not need it read back.
        public var issue: String?
        /// The conversation could not be reopened, so this is a different agent
        /// picking up somebody else's branch. It has to be told that.
        public var fresh: Bool

        public init(branch: String, base: String, branchSha: String, baseSha: String,
                    files: [String], resultPath: String, verifyCmd: String? = nil,
                    issue: String? = nil, fresh: Bool = false) {
            self.branch = branch
            self.base = base
            self.branchSha = branchSha
            self.baseSha = baseSha
            self.files = files
            self.resultPath = resultPath
            self.verifyCmd = verifyCmd
            self.issue = issue
            self.fresh = fresh
        }
    }

    public static func resolve(_ ctx: ConflictContext) -> String {
        var out = ctx.fresh
            ? """
              You are running inside Ouroboros, which is supervising this run.

              A branch needs rescuing and the agent that wrote it could not be reached — its
              conversation is gone. You are reading this work for the first time, so read it
              before you touch it: `git log \(ctx.base)..\(ctx.branch)` and \
              `git diff \(ctx.base)...\(ctx.branch)`.

              """
            : """
              You are running inside Ouroboros, which is supervising this run.

              This is the branch you wrote earlier in this conversation. It no longer merges.

              """

        out += """
        `\(ctx.branch)` no longer merges into `\(ctx.base)`.

        Compared: `\(String(ctx.baseSha.prefix(12)))` (\(ctx.base)) \
        against `\(String(ctx.branchSha.prefix(12)))` (\(ctx.branch)).

        """

        if ctx.files.isEmpty {
            out += "git did not name the files; run the merge test yourself to find them.\n"
        } else {
            out += "git cannot merge these on its own:\n\n"
            for file in ctx.files { out += "  \(file)\n" }
        }

        if let issue = ctx.issue, !issue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "\nWhat the branch was for:\n\n\(issue)\n"
        }

        out += """

        Rebase `\(ctx.branch)` onto `\(ctx.base)` and resolve the conflicts.

        Where the resolution is obvious, take it. You know what your change was for; most
        conflicts are two edits to neighbouring lines and keeping both is simply correct.

        Where it is NOT obvious, stop and ask. Do not guess, and do not pick a side to make
        the build pass — a green build on the wrong half of a conflict is worse than an
        unresolved branch, because it looks finished. Stopping is a good outcome here, not a
        failure: say what each side is trying to do and name the one thing you need decided.
        Then abort the rebase so the branch is left exactly as it was, and write the result
        file with outcome "needs-input".

        """

        if let verify = ctx.verifyCmd, !verify.isEmpty {
            out += """
            Ouroboros will independently run `\(verify)` on your branch after you exit, and the
            merge will be re-tested. Run it yourself and get it green first.

            """
        }

        out += """
        When the rebase is done and the conflicts are resolved, STOP. Specifically, do NOT:
          · merge, or push anything
          · switch branches or remove this worktree
          · move or resolve the issue file

        Ouroboros re-verifies the branch and re-tests the merge itself. You produce a branch
        that merges; you never perform the merge.

        Last thing before you exit, write this file:

           \(ctx.resultPath)

           containing exactly one JSON object:

           {"outcome": "done", "summary": "<1-2 sentences, past tense, how you resolved it>", \
        "filesChanged": ["path/one"]}

           `outcome` is one of "done", "needs-input", "blocked". For "needs-input", include a
           "question" field holding the single thing you need answered — that question is what
           the human sees, so make it answerable in a sentence.
        """
        return out
    }

    /// A `## Resolution` section, appended to the issue file by Ouroboros using
    /// the agent's own summary — deterministic, and it happens even when the
    /// agent forgot.
    public static func resolutionSection(summary: String?, branch: String?, merged: String?,
                                         at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        var out = "\n\n## Resolution\n\n"
        out += summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? summary!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Fixed by an Ouroboros agent."
        out += "\n\n"
        if let branch { out += "Branch `\(branch)`" }
        if let merged { out += branch != nil ? ", merged into `\(merged)`" : "Merged into `\(merged)`" }
        if branch != nil || merged != nil { out += ". " }
        out += "\(formatter.string(from: date))\n"
        return out
    }
}
