import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The thumbnail grid in the takes panel.
///
/// A tile is 16:9, so its height follows the tile-size slider: at the small end
/// the picture is 39pt tall and the comment/circle-take cluster and the duration
/// badge together want 49. They used to be pinned to opposite corners regardless
/// and printed straight over each other.
///
/// The badge sizes here are measured — the real capsule, the real pill, rendered
/// through NSHostingView in both languages — and then walked across the whole
/// slider range as rectangles. So "they never collide" is checked at every tile
/// size the operator can dial in, and the constants the layout decides from
/// cannot drift away from what the badges actually render as.
@Suite @MainActor struct ViewTakesTileTests {
    /// Every 5pt of the slider, both ends included.
    private var tileWidths: [Double] {
        let range = TakeTileBadges.tileWidthRange
        return Array(stride(from: range.lowerBound, to: range.upperBound, by: 5))
            + [range.upperBound]
    }

    /// The longest duration a badge can be asked to show on a shift: a 100
    /// minute take. The pill is the widest thing in the bottom corner, so its
    /// width is what decides whether the corners can meet.
    private static let longTakeSeconds: Double = 100 * 60 + 7

    @Test func theBadgeConstantsMatchWhatTheBadgesRender() async throws {
        try await ViewProbe.run { probe in
            let takes = try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let take = try #require(takes.first)

            let assumedControls = TakeTileBadges.controlsHeight
            let controls = probe.fittingSizes { TakeTileControls(take: take) }
            #expect(controls.en.height == assumedControls,
                    "the capsule renders \(controls.en.height)pt, layout assumes \(assumedControls)")
            #expect(controls.ru == controls.en,
                    "icons only, so the capsule cannot change with the language")

            let assumedPill = TakeTileBadges.durationHeight
            let pill = probe.fittingSizes {
                TakeDurationBadge(seconds: Self.longTakeSeconds)
            }
            #expect(pill.en.height == assumedPill,
                    "the pill renders \(pill.en.height)pt, layout assumes \(assumedPill)")
            #expect(pill.ru == pill.en, "the duration is digits in both languages")
        }
    }

    /// The acceptance case: no tile size puts the two badges in the same place,
    /// and neither of them hangs off the picture.
    @Test func theBadgesNeverMeetAtAnyTileSize() async throws {
        try await ViewProbe.run { probe in
            let takes = try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let take = try #require(takes.first)
            // Russian cannot widen either badge, but measure the wider of the two
            // languages anyway rather than assuming it
            let controlsSizes = probe.fittingSizes { TakeTileControls(take: take) }
            let pillSizes = probe.fittingSizes {
                TakeDurationBadge(seconds: Self.longTakeSeconds)
            }
            let controls = CGSize(
                width: max(controlsSizes.en.width, controlsSizes.ru.width),
                height: max(controlsSizes.en.height, controlsSizes.ru.height))
            let pill = CGSize(width: max(pillSizes.en.width, pillSizes.ru.width),
                              height: max(pillSizes.en.height, pillSizes.ru.height))

            for width in tileWidths {
                let bounds = CGSize(
                    width: width,
                    height: TakeTileBadges.thumbnailHeight(tileWidth: width))
                let picture = CGRect(origin: .zero, size: bounds)
                let controlsRect = TakeTileBadges.controlsFrame(size: controls,
                                                                in: bounds)
                #expect(picture.contains(controlsRect),
                        "the controls hang off a \(width)pt tile: \(controlsRect)")
                guard TakeTileBadges.bothFitOnImage(thumbnailHeight: bounds.height)
                else { continue }
                let pillRect = TakeTileBadges.durationFrame(size: pill, in: bounds)
                #expect(picture.contains(pillRect),
                        "the duration hangs off a \(width)pt tile: \(pillRect)")
                #expect(!controlsRect.intersects(pillRect),
                        "at \(width)pt the badges overlap: \(controlsRect)/\(pillRect)")
            }
        }
    }

    /// Which way the layout goes at each end of the slider. The small tile is the
    /// case the operator reported; the big one has to keep the duration on the
    /// picture, or the fix would have taken it away from everybody.
    @Test func theSmallestTileMovesTheDurationOffThePicture() {
        let range = TakeTileBadges.tileWidthRange
        let small = TakeTileBadges.thumbnailHeight(tileWidth: range.lowerBound)
        let large = TakeTileBadges.thumbnailHeight(tileWidth: range.upperBound)

        #expect(!TakeTileBadges.bothFitOnImage(thumbnailHeight: small),
                "a \(range.lowerBound)pt tile is \(small)pt tall — too short for both")
        #expect(TakeTileBadges.bothFitOnImage(thumbnailHeight: large))
        // and the switch happens once, not repeatedly, across the slider
        let flips = stride(from: range.lowerBound, through: range.upperBound,
                          by: 1).map {
            TakeTileBadges.bothFitOnImage(
                thumbnailHeight: TakeTileBadges.thumbnailHeight(tileWidth: $0))
        }
        #expect(zip(flips, flips.dropFirst()).filter { $0 != $1 }.count == 1,
                "the layout flips more than once across the slider")
    }

    /// A tile is laid out at exactly the slider's value (`gridColumns` pins
    /// min == max), so nothing inside it may ask for more — in either language,
    /// and least of all at the smallest size where the duration shares the
    /// caption line with the file name.
    @Test func aTileNeverOverflowsItsColumn() async throws {
        try await ViewProbe.run { probe in
            let takes = try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let take = try #require(takes.first)
            let other = try ViewFixtures.seedOtherFiles(probe.controller,
                                                        in: probe.root)

            for width in [TakeTileBadges.tileWidthRange.lowerBound, 100.0, 150.0] {
                let laid = probe.sizes(proposedWidth: width, proposedHeight: 400) {
                    TakeCell(take: take, tileWidth: width)
                }
                #expect(laid.en.width <= width,
                        "the \(width)pt tile wants \(laid.en.width)pt in English")
                #expect(laid.ru.width <= width,
                        "the \(width)pt tile wants \(laid.ru.width)pt in Russian")
                // the Other-content tile carries the same two-line budget, and
                // the photo is the wide case: "6000×4000" beside a file name
                for url in other {
                    let name = url.lastPathComponent
                    let cell = probe.sizes(proposedWidth: width,
                                           proposedHeight: 400) {
                        OtherCell(url: url, tileWidth: width)
                    }
                    #expect(cell.en.width <= width,
                            "\(name) at \(width)pt wants \(cell.en.width)pt")
                    #expect(cell.ru == cell.en,
                            "\(name) changed with the language: \(cell)")
                }
            }
        }
    }

    /// The whole panel in grid mode at the smallest tile, squeezed to the
    /// narrowest the split view allows — the render the reported bug was visible
    /// in.
    @Test func theGridFitsTheNarrowestPanelAtTheSmallestTile() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            probe.store.set("grid", forKey: "takesViewMode")
            probe.store.set(TakeTileBadges.tileWidthRange.lowerBound,
                            forKey: "takesTileSize")
            #expect(probe.store.string(forKey: "takesViewMode") == "grid")

            let panel = ViewBudget.panelMinWidth
            let minimum = probe.minimumWidths(proposedHeight: 600) { TakeListView() }
            #expect(minimum.ru <= panel,
                    "the smallest-tile grid needs \(minimum.ru)pt of \(panel)")
            #expect(minimum.ru == minimum.en)
        }
    }

    // MARK: - a tile is 16:9 whatever it is handed (owner item 26)

    /// The picture in a tile is a fixed 16:9 cell for EVERY source aspect.
    ///
    /// It used to be a ZStack of a black plate and a `.scaledToFill()` image
    /// under `.aspectRatio(16/9, contentMode: .fit)`. Fill answers a proposal
    /// with a size that COVERS it, the stack takes the larger of its children,
    /// and `.aspectRatio` reports whatever its child measured — so one vertical
    /// clip in the folder produced a tile several times taller than the grid's
    /// row. Measured at both ends of the slider and in the middle.
    @Test func theTilePictureIs16By9ForEverySourceAspect() async throws {
        try await ViewProbe.run { probe in
            for aspect in ViewFixtures.thumbnailAspects {
                let image = ViewFixtures.thumbnail(width: aspect.width,
                                                   height: aspect.height)
                for width in [TakeTileBadges.tileWidthRange.lowerBound,
                              150.0, TakeTileBadges.tileWidthRange.upperBound] {
                    let expected = TakeTileBadges.thumbnailHeight(tileWidth: width)
                    let laid = probe.size(
                        TakeTileThumbnail(image: image) { Color.clear },
                        proposedWidth: width, proposedHeight: 4000)
                    #expect(abs(laid.height - expected) <= 0.5,
                            "\(aspect.name)/\(width)pt: \(laid.height)pt, 16:9 wants \(expected)pt")
                    #expect(laid.width <= width,
                            "\(aspect.name) at \(width)pt is \(laid.width)pt wide")
                }
            }
        }
    }

    /// The acceptance case the operator reported: the grid stays uniform. A
    /// portrait clip's whole tile — picture, badges and caption line — has to
    /// measure exactly what a 16:9 clip's does, in both languages.
    @Test func aPortraitThumbnailDoesNotResizeItsTile() async throws {
        try await ViewProbe.run { probe in
            let takes = try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let take = try #require(takes.first)
            let other = try ViewFixtures.seedOtherFiles(probe.controller,
                                                        in: probe.root)

            for width in [TakeTileBadges.tileWidthRange.lowerBound, 150.0] {
                var takeSizes: [String: (en: CGSize, ru: CGSize)] = [:]
                var otherSizes: [String: (en: CGSize, ru: CGSize)] = [:]
                for aspect in ViewFixtures.thumbnailAspects {
                    let image = ViewFixtures.thumbnail(width: aspect.width,
                                                       height: aspect.height)
                    probe.controller.thumbnails[take.id] = image
                    probe.controller.otherThumbnails[other[0]] = image
                    takeSizes[aspect.name] = probe.sizes(proposedWidth: width,
                                                         proposedHeight: 4000) {
                        TakeCell(take: take, tileWidth: width)
                    }
                    otherSizes[aspect.name] = probe.sizes(proposedWidth: width,
                                                          proposedHeight: 4000) {
                        OtherCell(url: other[0], tileWidth: width)
                    }
                }
                let reference = try #require(takeSizes["16:9"])
                for (name, size) in takeSizes {
                    #expect(size.en == reference.en,
                            "\(name) take tile/\(width)pt: \(size.en) vs \(reference.en)")
                    #expect(size.ru == size.en, "\(name) take tile: \(size)")
                }
                let otherRef = try #require(otherSizes["16:9"])
                for (name, size) in otherSizes {
                    #expect(size.en == otherRef.en,
                            "\(name) other tile/\(width)pt: \(size.en) vs \(otherRef.en)")
                    #expect(size.ru == size.en, "\(name) other tile: \(size)")
                }
            }
        }
    }

    // MARK: - photo or video, at a glance (owner item 27)

    /// The type badge's rendered height is the number the tile layout decides
    /// from — the same discipline the take badges above are held to.
    @Test func theTypeBadgeMatchesTheConstantTheLayoutUses() async throws {
        try await ViewProbe.run { probe in
            let other = try ViewFixtures.seedOtherFiles(probe.controller,
                                                        in: probe.root)
            let assumed = TakeTileBadges.typeBadgeHeight
            for url in other {
                let badge = probe.fittingSizes { OtherTypeBadge(url: url) }
                #expect(badge.en.height == assumed,
                        "\(url.lastPathComponent): \(badge.en.height)pt, layout assumes \(assumed)")
                #expect(badge.ru == badge.en,
                        "a glyph cannot change with the language: \(badge)")
            }
            // and the pair fits above the metric pill at the sizes that claim to
            let metric = probe.fittingSizes { TileMetricBadge(text: "6000×4000") }
            let range = TakeTileBadges.tileWidthRange
            for width in stride(from: range.lowerBound, through: range.upperBound,
                                by: 5) {
                let height = TakeTileBadges.thumbnailHeight(tileWidth: width)
                guard TakeTileBadges.typeAndMetricFitOnImage(thumbnailHeight: height)
                else { continue }
                #expect(TakeTileBadges.typeBadgeHeight + metric.en.height
                            + 3 * TakeTileBadges.inset <= height,
                        "at \(width)pt the two badges do not fit \(height)pt")
            }
        }
    }

    /// A clip answers with its length and a photo with its pixel size — the
    /// second, quieter half of telling the two apart, and the reason the cell
    /// never shows a duration for a still.
    @Test func otherContentShowsLengthForClipsAndSizeForPhotos() async throws {
        try await ViewProbe.run { probe in
            let other = try ViewFixtures.seedOtherFiles(probe.controller,
                                                        in: probe.root)
            #expect(!otherIsPhoto(other[0]))
            #expect(otherIsPhoto(other[1]))
            #expect(probe.controller.otherMetricText(for: other[0]) == "0:42")
            #expect(probe.controller.otherMetricText(for: other[1]) == "6000×4000")

            // nothing decoded yet is a third state, and it says nothing rather
            // than "0:00" — which would read as an empty clip
            let unknown = probe.root.appendingPathComponent("not_decoded.mov")
            #expect(probe.controller.otherMetricText(for: unknown) == nil)
        }
    }

    /// The selection outline is an overlay on purpose: the panel's widths are
    /// measured to the point elsewhere in this suite, and a selected tile must
    /// not be a different size from an unselected one — in either language.
    @Test func selectingAnItemDoesNotResizeIt() async throws {
        try await ViewProbe.run { probe in
            let takes = try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let take = try #require(takes.first)
            let other = try ViewFixtures.seedOtherFiles(probe.controller,
                                                        in: probe.root)

            let quietTile = probe.fittingSizes { TakeCell(take: take, tileWidth: 150) }
            let quietRow = probe.fittingSizes { TakeRow(take: take) }
            let quietOther = probe.fittingSizes { OtherRow(url: other[0]) }

            probe.controller.clickPanelItem(take.url)
            probe.controller.clickPanelItem(other[0], command: true)

            let tile = probe.fittingSizes { TakeCell(take: take, tileWidth: 150) }
            let row = probe.fittingSizes { TakeRow(take: take) }
            let otherRow = probe.fittingSizes { OtherRow(url: other[0]) }

            #expect(tile == quietTile, "the outline resized the tile: \(tile)")
            #expect(row == quietRow, "the outline resized the take row: \(row)")
            #expect(otherRow == quietOther,
                    "the outline resized the other-content row: \(otherRow)")
        }
    }

    /// The rows the selection was added to, squeezed to the narrowest panel the
    /// split view allows. A take row carries a comment ("проверка объектива" in
    /// the fixture) and an Other-content row a file name, so Russian is the case
    /// that decides whether either one can still be made to fit.
    @Test func theSelectableRowsFitTheNarrowestPanel() async throws {
        try await ViewProbe.run { probe in
            let takes = try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let take = try #require(takes.first)
            let other = try ViewFixtures.seedOtherFiles(probe.controller,
                                                        in: probe.root)
            let panel = ViewBudget.panelMinWidth

            let takeRow = probe.minimumWidths(proposedHeight: 200) {
                TakeRow(take: take)
            }
            #expect(takeRow.ru <= panel,
                    "the take row needs \(takeRow.ru)pt of \(panel)")
            let otherRow = probe.minimumWidths(proposedHeight: 200) {
                OtherRow(url: other[0])
            }
            #expect(otherRow.ru <= panel,
                    "the other-content row needs \(otherRow.ru)pt of \(panel)")
            #expect(otherRow.ru == otherRow.en,
                    "the other-content row changed with the language: \(otherRow)")
        }
    }
}
