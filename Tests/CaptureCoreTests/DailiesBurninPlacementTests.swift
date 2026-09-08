import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

/// **Where the burn-ins go, now that it is the operator's choice.**
///
/// The layout was fixed — timecode top-centre, clip name bottom-left, project
/// bottom-right, the free line top-left — which is the classic arrangement and
/// is right until it is not: a camera that burns its own timecode into the top
/// of the frame, a slate in one corner, a client who reads the reel somewhere
/// else (owner: "в дейлизах хочется при настройке оверлеев какой-то большей
/// кастомизации положения и настроек").
///
/// Two lines can now be sent to the same corner, which was impossible before
/// and is one picker away today — so the stacking rule is part of the feature
/// rather than a detail of it.
@Suite struct DailiesBurninPlacementTests {
    private let size = CGSize(width: 1920, height: 1080)

    private func layout(_ texts: DailiesOverlay.Texts) -> DailiesOverlay.Layout {
        DailiesOverlay(size: size, texts: texts).layout
    }

    /// The default arrangement is the classic one, unchanged: every existing
    /// caller means this, and a default that moved would re-lay out every
    /// operator's dailies without being asked.
    @Test func theDefaultsAreTheClassicArrangement() throws {
        let placed = layout(DailiesOverlay.Texts(
            custom: "CAMERA A", clipName: "A001C001", project: "FILM · A001",
            timecodeTemplate: "00:00:00:00"))
        let timecode = try #require(placed.timecode)
        let custom = try #require(placed.custom)
        let clipName = try #require(placed.clipName)
        let project = try #require(placed.project)

        #expect(abs(timecode.midX - size.width / 2) < 2, "TC is not centred")
        #expect(timecode.minY < size.height / 2, "TC is not along the top")
        #expect(custom.minX < size.width / 2, "the free line is not on the left")
        #expect(custom.minY < size.height / 2, "the free line is not at the top")
        #expect(clipName.minX < size.width / 2)
        #expect(clipName.minY > size.height / 2, "the clip name is not at the bottom")
        #expect(project.maxX > size.width / 2, "the project is not on the right")
        #expect(project.minY > size.height / 2)
    }

    /// Every one of the six places puts a line where its name says.
    @Test func eachPositionPutsTheLineWhereItsNameSays() throws {
        for position in DailiesBurninPosition.allCases {
            let placed = layout(DailiesOverlay.Texts(
                clipName: "A001C001", clipNamePosition: position))
            let rect = try #require(placed.clipName,
                                    Comment(rawValue: "\(position) drew nothing"))
            if position.isTop {
                #expect(rect.minY < size.height / 2,
                        Comment(rawValue: "\(position) is not along the top"))
            } else {
                #expect(rect.minY > size.height / 2,
                        Comment(rawValue: "\(position) is not along the bottom"))
            }
            switch position {
            case .topLeft, .bottomLeft:
                #expect(rect.minX < size.width / 3,
                        Comment(rawValue: "\(position) is not on the left"))
            case .topCenter, .bottomCenter:
                #expect(abs(rect.midX - size.width / 2) < 2,
                        Comment(rawValue: "\(position) is not centred"))
            case .topRight, .bottomRight:
                #expect(rect.maxX > size.width * 2 / 3,
                        Comment(rawValue: "\(position) is not on the right"))
            }
        }
    }

    /// **Two lines in one corner stack; they do not overlap.** A line hidden
    /// under another is worse than a line in the wrong place: the operator
    /// cannot see that it is there, and a whole day's dailies carry the
    /// mistake.
    @Test func twoLinesInOneCornerStackInsteadOfOverlapping() throws {
        let placed = layout(DailiesOverlay.Texts(
            clipName: "A001C001", project: "FILM · A001",
            clipNamePosition: .bottomLeft, projectPosition: .bottomLeft))
        let first = try #require(placed.clipName)
        let second = try #require(placed.project)

        #expect(!first.intersects(second), """
            the two strips overlap: \(first) and \(second)
            """)
        // …and the second steps INWARD from the bottom edge, not off the frame
        #expect(second.minY < first.minY, "the second strip went off the bottom")
        #expect(second.minY > 0)
    }

    /// The same at the top, where stacking runs the other way.
    @Test func stackingAtTheTopRunsDownwards() throws {
        let placed = layout(DailiesOverlay.Texts(
            custom: "CAMERA A", timecodeTemplate: "00:00:00:00",
            customPosition: .topCenter, timecodePosition: .topCenter))
        let timecode = try #require(placed.timecode)
        let custom = try #require(placed.custom)

        #expect(!timecode.intersects(custom))
        #expect(custom.minY > timecode.minY,
                "the second strip did not step down from the top")
        #expect(custom.maxY < size.height)
    }
}
