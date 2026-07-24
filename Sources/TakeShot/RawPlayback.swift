import CBraw
import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import QuartzCore

/// Player for RAW clips (Blackmagic RAW; DNG sequences plug in later):
/// decodes frames on a background task and presents them to registered
/// MetalPreviewLayer sinks — the same display path as live and AVPlayer
/// playback, so color and geometry match.
@MainActor
final class RawPlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var isLooping = false
    @Published private(set) var currentFrame = 0

    let url: URL
    let frameCount: Int
    let frameRate: Double
    let width: Int
    let height: Int
    let startTimecode: Timecode?

    /// Scope data from decoded frames while playing (main queue).
    var onScopeData: ((ScopeData) -> Void)?
    var scopesEnabled = false

    private let clip: CBRClip
    private var playTask: Task<Void, Never>?

    // sinks follow the PlaybackFrameTap pattern: one layer per mount
    private let sinksLock = NSLock()
    private let sinks = NSHashTable<MetalPreviewLayer>.weakObjects()
    private var letterbox = CIColor(red: 0, green: 0, blue: 0)
    /// Last decoded frame — re-presented to newly registered sinks.
    private var lastBuffer: CVPixelBuffer?

    init?(url: URL, error errorText: inout String?) {
        let clip: CBRClip
        do {
            clip = try CBRClip(path: url.path)
        } catch {
            errorText = error.localizedDescription
            return nil
        }
        self.url = url
        self.clip = clip
        frameCount = Int(clip.frameCount)
        frameRate = Double(clip.frameRate) > 0 ? Double(clip.frameRate) : 24
        width = Int(clip.width)
        height = Int(clip.height)
        // SDK reports "HH:MM:SS:FF" (or ";" before FF for drop-frame)
        startTimecode = Self.parseTimecode(
            clip.startTimecode, fps: Int(Double(clip.frameRate).rounded()))
    }

    deinit {
        playTask?.cancel()
    }

    // MARK: - sinks

    func addSink(_ layer: MetalPreviewLayer) {
        sinksLock.lock()
        layer.letterboxColor = letterbox
        sinks.add(layer)
        sinksLock.unlock()
        if let buffer = lastBuffer {
            layer.present(buffer)
        } else {
            showFrame(currentFrame) // first mount: decode the poster frame
        }
    }

    func removeSink(_ layer: MetalPreviewLayer) {
        sinksLock.lock()
        sinks.remove(layer)
        sinksLock.unlock()
    }

    func setLetterbox(_ color: CIColor) {
        sinksLock.lock()
        letterbox = color
        let all = sinks.allObjects
        sinksLock.unlock()
        for layer in all {
            layer.letterboxColor = color
            layer.redraw()
        }
    }

    nonisolated private func present(_ buffer: CVPixelBuffer) {
        sinksLock.lock()
        let all = sinks.allObjects
        sinksLock.unlock()
        for layer in all {
            layer.present(buffer)
        }
    }

    // MARK: - transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying, frameCount > 0 else { return }
        isPlaying = true
        // restart from the top when play is hit at the end
        let startFrame = currentFrame >= frameCount - 1 ? 0 : currentFrame
        currentFrame = startFrame
        let clip = clip
        let fps = frameRate
        let total = frameCount
        playTask = Task.detached(priority: .userInitiated) { [weak self] in
            let startHost = CACurrentMediaTime()
            var scopeCounter = 0
            var index = startFrame
            while !Task.isCancelled {
                guard let buffer = clip.copyFrame(at: UInt64(index)) else {
                    break
                }
                guard let self else { return }
                self.present(buffer)
                scopeCounter += 1
                let analyze = scopeCounter % 6 == 0
                await MainActor.run {
                    self.lastBuffer = buffer
                    self.currentFrame = index
                    if analyze, self.scopesEnabled,
                       let data = ScopeAnalyzer.analyze(buffer) {
                        self.onScopeData?(data)
                    }
                }
                // real-time mapping: skip frames if decode is slower than fps
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
                if next >= total {
                    let looping = await MainActor.run { [weak self] in
                        self?.isLooping ?? false
                    }
                    if !looping { break }
                    // loop restarts the time base at frame 0
                    return await MainActor.run { [weak self] in
                        guard let self, self.isPlaying else { return }
                        self.isPlaying = false
                        self.currentFrame = 0
                        self.play()
                    }
                }
                index = next
            }
            await MainActor.run { [weak self] in
                self?.isPlaying = false
            }
        }
    }

    func pause() {
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
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let buffer = clip.copyFrame(at: UInt64(index)) else { return }
            guard let self else { return }
            self.present(buffer)
            await MainActor.run {
                self.lastBuffer = buffer
                if self.scopesEnabled, let data = ScopeAnalyzer.analyze(buffer) {
                    self.onScopeData?(data)
                }
            }
        }
    }

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
