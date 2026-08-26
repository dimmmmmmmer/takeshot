import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// **The tap does not change what the FILE gets, and that is the claim this
/// whole file exists to make in bytes.**
///
/// Audio reaching a take is what this project protects hardest — the per-take
/// channel-mask latch, the conform, the silence backstop and the pre-roll ring
/// are all about the same deliverable — and the tap is new code on the same
/// packet a moment before it is written. "It runs after `recordAudio` so it
/// cannot" is an argument about statement order, and statement order is exactly
/// the kind of thing a later refactor moves.
///
/// So the take is SHOT TWICE, identically, once with a consumer on the tap and
/// once with none, and the audio track's samples are compared byte for byte.
/// The take is written LPCM (`TakeWriter.audioSettings`), so those bytes are
/// the samples that were appended: a mis-interleave, a channel taken from the
/// wrong slot, a packet written twice or a mask read a moment too late all move
/// them, and every one of those leaves the track the right LENGTH.
///
/// The mask is deliberately one that makes the two paths DIFFERENT: three
/// channels to the file and two to the wire, off an eight-channel source. Two
/// paths that happened to want the same buffer would make the comparison pass
/// on a design where the tap really did reach the file's packet.
struct AudioTapRecordIdentityTests {
    /// Channels 3, 4 and 5 of an eight-channel embed: three to the file, and
    /// the first two of them to the wire.
    static let mask = (1 << 2) | (1 << 3) | (1 << 4)
    static let sourceChannels = 8

    struct Shot {
        var audioBytes: Data
        var fileChannels: Int
        var droppedAudioPackets: Int
        var paddedAudioPackets: Int
        var tappedPackets: Int
    }

    @Test func theRecordedAudioIsByteIdenticalWithTheTapOnAndOff()
        async throws {
        let untapped: Shot = try await Self.shoot(tapped: false)
        let tapped: Shot = try await Self.shoot(tapped: true)

        // First: the tap really was live in the second run, or the comparison
        // below is two identical runs of the same code.
        #expect(untapped.tappedPackets == 0)
        #expect(tapped.tappedPackets > 0,
                "no packet reached the tap — the comparison proves nothing")

        // Second: nothing about this machine made the two runs different for a
        // reason that is not the tap. Named rather than folded into the byte
        // comparison so a loaded runner reports itself instead of the code.
        #expect(untapped.droppedAudioPackets == 0)
        #expect(tapped.droppedAudioPackets == 0)
        #expect(untapped.paddedAudioPackets == 0)
        #expect(tapped.paddedAudioPackets == 0)

        // Third: the file's WIDTH is the mask's three, in both — the tap did
        // not narrow the track to the two channels it takes.
        #expect(untapped.fileChannels == 3)
        #expect(tapped.fileChannels == 3)

        // And then the bytes — as a first-difference INDEX rather than as
        // `a == b`. Both sides are half a megabyte, and a failed `#expect` on
        // two `Data` values of that size renders both of them into the failure
        // message: measured, that alone hangs the suite for minutes. The index
        // is also the more useful answer — it says how far into the take the
        // divergence starts.
        #expect(!untapped.audioBytes.isEmpty, "no audio in the untapped take")
        let sizes = "\(tapped.audioBytes.count) vs \(untapped.audioBytes.count)"
        #expect(tapped.audioBytes.count == untapped.audioBytes.count,
                "the tapped take holds a different amount of sound: \(sizes)")
        let firstDifference: Int? = zip(tapped.audioBytes, untapped.audioBytes)
            .enumerated().first { $0.element.0 != $0.element.1 }?.offset
        let place = "\(firstDifference ?? -1) of \(untapped.audioBytes.count)"
        #expect(firstDifference == nil,
                "the tap changed the file's audio from byte \(place)")
    }

    /// One take, shot the same way both times.
    private static func shoot(tapped: Bool) async throws -> Shot {
        let root = TestMedia.scratchDirectory("AudioTapIdentity")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.capture.codec = .proResProxy
        settings.capture.destinationPath = root.path
        settings.capture.startDebounceFrames = 3
        settings.capture.stopDebounceFrames = 5
        settings.capture.detectionMode = .timecodeRun
        settings.audio.audioChannelMask = mask

        let pipeline = CapturePipeline(config: .init(
            settings: settings, slate: SlateMetadata(scene: "1"), takeNumber: 1))
        let finished = TakeCollector()
        let recStates = EventCollector<Bool>()
        pipeline.onTakeFinished = { finished.append($0) }
        pipeline.onRecStateChanged = { recStates.append($0) }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "test"))

        let taken = TapCollector()
        let owner = NSObject()
        if tapped {
            pipeline.addAudioTap(owner) { taken.take($0) }
        }
        defer { pipeline.removeAudioTap(owner) }

        let frame = TestMedia.pixelBuffer()
        let driver = SignalDriver(pipeline: pipeline, withAudio: true,
                                  audioChannels: sourceChannels,
                                  audioSignature: true)
        let standby = Timecode(hours: 9, minutes: 0, seconds: 0, frames: 0,
                               fps: 25)
        try await driver.pushStalled(standby, count: 6, pixelBuffer: frame)
        let rolled = try await driver.pushRunning(from: standby, count: 40,
                                                  pixelBuffer: frame)
        try await driver.pushStalled(rolled, count: 10, pixelBuffer: frame)

        await TestWait.untilWritten { recStates.last == false }
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { !finished.isEmpty }
        let take = try #require(finished.first)
        await TestWait.fileExists(at: take.url)

        let health = pipeline.health
        return Shot(
            audioBytes: try await TestAudio.rawSamples(of: take.url),
            fileChannels: try await TestAudio.channelCount(of: take.url),
            droppedAudioPackets: health.droppedAudioPacketsTotal,
            paddedAudioPackets: health.paddedAudioPacketsTotal
                + health.gapFilledAudioPacketsTotal,
            tappedPackets: taken.count)
    }

    /// **The two derived packets are different widths off the same source
    /// packet**, which is what the byte comparison above is comparing.
    ///
    /// Checked without a file because it is the mechanism rather than the
    /// outcome: the record path selects three channels through
    /// `trimFormatCache`, the tap selects two through `stereoFormatCache`, and
    /// they are separate caches for the reason `PCMAudio.makeSampleBuffer`
    /// keys its own on the channel count — one description cannot describe two
    /// widths, and the two paths ask for different ones on every single packet.
    @Test func theFilesPacketAndTheWiresAreDifferentWidths() throws {
        var settings = CaptureSettings()
        settings.capture.detectionMode = .vanc
        settings.audio.audioChannelMask = Self.mask
        let pipeline = CapturePipeline(config: .init(
            settings: settings, slate: SlateMetadata(scene: "1"), takeNumber: 1))
        let taken = TapCollector()
        let owner = NSObject()
        pipeline.addAudioTap(owner) { taken.take($0) }
        defer { pipeline.removeAudioTap(owner) }

        try AudioTapFixture.push(3, channels: Self.sourceChannels,
                                 into: pipeline)

        #expect(taken.lastChannelCount == 2)
        let toFile: Int = pipeline.queue.sync {
            pipeline.recordChannelCount(under: pipeline.effectiveAudioChannelMask)
        }
        #expect(toFile == 3, "the file's width is \(toFile), not the mask's 3")
        let caches: (Int, Int) = pipeline.queue.sync {
            (Self.width(of: pipeline.trimFormatCache),
             Self.width(of: pipeline.stereoFormatCache))
        }
        #expect(caches == (3, 2),
                "the two paths are sharing one format description: \(caches)")
    }

    private static func width(of description: CMAudioFormatDescription?) -> Int {
        guard let description,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                  description)?.pointee else { return 0 }
        return Int(asbd.mChannelsPerFrame)
    }
}
