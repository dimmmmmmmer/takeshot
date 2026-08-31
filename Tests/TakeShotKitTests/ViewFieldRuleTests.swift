import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// Every text field an operator can type into holds only what its value can be.
///
/// The app has three shapes of input: a filtered `NameTextField`, a typed
/// `TextField(value:format:)`, and a bare `TextField(text:)`. The third has no
/// rule at all, and the audit that found this found exactly one of them on a
/// value that HAS a rule — the project name, which `NameField.prefix` describes
/// and which nothing enforced. `NamingEngine.sanitize` rewrote it afterwards,
/// so what the operator typed and what reached the file name were different
/// strings with nothing to say which.
///
/// A walk rather than a list, for the reason `ViewDisabledRuleTests` is one: a
/// list here would be a second copy of a fact about the source, and it goes
/// stale the way a hard-coded count does.
struct ViewFieldRuleTests {
    /// One `TextField(` in the tree that binds text rather than a typed value.
    struct Site {
        let file: String
        let line: Int
        let text: String
    }

    /// Every bare `TextField(..., text:)` under `Sources/TakeShotKit`.
    ///
    /// `TextField(value:format:)` is not one: a formatter is a rule, and the
    /// value it parses into is the type. What this hunts is the shape with
    /// neither.
    private func bareTextFields() throws -> [Site] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        let walker = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil))
        var found: [Site] = []
        var files = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            files += 1
            guard let raw = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let lines = raw.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.contains("//")
                    ? String(line[line.startIndex..<line.range(of: "//")!.lowerBound])
                    : line
                // `NameTextField(` contains `TextField(`. It is the filtered
                // one — the thing this hunts the ABSENCE of — so a substring
                // match that counted it would report every correct site.
                guard Self.isBareTextField(code) else { continue }
                found.append(Site(file: url.lastPathComponent, line: index + 1,
                                  text: code.trimmingCharacters(in: .whitespaces)))
            }
        }
        try #require(files > 100, "the walk did not find the source tree")
        // **A floor on the EXTRACTOR, not only on the walk.** The rule below
        // asserts an absence, so a detector that stopped recognising the shape
        // it hunts would report a clean tree rather than a broken test. The app
        // has free text in it on purpose — a comment, a search box, an SRT
        // address, an NDI source name — so finding none of them means this
        // stopped looking.
        try #require(!found.isEmpty, """
            the walk found no bare TextField anywhere, which cannot be true \
            while the comment box and the SRT address exist — the detector is \
            no longer recognising the shape
            """)
        return found
    }

    /// One line's worth of the decision, so it can be checked against lines
    /// whose answer is known (`theDetectorKnowsTheShapeItHunts`).
    ///
    /// `NameTextField(` contains `TextField(`. It is the FILTERED one — the
    /// thing this hunts the absence of — so a substring match that counted it
    /// would report every correct site as an offender.
    static func isBareTextField(_ code: String) -> Bool {
        let bare = code.replacingOccurrences(of: "NameTextField(",
                                             with: "«filtered»(")
        return bare.contains("TextField(") && bare.contains("text:")
    }

    /// **Nothing that becomes part of a FILE NAME is bound as raw text.**
    ///
    /// Those values have a rule — `NameField` — and a field that does not
    /// enforce it lets the operator type something `NamingEngine.sanitize`
    /// then rewrites on the way to disk, so what they typed and what landed
    /// are different strings with nothing to say which. The project name was
    /// exactly that until this test existed.
    ///
    /// Asserted on the VALUES rather than on a list of allowed files: a
    /// comment, a search query, an SRT address and an NDI source name are
    /// legitimately free text, and enumerating those would be a list that goes
    /// stale. Naming what may NOT be free names the rule instead.
    @Test func noFileNameValueIsBoundAsRawText() throws {
        // Everything the naming template can splice into a file name.
        let fileNameValues = ["projectName", "cameraLabel", "postfix",
                              ".roll", ".scene", ".shot", "clipDisplay"]
        let offenders = try bareTextFields().filter { site in
            fileNameValues.contains { site.text.contains($0) }
        }
        #expect(offenders.isEmpty,
                """
                these bind a file-name component as raw text — use \
                NameTextField(field:), which refuses the character rather than \
                letting `sanitize` rewrite it afterwards:
                \(offenders.map { "\($0.file):\($0.line) \($0.text)" }
                    .joined(separator: "\n"))
                """)
    }

    /// The detector still tells the three shapes apart. Checked against lines
    /// rather than against the tree, because the tree is what it is USED on:
    /// a detector that quietly stopped matching would make the rule above
    /// pass by finding nothing.
    @Test func theDetectorKnowsTheShapeItHunts() {
        // bare: no rule at all — the shape the rule is about
        #expect(ViewFieldRuleTests.isBareTextField(
            #"TextField("", text: $controller.settings.naming.projectName)"#))
        #expect(ViewFieldRuleTests.isBareTextField(
            #"    TextField(L("srt_address"), text: address)"#))
        // filtered: `NameTextField` carries the rule
        #expect(!ViewFieldRuleTests.isBareTextField(
            #"NameTextField(field: .prefix, text: $text)"#))
        // typed: a format IS a rule, and the value it parses into is the type
        #expect(!ViewFieldRuleTests.isBareTextField(
            #"TextField("", value: $port, format: .number.grouping(.never))"#))
        // and nothing at all
        #expect(!ViewFieldRuleTests.isBareTextField("Text(L(\"rec\"))"))
    }

    /// …and the project name in particular, because that is the one this found.
    @Test func theProjectNameRefusesWhatAPathCannotHold() {
        for bad in ["/", ":", "\u{0}", "a\nb"] {
            #expect(!NameField.prefix.accepts(bad),
                    "the project name field accepts \(bad.debugDescription)")
        }
        // …and keeps what a project is actually called.
        for good in ["Nightfall", "Ночь", "The 39 Steps", "A-B_C"] {
            #expect(NameField.prefix.accepts(good),
                    "the project name field refuses \(good)")
        }
    }
}
