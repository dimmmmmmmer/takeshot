import AVFoundation
import CoreMedia
import Foundation

@testable import TakeShotKit

// The fake device layer for the USB-audio suites. Everything above
// `AudioInputDeviceProviding` / `AudioCaptureDevice` is the real code under
// test; these two stand in for the hardware so no suite ever enumerates —
// let alone opens — an audio device of the machine running it.

/// A device list the test owns, plus the hot-plug callback CoreAudio would
/// fire. `ControllerHarness` installs an empty one by default, so a controller
/// built for any other suite cannot touch real inputs either.
final class FakeAudioInputProvider: AudioInputDeviceProviding {
    /// The "plugged-in" devices. Mutate, then call `deviceListChanged()`.
    var connected: [FakeAudioCaptureDevice] = []
    private var onChange: (() -> Void)?

    func list() -> [AudioInputDeviceInfo] {
        connected.map {
            AudioInputDeviceInfo(uid: $0.uid, name: $0.name,
                                 channelCount: $0.channelCount)
        }
    }

    func startWatching(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func makeCaptureDevice(uid: String) -> AudioCaptureDevice? {
        connected.first { $0.uid == uid }
    }

    /// What a plug/unplug looks like from above: the list changed callback.
    func deviceListChanged() {
        onChange?()
    }
}

/// A fake USB interface producing known PCM: every sample is `amplitude`, so
/// whether its signal reached a written file is a one-number question. Runs
/// its own 40 ms delivery timer like the real capture session (`automatic`),
/// or is stepped by hand with `pushOnce()` for deterministic conversion tests.
final class FakeAudioCaptureDevice: AudioCaptureDevice, @unchecked Sendable {
    let uid: String
    let name: String
    let channelCount: Int
    let sampleRate: Double
    let amplitude: Int16
    private let automatic: Bool

    // The real devices guard these slots (see the AudioCaptureDevice contract);
    // a double that leaves them bare turns the sanitizer into noise about
    // itself, so it models the contract rather than undercutting it.
    private let lock = NSLock()
    private var storedOnBuffer: ((AVAudioPCMBuffer, CMTime) -> Void)?
    private var storedOnDeviceGone: (() -> Void)?

    var onBuffer: ((AVAudioPCMBuffer, CMTime) -> Void)? {
        get { lock.withLock { storedOnBuffer } }
        set { lock.withLock { storedOnBuffer = newValue } }
    }
    var onDeviceGone: (() -> Void)? {
        get { lock.withLock { storedOnDeviceGone } }
        set { lock.withLock { storedOnDeviceGone = newValue } }
    }

    private let queue = DispatchQueue(label: "takeshot.tests.fake-usb")
    private static let queueKey = DispatchSpecificKey<Void>()
    private let interval: DispatchTimeInterval
    private var timer: DispatchSourceTimer?
    private var framesPushed: Int64 = 0
    private var base: CMTime?
    private var startedFlag = false
    var started: Bool { lock.withLock { startedFlag } }

    init(uid: String = "fake-usb", name: String = "Fake USB Interface",
         channelCount: Int = 2, sampleRate: Double = 48_000,
         amplitude: Int16 = 9000, automatic: Bool = true,
         interval: DispatchTimeInterval = .milliseconds(40)) {
        self.uid = uid
        self.name = name
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.amplitude = amplitude
        self.automatic = automatic
        self.interval = interval
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    func start() throws {
        lock.withLock { startedFlag = true }
        guard automatic else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.push() }
        timer.resume()
        self.timer = timer
    }

    /// Returns with no delivery in flight. `DispatchSourceTimer.cancel()` does
    /// not wait for a handler that is already running, so the drain is what
    /// makes "stopped" true rather than merely requested — the double is held
    /// to a stricter standard than the hardware here on purpose (the real
    /// session spins down asynchronously; a test that cannot tell the
    /// difference cannot assert "nothing arrived after stop").
    func stop() {
        timer?.cancel()
        timer = nil
        lock.withLock { startedFlag = false }
        // re-entrancy: a stop reached from the delivery itself must not
        // deadlock on its own queue
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            queue.sync {}
        }
    }

    /// One 40 ms buffer, synchronously on the caller's thread — the manual
    /// mode for conversion tests (the device contract only asks for serial
    /// delivery, which a single test thread satisfies).
    func pushOnce() {
        push()
    }

    /// Unplugged: delivery stops, then the disconnect callback fires — the
    /// order the real notification arrives in.
    func vanish() {
        stop()
        onDeviceGone?()
    }

    private func push() {
        guard started else { return }
        let frames = AVAudioFrameCount(sampleRate * 0.04)
        // the layout-carrying builder: a plain AVAudioFormat init returns nil
        // past two channels, and USB fakes go up to 32
        guard let format = ExternalAudioSource.int16Format(
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: frames),
              let samples = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = frames
        for index in 0..<Int(frames) * channelCount { samples[index] = amplitude }
        // contiguous host-clock stamps, like a real device's stream
        if base == nil { base = CMClockGetTime(CMClockGetHostTimeClock()) }
        guard let base else { return }
        let pts = CMTimeAdd(base, CMTime(value: framesPushed,
                                         timescale: CMTimeScale(sampleRate)))
        framesPushed += Int64(frames)
        // copy out, then call — never invoke a client closure under the lock
        let deliver = onBuffer
        deliver?(buffer, pts)
    }
}

/// Collects emitted packets behind a lock (delivery may come from the fake's
/// own queue while the test asserts from a concurrency thread).
final class PacketCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CMSampleBuffer] = []

    func append(_ packet: CMSampleBuffer) {
        lock.withLock { stored.append(packet) }
    }

    var all: [CMSampleBuffer] { lock.withLock { stored } }
    var count: Int { lock.withLock { stored.count } }
}

/// Reading a written take's audio back — the file is the only witness that
/// counts for "which source's PCM ended up in the take".
enum TestAudioKit {
    /// Largest |sample| in the file's audio track, decoded as 16-bit PCM.
    static func peakAmplitude(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.tracks(ofType: .audio).first
        else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        var peak = 0
        while let buffer = output.copyNextSampleBuffer() {
            for sample in int16Samples(of: buffer) {
                peak = max(peak, abs(Int(sample)))
            }
        }
        return peak
    }

    /// Where the two tracks sit on the file's timeline — the check that USB
    /// audio (host clock) was anchored to the take's video (stream clock).
    static func trackRanges(
        of url: URL) async throws -> (video: CMTimeRange?, audio: CMTimeRange?) {
        let asset = AVURLAsset(url: url)
        let video = try await asset.tracks(ofType: .video).first?
            .load(.timeRange)
        let audio = try await asset.tracks(ofType: .audio).first?
            .load(.timeRange)
        return (video, audio)
    }

    /// The buffer's payload as Int16 samples (interleaved PCM).
    static func int16Samples(of buffer: CMSampleBuffer) -> [Int16] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
            let pointer, length >= 2 else { return [] }
        return pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) {
            Array(UnsafeBufferPointer(start: $0, count: length / 2))
        }
    }
}
