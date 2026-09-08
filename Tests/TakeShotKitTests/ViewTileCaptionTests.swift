import Foundation
import Testing

@testable import TakeShotKit

/// **What the tile caption keeps when there is not room for all of it.**
///
/// The operator's order, and it is the reverse of what the code did: the
/// beginning of the NAME first, then a duration, then a pixel size (owner:
/// "при минимальных размерах затираются название и хрон. лучше при минималке
/// оставлять начало названий, потом по важности хрон, а потом уже резолюшн").
///
/// The old rule was deliberate and written down — the badge kept its full width
/// and the name gave way — which at the narrowest tile left "3840×2160" and no
/// name: the file identified by the one fact every other file on the card
/// shares.
@Suite struct ViewTileCaptionTests {
    private let narrowest = TakeTileBadges.tileWidthRange.lowerBound
    private let widest = TakeTileBadges.tileWidthRange.upperBound

    /// A duration is four characters and survives the smallest tile there is.
    @Test func aDurationSurvivesTheNarrowestTile() {
        #expect(TakeTileBadges.metricFitsBesideName("0:02", tileWidth: narrowest))
        #expect(TakeTileBadges.metricFitsBesideName("12:34", tileWidth: narrowest))
    }

    /// A pixel size is nine and does not — it is the one the operator can also
    /// read off the picture, and the one that was eating the name.
    @Test func aPixelSizeGivesWayOnTheNarrowestTile() {
        #expect(!TakeTileBadges.metricFitsBesideName("3840×2160",
                                                     tileWidth: narrowest))
        #expect(!TakeTileBadges.metricFitsBesideName("1920×1080",
                                                     tileWidth: narrowest))
    }

    /// …and comes back as soon as there is room for it beside a readable name.
    @Test func aPixelSizeReturnsOnATileWithRoomForBoth() {
        #expect(TakeTileBadges.metricFitsBesideName("3840×2160", tileWidth: 150))
        #expect(TakeTileBadges.metricFitsBesideName("3840×2160", tileWidth: widest))
    }

    /// The rule is a width budget, not a list of known strings: whatever the
    /// metric turns out to be, what it has to leave behind is room for the
    /// start of a name.
    @Test func theRuleIsAWidthBudgetAndNotAListOfStrings() {
        let room = TakeTileBadges.minimumNameWidth + TakeTileBadges.metricSpacing
        let sixGlyphs = String(repeating: "8", count: 6)
        #expect(TakeTileBadges.metricFitsBesideName(
            sixGlyphs, tileWidth: room + 6 * TakeTileBadges.metricDigitWidth))
        #expect(!TakeTileBadges.metricFitsBesideName(
            sixGlyphs, tileWidth: room + 6 * TakeTileBadges.metricDigitWidth - 1))
    }
}
