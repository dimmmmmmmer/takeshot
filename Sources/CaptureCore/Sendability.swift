import CoreMedia
import CoreVideo

// CoreVideo and CoreMedia buffers predate Sendable, so under Swift 6 every hop
// onto the pipeline queue reads as sending non-Sendable state — a hundred
// warnings describing the very thing this app does for a living.
//
// The conformances are stated here once instead. They are honest for these
// types: the objects are reference-counted CF types that are safe to pass
// between threads, and the thing that genuinely is not safe — two threads
// touching the same frame's pixels at once — is prevented by the queue
// discipline the pipeline is built on (one serial queue owns processing, the
// display queue only reads buffers it was handed, and pooled buffers are
// retained for as long as anyone can still be looking at them).
//
// Anything genuinely shared and mutable is guarded explicitly: see the locks in
// CapturePipeline, PreviewSinkRegistry and MetalPreviewLayer.

extension CVBuffer: @retroactive @unchecked Sendable {}
extension CMSampleBuffer: @retroactive @unchecked Sendable {}
extension CMFormatDescription: @retroactive @unchecked Sendable {}
