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
            let ext = url.pathExtension.lowercased()
            let rawOwned = controller.rawPlayer?.url == url
            if rawOwned || CaptureController.rawExtensions.contains(ext) {
                if let model = controller.rawPlayer {
                    RawTapLayerView(model: model)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                        Text(controller.rawPlayerError ?? L("raw_open_failed"))
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(20)
                }
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

/// RAW playback mount: its own layer, registered with the engine.
private struct RawTapLayerView: NSViewRepresentable {
    let model: RawPlayerModel

    final class Coordinator {
        var model: RawPlayerModel?
        var layer: MetalPreviewLayer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let layer = MetalPreviewLayer()
        model.addSink(layer)
        context.coordinator.model = model
        context.coordinator.layer = layer
        return MetalPreviewHostView(layer: layer)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let layer = coordinator.layer {
            coordinator.model?.removeSink(layer)
        }
    }
}

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
                model.isLooping.toggle()
            } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(model.isLooping
                                     ? AnyShapeStyle(controller.accentColor)
                                     : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(L("playback_loop"))

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

            TransportPositionControls(model: model, position: model.position)

            Text(controller.playbackTC(atSeconds: model.duration))
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

            MarkerButton()

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
        .onAppear {
            model.attach(player)
            consumeReplayLoopRequest()
        }
        .onChange(of: controller.playbackURL) { _, _ in
            consumeReplayLoopRequest()
        }
        .onDisappear { model.detach() }
    }

    private func consumeReplayLoopRequest() {
        if controller.replayLoopRequested {
            model.isLooping = true
            controller.replayLoopRequested = false
        }
    }

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The color a marker name maps to (palette in TakeMarker.colors).
func markerColor(_ name: String) -> Color {
    switch name {
    case "red": return .red
    case "yellow": return .yellow
    case "green": return .green
    case "cyan": return .cyan
    case "blue": return .blue
    case "purple": return .purple
    default: return .orange
    }
}

/// Add-marker flag + the marker list editor, for both transports.
private struct MarkerButton: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
    @State private var showList = false

    var body: some View {
        Button {
            controller.addMarker()
        } label: {
            Image(systemName: "flag.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .help("\(L("marker_add_help")) — \(hotkeys.combo(for: .addMarker).display)")

        if !controller.playbackMarkers.isEmpty {
            Button {
                controller.jumpToMarker(forward: false)
            } label: {
                Image(systemName: "chevron.backward.2")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(L("marker_prev_help"))

            Button {
                showList.toggle()
            } label: {
                Text("\(controller.playbackMarkers.count)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(L("marker_list_help"))
            .popover(isPresented: $showList, arrowEdge: .top) {
                MarkerListEditor()
            }

            Button {
                controller.jumpToMarker(forward: true)
            } label: {
                Image(systemName: "chevron.forward.2")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(L("marker_next_help"))
        }
    }
}

/// Popover list: jump to, recolor, annotate and delete markers.
private struct MarkerListEditor: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("markers_title"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("markers_clear_all"), role: .destructive) {
                    controller.clearPlaybackMarkers()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
            }
            Divider()
            ForEach(Array(controller.playbackMarkers.enumerated()),
                    id: \.offset) { index, marker in
                HStack(spacing: 8) {
                    Text(marker.note.isEmpty
                         ? L("marker_n", index + 1) : marker.note)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 76, alignment: .leading)
                    // color swatch menu
                    Menu {
                        ForEach(TakeMarker.colors, id: \.self) { name in
                            Button {
                                controller.updatePlaybackMarker(at: index) {
                                    $0.color = name
                                }
                            } label: {
                                Label(name.capitalized,
                                      systemImage: marker.color == name
                                          ? "circle.inset.filled" : "circle.fill")
                            }
                            .tint(markerColor(name))
                        }
                    } label: {
                        Circle()
                            .fill(markerColor(marker.color))
                            .frame(width: 10, height: 10)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button {
                        controller.seekPlayback(to: marker.seconds)
                    } label: {
                        Text(marker.timecodeText.isEmpty
                             ? TransportBar.timeText(marker.seconds)
                             : marker.timecodeText)
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .help(L("marker_jump_help"))

                    TextField(L("marker_note_placeholder"), text: Binding(
                        get: { controller.playbackMarkers[safe: index]?.note ?? "" },
                        set: { note in
                            controller.updatePlaybackMarker(at: index) {
                                $0.note = note
                            }
                        }))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 180)

                    Button {
                        controller.removePlaybackMarker(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("marker_delete_help"))
                }
            }
        }
        .padding(12)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Marker positions over a transport slider (display only).
struct MarkerTicks: View {
    let markers: [TakeMarker]
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                if duration > 0 {
                    Rectangle()
                        .fill(markerColor(marker.color))
                        .frame(width: 2, height: 7)
                        .position(
                            x: geo.size.width
                                * min(1, max(0, marker.seconds / duration)),
                            y: geo.size.height - 3)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// TC readout + scrubber: the only part of the bar that re-renders at 10 Hz.
private struct TransportPositionControls: View {
    @EnvironmentObject private var controller: CaptureController
    let model: TransportModel
    @ObservedObject var position: TransportPosition

    var body: some View {
        Text(controller.playbackTC(atSeconds: position.currentTime))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

        Slider(value: Binding(
            get: { position.currentTime },
            set: { model.seek(to: $0) }),
            in: 0...max(model.duration, 0.01))
            .controlSize(.small)
            .overlay {
                MarkerTicks(markers: controller.playbackMarkers,
                            duration: model.duration)
            }
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

/// Playhead position only — isolated so the 10 Hz tick re-renders just the
/// TC readout and the slider, not the whole transport bar.
@MainActor
final class TransportPosition: ObservableObject {
    @Published var currentTime: Double = 0
}

/// Observing AVPlayer for the transport: time, speed, loop.
@MainActor
final class TransportModel: ObservableObject {
    let position = TransportPosition()
    var currentTime: Double { position.currentTime }
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
                self.position.currentTime = time.seconds
                let playing = player.rate != 0
                if self.isPlaying != playing { self.isPlaying = playing }
                if let item = player.currentItem, item.duration.isNumeric,
                   self.duration != item.duration.seconds {
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
