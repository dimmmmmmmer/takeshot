import AVFoundation
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **The NDI sound leg does not change what the FILE gets, and that is the
/// claim this file makes in bytes.**
///
/// `AudioTapRecordIdentityTests` is the model and this is the same argument one
/// consumer along. The tap itself is already cleared: it runs after
/// `recordAudio`, on a packet the writer has already been handed, and the
/// take's audio is byte-identical with a consumer on it and with none. What
/// that test cannot say anything about is a consumer that does REAL WORK on the
/// packet it is given — and the NDI leg does: it reads every sample out of the
/// block buffer, scales it and re-lays it out. `PCMAudio.interleavedSamples`
/// COPIES, so that is safe; a version that read the block buffer's pointer in
/// place and wrote through it would not be, and would leave the track exactly
/// the right length while changing every sample in the file.
///
/// So the take is SHOT TWICE, identically, once with a real `NDIAudioMirror` on
/// the tap and once with nothing, and the audio track's samples are compared
/// byte for byte. The take is written LPCM (`TakeWriter.audioSettings`), so
/// those bytes are the samples that were appended.
///
/// **It is shot in TWO channel configurations, and they are different claims.**
///
/// The first is the model's: three channels to the file and two to the wire,
/// off an eight-channel source. Two paths that happened to want the same buffer
/// would make the comparison pass on a design where the leg really did reach
/// the file's packet, so the mask is deliberately one that makes them differ.
///
/// The second is the sharp one and the model does not have it. With a STEREO
/// source and no mask, `PCMAudio.selectChannels` hands the tap back the
/// original buffer — everything is selected, so there is nothing to pack — and
/// the leg is therefore holding the very `CMSampleBuffer` object the writer was
/// handed a line earlier. That is the only configuration in which a leg that
/// wrote through its input could reach the file at all, and it is the one a
/// planted destructive conversion has to be caught by. Measured: the same
/// mutation under the first configuration changes nothing, because the tap's
/// packet there is a buffer of its own.
@Suite(.serialized)
struct NDIAudioRecordIdentityTests {
    /// Channels 3, 4 and 5 of an eight-channel embed: three to the file, and
    /// the first two of them to the wire.
    static let splitMask = (1 << 2) | (1 << 3) | (1 << 4)

    struct Shot {
        var audioBytes: Data
        var fileChannels: Int
        var droppedAudioPackets: Int
        var paddedAudioPackets: Int
        var sentPackets: Int
    }

    /// Three channels to the file, two to the wire, off eight.
    @Test func theRecordedAudioIsByteIdenticalWithTheNDILegOnAndOff()
        async throws {
        let bare: Shot = try await Self.shoot(mirrored: false, channels: 8,
                                              mask: Self.splitMask)
        let mirrored: Shot = try await Self.shoot(mirrored: true, channels: 8,
                                                  mask: Self.splitMask)
        Self.compare(bare: bare, mirrored: mirrored, fileChannels: 3)
    }

    /// **The configuration where the leg holds the writer's own buffer.**
    ///
    /// A stereo source with no mask: the record path writes the packet
    /// untouched and `selectChannels` hands the tap that same object back
    /// rather than packing a copy. So a conversion that read the block buffer
    /// in place and wrote through it would corrupt the file — and only this
    /// configuration can see it.
    @Test func theRecordedAudioSurvivesTheLegHoldingItsOwnBuffer()
        async throws {
        // The mechanism, stated before the outcome: this really is the case
        // where the two paths share one buffer, and not just another mask.
        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.packet([1, 2, 3, 4], channels: 2, cache: &cache))
        var selectCache: CMAudioFormatDescription?
        let selected: CMSampleBuffer = try #require(
            PCMAudio.selectChannels(packet, indices: [0, 1],
                                    formatCache: &selectCache))
        #expect(selected === packet,
                "the tap gets a copy here too — this shot proves nothing extra")

        let bare: Shot = try await Self.shoot(mirrored: false, channels: 2,
                                              mask: nil)
        let mirrored: Shot = try await Self.shoot(mirrored: true, channels: 2,
                                                  mask: nil)
        Self.compare(bare: bare, mirrored: mirrored, fileChannels: 2)
    }

    private static func compare(bare: Shot, mirrored: Shot,
                                fileChannels: Int) {

        // First: the leg really was live in the second run, and it really did
        // convert — or the comparison below is two identical runs of the same
        // code with a different name.
        #expect(bare.sentPackets == 0)
        #expect(mirrored.sentPackets > 0,
                "no packet reached the NDI leg — the comparison proves nothing")

        // Second: nothing about this machine made the two runs differ for a
        // reason that is not the leg. Named rather than folded into the byte
        // comparison so a loaded runner reports itself instead of the code.
        #expect(bare.droppedAudioPackets == 0)
        #expect(mirrored.droppedAudioPackets == 0)
        #expect(bare.paddedAudioPackets == 0)
        #expect(mirrored.paddedAudioPackets == 0)

        // Third: the file's WIDTH is what the mask asked for, in both — the leg
        // did not narrow the track to the two channels it takes.
        #expect(bare.fileChannels == fileChannels)
        #expect(mirrored.fileChannels == fileChannels)

        // And then the bytes — as a first-difference INDEX rather than as
        // `a == b`, for the model's reason: a failed `#expect` on two `Data`
        // values of this size renders both into the failure message, which
        // alone hangs the suite for minutes. The index is also the more useful
        // answer — it says how far into the take the divergence starts.
        #expect(!bare.audioBytes.isEmpty, "no audio in the unmirrored take")
        let sizes = "\(mirrored.audioBytes.count) vs \(bare.audioBytes.count)"
        #expect(mirrored.audioBytes.count == bare.audioBytes.count,
                "the mirrored take holds a different amount of sound: \(sizes)")
        let firstDifference: Int? = zip(mirrored.audioBytes, bare.audioBytes)
            .enumerated().first { $0.element.0 != $0.element.1 }?.offset
        let place = "\(firstDifference ?? -1) of \(bare.audioBytes.count)"
        #expect(firstDifference == nil,
                "the NDI leg changed the file's audio from byte \(place)")
    }

    /// The one settings blob both shots are taken with. Its own function so
    /// `shoot` stays inside the body-length ceiling, and so the two runs cannot
    /// drift apart in a field nobody looked at.
    private static func settings(in root: URL, mask: Int?) -> CaptureSettings {
        var settings = CaptureSettings()
        settings.capture.codec = .proResProxy
        settings.capture.destinationPath = root.path
        settings.capture.startDebounceFrames = 3
        settings.capture.stopDebounceFrames = 5
        settings.capture.detectionMode = .timecodeRun
        settings.audio.audioChannelMask = mask
        return settings
    }

    /// One take, shot the same way both times.
    private static func shoot(mirrored: Bool, channels: Int,
                              mask: Int?) async throws -> Shot {
        let root = MediaFixtures.scratchDirectory("NDIAudioIdentity")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = CapturePipeline(config: .init(
            settings: Self.settings(in: root, mask: mask),
            slate: SlateMetadata(scene: "1"), takeNumber: 1))
        let finished = NDITakeCollector()
        let recStates = NDIRecStateCollector()
        pipeline.onTakeFinished = { finished.append($0) }
        pipeline.onRecStateChanged = { recStates.note($0) }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "test"))

        // The real leg, on the real tap, with a fake SENDER behind it — the
        // network is the only thing faked, so every byte of the conversion runs.
        let sender = FakeNDISender(name: "identity")
        let mirror = NDIAudioMirror(sender: sender)
        if mirrored {
            pipeline.addAudioTap(mirror) { [weak mirror] packet in
                mirror?.offer(packet)
            }
        }
        defer {
            pipeline.removeAudioTap(mirror)
            mirror.stop()
        }

        let frame = MediaFixtures.pixelBuffer(level: 128, width: 320,
                                              height: 180)
        let driver = NDISignalDriver(pipeline: pipeline,
                                     audioChannels: channels)
        let standby = Timecode(hours: 9, minutes: 0, seconds: 0, frames: 0,
                               fps: 25)
        try await driver.pushStalled(standby, count: 6, pixelBuffer: frame)
        let rolled = try await driver.pushRunning(from: standby, count: 40,
                                                  pixelBuffer: frame)
        try await driver.pushStalled(rolled, count: 10, pixelBuffer: frame)

        await NDIWait.until { recStates.last == false }
        await pipeline.finishPendingWrites()
        await NDIWait.until { !finished.isEmpty }
        let take = try #require(finished.first)
        await NDIWait.until { FileManager.default.fileExists(atPath: take.url.path) }
        // The sends are on the mirror's own queue, so the count has to settle
        // before it is read — the same reason every other wait here polls.
        await NDIWait.until { !mirrored || !sender.audio.isEmpty }

        let health = pipeline.health
        return Shot(
            audioBytes: try await NDIAudioFile.rawSamples(of: take.url),
            fileChannels: try await NDIAudioFile.channelCount(of: take.url),
            droppedAudioPackets: health.droppedAudioPacketsTotal,
            paddedAudioPackets: health.paddedAudioPacketsTotal
                + health.gapFilledAudioPacketsTotal,
            sentPackets: sender.audio.count)
    }
}

// MARK: - the fixtures this file needs and TakeShotKitTests did not have

/// Takes that finished, behind a lock: the callback lands off the pipeline's
/// queue and the test reads it from elsewhere.
final class NDITakeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Take] = []
    func append(_ take: Take) { lock.withLock { stored.append(take) } }
    var first: Take? { lock.withLock { stored.first } }
    var isEmpty: Bool { lock.withLock { stored.isEmpty } }
}

/// The REC states the detector went through; only the last one is read.
final class NDIRecStateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func note(_ state: Bool) { lock.withLock { stored = state } }
    var last: Bool? { lock.withLock { stored } }
}

/// Poll for an outcome rather than for a flag or a wall-clock window, which is
/// this suite's rule: anything that depends on encoding and finalizing a file
/// gets an I/O-sized budget, not an interactive one.
enum NDIWait {
    @discardableResult
    static func until(timeout: TimeInterval = 20,
                      _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

/// A deterministic signal: the same frames and the same samples on every run,
/// which is what makes a byte comparison between two takes mean anything.
struct NDISignalDriver {
    let pipeline: CapturePipeline
    let audioChannels: Int

    private final class Counter {
        var frame = 0
        var audioCache: CMAudioFormatDescription?
    }

    private let counter = Counter()

    init(pipeline: CapturePipeline, audioChannels: Int) {
        self.pipeline = pipeline
        self.audioChannels = audioChannels
    }

    /// One frame and its 40 ms of audio at `timecode`, then a real 40 ms wait.
    ///
    /// The samples carry a SIGNATURE — channel and frame index — rather than a
    /// tone or silence: a channel taken from the wrong slot, a mis-interleave
    /// or a packet written twice all leave the track the right length, and only
    /// distinguishable samples make the byte comparison able to see them.
    func push(_ timecode: Timecode, pixelBuffer: CVPixelBuffer) async throws {
        counter.frame += 1
        let index = counter.frame
        pipeline.handleFrame(
            pixelBuffer: pixelBuffer,
            pts: CMTime(value: CMTimeValue(index * 40), timescale: 1000),
            timecode: timecode, vancTrigger: nil)
        let frames = 1920
        var samples = [Int16](repeating: 0, count: frames * audioChannels)
        for frame in 0..<frames {
            for channel in 0..<audioChannels {
                let value = (index &* 7 &+ frame &* 3 &+ channel &* 101) % 30_000
                samples[frame * audioChannels + channel] = Int16(value - 15_000)
            }
        }
        if let audio = samples.withUnsafeBytes({ raw in
            PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!,
                                      sampleFrames: frames,
                                      channelCount: audioChannels,
                                      ptsSeconds: Double(index) * 0.04,
                                      formatCache: &counter.audioCache)
        }) {
            pipeline.handleAudio(audio)
        }
        try await Task.sleep(for: .milliseconds(40))
    }

    /// `count` frames with the timecode standing still (camera in standby).
    func pushStalled(_ timecode: Timecode, count: Int,
                     pixelBuffer: CVPixelBuffer) async throws {
        for _ in 0..<count {
            try await push(timecode, pixelBuffer: pixelBuffer)
        }
    }

    /// `count` frames with the timecode advancing; returns where it ended.
    func pushRunning(from start: Timecode, count: Int,
                     pixelBuffer: CVPixelBuffer) async throws -> Timecode {
        var timecode = start
        for _ in 0..<count {
            timecode = timecode.advanced(by: 1)
            try await push(timecode, pixelBuffer: pixelBuffer)
        }
        return timecode
    }
}

/// What a finished take's audio track really holds.
enum NDIAudioFile {
    /// Every byte of the audio track, in order. The take is LPCM, so these are
    /// the samples that were appended and two identical takes compare equal.
    static func rawSamples(of url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.tracks(ofType: .audio).first
        else { return Data() }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        var out = Data()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                              lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            out.append(UnsafeRawPointer(pointer)
                .assumingMemoryBound(to: UInt8.self), count: length)
        }
        return out
    }

    /// How many channels the file's audio carries, read off a SAMPLE rather
    /// than off the track: a format description crossing out of the nonisolated
    /// scope that loaded it is a crossing the older SDK rejects, and a count is
    /// a value. 0 when there is no audio track at all.
    static func channelCount(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.tracks(ofType: .audio).first
        else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        while let buffer = output.copyNextSampleBuffer() {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                      format)?.pointee else { continue }
            return Int(asbd.mChannelsPerFrame)
        }
        return 0
    }
}
