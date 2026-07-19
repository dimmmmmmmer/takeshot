import AVFoundation
import AVKit
import CaptureCore
import Combine
import SwiftUI

/// Просмотр записанного: видео с собственным транспортом (без затемняющих
/// hover-контролов системного плеера) или фото.
struct PlaybackView: View {
    @EnvironmentObject private var controller: CaptureController

    private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "tif", "tiff", "dng", "arw", "cr2", "webp"]

    var body: some View {
        if let url = controller.playbackURL {
            if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                ImagePlaybackView(url: url)
            } else {
                VStack(spacing: 0) {
                    PlayerSurface(player: controller.player)
                    TransportBar(player: controller.player)
                }
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

/// Голая видеоповерхность — без системных контролов и их затемнения.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

/// Транспорт: play/pause, скраббер, время. Всегда видимый, ничего не затемняет.
private struct TransportBar: View {
    let player: AVPlayer
    @StateObject private var model = TransportModel()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

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

/// Наблюдение за AVPlayer для транспорта.
@MainActor
private final class TransportModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []

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
    }

    func detach() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
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
            player.play()
        }
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
