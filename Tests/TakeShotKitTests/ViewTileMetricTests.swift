import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The one fact a tile states beside its name: a take's length, or an
/// Other-content item's length or pixel size (owner item 43).
///
/// Its own suite rather than more of `ViewTakesTileTests`, which is at the
/// type-length ceiling — and it is a question of its own anyway: that one is
/// about where the badges sit, this one is about the badge not wrapping.
@Suite @MainActor struct ViewTileMetricTests {
    /// The widest thing the badge is ever asked to show, and the value that
    /// wrapped: nine characters against a duration's four.
    private static let pixelSize = "6000×4000"

    /// The badge never takes a second line, however little width it is offered.
    ///
    /// On the caption line of a 70pt tile "6000×4000" used to wrap into a
    /// column. That is not only ugly — the tile grows taller than its
    /// neighbours, so one photo in the record folder breaks the grid's row.
    @Test func theMetricBadgeStaysOnOneLineAtTheSmallestTile() async throws {
        try await ViewProbe.run { probe in
            let smallest = TakeTileBadges.tileWidthRange.lowerBound
            let oneLine = probe.fittingSizes {
                TileMetricBadge(text: Self.pixelSize, onImage: false)
            }
            let squeezed = probe.sizes(proposedWidth: smallest,
                                       proposedHeight: 400) {
                TileMetricBadge(text: Self.pixelSize, onImage: false)
            }
            #expect(squeezed.en.height == oneLine.en.height,
                    "the size badge wrapped: \(squeezed.en) against \(oneLine.en)")
            #expect(squeezed.ru == squeezed.en)

            // …and the plated flavour, which the mid-sized tiles carry ON the
            // picture: the same badge, so the same rule
            let duration = probe.fittingSizes { TileMetricBadge(text: "0:42") }
            let plated = probe.sizes(proposedWidth: smallest,
                                     proposedHeight: 400) {
                TileMetricBadge(text: Self.pixelSize)
            }
            #expect(plated.en.height == duration.en.height,
                    "the plated size badge is \(plated.en.height)pt — it wrapped")
            #expect(plated.en.height == TakeTileBadges.durationHeight,
                    "the badge renders \(plated.en.height)pt, layout assumes \(TakeTileBadges.durationHeight)")
        }
    }

    /// The acceptance case: at the smallest tile a photo's cell is exactly as
    /// tall as a clip's. It is a grid — one taller tile is a ragged row.
    @Test func aPhotoTileIsNoTallerThanAClipTileAtTheSmallestSize() async throws {
        try await ViewProbe.run { probe in
            let other = try ViewFixtures.seedOtherFiles(probe.controller,
                                                        in: probe.root)
            for width in [TakeTileBadges.tileWidthRange.lowerBound, 100.0] {
                let clip = probe.sizes(proposedWidth: width,
                                       proposedHeight: 400) {
                    OtherCell(url: other[0], tileWidth: width)
                }
                let photo = probe.sizes(proposedWidth: width,
                                        proposedHeight: 400) {
                    OtherCell(url: other[1], tileWidth: width)
                }
                #expect(photo.en.height == clip.en.height,
                        "at \(width)pt the photo tile is \(photo.en.height)pt, the clip \(clip.en.height)")
                #expect(photo.ru == photo.en)
                #expect(photo.en.width <= width,
                        "the \(width)pt photo tile wants \(photo.en.width)pt")
            }
        }
    }

    /// The badge keeps its width and the NAME gives way, not the other way
    /// round: a middle-truncated file name reads fine short, "6000×…" does not.
    @Test func theFileNameGivesWayToTheMetricNotTheOtherWayRound() async throws {
        try await ViewProbe.run { probe in
            let other = try ViewFixtures.seedOtherFiles(probe.controller,
                                                        in: probe.root)
            let width = TakeTileBadges.tileWidthRange.lowerBound
            let badge = probe.fittingSizes {
                TileMetricBadge(text: Self.pixelSize, onImage: false)
            }
            // the tile is narrower than the name plus the badge, so something
            // has to give — and the badge must still be drawn in full
            let cell = probe.sizes(proposedWidth: width, proposedHeight: 400) {
                OtherCell(url: other[1], tileWidth: width)
            }
            #expect(badge.en.width < width,
                    "the badge alone does not fit a \(width)pt tile: \(badge.en)")
            #expect(cell.en.width <= width)
        }
    }
}
