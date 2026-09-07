import Foundation
import Testing

@testable import TakeShotKit

/// **A string that does not match its arguments must not take the app down.**
///
/// `String(format:)` reads its argument list by the conversions IN THE STRING.
/// A `%@` handed an Int builds a pointer out of a small integer and
/// dereferences it: EXC_BAD_ACCESS at address 0x2, inside CoreFoundation, with
/// nothing in the backtrace naming the key. That is not a hypothetical — it is
/// what happened the day `"Dailies done: %d files"` became `"%@"` and one call
/// site kept passing the number.
///
/// `LocalizationTests` holds the two languages to the same conversions, which
/// is the half a static check can see. This is the other half: a CALL SITE
/// that passes the wrong kind, which no amount of reading the .strings files
/// can catch. The fallback is visible nonsense on one line of one panel rather
/// than a process that dies mid-take.
struct ModelLocalizedFormatTests {
    @Test func aCountMismatchIsRefused() {
        #expect(!LocalizedFormat.matches("%@ of %@", ["one"]))
        #expect(!LocalizedFormat.matches("%d", []))
        #expect(LocalizedFormat.matches("%@ of %d", ["one", 2]))
        #expect(LocalizedFormat.matches("nothing to splice", []))
    }

    /// The kind, which is the one that crashes rather than merely reading oddly.
    @Test func anObjectConversionAgainstANumberIsRefused() {
        #expect(!LocalizedFormat.matches("Dailies done: %@", [2]))
        #expect(LocalizedFormat.matches("Dailies done: %@", ["2 files"]))
        // …and the other way, which does not crash but prints a pointer as a
        // number and is just as wrong on screen.
        #expect(!LocalizedFormat.matches("Buffer %d ms", ["260"]))
        #expect(LocalizedFormat.matches("Buffer %d ms", [260]))
    }

    /// `%%` is an escaped percent and consumes nothing — the app's own strings
    /// carry "18% grey" and "100%" in prose.
    @Test func anEscapedPercentIsNotAConversion() {
        #expect(LocalizedFormat.matches("100%% done", []))
        #expect(LocalizedFormat.matches("%d%% of %@", [50, "the card"]))
    }

    /// Flags, widths, precisions and length modifiers belong to the conversion
    /// and are not conversions of their own.
    @Test func theWholeConversionIsReadAndNotJustThePercent() {
        #expect(LocalizedFormat.conversions(in: "%.1f").count == 1)
        #expect(LocalizedFormat.conversions(in: "%-8ld %05d").count == 2)
        #expect(LocalizedFormat.matches("%.1f MB/s", [2.5]))
    }

    /// A positional format may use an argument twice or skip one, so only a
    /// format asking for MORE than it was given is certainly wrong.
    @Test func aPositionalFormatIsJudgedByItsHighestPosition() {
        #expect(LocalizedFormat.matches("%1$@ (%2$d good, %3$d bad)",
                                        ["2 takes", 1, 1]))
        #expect(LocalizedFormat.matches("%1$@ and %1$@ again", ["one"]))
        #expect(!LocalizedFormat.matches("%1$@ %2$@", ["one"]))
    }

    /// **Every formatted string in both languages agrees with itself.**
    ///
    /// The cross-language guard in `LocalizationTests` compares en against ru;
    /// this asks whether each one is even parseable as a format — a conversion
    /// this parser cannot read would make the guard above pass everything
    /// silently, which is the failure mode of a checker nobody checks.
    @Test func everyFormattedStringParsesIntoConversions() throws {
        for language in ["en", "ru"] {
            let path = try #require(Bundle.module.path(forResource: language,
                                                       ofType: "lproj"))
            let table = try #require(NSDictionary(
                contentsOfFile: path + "/Localizable.strings")
                as? [String: String])
            var withConversions = 0
            for (_, text) in table where text.contains("%") {
                let found = LocalizedFormat.conversions(in: text)
                if !found.isEmpty { withConversions += 1 }
            }
            // A floor, so a parser that started returning nothing at all would
            // fail here rather than turning every check above into a no-op.
            #expect(withConversions > 100,
                    "\(language): only \(withConversions) formatted strings")
        }
    }
}
