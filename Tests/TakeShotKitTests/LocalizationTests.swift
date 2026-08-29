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

    /// One `L("…")` in the tree.
    struct KeyUse {
        let key: String
        let file: String
        let line: Int
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
                for key: String in Self.keys(inCallsOn: code(of: lines[index])) {
                    found.append(KeyUse(key: key,
                                        file: url.lastPathComponent,
                                        line: index + 1))
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

    /// The literals in the first argument of every `L(` call on one line.
    static func keys(inCallsOn line: String) -> [String] {
        let characters: [Character] = Array(line)
        var keys: [String] = []
        for index: Int in characters.indices where isCallStart(characters, at: index) {
            keys += keysInFirstArgument(characters, from: index + 2)
        }
        return keys
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
    private static func keysInFirstArgument(_ characters: [Character],
                                            from start: Int) -> [String] {
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
                return keys // past the key: what follows are format arguments
            default:
                break
            }
            scan += 1
        }
        return keys
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
