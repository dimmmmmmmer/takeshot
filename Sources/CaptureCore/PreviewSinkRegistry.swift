import CoreImage
import CoreVideo
import Foundation

/// Thread-safe registry of preview layers shared by every frame producer
/// (capture pipeline, playback tap, RAW engine). Each SwiftUI mount registers
/// its OWN layer — a CALayer can live in one NSView only — and the producer
/// mirrors frames to all of them. The registry also carries the per-surface
/// presentation state (letterbox color, operator assists) and applies it to
/// layers as they join.
public final class PreviewSinkRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let sinks = NSHashTable<MetalPreviewLayer>.weakObjects()
    private var letterbox = CIColor(red: 0, green: 0, blue: 0)
    private var assist = ViewAssist()

    public init() {}

    /// Register a layer; the current letterbox/assist state applies at once.
    public func add(_ layer: MetalPreviewLayer) {
        lock.lock()
        layer.letterboxColor = letterbox
        layer.setAssist(assist)
        sinks.add(layer)
        lock.unlock()
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

    public func setAssist(_ newValue: ViewAssist) {
        lock.lock()
        assist = newValue
        let layers = sinks.allObjects
        lock.unlock()
        for layer in layers {
            layer.setAssist(newValue)
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
