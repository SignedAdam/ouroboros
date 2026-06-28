import XCTest
@testable import Ouroboros

final class IssueTests: XCTestCase {
    func testSuggestTitleUsesFirstNonEmptyLine() {
        XCTAssertEqual(IssueText.suggestTitle("\n  \nFix the broken login button\nmore detail"),
                       "Fix the broken login button")
    }
    func testSuggestTitleCapsAtNineWords() {
        XCTAssertEqual(IssueText.suggestTitle("one two three four five six seven eight nine ten eleven"),
                       "one two three four five six seven eight nine")
    }
    func testSuggestTitleEmptyInEmptyOut() {
        XCTAssertEqual(IssueText.suggestTitle("   \n  "), "")
    }
    func testCleanTitleCollapsesWhitespaceAndStripsSlashes() {
        XCTAssertEqual(IssueText.cleanTitle("  a/b   c\nd ."), "a-b c d")
    }
    func testSlugify() {
        XCTAssertEqual(IssueText.slugify("Fix the Login Button!"), "fix-the-login-button")
        XCTAssertEqual(IssueText.slugify("   "), "issue")
    }
}
