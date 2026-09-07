import Foundation
import Testing

@testable import TakeShotKit

/// **A surface must render `localizedText` and never `english`.**
///
/// The two are both non-empty paragraphs of similar length, so a row that went
/// back to showing the bridge's diagnostic sentence would lay out at very
/// nearly the same size and no render test would notice: the defect is
/// invisible to a measurement and visible only to a reader. So it is checked
/// the way `ViewDisabledRuleTests` checks its rule — by walking the sources.
///
/// Its own file rather than more rows in `BridgeLocalizationTests`, which is at
/// the type-length ceiling.
struct BridgeDiagnosticRuleTests {
    /// What this does NOT catch: a row that spelled an English sentence out
    /// inline instead of reading either property. Nothing here can; what covers
    /// that is that neither section has any literal prose in it at all, which
    /// `theNDIRowLabelsFitTheSettingsForm` and its SRT twin already depend on.
    ///
    /// **Named as a DENY list and not an allow list**, which is the difference
    /// between a rule and a snapshot. It used to name the seven files that were
    /// surfaces at the time, so the eighth surface — the one somebody adds next
    /// month — was covered by nothing at all and the suite would have stayed
    /// green through it. What is listed now is the handful of places where the
    /// diagnostic legitimately LIVES; every other file in both targets is
    /// checked by being walked.
    @Test func noSurfaceShowsTheBridgesEnglishDiagnostic() throws {
        // The diagnostic has to exist somewhere. `BridgeLocalization` defines
        // it; `WebRTCPeer.message` and `SRTStreamError.message` are the
        // accessors a diagnostics bundle and a log line read, and the rule is
        // only that a SURFACE does not read one.
        let allowed: Set<String> = ["BridgeLocalization.swift",
                                    "WebRTCPeer.swift", "SRTStream.swift"]
        var readers: [String] = []
        var files = 0
        for target in ["Sources/TakeShotKit", "Sources/CaptureCore"] {
            let root: URL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(target)
            let walker = try #require(FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                files += 1
                guard !allowed.contains(url.lastPathComponent),
                      let raw = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                for line in raw.components(separatedBy: "\n")
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && Self.readsTheDiagnostic(line) {
                    readers.append("\(url.lastPathComponent): "
                        + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        try #require(files > 100, "the walk did not find the source trees")
        #expect(readers.isEmpty, """
            these show the bridge's English diagnostic instead of the words \
            the app chose:
            \(readers.joined(separator: "\n"))
            """)

        // …and the surfaces that MUST read the localized words still do. The
        // deny list above cannot say this: a row that showed nothing at all
        // would satisfy it.
        let root: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        for name in ["NDISettingsSection", "SRTSettingsSection",
                     "CaptureController+WebRTC", "CaptureController+Capture",
                     "CaptureController+Windows", "CaptureController+Multicam",
                     "RawPlayback"] {
            let source: String = try String(
                contentsOf: root.appendingPathComponent("\(name).swift"),
                encoding: .utf8)
            #expect(source.contains("localizedText"),
                    "\(name) no longer renders the localized reason")
        }
    }

    /// Whether one line READS a bridge's English diagnostic.
    ///
    /// `something.english` where `something` starts lowercase — a value, not a
    /// type. `AppLanguage.english` and `OffloadReportLabels = .english` are
    /// enum cases with nothing to do with a bridge, and both appear in these
    /// trees; a substring match on "english" reported all of them.
    static func readsTheDiagnostic(_ line: String) -> Bool {
        var identifierStart: Character?
        var index = line.startIndex
        while index < line.endIndex {
            defer { index = line.index(after: index) }
            let character = line[index]
            guard character != "." else {
                let rest = line[line.index(after: index)...]
                let after = rest.dropFirst("english".count).first
                if rest.hasPrefix("english"),
                   identifierStart?.isLowercase == true,
                   !(after?.isLetter ?? false), !(after?.isNumber ?? false) {
                    return true
                }
                identifierStart = nil
                continue
            }
            if character.isLetter || character.isNumber || character == "_" {
                if identifierStart == nil { identifierStart = character }
            } else {
                identifierStart = nil
            }
        }
        return false
    }
}
