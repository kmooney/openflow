import XCTest
@testable import OpenFlowKit

final class DomainsTests: XCTestCase {
    func testAURLBecomesTheDomainYouWouldSay() {
        XCTAssertEqual(Domains.term(from: "https://www.doordash.com/store/12"), "doordash.com")
        XCTAssertEqual(Domains.term(from: "http://doordash.com"), "doordash.com")
        XCTAssertEqual(Domains.term(from: "https://news.ycombinator.com/item?id=1"),
                       "news.ycombinator.com", "a subdomain is part of what you say")
        XCTAssertEqual(Domains.term(from: "https://WWW.BSKY.APP/"), "bsky.app")
    }

    /// Spending prompt budget on these buys nothing -- none is pronounceable
    /// as a domain, and the budget is the scarce resource.
    func testUnpronounceableOrLocalThingsAreSkipped() {
        for url in ["file:///Users/kevin/notes.txt", "about:config",
                    "moz-extension://abc/page.html", "chrome://settings",
                    "http://localhost:3000/x", "http://127.0.0.1/x",
                    "https://192.168.1.10/admin", "not a url", ""] {
            XCTAssertNil(Domains.term(from: url), url)
        }
    }

    func testVisitsCollapseToOneEntryPerDomain() {
        let ranked = Domains.rank([
            ("https://www.doordash.com/a", 3),
            ("https://doordash.com/b", 4),
            ("https://bsky.app/", 20),
            ("file:///tmp/x", 99),
        ])
        XCTAssertEqual(ranked.map(\.domain), ["bsky.app", "doordash.com"],
                       "most-visited first")
        XCTAssertEqual(ranked.first(where: { $0.domain == "doordash.com" })?.count, 7,
                       "www and bare are the same site, so their visits add up")
    }

    /// Seeding twice from an unchanged history must produce an unchanged file,
    /// so ties cannot fall back to dictionary ordering.
    func testTiesBreakAlphabeticallyRatherThanArbitrarily() {
        let visits = [("https://b.com/", 5), ("https://a.com/", 5), ("https://c.com/", 5)]
        for _ in 0..<8 {
            XCTAssertEqual(Domains.rank(visits).map(\.domain), ["a.com", "b.com", "c.com"])
        }
    }

    func testTheTokenEstimateTracksTheBudget() {
        XCTAssertEqual(Vocabulary.estimatedPromptTokens([]), 0)
        let fourty = (0..<40).map { "site\($0).com" }
        let estimate = Vocabulary.estimatedPromptTokens(fourty)
        XCTAssertGreaterThan(estimate, 100)
        XCTAssertLessThan(Vocabulary.estimatedPromptTokens(Array(fourty.prefix(10))), estimate)
    }
}

final class VocabularyFileTests: XCTestCase {
    func testASectionIsAddedWithoutTouchingAnythingElse() {
        let before = "# names\nLarchmont\nSiobhan\n"
        let after = VocabularyFile.replacingSection(
            in: before, app: "org.mozilla.firefox", terms: ["doordash.com"])
        XCTAssertTrue(after.hasPrefix("# names\nLarchmont\nSiobhan\n"))
        XCTAssertTrue(after.contains("[org.mozilla.firefox]\ndoordash.com"))
        XCTAssertEqual(VocabularyBook.parse(after).global, ["Larchmont", "Siobhan"])
    }

    /// The whole point: reseeding replaces the seeded list and leaves global
    /// terms, other apps, and the user's comments exactly as they were.
    func testReseedingReplacesOnlyThatSection() {
        let before = """
        Larchmont

        # my browser sites
        [org.mozilla.firefox]
        doordash.com
        bsky.app

        [com.apple.mail]
        Siobhan
        """
        let after = VocabularyFile.replacingSection(
            in: before, app: "org.mozilla.firefox", terms: ["example.com"])
        let book = VocabularyBook.parse(after)
        XCTAssertEqual(book.global, ["Larchmont"])
        XCTAssertEqual(book.perApp["org.mozilla.firefox"], ["example.com"])
        XCTAssertEqual(book.perApp["com.apple.mail"], ["Siobhan"],
                       "another app's section is untouched")
        XCTAssertTrue(after.contains("# my browser sites"), "comments are the user's")
    }

    func testCommentsInsideTheSectionSurvive() {
        let before = "[org.mozilla.firefox]\n# food\ndoordash.com\n"
        let after = VocabularyFile.replacingSection(
            in: before, app: "org.mozilla.firefox", terms: ["example.com"])
        XCTAssertTrue(after.contains("# food"))
        XCTAssertEqual(VocabularyBook.parse(after).perApp["org.mozilla.firefox"],
                       ["example.com"])
    }

    /// A header left behind with no terms silently captures whatever the user
    /// types after it, which is a nasty way to lose global terms.
    func testClearingASectionRemovesItsHeader() {
        let before = "Larchmont\n[org.mozilla.firefox]\ndoordash.com\n"
        let after = VocabularyFile.replacingSection(
            in: before, app: "org.mozilla.firefox", terms: [])
        XCTAssertFalse(after.contains("[org.mozilla.firefox]"))
        XCTAssertEqual(VocabularyBook.parse(after).global, ["Larchmont"])
    }

    func testTheHeaderKeepsTheCaseTheUserWroteIt() {
        let before = "[org.mozilla.Firefox]\nold.com\n"
        let after = VocabularyFile.replacingSection(
            in: before, app: "org.mozilla.firefox", terms: ["new.com"])
        XCTAssertTrue(after.contains("[org.mozilla.Firefox]"))
        XCTAssertEqual(VocabularyBook.parse(after).perApp["org.mozilla.firefox"], ["new.com"])
    }

    /// Writing the same list twice must not grow the file.
    func testWritingIsIdempotent() {
        let before = "Larchmont\n"
        let once = VocabularyFile.replacingSection(
            in: before, app: "org.mozilla.firefox", terms: ["a.com", "b.com"])
        let twice = VocabularyFile.replacingSection(
            in: once, app: "org.mozilla.firefox", terms: ["a.com", "b.com"])
        XCTAssertEqual(once, twice)
    }

    func testExistingTermsCanBeReadBackToBeKeptFirst() {
        let text = "[org.mozilla.firefox]\nhand.com\n"
        XCTAssertEqual(VocabularyFile.section(text, app: "org.mozilla.firefox"), ["hand.com"])
        XCTAssertEqual(VocabularyFile.section(text, app: "com.apple.mail"), [])
    }
}
