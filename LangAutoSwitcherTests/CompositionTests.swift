// Composition.swift is compiled directly into this test bundle
// (see project.yml), so no app import is needed.
import XCTest

final class CompositionTests: XCTestCase {

    // MARK: - the invariant that broke

    /// Regression: "също трябва да е готов" came out with two spaces between
    /// "да" and "е". "e" is a word in both languages, so it was held back for
    /// its right-hand neighbour — and the space was emitted twice, once into
    /// the marked text and once straight into the document.
    func testHeldWordOwnsItsSpace() {
        // The composition draws the space...
        XCTAssertEqual(Composition.markedText(pending: "e", buffer: "gotow"), "e gotow")
        // ...so the keypress must not also reach the document...
        XCTAssertFalse(Composition.spacePassesThrough(pending: "e"))
        // ...and commit puts exactly one back.
        XCTAssertEqual(Composition.commit(pending: "е", next: "готов"), "е готов")
    }

    func testSpacePassesThroughWhenNothingIsHeld() {
        XCTAssertTrue(Composition.spacePassesThrough(pending: nil))
    }

    // MARK: - marked text

    func testMarkedTextWithoutPendingIsJustTheBuffer() {
        XCTAssertEqual(Composition.markedText(pending: nil, buffer: "gotow"), "gotow")
    }

    /// Regression: a composition that ends in a space is drawn as an empty
    /// box by Chromium apps, so a held word sat there with a box stuck to it.
    /// The space belongs to the commit, not to what is drawn.
    func testHeldWordIsDrawnWithoutATrailingSpace() {
        XCTAssertEqual(Composition.markedText(pending: "e", buffer: ""), "e")
        XCTAssertFalse(Composition.markedText(pending: "e", buffer: "").hasSuffix(" "))
        // The space is still there when it actually separates two words.
        XCTAssertEqual(Composition.markedText(pending: "e", buffer: "g"), "e g")
        // ...and commit still emits exactly one.
        XCTAssertEqual(Composition.commit(pending: "е", next: "готов"), "е готов")
    }

    // MARK: - commit

    func testCommitWithoutPending() {
        XCTAssertEqual(Composition.commit(pending: nil, next: "готов"), "готов")
    }

    func testCommitReattachesTrailingPunctuation() {
        XCTAssertEqual(Composition.commit(pending: "е", next: "готов", trailing: "."),
                       "е готов.")
        XCTAssertEqual(Composition.commit(pending: nil, next: "готов", trailing: "?"),
                       "готов?")
    }

    /// An email after a held word still gets the space the user typed.
    func testCommitKeepsSpaceBeforeAnEmail() {
        XCTAssertEqual(Composition.commit(pending: "това", next: "mitko@example.com"),
                       "това mitko@example.com")
    }

    // MARK: - backspace

    func testBackspaceEatsTheBufferFirst() {
        let r = Composition.backspace(pending: "e", buffer: "gotow")
        XCTAssertEqual(r.pending, "e")
        XCTAssertEqual(r.buffer, "goto")
    }

    /// With an empty buffer the last thing on screen is the held word itself,
    /// so backspace takes it off hold and deletes one visible character.
    func testBackspaceOnEmptyBufferUnholdsAndDeletesOneCharacter() {
        let r = Composition.backspace(pending: "na", buffer: "")
        XCTAssertNil(r.pending)
        XCTAssertEqual(r.buffer, "n")
    }

    /// Every backspace removes exactly one character from what is drawn —
    /// no keypress that looks like it did nothing.
    func testEachBackspaceShortensTheDisplayByOne() {
        var pending: String? = "na"
        var buffer = "topk"
        var lengths = [Composition.markedText(pending: pending, buffer: buffer).count]
        for _ in 0..<6 {
            (pending, buffer) = Composition.backspace(pending: pending, buffer: buffer)
            lengths.append(Composition.markedText(pending: pending, buffer: buffer).count)
        }
        XCTAssertEqual(lengths, [7, 6, 5, 4, 2, 1, 0])
    }

    func testBackspaceWithNothingComposing() {
        let r = Composition.backspace(pending: nil, buffer: "")
        XCTAssertNil(r.pending)
        XCTAssertEqual(r.buffer, "")
    }

    /// Regression: backspacing away the whole word left the last letter on
    /// screen as an orphaned composition — an underlined letter or an empty
    /// box in Chromium apps (Viber, Slack). Emptying the composition has to
    /// produce empty marked text, which is what clears it.
    func testDeletingTheWholeWordLeavesNothingMarked() {
        var (pending, buffer) = (String?.none, "topk")
        for _ in 0..<4 {
            (pending, buffer) = Composition.backspace(pending: pending, buffer: buffer)
        }
        XCTAssertNil(pending)
        XCTAssertEqual(buffer, "")
        XCTAssertEqual(Composition.markedText(pending: pending, buffer: buffer), "")
    }

    /// The same, for a word that was on hold: nothing marked, no stray space.
    func testDeletingAHeldWordLeavesNothingMarked() {
        // 4 to clear "topk", then 2 for "na"
        var (pending, buffer) = (String?.some("na"), "topk")
        for _ in 0..<6 {
            (pending, buffer) = Composition.backspace(pending: pending, buffer: buffer)
        }
        XCTAssertNil(pending)
        XCTAssertEqual(Composition.markedText(pending: pending, buffer: buffer), "")
    }

    /// Un-holding then re-typing continues the word rather than starting one.
    func testUnholdThenTypeContinuesTheSameWord() {
        var (pending, buffer) = Composition.backspace(pending: "ed", buffer: "")
        buffer += "no"
        XCTAssertNil(pending)
        XCTAssertEqual(Composition.markedText(pending: pending, buffer: buffer), "eno")
    }

    // MARK: - A run of held words

    /// Two ambiguous words in a row are held together, and the run is drawn
    /// exactly as it will be committed: the words with single spaces between
    /// them, and still no trailing space before the word being typed.
    func testAHeldRunIsDrawnAsPlainWords() {
        XCTAssertEqual(Composition.markedText(pending: "move li", buffer: ""), "move li")
        XCTAssertEqual(Composition.markedText(pending: "move li", buffer: "d"), "move li d")
        XCTAssertEqual(Composition.commit(pending: "може ли", next: "да"), "може ли да")
    }

    /// Backspacing through a run eats it and ends with nothing marked. The
    /// display never grows and no keypress is a no-op. The two-character
    /// steps are the single-word case once per held word: emptying the buffer
    /// also takes away the space that was only drawn because something
    /// followed it.
    func testBackspaceEatsARunDownToNothing() {
        var (pending, buffer) = (String?.some("move li"), "da")
        var lengths = [Composition.markedText(pending: pending, buffer: buffer).count]
        for _ in 0..<12 {
            (pending, buffer) = Composition.backspace(pending: pending, buffer: buffer)
            lengths.append(Composition.markedText(pending: pending, buffer: buffer).count)
        }
        XCTAssertEqual(lengths, [10, 9, 7, 6, 4, 3, 2, 1, 0, 0, 0, 0, 0])
        XCTAssertNil(pending)
        XCTAssertEqual(Composition.markedText(pending: pending, buffer: buffer), "")
    }

    /// Regression: backspace on a held run moved the whole run, spaces and
    /// all, into the buffer. "move li" then committed as ONE token with a
    /// space inside, matched nothing, and stayed Latin. Only the last held
    /// word comes off hold; the earlier ones keep waiting.
    func testBackspaceOnARunUnholdsOnlyTheLastWord() {
        let r = Composition.backspace(pending: "move li", buffer: "")
        XCTAssertEqual(r.pending, "move")
        XCTAssertEqual(r.buffer, "l")
        XCTAssertFalse(r.buffer.contains(" "))
    }

    func testBackspaceOnAOneLetterLastWordLeavesTheRestHeld() {
        let r = Composition.backspace(pending: "stane i", buffer: "")
        XCTAssertEqual(r.pending, "stane")
        XCTAssertEqual(r.buffer, "")
    }

    // MARK: - numbers in a held run

    /// Regression (Viber): "може да stane i to 10 часа". Three ambiguous
    /// words were held, "10" ended the hold through the email/URL path and
    /// they landed Latin. A bare number joins the run instead, so "часа"
    /// decides it.
    func testANumberJoinsTheHeldRun() {
        XCTAssertTrue(Composition.holdsNumber(pending: "stane i to", word: "10",
                                              trailing: "", maxTokens: 5))
    }

    func testNothingHeldMeansNothingToJoin() {
        XCTAssertFalse(Composition.holdsNumber(pending: nil, word: "10",
                                               trailing: "", maxTokens: 5))
    }

    /// "to 10." ends the sentence: commit, don't keep holding.
    func testPunctuationAfterTheNumberEndsTheHold() {
        XCTAssertFalse(Composition.holdsNumber(pending: "to", word: "10",
                                               trailing: ".", maxTokens: 5))
    }

    /// Only bare numbers: "a3", "10:30" or an address go the usual way.
    func testOnlyBareNumbersJoin() {
        XCTAssertFalse(Composition.holdsNumber(pending: "to", word: "a3",
                                               trailing: "", maxTokens: 5))
        XCTAssertFalse(Composition.holdsNumber(pending: "to", word: "x@y.bg",
                                               trailing: "", maxTokens: 5))
    }

    /// The run is visible marked text, so it stays short.
    func testAFullRunTakesNoMoreNumbers() {
        XCTAssertFalse(Composition.holdsNumber(pending: "a b c 1 2", word: "3",
                                               trailing: "", maxTokens: 5))
    }

    func testNumbersDoNotCountAsHeldWords() {
        XCTAssertEqual(Composition.heldWordCount("stane i to 10"), 3)
        XCTAssertEqual(Composition.heldWordCount("move"), 1)
    }
}
