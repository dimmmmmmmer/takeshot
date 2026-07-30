import CaptureCore
import SwiftUI

/// Playback content without the transport (also used in compare modes):
/// video (the unified sample-buffer render, like live) or a photo.
struct PlaybackContent: View {
    @EnvironmentObject private var controller: CaptureController

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

/// The A pane of the A/B split: what the operator picked as the compare source.
///
/// It is NOT always the live signal. Choosing another clip as the B source and
/// switching to A/B used to leave this pane on the camera, so the operator was
/// handed live-vs-clip while the picker said clip-vs-clip — the one comparison
/// they had explicitly turned off.
struct CompareSourceContent: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        switch controller.comparePaneSource {
        case .live:
            LivePreviewContent()
        case .clip:
            CompareClipLayerView(tap: controller.playbackTap)
        }
    }
}

/// The A|B compare split: the chosen compare source beside the take under
/// review.
///
/// One view, mounted by all three surfaces that draw the player — the main
/// viewer, the fullscreen player and the external display. It used to be an
/// HStack written inline in `PreviewView`, and the other two rendered
/// `PlaybackContent()` alone: with A/B engaged the operator's window showed two
/// pictures while the fullscreen and the director's monitor showed one, which
/// reads as "the compare is off" on the surface the client is watching.
///
/// Each mount builds its OWN pair of layers (see `CompareSourceContent` and
/// `PlaybackContent`, whose representables register per mount) — a CALayer
/// lives in one NSView, so sharing would hand the picture to whichever window
/// laid out last and black the others out.
struct ComparePlaybackSplit: View {
    var body: some View {
        // A is the chosen compare source — the other clip when there is one,
        // the live signal otherwise; B is the take under review.
        HStack(spacing: 2) {
            CompareSourceContent()
            PlaybackContent()
        }
    }
}

/// Compare-source mount: its own layer, registered with the tap's compare
/// registry (the B clip's frames, uncomposited).
private struct CompareClipLayerView: NSViewRepresentable {
    let tap: PlaybackFrameTap

    final class Coordinator {
        var tap: PlaybackFrameTap?
        var layer: MetalPreviewLayer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let layer = MetalPreviewLayer()
        tap.addCompareSink(layer)
        context.coordinator.tap = tap
        context.coordinator.layer = layer
        return MetalPreviewHostView(layer: layer)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let layer = coordinator.layer {
            coordinator.tap?.removeCompareSink(layer)
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

/// External-monitor window content: a mirror of the current mode.
struct ExternalOutputView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ZStack {
            Color.black
            // A/B is a split of two surfaces; wipe and blend arrive already
            // composited in the one picture PlaybackContent draws.
            if controller.showsCompareSplit {
                ComparePlaybackSplit()
            } else if controller.viewerMode == .playback,
                      controller.playbackURL != nil {
                PlaybackContent()
            } else {
                LivePreviewLayerView(pipeline: controller.pipeline)
            }
        }
        .ignoresSafeArea()
    }
}
