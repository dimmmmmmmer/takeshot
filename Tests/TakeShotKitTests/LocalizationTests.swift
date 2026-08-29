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

    /// The direction the pair-wise check above cannot see: a key used in the
    /// SOURCE and present in NEITHER file.
    ///
    /// Both tables then agree perfectly — symmetrically missing is still
    /// missing — while the operator reads `menu_change_folder` off a menu item.
    /// `L()` returns the key when it resolves nothing, which is the right
    /// behaviour (a blank menu is worse) and the reason nothing throws.
    ///
    /// **What this deliberately does NOT assert is the other direction.**
    /// 150 of the 803 keys are built at runtime rather than written — the six
    /// bridges' `bridge_<code>`, the alarm cases, the assist band labels — so
    /// an unused-key check would be 150 false alarms and would be deleted
    /// within a week. This walks LITERALS: a key it cannot see is unguarded,
    /// never wrongly accused. Both are stated at the type because "we check the
    /// strings files" is the kind of half-truth that stops people looking.
    @Test func everyKeyWrittenAsALiteralIsInBothStringsFiles() throws {
        let bundle = Bundle.module
        var tables: [String: [String: String]] = [:]
        for language in ["en", "ru"] {
            let folder: String = try #require(
                bundle.path(forResource: language, ofType: "lproj"))
            tables[language] = try #require(NSDictionary(
                contentsOfFile: folder + "/Localizable.strings")
                as? [String: String])
        }

        let uses: [LocalizationTests.KeyUse] = try literalKeys()
        // Not a pinned count — a floor under "the walk read the sources at
        // all", so a broken extractor cannot come back green having found
        // nothing to check.
        try #require(uses.count > 400,
                     "the walk found \(uses.count) keys, so a green run here would mean nothing")

        for language in ["en", "ru"] {
            let table: [String: String] = try #require(tables[language])
            let absent: [String] = uses
                .filter { table[$0.key] == nil }
                .map { "\($0.key) (\($0.file):\($0.line))" }
            #expect(absent.isEmpty,
                    """
                    \(language) has no words for keys the app asks for by name, \
                    so the raw key is what reaches the screen:
                    \(absent.joined(separator: "\n"))
                    """)
        }
    }

    /// A key written twice in one file is silently the LAST one.
    ///
    /// Every other check in this suite reads the files through `NSDictionary`,
    /// which is a dictionary and has already thrown the earlier entry away — so
    /// none of them can see this, by construction. The failure it leaves is the
    /// quiet kind: 804 entries is past the size where anyone scrolls, a key
    /// gets a second home, and then editing the one you found changes nothing
    /// on screen and nothing in any test.
    @Test func noKeyIsDefinedTwiceInOneFile() throws {
        for language in ["en", "ru"] {
            let folder: String = try #require(
                Bundle.module.path(forResource: language, ofType: "lproj"))
            let text: String = try String(
                contentsOfFile: folder + "/Localizable.strings", encoding: .utf8)
            var seen: Set<String> = []
            var twice: [String] = []
            for line: String in text.components(separatedBy: "\n") {
                guard line.hasPrefix("\""),
                      let end = line.dropFirst().firstIndex(of: "\"") else { continue }
                let key = String(line[line.index(after: line.startIndex)..<end])
                if !seen.insert(key).inserted { twice.append(key) }
            }
            // A floor under "the reader found the entries at all" — this parses
            // the file by hand rather than through Foundation, which is the
            // whole point, so it has to prove it read something.
            try #require(seen.count > 700,
                         "\(language): read only \(seen.count) keys, so a green run means nothing")
            #expect(twice.isEmpty,
                    """
                    \(language) defines these keys more than once, and the LAST \
                    one is what the app shows: \(twice.joined(separator: ", "))
                    """)
        }
    }

    /// A key that reaches `String(format:)` has to carry the SAME conversions
    /// in both languages, in the same order.
    ///
    /// `L(_:_:)` splices values into the string the operator's language chose,
    /// and the argument list is fixed by the CALL SITE. So the two directions
    /// fail differently and only one of them is quiet: a translation with
    /// FEWER conversions silently drops a value (a toast that names no file),
    /// and one with MORE reads past the end of the argument list — undefined,
    /// commonly a crash, in one language only, on a path an English-speaking
    /// developer never walks.
    ///
    /// A bare `%` is the same defect wearing different clothes: `String(format:)`
    /// reads `100% done` as a space-flagged `%d` and consumes an argument that
    /// is not there. In a formatted string it has to be `%%`. (Plain keys are
    /// handed back as written and may say `18%` freely — which several do, so
    /// this cannot be a blanket rule about the files.)
    ///
    /// Positional forms (`%1$@`) count as themselves, which is right: a
    /// translator who reorders values must use them, and a language that
    /// reorders without them is the bug this catches.
    @Test func aFormattedStringCarriesTheSameValuesInBothLanguages() throws {
        let bundle = Bundle.module
        var tables: [String: [String: String]] = [:]
        for language in ["en", "ru"] {
            let folder: String = try #require(
                bundle.path(forResource: language, ofType: "lproj"))
            tables[language] = try #require(NSDictionary(
                contentsOfFile: folder + "/Localizable.strings")
                as? [String: String])
        }
        let english: [String: String] = try #require(tables["en"])
        let russian: [String: String] = try #require(tables["ru"])

        let formatted: [KeyUse] = try literalKeys().filter(\.takesArguments)
        let keys: Set<String> = Set(formatted.map(\.key))
        // A floor under "the walk found the formatted call sites at all".
        try #require(keys.count > 80,
                     "only \(keys.count) formatted keys found, so a green run here would mean nothing")

        for use: KeyUse in formatted {
            guard let base: String = english[use.key],
                  let other: String = russian[use.key] else { continue }
            let site = "\(use.key) (\(use.file):\(use.line))"
            #expect(Self.conversions(in: base) == Self.conversions(in: other),
                    """
                    \(site) splices different values in the two languages, and \
                    the call site can only pass one list:
                      en \(Self.conversions(in: base)): \(base)
                      ru \(Self.conversions(in: other)): \(other)
                    """)
            for (language, text) in [("en", base), ("ru", other)] {
                #expect(!Self.hasBaredPercent(text),
                        """
                        \(site) [\(language)] carries a % that is not a \
                        conversion and not an escaped %%, so String(format:) \
                        reads it as one and consumes an argument that is not \
                        there: \(text)
                        """)
            }
        }
    }

    /// The printf conversions in a string, in order, `%%` excluded.
    ///
    /// Deliberately does NOT accept the space flag (`% d`): in these files a
    /// space after a percent is prose — "18% grey", "0% and above 100%" — and
    /// treating it as a conversion would report two hints that are never
    /// formatted at all. `hasBaredPercent` is what catches the same characters
    /// when the string IS formatted, where they really are a hazard.
    static func conversions(in text: String) -> [String] {
        Self.conversionMatches(in: text)
            .map(\.token)
            .filter { !$0.hasSuffix("%") }
    }

    /// True when a `%` survives after every conversion and every `%%` is
    /// removed.
    static func hasBaredPercent(_ text: String) -> Bool {
        var remaining: String = text
        for match in Self.conversionMatches(in: text).reversed() {
            remaining.replaceSubrange(match.range, with: "")
        }
        return remaining.contains("%")
    }

    private static let conversionPattern =
        "%(?:[0-9]+\\$)?[-+#0]*[0-9*]*(?:\\.[0-9]+)?"
        + "(?:hh|h|ll|l|q|L|z|t|j)?[@dDuUxXoOfeEgGcCsSp%]"

    /// Every conversion in `text`, with where it sits.
    private static func conversionMatches(in text: String)
        -> [(token: String, range: Range<String.Index>)] {
        guard let expression = try? NSRegularExpression(
            pattern: Self.conversionPattern) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: whole).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return (String(text[range]), range)
        }
    }

    /// One `L("…")` in the tree.
    struct KeyUse {
        let key: String
        let file: String
        let line: Int
        /// The call passes arguments after the key, so its string goes through
        /// `String(format:)` rather than being handed back as written.
        let takesArguments: Bool
    }

    /// Every key written as a literal in the FIRST argument of an `L(` call.
    ///
    /// First argument rather than "any literal inside the parens", because
    /// `L("marker_added", tcText)` takes format arguments after the key and a
    /// literal one would be a value, not a key. The scan is over the first
    /// argument specifically so that `L(forward ? "menu_step_forward" :
    /// "menu_step_back")` contributes BOTH of its keys — a regex anchored on
    /// `L("` sees neither, and that call site is a menu item's label.
    private func literalKeys() throws -> [KeyUse] {
        let root: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil),
                                  "the source tree could not be walked")
        var found: [KeyUse] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let raw: String = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let lines: [String] = raw.components(separatedBy: "\n")
            for index: Int in lines.indices {
                for call in Self.keys(inCallsOn: code(of: lines[index])) {
                    found.append(KeyUse(key: call.key,
                                        file: url.lastPathComponent,
                                        line: index + 1,
                                        takesArguments: call.takesArguments))
                }
            }
        }
        return found
    }

    /// The code half of a line — a `//` comment can mention `L("…")` in prose
    /// (this file's own doc comments do), and a key named in a comment is not a
    /// key the app asks for.
    private func code(of line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<range.lowerBound])
    }

    /// The literals in the first argument of every `L(` call on one line, each
    /// carrying whether that call goes on to pass arguments.
    static func keys(inCallsOn line: String)
        -> [(key: String, takesArguments: Bool)] {
        let characters: [Character] = Array(line)
        var calls: [(key: String, takesArguments: Bool)] = []
        for index: Int in characters.indices where isCallStart(characters, at: index) {
            let call = keysInFirstArgument(characters, from: index + 2)
            calls += call.keys.map { ($0, call.takesArguments) }
        }
        return calls
    }

    /// An `L(` that is a call and not the tail of another identifier — `AL(`
    /// and `someL(` end in the same letter.
    private static func isCallStart(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "L",
              index + 1 < characters.count, characters[index + 1] == "(" else {
            return false
        }
        guard index > 0 else { return true }
        let before: Character = characters[index - 1]
        return !(before.isLetter || before.isNumber || before == "_")
    }

    /// Every string literal in the first argument, starting just inside the
    /// open paren.
    ///
    /// The first argument specifically, because `L("marker_added", tcText)`
    /// takes format arguments after the key and a literal one there would be a
    /// value rather than a key. Every literal in it, because
    /// `L(forward ? "menu_step_forward" : "menu_step_back")` contributes BOTH —
    /// a regex anchored on `L("` sees neither, and that call site is a menu
    /// item's label. (Both halves were planted and seen failing.)
    private static func keysInFirstArgument(_ characters: [Character], from start: Int)
        -> (keys: [String], takesArguments: Bool) {
        var keys: [String] = []
        var depth: Int = 1
        var scan: Int = start
        while scan < characters.count, depth > 0 {
            switch characters[scan] {
            case "\"":
                let literal: String = Self.literal(characters, from: &scan)
                if depth == 1, !literal.isEmpty { keys.append(literal) }
            case "(":
                depth += 1
            case ")":
                depth -= 1
            case "," where depth == 1:
                // Past the key. A comma here is the variadic overload, which
                // means this string reaches `String(format:)`.
                return (keys, true)
            default:
                break
            }
            scan += 1
        }
        return (keys, false)
    }

    /// The contents of the string literal opening at `scan`, leaving `scan` on
    /// its closing quote. An escape answers empty rather than a mangled key:
    /// a key with a backslash in it is not something this walk should guess at.
    private static func literal(_ characters: [Character],
                                from scan: inout Int) -> String {
        var text: String = ""
        scan += 1
        while scan < characters.count, characters[scan] != "\"" {
            if characters[scan] == "\\" { return "" }
            text.append(characters[scan])
            scan += 1
        }
        return text
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
