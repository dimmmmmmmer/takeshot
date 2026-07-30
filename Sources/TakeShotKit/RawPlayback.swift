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
/// The clip decoders themselves live in `RawClipSource.swift`; the transport
/// and the timecode readouts are extensions at the bottom of this file.
@MainActor
final class RawPlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var isLooping = false
    @Published private(set) var currentFrame = 0
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

    private let clip: RawClipSource
    private var playTask: Task<Void, Never>?
    /// Bumped on every play/pause/seek: a cancelled loop parked in a blocking
    /// decode wakes up later — its writes must not clobber the new session.
    private var playGeneration = 0

    // sinks follow the PlaybackFrameTap pattern: one layer per mount
    private let sinks = PreviewSinkRegistry()
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
    /// Last decoded frame — re-presented to newly registered sinks.
    private var lastBuffer: CVPixelBuffer?

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
            layer.present(buffer)
        } else {
            showFrame(currentFrame) // first mount: decode the poster frame
        }
    }

    func removeSink(_ layer: MetalPreviewLayer) {
        sinks.remove(layer)
    }

    func setViewAssist(_ assist: ViewAssist) {
        sinks.setAssist(assist)
    }

    func setLetterbox(_ color: CIColor) {
        sinks.setLetterbox(color)
    }

    nonisolated private func present(_ buffer: CVPixelBuffer) {
        sinks.present(buffer)
        displayFrameLock.lock()
        let handler = displayFrameHandler
        displayFrameLock.unlock()
        handler?(buffer)
    }
}

// MARK: - transport

extension RawPlayerModel {
    /// Set/clear the in or out point at the playhead (same semantics as the
    /// AVPlayer transport: clicking near an existing point clears it).
    func toggleRangePoint(out: Bool) {
        let before = (inFrame, outFrame)
        let now = currentFrame
        if out {
            if let existing = outFrame, abs(existing - now) < 2 {
                outFrame = nil
            } else {
                outFrame = now
                if let inF = inFrame, inF >= now { inFrame = nil }
            }
        } else {
            if let existing = inFrame, abs(existing - now) < 2 {
                inFrame = nil
            } else {
                inFrame = now
                if let outF = outFrame, outF <= now { outFrame = nil }
            }
        }
        // This engine is thrown away and rebuilt for every clip, so its range is
        // normally filed with the controller only on the way out. That is too late
        // to survive a quit with the clip still open — hence a report on the spot.
        guard (inFrame, outFrame) != before else { return }
        onRangeChanged?()
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard !isPlaying, frameCount > 0 else { return }
        isPlaying = true
        playGeneration += 1
        let generation = playGeneration
        // restart from the top (or the in point) when play is hit at the end
        let floorFrame = inFrame ?? 0
        let startFrame = currentFrame >= frameCount - 1
            ? floorFrame : max(currentFrame, 0)
        currentFrame = startFrame
        playTask = makePlayTask(startFrame: startFrame, generation: generation)
    }

    /// The decode/present loop. It carries `generation`: a loop that was
    /// cancelled while parked in a blocking decode wakes up later, and every
    /// write it could make is gated on the generation still being current.
    private func makePlayTask(startFrame: Int,
                              generation: Int) -> Task<Void, Never> {
        let clip = clip
        let fps = frameRate
        let total = frameCount
        return Task.detached(priority: .userInitiated) { [weak self] in
            let startHost = CACurrentMediaTime()
            var scopeCounter = 0
            var index = startFrame
            while !Task.isCancelled {
                guard let buffer = clip.copyFrame(at: index) else {
                    break
                }
                guard let self else { return }
                scopeCounter += 1
                guard await self.presentPlayed(buffer, at: index,
                                               generation: generation,
                                               scopeCounter: scopeCounter)
                else { return }
                let next = await Self.nextIndex(after: index,
                                                startFrame: startFrame,
                                                startHost: startHost, fps: fps)
                let outLimit = await MainActor.run { [weak self] in
                    self?.outFrame
                }
                if let outLimit, next > outLimit {
                    let looping = await MainActor.run { [weak self] in
                        self?.isLooping ?? false
                    }
                    if looping {
                        return await self.restartLoop(fromInPoint: true,
                                                      generation: generation)
                    }
                    break
                }
                if next >= total {
                    let looping = await MainActor.run { [weak self] in
                        self?.isLooping ?? false
                    }
                    if !looping { break }
                    // loop restarts the time base at frame 0
                    return await self.restartLoop(fromInPoint: false,
                                                  generation: generation)
                }
                index = next
            }
            await self?.finishLoop(generation: generation)
        }
    }

    /// Present one decoded frame and publish the transport state. Returns
    /// false when the loop is stale — pause/seek happened mid-decode, and
    /// neither the picture nor the transport state may be touched.
    nonisolated private func presentPlayed(_ buffer: CVPixelBuffer, at index: Int,
                                           generation: Int,
                                           scopeCounter: Int) async -> Bool {
        let state = await MainActor.run {
            (live: self.playGeneration == generation && self.isPlaying,
             scopes: self.scopesEnabled)
        }
        guard state.live else { return false }
        self.present(buffer)
        // analysis stays OFF the MainActor: noisy frames are expensive
        let scopeData = scopeCounter % 6 == 0 && state.scopes
            ? ScopeAnalyzer.analyze(buffer) : nil
        let boxed = UncheckedSendable(buffer)
        await MainActor.run {
            self.lastBuffer = boxed.value
            self.currentFrame = index
            if let scopeData {
                self.onScopeData?(scopeData)
            }
        }
        return true
    }

    /// Real-time mapping: skip frames if decode is slower than fps, and wait
    /// out the slot if it is faster.
    nonisolated private static func nextIndex(
        after index: Int, startFrame: Int,
        startHost: CFTimeInterval, fps: Double) async -> Int {
        let elapsed = CACurrentMediaTime() - startHost
        var next = startFrame + Int(elapsed * fps) + 1
        if next <= index { // decode faster than fps: wait for the slot
            next = index + 1
            let slotTime = startHost + Double(next - startFrame) / fps
            let wait = slotTime - CACurrentMediaTime()
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            }
        }
        return next
    }

    /// Loop point reached: hand the session to a NEW generation. A loop that
    /// is no longer the current one must not restart playback behind its back.
    private func restartLoop(fromInPoint: Bool, generation: Int) {
        guard isPlaying, playGeneration == generation else { return }
        isPlaying = false
        currentFrame = fromInPoint ? (inFrame ?? 0) : 0
        play()
    }

    /// The loop ran out (clip end, failed decode, cancellation): only the
    /// generation that is still current may clear the playing flag.
    private func finishLoop(generation: Int) {
        guard playGeneration == generation else { return }
        isPlaying = false
    }

    func pause() {
        playGeneration += 1 // orphan any loop parked in a blocking decode
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    /// Show one frame (paused seek / poster). Decode runs off the main thread.
    func seek(to frame: Int) {
        let clamped = min(max(0, frame), max(0, frameCount - 1))
        let wasPlaying = isPlaying
        pause()
        currentFrame = clamped
        showFrame(clamped)
        if wasPlaying {
            play()
        }
    }

    private func showFrame(_ index: Int) {
        let clip = clip
        let generation = playGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let buffer = clip.copyFrame(at: index) else { return }
            guard let self else { return }
            let live = await MainActor.run { self.playGeneration == generation }
            guard live else { return }
            self.present(buffer)
            let data = ScopeAnalyzer.analyze(buffer) // off-main, like the loop
            let boxed = UncheckedSendable(buffer)
            await MainActor.run {
                self.lastBuffer = boxed.value
                if self.scopesEnabled, let data {
                    self.onScopeData?(data)
                }
            }
        }
    }
}

// MARK: - readouts

extension RawPlayerModel {
    /// Seconds view of the range (shared transport UI).
    var inPoint: Double? { inFrame.map { Double($0) / max(1, frameRate) } }
    var outPoint: Double? { outFrame.map { Double($0) / max(1, frameRate) } }

    private static func parseTimecode(_ text: String?, fps: Int) -> Timecode? {
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
