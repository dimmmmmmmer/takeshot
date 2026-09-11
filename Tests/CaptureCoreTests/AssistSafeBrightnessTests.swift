import CoreImage
import Foundation
import Testing

@testable import CaptureCore

/// **The safe areas have their own brightness** (owner: "добавь в сейфзоны
/// ползунок настройки их яркости").
///
/// They ship at 0.45 and 0.30 of white — right over a mid-grey scene, and
/// either swallowed by a night exterior or the loudest thing in the frame over
/// a white cyc. The slider scales both, and these are the two things that have
/// to stay true while it does: the inner box stays the fainter of the pair,
/// and the FRAMELINE does not move with them.
@Suite struct AssistSafeBrightnessTests {
    private func drawn(_ guides: AssistGuides, size: CGSize = CGSize(width: 320,
                                                                     height: 180))
        -> [UInt8] {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: size))
        let out = guides.drawn(over: black)
        let context = CIContext(options: [.cacheIntermediates: false])
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(out, toBitmap: base,
                           rowBytes: Int(size.width) * 4,
                           bounds: CGRect(origin: .zero, size: size),
                           format: .RGBA8, colorSpace: nil)
        }
        return bytes
    }

    /// Total ink: the safe boxes are the only thing drawn, so the sum over the
    /// frame is what the brightness scales.
    private func ink(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
    }

    @Test func theBrightnessScalesTheSafeAreasAndNothingElse() {
        var full = AssistGuides()
        full.safeAreas = true
        var dim = full
        dim.safeBrightness = 0.25

        let bright = ink(drawn(full))
        let faint = ink(drawn(dim))
        #expect(bright > 0, "the safe areas drew nothing at all")
        #expect(faint > 0, """
            a quarter brightness drew nothing — an aid that is ON and invisible \
            is a switch that looks broken
            """)
        #expect(Double(faint) < Double(bright) * 0.5, """
            a quarter brightness drew \(faint) against \(bright) at full
            """)
    }

    /// The frameline is a statement about the deliverable's crop and keeps its
    /// own weight: dimming the safe areas must not fade the frame with them.
    @Test func theFramelineKeepsItsOwnWeight() {
        var framed = AssistGuides()
        framed.ratio = 2.39
        var dimmedSafes = framed
        dimmedSafes.safeBrightness = 0.1
        #expect(ink(drawn(framed)) == ink(drawn(dimmedSafes)), """
            the safe-area slider moved a frameline that is not drawn with them
            """)
    }

    /// Out-of-range values are clamped rather than trusted — a blob edited by
    /// hand cannot hand the compositor an alpha off the scale.
    @Test func theBrightnessIsClampedToWhatCanBeDrawn() {
        var guides = AssistGuides()
        guides.safeBrightness = 4
        #expect(guides.safeAlphaScale == 1)
        guides.safeBrightness = -1
        #expect(guides.safeAlphaScale == 0.05)
    }
}
