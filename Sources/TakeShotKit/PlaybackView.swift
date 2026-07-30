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
            if controller.viewerMode == .playback, controller.playbackURL != nil {
                PlaybackContent()
            } else {
                LivePreviewLayerView(pipeline: controller.pipeline)
            }
        }
        .ignoresSafeArea()
    }
}
