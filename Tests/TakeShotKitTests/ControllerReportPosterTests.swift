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
