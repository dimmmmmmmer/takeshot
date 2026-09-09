import AppKit
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The PDF report's pictures must not depend on scroll history.**
///
/// The panel's thumbnail cache holds what the grid scrolled past, and the
/// report used to hand it through as it stood: a take the operator never
/// scrolled to came out as a BLANK cell, with the row's text intact so nothing
/// looked wrong. On a long day that is most of the document.
///
/// The contact sheet had the rule right ("a sheet whose cells depend on scroll
/// history is wrong") and decoded its own posters; this is the same rule
/// applied to the document beside it.
///
/// What is pinned here is the DECISION — which takes still need a picture —
/// rather than the decode itself: decoding needs a real movie, and this target
/// has no encoder. The decode's own path is `ContactSheet.exportThumbnails`,
/// which the contact sheet's tests cover.
@MainActor @Suite struct ControllerReportPosterTests {
    private func take(_ name: String) -> Take {
        Take(url: URL(fileURLWithPath: "/tmp/\(name).mov"), scene: "1",
             roll: "A001", takeNumber: 1, startTimecode: nil,
             durationSeconds: 4, recordedAt: Date())
    }

    @Test func onlyTheTakesWithoutAPictureAreDecoded() {
        let seen = take("A001C001")
        let unseen = take("A001C002")
        let cache: [UUID: NSImage] = [seen.id: NSImage(size: .init(width: 1, height: 1))]

        let needed = CaptureController.takesNeedingPosters([seen, unseen],
                                                            cached: cache)
        #expect(needed.map(\.id) == [unseen.id],
                "the report asked for \(needed.count) pictures, not the one missing")
    }

    /// A day nobody scrolled through: every take needs one, which is the case
    /// the old behaviour turned into a document of empty cells.
    @Test func anUnscrolledDayNeedsEveryPicture() {
        let takes = [take("A001C001"), take("A001C002"), take("A001C003")]
        #expect(CaptureController.takesNeedingPosters(takes, cached: [:]).count
            == 3)
    }

    /// …and one that was scrolled through decodes nothing, so the ordinary
    /// export stays as quick as it was.
    @Test func aScrolledDayDecodesNothing() {
        let takes = [take("A001C001"), take("A001C002")]
        let cache = Dictionary(uniqueKeysWithValues: takes.map {
            ($0.id, NSImage(size: .init(width: 1, height: 1)))
        })
        #expect(CaptureController.takesNeedingPosters(takes, cached: cache)
            .isEmpty)
    }
}

/// **The contact sheet is gone, and its poster decoder is not.**
///
/// The owner asked what the sheet was for twice ("смысла contact sheet так и
/// не увидел когда есть shift report"): it was the report's visual sibling —
/// same header, same vocabulary, one cell per take — and the report already
/// carries a poster beside every take. What had a second caller was the
/// decode, and that is why `TakePosters` exists rather than the file simply
/// being deleted.
@Suite struct ContactSheetRetirementTests {
    @Test func nothingInTheAppStillOffersAContactSheet() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var offenders: [String] = []
        var files = 0
        for folder in ["Sources", "Tests"] {
            let walker = try #require(FileManager.default.enumerator(
                at: root.appendingPathComponent(folder),
                includingPropertiesForKeys: nil))
            for case let url as URL in walker
            where ["swift", "strings"].contains(url.pathExtension) {
                guard url.lastPathComponent != "ControllerReportPosterTests.swift",
                      let raw = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                files += 1
                for (index, line) in raw.components(separatedBy: "\n").enumerated()
                where line.contains("ContactSheet") || line.contains("contact_") {
                    // The comment that says WHY it went is not an offender.
                    guard !line.trimmingCharacters(in: .whitespaces)
                        .hasPrefix("//"), !line.contains("///") else { continue }
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        try #require(files > 100, "the walk did not find the tree")
        #expect(offenders.isEmpty, """
            the retired document left something behind: \
            \(offenders.joined(separator: ", "))
            """)
    }

    /// …and the decode it left behind is the one the report uses.
    @Test func theReportsPosterDecoderSurvived() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/TakeShotKit/CaptureController+Reports.swift"),
            encoding: .utf8)
        #expect(source.contains("TakePosters.exportThumbnails"),
                "the report no longer decodes its own posters")
    }
}
