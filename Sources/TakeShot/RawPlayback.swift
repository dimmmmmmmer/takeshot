import CBraw
import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import QuartzCore

/// A decodable RAW clip: BRAW file, CinemaDNG folder (R3D once its SDK is
/// integrated). Decode is blocking; the player calls it off the main thread.
protocol RawClipSource: Sendable {
    var formatBadge: String { get } // "BRAW" / "DNG" in the transport
    var frameCount: Int { get }
    var frameRate: Double { get }
    var width: Int { get }
    var height: Int { get }
    var startTimecodeText: String? { get }
    func copyFrame(at index: Int) -> CVPixelBuffer?
}

/// Blackmagic RAW via the CBraw bridge.
struct BRAWSource: RawClipSource, @unchecked Sendable {
    let formatBadge = "BRAW"
    private let clip: CBRClip
    let frameCount: Int
    let frameRate: Double
    let width: Int
    let height: Int
    let startTimecodeText: String?

    init(url: URL) throws {
        clip = try CBRClip(path: url.path)
        frameCount = Int(clip.frameCount)
        frameRate = Double(clip.frameRate) > 0 ? Double(clip.frameRate) : 24
        width = Int(clip.width)
        height = Int(clip.height)
        startTimecodeText = clip.startTimecode
    }

    func copyFrame(at index: Int) -> CVPixelBuffer? {
        clip.copyFrame(at: UInt64(index))
    }
}

/// CinemaDNG: a folder of .dng frames, decoded through CIRAWFilter and
/// rendered into Rec.709 code values — the same convention every other
/// surface in the app draws.
struct DNGSequenceSource: RawClipSource, @unchecked Sendable {
    let formatBadge = "DNG"
    // decodes arrive from the play loop AND from seek's detached task — the
    // pool rebuild inside PixelBufferPool is not thread-safe
    private let decodeQueue = DispatchQueue(label: "takeshot.dng.decode")
    private let frames: [URL]
    let frameCount: Int
    let frameRate: Double
    let width: Int
    let height: Int
    let startTimecodeText: String? = nil
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool = PixelBufferPool()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)

    enum DNGError: LocalizedError {
        case empty
        var errorDescription: String? { "No DNG frames in the folder" }
    }

    static func frameURLs(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent.localizedStandardCompare(
                $1.lastPathComponent) == .orderedAscending }
    }

    init(folder: URL) throws {
        frames = Self.frameURLs(in: folder)
        guard !frames.isEmpty else { throw DNGError.empty }
        frameCount = frames.count
        // frame rate from the CinemaDNG tag when present, else 24
        var fps = 24.0
        var size = CGSize(width: 1920, height: 1080)
        if let source = CGImageSourceCreateWithURL(frames[0] as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
               as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                size = CGSize(width: w, height: h)
            }
            if let dng = props[kCGImagePropertyDNGDictionary] as? [CFString: Any],
               let rate = dng["FrameRate" as CFString] as? Double, rate > 0 {
                fps = rate
            }
        }
        frameRate = fps
        width = Int(size.width)
        height = Int(size.height)
    }

    func copyFrame(at index: Int) -> CVPixelBuffer? {
        decodeQueue.sync { decodeFrame(at: index) }
    }

    private func decodeFrame(at index: Int) -> CVPixelBuffer? {
        guard frames.indices.contains(index) else { return nil }
        let url = frames[index]
        var image: CIImage?
        if let filter = CIRAWFilter(imageURL: url) {
            image = filter.outputImage
        }
        if image == nil, // not a camera RAW ImageIO can develop — plain decode
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            image = CIImage(cgImage: cg)
        }
        guard let image else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              let buffer = pool.buffer(width: Int(extent.width),
                                       height: Int(extent.height))
        else { return nil }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        // develop into Rec.709 code values (unmanaged everywhere after this)
        destination.colorSpace = Self.colorSpace
        guard let task = try? context.startTask(
            toRender: image.transformed(by: CGAffineTransform(
                translationX: -extent.minX, y: -extent.minY)),
            to: destination) else { return nil }
        _ = try? task.waitUntilCompleted()
        return buffer
    }
}

/// Player for RAW clips: decodes frames on a background task and presents
/// them to registered MetalPreviewLayer sinks — the same display path as
/// live and AVPlayer playback, so color and geometry match.
@MainActor
final class RawPlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var isLooping = false
    @Published private(set) var currentFrame = 0
    /// Loop range in frames.
    @Published var inFrame: Int?
    @Published var outFrame: Int?

    /// Seconds view of the range (shared transport UI).
    var inPoint: Double? { inFrame.map { Double($0) / max(1, frameRate) } }
    var outPoint: Double? { outFrame.map { Double($0) / max(1, frameRate) } }

    /// Set/clear the in or out point at the playhead (same semantics as the
    /// AVPlayer transport: clicking near an existing point clears it).
    func toggleRangePoint(out: Bool) {
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
    }

    let url: URL
    let frameCount: Int
    let frameRate: Double
    let width: Int
    let height: Int
    let startTimecode: Timecode?
    var formatBadge: String { clip.formatBadge }

    /// Scope data from decoded frames while playing (main queue).
    var onScopeData: ((ScopeData) -> Void)?
    var scopesEnabled = false

    private let clip: RawClipSource
    private var playTask: Task<Void, Never>?
    /// Bumped on every play/pause/seek: a cancelled loop parked in a blocking
    /// decode wakes up later — its writes must not clobber the new session.
    private var playGeneration = 0

    // sinks follow the PlaybackFrameTap pattern: one layer per mount
    private let sinksLock = NSLock()
    private let sinks = NSHashTable<MetalPreviewLayer>.weakObjects()
    private var letterbox = CIColor(red: 0, green: 0, blue: 0)
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
        sinksLock.lock()
        layer.letterboxColor = letterbox
        layer.setAssist(sinkAssist)
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

    private var sinkAssist = ViewAssist()

    func setViewAssist(_ assist: ViewAssist) {
        sinksLock.lock()
        sinkAssist = assist
        let all = sinks.allObjects
        sinksLock.unlock()
        for layer in all { layer.setAssist(assist) }
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
        playGeneration += 1
        let generation = playGeneration
        // restart from the top (or the in point) when play is hit at the end
        let floorFrame = inFrame ?? 0
        let startFrame = currentFrame >= frameCount - 1
            ? floorFrame : max(currentFrame, 0)
        currentFrame = startFrame
        let clip = clip
        let fps = frameRate
        let total = frameCount
        playTask = Task.detached(priority: .userInitiated) { [weak self] in
            let startHost = CACurrentMediaTime()
            var scopeCounter = 0
            var index = startFrame
            while !Task.isCancelled {
                guard let buffer = clip.copyFrame(at: index) else {
                    break
                }
                guard let self else { return }
                // a stale loop (pause/seek happened mid-decode) must not
                // present or touch the transport state
                let state = await MainActor.run {
                    (live: self.playGeneration == generation && self.isPlaying,
                     scopes: self.scopesEnabled)
                }
                guard state.live else { return }
                self.present(buffer)
                scopeCounter += 1
                // analysis stays OFF the MainActor: noisy frames are expensive
                let scopeData = scopeCounter % 6 == 0 && state.scopes
                    ? ScopeAnalyzer.analyze(buffer) : nil
                await MainActor.run {
                    self.lastBuffer = buffer
                    self.currentFrame = index
                    if let scopeData {
                        self.onScopeData?(scopeData)
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
                let outLimit = await MainActor.run { [weak self] in
                    self?.outFrame
                }
                if let outLimit, next > outLimit {
                    let looping = await MainActor.run { [weak self] in
                        self?.isLooping ?? false
                    }
                    if looping {
                        return await MainActor.run { [weak self] in
                            guard let self, self.isPlaying,
                                  self.playGeneration == generation else { return }
                            self.isPlaying = false
                            self.currentFrame = self.inFrame ?? 0
                            self.play()
                        }
                    }
                    break
                }
                if next >= total {
                    let looping = await MainActor.run { [weak self] in
                        self?.isLooping ?? false
                    }
                    if !looping { break }
                    // loop restarts the time base at frame 0
                    return await MainActor.run { [weak self] in
                        guard let self, self.isPlaying,
                              self.playGeneration == generation else { return }
                        self.isPlaying = false
                        self.currentFrame = 0
                        self.play()
                    }
                }
                index = next
            }
            await MainActor.run { [weak self] in
                guard let self, self.playGeneration == generation else { return }
                self.isPlaying = false
            }
        }
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
