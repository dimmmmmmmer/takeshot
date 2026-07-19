import AVFoundation
import CaptureCore
import Combine
import SwiftUI

/// Контент плейбека без транспорта (используется и в режимах сравнения):
/// видео на прозрачной подложке или фото.
struct PlaybackContent: View {
    @EnvironmentObject private var controller: CaptureController

    static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr2", "webp"]

    var body: some View {
        if let url = controller.playbackURL {
            if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                ImagePlaybackView(url: url)
            } else {
                PlayerSurface(player: controller.player)
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

/// Фото на подложке плеера.
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

/// Голая видеоповерхность на AVPlayerLayer: без контролов, без затемнения,
/// прозрачный фон — сквозь letterbox виден цвет подложки плеера.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = .clear
            layer = playerLayer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView(frame: .zero)
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: LayerView, context: Context) {}
}

/// Транспорт: play/pause, ±5 с, скраббер, время, скорость, loop, фулскрин.
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
                    .foregroundStyle(model.isLooping ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(L("playback_loop"))

            Button {
                controller.toggleFullscreen()
            } label: {
                Image(systemName: controller.isImmersive
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help(L("fullscreen"))
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

/// Наблюдение за AVPlayer для транспорта: время, скорость, loop.
@MainActor
final class TransportModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var desiredRate: Double = 1.0
    @Published var isLooping = false

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

/// Контент окна на внешнем мониторе: зеркало текущего режима.
struct ExternalOutputView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ZStack {
            Color.black
            if controller.viewerMode == .playback, controller.playbackURL != nil {
                PlaybackContent()
            } else {
                ExternalLiveView(layer: controller.pipeline.externalLayer)
            }
        }
        .ignoresSafeArea()
    }
}

private struct ExternalLiveView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .clear
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
