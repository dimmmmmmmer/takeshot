import AppKit
import SwiftUI
import Testing

@testable import TakeShotKit

/// The footer's meter bank, which is one `Canvas` rather than a channel's worth
/// of laid-out subtrees.
///
/// It was a `ForEach` of `GeometryReader`s — sixteen of them for an SDI embed,
/// each with its own implicit animation — and `LiveSignal` publishes both the
/// levels AND the monitoring volume, so a drag of the popover's slider re-laid
/// out the whole bank per frame (owner: "по клику на иконку громкоговорителя
/// ползунок выпадающий лагает"). What is asserted here is what the rewrite must
/// not have changed: where the bars are, and which of them are dimmed.
@MainActor
struct ViewAudioMeterBankTests {
    /// The bank asks for exactly the bars plus the gaps between them — no gap
    /// after the last one, which is the off-by-one that would push the codec
    /// and the folder along beside it.
    @Test func theBankAsksForItsBarsAndTheGapsBetweenThem() {
        #expect(AudioMeterView.width(for: 0) == 0)
        #expect(AudioMeterView.width(for: 1) == AudioMeterView.idealBarWidth)
        let two = 2 * AudioMeterView.idealBarWidth + AudioMeterView.barSpacing
        #expect(AudioMeterView.width(for: 2) == two)
        // the 16-channel embed the footer's left-hand group is sized around
        let sixteen = 16 * AudioMeterView.idealBarWidth
            + 15 * AudioMeterView.barSpacing
        #expect(AudioMeterView.width(for: 16) == sixteen)
    }

    /// A channel that is carrying draws, one that is silent does not, and the
    /// bars land in their own columns rather than smearing across the bank.
    ///
    /// Driven through a real render rather than through the geometry helper:
    /// the helper is what the drawing READS, so asserting it against itself
    /// would pass with the Canvas drawing nothing at all.
    @Test func onlyTheCarryingChannelsDraw() {
        // four channels: two at full scale, two silent
        let levels: [Float] = [0, -60, 0, -60]
        let view = AudioMeterView(levels: levels, enabled: nil)
            .frame(height: 44)
        let size = CGSize(width: AudioMeterView.width(for: levels.count) + 8,
                          height: 44)
        let columns: [Int] = ViewRender.brightColumns(view, in: size)
        #expect(!columns.isEmpty, "the bank drew nothing at all")

        // the lit channels are the first and third, so nothing bright may fall
        // in the second channel's column
        let bar = AudioMeterView.idealBarWidth + AudioMeterView.barSpacing
        let secondChannel = Int(4 + bar)...Int(4 + bar + AudioMeterView.idealBarWidth)
        let bleed = columns.filter { secondChannel.contains($0) }
        #expect(bleed.isEmpty,
                "a silent channel's column has bright pixels in it: \(bleed)")
    }

    /// A channel that is not being recorded is dimmed rather than hidden: the
    /// operator still has to see that sound is arriving on it.
    @Test func aDisabledChannelIsDimmedAndStillDrawn() {
        let levels: [Float] = [0, 0]
        let size = CGSize(width: AudioMeterView.width(for: 2) + 8, height: 44)
        let lit = ViewRender.meanBrightness(
            AudioMeterView(levels: levels, enabled: [true, true])
                .frame(height: 44), in: size)
        let dimmed = ViewRender.meanBrightness(
            AudioMeterView(levels: levels, enabled: [true, false])
                .frame(height: 44), in: size)
        #expect(dimmed < lit, "dimming a channel changed nothing on screen")
        let dark = ViewRender.meanBrightness(
            AudioMeterView(levels: [-60, -60], enabled: [true, true])
                .frame(height: 44), in: size)
        #expect(dimmed > dark,
                "a dimmed channel is as dark as a silent one — it vanished")
    }
}
