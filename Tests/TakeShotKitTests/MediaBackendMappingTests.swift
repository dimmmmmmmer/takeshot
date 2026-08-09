import CDeckLink
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// The boundary where the DeckLink bridge's plain values become domain types.
///
/// This is the only part of the adapter a test may touch: the discovery
/// callback is a process-wide singleton and starting a capture adopts whatever
/// board is plugged into the machine running the suite, so the adapter is built
/// with `watchesDevices: false` and never started. The delegate methods are
/// pure mapping and they are where an on-set bug hides — a timecode folded with
/// the wrong fps, a fractional rate not flagged as potential drop-frame, or a
/// VANC payload that loses its DID all reach the take without anything looking
/// broken until the footage is in the edit.
@Suite struct MediaBackendMappingTests {
    /// An adapter that watches nothing and has never been started, its bridge
    /// stand-in, and what it forwarded.
    private func makeRig() -> BridgeRig {
        let adapter = DeckLinkBackendAdapter(watchesDevices: false)
        let recorder = BridgeRecorder()
        adapter.delegate = recorder
        return BridgeRig(adapter: adapter, capture: CDLCapture(),
                         recorder: recorder)
    }

    private func videoFormat(width: Int, height: Int, frameRate: Double,
                             timecodeFPS: Int32, name: String,
                             rgb: Bool = false, bitDepth: Int32 = 8,
                             sourceBitDepth: Int32 = 0) -> CDLVideoFormat {
        let format = CDLVideoFormat()
        format.width = width
        format.height = height
        format.frameRate = frameRate
        format.timecodeFPS = timecodeFPS
        format.modeName = name
        format.isRGB444 = rgb
        format.bitDepth = bitDepth
        format.sourceBitDepth = sourceBitDepth
        return format
    }

    /// Both depths cross the bridge, and the bridge's 0 becomes nil.
    ///
    /// The zero is what the bridge says when the signal did not describe itself
    /// — a forced input mode fires no detection callback, and a DeckLink header
    /// set older than the depth flags cannot read one. Letting it through as the
    /// number 0 would put a depth nobody has ever seen into the shortfall
    /// arithmetic; letting it through as 8 would invent an answer.
    @Test func bothBitDepthsCrossTheBridgeAndZeroBecomesUnknown() throws {
        let rig = makeRig()
        let (adapter, capture, recorder) = (rig.adapter, rig.capture, rig.recorder)
        adapter.capture(capture, didDetect: videoFormat(
            width: 3840, height: 2160, frameRate: 25, timecodeFPS: 25,
            name: "2160p25", rgb: true, bitDepth: 10, sourceBitDepth: 12))
        adapter.capture(capture, didDetect: videoFormat(
            width: 1920, height: 1080, frameRate: 25, timecodeFPS: 25,
            name: "1080p25", rgb: true, bitDepth: 10, sourceBitDepth: 0))
        let formats: [CaptureFormat] = recorder.snapshot.formats
        #expect(formats.count == 2)
        let followed: CaptureFormat = try #require(formats.first)
        #expect(followed.sourceBitDepth == 12, "the signal's depth was dropped")
        #expect(followed.bitDepth == 10, "the enabled depth was dropped")
        #expect(followed.capturableBitDepth == 12)
        let quiet: CaptureFormat = try #require(formats.last)
        #expect(quiet.sourceBitDepth == nil, "0 was passed on as a real depth")
        #expect(quiet.capturableBitDepth == nil)
    }

    /// 29.97 and 59.94 are flagged as POSSIBLY drop-frame; the real flag comes
    /// with each frame's timecode. Getting this wrong makes the file's timecode
    /// track count in a numbering the camera never used.
    @Test func aFractionalRateIsFlaggedAsPotentialDropFrame() throws {
        let rig = makeRig()
        let (adapter, capture, recorder) = (rig.adapter, rig.capture, rig.recorder)

        adapter.capture(capture, didDetect: videoFormat(
            width: 1920, height: 1080, frameRate: 30_000.0 / 1001.0,
            timecodeFPS: 30, name: "1080p29.97"))
        adapter.capture(capture, didDetect: videoFormat(
            width: 1920, height: 1080, frameRate: 25, timecodeFPS: 25,
            name: "1080p25", rgb: true))

        let formats = recorder.snapshot.formats
        #expect(formats.count == 2)
        let fractional = try #require(formats.first)
        #expect(fractional.isDropFrame)
        #expect(fractional.width == 1920 && fractional.height == 1080)
        #expect(fractional.timecodeFPS == 30)
        #expect(fractional.name == "1080p29.97")
        #expect(!fractional.isRGB444)

        let whole = try #require(formats.last)
        #expect(!whole.isDropFrame, "25 fps is never drop-frame")
        #expect(whole.isRGB444, "the RGB 4:4:4 flag decides the levels expansion")
    }

    /// The bridge does not know the timecode fps, so it hands over components
    /// with fps 0 and the pipeline fills it from the current format. An adapter
    /// that guessed here would silently renumber every take.
    @Test func timecodeComponentsArriveWithTheFPSLeftForThePipeline() throws {
        let rig = makeRig()
        let (adapter, capture, recorder) = (rig.adapter, rig.capture, rig.recorder)
        let picture = MediaFixtures.pixelBuffer(level: 0x40, width: 16, height: 16)

        let frame = CDLCapturedFrame()
        frame.pixelBuffer = picture
        frame.ptsSeconds = 1.5
        frame.hasTimecode = true
        frame.tcHours = 14
        frame.tcMinutes = 22
        frame.tcSeconds = 9
        frame.tcFrames = 17
        frame.tcDropFrame = true
        frame.ancillaryPackets = []
        adapter.capture(capture, didReceiveVideoFrame: frame)

        let delivered = try #require(recorder.snapshot.frames.first)
        let timecode = try #require(delivered.timecode)
        #expect(timecode.hours == 14 && timecode.minutes == 22)
        #expect(timecode.seconds == 9 && timecode.frames == 17)
        #expect(timecode.isDropFrame)
        #expect(timecode.fps == 0, "the adapter must not invent a timecode rate")
        // 240 kHz: divides 24, 25, 30, 48, 50 and 60 exactly, so no rate
        // accumulates rounding on the capture timeline
        #expect(delivered.pts.timescale == 240_000)
        #expect(abs(delivered.pts.seconds - 1.5) < 0.000_01)
    }

    /// No timecode on the wire means no timecode — not 00:00:00:00, which the
    /// detector and the writer would take for a real anchor.
    @Test func aFrameWithoutTimecodeCarriesNone() throws {
        let rig = makeRig()
        let (adapter, capture, recorder) = (rig.adapter, rig.capture, rig.recorder)
        let picture = MediaFixtures.pixelBuffer(level: 0x40, width: 16, height: 16)

        let frame = CDLCapturedFrame()
        frame.pixelBuffer = picture
        frame.ptsSeconds = 0
        frame.hasTimecode = false
        frame.tcHours = 99 // stale components the bridge left behind
        frame.ancillaryPackets = []
        adapter.capture(capture, didReceiveVideoFrame: frame)

        let delivered = try #require(recorder.snapshot.frames.first)
        #expect(delivered.timecode == nil)
        #expect(CVPixelBufferGetWidth(delivered.pixelBuffer) == 16)
    }

    /// VANC packets are what the REC trigger is decoded from, so the DID/SDID
    /// pair and the payload have to survive the crossing intact.
    @Test func ancillaryPacketsKeepTheirIdentifiersAndPayload() throws {
        let rig = makeRig()
        let (adapter, capture, recorder) = (rig.adapter, rig.capture, rig.recorder)
        let picture = MediaFixtures.pixelBuffer(level: 0x40, width: 16, height: 16)

        let packet = CDLAncillaryPacket()
        packet.did = 0x51
        packet.sdid = 0x53
        packet.lineNumber = 9
        packet.data = Data([0x01, 0x02, 0x03])

        let frame = CDLCapturedFrame()
        frame.pixelBuffer = picture
        frame.ptsSeconds = 0
        frame.hasTimecode = false
        frame.ancillaryPackets = [packet]
        adapter.capture(capture, didReceiveVideoFrame: frame)

        let delivered = try #require(recorder.snapshot.frames.first)
        #expect(delivered.ancillaryPackets == [
            AncillaryPacket(did: 0x51, sdid: 0x53, lineNumber: 9,
                            data: [0x01, 0x02, 0x03]),
        ])
    }

    /// Interleaved PCM from the bridge becomes a sample buffer with the channel
    /// count the board actually delivered — the writer's audio track is built
    /// from it, and a mismatch is a take with the wrong number of channels.
    @Test func pcmBytesBecomeASampleBufferOfTheRightShape() throws {
        let rig = makeRig()
        let (adapter, capture, recorder) = (rig.adapter, rig.capture, rig.recorder)
        let channels = 8
        let sampleFrames = 512
        let samples = [Int16](repeating: 1000, count: sampleFrames * channels)

        samples.withUnsafeBytes { raw in
            adapter.capture(capture, didReceiveAudioBytes: raw.baseAddress!,
                            sampleFrames: UInt32(sampleFrames),
                            channelCount: UInt32(channels), ptsSeconds: 2)
        }

        let buffer = try #require(recorder.snapshot.audio.first)
        #expect(CMSampleBufferGetNumSamples(buffer) == sampleFrames)
        let description = try #require(CMSampleBufferGetFormatDescription(buffer))
        let asbd = try #require(
            CMAudioFormatDescriptionGetStreamBasicDescription(description))
        #expect(Int(asbd.pointee.mChannelsPerFrame) == channels)
        #expect(asbd.pointee.mSampleRate == 48_000)
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(buffer).seconds - 2)
                < 0.000_01)
    }

    @Test func signalStateIsForwardedAsIs() {
        let rig = makeRig()
        let (adapter, capture, recorder) = (rig.adapter, rig.capture, rig.recorder)
        adapter.capture(capture, signalPresent: false)
        adapter.capture(capture, signalPresent: true)
        #expect(recorder.snapshot.signals == [false, true])
    }

    /// Callbacks report the ADAPTER, not the bridge object: the controller
    /// compares the reported backend against the one it started.
    @Test func callbacksAreReportedAsTheAdapter() {
        let rig = makeRig()
        let (adapter, capture, recorder) = (rig.adapter, rig.capture, rig.recorder)
        adapter.capture(capture, didDetect: videoFormat(
            width: 1280, height: 720, frameRate: 50, timecodeFPS: 50,
            name: "720p50"))
        #expect(recorder.snapshot.sources == [ObjectIdentifier(adapter)])
    }

    /// The writer needs the channel count before the first packet arrives, so a
    /// take that starts on capture frame 1 still gets an audio track.
    @Test func theAudioChannelCountIsKnownWithoutASignal() {
        let adapter = DeckLinkBackendAdapter(watchesDevices: false)
        #expect(adapter.embeddedAudioChannels == 16)
    }

    /// Stopping a capture that was never started is what a device switch does
    /// on its first pass; it must not fault.
    @Test func stoppingBeforeStartingIsSafe() {
        let adapter = DeckLinkBackendAdapter(watchesDevices: false)
        adapter.stopCapture()
        adapter.stopCapture()
        adapter.forcedMode = ("1080p25", true)
        #expect(adapter.forcedMode?.name == "1080p25")
        #expect(adapter.forcedMode?.rgb == true)
    }
}

/// Records what the adapter forwarded. The real callbacks arrive on the DeckLink
/// thread, so this is lock-guarded exactly like the production delegate.
private final class BridgeRecorder: CaptureBackendDelegate, @unchecked Sendable {
    struct State {
        var formats: [CaptureFormat] = []
        var frames: [CapturedFrame] = []
        var audio: [CMSampleBuffer] = []
        var signals: [Bool] = []
        var sources: [ObjectIdentifier] = []
    }

    private let lock = NSLock()
    private var state = State()

    var snapshot: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func mutate(_ body: (inout State) -> Void) {
        lock.lock()
        body(&state)
        lock.unlock()
    }

    func backend(_ backend: CaptureBackend, didDetectFormat format: CaptureFormat) {
        mutate {
            $0.formats.append(format)
            $0.sources.append(ObjectIdentifier(backend))
        }
    }

    func backend(_ backend: CaptureBackend, didReceive frame: CapturedFrame) {
        mutate {
            $0.frames.append(frame)
            $0.sources.append(ObjectIdentifier(backend))
        }
    }

    func backend(_ backend: CaptureBackend, didReceiveAudio sampleBuffer: CMSampleBuffer) {
        mutate { $0.audio.append(sampleBuffer) }
    }

    func backend(_ backend: CaptureBackend, signalPresent: Bool) {
        mutate { $0.signals.append(signalPresent) }
    }

    func backendDeviceListChanged(_ backend: CaptureBackend) {}
}

/// The adapter under test, the bridge object its callbacks name, and the
/// recorder behind it.
private struct BridgeRig {
    let adapter: DeckLinkBackendAdapter
    let capture: CDLCapture
    let recorder: BridgeRecorder
}
