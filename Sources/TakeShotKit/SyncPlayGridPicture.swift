import CaptureCore
@preconcurrency import CoreVideo
import Foundation

/// **The sync-play grid as a display-frame source** — the fourth one, beside
/// the live pipeline, the playback tap and the RAW engine.
///
/// The app has three things that publish a `LiveFrame` to the viewer's mirrors,
/// and each of them owns a lock-guarded handler slot that `wireDisplayMirrors`
/// installs into: `CapturePipeline`, `PlaybackFrameTap` and `RawPlayerModel`.
/// A comparison is a fourth: what the operator is looking at then is not any
/// one of those surfaces but a grid composed out of several playback taps, and
/// the mirrors exist to show the director what the operator is looking at. So
/// it gets the same slot rather than a special case downstream — every mirror
/// keeps naming a `LivePicture` and reading it through `LiveFrame`'s subscript,
/// which is the one place a name becomes a buffer.
///
/// **A tile has no assist stage and no viewing LUT**, so the grid's decorated
/// picture and its clean one are the SAME buffer, named twice. That is a
/// measurement about `SyncPlayModel.Tile` — nothing sets a LUT or an assist on
/// a tile's tap, so `PlaybackFrameTap.deliver` hands back `shown === output` —
/// and not an assertion that they should be equal. If the tiles ever grow an
/// assist stage, `.decorated` follows it here for free and `.clean` does not,
/// which is the split every other source already has.
///
/// **The tile names and timecodes ARE in this picture**, which they were not.
/// They used to be SwiftUI chrome over the grid — `SyncPlayView`'s per-tile
/// overlays — so every surface this file feeds saw anonymous rectangles and a
/// director comparing four takes could not tell which was which. They are drawn
/// into the composed frame now: `TileIdentity.take` per tile and the tile's own
/// clock, pushed from `CaptureController+SyncPlayPicture` and rendered by
/// `MultiviewComposer`. What that changed here is nothing at all — this file
/// still publishes whatever the composer hands it — which is the point of the
/// identity living down there rather than in each of the four sources.
///
/// Nothing here exists while nobody is watching: the controller builds one when
/// a mirror appears under a comparison and drops it when the last one goes
/// (`CaptureController+SyncPlayPicture`).
final class SyncPlayGridPicture: @unchecked Sendable {
    /// Set from the main actor, read on the composer's queue — the same
    /// crossing, and the same lock, as the three sources above.
    private let lock = NSLock()
    private var displayFrameHandler: (@Sendable (LiveFrame) -> Void)?
    /// The raster the last grid was composed at, so `blank` can answer at the
    /// size the mirrors are already carrying rather than at a guess.
    private var lastWidth = 0
    private var lastHeight = 0
    /// Blanked once — and then never again a grid.
    ///
    /// A latch rather than an ordering, because the ordering cannot be had: the
    /// tiles stop delivering on their own queues and the blank is issued from
    /// the main actor, so a compose already past the composer's `stopped` guard
    /// can reach `publish` AFTER the replacement has gone out and freeze the
    /// mirrors on the grid all over again. This makes the sequence irrelevant.
    private var blanked = false

    func setOnDisplayFrame(_ handler: (@Sendable (LiveFrame) -> Void)?) {
        lock.lock()
        displayFrameHandler = handler
        lock.unlock()
    }

    /// One composed grid, from `MultiviewComposer`'s queue.
    func publish(_ buffer: CVPixelBuffer) {
        lock.lock()
        guard !blanked else {
            lock.unlock()
            return
        }
        let handler = displayFrameHandler
        lastWidth = CVPixelBufferGetWidth(buffer)
        lastHeight = CVPixelBufferGetHeight(buffer)
        lock.unlock()
        handler?(LiveFrame(decorated: buffer, clean: buffer))
    }

    /// **One black frame, because the mirrors HOLD their last one.**
    ///
    /// `PlayoutFeeder` submits and the board goes on showing what it was given;
    /// an NDI receiver keeps the last frame it got; a browser keeps the last one
    /// it decoded. So a source going quiet is not the same thing as a surface
    /// going blank, and when a comparison ends with no take parked underneath it
    /// there is nothing to take the grid's place — the four-up picture would sit
    /// on the director's monitor for the rest of the day, looking exactly like a
    /// comparison somebody is running.
    ///
    /// Black is the honest answer there and it is the only one available: the
    /// app has no picture at that moment. Composed at the raster the grid was
    /// last composed at, so the H.264 sessions are not rebuilt for one frame
    /// (`LiveVideoEncoder.session(for:)` rebuilds on a raster change and costs
    /// every watcher a gap). A grid that never composed anything has nothing to
    /// blank and does nothing.
    ///
    /// Allocated rather than pooled, deliberately: this is one frame at the end
    /// of a comparison, and a pooled buffer can be vended again while a consumer
    /// still holds this one.
    @discardableResult
    func blank() -> Bool {
        lock.lock()
        let handler = displayFrameHandler
        let width = lastWidth
        let height = lastHeight
        blanked = true
        lock.unlock()
        guard let handler, width > 0, height > 0,
              let black = Self.blackFrame(width: width, height: height)
        else { return false }
        handler(LiveFrame(decorated: black, clean: black))
        return true
    }

    /// Opaque black BGRA. The alpha is filled rather than left at the
    /// allocator's zero: a DeckLink output ignores it, NDI's BGRA does not, and
    /// a transparent "black" frame is a receiver's own background.
    private static func blackFrame(width: Int, height: Int) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let made else { return nil }
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        guard let base = CVPixelBufferGetBaseAddress(made) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(made)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = bytes + y * stride
            for x in 0..<width {
                let pixel = row + x * 4
                pixel[0] = 0
                pixel[1] = 0
                pixel[2] = 0
                pixel[3] = 0xFF
            }
        }
        return made
    }
}
