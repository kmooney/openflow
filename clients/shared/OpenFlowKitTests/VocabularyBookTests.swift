import XCTest
@testable import OpenFlowKit

final class VocabularyBookTests: XCTestCase {
    private func context(_ bundle: String?) -> DictationContext {
        DictationContext(bundleID: bundle)
    }

    /// Every vocab.txt written before sections existed is entirely global, and
    /// must keep behaving exactly as it did.
    func testAFileWithNoSectionsIsAllGlobal() {
        let book = VocabularyBook.parse("# names\nLarchmont\n\n  Siobhan  \n")
        XCTAssertEqual(book.global, ["Larchmont", "Siobhan"])
        XCTAssertTrue(book.perApp.isEmpty)
        XCTAssertEqual(book.terms(for: context("com.apple.Terminal")),
                       ["Larchmont", "Siobhan"])
        XCTAssertEqual(Vocabulary.parse("Larchmont\nSiobhan"), ["Larchmont", "Siobhan"])
    }

    func testSectionsBindTermsToOneApp() {
        let book = VocabularyBook.parse("""
        Anthropic

        [com.apple.Terminal]
        git status
        kubectl

        [com.apple.mail]
        Siobhan
        """)
        XCTAssertEqual(book.global, ["Anthropic"])
        XCTAssertEqual(book.apps, ["com.apple.mail", "com.apple.terminal"])
        XCTAssertEqual(book.terms(for: context("com.apple.Terminal")),
                       ["git status", "kubectl", "Anthropic"])
        XCTAssertEqual(book.terms(for: context("com.apple.mail")), ["Siobhan", "Anthropic"])
        XCTAssertEqual(book.terms(for: context("com.example.other")), ["Anthropic"],
                       "an app with no section still gets the global list")
    }

    /// The truncation is from the tail, so ordering is what decides which terms
    /// survive a full prompt -- the ones chosen for this app must.
    func testAppTermsComeFirstSoTheySurviveTheTokenCap() {
        let global = (0..<Vocabulary.maxTerms).map { "global\($0)" }
        let book = VocabularyBook.parse(
            global.joined(separator: "\n") + "\n[com.apple.terminal]\nkubectl\n")
        let terms = book.terms(for: context("com.apple.Terminal"))
        XCTAssertEqual(terms.count, Vocabulary.maxTerms)
        XCTAssertEqual(terms.first, "kubectl")
        XCTAssertFalse(terms.contains("global\(Vocabulary.maxTerms - 1)"),
                       "the tail is what gets dropped")
    }

    func testBundleIdsMatchWhateverCaseTheyAreWrittenIn() {
        let book = VocabularyBook.parse("[com.apple.TERMINAL]\nkubectl")
        XCTAssertEqual(book.terms(for: context("com.apple.terminal")), ["kubectl"])
        XCTAssertEqual(book.terms(for: context("com.apple.Terminal")), ["kubectl"])
    }

    func testATermIsNotPaidForTwice() {
        let book = VocabularyBook.parse("kubectl\n[com.apple.terminal]\nKubectl")
        XCTAssertEqual(book.terms(for: context("com.apple.terminal")), ["Kubectl"],
                       "the app's spelling wins, and the budget is spent once")
    }

    func testCommentsAndBlankLinesAreIgnoredInsideSectionsToo() {
        let book = VocabularyBook.parse("""
        [com.apple.terminal]
        # shell things
        git status

        kubectl
        """)
        XCTAssertEqual(book.perApp["com.apple.terminal"], ["git status", "kubectl"])
    }

    /// An empty header is a typo. Dropping every term after it would be a
    /// silent, confusing failure.
    func testAnEmptyHeaderFallsBackToGlobalRatherThanSwallowingTheRest() {
        let book = VocabularyBook.parse("[]\nAnthropic\nSiobhan")
        XCTAssertEqual(book.global, ["Anthropic", "Siobhan"])
        XCTAssertTrue(book.perApp.isEmpty)
    }

    func testNoAppMeansGlobalOnly() {
        let book = VocabularyBook.parse("Anthropic\n[com.apple.terminal]\nkubectl")
        XCTAssertEqual(book.terms(for: context(nil)), ["Anthropic"])
    }

    func testAMissingFileIsEmptyRatherThanFatal() {
        let missing = URL(fileURLWithPath: "/nope/vocab.txt")
        XCTAssertEqual(VocabularyBook.load(from: missing), .empty)
    }
}
