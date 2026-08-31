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

    /// The channel panel's single bars fill from the bottom to the level, and
    /// no further.
    ///
    /// They were the one meter the `Canvas` rewrite missed: a `GeometryReader`
    /// around three `Rectangle`s whose HEIGHTS were the level, with a 0.07 s
    /// implicit animation over that layout at the call site — sixteen of them
    /// in the channel panel, re-laid-out on every audio tick.
    ///
    /// Rendered rather than measured through the helper: the helper is what the
    /// drawing reads, so asserting it against itself would pass with the bar
    /// drawing nothing.
    @Test func aChannelBarFillsFromTheBottomToItsLevel() throws {
        let size = CGSize(width: 20, height: 170)
        let full = try #require(ViewRender.drawnBounds(SegmentedMeterBar(level: 0),
                                                       in: size),
                                "a bar at full scale drew nothing")
        #expect(full.height > size.height * 0.9, "full scale did not fill")

        // -30 dBFS is half the -60…0 scale
        let half = try #require(ViewRender.drawnBounds(SegmentedMeterBar(level: -30),
                                                       in: size),
                                "a bar at -30 dBFS drew nothing")
        #expect(abs(half.height - size.height / 2) < 6,
                "half scale drew \(half.height)pt of \(size.height)")
        // it grows from the BOTTOM: the top of a half bar is mid-height, and
        // its bottom is the bar's bottom
        #expect(abs(half.maxY - size.height) < 3, "the bar left the floor")
        #expect(abs(half.minY - size.height / 2) < 6,
                "the bar's top is at \(half.minY), not mid-height")

        // silence draws nothing at all rather than a sliver of green
        #expect(ViewRender.drawnBounds(SegmentedMeterBar(level: -60), in: size) == nil)
    }

    /// Yellow starts at -10 dBFS and red at -5 — the marks the footer's bank
    /// reads too, since both now draw through `AudioMeterView.fill`.
    ///
    /// Measured off the rendered bar rather than off the constants: the
    /// constants are what the drawing reads, so comparing them to themselves
    /// would hold even if the bands were drawn in the wrong order.
    @Test func theBandsChangeColourAtTheMarks() throws {
        let size = CGSize(width: 20, height: 200)
        // hot enough to show all three bands
        let bands = try #require(Self.bandTops(SegmentedMeterBar(level: 0), in: size))
        #expect(bands.green != nil && bands.yellow != nil && bands.red != nil,
                "a bar at full scale is missing a band: \(bands)")

        // The bands stack from the bottom, so the TOP of each one is the mark
        // where the next takes over: green ends where yellow starts, yellow
        // ends where red starts, and red ends at the level itself.
        let greenTop = 1 - (try #require(bands.green)) / size.height
        let yellowTop = 1 - (try #require(bands.yellow)) / size.height
        let redTop = 1 - (try #require(bands.red)) / size.height
        #expect(abs(greenTop - SegmentedMeterBar.yellowMark) < 0.04,
                "green runs to \(greenTop), not \(SegmentedMeterBar.yellowMark)")
        #expect(abs(yellowTop - SegmentedMeterBar.redMark) < 0.04,
                "yellow runs to \(yellowTop), not \(SegmentedMeterBar.redMark)")
        #expect(redTop > 0.97, "red stopped short of full scale at \(redTop)")

        // a bar that never reaches -10 is green all the way up
        let quiet = try #require(Self.bandTops(SegmentedMeterBar(level: -30), in: size))
        #expect(quiet.green != nil)
        #expect(quiet.yellow == nil && quiet.red == nil,
                "a -30 dBFS bar showed a warning band: \(quiet)")
    }

    /// The topmost row at which each of the three band colours appears, in
    /// points from the top of the bar. A colour probe rather than a brightness
    /// one: which band it is, is the thing being asserted.
    private struct BandTops: CustomStringConvertible {
        var green: CGFloat?
        var yellow: CGFloat?
        var red: CGFloat?
        var description: String {
            "green: \(green as Any), yellow: \(yellow as Any), red: \(red as Any)"
        }
    }

    private static func bandTops(_ view: some View, in size: CGSize) -> BandTops? {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(max(1, rep.pixelsHigh / max(1, Int(size.height))))
        var green: CGFloat?, yellow: CGFloat?, red: CGFloat?
        let x = rep.pixelsWide / 2
        for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.genericRGB),
                  c.alphaComponent > 0.5 else { continue }
            let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
            guard max(r, g) > 0.35, b < 0.5 else { continue }  // skip the track
            let point = CGFloat(y) / scale
            if r < 0.4, g > 0.4 { green = green ?? point }          // green
            else if r > 0.4, g > 0.4 { yellow = yellow ?? point }   // yellow
            else if r > 0.4, g < 0.4 { red = red ?? point }         // red
        }
        return BandTops(green: green, yellow: yellow, red: red)
    }
}
