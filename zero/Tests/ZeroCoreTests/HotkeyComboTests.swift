import XCTest
import Foundation
import Carbon.HIToolbox
@testable import ZeroCore

// The hotkey is the app's front door: it is read from config.json, written by
// /hotkey, and registered once at launch. Every failure mode here is silent —
// a combo that no longer parses just falls through to a fallback, and the key
// the user configured quietly stops working.

final class HotkeyParseTests: XCTestCase {

    func testTheTwoCombosTheAppShipsWith() {
        let opt = HotkeyCombo.parse("opt+space")
        XCTAssertEqual(opt?.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(opt?.modifiers, UInt32(optionKey))

        let cmdShift = HotkeyCombo.parse("cmd+shift+space")
        XCTAssertEqual(cmdShift?.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(cmdShift?.modifiers, UInt32(cmdKey) | UInt32(shiftKey))
    }

    func testModifiersAccumulate() {
        let all = HotkeyCombo.parse("ctrl+opt+shift+cmd+k")
        XCTAssertEqual(all?.keyCode, UInt32(kVK_ANSI_K))
        XCTAssertEqual(all?.modifiers,
                       UInt32(controlKey) | UInt32(optionKey)
                       | UInt32(shiftKey) | UInt32(cmdKey))
    }

    func testModifierAliasesAreTheSameKey() {
        XCTAssertEqual(HotkeyCombo.parse("alt+space")?.modifiers, UInt32(optionKey))
        XCTAssertEqual(HotkeyCombo.parse("option+space")?.modifiers, UInt32(optionKey))
        XCTAssertEqual(HotkeyCombo.parse("command+k")?.modifiers, UInt32(cmdKey))
        XCTAssertEqual(HotkeyCombo.parse("control+k")?.modifiers, UInt32(controlKey))
        XCTAssertEqual(HotkeyCombo.parse("alt+cmd+i").map(\.modifiers),
                       HotkeyCombo.parse("opt+command+i").map(\.modifiers))
    }

    func testOrderOfModifiersDoesNotMatter() {
        let a = HotkeyCombo.parse("cmd+shift+space")
        let b = HotkeyCombo.parse("shift+cmd+space")
        XCTAssertEqual(a?.keyCode, b?.keyCode)
        XCTAssertEqual(a?.modifiers, b?.modifiers)
    }

    func testCaseAndSeparatorsAreForgiving() {
        let canonical = HotkeyCombo.parse("opt+space")
        for spelling in ["OPT+SPACE", "Opt+Space", "opt space", "opt + space"] {
            XCTAssertEqual(HotkeyCombo.parse(spelling)?.keyCode, canonical?.keyCode, spelling)
            XCTAssertEqual(HotkeyCombo.parse(spelling)?.modifiers, canonical?.modifiers, spelling)
        }
    }

    func testKeyAliases() {
        XCTAssertEqual(HotkeyCombo.parse("cmd+esc")?.keyCode, UInt32(kVK_Escape))
        XCTAssertEqual(HotkeyCombo.parse("cmd+enter")?.keyCode, UInt32(kVK_Return))
        XCTAssertEqual(HotkeyCombo.parse("cmd+ret")?.keyCode, UInt32(kVK_Return))
        XCTAssertEqual(HotkeyCombo.parse("cmd+spc")?.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(HotkeyCombo.parse("cmd+/")?.keyCode, UInt32(kVK_ANSI_Slash))
        XCTAssertEqual(HotkeyCombo.parse("cmd+.")?.keyCode, UInt32(kVK_ANSI_Period))
        XCTAssertEqual(HotkeyCombo.parse("cmd+,")?.keyCode, UInt32(kVK_ANSI_Comma))
    }

    func testDigitsAndLetters() {
        XCTAssertEqual(HotkeyCombo.parse("opt+0")?.keyCode, UInt32(kVK_ANSI_0))
        XCTAssertEqual(HotkeyCombo.parse("opt+9")?.keyCode, UInt32(kVK_ANSI_9))
        XCTAssertEqual(HotkeyCombo.parse("opt+z")?.keyCode, UInt32(kVK_ANSI_Z))
    }

    func testABareKeyIsRefused() {
        // A global hotkey with no modifier would swallow that key everywhere on
        // the machine — including inside the app the user is typing in.
        XCTAssertNil(HotkeyCombo.parse("space"))
        XCTAssertNil(HotkeyCombo.parse("k"))
        XCTAssertNil(HotkeyCombo.parse(""))
    }

    func testAMissingOrUnknownKeyIsRefused() {
        XCTAssertNil(HotkeyCombo.parse("opt+"), "modifier with nothing to press")
        XCTAssertNil(HotkeyCombo.parse("cmd+shift"), "still no key")
        XCTAssertNil(HotkeyCombo.parse("opt+banana"), "not a key name")
        XCTAssertNil(HotkeyCombo.parse("opt+f1"), "function keys are not in the table")
        XCTAssertNil(HotkeyCombo.parse("opt+;"))
    }

    func testTheLastKeyWins() {
        // Two key names is user error; taking the last one keeps parsing total
        // instead of failing into a fallback combo.
        XCTAssertEqual(HotkeyCombo.parse("opt+a+b")?.keyCode, UInt32(kVK_ANSI_B))
    }
}

final class HotkeyDescribeTests: XCTestCase {

    func testRendersInTheOrderMacOSWritesModifiers() {
        XCTAssertEqual(HotkeyCombo.describe("opt+space"), "⌥Space")
        XCTAssertEqual(HotkeyCombo.describe("cmd+shift+space"), "⇧⌘Space")
        XCTAssertEqual(HotkeyCombo.describe("shift+cmd+space"), "⇧⌘Space")
        XCTAssertEqual(HotkeyCombo.describe("ctrl+opt+shift+cmd+k"), "⌃⌥⇧⌘K")
    }

    func testNamedKeysGetTheirGlyph() {
        XCTAssertEqual(HotkeyCombo.describe("cmd+esc"), "⌘⎋")
        XCTAssertEqual(HotkeyCombo.describe("cmd+enter"), "⌘↩")
        XCTAssertEqual(HotkeyCombo.describe("cmd+tab"), "⌘⇥")
        XCTAssertEqual(HotkeyCombo.describe("cmd+/"), "⌘/")
        XCTAssertEqual(HotkeyCombo.describe("cmd+."), "⌘.")
        XCTAssertEqual(HotkeyCombo.describe("cmd+,"), "⌘,")
    }

    func testPlainKeysAreUppercased() {
        XCTAssertEqual(HotkeyCombo.describe("opt+cmd+i"), "⌥⌘I")
        XCTAssertEqual(HotkeyCombo.describe("opt+7"), "⌥7")
    }

    func testNonsenseIsEchoedBackRatherThanHidden() {
        // The footer shows whatever is configured; a combo that cannot be
        // rendered is still better shown than blanked out.
        XCTAssertEqual(HotkeyCombo.describe("banana"), "banana")
        XCTAssertEqual(HotkeyCombo.describe(""), "")
    }

    func testEveryFallbackRenders() {
        for combo in HotkeyCombo.fallbacks {
            XCTAssertNotNil(HotkeyCombo.parse(combo), "\(combo) must be registrable")
            XCTAssertNotEqual(HotkeyCombo.describe(combo), combo,
                              "\(combo) fell through to the raw string")
        }
    }
}

final class HotkeyCaptureHintTests: XCTestCase {

    func testTheHintNamesTheComboThatRegistered() {
        XCTAssertEqual(HotkeyCombo.captureHint(active: "opt+space"),
                       "⌥Space to capture anywhere")
        XCTAssertEqual(HotkeyCombo.captureHint(active: "cmd+shift+space"),
                       "⇧⌘Space to capture anywhere")
    }

    func testNoRegisteredComboIsSaidRatherThanGuessed() {
        // Every combo in the chain was taken: there is no key to advertise, and
        // the panel is itself the way in.
        XCTAssertEqual(HotkeyCombo.captureHint(active: nil), "no capture hotkey — use this menu")
        XCTAssertEqual(HotkeyCombo.captureHint(active: "  "), "no capture hotkey — use this menu")
    }

    func testTheHintNeverHardCodesOneCombo() {
        // The bug this replaced: a literal in the panel footer that kept saying
        // ⌥⌘I long after the default became ⌥Space.
        for combo in HotkeyCombo.fallbacks {
            XCTAssertTrue(HotkeyCombo.captureHint(active: combo)
                            .hasPrefix(HotkeyCombo.describe(combo)),
                          "\(combo) is not the key the hint names")
        }
    }
}

final class HotkeyNameTests: XCTestCase {

    func testCodeAndMaskRoundTripToText() {
        for combo in ["opt+space", "shift+cmd+space", "ctrl+opt+shift+cmd+k", "opt+7"] {
            let parsed = HotkeyCombo.parse(combo)
            XCTAssertNotNil(parsed, combo)
            XCTAssertEqual(HotkeyCombo.name(keyCode: parsed!.keyCode,
                                            modifiers: parsed!.modifiers),
                           combo, "the app reports the combo it really registered")
        }
    }

    func testModifiersAreNamedInACanonicalOrder() {
        XCTAssertEqual(HotkeyCombo.name(keyCode: UInt32(kVK_Space),
                                        modifiers: UInt32(cmdKey) | UInt32(shiftKey)),
                       "shift+cmd+space")
    }

    func testAnUnknownCodeHasNoName() {
        XCTAssertNil(HotkeyCombo.name(keyCode: 9999, modifiers: UInt32(cmdKey)))
    }
}

final class HotkeyChainTests: XCTestCase {

    func testWithNoPreferenceItIsJustTheFallbacks() {
        XCTAssertEqual(HotkeyCombo.chain(preferred: nil), HotkeyCombo.fallbacks)
        XCTAssertEqual(HotkeyCombo.chain(preferred: ""), HotkeyCombo.fallbacks)
        XCTAssertEqual(HotkeyCombo.chain(preferred: "   "), HotkeyCombo.fallbacks)
    }

    func testThePreferredComboIsTriedFirstAndNormalized() {
        XCTAssertEqual(HotkeyCombo.chain(preferred: "  CMD+K  ").first, "cmd+k")
        XCTAssertEqual(HotkeyCombo.chain(preferred: "cmd+k"),
                       ["cmd+k"] + HotkeyCombo.fallbacks)
    }

    func testAPreferredFallbackIsNotTriedTwice() {
        let chain = HotkeyCombo.chain(preferred: "cmd+shift+space")
        XCTAssertEqual(chain.first, "cmd+shift+space")
        XCTAssertEqual(chain.count, HotkeyCombo.fallbacks.count)
        XCTAssertEqual(Set(chain).count, chain.count, "no combo is attempted twice")
    }

    func testUnparseableConfigStillLeavesAWorkingKey() {
        // A typo in config.json must not cost the user the hotkey entirely.
        let chain = HotkeyCombo.chain(preferred: "banana")
        XCTAssertEqual(chain.first, "banana")
        XCTAssertTrue(chain.dropFirst().allSatisfy { HotkeyCombo.parse($0) != nil })
    }
}
