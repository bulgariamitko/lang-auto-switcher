// DictionarySource.swift is compiled directly into this test bundle
// (see project.yml), so no app import is needed.
import XCTest

final class DictionarySourceTests: XCTestCase {

    /// Regression: the installed copy of a bundled dictionary was made once
    /// and then always won, so words added in later releases ("й",
    /// "синхронизирал") never reached existing installs.
    func testNewerBundleReplacesStaleInstalledCopy() {
        let c = DictionarySource.choose(installed: "да\nне\n", bundled: "да\nне\nй\n")
        XCTAssertEqual(c, .init(text: "да\nне\nй\n", writeInstalled: true))
    }

    /// Words removed from the bundle as harmful must disappear too — merging
    /// would have kept them.
    func testRemovedWordsDoNotSurviveInTheInstalledCopy() {
        let c = DictionarySource.choose(installed: "гоогле\nда\n", bundled: "да\n")
        XCTAssertEqual(c?.text, "да\n")
        XCTAssertEqual(c?.writeInstalled, true)
    }

    func testIdenticalCopiesAreNotRewritten() {
        let c = DictionarySource.choose(installed: "да\n", bundled: "да\n")
        XCTAssertEqual(c, .init(text: "да\n", writeInstalled: false))
    }

    func testFirstRunInstallsTheBundledCopy() {
        let c = DictionarySource.choose(installed: nil, bundled: "да\n")
        XCTAssertEqual(c, .init(text: "да\n", writeInstalled: true))
    }

    /// A language downloaded from the menu has no bundled list: keep it.
    func testDownloadedLanguageKeepsItsInstalledCopy() {
        let c = DictionarySource.choose(installed: "och\n", bundled: nil)
        XCTAssertEqual(c, .init(text: "och\n", writeInstalled: false))
    }

    func testEmptyFilesCountAsMissing() {
        XCTAssertNil(DictionarySource.choose(installed: "", bundled: ""))
        XCTAssertEqual(DictionarySource.choose(installed: "", bundled: nil), nil)
        XCTAssertEqual(DictionarySource.choose(installed: "", bundled: "да\n")?.writeInstalled, true)
    }
}
