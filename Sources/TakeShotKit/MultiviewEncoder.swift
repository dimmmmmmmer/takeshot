@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

/// Turns each camera's displayed frames into the small JPEGs the multiview
/// page shows, on a queue of its own.
///
/// The discipline is the scope analyzer's: the display queue drops a frame
/// here and returns at once, only the newest frame per camera is kept, and
/// the pass that scales and encodes runs on this queue — never on capture,
/// never on main. Two regulators keep the work modest:
///
/// - **Pacing.** A camera is encoded at most `framesPerSecond` times a
///   second. A phone-sized monitor does not gain anything past ~5 fps, and
///   this is a machine that is recording.
/// - **Latest wins.** A pass that cannot keep up (or a wire that outruns the
///   pace) replaces the pending frame instead of queueing behind it, so the
///   stream falls to fewer frames rather than to older ones.
///
/// The encoder exists only while somebody is watching: the server reports
/// multiview demand and the controller builds or drops it on that signal, so
/// an idle set costs no encode work at all.
final class MultiviewEncoder: @unchecked Sendable {
    /// Longest edge of the encoded frame. A phone tile at arm's length; the
    /// grabs and stills that are deliverables never come through here.
    static let maximumEdge: CGFloat = 480
    /// JPEG quality — a monitor, not a grading surface.
    static let quality = 0.5
    /// Encode ceiling per camera. See the pacing note above.
    static let framesPerSecond = 5.0

    static var minimumInterval: TimeInterval { 1 / framesPerSecond }

    private let queue = DispatchQueue(label: "com.takeshot.multiview",
                                      qos: .utility)
    private let sink: @Sendable (Int, Data) -> Void
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - queue-confined state

    /// Newest frame per camera, not yet encoded.
    private var pending: [Int: CVPixelBuffer] = [:]
    /// Cameras with an encode pass already scheduled.
    private var scheduled: Set<Int> = []
    /// When each camera was last encoded, on the monotonic clock.
    private var lastEncodeAt: [Int: TimeInterval] = [:]

    /// `sink` receives (camera index, JPEG bytes) on the encoder's queue.
    init(sink: @escaping @Sendable (Int, Data) -> Void) {
        self.sink = sink
    }

    /// Offer one displayed frame. Called on the display queue; returns at
    /// once — the hop is an async dispatch, never a wait.
    func offer(_ buffer: CVPixelBuffer, camera: Int) {
        queue.async { [self] in enqueue(buffer, camera: camera) }
    }

    private func enqueue(_ buffer: CVPixelBuffer, camera: Int) {
        pending[camera] = buffer // latest wins
        guard !scheduled.contains(camera) else { return }
        scheduled.insert(camera)
        let now = RemoteServer.monotonicNow()
        let earliest = (lastEncodeAt[camera] ?? 0) + Self.minimumInterval
        let wait = max(0, earliest - now)
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.encodePending(camera)
        }
    }

    private func encodePending(_ camera: Int) {
        scheduled.remove(camera)
        guard let buffer = pending.removeValue(forKey: camera) else { return }
        // Stamped before the pass, so the pace is measured start to start and
        // a slow encode does not quietly raise the delivered rate afterwards.
        lastEncodeAt[camera] = RemoteServer.monotonicNow()
        guard let jpeg = Self.jpeg(from: buffer, context: ciContext) else {
            return
        }
        sink(camera, jpeg)
    }

    /// One display buffer as a phone-sized JPEG. A free function bar the
    /// context, like `RemotePoster.jpeg` and for the same reason: scaling and
    /// encoding needs no encoder state, and a test can hand it a known frame
    /// and measure the bytes that come back.
    ///
    /// **The colour space is declared on BOTH ends, and that is the point.**
    /// The display path's contract is the one stated at `MetalPreviewLayer`:
    /// the buffer holds 709-encoded code values, and the surface says so rather
    /// than converting them. Reading the buffer WITHOUT naming a space asks
    /// CoreImage to guess from whatever colour attachments the pooled buffer
    /// happens to carry — sRGB when there are none, and a pool recycles
    /// IOSurfaces between frames — and then writing 709 turns that guess into a
    /// gamma conversion. The result is a tile a few percent off the app's own
    /// picture, changing with the frame that recycled the buffer. Naming 709 in
    /// and 709 out makes the pass an identity, exactly as the still grabs do
    /// (see `CapturePipeline.pngData`).
    static func jpeg(from buffer: CVPixelBuffer, context: CIContext,
                     maxEdge: CGFloat = maximumEdge,
                     quality: Double = quality) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpaceCreateDeviceRGB()
        let image = CIImage(cvPixelBuffer: buffer,
                            options: [.colorSpace: space])
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxEdge / longest)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale,
                                                             y: scale))
        let option = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(of: scaled, colorSpace: space,
                                          options: [option: quality])
    }
}
