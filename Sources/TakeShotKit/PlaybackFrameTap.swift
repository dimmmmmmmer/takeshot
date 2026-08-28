import AVFoundation
import os.log
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// Unified playback render: frames are pulled from AVPlayer via AVPlayerItemVideoOutput
/// (after videoComposition, i.e. already with the LUT) and drawn by MetalPreviewLayer —
/// the same graphics-path renderer as live. No AVPlayerLayer — live and playback go
/// through the same display path, so wipe/blend compare fairly and colors match.
///
/// Every mount (main window, compare branches, fullscreen, external monitor)
/// registers its OWN layer: a CALayer lives in only one NSView, and a shared
/// instance got stolen between views on branch switches — the survivor then
/// drew with the thief's stale geometry.
///
/// The LUT/compare composite and its B-side clip live in
/// `PlaybackFrameTap+Compose.swift`; members it reaches are module-internal
/// rather than private for that reason.
final class PlaybackFrameTap: @unchecked Sendable {
    let sinks = PreviewSinkRegistry()
    /// Mounts showing the COMPARE SOURCE on its own surface — the A pane of the
    /// A/B split. Its own registry rather than a second `sinks` member: the two
    /// carry different pictures at the same time (A is the B clip, `sinks` is the
    /// clip under review), and one registry would mirror both into every layer.
    let compareSinks = PreviewSinkRegistry()
    /// Every delivered frame (tap queue) — hardware playout mirror. Set from the
    /// main actor while the tap queue reads it, so it goes through a lock (see
    /// the same pattern in CapturePipeline and RawPlayerModel).
    let displayFrameLock = NSLock()
    var displayFrameHandler: (@Sendable (LiveFrame) -> Void)?

    func setOnDisplayFrame(_ handler: (@Sendable (LiveFrame) -> Void)?) {
        displayFrameLock.lock()
        displayFrameHandler = handler
        displayFrameLock.unlock()
    }

    func addSink(_ layer: MetalPreviewLayer) {
        sinks.add(layer)
        // show the current frame right away — a paused player won't push one
        queue.async {
            if let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: false)
            }
        }
    }

    func removeSink(_ layer: MetalPreviewLayer) {
        sinks.remove(layer)
    }

    /// Register a mount for the A/B compare source (see `compareSinks`).
    func addCompareSink(_ layer: MetalPreviewLayer) {
        compareSinks.add(layer)
        // a paused pair pushes nothing — show whatever the B clip is parked on
        queue.async {
            if let buffer = self.lastCompareBuffer {
                self.compareSinks.present(buffer)
            }
        }
    }

    func removeCompareSink(_ layer: MetalPreviewLayer) {
        compareSinks.remove(layer)
    }

    /// The aids. Two destinations, because the value has two halves: the
    /// exposure tools and the guides are drawn into the delivered FRAME (which
    /// is what carries them to the hardware playout — owner item 7), and the
    /// sinks get the whole value for the geometry they place with.
    ///
    /// A paused clip is re-delivered on the spot: nothing else would put the
    /// change on screen, the same reason `setLUT` re-delivers.
    func setViewAssist(_ assist: ViewAssist) {
        assistStage.setAssist(assist)
        sinks.setAssist(assist)
        compareSinks.setAssist(assist)
        queue.async {
            self.idleDelivered = false
            if let buffer = self.lastBuffer {
                self.deliver(buffer, analyzed: false)
            }
        }
    }

    func setLetterbox(_ color: CIColor) {
        sinks.setLetterbox(color)
        compareSinks.setLetterbox(color)
    }

    let queue = DispatchQueue(label: "takeshot.playback-tap", qos: .userInitiated)
    /// Scope analysis runs here, never on the render queue: a pass costs ~14 ms
    /// and the tap polls at 60 Hz, so analyzing inline stuttered the very
    /// picture it was measuring.
    let scopeQueue = DispatchQueue(label: "takeshot.playback-scopes",
                                   qos: .utility)
    /// A pass is in flight (tap-queue confined) — latest-wins, frames offered
    /// while it runs are skipped rather than queued up.
    var scopeBusy = false
    /// A re-analysis of the frame already on screen was asked for while a pass
    /// was in flight (tap-queue confined). Skipping a FRAME is right — a newer
    /// one is 16 ms away — but skipping this request loses it for good, and a
    /// paused clip has no next frame to recover on. See `reanalyzeCurrentFrame`.
    var scopeReanalysisPending = false
    /// The part of the frame the scopes read (punch-in crop; tap-queue confined).
    var scopeRegion = ScopeRegion.full
    /// The poll's own state (`+Tick`): the output being asked for frames, the
    /// item it belongs to, the timer doing the asking, and whether the viewer
    /// wants any of it. Module-internal rather than private for that reason —
    /// nothing outside this type touches them.
    var output: AVPlayerItemVideoOutput?
    weak var item: AVPlayerItem?
    var timer: DispatchSourceTimer?
    var running = false
    var scopesEnabled = false
    var tickCount = 0

    /// Scope data from playback frames (~15 Hz while enabled), on the main queue.
    var onScopeData: ((ScopeData) -> Void)?

    var lastBuffer: CVPixelBuffer?
    /// Static source (a still in the player): composited/analyzed like video.
    var stillBuffer: CVPixelBuffer?

    // MARK: - levels (tap-queue confined; see `+Levels`)

    /// Whether the clip under review carries the camera's wire codes and has to
    /// be expanded for the screen, the way the live path expands the wire.
    var sourceCarriesWireCodes = false
    /// The same question for the compare clip — two takes in a wipe must be
    /// expanded the same way or the seam is a contrast step.
    var compareCarriesWireCodes = false
    /// What the clip under review says it is encoded with — `.sdr` for
    /// everything that is not a PQ or HLG file, which is every take this app
    /// has ever written before HDR and every foreign clip that says nothing.
    var sourceTransfer = SignalTransfer.sdr
    /// The same for the compare clip: two takes in a wipe must be tone mapped
    /// the same way or the seam is a contrast step.
    var compareTransfer = SignalTransfer.sdr
    /// Where the expanded copy goes. A decoder's buffer is not ours to modify:
    /// it can share an IOSurface with a frame the decoder still holds.
    let levelsPool = PixelBufferPool()
    /// Idle output already delivered — with compare off, a paused/still frame
    /// is re-rendered only when the LUT/compare/scopes inputs change.
    var idleDelivered = false

    // MARK: - compare & LUT (composited in PlaybackFrameTap+Compose, in one
    // Metal layer: SwiftUI masks/opacity over video layers drop the colorspace
    // and shift colors)

    /// The compositor's own mode, not a copy of it. The tap used to declare an
    /// identical three-case enum and translate case by case into
    /// `CompareCompositor.Mode` in the render — two spellings of one thing, and
    /// the translation was the only place a fourth mode could be forgotten.
    typealias Compare = CompareCompositor.Mode

    var compare: Compare = .off
    /// Pulls the latest live preview frame (assigned via setLiveBufferProvider).
    ///
    /// `@Sendable` because it is installed from the main actor and called on
    /// the tap queue — the same crossing as every other handler here, and the
    /// pipeline's own frame accessors it forwards to are lock-guarded.
    var liveBufferProvider: (@Sendable () -> CVPixelBuffer?)?
    /// Pulls the same live frame at the pre-LUT stage — the difference compare
    /// measures code values, so its back half must not carry the preview LUT.
    /// Falls back to `liveBufferProvider` when unset.
    var livePreLUTBufferProvider: (@Sendable () -> CVPixelBuffer?)?

    /// Queue-confined setter — the provider is read on the tap queue.
    func setLiveBufferProvider(_ provider: @escaping @Sendable () -> CVPixelBuffer?) {
        queue.async { self.liveBufferProvider = provider }
    }

    /// Queue-confined setter for the pre-LUT half (see the property above).
    func setLivePreLUTBufferProvider(
        _ provider: @escaping @Sendable () -> CVPixelBuffer?) {
        queue.async { self.livePreLUTBufferProvider = provider }
    }
    var lutFilter: CIFilter?
    var lutIntensity: Double = 1

    // B-side clip (take vs take): its own slaved player; when set, the
    // compare back half comes from it instead of the live signal
    var comparePlayer: AVPlayer?
    var compareOutput: AVPlayerItemVideoOutput?
    var lastCompareBuffer: CVPixelBuffer?
    /// Which clip the B side is on — the levels answer arrives after a load and
    /// must not be applied to whatever the operator switched to meanwhile.
    var compareURL: URL?
    weak var syncPlayer: AVPlayer?

    let ciContext = CIContext(options: [.cacheIntermediates: false])
    let composePool = PixelBufferPool()
    /// The operator aids, drawn into the delivered frame (see `AssistStage`).
    /// Tap-queue confined on the render side, like the compositor above it.
    let assistStage = AssistStage()

    func setScopesEnabled(_ on: Bool) {
        queue.async {
            self.idleDelivered = false
            self.scopesEnabled = on
            // paused player delivers no new frames — analyze right away (via
            // deliver, so scopes see the same composed output as the screen)
            if on { self.reanalyzeCurrentFrame() }
        }
    }

    /// Punch-in crop the scopes read. A paused clip delivers no new frames, so
    /// the change is re-analyzed at once.
    func setScopeRegion(_ region: ScopeRegion) {
        queue.async {
            guard region != self.scopeRegion else { return }
            self.scopeRegion = region
            self.reanalyzeCurrentFrame()
        }
    }

    /// The current playback frame (pin-as-reference). Queue-synchronous.
    func currentBuffer() -> CVPixelBuffer? {
        var result: CVPixelBuffer?
        queue.sync { result = self.lastBuffer }
        return result
    }

    /// The frame the compare source is on — the B clip's own picture, exactly as
    /// it is handed to `compareSinks` (the A pane) and to the wipe/blend back
    /// half. Queue-synchronous, like `currentBuffer()`.
    func compareSideBuffer() -> CVPixelBuffer? {
        var result: CVPixelBuffer?
        queue.sync { result = self.lastCompareBuffer }
        return result
    }

    /// Show a still through the same render/LUT/compare path as video.
    func attachStill(_ buffer: CVPixelBuffer) {
        queue.async {
            self.detachLocked()
            self.idleDelivered = false
            // a still is a picture, not a signal: its codes are display values
            self.sourceCarriesWireCodes = false
            self.sourceTransfer = .sdr
            self.stillBuffer = buffer
            self.lastBuffer = buffer
            self.deliver(buffer, analyzed: self.scopesEnabled)
            self.startTimerIfNeeded()
        }
    }

    /// What both video outputs ask the decoder for.
    ///
    /// BGRA full range: MetalPreviewLayer passes code values through unmanaged,
    /// and full-range RGB is the exact same representation the live path draws
    /// — playback and rec render identically. Typed as `any Sendable` rather
    /// than `Any` because the dictionary is built on the main actor and used on
    /// the tap queue: every value in it is a number or an empty dictionary.
    static let displayBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    /// Attach to a new clip (the old output is removed).
    ///
    /// The `url` is the item's own, and it is asked for rather than read back
    /// off the item: `AVPlayerItem.asset` belongs to the main actor and the
    /// levels question is answered on the tap queue, so the file is opened for
    /// its metadata the same way the compare clip's is (see `+Levels`).
    func attach(to item: AVPlayerItem, url: URL) {
        queue.async {
            self.detachLocked()
            let output = AVPlayerItemVideoOutput(
                pixelBufferAttributes: Self.displayBufferAttributes)
            item.attachOutput(output)
            self.output = output
            self.item = item
            self.lastBuffer = nil
            // until the file has said otherwise it is treated as a picture, so
            // a foreign clip is never expanded on a guess
            self.sourceCarriesWireCodes = false
            self.sourceTransfer = .sdr
            self.detectLevels(of: item, at: url)
            self.startTimerIfNeeded()
        }
    }

    /// Poll for frames, or stop.
    ///
    /// **Switching ON drops the idle latch**, and that is what makes "the
    /// parked take comes back" true rather than nearly true. `idleDelivered`
    /// means "this paused picture has already been handed to my surfaces" — and
    /// while the tap was OFF those surfaces were showing something else
    /// entirely: the sync-play grid, the live signal. A paused clip has no next
    /// frame to recover on, so without this the tap comes back on, finds the
    /// latch still set from before it went off, delivers nothing at all, and the
    /// picture that replaced it stays on the hardware output — which holds its
    /// last frame — for the rest of the day.
    func setRunning(_ running: Bool) {
        queue.async {
            if running, !self.running { self.idleDelivered = false }
            self.running = running
            self.startTimerIfNeeded()
        }
    }

    func detach() {
        queue.async { self.detachLocked() }
    }

    /// How often the tap asks the player for a frame: ~60 Hz.
    static let tickIntervalMilliseconds = 16

    /// Ticks between scope passes while playing. At the interval above, 4 is
    /// ~15 updates a second — the same rate the live path aims for — and the
    /// busy gate skips anything the analyzer cannot keep up with.
    ///
    /// Named next to the interval it is a multiple of, rather than as a 16
    /// inside the timer call: the delivered rate is the two of them together,
    /// it is a number the brief for the scopes work is written against, and
    /// `theScopeRateOffPlaybackIsFifteenHertz` asserts it from here.
    static let scopeTickStride = 4

    /// Scope passes a second offered while a clip plays.
    static var scopeUpdatesPerSecond: Double {
        1000 / Double(tickIntervalMilliseconds * scopeTickStride)
    }

    // MARK: - on queue

    func detachLocked() {
        timer?.cancel()
        timer = nil
        if let output, let item {
            item.detachOutput(output)
        }
        output = nil
        item = nil
        stillBuffer = nil
    }
}

/// The two `AVPlayerItem` messages the tap sends, as it has to send them:
/// from `PlaybackFrameTap.queue`, which is not the main actor.
///
/// Both SDKs declare the whole of `AVPlayerItem` `NS_SWIFT_UI_ACTOR`. The
/// macOS 26 SDK then takes exactly these two methods back out of it —
/// `- (void)addOutput:(AVPlayerItemOutput *)output NS_SWIFT_NONISOLATED` —
/// and marks `AVPlayerItemOutput` itself `NS_SWIFT_SENDABLE`. The macOS 15 SDK
/// does neither, so there the same two lines read as a main-actor call made
/// off the main actor, with a non-Sendable value crossing into it. The newer
/// annotation is Apple's own statement that attaching an output is a call any
/// thread may make; it is how this tap has always used them, and nothing has
/// ever misbehaved.
///
/// Obeying the stricter of the two annotations is not open to us, and that is
/// a threading fact rather than a preference. Attach and detach are ordered
/// against frame delivery BY being on the tap queue: hopping them to the main
/// actor would let a removal run while `tick` is copying a buffer out of the
/// very output being removed, and doing it synchronously would deadlock — the
/// opposite hop already exists, `currentBuffer()` and the tests both call
/// `queue.sync` from the main actor.
///
/// So the message is sent dynamically. It is the same `objc_msgSend` with the
/// same argument on the same thread that `item.add(output)` compiles to; the
/// only thing it does not carry is the isolation annotation the two SDKs
/// disagree about. `MainActor.assumeIsolated` would be the lie here — this
/// really is not the main actor, and it would trap on the first clip opened.
extension AVPlayerItem {
    /// `addOutput:` from the tap queue (see above).
    nonisolated func attachOutput(_ output: AVPlayerItemOutput) {
        _ = perform(PlayerItemOutputMessage.add, with: output)
    }

    /// `removeOutput:` from the tap queue (see above).
    nonisolated func detachOutput(_ output: AVPlayerItemOutput) {
        _ = perform(PlayerItemOutputMessage.remove, with: output)
    }
}

/// The two selectors, formed from the SDK's own declarations rather than
/// spelled as strings: a rename on Apple's side is then a build error here
/// instead of an unrecognised selector on set. Both names are overloaded on
/// `AVPlayerItem` — the other pair takes an `AVPlayerItemMediaDataCollector`
/// — which is what the explicit function type picks between.
private enum PlayerItemOutputMessage {
    static let add = #selector(
        AVPlayerItem.add(_:) as (AVPlayerItem) -> (AVPlayerItemOutput) -> Void)
    static let remove = #selector(
        AVPlayerItem.remove(_:) as (AVPlayerItem) -> (AVPlayerItemOutput) -> Void)
}
