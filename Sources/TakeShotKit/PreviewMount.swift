import CaptureCore
import SwiftUI

/// One preview mount: a `MetalPreviewLayer` of its own, registered with a frame
/// source for exactly as long as the view is on screen.
///
/// A CALayer can be hosted by ONE NSView (docs/ARCHITECTURE.md), so every mount
/// builds its own layer and hands it to the source rather than sharing one.
/// That rule used to be written out four times — once per source: the live
/// pipeline, the playback tap, the tap's compare registry and the RAW engine —
/// and the four copies differed only in which pair of add/remove calls they
/// made. A missed `remove` is invisible until a surface nobody is looking at is
/// still being fed frames, which is why the four are now one.
///
/// `attach`/`detach` capture the source, and the coordinator holds `detach`, so
/// the source stays alive for the mount's lifetime exactly as it did when each
/// copy kept its own reference.
struct PreviewMount: NSViewRepresentable {
    /// Register the layer with the frame source.
    let attach: (MetalPreviewLayer) -> Void
    /// Let go of it again.
    let detach: (MetalPreviewLayer) -> Void

    final class Coordinator {
        var layer: MetalPreviewLayer?
        var detach: ((MetalPreviewLayer) -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let layer = MetalPreviewLayer()
        attach(layer)
        context.coordinator.layer = layer
        context.coordinator.detach = detach
        return MetalPreviewHostView(layer: layer)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let layer = coordinator.layer {
            coordinator.detach?(layer)
        }
    }
}

extension PreviewMount {
    /// Live capture.
    static func live(_ pipeline: CapturePipeline) -> PreviewMount {
        PreviewMount(attach: { pipeline.addDisplaySink($0) },
                     detach: { pipeline.removeDisplaySink($0) })
    }

    /// The clip under review.
    static func playback(_ tap: PlaybackFrameTap) -> PreviewMount {
        PreviewMount(attach: { tap.addSink($0) },
                     detach: { tap.removeSink($0) })
    }

    /// The compare source on its own surface — the A pane of the A/B split,
    /// which carries the B clip's frames uncomposited.
    static func compareSource(_ tap: PlaybackFrameTap) -> PreviewMount {
        PreviewMount(attach: { tap.addCompareSink($0) },
                     detach: { tap.removeCompareSink($0) })
    }

    /// A BRAW/CinemaDNG clip, from its own decoder.
    static func raw(_ model: RawPlayerModel) -> PreviewMount {
        PreviewMount(attach: { model.addSink($0) },
                     detach: { model.removeSink($0) })
    }
}
