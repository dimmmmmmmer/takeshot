import AVFoundation
import CaptureCore
import Combine
import Foundation

/// **The pinned reference as a CLIP that plays**, rather than the still frame
/// a pin has always been.
///
/// Owner: "реф видео из плейбека при пине на странице река не играет как видео
/// а остается стиллом". Pinning has always deep-copied ONE decoded frame
/// (`CapturePipeline.setPreviewReference`), which is right for a still off the
/// card and wrong for the thing an operator actually pins — the take they just
/// shot, to line the next setup up against. A frozen frame of a moving
/// reference is a worse reference than the clip: an actor's position, a camera
/// move, a practical coming on are all in the motion.
///
/// A second engine, owned like `RawPlayerModel` is: the controller holds one
/// while a reference is pinned from a video take and lets go of it on unpin.
/// Internally it is `SyncPlayModel.Tile` — the app's other "one more player
/// beside the main one" — down to `automaticallyWaitsToMinimizeStalling =
/// false` (local files) and `isMuted = true` (a reference is a picture; the
/// sound on set is the sound on set).
///
/// **Where its frames go, and what they must never do.** The tap decodes on
/// its own queue (`takeshot.playback-tap`), and from THAT queue the frame is
/// stored behind a lock and pushed straight onto the A/B pane
/// (`CapturePipeline.presentReference`). The capture queue — the one that
/// appends to the writer, where a slow pass is not a late picture but a hole in
/// the file — only ever reads the stored frame through
/// `CapturePipeline.setReferenceFrameProvider`, which is one lock and one
/// retain. It must never reach for `PlaybackFrameTap.currentBuffer()`, which is
/// a `queue.sync` and would park the capture queue behind a decode.
@MainActor
final class ReferenceClipPlayer: ObservableObject {
    let url: URL
    /// The operator's own in/out, if they marked one. A reference loops the
    /// part they said matters rather than the whole take.
    let range: ClipRange
    let player: AVPlayer
    let tap = PlaybackFrameTap()

    /// Whether the clip is rolling. Published because the one operator control
    /// this feature offers is a freeze, and a button has to say which state it
    /// is in.
    @Published private(set) var isPlaying = false

    /// The latest decoded frame, behind a lock rather than behind the tap's
    /// queue — see the type's own doc for why that distinction is the whole
    /// design.
    ///
    /// Its own tiny class because it is written on the decode queue and read
    /// on the capture queue, and neither is the main actor: a property of a
    /// `@MainActor` type cannot be either.
    private final class LatestFrame: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: CVPixelBuffer?

        func store(_ new: CVPixelBuffer) {
            lock.lock()
            buffer = new
            lock.unlock()
        }

        func read() -> CVPixelBuffer? {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    private let frames = LatestFrame()
    private var endObserver: NSObjectProtocol?
    private var boundaryObserver: Any?

    init(url: URL, range: ClipRange, startAt seconds: Double?,
         pipeline: CapturePipeline) {
        self.url = url
        self.range = range
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        // `.none` rather than the `.pause` the sync-play tiles use: a
        // reference that stops at the end is a still again, which is the
        // report this type exists to answer. The LOOP itself is the observers
        // below — this only spares the operator a visible stop at the seam,
        // and no test pins it, because with the observers in place a `.pause`
        // is recovered from within a frame. It is a comfort, not the
        // mechanism.
        player.actionAtItemEnd = .none
        player.isMuted = true
        self.player = player
        tap.attach(to: item, url: url)
        let frames = self.frames
        tap.setOnDisplayFrame { [weak pipeline] frame in
            // **The clean picture of THIS tap, which is never given an
            // assist** — and that is load-bearing rather than incidental.
            //
            // A clean picture carries the operator's settled framing now
            // (`AssistStage.framed`), and this buffer is not only shown on the
            // A/B pane: it is stored and read back on the capture queue as the
            // back half of the DIFFERENCE compare
            // (`CapturePipeline.setReferenceFrameProvider`), which measures
            // code values. `push(_:)` reaches the pipeline, the playback tap
            // and the RAW player and nothing else, so this tap's stage sits at
            // the default and `framed` answers nil.
            //
            // The day somebody pushes an assist to this tap, |A−B| quietly
            // starts measuring a resampled picture. Take the framing off here
            // if that ever happens.
            let buffer = frame[.clean]
            frames.store(buffer)
            // Straight onto the A/B pane, from the decode's own queue. See the
            // type doc: routing this through the pipeline's queue would put a
            // decode in front of the writer.
            pipeline?.presentReference(buffer)
        }
        installLoop(item: item)
        // The operator's own IN point, or wherever they were watching when
        // they pinned: a reference pinned at a specific moment should start
        // from that moment rather than from the head of the take.
        seek(to: range.inPoint ?? seconds ?? 0)
    }

    /// The frame the compare should composite right now, or nil before the
    /// first one has been decoded — in which case the pinned still is still
    /// there to fall back on.
    nonisolated func latestFrame() -> CVPixelBuffer? { frames.read() }

    /// Decode and play, or stop doing either.
    ///
    /// Both halves together on purpose: the tap's 60 Hz poll and the player's
    /// rate are one decision — "is this reference on screen" — and a tap left
    /// running over a paused player is the "decode for nothing" this app
    /// refuses everywhere else.
    func setRunning(_ running: Bool) {
        tap.setRunning(running)
        if running {
            player.play()
        } else {
            player.pause()
        }
        isPlaying = running
    }

    /// The operator's one control: freeze the reference where it is, or let it
    /// run again. The tap keeps running while frozen — a frozen reference is
    /// still on screen, and stopping the poll would leave the A/B pane with
    /// whatever it happened to hold.
    func togglePlaying() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    /// Stop the poll, let go of the item, and take the observers with it.
    /// Explicit rather than in `deinit`, like `SyncPlayModel.Tile.shutDown`:
    /// the tap's timer belongs to the dispatch system once it is resumed.
    func shutDown() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
        player.pause()
        isPlaying = false
        tap.setRunning(false)
        tap.detach()
    }

    /// **The loop, both ends of it.**
    ///
    /// A marked OUT point is a boundary observer; the file's own end is the
    /// notification. Both land on the same seek, so a reference with no range
    /// loops the whole take and one with a range loops the part the operator
    /// said matters — the same `ClipRange` the transport writes to the
    /// sidecar, not a second idea of "the interesting bit".
    private func installLoop(item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item,
            queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.loop() }
        }
        guard let outPoint = range.outPoint else { return }
        let mark = NSValue(time: CMTime(seconds: outPoint,
                                        preferredTimescale: 600))
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [mark], queue: .main) { [weak self] in
            Task { @MainActor [weak self] in self?.loop() }
        }
    }

    private func loop() {
        seek(to: range.inPoint ?? 0)
        guard isPlaying else { return }
        player.play()
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds),
                               preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
