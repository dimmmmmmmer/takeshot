import AppKit
import CaptureCore

/// NSView host for MetalPreviewLayer: keeps drawableSize/contentsScale in sync
/// with the view geometry (CAMetalLayer does not do this by itself — without
/// the sync the preview stays black or renders at the wrong resolution).
final class MetalPreviewHostView: NSView {
    private let previewLayer: MetalPreviewLayer

    init(layer: MetalPreviewLayer) {
        self.previewLayer = layer
        super.init(frame: .zero)
        wantsLayer = true
        layer.backgroundColor = .clear
        self.layer = layer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        previewLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale,
                          height: bounds.height * scale)
        if size.width > 0, size.height > 0, previewLayer.drawableSize != size {
            previewLayer.drawableSize = size
            // paused playback / no signal: no new frame will arrive to fill the
            // resized drawable — redraw the last one right away or the image
            // stretches/jumps for a frame
            previewLayer.redraw()
        }
    }
}
