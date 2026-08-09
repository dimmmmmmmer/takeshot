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
    /// Longest edge of the encoded frame when the page is showing ONE camera —
    /// the tile is then the whole phone, and a phone is 1179 physical pixels
    /// across (iPhone 15) with a tablet not far behind. 1280 is that width to
    /// within rounding, and it is the size a script supervisor can read a slate
    /// off. The grabs and stills that are deliverables never come through here.
    static let soloEdge: CGFloat = 1280
    /// Two cameras: they stack in portrait and sit side by side in landscape,
    /// so each tile is about half the screen.
    static let pairEdge: CGFloat = 960
    /// Three or more: the page wraps onto a 2-across grid, so a tile is about
    /// 590 physical pixels on a phone. 640 covers that natively.
    static let gridEdge: CGFloat = 640
    /// JPEG quality — a monitor, not a grading surface.
    ///
    /// ImageIO quantises this into buckets, measured on a 1080p frame scaled to
    /// 960: 0.70 → 27.1 KB, 0.75 → 28.4 KB, 0.80 → 28.4 KB (byte-identical to
    /// 0.75), 0.85 → 38.4 KB. So 0.75 is the cheapest point of the last bucket
    /// before a 35 % cliff, and asking for 0.80 would buy exactly nothing. The
    /// 0.5 this shipped with cost 17.1 KB and blocked visibly on skin.
    static let quality = 0.75
    /// Encode ceiling per camera. See the pacing note above.
    static let framesPerSecond = 5.0

    static var minimumInterval: TimeInterval { 1 / framesPerSecond }

    /// How big a tile is worth encoding for a page showing `cameras` of them.
    ///
    /// One constant could not answer this. A fixed cap sized for the single
    /// fullscreen view sends four times those bytes for a four-up grid whose
    /// tiles are a quarter of the screen; a fixed cap sized for the grid is
    /// what made a single camera look like a thumbnail. Measured on a 1080p
    /// frame, the ladder holds the whole page inside 1.7-2.6 Mbit/s whatever
    /// the camera count, against 7.2 Mbit/s for a flat 1280 at four cameras.
    static func maximumEdge(cameras: Int) -> CGFloat {
        switch cameras {
        case ...1: return soloEdge
        case 2: return pairEdge
        default: return gridEdge
        }
    }

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
    /// How many tiles the page is laying out, which is what sizes each of
    /// them. The controller sets it; nothing here infers it from the frames
    /// that arrive — a camera that has not sent one yet still owns a tile.
    private var cameraCount = 1

    /// `sink` receives (camera index, JPEG bytes) on the encoder's queue.
    init(sink: @escaping @Sendable (Int, Data) -> Void) {
        self.sink = sink
    }

    /// The channel list reshaped. Hopped onto the encoder's queue like every
    /// other read of this state, so a multicam switch cannot race an encode.
    func setCameraCount(_ count: Int) {
        queue.async { [self] in cameraCount = max(1, count) }
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
        let edge = Self.maximumEdge(cameras: cameraCount)
        guard let jpeg = Self.jpeg(from: buffer, context: ciContext,
                                   maxEdge: edge) else {
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
                     maxEdge: CGFloat,
                     quality: Double = quality) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpaceCreateDeviceRGB()
        let image = CIImage(cvPixelBuffer: buffer,
                            options: [.colorSpace: space])
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0 else { return nil }
        let option = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(
            of: reduced(image, to: min(1, maxEdge / longest)),
            colorSpace: space, options: [option: quality])
    }

    /// The frame at `scale`, band-limited first.
    ///
    /// **An affine transform is not a downscale, and that was the real fault
    /// here.** `transformed(by:)` resamples with the sampler's own two-tap
    /// filter rather than averaging the pixels it is dropping, so everything
    /// above the target's Nyquist folds back as moire. Measured through this
    /// very encode on a zone plate reduced 1920 → 640, standard deviation
    /// inside the band that should have come out flat grey: the affine
    /// transform 18.9 codes, Lanczos 1.5 — and a deliberately unfiltered
    /// nearest sample scores 21.3 on the same subject, which is the company the
    /// affine transform was keeping. The tile was not merely small; its fine
    /// detail was wrong, and JPEG then spent bytes coding the moire. Lanczos
    /// costs about half a millisecond more per 1080p frame (0.9 ms against
    /// 1.5 at the grid rung) and produces FEWER bytes at the same quality,
    /// because what it removes is noise.
    ///
    /// Clamped before and cropped after, which is not decoration: Lanczos
    /// reaches three output pixels beyond each edge, and off the edge of an
    /// unclamped CIImage is transparent black. A flat 128 field came back with
    /// its corner at 112 without this and at 128 with it. The crop also fixes
    /// the output size arithmetically rather than leaving it to the filter's
    /// own rounding.
    private static func reduced(_ image: CIImage, to scale: CGFloat) -> CIImage {
        guard scale < 1 else { return image }
        let extent = image.extent
        return image.clampedToExtent()
            .applyingFilter("CILanczosScaleTransform",
                            parameters: [kCIInputScaleKey: scale,
                                         kCIInputAspectRatioKey: 1.0])
            .cropped(to: CGRect(x: extent.origin.x * scale,
                                y: extent.origin.y * scale,
                                width: (extent.width * scale).rounded(),
                                height: (extent.height * scale).rounded()))
    }
}
