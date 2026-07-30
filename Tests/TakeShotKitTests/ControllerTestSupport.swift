import AppKit
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

// Shared fixtures for the CaptureController suites.
//
// Three things make the controller hostile to tests and all three are handled
// here, once: it reads and writes the operator's real UserDefaults (record
// folder included); selecting a device in `init` adopts whatever board the
// machine has and starts capturing on it; and the demo source it falls back to
// draws with AppKit off the main thread and plays audible tones.
// `ControllerHarness.run` hands every suite a controller wired to throwaway
// preferences (see InMemoryDefaults), a throwaway record folder and a silent
// synthetic signal, and tears all of it down afterwards.

@MainActor
enum ControllerHarness {
    /// Preferences for the controller under test: in memory, emptied per run.
    private static let scratchDefaults = InMemoryDefaults()

    /// Empty preferences holding exactly `settings`.
    private static func preparedDefaults(
        _ settings: CaptureSettings) throws -> UserDefaults {
        let defaults = scratchDefaults
        defaults.removeAll()
        settings.save(to: defaults)
        try #require(CaptureSettings.loaded(from: defaults).destinationPath
                        == settings.destinationPath,
                     "the scratch preferences did not take the settings")
        return defaults
    }

    /// A controller on a scratch record folder and scratch preferences. `live`
    /// keeps the synthetic signal running (only the capture suite needs it);
    /// everything else stops it immediately so a state test is not racing a
    /// 1080p feed.
    static func run(
        live: Bool = false,
        extraBackends: [(String, CaptureBackend)] = [],
        configure: (inout CaptureSettings) -> Void = { _ in },
        _ body: (CaptureController, URL) async throws -> Void) async throws {
        let id = UUID().uuidString
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-controller-\(id)")
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
        // FileManager's directory enumerator hands back fully resolved paths
        // (/private/var…, where the temp directory reports /var…), so the
        // fixture root is resolved the same way — otherwise no scanned URL
        // ever compares equal to one the test built, and the scan's own
        // "this file is already one of ours" check would be defeated too.
        let root = ControllerFixtures.resolved(scratch)

        var settings = CaptureSettings()
        settings.schemaVersion = CaptureSettings.currentSchemaVersion
        settings.destinationPath = root.path
        settings.codec = .proResProxy // the tests encode in real time
        // The live monitor is on by default in the app, and the demo source
        // generates real sine tones: leaving it on plays them out of the
        // developer's speakers for as long as the suite runs, and opens a real
        // output device that a CI runner may not have. Suites that need the
        // monitor switch itself turn it back on, and none of those run a
        // signal.
        settings.monitorEnabled = false
        configure(&settings)
        let defaults = try Self.preparedDefaults(settings)
        defer {
            // The metadata CSV is written on its own serial queue and creates
            // the record folder as it goes: a write that lands after the
            // scratch folder is deleted puts it straight back.
            CaptureController.takeLogQueue.sync {}
            Self.scratchDefaults.removeAll()
            try? FileManager.default.removeItem(at: root)
        }

        // One backend only: no DeckLink adapter, so the tests neither touch the
        // machine's hardware nor depend on whether any is attached. It stands
        // in for the demo source under the same "mock:" prefix and device ID —
        // see SyntheticSignalBackend for why the real one is not used.
        let controller = CaptureController(
            backends: [("mock", SyntheticSignalBackend())] + extraBackends,
            defaults: defaults)
        // Belt and braces: a controller that did not get the fixture's folder
        // has to fail here rather than quietly work on the operator's.
        try #require(controller.settings.destinationPath == root.path,
                     "the controller adopted a folder that is not the fixture's")
        // belt and braces on the monitor: force the routing call even if the
        // stored setting ever stops reaching it, so the suite stays silent
        controller.monitorOn = false
        controller.audioMonitor.stop()
        defer {
            controller.monitorOn = false
            controller.audioMonitor.stop()
            // The volume and LUT sliders persist on a 400 ms debounce. A task
            // still pending when a test ends would write this controller's
            // whole settings blob into the shared scratch preferences part-way
            // through the next one.
            controller.volumePersistTask?.cancel()
            controller.lutPersistTask?.cancel()
            // the watcher re-creates the record folder when it sees it vanish,
            // so it has to go before the folder does
            controller.folderWatcher?.cancel()
            controller.folderWatcher = nil
            controller.stopCapture()
        }
        if !live { controller.stopCapture() }
        // The kernel folder watcher turns every write into a rescan at an
        // unpredictable moment, and a rescan retires takes it cannot find on
        // disk. Suites drive `scanDestinationFolder()` themselves instead.
        controller.folderWatcher?.cancel()
        controller.folderWatcher = nil
        // init also enqueues one scan of its own, which lands at an
        // unpredictable moment. Bumping the generation is the controller's own
        // way of saying "that scan is stale" — it discards itself instead of
        // retiring takes the body is about to seed.
        controller.libraryGeneration += 1
        try await body(controller, root)
    }
}

@MainActor
enum ControllerWait {
    /// Poll until `condition` holds or the budget runs out. Used for both
    /// directions: an expected change, and the full-budget wait that proves a
    /// change did NOT happen.
    @discardableResult
    static func until(_ condition: () -> Bool,
                      timeout: Duration = .seconds(10)) async -> Bool {
        let steps = max(1, Int(timeout / .milliseconds(50)))
        for _ in 0..<steps where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// For a condition that waits on encoding, finalizing and writing a file.
    /// Those are I/O bound and a loaded machine — a CI runner, or a developer
    /// building in another window — takes far longer than the interactive
    /// budget above. A generous ceiling costs nothing when the condition is
    /// already true, and the alternative is a suite that fails at random.
    @discardableResult
    static func untilWritten(_ condition: () -> Bool) async -> Bool {
        await until(condition, timeout: .seconds(45))
    }
}

/// Stand-in for the demo source: the same device ID, the same 1080p25 format
/// and the same 16-channel embed, feeding blank frames and near-silence.
///
/// `MockCaptureBackend` itself is not used to drive the controller. Writing
/// these suites is what found the crash in it — it burned its timecode badge
/// with AppKit string drawing on its own dispatch queue, which killed the
/// process twice here, and that has since been fixed. What remains is that its
/// audio is real sine tones at full listening level, which the app plays out of
/// the machine's speakers whenever live monitoring is on, and that its picture
/// changes every frame for no benefit to these assertions.
///
/// Nothing the controller suites assert depends on the picture content or the
/// tone; the pipeline, writer and take-list paths are the same either way.
final class SyntheticSignalBackend: CaptureBackend {
    weak var delegate: CaptureBackendDelegate?
    var isAvailable: Bool { true }
    var embeddedAudioChannels: Int { MockCaptureBackend.audioChannels }

    static let format = CaptureFormat(width: 1920, height: 1080, frameRate: 25,
                                      timecodeFPS: 25, name: "Test 1080p25")
    /// Frozen, like the demo camera in standby.
    static let timecode = Timecode(hours: 10, minutes: 0, seconds: 0,
                                   frames: 0, fps: 25)

    private let queue = DispatchQueue(label: "takeshot.tests.synthetic-source")
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frameCounter = 0
    private var audioFormatCache: CMAudioFormatDescription?

    func devices() -> [CaptureDeviceInfo] {
        [CaptureDeviceInfo(id: MockCaptureBackend.deviceID, name: "Test source")]
    }

    func startCapture(deviceID: String) throws {
        stopCapture()
        delegate?.backend(self, didDetectFormat: Self.format)
        delegate?.backend(self, signalPresent: true)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.resume()
        self.timer = timer
    }

    func stopCapture() {
        timer?.cancel()
        timer = nil
    }

    private func emit() {
        frameCounter += 1
        guard let pixelBuffer = nextBuffer() else { return }
        delegate?.backend(self, didReceive: CapturedFrame(
            pixelBuffer: pixelBuffer,
            pts: CMTime(value: CMTimeValue(frameCounter * 40), timescale: 1000),
            timecode: Self.timecode))
        emitAudio()
    }

    private func nextBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Self.format.width,
                kCVPixelBufferHeightKey: Self.format.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                    attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    /// 40 ms of near-silence on 16 channels: the meters see a real level array
    /// and nothing is audible even if a route is opened by mistake.
    private func emitAudio() {
        let channels = MockCaptureBackend.audioChannels
        let sampleFrames = 1920
        let samples = [Int16](repeating: 1, count: sampleFrames * channels)
        let buffer = samples.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return PCMAudio.makeSampleBuffer(
                bytes: base, sampleFrames: sampleFrames,
                channelCount: channels,
                ptsSeconds: Double(frameCounter) * 0.04,
                formatCache: &audioFormatCache)
        }
        if let buffer { delegate?.backend(self, didReceiveAudio: buffer) }
    }
}

/// A backend whose device list the test owns, standing in for a board being
/// plugged in and pulled out. It produces no signal — only the device list and
/// the start/stop bookkeeping matter here.
final class StubCaptureBackend: CaptureBackend {
    weak var delegate: CaptureBackendDelegate?
    var isAvailable: Bool { true }
    var deviceList: [CaptureDeviceInfo] = []
    private(set) var startedDeviceID: String?

    struct NotThere: Error {}

    func devices() -> [CaptureDeviceInfo] { deviceList }

    func startCapture(deviceID: String) throws {
        guard deviceList.contains(where: { $0.id == deviceID }) else {
            throw NotThere()
        }
        startedDeviceID = deviceID
    }

    func stopCapture() { startedDeviceID = nil }
}

/// A counter a pipeline-queue callback can bump.
final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

enum ControllerFixtures {
    /// `URL.resolvingSymlinksInPath()` deliberately leaves /var alone; realpath
    /// does not, and realpath is what the directory enumerator effectively
    /// reports.
    static func resolved(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return url }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    /// Age a file past the scan's three-second "still being written" window.
    static func settle(_ url: URL) throws {
        try setModified(url, .init(timeIntervalSinceNow: -30))
    }

    /// Put a file's modification date wherever the test needs it — including
    /// the future, which is how a write is held open for the scan without
    /// racing a wall-clock window.
    static func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: url.path)
    }

    /// A take that does not need a file behind it — enough for the list, the
    /// rating cycle and the CSV.
    static func take(named name: String, in root: URL, roll: String = "001",
                     clip: Int = 1, recordedAt: Date = Date()) -> Take {
        Take(url: root.appendingPathComponent("\(name).mov"),
             scene: "", roll: roll, takeNumber: clip,
             startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0,
                                     frames: 0, fps: 25),
             durationSeconds: 4, recordedAt: recordedAt)
    }

    /// Back a fixture take with a file, so a folder rescan does not retire it
    /// out from under the test.
    static func placeholder(for take: Take) throws {
        try Data([0x00]).write(to: take.url)
    }

    /// A real, decodable PNG — the still paths in the controller go through
    /// CGImageSource and reject anything that is merely named `.png`.
    @discardableResult
    static func writePNG(at url: URL, side: Int = 16) throws -> URL {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4, bitsPerPixel: 32))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }
}
