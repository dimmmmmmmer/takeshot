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
/// **…and that is a statement about LIVE cameras, which is why `Pacing`
/// exists.** This composer was written for boards, where every tile is its own
/// running signal and "one frame stale" is bounded by that signal's own frame
/// interval. A sync-play grid is the other case — 2-4 takes being played back
/// against ONE master transport (`SyncPlayModel`) — and two of the three
/// assumptions above do not survive the move:
///
/// - **The clock tile and the top-left tile are not the same tile.** Camera 0
///   is the clock here because on a multicam rig the main board is both. A
///   comparison's tiles have different LENGTHS, so the first one can freeze on
///   its last frame while the others are still rolling, and a compose paced to
///   it would freeze the whole grid on the director's monitor while the
///   operator watches three takes carry on. `SyncPlayModel` already names the
///   tile that plays longest — its `anchorIndex` — for exactly this reason, and
///   `.clock(camera:)` is how that name reaches here.
/// - **A paused grid has no clock at all.** A stepped comparison delivers ONE
///   frame per tile per step, in whatever order four independent 60 Hz taps
///   happen to tick, and then nothing. Paced to one tile, every tile that
///   ticked after it stays a step behind — permanently, and invisibly, because
///   the operator's own screen is right. `.everyFrame` is for that: when
///   nothing is delivering at a rate worth pacing to, there is nothing to pace,
///   and the cost is four composes per STEP rather than four per frame
///   interval.
///
/// Neither is a live-camera concern and neither changes what a live grid does:
/// the default is `.clock(camera: 0)`, which is this file as it was written,
/// and `CaptureController+LivePictures` never sets it.
///
/// **Each tile says what it is, in the picture.** The name, the REC lamp and
/// the running timecode used to be SwiftUI chrome drawn over the grid on the
/// operator's own screen — the one surface that never needed them — so every
/// far end this composer feeds saw anonymous rectangles. They are composited in
/// here now, once, so the hardware monitor, the SDI output, NDI, SRT and every
/// browser get them together rather than four times or not at all. What a tile
/// IS lives in `TileIdentity`, which has two cases because this composer has
/// two callers and their tiles are two kinds of thing; what it costs and what
/// is cached lives in `TileBadge`. The clock is pushed separately from the
/// identity because it moves at a completely different rate — both notes say
/// why at their own types.
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
    /// **What runs the compose pass** — the one concept a transport-locked grid
    /// needed that a rig of live boards did not. See the note at the top of this
    /// file for why there are two answers rather than one.
    enum Pacing: Equatable, Sendable {
        /// One tile is the clock: it composes, the others replace their tile
        /// and wait. The live rule, and the default.
        ///
        /// The camera is nameable rather than fixed at 0 because the clock and
        /// the top-left cell are two different questions — they coincide on a
        /// multicam rig and come apart in a comparison, where the tile that
        /// plays longest is the only one guaranteed to still be delivering.
        case clock(camera: Int)
        /// No tile is running at a rate worth pacing to, so every arrival
        /// composes. What a PAUSED comparison needs: its tiles deliver once
        /// each per step and then stop.
        case everyFrame

        /// Whether a frame from `camera` runs the pass.
        func composes(on camera: Int) -> Bool {
            switch self {
            case .clock(let clock): return camera == clock
            case .everyFrame: return true
            }
        }
    }

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

    /// Newest frame per camera, camera 0's included — the canvas is sized off
    /// it (see `compose`), and under `.everyFrame` the pass can be run by a
    /// tile that is not camera 0 at all, so it has to be here to be found.
    private var tiles: [Int: CVPixelBuffer] = [:]
    /// **Who each tile is** — see `TileIdentity` for why the two callers' tiles
    /// are two kinds rather than one with a flag. Slow-moving: a rename or a
    /// REC press, restated on every tick by the wiring and absorbed by the
    /// badge cache.
    private var identities: [Int: TileIdentity] = [:]
    /// **Where each tile is in time.** Separate from the identity because it
    /// changes every frame and arrives from somewhere else entirely; separate
    /// all the way down, so a tick does not rebuild a nameplate.
    private var clocks: [Int: String] = [:]
    private var cameraCount = 1
    private var scheduled = false
    private var pendingRate = 0.0
    private var pacing = Pacing.clock(camera: 0)
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
            // …and must not keep its NAME either, which is the worse half: a
            // stale picture at least looks like a picture, while a label left
            // behind would sit over whatever tile inherits that cell and say it
            // is a camera that is no longer in the session.
            identities = identities.filter { $0.key < cameraCount }
            clocks = clocks.filter { $0.key < cameraCount }
        }
    }

    /// Who a tile is. Hopped onto this queue like every other read of this
    /// state, so a rename or a REC press cannot race a compose.
    ///
    /// Restating an unchanged identity is free — the badge cache is keyed on
    /// what is drawn, so this is a dictionary write and a lookup — which is
    /// what lets the wiring push it on every timecode tick and never have to
    /// work out whether anything changed.
    func setIdentity(_ identity: TileIdentity?, camera: Int) {
        queue.async { [self] in identities[camera] = identity }
    }

    /// Where a tile is in time, already rendered to the string the picture
    /// shows. A string rather than a `Timecode` because the two callers format
    /// it differently and both formats already exist on the main actor: a live
    /// board's is `Timecode.description` off `CapturePipeline.onTimecode`, a
    /// comparison tile's is `SyncPlayModel.tileTimecodeText`, which counts
    /// within the clip. Choosing between them here would be a third opinion.
    func setClock(_ timecode: String?, camera: Int) {
        queue.async { [self] in clocks[camera] = timecode }
    }

    /// What runs the pass. Hopped onto this queue like every other read of this
    /// state; never called by the live grid, which keeps the default.
    func setPacing(_ pacing: Pacing) {
        queue.async { [self] in self.pacing = pacing }
    }

    /// Offer one camera's clean frame. Called on that camera's display queue;
    /// returns at once — the hop is an async dispatch, never a wait.
    ///
    /// `framesPerSecond` is read from whichever camera runs the pass: under the
    /// live rule that is camera 0 alone, so the grid runs at the main camera's
    /// rate by construction and a B-cam at a different rate is a tile that
    /// refreshes when it refreshes. A comparison's tiles are all offered the
    /// master transport's one rate, so there is nothing to choose between.
    func offer(_ buffer: CVPixelBuffer, camera: Int, framesPerSecond: Double) {
        queue.async { [self] in
            guard !stopped else { return }
            tiles[camera] = buffer // latest wins, every camera
            guard pacing.composes(on: camera) else { return }
            pendingRate = framesPerSecond
            guard !scheduled else { return }
            scheduled = true
            queue.async { [weak self] in self?.composePending() }
        }
    }

    /// What the composer is holding for one tile, read by hopping onto its own
    /// queue like every other access to this state.
    ///
    /// **For the suite, and it earns its place.** Most of this change shows up
    /// in the picture — a lamp widens the plate, a badge is clamped inside its
    /// cell — but two of its rules do not: a departed camera's NAME being
    /// dropped rather than left over the tile that inherits its cell, and a
    /// clock landing on the tile it belongs to. Both are only ever visible as
    /// GLYPHS, and glyphs are what this project's tests may not read (the
    /// centring test that measured drawn bounds and came back nil on a headless
    /// runner). Asserting on the state the draw is made from is the portable
    /// half of that; see `MultiviewIdentityTests` for what it still cannot see.
    func heldIdentity(camera: Int) -> TileIdentity? {
        queue.sync { identities[camera] }
    }

    /// The clock string this tile would be drawn with. Same reason as
    /// `heldIdentity(camera:)`.
    func heldClock(camera: Int) -> String? {
        queue.sync { clocks[camera] }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            tiles.removeAll()
            identities.removeAll()
            clocks.removeAll()
        }
    }

    private func composePending() {
        scheduled = false
        // The canvas is camera 0's raster whoever ran the pass, so a grid whose
        // top-left tile has not delivered yet composes nothing rather than
        // guessing at a size. Self-healing: the first frame from camera 0
        // composes the tiles already waiting.
        guard !stopped, let main = tiles[0] else { return }
        guard let composed = compose(main: main) else { return }
        sink(composed, pendingRate)
    }

    /// The grid, at camera 0's raster.
    ///
    /// **The canvas follows camera 0 and not the camera count**, which is what
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
        // One camera with nothing to say about itself: the grid IS the clean
        // picture, and a scale-to-self plus a letterbox with no bars is a full
        // render pass for an identity. Handed straight back instead.
        //
        // **The pass-through survives exactly as far as "nothing to draw".**
        // Once a single camera HAS a name or a clock, the picture is no longer
        // the clean buffer and there is no way to hand back something that is
        // not the buffer other consumers are sharing — burning a label into the
        // clean picture is the one thing `LivePicture` exists to prevent. So a
        // labelled single camera costs a render where an anonymous one costs
        // 0.010 ms, and that is the honest price of the label rather than a
        // regression to find later.
        guard cameraCount > 1 || identities[0] != nil || clocks[0] != nil else {
            return main
        }
        // Raw code values on both ends, like every other stage in the display
        // path: these buffers hold 709-encoded codes and a managed render here
        // would shift a picture the operator is judging exposure on.
        var image = CIImage(color: .black).cropped(to: canvas)
        for camera in 0..<cameraCount {
            let cell = Self.cell(camera: camera, cameras: cameraCount,
                                 in: canvas)
            if let source = tiles[camera] {
                let tile = CIImage(cvPixelBuffer: source,
                                   options: [.colorSpace: NSNull()])
                image = Self.placed(tile, in: cell).composited(over: image)
            }
            // Drawn whether or not the tile has delivered a frame: a board that
            // has not sent one yet is a black cell, and a black cell with a name
            // on it reads as a camera that is not sending. Without the name it
            // reads as the grid being one tile short.
            image = marked(camera: camera, in: cell, over: image)
        }
        let destination = CIRenderDestination(pixelBuffer: out)
        destination.colorSpace = nil
        guard let task = try? context.startTask(toRender: image.cropped(to: canvas),
                                                to: destination),
              (try? task.waitUntilCompleted()) != nil else { return nil }
        return out
    }

    /// One tile's identity drawn over its cell: the nameplate at the top left,
    /// the clock at the bottom left.
    ///
    /// The corners are the ones `MulticamGrid` and `SyncPlayView` already put
    /// their SwiftUI overlays in, so an operator glancing between their own
    /// screen and the director's monitor reads one layout rather than two. The
    /// bitmaps come out of `TileBadge`'s cache, so what this costs on a settled
    /// grid is two dictionary lookups and two composites — see the note there.
    private func marked(camera: Int, in cell: CGRect,
                        over base: CIImage) -> CIImage {
        let metrics = TileTypeMetrics(tileHeight: cell.height)
        let room = metrics.maximumWidth(in: cell)
        var image = base
        if let identity = identities[camera],
           let plate = TileBadge.nameplate(for: identity, metrics: metrics,
                                           maximumWidth: room) {
            let origin = metrics.nameplateOrigin(
                in: cell, height: plate.extent.height)
            image = plate.transformed(by: CGAffineTransform(
                translationX: origin.x, y: origin.y)).composited(over: image)
        }
        if let clock = clocks[camera],
           let plate = TileBadge.clock(text: clock, metrics: metrics,
                                       maximumWidth: room) {
            let origin = metrics.clockOrigin(in: cell)
            image = plate.transformed(by: CGAffineTransform(
                translationX: origin.x, y: origin.y)).composited(over: image)
        }
        return image
    }
}
