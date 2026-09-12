@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

/// Thread-safe registry of preview layers shared by every frame producer
/// (capture pipeline, playback tap, RAW engine). Each SwiftUI mount registers
/// its OWN layer — a CALayer can live in one NSView only — and the producer
/// mirrors frames to all of them. The registry also carries the one piece of
/// per-surface presentation state there is — the letterbox colour — and
/// applies it to layers as they join.
///
/// **There were two.** The operator's assists rode this registry as well,
/// because the surfaces used to apply the geometry half of them each for
/// itself. They are applied once upstream now, into the signal's own raster
/// (`AssistStage.rendered`), so that the consumers which are pixel buffers
/// rather than layers carry them too; a layer aspect-fits what arrives, and
/// there is nothing left to tell it.
public final class PreviewSinkRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let sinks = NSHashTable<MetalPreviewLayer>.weakObjects()
    private var letterbox = CIColor(red: 0, green: 0, blue: 0)

    public init() {}

    /// Register a layer; the current letterbox applies at once.
    public func add(_ layer: MetalPreviewLayer) {
        lock.lock()
        let color = letterbox
        sinks.add(layer)
        lock.unlock()
        // applied outside the lock: a layer call can wait on that layer's own
        // render lock, and holding the registry lock through it would stall
        // every producer mirroring frames
        layer.letterboxColor = color
    }

    public func remove(_ layer: MetalPreviewLayer) {
        lock.lock()
        sinks.remove(layer)
        lock.unlock()
    }

    public func all() -> [MetalPreviewLayer] {
        lock.lock()
        defer { lock.unlock() }
        return sinks.allObjects
    }

    public func setLetterbox(_ color: CIColor) {
        lock.lock()
        letterbox = color
        let layers = sinks.allObjects
        lock.unlock()
        for layer in layers {
            layer.letterboxColor = color
            layer.redraw()
        }
    }

    public func present(_ buffer: CVPixelBuffer) {
        for layer in all() {
            layer.present(buffer)
        }
    }

    public func clearToBlack() {
        for layer in all() {
            layer.clearToBlack()
        }
    }
}

/// CoreVideo/CoreGraphics types predate Sendable. The wrapped value crosses
/// exactly one actor hop and is used serially — the annotation states that
/// contract instead of silencing it per call site.
public struct UncheckedSendable<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}
