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
    var displayFrameHandler: (@Sendable (CVPixelBuffer) -> Void)?

    func setOnDisplayFrame(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {
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
    var liveBufferProvider: (() -> CVPixelBuffer?)?
    /// Pulls the same live frame at the pre-LUT stage — the difference compare
    /// measures code values, so its back half must not carry the preview LUT.
    /// Falls back to `liveBufferProvider` when unset.
    var livePreLUTBufferProvider: (() -> CVPixelBuffer?)?

    /// Queue-confined setter — the provider is read on the tap queue.
    func setLiveBufferProvider(_ provider: @escaping () -> CVPixelBuffer?) {
        queue.async { self.liveBufferProvider = provider }
    }

    /// Queue-confined setter for the pre-LUT half (see the property above).
    func setLivePreLUTBufferProvider(_ provider: @escaping () -> CVPixelBuffer?) {
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
            self.stillBuffer = buffer
            self.lastBuffer = buffer
            self.deliver(buffer, analyzed: self.scopesEnabled)
            self.startTimerIfNeeded()
        }
    }

    /// Attach to a new clip (the old output is removed).
    func attach(to item: AVPlayerItem) {
        queue.async {
            self.detachLocked()
            // BGRA full range: MetalPreviewLayer passes code values through
            // unmanaged, and full-range RGB is the exact same representation
            // the live path draws — playback and rec render identically
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
            item.add(output)
            self.output = output
            self.item = item
            self.lastBuffer = nil
            // until the file has said otherwise it is treated as a picture, so
            // a foreign clip is never expanded on a guess
            self.sourceCarriesWireCodes = false
            self.detectLevels(of: item)
            self.startTimerIfNeeded()
        }
    }

    func setRunning(_ running: Bool) {
        queue.async {
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
            item.remove(output)
        }
        output = nil
        item = nil
        stillBuffer = nil
    }
}
