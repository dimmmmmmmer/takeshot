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
}
