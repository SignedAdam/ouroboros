import XCTest
@testable import ZeroCore

/// Reading `git diff` is the one place a rendering bug turns into a wrong
/// answer about code. These are the shapes git actually emits, including the
/// four that used to be handled by ignoring them.
final class UnifiedDiffTests: XCTestCase {

    func testOneModifiedFileWithOneHunk() {
        let patch = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1234567..89abcde 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,7 +10,8 @@ func start() {
             let a = 1
        -    let b = 2
        +    let b = 3
        +    let c = 4
             print(a)
        """
        let files = UnifiedDiff.parse(patch)
        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertEqual(file.path, "Sources/App.swift")
        XCTAssertEqual(file.change, .modified)
        XCTAssertEqual(file.added, 2)
        XCTAssertEqual(file.removed, 1)
        XCTAssertEqual(file.hunks.count, 1)
        XCTAssertEqual(file.hunks[0].oldStart, 10)
        XCTAssertEqual(file.hunks[0].newStart, 10)
        XCTAssertEqual(file.hunks[0].context, "func start() {")
    }

    /// The marker is stripped: a view that wants to show the code should not
    /// have to know that column one is a control character.
    func testLinesCarryTheirKindAndNotTheirMarker() {
        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         kept
        -gone
        +new
        """
        let lines = UnifiedDiff.parse(patch)[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added])
        XCTAssertEqual(lines.map(\.text), ["kept", "gone", "new"])
    }

    func testSeveralFilesInOnePatch() {
        let patch = """
        diff --git a/one.txt b/one.txt
        --- a/one.txt
        +++ b/one.txt
        @@ -1 +1 @@
        -a
        +b
        diff --git a/two.txt b/two.txt
        --- a/two.txt
        +++ b/two.txt
        @@ -1 +1 @@
        -c
        +d
        """
        XCTAssertEqual(UnifiedDiff.parse(patch).map(\.path), ["one.txt", "two.txt"])
    }

    func testSeveralHunksAreNumberedInOrder() {
        let patch = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,2 @@ first
        -a
        +b
        @@ -40,2 +40,2 @@ second
        -c
        +d
        """
        let hunks = UnifiedDiff.parse(patch)[0].hunks
        XCTAssertEqual(hunks.map(\.index), [0, 1])
        XCTAssertEqual(hunks.map(\.context), ["first", "second"])
        XCTAssertEqual(hunks[1].oldStart, 40)
    }

    /// A new file's old side is /dev/null, so the path has to come off the +++
    /// line — and the change is `added`, which is what a reviewer scans for.
    func testANewFile() {
        let patch = """
        diff --git a/new.swift b/new.swift
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/new.swift
        @@ -0,0 +1,2 @@
        +one
        +two
        """
        let file = UnifiedDiff.parse(patch)[0]
        XCTAssertEqual(file.path, "new.swift")
        XCTAssertEqual(file.change, .added)
        XCTAssertEqual(file.added, 2)
        XCTAssertEqual(file.removed, 0)
    }

    func testADeletedFileKeepsItsName() {
        let patch = """
        diff --git a/old.swift b/old.swift
        deleted file mode 100644
        --- a/old.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        """
        let file = UnifiedDiff.parse(patch)[0]
        XCTAssertEqual(file.path, "old.swift")
        XCTAssertEqual(file.change, .deleted)
        XCTAssertEqual(file.removed, 2)
    }

    func testARenameCarriesWhereItCameFrom() {
        let patch = """
        diff --git a/from.swift b/to.swift
        similarity index 94%
        rename from from.swift
        rename to to.swift
        --- a/from.swift
        +++ b/to.swift
        @@ -1 +1 @@
        -a
        +b
        """
        let file = UnifiedDiff.parse(patch)[0]
        XCTAssertEqual(file.path, "to.swift")
        XCTAssertEqual(file.oldPath, "from.swift")
        XCTAssertEqual(file.change, .renamed)
    }

    /// A pure rename has no hunks at all, and used to fall out of the list.
    func testARenameWithNoEditsStillAppears() {
        let patch = """
        diff --git a/from.swift b/to.swift
        similarity index 100%
        rename from from.swift
        rename to to.swift
        """
        let files = UnifiedDiff.parse(patch)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "to.swift")
        XCTAssertEqual(files[0].oldPath, "from.swift")
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func testABinaryFileIsMarkedRatherThanShownEmpty() {
        let patch = """
        diff --git a/logo.png b/logo.png
        index 1111111..2222222 100644
        Binary files a/logo.png and b/logo.png differ
        """
        let file = UnifiedDiff.parse(patch)[0]
        XCTAssertEqual(file.path, "logo.png")
        XCTAssertTrue(file.binary)
        XCTAssertTrue(file.hunks.isEmpty)
    }

    /// "\\ No newline at end of file" describes the line above it. Counting it
    /// as a line of the file puts a stray row in the middle of a hunk.
    func testTheNoNewlineNoteIsNotALine() {
        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        """
        let lines = UnifiedDiff.parse(patch)[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.removed, .added])
    }

    /// An empty line inside a hunk arrives as a zero-length string, not as a
    /// space, and it is context.
    func testAnEmptyContextLineSurvives() {
        let patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@\n a\n\n+b\n"
        let lines = UnifiedDiff.parse(patch)[0].hunks[0].lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].kind, .context)
        XCTAssertEqual(lines[1].text, "")
    }

    func testAPathWithASpaceIsReadFromTheMarkerLines() {
        let patch = """
        diff --git a/some dir/a b.txt b/some dir/a b.txt
        --- a/some dir/a b.txt
        +++ b/some dir/a b.txt
        @@ -1 +1 @@
        -x
        +y
        """
        XCTAssertEqual(UnifiedDiff.parse(patch)[0].path, "some dir/a b.txt")
    }

    func testNothingInNothingOut() {
        XCTAssertTrue(UnifiedDiff.parse("").isEmpty)
        XCTAssertTrue(UnifiedDiff.parse("not a diff at all\njust text\n").isEmpty)
    }
}

/// The report as a whole: what it totals, and what it says about itself.
final class DiffReportTests: XCTestCase {

    private func report() -> DiffReport {
        DiffReport(
            runId: "r-1", base: "main", branch: "fix/x",
            baseSha: "aaaa", branchSha: "bbbb",
            commits: [DiffCommit(sha: "1111111", subject: "first"),
                      DiffCommit(sha: "2222222", subject: "second")],
            files: [DiffFile(path: "a.swift", added: 10, removed: 2),
                    DiffFile(path: "b.swift", added: 4, removed: 1)])
    }

    func testTotalsComeFromTheFiles() {
        XCTAssertEqual(report().added, 14)
        XCTAssertEqual(report().removed, 3)
    }

    func testSummaryReadsAsASentence() {
        XCTAssertEqual(report().summary, "2 commits · 2 files · +14 -3")
    }

    func testOneOfEachIsSingular() {
        let one = DiffReport(runId: "r", base: "main", branch: "b",
                             commits: [DiffCommit(sha: "1", subject: "s")],
                             files: [DiffFile(path: "a", added: 1, removed: 0)])
        XCTAssertEqual(one.summary, "1 commit · 1 file · +1 -0")
    }

    func testAnEmptyReportSaysSo() {
        let empty = DiffReport(runId: "r", base: "main", branch: "b")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.summary, "no changes")
    }

    /// The payload crosses a socket to the CLI and to the panel; it has to
    /// survive the trip whole.
    func testRoundTrip() throws {
        let data = try JSONEncoder().encode(report())
        let back = try JSONDecoder().decode(DiffReport.self, from: data)
        XCTAssertEqual(back, report())
    }

    /// A diff, like a merge verdict, names the two commits it is about.
    func testItNamesWhatItCompared() {
        XCTAssertEqual(report().baseSha, "aaaa")
        XCTAssertEqual(report().branchSha, "bbbb")
    }
}
