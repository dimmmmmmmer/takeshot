import Foundation
import Testing

@testable import TakeShotKit

/// **"1 дублей" was the headline of every shift report a one-take day made.**
///
/// Russian agrees a noun with its number and has three forms — 1 дубль,
/// 2 дубля, 5 дублей — and the app wrote `"%d дублей"` for all of them. It was
/// on the shift report's own summary line, on the offload's "verified: N
/// files", on the dailies batch, and on the button that asks whether to resume:
/// every place an operator reads a number, in the language most of them read it
/// in.
///
/// The `item_count` family already carried the machinery for exactly this and
/// nothing else used it, so this is that family generalised — a stem and three
/// keys — rather than a second mechanism beside it.
struct ModelPluralCountTests {
    /// The three Russian forms, on the numbers that pick each one. Asserted on
    /// the SHAPE (which key is chosen) rather than on the words, so the suite
    /// says the same thing whatever language it runs in.
    @Test func theFormFollowsTheNumberTheWayRussianDoes() {
        for noun in CountedNoun.all {
            for count in [1, 21, 101, 1_001] {
                #expect(localizedCount(count, noun) == L(noun.one, count),
                        "\(count) \(noun.one) did not take the singular")
            }
            for count in [2, 3, 4, 22, 34, 102] {
                #expect(localizedCount(count, noun) == L(noun.few, count),
                        "\(count) \(noun.few) did not take the few form")
            }
            // …and the exceptions, which are the whole reason this is not
            // `count == 1`: eleven through fourteen take the many form
            // whatever their last digit is.
            for count in [0, 5, 11, 12, 13, 14, 25, 100, 111] {
                #expect(localizedCount(count, noun) == L(noun.many, count),
                        "\(count) \(noun.many) did not take the many form")
            }
        }
    }

    /// Every family is complete in both languages. A missing key renders as the
    /// key itself — `take_count_few` on a shift report — and a form nobody
    /// tests is a form nobody notices until the day the count lands on it.
    @Test func everyFamilyIsCompleteInBothLanguages() throws {
        for noun in CountedNoun.all {
            for key in noun.keys {
                for (language, table) in try Self.tables() {
                    let text = try #require(table[key],
                                            "\(key) is missing from \(language)")
                    #expect(text.contains("%d"),
                            "\(key) in \(language) carries no number: \(text)")
                }
            }
        }
    }

    /// The sentences that TAKE a phrase must take one, and the ones that take a
    /// number must not have been converted by halves: a `%@` fed an Int, or a
    /// `%d` fed a String, renders as garbage in one language only.
    @Test func theConvertedSentencesTakeAPhrase() throws {
        for key in ["offload_done", "verify_done", "dailies_done",
                    "dailies_batch", "offload_resume_accept"] {
            for (language, table) in try Self.tables() {
                let text = try #require(table[key])
                #expect(text.contains("%@"),
                        "\(key) in \(language) still takes a bare number: \(text)")
                #expect(!text.contains("%d"),
                        "\(key) in \(language) takes both: \(text)")
            }
        }
        // …and the one that takes a phrase AND two numbers keeps its positions,
        // because a positional format that loses one argument is a crash.
        for (language, table) in try Self.tables() {
            let text = try #require(table["report_takes_summary"])
            #expect(text.contains("%1$@"), "\(language): \(text)")
            #expect(text.contains("%2$d"), "\(language): \(text)")
            #expect(text.contains("%3$d"), "\(language): \(text)")
        }
    }

    /// Both strings tables, read off the bundle the way `LocalizationTests`
    /// does — the format is what is asserted here, and `L` would resolve
    /// whichever language the suite happens to be running in.
    private static func tables() throws -> [(String, [String: String])] {
        try ["en", "ru"].map { language in
            let path = try #require(Bundle.module.path(forResource: language,
                                                       ofType: "lproj"))
            let table = try #require(NSDictionary(
                contentsOfFile: path + "/Localizable.strings")
                as? [String: String])
            return (language, table)
        }
    }
}
