import CaptureCore
import SwiftUI

/// Transport for the RAW engine: play/pause, frame scrubber, loop.
///
/// A thin configuration of the controls in `TransportControls.swift`. What is
/// only here is the frame-domain scrubber — this engine counts frames, not
/// seconds — and the codec badge.
struct RawTransportBar: View {
    @ObservedObject var model: RawPlayerModel
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(spacing: 10) {
            TransportPlayGroup(
                isPlaying: model.isPlaying,
                skipBack: { model.skip(seconds: -5) },
                togglePlay: { model.togglePlay() },
                skipForward: { model.skip(seconds: 5) })

            TransportTimeText(model.timecodeText)

            Slider(value: Binding(
                get: { Double(model.currentFrame) },
                set: { model.seek(to: Int($0)) }),
                in: 0...Double(max(1, model.frameCount - 1)))
                .controlSize(.small)
                .overlay {
                    MarkerTicks(markers: controller.playbackMarkers,
                                duration: Double(model.frameCount)
                                    / max(1, model.frameRate))
                }

            TransportTimeText(model.endTimecodeText)

            TransportRangeControls(engine: model)

            MarkerButton()

            RawDecodeFailureGlyph(model: model)

            RawFormatBadge(model: model)

            TransportFullscreenButton()
        }
        .transportBarChrome()
    }
}

/// The codec plate — and, for a format whose decoder chose a colour space, what
/// it chose.
///
/// Nothing in this app named a colour space to the operator before R3D: every
/// other source either arrives as Rec.709 on the wire or was developed to it on
/// the way in, so there was nothing to disclose. R3D genuinely had a choice (its
/// native output is REDWideGamutRGB / Log3G10, which on a Rec.709 viewer is
/// unjudgeable), so the plate states the transform, the decode reduction, and
/// whether the clip carries a camera look that is being withheld. Same argument
/// as the input-levels picker sitting on the player badge and not only in
/// Settings: how the signal is being interpreted belongs where the signal is.
struct RawFormatBadge: View {
    @ObservedObject var model: RawPlayerModel

    var body: some View {
        HStack(spacing: 3) {
            Text(model.formatBadge)
            if let divisor = model.colorNote?.scaleDivisor, divisor > 1 {
                Text(verbatim: "1/\(divisor)")
                    .foregroundStyle(.tertiary)
            }
            if let note = model.colorNote, note.cameraLUTName != nil {
                Image(systemName: note.cameraLUTApplied
                    ? "swatchpalette.fill" : "swatchpalette")
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(.secondary)
        .help(tooltip)
    }

    /// The colour statement (`RawColorNote.operatorLines`) followed by the
    /// camera's own facts.
    private var tooltip: String {
        ((model.colorNote?.operatorLines ?? []) + model.infoLines)
            .joined(separator: "\n")
    }
}

/// A decode that failed mid-clip, kept on screen for as long as the clip is
/// open. The toast beside it dismisses itself after five seconds; a corrupt
/// frame on a camera card is worth more than five seconds of the operator's
/// attention, and pausing silently is what makes it look like the clip ended.
struct RawDecodeFailureGlyph: View {
    @ObservedObject var model: RawPlayerModel

    var body: some View {
        if let error = model.playbackError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help(error)
        }
    }
}
