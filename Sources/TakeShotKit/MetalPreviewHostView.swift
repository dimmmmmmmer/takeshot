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
        guard size.width > 0, size.height > 0 else { return }
        // the layer adopts the size inside its own render pass — assigning
        // drawableSize here would reallocate the drawable pool underneath a
        // producer queue sitting in nextDrawable()
        previewLayer.setDrawableSize(size)
    }
}
