import CaptureCore
import SwiftUI

/// The main viewer surface: one NSView + one MetalPreviewLayer whose frame
/// source is re-routed between live capture, AVPlayer playback and the RAW
/// engine. One surface — rec and playback occupy identical pixels, so a mode
/// switch cannot shift or resize the image.
struct ViewerSurface: NSViewRepresentable {
    let controller: CaptureController
    let source: Source

    enum Source: Equatable {
        case none
        case live
        case playback
        case raw(ObjectIdentifier)
    }

    final class Coordinator {
        var layer: MetalPreviewLayer?
        weak var pipeline: CapturePipeline?
        weak var tap: PlaybackFrameTap?
        weak var raw: RawPlayerModel?
        var current: Source = .none
        var attached = false

        @MainActor
        func attach(_ source: Source, controller: CaptureController) {
            guard let layer, !attached || source != current else { return }
            detach()
            attached = true
            current = source
            switch source {
            case .none:
                layer.clearToBlack()
            case .live:
                pipeline = controller.pipeline
                controller.pipeline.addDisplaySink(layer)
            case .playback:
                tap = controller.playbackTap
                controller.playbackTap.addSink(layer)
            case .raw:
                raw = controller.rawPlayer
                controller.rawPlayer?.addSink(layer)
            }
        }

        @MainActor
        func detach() {
            guard let layer else { return }
            pipeline?.removeDisplaySink(layer)
            tap?.removeSink(layer)
            raw?.removeSink(layer)
            pipeline = nil
            tap = nil
            raw = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let layer = MetalPreviewLayer()
        context.coordinator.layer = layer
        context.coordinator.attach(source, controller: controller)
        return MetalPreviewHostView(layer: layer)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(source, controller: controller)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

/// Live preview mount: creates its OWN layer and registers it as a pipeline
/// sink (a CALayer can live in one view only — the pipeline mirrors frames to
/// every registered sink, so compare/multicam mounts don't fight over one).
struct LivePreviewLayerView: NSViewRepresentable {
    let pipeline: CapturePipeline

    final class Coordinator {
        var pipeline: CapturePipeline?
        var layer: MetalPreviewLayer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let layer = MetalPreviewLayer()
        pipeline.addDisplaySink(layer)
        context.coordinator.pipeline = pipeline
        context.coordinator.layer = layer
        return MetalPreviewHostView(layer: layer)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let layer = coordinator.layer {
            coordinator.pipeline?.removeDisplaySink(layer)
        }
    }
}
