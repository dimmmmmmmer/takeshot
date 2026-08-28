import Foundation
import Testing
@testable import TakeShotKit

/// The language switch swaps the .lproj bundle under L(). A missing bundle does
/// not throw — it renders raw keys all over the UI — so the resolution is
/// pinned here, along with the two .strings files staying in step.
struct LocalizationTests {
    @Test func bothLanguagesResolveTheirOwnBundle() {
        L10n.apply(.russian)
        let ru = L("rec")
        L10n.apply(.english)
        let en = L("rec")

        #expect(ru != "rec", "the raw key means the .lproj bundle was not found")
        #expect(en == "REC")
    }

    @Test func systemLanguageFallsBackToTheModuleBundle() {
        L10n.apply(.system)
        #expect(L("rec") != "rec")
        L10n.apply(.english) // leave the suite on a known language
    }

    /// Adding a string to one file and forgetting the other is the standard way
    /// this project's UI ends up half-translated.
    @Test func theTwoStringsFilesCoverTheSameKeys() throws {
        let bundle = Bundle.module
        let enPath = try #require(bundle.path(forResource: "en", ofType: "lproj"))
        let ruPath = try #require(bundle.path(forResource: "ru", ofType: "lproj"))
        let en = try #require(NSDictionary(contentsOfFile:
            enPath + "/Localizable.strings") as? [String: String])
        let ru = try #require(NSDictionary(contentsOfFile:
            ruPath + "/Localizable.strings") as? [String: String])

        let missing = en.keys.filter { ru[$0] == nil }.sorted()
        #expect(missing.isEmpty, "not translated: \(missing.joined(separator: ", "))")
        let extra = ru.keys.filter { en[$0] == nil }.sorted()
        #expect(extra.isEmpty,
                "no longer in the base language: \(extra.joined(separator: ", "))")
    }

    /// **A lowercase `\u` escape is not decoded, and nothing else notices.**
    ///
    /// Foundation's .strings parser takes `\U2019` and does NOT take `’`:
    /// it drops the backslash and leaves the four digits standing, so the
    /// operator reads "RED​u2019s R3D SDK" and every test that only compares
    /// two tables, or asserts a line is non-empty, passes. Two lines in this
    /// project were shipping exactly that — one of them the live toast for a
    /// clip whose camera LUT was withheld — and they were found by a mutation
    /// aimed at something else entirely.
    ///
    /// The rule this pins is the simple one: write the character. Every other
    /// line in both files already does, `—` and `’` included, and a literal
    /// cannot be half-decoded.
    @Test func noStringHidesAnUndecodedEscape() throws {
        let bundle = Bundle.module
        for language in ["en", "ru"] {
            let folder: String = try #require(
                bundle.path(forResource: language, ofType: "lproj"))
            let text: String = try String(
                contentsOfFile: folder + "/Localizable.strings",
                encoding: .utf8)
            let offenders: [String] = text
                .components(separatedBy: "\n")
                .filter { $0.contains("\\u") }
            #expect(offenders.isEmpty,
                    """
                    \(language) carries a lowercase \\u escape, which the \
                    .strings parser leaves undecoded — write the character:
                    \(offenders.joined(separator: "\n"))
                    """)
        }
    }
}
