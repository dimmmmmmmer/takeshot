import Foundation
import Testing

@testable import TakeShotKit

/// **No suite in this project may write a preferences domain.**
///
/// `UserDefaults(suiteName:)` writes a plist, and there is no teardown that
/// gets rid of it: removing the domain empties it, and cfprefsd writes the
/// emptiness back on its own schedule — after the delete, whatever order the
/// teardown uses, and however carefully it calls `synchronize()`. Measured on
/// the development machine before this rule: 7,237 files in
/// ~/Library/Preferences, one per test case per run, each an empty dictionary
/// that Preferences scans on every launch of every app on the machine.
///
/// The answer is `InMemoryDefaults`, which every suite here now uses. This
/// rule is what keeps the next one from reaching for a real suite because it
/// looks like the obvious thing to do — it is, and it is wrong, and the reason
/// is not visible from the call site.
struct SuiteHygieneRuleTests {
    /// The test targets' CODE, from this file's own location.
    ///
    /// Comments are stripped, which is not a nicety: every file that explains
    /// why the rule exists has to name the API it forbids, and a rule that
    /// counted those would forbid its own reasoning. This file excludes itself
    /// for the same reason.
    private static func testSources() throws -> [(name: String, text: String)] {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let own = URL(fileURLWithPath: #filePath).lastPathComponent
        var found: [(String, String)] = []
        let walker = try #require(
            FileManager.default.enumerator(at: tests,
                                           includingPropertiesForKeys: nil))
        for case let url as URL in walker
        where url.pathExtension == "swift" && url.lastPathComponent != own {
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces)
                    .hasPrefix("//") }
                .joined(separator: "\n")
            found.append((url.lastPathComponent, code))
        }
        // A floor, so a walk that found nothing would fail here rather than
        // passing every rule below in silence.
        try #require(found.count > 100,
                     "only \(found.count) test sources found")
        return found
    }

    @Test func noSuiteCreatesAPreferencesDomain() throws {
        let offenders = try Self.testSources()
            .filter { $0.text.contains("UserDefaults(suiteName:") }
            .map(\.name)
        #expect(offenders.isEmpty, """
            these suites write a plist into the operator's Preferences folder \
            that nothing can remove — use InMemoryDefaults: \
            \(offenders.joined(separator: ", "))
            """)
    }

    /// …and none of them reaches for the operator's real settings either.
    ///
    /// `UserDefaults.standard` in a test is the same defect one step worse: a
    /// suite that wrote there would change the settings of the app on the
    /// machine running it, which on this project's development Mac is the
    /// machine that shoots.
    @Test func noSuiteReachesTheOperatorsOwnDefaults() throws {
        let offenders = try Self.testSources()
            .filter { source in
                source.text.contains("UserDefaults.standard.set")
                    || source.text.contains("UserDefaults.standard.removeObject")
            }
            .map(\.name)
        #expect(offenders.isEmpty, """
            these suites write the real defaults domain: \
            \(offenders.joined(separator: ", "))
            """)
    }
}
