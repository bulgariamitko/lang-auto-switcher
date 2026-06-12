// TextHeuristics.swift is compiled directly into this test bundle
// (see project.yml), so no app import is needed — the test target stays
// independent of InputMethodKit, Sparkle, and the Rust static lib.
import XCTest

final class TextHeuristicsTests: XCTestCase {

    // MARK: - Emoticons

    func testKnownEmoticonsAreDetected() {
        for emoticon in [":D", ":P", ":-D", "xD", "XD", ";P", "=D", ":'D"] {
            XCTAssertTrue(TextHeuristics.isEmoticon(emoticon), "\(emoticon) should be an emoticon")
        }
    }

    func testRegularWordsAreNotEmoticons() {
        for word in ["hello", "D", "x", ":", "kolata", "не"] {
            XCTAssertFalse(TextHeuristics.isEmoticon(word), "\(word) should not be an emoticon")
        }
    }

    func testEmoticonPrefixPlusBodyCombination() {
        // ":" + ")" → ":)" must be recognized via prefix+body so the buffer
        // is committed raw before the ")" passes through.
        XCTAssertTrue(TextHeuristics.isEmoticonPrefix(":"))
        XCTAssertTrue(TextHeuristics.isEmoticonPrefix(":-"))
        XCTAssertTrue(TextHeuristics.isEmoticonBody(")"))
        XCTAssertTrue(TextHeuristics.isEmoticonBody("*"))

        XCTAssertFalse(TextHeuristics.isEmoticonPrefix("ab"))
        XCTAssertFalse(TextHeuristics.isEmoticonBody("a"))
    }

    // MARK: - Email / URL detection

    func testEmailsAndUrlsAreDetected() {
        XCTAssertTrue(TextHeuristics.isEmailOrUrl("user@example.com"))
        XCTAssertTrue(TextHeuristics.isEmailOrUrl("example.com"))
        XCTAssertTrue(TextHeuristics.isEmailOrUrl("foo/bar"))
        XCTAssertTrue(TextHeuristics.isEmailOrUrl("v2.7.16"))
        XCTAssertTrue(TextHeuristics.isEmailOrUrl("b4"))   // contains a digit
    }

    func testPlainWordsAreNotEmailsOrUrls() {
        XCTAssertFalse(TextHeuristics.isEmailOrUrl("hello"))
        XCTAssertFalse(TextHeuristics.isEmailOrUrl("zdravej"))
        // Trailing dot alone isn't a domain (the split produces one part).
        XCTAssertFalse(TextHeuristics.isEmailOrUrl("hello."))
        XCTAssertFalse(TextHeuristics.isEmailOrUrl(".hidden"))
    }

    // MARK: - Trailing punctuation

    func testTrailingPunctuationIsSplitOff() {
        let (word, trailing) = TextHeuristics.splitTrailingPunctuation("zdravej?!")
        XCTAssertEqual(word, "zdravej")
        XCTAssertEqual(trailing, "?!")
    }

    func testWordWithoutPunctuationIsUntouched() {
        let (word, trailing) = TextHeuristics.splitTrailingPunctuation("zdravej")
        XCTAssertEqual(word, "zdravej")
        XCTAssertEqual(trailing, "")
    }

    func testPunctuationOnlyBufferLeavesEmptyWord() {
        let (word, trailing) = TextHeuristics.splitTrailingPunctuation("...")
        XCTAssertEqual(word, "")
        XCTAssertEqual(trailing, "...")
    }

    func testInternalPunctuationIsKept() {
        // Only TRAILING punctuation is stripped; dots inside stay (emails
        // and URLs are handled by isEmailOrUrl before this runs).
        let (word, trailing) = TextHeuristics.splitTrailingPunctuation("foo.bar.")
        XCTAssertEqual(word, "foo.bar")
        XCTAssertEqual(trailing, ".")
    }
}
