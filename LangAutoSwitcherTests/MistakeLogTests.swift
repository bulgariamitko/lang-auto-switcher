// MistakeLog.swift is compiled directly into this test bundle
// (see project.yml), so no app import is needed.
import XCTest

final class MistakeLogTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - deletion watch

    /// "лаптоп" + space, then six Backspaces: the space and five letters.
    /// The user is plainly replacing the word — report it.
    func testErasingAConvertedWordIsReported() {
        var w = DeletionWatch(original: "laptop", output: "лаптоп", committedAt: t0)
        for _ in 0..<5 { XCTAssertFalse(w.backspace(at: t0 + 1)) }
        XCTAssertTrue(w.backspace(at: t0 + 1))
    }

    /// Fixing the last letter or two is editing, not a wrong-language word.
    func testTrimmingTheEndingIsNotReported() {
        var w = DeletionWatch(original: "laptop", output: "лаптоп", committedAt: t0)
        XCTAssertFalse(w.backspace(at: t0 + 1))
        XCTAssertFalse(w.backspace(at: t0 + 1))
        XCTAssertFalse(w.backspace(at: t0 + 1))
    }

    func testReportedOnlyOnce() {
        var w = DeletionWatch(original: "da", output: "да", committedAt: t0)
        XCTAssertFalse(w.backspace(at: t0 + 1))
        XCTAssertTrue(w.backspace(at: t0 + 1))
        XCTAssertFalse(w.backspace(at: t0 + 1))
    }

    /// ⌥⌫ erases the whole word in one press.
    func testOptionBackspaceErasesTheWordAtOnce() {
        var w = DeletionWatch(original: "laptop", output: "лаптоп", committedAt: t0)
        XCTAssertTrue(w.backspace(wholeWord: true, at: t0 + 1))
    }

    /// Coming back to a word long after typing it is editing, not correcting.
    func testExpiredWatchReportsNothing() {
        var w = DeletionWatch(original: "da", output: "да", committedAt: t0)
        let late = t0 + DeletionWatch.window + 1
        XCTAssertTrue(w.isExpired(at: late))
        XCTAssertFalse(w.backspace(wholeWord: true, at: late))
    }

    func testOnlyDecisionsThatCouldBeWrongAreWatched() {
        // Converted — could have been wrong.
        XCTAssertTrue(DeletionWatch.shouldWatch(original: "laptop", output: "лаптоп",
                                                isKnownBaseWord: true))
        // Left Latin but not English — maybe a missed conversion.
        XCTAssertTrue(DeletionWatch.shouldWatch(original: "klipcheta", output: "klipcheta",
                                                isKnownBaseWord: false))
        // A known English word left as typed — deleting it is ordinary editing.
        XCTAssertFalse(DeletionWatch.shouldWatch(original: "hello", output: "hello",
                                                 isKnownBaseWord: true))
        XCTAssertFalse(DeletionWatch.shouldWatch(original: "", output: "",
                                                 isKnownBaseWord: false))
    }

    // MARK: - line format

    func testLineCarriesWordResultContextAndApp() {
        let line = MistakeLog.line(kind: .revert, typed: "lfnf", got: "дата",
                                   before: "the ", app: "com.apple.Notes",
                                   version: "2.9.5", at: t0)
        XCTAssertTrue(line.contains("  REVERT  "))
        XCTAssertTrue(line.contains("typed=\"lfnf\""))
        XCTAssertTrue(line.contains("got=\"дата\""))
        XCTAssertTrue(line.contains("before=\"the \""))
        XCTAssertTrue(line.contains("app=com.apple.Notes"))
        XCTAssertTrue(line.hasSuffix("v=2.9.5"))
        XCTAssertFalse(line.contains("\n"))
    }

    func testUnknownContextIsLeftOut() {
        let line = MistakeLog.line(kind: .force, typed: "x", got: "x", before: nil,
                                   app: nil, version: "1", at: t0)
        XCTAssertFalse(line.contains("before="))
        XCTAssertTrue(line.contains("app=?"))
    }

    /// The user's text must never break a line apart.
    func testQuotingEscapesNewlinesTabsAndQuotes() {
        XCTAssertEqual(MistakeLog.quote("a\"b\nc\td\\"), "\"a\\\"b\\nc\\td\\\\\"")
    }

    /// Context is the current line only, and capped — neighbours, not a transcript.
    func testContextKeepsOnlyTheTailOfTheCurrentLine() {
        XCTAssertEqual(MistakeLog.trimContext("first paragraph\nmoje li "), "moje li ")
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(MistakeLog.trimContext(long).count, MistakeLog.contextLimit)
    }

    // MARK: - file

    func testAppendWritesLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("mistakes.log")
        defer { try? FileManager.default.removeItem(at: dir) }
        MistakeLog.append("one\n", to: url)
        MistakeLog.append("two\n", to: url)
        MistakeLog.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\n")
    }
}
