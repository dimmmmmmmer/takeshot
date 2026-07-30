import CaptureCore
import SwiftUI

/// Transport for the RAW engine: play/pause, frame scrubber, loop.
struct RawTransportBar: View {
    @ObservedObject var model: RawPlayerModel
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.seek(to: model.currentFrame - Int(model.frameRate * 5))
            } label: {
                Image(systemName: "gobackward.5")
            }
            .buttonStyle(.plain)

            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                model.seek(to: model.currentFrame + Int(model.frameRate * 5))
            } label: {
                Image(systemName: "goforward.5")
            }
            .buttonStyle(.plain)

            Text(model.timecodeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

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

            Text(model.endTimecodeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                model.toggleRangePoint(out: false)
            } label: {
                Image(systemName: TransportModel.inPointSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(model.inPoint != nil
                                     ? AnyShapeStyle(controller.accentColor)
                                     : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(L("loop_in_help"))

            Button {
                model.isLooping.toggle()
            } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(model.isLooping
                                     ? AnyShapeStyle(controller.accentColor)
                                     : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(L("playback_loop"))

            Button {
                model.toggleRangePoint(out: true)
            } label: {
                Image(systemName: TransportModel.outPointSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(model.outPoint != nil
                                     ? AnyShapeStyle(controller.accentColor)
                                     : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(L("loop_out_help"))

            MarkerButton()

            Text(model.formatBadge)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.secondary)

            Button {
                controller.togglePlaybackFullscreen()
            } label: {
                Image(systemName: controller.isPlaybackFullscreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help(L("fullscreen_playback"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
    }
}
