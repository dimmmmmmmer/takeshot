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

            Text(model.formatBadge)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.secondary)

            TransportFullscreenButton()
        }
        .transportBarChrome()
    }
}
