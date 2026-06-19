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

    // MARK: - Key routing

    func testPlainBackspaceIsRecognizedByKeyCode() {
        // keyCode 51 with no Command/Option is a plain Delete the IME consumes.
        XCTAssertTrue(TextHeuristics.isPlainBackspace(keyCode: 51, command: false, option: false))
    }

    func testModifiedOrOtherKeysAreNotPlainBackspace() {
        // Cmd/Opt+Delete fall through to their existing handling.
        XCTAssertFalse(TextHeuristics.isPlainBackspace(keyCode: 51, command: true, option: false))
        XCTAssertFalse(TextHeuristics.isPlainBackspace(keyCode: 51, command: false, option: true))
        // Any other key is never a backspace.
        XCTAssertFalse(TextHeuristics.isPlainBackspace(keyCode: 0, command: false, option: false))
        XCTAssertFalse(TextHeuristics.isPlainBackspace(keyCode: 49, command: false, option: false)) // space
    }

    // MARK: - Edge digits

    func testLeadingDigitsArePeeled() {
        let (lead, core, trail) = TextHeuristics.splitEdgeDigits("2godini")
        XCTAssertEqual(lead, "2")
        XCTAssertEqual(core, "godini")
        XCTAssertEqual(trail, "")
    }

    func testTrailingDigitsArePeeled() {
        let (lead, core, trail) = TextHeuristics.splitEdgeDigits("godini2")
        XCTAssertEqual(lead, "")
        XCTAssertEqual(core, "godini")
        XCTAssertEqual(trail, "2")
    }

    func testDigitsOnBothEndsArePeeled() {
        let (lead, core, trail) = TextHeuristics.splitEdgeDigits("12ri345")
        XCTAssertEqual(lead, "12")
        XCTAssertEqual(core, "ri")
        XCTAssertEqual(trail, "345")
    }

    func testInteriorDigitsStayInCore() {
        // "covid19vaccine" / "mp3foo" keep interior digits so the caller can
        // recognize them as identifiers and leave them Latin.
        let (lead, core, trail) = TextHeuristics.splitEdgeDigits("covid19vaccine")
        XCTAssertEqual(lead, "")
        XCTAssertEqual(core, "covid19vaccine")
        XCTAssertEqual(trail, "")
        XCTAssertTrue(core.contains(where: { $0.isNumber }))
    }

    func testAllDigitsLeavesEmptyCore() {
        let (lead, core, trail) = TextHeuristics.splitEdgeDigits("2024")
        XCTAssertEqual(core, "")
        // Lead greedily takes everything; trail is empty once core is empty.
        XCTAssertEqual(lead, "2024")
        XCTAssertEqual(trail, "")
    }

    func testNoDigitsIsUntouched() {
        let (lead, core, trail) = TextHeuristics.splitEdgeDigits("godini")
        XCTAssertEqual(lead, "")
        XCTAssertEqual(core, "godini")
        XCTAssertEqual(trail, "")
    }
}
