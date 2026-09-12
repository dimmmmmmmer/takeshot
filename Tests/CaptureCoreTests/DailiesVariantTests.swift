import Foundation
import Testing

@testable import CaptureCore

/// **More versions of the same day** (owner: "и да, очередь из нескольких
/// вариантов дейликов будет супер").
///
/// The value itself and what it survives: this travels through the settings
/// blob, which is a FLAT map read back by builds that do not have to be this
/// one.
@Suite struct DailiesVariantTests {
    @Test func aVariantSurvivesTheRoundTripThroughSettings() throws {
        let variant = DailiesVariant(resolution: .sd, codec: .proResLT,
                                     suffix: "_PHONE")
        let back: DailiesVariant = try #require(
            DailiesVariant(stored: variant.stored))
        #expect(back.resolution == .sd)
        #expect(back.codec == .proResLT)
        #expect(back.suffix == "_PHONE")
        // …and the id is NOT part of it: the row's identity is the list's
        // business and means nothing on disk
        #expect(back.id != variant.id)
    }

    /// A codec's raw value has spaces in it and a suffix is the operator's own
    /// text, so the separator has to be something neither can contain.
    @Test func aCodecWithSpacesInItsNameStillParses() throws {
        let stored = DailiesVariant(resolution: .hd, codec: .proResLT,
                                    suffix: "_EDIT").stored
        #expect(stored == "1080|ProRes 422 LT|_EDIT")
        #expect(DailiesVariant(stored: stored)?.codec == .proResLT)
    }

    /// One mangled entry must not cost an operator the others — the same
    /// leniency every other list in that blob has.
    @Test func anUnreadableEntryIsDroppedAndTheRestAreKept() {
        var settings = DailiesSettings()
        settings.variants = ["540|H.264|_PHONE", "nonsense",
                             "1080|Nonexistent Codec|_X",
                             "720|ProRes 422 LT|_EDIT"]
        let kept: [DailiesVariant] = settings.variantsEffective
        #expect(kept.count == 2)
        #expect(kept.map(\.suffix) == ["_PHONE", "_EDIT"])
    }

    /// A codec that is not offered for dailies is refused, for the reason
    /// `codecEffective` refuses one: a blob must not start a run that writes a
    /// review copy bigger than the take.
    @Test func aCodecThatIsNotADailiesChoiceIsRefused() {
        for codec in [CaptureCodec.proRes4444, .proResHQ, .proRes422] {
            #expect(!CaptureCodec.dailiesChoices.contains(codec))
            #expect(DailiesVariant(stored: "1080|\(codec.rawValue)|_X") == nil,
                    "\(codec.rawValue) is not a review copy")
        }
    }

    /// A hand-edited blob cannot ask for forty passes over a night's footage:
    /// the cost of a variant is a decode of every take, not a row in a list.
    @Test func theListIsCappedWhereTheModelCapsIt() {
        var settings = DailiesSettings()
        settings.variants = (0..<20).map { "540|H.264|_V\($0)" }
        #expect(settings.variantsEffective.count == DailiesVariant.limit)
    }

    @Test func noVariantsAtAllIsTheOrdinaryCase() {
        #expect(DailiesSettings().variantsEffective.isEmpty)
        var settings = DailiesSettings()
        settings.variants = []
        #expect(settings.variantsEffective.isEmpty)
    }
}
