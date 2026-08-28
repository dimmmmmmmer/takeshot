import CNDI
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Fixtures for the NDI sound leg.
enum NDIAudioFixtures {
    /// One 40 ms packet whose every sample is its own (channel, frame) pair,
    /// so a de-interleave that puts a sample in the wrong plane is visible
    /// rather than merely different.
    ///
    /// Channel `c` frame `f` carries `(c + 1) * 1000 + f`, which stays well
    /// inside Int16 for the frame counts used here.
    static func signature(frames: Int = 8, channels: Int = 2,
                          cache: inout CMAudioFormatDescription?)
        -> CMSampleBuffer? {
        var samples = [Int16](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                samples[frame * channels + channel] =
                    Int16((channel + 1) * 1000 + frame)
            }
        }
        return samples.withUnsafeBytes { raw in
            PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!,
                                      sampleFrames: frames,
                                      channelCount: channels, ptsSeconds: 0,
                                      formatCache: &cache)
        }
    }

    /// A packet built from exactly these interleaved samples.
    static func packet(_ samples: [Int16], channels: Int,
                       cache: inout CMAudioFormatDescription?)
        -> CMSampleBuffer? {
        samples.withUnsafeBytes { raw in
            PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!,
                                      sampleFrames: samples.count / channels,
                                      channelCount: channels, ptsSeconds: 0,
                                      formatCache: &cache)
        }
    }
}

/// **The conversion, which is the only real work this leg does.**
///
/// The tap produces interleaved signed 16-bit PCM and
/// `NDIlib_send_send_audio_v3` takes `NDIlib_FourCC_audio_type_FLTP` —
/// de-interleaved 32-bit float. A pure static function, so the arithmetic is
/// testable with no sender, no SDK and no network, exactly as `NDIFrameRate` is.
struct NDIAudioConversionTests {
    /// Every channel in its own contiguous plane, in order, with the frames of
    /// each in the order they arrived.
    ///
    /// Checked against a signature rather than against a tone: a de-interleave
    /// that swapped two channels, or that read down a column instead of across
    /// a row, leaves a tone sounding like a tone.
    @Test func everyChannelLandsInItsOwnPlaneInOrder() throws {
        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.signature(frames: 8, channels: 2, cache: &cache))
        let out = try #require(NDIAudioMirror.planarFloat(from: packet))

        #expect(out.channels == 2)
        #expect(out.framesPerChannel == 8)
        #expect(out.planes.count == 16)
        let scale = Float(1.0 / 32768.0)
        for channel in 0..<2 {
            for frame in 0..<8 {
                let expected = Float((channel + 1) * 1000 + frame) * scale
                let got = out.planes[channel * 8 + frame]
                #expect(got == expected,
                        "channel \(channel) frame \(frame) is \(got)")
            }
        }
    }

    /// The scale is 1/32768 and not 1/32767, which is a decision rather than an
    /// off-by-one: it puts −32768 on exactly −1.0. Dividing by 32767 instead
    /// makes the full-scale NEGATIVE sample come out at −1.00003, i.e. the one
    /// code a limiter is most likely to have parked samples on is the one that
    /// clips.
    @Test func fullScaleSamplesLandInsideTheFloatRange() throws {
        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(NDIAudioFixtures.packet(
            [Int16.min, Int16.max, 0, -1, 1, Int16.min], channels: 2,
            cache: &cache))
        let out = try #require(NDIAudioMirror.planarFloat(from: packet))

        // Left plane: min, 0, 1. Right plane: max, −1, min.
        #expect(out.planes[0] == -1.0)
        #expect(out.planes[1] == 0.0)
        #expect(out.planes[3] == 32_767.0 / 32_768.0)
        #expect(out.planes[3] < 1.0)
        #expect(out.planes.allSatisfy { $0 >= -1.0 && $0 < 1.0 },
                "a sample left the range NDI's float format is defined on")
    }

    /// **One enabled channel travels MONO**, which is the tap's rule reaching
    /// the wire unchanged: an NDI audio frame states its own channel count, so
    /// mono goes out as mono. Faking a second channel would be the app
    /// inventing sound.
    @Test func aMonoPacketStaysMono() throws {
        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.signature(frames: 4, channels: 1, cache: &cache))
        let out = try #require(NDIAudioMirror.planarFloat(from: packet))
        #expect(out.channels == 1)
        #expect(out.framesPerChannel == 4)
        #expect(out.planes.count == 4)
    }

    /// The rate is read off the packet, not assumed. Every buffer `PCMAudio`
    /// builds is 48 kHz today and an NDI frame DECLARES its rate, so a
    /// hard-coded number would be a lie waiting for the day the pipeline's is
    /// not the one written in this file.
    @Test func theRateComesFromThePacket() throws {
        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.signature(cache: &cache))
        let out = try #require(NDIAudioMirror.planarFloat(from: packet))
        #expect(out.sampleRate == 48_000)
    }

    /// Anything that is not interleaved 16-bit PCM is refused rather than
    /// reinterpreted, for `sendFrame:`'s reason one media type along: a float
    /// read of samples that are not there is not quiet sound, it is a read past
    /// the end of the block.
    @Test func aPacketThatIsNotSixteenBitPCMIsRefused() throws {
        let video = try NDIFixtures.displayBuffer()
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 25),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: video,
            formatDescriptionOut: &format)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: video,
            formatDescription: try #require(format), sampleTiming: &timing,
            sampleBufferOut: &buffer)
        #expect(NDIAudioMirror.planarFloat(from: try #require(buffer)) == nil,
                "a video sample buffer was read as sound")
    }
}

/// The sound leg's discipline: its own queue, every packet, and a bound on what
/// a wedged receiver can cost.
struct NDIAudioMirrorTests {
    /// **The send is on the sound's own queue** — not the caller's, which is
    /// the capture queue that owns the file, and not the picture's, which is
    /// the whole point of there being two.
    @Test func theAudioSendRunsOnItsOwnQueue() async throws {
        let sender = FakeNDISender(name: "test")
        let mirror = NDIAudioMirror(sender: sender)
        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.signature(cache: &cache))
        let caller = DispatchQueue(label: "takeshot.test.pretend-capture")
        caller.async { mirror.offer(packet) }
        #expect(await ControllerWait.until { !sender.audio.isEmpty })

        let queues: [String] = sender.audio.map(\.queue)
        #expect(queues.allSatisfy { $0 == NDIAudioMirror.queueLabel },
                "the audio send ran on \(queues)")
        #expect(!queues.contains(NDIVideoMirror.queueLabel),
                "the sound went out on the picture's queue")
        mirror.stop()
    }

    /// **Every packet goes and none is coalesced**, which is where this leg
    /// parts company with the picture's.
    ///
    /// `NDIVideoMirror` keeps only the newest frame, because a monitor wants
    /// fewer frames rather than older ones. Sound has no such freedom: NDI
    /// synthesizes the audio timecode from the samples it is handed, so a
    /// dropped packet is both a hole and a permanent shift of everything after
    /// it against the picture. Six packets offered back to back must arrive as
    /// six, in order.
    @Test func everyPacketGoesInOrder() async throws {
        let sender = FakeNDISender(name: "test")
        let mirror = NDIAudioMirror(sender: sender)
        var cache: CMAudioFormatDescription?
        for index in 0..<6 {
            let packet: CMSampleBuffer = try #require(
                NDIAudioFixtures.packet([Int16(index), Int16(-index)],
                                        channels: 2, cache: &cache))
            mirror.offer(packet)
        }
        #expect(await ControllerWait.until { sender.audio.count == 6 },
                "\(sender.audio.count) of 6 packets arrived — a coalesce")

        let firsts: [Float] = sender.audio.map { $0.planes[0] }
        let scale = Float(1.0 / 32768.0)
        #expect(firsts == (0..<6).map { Float($0) * scale },
                "the packets arrived out of order: \(firsts)")
        mirror.stop()
    }

    /// **Offering costs the capture queue a bounds test and a dispatch, even
    /// while a send is wedged.**
    ///
    /// The tap runs on the pipeline queue, which is the capture queue that owns
    /// the per-frame work and the file. If `offer` waited on anything, a slow
    /// NDI receiver would be holding up the recorder. Measured against the
    /// wedge rather than against a clock the runner owns.
    @Test func offeringDoesNotWaitForASendThatHasParked() async throws {
        let sender = BlockingNDISender(holding: 0, holdingAudio: 1.5)
        let mirror = NDIAudioMirror(sender: sender)
        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.signature(frames: 4, cache: &cache))
        mirror.offer(packet)
        #expect(sender.waitUntilInsideAudioSend(), "the send never started")

        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 { mirror.offer(packet) }
        let elapsed =
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        #expect(elapsed < 0.5,
                "200 offers took \(elapsed)s while one send was parked")
        mirror.stop()
    }

    /// **The backlog is bounded**, which is what keeps "nothing is coalesced"
    /// from meaning "a wedged receiver grows this queue without limit".
    ///
    /// The ceiling is a second of sound. Held inside a send, offers past it are
    /// refused and COUNTED rather than queued — a gap in a monitoring feed, and
    /// only reachable once the receiver has stopped taking sound at all.
    @Test func theBacklogCeilingRefusesRatherThanGrowing() async throws {
        let sender = BlockingNDISender(holding: 0, holdingAudio: 2)
        let mirror = NDIAudioMirror(sender: sender)
        var cache: CMAudioFormatDescription?
        // 4800 frames a packet: eleven fill the 48 000-frame ceiling.
        let samples = [Int16](repeating: 0, count: 4800 * 2)
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.packet(samples, channels: 2, cache: &cache))
        mirror.offer(packet)
        #expect(sender.waitUntilInsideAudioSend(), "the send never started")

        for _ in 0..<40 { mirror.offer(packet) }
        #expect(mirror.droppedPackets > 0,
                "40 packets queued behind a wedged send and none was refused")
        // …and the ones admitted really are bounded by the ceiling rather than
        // by how fast the loop ran.
        #expect(mirror.droppedPackets >= 40 - 11,
                "\(mirror.droppedPackets) refused — the ceiling let too many in")
        mirror.stop()
    }

    /// A stopped mirror admits nothing, and the flag is set SYNCHRONOUSLY: a
    /// switch the operator has just thrown must stop costing the capture queue
    /// before any hop of this object's own has been scheduled.
    @Test func aStoppedMirrorAdmitsNothing() async throws {
        let sender = FakeNDISender(name: "test")
        let mirror = NDIAudioMirror(sender: sender)
        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.signature(cache: &cache))
        mirror.offer(packet)
        #expect(await ControllerWait.until { !sender.audio.isEmpty })

        mirror.stop()
        let before = sender.audio.count
        for _ in 0..<10 { mirror.offer(packet) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(sender.audio.count == before,
                "sound kept going out after the mirror was stopped")
        // …and stopping the SOUND does not take the source off the network:
        // one sender is one source and the picture's mirror ends it.
        #expect(!sender.isStopped,
                "the sound leg tore down a source it did not announce")
    }

    /// **Neither leg can hold the other up**, which is the reason there are two
    /// queues rather than one.
    ///
    /// NDI's video send and audio send are different calls on the same sender
    /// and both block for as long as the receiver makes them. Here the PICTURE
    /// is held inside its send for two seconds and the sound has to keep going
    /// throughout.
    @Test func aParkedPictureSendDoesNotStallTheSound() async throws {
        let sender = BlockingNDISender(holding: 2)
        let video = NDIVideoMirror(sender: sender, framesPerSecond: 1000)
        let audio = NDIAudioMirror(sender: sender)
        video.offer(try NDIFixtures.displayBuffer(), rate: NDIFrameRate(fps: 25))
        #expect(sender.waitUntilInsideSend(), "the picture send never started")

        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.signature(frames: 4, cache: &cache))
        for _ in 0..<5 { audio.offer(packet) }
        #expect(await ControllerWait.until({ sender.audioCount >= 5 },
                                           timeout: .milliseconds(900)),
                "the sound stalled behind a parked picture send")
        video.stop()
        audio.stop()
    }

    /// …and the other direction, which is the one that is new: the SOUND is
    /// held inside its send and the picture has to keep going.
    @Test func aParkedSoundSendDoesNotStallThePicture() async throws {
        let sender = BlockingNDISender(holding: 0, holdingAudio: 2)
        let video = NDIVideoMirror(sender: sender, framesPerSecond: 1000)
        let audio = NDIAudioMirror(sender: sender)
        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.signature(frames: 4, cache: &cache))
        audio.offer(packet)
        #expect(sender.waitUntilInsideAudioSend(), "the sound send never started")

        let frame = try NDIFixtures.displayBuffer()
        for _ in 0..<5 {
            video.offer(frame, rate: NDIFrameRate(fps: 25))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await ControllerWait.until({ sender.count >= 3 },
                                           timeout: .milliseconds(900)),
                "the picture stalled behind a parked sound send")
        video.stop()
        audio.stop()
    }
}

/// The leg from the controller's side: built with the switch, dropped with it,
/// and taking its packets off the tap that already exists.
@Suite @MainActor
struct NDIAudioWiringTests {
    /// The switch announces a source and registers ONE consumer on the
    /// pipeline's stereo tap; turning it off takes both away.
    ///
    /// `hasAudioTaps` is the observable rather than a count of mirrors, because
    /// a tap left registered over a dropped mirror is exactly the leak this
    /// pairs against: it costs the capture queue a mix per packet for nobody.
    @Test func theTapIsRegisteredWithTheSwitchAndGoesWithIt() async throws {
        try await NDIProbe.run { controller, log in
            #expect(!controller.pipeline.hasAudioTaps,
                    "something was already on the tap")
            controller.settings.ndi.enabled = true
            #expect(controller.mirrors.ndiAudio != nil)
            #expect(controller.pipeline.hasAudioTaps,
                    "the NDI source announced no sound")
            #expect(log.all.count == 1, "a second sender was built for the sound")

            controller.settings.ndi.enabled = nil
            #expect(controller.mirrors.ndiAudio == nil)
            #expect(!controller.pipeline.hasAudioTaps,
                    "the tap outlived the NDI source")
        }
    }

    /// **The sound reaches the source, converted, off the pipeline's own
    /// packets** — the end to end of the leg.
    @Test func theStereoTapReachesTheSource() async throws {
        try await NDIProbe.run(live: true) { controller, log in
            controller.settings.ndi.enabled = true
            let sender: FakeNDISender = try #require(log.latest)
            #expect(await ControllerWait.until { !sender.audio.isEmpty },
                    "no sound ever reached the NDI source")

            let packet = try #require(sender.audio.first)
            #expect(packet.sampleRate == 48_000)
            #expect(packet.channels == 2, "the fold is not stereo")
            #expect(packet.framesPerChannel > 0)
            #expect(packet.planes.count
                == packet.framesPerChannel * packet.channels)
            #expect(packet.queue == NDIAudioMirror.queueLabel)
        }
    }

    /// **An NDI source builds no AAC encoder**, which is the difference between
    /// this leg and SRT's stated as something that can fail.
    ///
    /// `LiveAudioEncoder` exists for the transport stream's second elementary
    /// stream. NDI takes PCM and codes it itself, exactly as it takes frames
    /// rather than H.264 — so a controller with NDI on and SRT off must have no
    /// converter at all, and no H.264 session either.
    @Test func theNDILegBuildsNoAACEncoder() async throws {
        try await NDIProbe.run(live: true) { controller, log in
            controller.settings.ndi.enabled = true
            let sender: FakeNDISender = try #require(log.latest)
            #expect(await ControllerWait.until { !sender.audio.isEmpty })
            #expect(controller.mirrors.liveAudioEncoder == nil,
                    "the NDI sound leg built an AAC encoder")
            #expect(controller.mirrors.liveEncoders.isEmpty,
                    "the NDI sound leg built an H.264 session")
        }
    }

    /// **The channels are the tap's, and the tap's are the file's.** An
    /// operator whose live pair is 5-6 gets 5-6 on the wire, not two dead
    /// channels — and the mask that makes that true is read once, in
    /// `stereoChannelIndices`, for the speakers and every transport alike.
    ///
    /// A mask of ONE channel is the sharper half of the same rule: it travels
    /// mono rather than doubled.
    @Test func aSingleEnabledChannelTravelsMono() async throws {
        try await NDIProbe.run(live: true, configure: { settings in
            settings.audio.audioChannelMask = 1 << 1
        }, { controller, log in
            controller.settings.ndi.enabled = true
            let sender: FakeNDISender = try #require(log.latest)
            #expect(await ControllerWait.until { !sender.audio.isEmpty },
                    "no sound reached the source with a one-channel mask")
            let packet = try #require(sender.audio.first)
            #expect(packet.channels == 1,
                    "one enabled channel travelled as \(packet.channels)")
            #expect(packet.planes.count == packet.framesPerChannel)
        })
    }

    /// A name change re-announces the source, and the sound has to MOVE: on to
    /// the new sender, and off the old one.
    ///
    /// Both halves are asserted and the last one is the one that catches the
    /// leak. `startNDIOutput` registers a fresh consumer under a fresh KEY, so
    /// a path that forgot to remove the old leg still delivers sound to the new
    /// source and still answers `hasAudioTaps` — the old mirror is only weakly
    /// held by its closure, so it deallocates and goes quiet on its own. What
    /// does NOT go away is its entry in the pipeline's tap table: a closure
    /// called per packet for the rest of the session, on the queue that owns
    /// the file, that nothing will ever remove. Switching the source off is
    /// what makes that visible — the table has to come back EMPTY, and it only
    /// does if every leg that was registered was also removed.
    @Test func aReannounceMovesTheSoundToTheNewSender() async throws {
        try await NDIProbe.run(live: true) { controller, log in
            controller.settings.ndi.enabled = true
            let first: FakeNDISender = try #require(log.latest)
            #expect(await ControllerWait.until { !first.audio.isEmpty })

            controller.settings.ndi.sourceName = "Client feed"
            #expect(await ControllerWait.until { log.all.count == 2 },
                    "the settled name was never announced")
            let second: FakeNDISender = try #require(log.latest)
            #expect(await ControllerWait.until { !second.audio.isEmpty },
                    "the sound stayed on the source that was taken down")
            #expect(controller.pipeline.hasAudioTaps)

            // …and the old source is finished with. Sampled after the new one
            // has already had sound, so the window being measured is one in
            // which packets are demonstrably still flowing.
            let stale = first.audio.count
            try await Task.sleep(for: .milliseconds(300))
            #expect(first.audio.count == stale,
                    "the old sender kept getting sound after the re-announce")

            // The leak the two assertions above cannot see: switching off has
            // to leave NOTHING on the tap, and it only can if the re-announce
            // removed the leg it replaced.
            controller.settings.ndi.enabled = nil
            #expect(!controller.pipeline.hasAudioTaps,
                    "a re-announce left a leg on the tap that nothing removes")
        }
    }

    /// A sender that could not be created leaves nothing behind at all: no
    /// picture mirror, no sound leg, nothing on the tap.
    @Test func aSenderThatFailedLeavesNothingOnTheTap() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.mirrors.ndiSenderFactory = { _ in
                throw NSError(domain: "test", code: 1)
            }
            controller.settings.ndi.enabled = true
            #expect(controller.mirrors.ndi == nil)
            #expect(controller.mirrors.ndiAudio == nil)
            #expect(!controller.pipeline.hasAudioTaps,
                    "a failed source left its sound leg on the tap")
        }
    }

    /// …and `ndiFailed` itself takes a LIVE leg off, which is the half the test
    /// above cannot reach.
    ///
    /// Its only caller today is the `catch` around the factory, and the factory
    /// throws before the leg is built — so that path always finds nothing to
    /// clean up and would pass with the teardown deleted. Called directly here,
    /// because what this function promises is "no source and no consumers", and
    /// a teardown that drops the picture and leaves the sound is the asymmetry
    /// the first caller that reaches it live would inherit.
    @Test func failingALiveSourceTakesItsSoundLegOff() async throws {
        try await NDIProbe.run { controller, log in
            controller.settings.ndi.enabled = true
            #expect(controller.mirrors.ndiAudio != nil)
            #expect(controller.pipeline.hasAudioTaps)
            #expect(log.all.count == 1)

            controller.ndiFailed("source name already in use")

            #expect(controller.mirrors.ndi == nil)
            #expect(controller.mirrors.ndiAudio == nil)
            #expect(!controller.pipeline.hasAudioTaps,
                    "a failed source left its sound leg on the tap")
            #expect(controller.mirrors.ndiState
                == NDIOutputState.failed("source name already in use"))
        }
    }
}
