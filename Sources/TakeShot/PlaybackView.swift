import AVFoundation
import CaptureCore
import Combine
import SwiftUI

/// Playback content without the transport (also used in compare modes):
/// video (the unified sample-buffer render, like live) or a photo.
struct PlaybackContent: View {
    @EnvironmentObject private var controller: CaptureController

    static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr2", "webp"]

    var body: some View {
        if let url = controller.playbackURL {
            if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                ImagePlaybackView(url: url)
            } else {
                TapLayerView(tap: controller.playbackTap)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 40))
                Text(L("playback_pick_hint"))
                    .font(.headline)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Playback mount: its own layer, registered as a tap sink for its lifetime.
private struct TapLayerView: NSViewRepresentable {
    let tap: PlaybackFrameTap

    final class Coordinator {
        var tap: PlaybackFrameTap?
        var layer: MetalPreviewLayer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let layer = MetalPreviewLayer()
        tap.addSink(layer)
        context.coordinator.tap = tap
        context.coordinator.layer = layer
        return MetalPreviewHostView(layer: layer)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let layer = coordinator.layer {
            coordinator.tap?.removeSink(layer)
        }
    }
}

/// A photo on the player backdrop.
private struct ImagePlaybackView: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Label(url.lastPathComponent, systemImage: "photo")
                .foregroundStyle(.secondary)
        }
    }
}

/// Transport: play/pause, ±5 s, scrubber, time, speed, loop, fullscreen.
struct TransportBar: View {
    let player: AVPlayer
    @EnvironmentObject private var controller: CaptureController
    @StateObject private var model = TransportModel()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.skip(-5)
            } label: {
                Image(systemName: "gobackward.5")
            }
            .buttonStyle(.plain)

            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                model.skip(5)
            } label: {
                Image(systemName: "goforward.5")
            }
            .buttonStyle(.plain)

            Text(Self.timeText(model.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: Binding(
                get: { model.currentTime },
                set: { model.seek(to: $0) }),
                in: 0...max(model.duration, 0.01))
                .controlSize(.small)

            Text(Self.timeText(model.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Menu {
                ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                    Button("\(rate.formatted())×") { model.setRate(Float(rate)) }
                }
            } label: {
                Text("\(model.desiredRate.formatted())×")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 30)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("playback_speed"))

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

            if controller.playbackFileHasBakedLUT {
                Image(systemName: "camera.filters")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(L("lut_baked_indicator"))
            } else if controller.lutPreviewOn {
                Button {
                    controller.playbackLUTSuppressed.toggle()
                } label: {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 11))
                        .foregroundStyle(controller.playbackLUTSuppressed
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(controller.accentColor))
                }
                .buttonStyle(.plain)
                .help(L("lut_playback_toggle"))
            }

            TransportVolume(live: controller.live)
                .help(L("playback_volume"))

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
        .onAppear { model.attach(player) }
        .onDisappear { model.detach() }
    }

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Volume control observing only LiveSignal — dragging must not re-render
/// the whole transport/window (that read as slider lag).
private struct TransportVolume: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var live: LiveSignal

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: live.volume == 0
                  ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { controller.playbackVolume },
                set: { controller.playbackVolume = $0 }), in: 0...1)
                .frame(width: 64)
                .controlSize(.mini)
        }
    }
}

/// Observing AVPlayer for the transport: time, speed, loop.
@MainActor
final class TransportModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var desiredRate: Double = 1.0
    @Published var isLooping = true

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func attach(_ player: AVPlayer) {
        detach()
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = time.seconds
                self.isPlaying = player.rate != 0
                if let item = player.currentItem, item.duration.isNumeric {
                    self.duration = item.duration.seconds
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player,
                      (note.object as? AVPlayerItem) === player.currentItem,
                      self.isLooping else { return }
                player.seek(to: .zero)
                player.rate = Float(self.desiredRate)
            }
        }
    }

    func detach() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    func togglePlay() {
        guard let player else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if let item = player.currentItem, item.duration.isNumeric,
               item.currentTime() >= item.duration {
                player.seek(to: .zero)
            }
            player.rate = Float(desiredRate)
        }
    }

    func setRate(_ rate: Float) {
        desiredRate = Double(rate)
        if player?.rate != 0 {
            player?.rate = rate
        }
    }

    func skip(_ seconds: Double) {
        guard let player else { return }
        let target = max(0, player.currentTime().seconds + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// External-monitor window content: a mirror of the current mode.
struct ExternalOutputView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ZStack {
            Color.black
            if controller.viewerMode == .playback, controller.playbackURL != nil {
                PlaybackContent()
            } else {
                LivePreviewLayerView(pipeline: controller.pipeline)
            }
        }
        .ignoresSafeArea()
    }
}
