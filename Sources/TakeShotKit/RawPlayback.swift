import CBraw
import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import QuartzCore

/// Player for RAW clips: decodes frames on a background task and presents
/// them to registered MetalPreviewLayer sinks — the same display path as
/// live and AVPlayer playback, so color and geometry match.
///
/// The clip decoders themselves live in `RawClipSource.swift`. What this type
/// DOES is split by job: the operator's controls in `RawPlayback+Transport`,
/// the decode/present loop in `RawPlayback+PlayLoop`, scope analysis in
/// `RawPlayback+Scopes`. Members those reach are module-internal rather than
/// private for that reason, and never wider than the module.
@MainActor
final class RawPlayerModel: ObservableObject {
    /// Written by the transport and the play loop only — module-internal rather
    /// than `private(set)` because those live in the extensions above, and Swift
    /// has no setter access level between "this file" and "this module". Nothing
    /// outside this type assigns them.
    @Published var isPlaying = false
    @Published var isLooping = false
    @Published var currentFrame = 0
    /// Loop range in frames.
    @Published var inFrame: Int?
    @Published var outFrame: Int?

    let url: URL
    let frameCount: Int
    let frameRate: Double
    let width: Int
    let height: Int
    let startTimecode: Timecode?
    var formatBadge: String { clip.formatBadge }

    /// Scope data from decoded frames while playing (main queue).
    var onScopeData: ((ScopeData) -> Void)?
    /// Told when the loop range moved, so the controller can file it for this clip
    /// and persist it. Only fired for a real change.
    var onRangeChanged: (() -> Void)?
    var scopesEnabled = false
    /// The part of the frame the scopes read — the punched-in crop the viewer
    /// shows, `.full` otherwise.
    var scopeRegion = ScopeRegion.full

    /// A `refreshScopes` pass is in flight (see `RawPlayback+Scopes`).
    var scopeRefreshing = false
    /// Another refresh was asked for while that pass ran — a paused clip has no
    /// next frame to make up for a dropped one, so it is run afterwards.
    var scopeRefreshPending = false

    let clip: RawClipSource
    var playTask: Task<Void, Never>?
    /// Bumped on every play/pause/seek: a cancelled loop parked in a blocking
    /// decode wakes up later — its writes must not clobber the new session.
    var playGeneration = 0

    // sinks follow the PlaybackFrameTap pattern: one layer per mount
    private let sinks = PreviewSinkRegistry()
    /// The operator aids, drawn into the frame on its way out (see
    /// `AssistStage`). Confined to whichever thread `present` runs on — the
    /// decode task, or main when a paused clip is re-presented; both are
    /// serialized by the play generation.
    private let assistStage = AssistStage()
    /// Every presented frame — hardware playout mirror. Set from the main
    /// actor, read on the decode task; a tiny lock keeps it honest.
    private let displayFrameLock = NSLock()
    nonisolated(unsafe) private var displayFrameHandler:
        (@Sendable (CVPixelBuffer) -> Void)?

    nonisolated func setOnDisplayFrame(
        _ handler: (@Sendable (CVPixelBuffer) -> Void)?) {
        displayFrameLock.lock()
        displayFrameHandler = handler
        displayFrameLock.unlock()
    }
    /// Last decoded frame — re-presented to newly registered sinks, and
    /// re-analyzed by `+Scopes` when a paused clip's crop moves (which is why
    /// it is not private).
    var lastBuffer: CVPixelBuffer?

    init?(url: URL, error errorText: inout String?) {
        let clip: RawClipSource
        do {
            let ext = url.pathExtension.lowercased()
            if ext == "braw" {
                clip = try BRAWSource(url: url)
            } else if ext == "r3d" {
                // scaffold: recognized, decoder not integrated yet
                errorText = L("r3d_not_supported")
                return nil
            } else {
                clip = try DNGSequenceSource(folder: url)
            }
        } catch {
            errorText = error.localizedDescription
            return nil
        }
        self.url = url
        self.clip = clip
        frameCount = clip.frameCount
        frameRate = clip.frameRate > 0 ? clip.frameRate : 24
        width = clip.width
        height = clip.height
        // "HH:MM:SS:FF" (or ";" before FF for drop-frame)
        startTimecode = Self.parseTimecode(
            clip.startTimecodeText, fps: Int(clip.frameRate.rounded()))
    }

    deinit {
        playTask?.cancel()
    }

    // MARK: - sinks

    func addSink(_ layer: MetalPreviewLayer) {
        sinks.add(layer)
        if let buffer = lastBuffer {
            layer.present(assistStage.rendered(buffer) ?? buffer)
        } else {
            showFrame(currentFrame) // first mount: decode the poster frame
        }
    }

    func removeSink(_ layer: MetalPreviewLayer) {
        sinks.remove(layer)
    }

    /// The aids: drawn into the presented frame (which is what reaches the
    /// hardware playout — owner item 7) and handed to the sinks for the
    /// geometry half. A paused clip is re-presented so the change lands.
    func setViewAssist(_ assist: ViewAssist) {
        assistStage.setAssist(assist)
        sinks.setAssist(assist)
        if let buffer = lastBuffer { present(buffer) }
    }

    func setLetterbox(_ color: CIColor) {
        sinks.setLetterbox(color)
    }

    /// `lastBuffer` keeps the CLEAN decoded frame — that is what a still grab
    /// out of a RAW clip is taken from — and only the copy on its way to the
    /// surfaces carries the aids.
    nonisolated func present(_ buffer: CVPixelBuffer) {
        let shown = assistStage.rendered(buffer) ?? buffer
        sinks.present(shown)
        displayFrameLock.lock()
        let handler = displayFrameHandler
        displayFrameLock.unlock()
        handler?(shown)
    }
}

// MARK: - readouts

extension RawPlayerModel {
    /// Seconds view of the range (shared transport UI).
    var inPoint: Double? { inFrame.map { Double($0) / max(1, frameRate) } }
    var outPoint: Double? { outFrame.map { Double($0) / max(1, frameRate) } }

    fileprivate static func parseTimecode(_ text: String?, fps: Int) -> Timecode? {
        guard let text else { return nil }
        let dropFrame = text.contains(";")
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == ";" })
            .compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return Timecode(hours: parts[0], minutes: parts[1], seconds: parts[2],
                        frames: parts[3], fps: max(1, fps),
                        isDropFrame: dropFrame)
    }

    /// The frame currently on screen (grab-still in RAW playback).
    func currentBuffer() -> CVPixelBuffer? { lastBuffer }

    /// End TC of the clip (transport right-hand readout).
    var endTimecodeText: String {
        let fps = max(1, Int(frameRate.rounded()))
        let start = startTimecode?.frameNumber ?? 0
        return Timecode(frameNumber: start + frameCount, fps: fps,
                        isDropFrame: startTimecode?.isDropFrame ?? false)
            .description
    }

    /// Current position as timecode text for the player badge.
    var timecodeText: String {
        let fps = Int(frameRate.rounded())
        guard let start = startTimecode else {
            let seconds = Int(Double(currentFrame) / max(1, frameRate))
            return String(format: "%02d:%02d:%02d:%02d", seconds / 3600,
                          (seconds / 60) % 60, seconds % 60,
                          currentFrame % max(1, fps))
        }
        return Timecode(frameNumber: start.frameNumber + currentFrame,
                        fps: max(1, fps),
                        isDropFrame: start.isDropFrame).description
    }
}
