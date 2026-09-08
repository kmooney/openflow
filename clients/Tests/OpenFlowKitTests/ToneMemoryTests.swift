import XCTest
@testable import OpenFlowKit

final class FieldKindTests: XCTestCase {
    func testAddressBarsAreRecognisedAcrossBrowsers() {
        // Safari names the field by identifier, Chrome by description, and
        // both say "search" as well -- the URL reading has to win.
        XCTAssertEqual(
            FieldKind.classify(role: "AXTextField", subrole: nil,
                               hints: ["WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"]),
            .urlBar)
        XCTAssertEqual(
            FieldKind.classify(role: "AXTextField", subrole: nil,
                               hints: [nil, "Address and search bar"]),
            .urlBar)
        XCTAssertEqual(
            FieldKind.classify(role: "AXTextField", subrole: nil, hints: ["Location Bar"]),
            .urlBar)
    }

    func testSearchFieldsAreRecognisedByEitherSubroleOrName() {
        XCTAssertEqual(
            FieldKind.classify(role: "AXTextField", subrole: "AXSearchField", hints: [nil]),
            .search)
        XCTAssertEqual(
            FieldKind.classify(role: "AXTextField", subrole: nil, hints: ["Search messages"]),
            .search)
    }

    func testOrdinaryFieldsSplitByShape() {
        XCTAssertEqual(FieldKind.classify(role: "AXTextArea", subrole: nil,
                                          hints: ["Message #general"]), .multiLine)
        XCTAssertEqual(FieldKind.classify(role: "AXTextField", subrole: nil,
                                          hints: ["Subject"]), .singleLine)
        XCTAssertEqual(FieldKind.classify(role: "AXButton", subrole: nil, hints: [nil]), .unknown)
        XCTAssertEqual(FieldKind.classify(role: nil, subrole: nil, hints: []), .unknown)
    }

    /// Only the fields whose register genuinely differs from the app's get
    /// their own memory slot. A subject line wants what the body wants.
    func testOnlyAddressAndSearchGetTheirOwnSlot() {
        let mail = DictationContext(bundleID: "com.apple.mail", field: .singleLine)
        XCTAssertEqual(mail.key, "com.apple.mail")
        XCTAssertEqual(mail.lookupKeys, ["com.apple.mail"])

        let safari = DictationContext(bundleID: "com.apple.Safari", field: .urlBar)
        XCTAssertEqual(safari.key, "com.apple.safari#url", "bundle ids are normalised")
        XCTAssertEqual(safari.lookupKeys, ["com.apple.safari#url", "com.apple.safari"],
                       "the field is consulted first, then the app it lives in")
    }
}

final class ToneMemoryTests: XCTestCase {
    private func memory(fallback: Tone = .formal) -> ToneMemory {
        ToneMemory(storage: InMemoryToneStorage(), fallback: fallback)
    }

    private func context(_ bundle: String?, _ field: FieldKind = .unknown) -> DictationContext {
        DictationContext(bundleID: bundle, appName: nil, field: field)
    }

    // MARK: - the two cases the feature exists for

    func testAURLBarIsVeryCasualInAnyBrowser() {
        // No table entry for these: the rule is about the field, so it holds
        // for a browser that ships after we do.
        for browser in ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser"] {
            let r = memory().resolve(context(browser, .urlBar))
            XCTAssertEqual(r.tone, .veryCasual, "\(browser) address bar")
        }
        XCTAssertEqual(memory().tone(for: context("com.apple.Safari", .search)), .veryCasual)
    }

    func testMailIsFormalAndMessagingIsCasual() {
        let m = memory()
        XCTAssertEqual(m.tone(for: context("com.apple.mail", .multiLine)), .formal)
        XCTAssertEqual(m.tone(for: context("com.apple.MobileSMS", .multiLine)), .casual)
        XCTAssertEqual(m.tone(for: context("com.tinyspeck.slackmacgap")), .casual)
    }

    // MARK: - learning

    func testPickingATonePinsItForThatApp() {
        let m = memory()
        let slack = context("com.tinyspeck.slackmacgap", .multiLine)
        XCTAssertEqual(m.resolve(slack).source, .suggested("com.tinyspeck.slackmacgap"))

        XCTAssertTrue(m.remember(.formal, for: slack))
        let after = m.resolve(slack)
        XCTAssertEqual(after.tone, .formal)
        XCTAssertEqual(after.source, .remembered("com.tinyspeck.slackmacgap"))
        XCTAssertTrue(after.isRemembered)
    }

    func testWhatTheUserTaughtTheAppBeatsOurFieldRule() {
        // Someone who sets Safari to formal means it in the address bar too.
        // A shipped rule must never override an explicit choice.
        let m = memory()
        m.remember(.formal, for: context("com.apple.Safari"))
        let r = m.resolve(context("com.apple.Safari", .urlBar))
        XCTAssertEqual(r.tone, .formal)
        XCTAssertEqual(r.source, .remembered("com.apple.safari"))
    }

    func testTeachingAFieldDoesNotTeachTheWholeApp() {
        let m = memory(fallback: .formal)
        m.remember(.casual, for: context("com.apple.Safari", .urlBar))
        XCTAssertEqual(m.tone(for: context("com.apple.Safari", .urlBar)), .casual)
        XCTAssertEqual(m.tone(for: context("com.apple.Safari", .multiLine)), .formal,
                       "the page below the address bar is untouched")
    }

    func testAnUnknownAppFallsBackToTheGlobalPick() {
        let m = memory(fallback: .casual)
        let r = m.resolve(context("com.example.unheardof", .multiLine))
        XCTAssertEqual(r.tone, .casual)
        XCTAssertEqual(r.source, .fallback)
    }

    func testThereIsNothingToRememberWithoutAnApp() {
        // Dictating to the clipboard, or Accessibility declined to answer.
        let m = memory()
        XCTAssertFalse(m.remember(.casual, for: context(nil)),
                       "the caller has to treat this as a change to the default")
        XCTAssertTrue(m.all.isEmpty)
        XCTAssertEqual(m.resolve(context(nil)).source, .fallback)
    }

    // MARK: - forgetting and editing

    func testForgettingRevealsTheSuggestionAgain() {
        let m = memory()
        let mail = context("com.apple.mail", .multiLine)
        m.remember(.veryCasual, for: mail)
        XCTAssertEqual(m.tone(for: mail), .veryCasual)

        m.forget(mail)
        XCTAssertEqual(m.tone(for: mail), .formal)
        XCTAssertEqual(m.resolve(mail).source, .suggested("com.apple.mail"))
    }

    func testEditingARuleKeepsItsName() {
        let m = memory()
        m.remember(.casual, for: DictationContext(bundleID: "com.tinyspeck.slackmacgap",
                                                  appName: "Slack", field: .multiLine))
        m.setTone(.formal, forKey: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(m.all.map(\.label), ["Slack"])
        XCTAssertEqual(m.all.map(\.tone), [.formal])
    }

    func testForgetAllLeavesTheSuggestionsIntact() {
        let m = memory()
        m.remember(.formal, for: context("com.tinyspeck.slackmacgap"))
        m.forgetAll()
        XCTAssertTrue(m.all.isEmpty)
        XCTAssertEqual(m.tone(for: context("com.tinyspeck.slackmacgap")), .casual)
    }

    // MARK: - persistence

    func testRulesSurviveARestart() {
        let storage = InMemoryToneStorage()
        let first = ToneMemory(storage: storage, fallback: .formal)
        first.remember(.veryCasual, for: DictationContext(bundleID: "com.apple.Safari",
                                                          appName: "Safari", field: .urlBar))
        first.remember(.casual, for: DictationContext(bundleID: "com.apple.mail",
                                                      appName: "Mail", field: .multiLine))

        let reopened = ToneMemory(storage: storage, fallback: .formal)
        XCTAssertEqual(reopened.all.map(\.label), ["Mail", "Safari address bar"])
        XCTAssertEqual(reopened.tone(for: DictationContext(bundleID: "com.apple.Safari",
                                                           field: .urlBar)), .veryCasual)
        XCTAssertEqual(reopened.tone(for: DictationContext(bundleID: "com.apple.mail",
                                                           field: .multiLine)), .casual)
    }

    func testCorruptStoredRulesAreIgnoredRatherThanFatal() {
        let storage = InMemoryToneStorage(seed: Data("not json".utf8))
        let m = ToneMemory(storage: storage, fallback: .casual)
        XCTAssertTrue(m.all.isEmpty)
        XCTAssertEqual(m.tone(for: context("com.example.app")), .casual)
    }
}
