import CaptureCore
import SwiftUI

/// Preview grid of all cameras in multicam mode (main + extras).
struct MulticamGrid: View {
    @EnvironmentObject private var controller: CaptureController

    private var columns: Int {
        let n = 1 + controller.extraChannels.count
        return n <= 1 ? 1 : (n <= 4 ? 2 : 3)
    }

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: columns)
        LazyVGrid(columns: cols, spacing: 4) {
            MainCameraTile(live: controller.live)
            ForEach(controller.extraChannels) { channel in
                CameraTileChannel(channel: channel,
                                  background: controller.playerBackground)
            }
        }
        .padding(4)
    }
}

/// Main-camera tile: observes LiveSignal for TC so only the tile re-renders.
private struct MainCameraTile: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var live: LiveSignal

    var body: some View {
        CameraTile(pipeline: controller.pipeline,
                   label: controller.settings.cameraLabel,
                   timecode: live.currentTimecode,
                   recording: controller.isRecording,
                   background: controller.playerBackground)
    }
}

private struct CameraTileChannel: View {
    @ObservedObject var channel: CameraChannel
    let background: Color

    var body: some View {
        CameraTile(pipeline: channel.pipeline,
                   label: channel.camLabel,
                   timecode: channel.currentTimecode,
                   recording: channel.isRecording,
                   background: background)
    }
}

private struct CameraTile: View {
    let pipeline: CapturePipeline
    let label: String
    let timecode: Timecode?
    let recording: Bool
    let background: Color

    var body: some View {
        ZStack {
            Rectangle().fill(background)
            LivePreviewLayerView(pipeline: pipeline)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(recording ? Color.red.opacity(0.9) : .white.opacity(0.12),
                          lineWidth: recording ? 2.5 : 1))
        .overlay(alignment: .topLeading) {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            Text(timecode?.description ?? "--:--:--:--")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(recording ? .red : .white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
        }
    }
}
