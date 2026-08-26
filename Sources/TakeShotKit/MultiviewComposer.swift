import CaptureCore
@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

/// **`LivePicture.grid` as an actual frame**: every camera's clean picture
/// tiled into one buffer, on a queue of its own.
///
/// The phone camera grid does not need this — it sends one JPEG per camera and
/// the page lays the tiles out itself (`MultiviewEncoder`). A video track has no
/// page: an H.264 session carries one raster, so a browser that asked to watch
/// the grid has to be sent a grid, composed here. What that buys is the reason
/// the grid is a PICTURE rather than a layout — one encode serves every phone
/// watching it, exactly as the decorated picture does.
///
/// **The MAIN camera is the grid's clock.** A compose runs when camera 0
/// delivers and never when another camera does: the others replace their tile
/// and wait. Composing on every camera's frame would run the pass once per
/// camera per frame interval — four times the GPU work for a grid nobody can
/// see change faster than the main signal — and pacing that back down would
/// be a second rate limiter arguing with the encoder's. The cost of a tile that
/// is one frame stale on a monitoring surface is nothing; the cost of the pass
/// is real.
///
/// The discipline is the one every other display consumer follows: the display
/// queue drops a frame here and returns at once, only the newest frame per
/// camera is kept, and the compose runs on THIS queue — never on capture, never
/// on main, never on the display queue.
///
/// **What it costs, measured in release** (`MultiviewComposerTests`, signalled
/// rather than polled, minimum of twenty runs on the development Mac): one
/// camera 0.010 ms — the pass-through below, which is not a render at all — two
/// cameras 0.72 ms at 1080p and 1.44 at UHD, four cameras 0.87 and 1.96. Every
/// millisecond of that is on this composer's queue; the display queue's whole
/// involvement is one `dispatch_async`, and the H.264 encode that follows is
/// six milliseconds at 1080p, so this is a fraction of the work the picture was
/// already going to cost.
///
/// Nothing here exists while nobody is watching the grid: the controller builds
/// one when a viewer chooses it and drops it when the last one goes
/// (`CaptureController+LivePictures`).
final class MultiviewComposer: @unchecked Sendable {
    /// Tiles across, by camera count.
    ///
    /// The same shape the `/cameras` page draws — one camera full frame, two
    /// side by side, three or more wrapping onto a 2-across grid — so a phone
    /// that switches between the JPEG page and the video track is looking at
    /// the same arrangement rather than at two opinions about it.
    static func columns(cameras: Int) -> Int { cameras <= 1 ? 1 : 2 }

    static func rows(cameras: Int) -> Int {
        let across = columns(cameras: cameras)
        return max(1, (max(1, cameras) + across - 1) / across)
    }

    /// One camera's cell inside a `frame`-sized canvas.
    ///
    /// Pure, and that is what makes the layout checkable without a GPU: every
    /// interesting case here is arithmetic — a cell that must not overlap its
    /// neighbour, a last row with a hole in it, a canvas that does not divide
    /// evenly by the row count.
    static func cell(camera: Int, cameras: Int, in frame: CGRect) -> CGRect {
        let across = columns(cameras: cameras)
        let down = rows(cameras: cameras)
        let index = max(0, min(camera, max(0, cameras - 1)))
        let column = index % across
        // Row 0 is the TOP one, which in CoreImage's bottom-left origin is the
        // last band. A grid numbered from the top is what the page shows and
        // what the status' `cameras` array means; flipping it here rather than
        // at the draw is the difference between "camera A is top left" being a
        // fact and being a coincidence.
        let row = down - 1 - (index / across)
        let width = frame.width / CGFloat(across)
        let height = frame.height / CGFloat(down)
        return CGRect(x: frame.minX + CGFloat(column) * width,
                      y: frame.minY + CGFloat(row) * height,
                      width: width, height: height)
    }

    /// One camera's picture placed into its cell, aspect-fit and letterboxed.
    ///
    /// Fit and never fill: a tile cropped to its cell would hide the edges of a
    /// frame somebody is using to judge what is in shot, which is the one thing
    /// a monitoring surface must not do. The bars are DRAWN rather than left
    /// over — see `CIImage.letterboxed`, and the runner it was written for.
    static func placed(_ image: CIImage, in cell: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              cell.width > 0, cell.height > 0 else {
            return CIImage(color: .black).cropped(to: cell)
        }
        let scale = min(cell.width / extent.width, cell.height / extent.height)
        let width = extent.width * scale
        let height = extent.height * scale
        let placed = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: cell.midX - width / 2 - extent.minX * scale,
                y: cell.midY - height / 2 - extent.minY * scale))
        return placed.letterboxed(in: cell, with: .black)
    }

    /// `sink` receives the composed frame and the rate the main camera is
    /// running at, on this composer's queue.
    typealias Sink = @Sendable (CVPixelBuffer, Double) -> Void

    private let queue = DispatchQueue(label: MultiviewComposer.queueLabel,
                                      qos: .userInitiated)
    /// Named so a test can assert the compose is not on the display queue —
    /// which is the queue the preview layers and the playout mirror share, and
    /// the one thing this pass must never be able to hold up.
    static let queueLabel = "com.takeshot.multiview.compose"

    private let sink: Sink
    private let context: CIContext
    private let pool = PixelBufferPool()

    // MARK: - queue-confined state

    /// Newest frame per camera. Camera 0's is not kept: it is composed at once
    /// and never waits for anything.
    private var tiles: [Int: CVPixelBuffer] = [:]
    private var cameraCount = 1
    private var scheduled = false
    private var pendingMain: CVPixelBuffer?
    private var pendingRate = 0.0
    private var stopped = false

    init(sink: @escaping Sink) {
        self.sink = sink
        // Its own context, like the assist stage's and the keyer's: a context
        // holds caches sized for the work it has seen, and this pass is a
        // different size and shape from every other one in the app.
        context = CIContext(options: [.cacheIntermediates: false])
    }

    /// The channel list reshaped. Hopped onto this queue like every other read
    /// of this state, so a multicam switch cannot race a compose.
    func setCameraCount(_ count: Int) {
        queue.async { [self] in
            cameraCount = max(1, count)
            // A camera that went away must not keep a tile: its picture would
            // sit in the grid for the rest of the day, and a grid showing a
            // board nobody is recording is worse than one tile short.
            tiles = tiles.filter { $0.key < cameraCount }
        }
    }

    /// Offer one camera's clean frame. Called on that camera's display queue;
    /// returns at once — the hop is an async dispatch, never a wait.
    ///
    /// `framesPerSecond` is only read from camera 0: the grid runs at the main
    /// camera's rate by construction, and a B-cam at a different rate is a tile
    /// that refreshes when it refreshes.
    func offer(_ buffer: CVPixelBuffer, camera: Int, framesPerSecond: Double) {
        queue.async { [self] in
            guard !stopped else { return }
            guard camera == 0 else {
                tiles[camera] = buffer // latest wins; composed with the main one
                return
            }
            pendingMain = buffer // latest wins
            pendingRate = framesPerSecond
            guard !scheduled else { return }
            scheduled = true
            queue.async { [weak self] in self?.composePending() }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            tiles.removeAll()
            pendingMain = nil
        }
    }

    private func composePending() {
        scheduled = false
        guard !stopped, let pending = pendingMain else { return }
        pendingMain = nil
        guard let composed = compose(main: pending) else { return }
        sink(composed, pendingRate)
    }

    /// The grid, at the main camera's raster.
    ///
    /// **The canvas follows the main camera and not the camera count**, which is what
    /// keeps a multicam switch off the encoder: a raster change rebuilds the
    /// `VTCompressionSession` and costs every watcher a gap and a keyframe
    /// (`LiveVideoEncoder.session(for:)`), and adding a B-cam should not do
    /// that to the director. Tiles get smaller inside a canvas that does not
    /// move.
    private func compose(main: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(main)
        let height = CVPixelBufferGetHeight(main)
        guard width > 0, height > 0,
              let out = pool.buffer(width: width, height: height) else {
            return nil
        }
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width),
                            height: CGFloat(height))
        // One camera and nothing else to draw: the grid IS the clean picture,
        // and a scale-to-self plus a letterbox with no bars is a full render
        // pass for an identity. Handed straight back instead.
        guard cameraCount > 1 else { return main }
        // Raw code values on both ends, like every other stage in the display
        // path: these buffers hold 709-encoded codes and a managed render here
        // would shift a picture the operator is judging exposure on.
        var image = CIImage(color: .black).cropped(to: canvas)
        for camera in 0..<cameraCount {
            let source: CVPixelBuffer? = camera == 0 ? main : tiles[camera]
            guard let source else { continue }
            let tile = CIImage(cvPixelBuffer: source,
                               options: [.colorSpace: NSNull()])
            image = Self.placed(tile, in: Self.cell(camera: camera,
                                                    cameras: cameraCount,
                                                    in: canvas))
                .composited(over: image)
        }
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        guard let task = try? context.startTask(toRender: image.cropped(to: canvas),
                                                to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        return out
    }
}
