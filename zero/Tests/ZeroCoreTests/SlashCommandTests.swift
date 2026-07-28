import XCTest
import Foundation
@testable import ZeroCore

// The capture field is the whole product surface, and every one of these rules
// is invisible when it breaks: a palette that stops matching aliases, a `/`
// that shows nothing, a quoted argument that silently splits in two. None of it
// throws — it just quietly does the wrong thing — so it is all pinned here.

// MARK: - the palette

final class SlashSuggestionTests: XCTestCase {

    private func names(_ input: String) -> [String] {
        SlashCommands.suggestions(for: input).map(\.name)
    }

    func testPlainTextIsNotACommand() {
        XCTAssertEqual(names(""), [])
        XCTAssertEqual(names("the sidebar is empty"), [])
        // A path is a sentence, not a command — "/tmp is full" is a bug report.
        XCTAssertEqual(names("tmp/ is full"), [])
    }

    func testBareSlashShowsEverything() {
        XCTAssertEqual(SlashCommands.suggestions(for: "/").count, SlashCommands.all.count)
        XCTAssertEqual(names("/"), SlashCommands.all.map(\.name),
                       "declaration order is the palette's order")
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(names("  /  "), SlashCommands.all.map(\.name))
        XCTAssertEqual(names("  /idea"), ["idea"])
        XCTAssertEqual(names("/add\n"), ["add"])
    }

    func testPrefixMatchesOnName() {
        XCTAssertEqual(names("/i"), ["idea", "issues", "inbox"])
        XCTAssertEqual(names("/iss"), ["issues"])
    }

    func testPrefixMatchesOnAliasesToo() {
        // "reveal" is /open, "revert" is /undo — neither command's own name
        // starts with "rev", so only the alias pass can find them.
        XCTAssertEqual(names("/rev"), ["open", "undo"])
        XCTAssertEqual(names("/harn"), ["agent"])
    }

    func testExactMatchesComeFirst() {
        // "p" is an alias of /project, so it outranks /promote, whose *name*
        // merely starts with p, which outranks /runs, reached only via "ps".
        XCTAssertEqual(names("/p"), ["project", "promote", "runs"])
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(names("/ADD"), ["add"])
        XCTAssertEqual(names("/Iss"), ["issues"])
        XCTAssertEqual(names("/REVeal"), ["open"])
    }

    func testPunctuationAliasesAreReachable() {
        XCTAssertEqual(names("/?"), ["help"])
    }

    func testUnknownPrefixMatchesNothing() {
        XCTAssertEqual(names("/zzz"), [])
        XCTAssertEqual(names("/xyzzy"), [])
    }

    func testASpaceDismissesThePalette() {
        // Once an argument is being typed the palette must stop eating the
        // return key, or `/idea buy milk` can never be submitted.
        XCTAssertEqual(names("/idea buy milk"), [])
        XCTAssertEqual(names("/add ~/dev/acme"), [])
    }
}

// MARK: - the parser

final class SlashParseTests: XCTestCase {

    func testParsesCommandAndArguments() {
        let parsed = SlashCommands.parse("/rename monda atlas")
        XCTAssertEqual(parsed?.command.name, "rename")
        XCTAssertEqual(parsed?.args, ["monda", "atlas"])
    }

    func testResolvesAliases() {
        XCTAssertEqual(SlashCommands.parse("/p monda")?.command.name, "project")
        XCTAssertEqual(SlashCommands.parse("/note park this")?.command.name, "idea")
        XCTAssertEqual(SlashCommands.parse("/?")?.command.name, "help")
    }

    func testIsCaseInsensitiveOnTheCommandOnly() {
        let parsed = SlashCommands.parse("/ADD ~/dev/Acme")
        XCTAssertEqual(parsed?.command.name, "add")
        XCTAssertEqual(parsed?.args, ["~/dev/Acme"], "arguments keep their case")
    }

    func testExtraWhitespaceCollapses() {
        let parsed = SlashCommands.parse("   /idea    buy   milk   ")
        XCTAssertEqual(parsed?.command.name, "idea")
        XCTAssertEqual(parsed?.args, ["buy", "milk"])
    }

    func testQuotedArgumentsSurviveAsOne() {
        let parsed = SlashCommands.parse("/rename \"old name\" new")
        XCTAssertEqual(parsed?.command.name, "rename")
        XCTAssertEqual(parsed?.args, ["old name", "new"])
    }

    func testUnknownCommandsAreNotCommands() {
        // These fall through to being filed as ordinary issues, so returning nil
        // is the whole safety net: "/tmp is full" must reach the issue tracker.
        XCTAssertNil(SlashCommands.parse("/tmp is full"))
        XCTAssertNil(SlashCommands.parse("/zzz"))
        XCTAssertNil(SlashCommands.parse("/ADDD"))
    }

    func testNonCommandInputIsNil() {
        XCTAssertNil(SlashCommands.parse(""))
        XCTAssertNil(SlashCommands.parse("   "))
        XCTAssertNil(SlashCommands.parse("add ~/dev/acme"), "no leading slash")
        XCTAssertNil(SlashCommands.parse("/"), "a lone slash is not a command")
        XCTAssertNil(SlashCommands.parse("  /  "))
    }

    func testCommandsWithNoArguments() {
        XCTAssertEqual(SlashCommands.parse("/inbox")?.args, [])
        XCTAssertEqual(SlashCommands.parse("  /runs  ")?.args, [])
    }

    func testNamedResolvesNamesAndAliases() {
        XCTAssertEqual(SlashCommands.named("merge")?.name, "merge")
        XCTAssertEqual(SlashCommands.named("LAND")?.name, "merge")
        XCTAssertNil(SlashCommands.named("landing"))
        XCTAssertNil(SlashCommands.named(""))
    }
}

// MARK: - the tokenizer

final class SlashTokenizeTests: XCTestCase {

    func testRunsOfWhitespaceAreOneSeparator() {
        XCTAssertEqual(SlashCommands.tokenize("a  b\tc\nd"), ["a", "b", "c", "d"])
        XCTAssertEqual(SlashCommands.tokenize("   "), [])
        XCTAssertEqual(SlashCommands.tokenize(""), [])
    }

    func testBothQuoteStylesGroup() {
        XCTAssertEqual(SlashCommands.tokenize("\"old name\" new"), ["old name", "new"])
        XCTAssertEqual(SlashCommands.tokenize("'old name' new"), ["old name", "new"])
    }

    func testAnEmptyQuotedTokenSurvives() {
        // "" is a deliberate empty argument — /verify "" means "no command".
        XCTAssertEqual(SlashCommands.tokenize("verify \"\""), ["verify", ""])
    }

    func testQuotesJoinAdjacentText() {
        XCTAssertEqual(SlashCommands.tokenize("swift\" \"test"), ["swift test"])
    }

    func testAnUnterminatedQuoteRunsToTheEnd() {
        // The trailing quote is optional, which also means an apostrophe glues
        // the rest of the line into one argument. Fine where it lands — every
        // caller that cares re-joins its arguments with a space anyway.
        XCTAssertEqual(SlashCommands.tokenize("\"old name"), ["old name"])
        XCTAssertEqual(SlashCommands.tokenize("r-1 it's fine"), ["r-1", "its fine"])
    }
}

// MARK: - /add's path-to-name rule

final class SlashProjectNameTests: XCTestCase {

    func testTheDirectoryNamesItself() {
        // Capital N and all: /add ~/dev/Acme registers "Acme", not "acme".
        XCTAssertEqual(SlashCommands.projectName(forPath: "/dev/Acme"), "Acme")
        XCTAssertEqual(SlashCommands.projectName(forPath: "/Users/you/dev/Acme"), "Acme")
    }

    func testTrailingSlashesAreNoise() {
        XCTAssertEqual(SlashCommands.projectName(forPath: "/dev/acme/"), "acme")
        XCTAssertEqual(SlashCommands.projectName(forPath: "/dev/acme///"), "acme")
    }

    func testDegeneratePaths() {
        XCTAssertEqual(SlashCommands.projectName(forPath: "/"), "/")
        XCTAssertEqual(SlashCommands.projectName(forPath: "acme"), "acme")
        XCTAssertEqual(SlashCommands.projectName(forPath: ""), "")
    }

    func testTheParsedArgumentFeedsTheRuleStraightThrough() {
        // The path the user typed after /add is exactly what the rule sees.
        let parsed = SlashCommands.parse("/add /dev/Acme")
        XCTAssertEqual(parsed?.command.name, "add")
        XCTAssertEqual(SlashCommands.projectName(forPath: parsed?.args.first ?? ""), "Acme")

        let quoted = SlashCommands.parse("/add \"/dev/My Project/\"")
        XCTAssertEqual(SlashCommands.projectName(forPath: quoted?.args.first ?? ""), "My Project")
    }
}

// MARK: - the table itself

final class SlashTableTests: XCTestCase {

    func testEveryNameIsMatchable() {
        for command in SlashCommands.all {
            XCTAssertEqual(command.name, command.name.lowercased(),
                           "\(command.name) is compared against a lowercased needle")
            XCTAssertFalse(command.name.contains(where: { $0.isWhitespace }),
                           "\(command.name) could never be typed — a space closes the palette")
            XCTAssertFalse(command.summary.isEmpty, "\(command.name) has no summary to show")
            for alias in command.aliases {
                XCTAssertEqual(alias, alias.lowercased(), "alias \(alias) is unreachable")
                XCTAssertFalse(alias.contains(where: { $0.isWhitespace }), "alias \(alias)")
            }
        }
    }

    func testNoNameOrAliasIsClaimedTwice() {
        var seen = Set<String>()
        for token in SlashCommands.all.flatMap({ [$0.name] + $0.aliases }) {
            XCTAssertTrue(seen.insert(token).inserted,
                          "\(token) is claimed by two commands — one of them is unreachable")
        }
    }

    func testEveryCommandIsReachableByItsOwnName() {
        for command in SlashCommands.all {
            XCTAssertEqual(SlashCommands.parse("/" + command.name)?.command.name, command.name)
            XCTAssertEqual(SlashCommands.suggestions(for: "/" + command.name).first?.name,
                           command.name, "an exact name must sort first")
            for alias in command.aliases {
                XCTAssertEqual(SlashCommands.parse("/" + alias)?.command.name, command.name)
            }
        }
    }
}
