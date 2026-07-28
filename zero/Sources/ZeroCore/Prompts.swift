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

        public init(title: String, body: String, issuePath: String? = nil, branch: String,
                    base: String, worktree: Bool, verifyCmd: String? = nil, resultPath: String,
                    protectedPaths: [String] = [], extraContext: String? = nil) {
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
