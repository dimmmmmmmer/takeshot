import CoreImage
import Foundation

/// **One `CIContext` for every one-shot decode in the app.**
///
/// The thumbnail path, the Other-content decode and the still grab each built
/// their own and threw it away. `CIBufferRender` argued for that in its own
/// comment — a context holds caches sized for the work it has seen, and these
/// are one-shot decodes off the main actor — and the argument was reasonable
/// and wrong. Measured on this machine, release, 1080p to a 192×108 thumbnail
/// (`ThumbnailContextCostTests`):
///
/// - building a context: **2.4 ms**
/// - the render with a FRESH context: **9.67 ms**
/// - the same render on a shared one: **0.955 ms**
///
/// Ten times, and the gap is bigger than the construction alone because a new
/// context also recompiles the kernels the render needs. A card of two hundred
/// R3D files is two seconds of a folder scan against a fifth of a second — and
/// the scan runs while the operator is trying to look at the panel.
///
/// **Thread-safe by Apple's own statement**, which is the property that makes
/// one context possible at all: the decodes run on detached tasks and several
/// can be in flight at once. What is NOT shared is the contexts that belong to
/// a running stage — the keyer's, the assist stage's, the pipeline's, the RAW
/// player's. Those are hot paths with caches sized for one raster, and putting
/// them behind one context would make every frame of one wait on a thumbnail
/// of another.
enum DecodeContext {
    /// Built on first use, which is the first decode rather than launch.
    static let shared = CIContext(options: [.cacheIntermediates: false])
}
