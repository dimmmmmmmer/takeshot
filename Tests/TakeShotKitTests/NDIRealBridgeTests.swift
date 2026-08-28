import CNDI
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **The real bridge, executed.**
///
/// Runs only where the NDI SDK headers are — a development machine with the
/// drop, and not CI — which is `SRTLoopbackTests`' gate one bridge along. What
/// it can check without putting anything on the network is the half that
/// silently fails otherwise: that the runtime really loaded, that the AUDIO
/// entry point really resolved out of the dylib that is installed, and that the
/// two availability questions answer independently.
///
/// What it deliberately does NOT do is create a sender. That is an
/// announcement on whatever LAN the machine is on, which on a shoot is the set
/// network — the reason `ControllerHarness` fakes the sender for every
/// controller it builds. The call into `NDIlib_send_send_audio_v3` itself is
/// therefore opt-in; see `NDILiveSenderTests`.
@Suite(.enabled(if: CNDSender.isSDKAvailable(),
                "this build has no NDI SDK headers"))
struct NDIRealBridgeTests {
    /// The audio entry point resolved out of the runtime that is installed.
    ///
    /// This is the claim "the bridge compiles" cannot make: the header this
    /// build compiled against declares `NDIlib_send_send_audio_v3`, and the
    /// dylib that is loaded at runtime is whatever the machine has. A `dlsym`
    /// that came back NULL would leave the picture working and the sound
    /// silently refused, which is exactly the failure that has to be visible.
    @Test func theInstalledRuntimeExportsTheAudioSend() {
        #expect(CNDSender.isAudioAvailable(),
                "the loaded NDI runtime exports no audio send")
        #expect(NDISender.isAudioAvailable)
        #expect(CNDSender.runtimeVersion() != nil,
                "the runtime loaded but reports no version")
    }

    /// Audio availability implies the sender API, and never the other way
    /// round. The asymmetry is the promise: adding sound cannot take the
    /// picture away.
    @Test func soundAvailableImpliesTheSourceIsAvailable() {
        if CNDSender.isAudioAvailable() {
            #expect(CNDSender.isSDKAvailable())
        }
        // …and where the source is available the reason is nil, which is what
        // keeps a settings row from showing a paragraph over a working feed.
        #expect(CNDSender.unavailableReason() == nil)
        #expect(CNDSender.unavailableCode() == nil)
    }
}

/// **The published configuration: the sound is absent and harmless.**
///
/// A downloaded DMG is built with no vendor drops at all, so the stub is the
/// SHIPPED configuration and this is what the NDI sound leg is there. The suite
/// runs where the headers are NOT — CI, and any machine forced to the stub with
/// `-Xcc -DTAKESHOT_FORCE_STUBS=1`, which is the only way this half gets
/// compiled at all on a machine that has the SDK dropped in.
///
/// What has to be true is narrow and it is the same shape the picture's stub
/// tests make: the bridge answers NO rather than half-answering. The Swift
/// above it is still compiled and still correct — `NDIAudioConversionTests`
/// runs in this configuration too, because a value conversion needs no SDK —
/// and it is unreachable, because no sender can be created to hand it to.
@Suite(.enabled(if: !CNDSender.isSDKAvailable(),
                "this machine has the NDI SDK, so the bridge is the real one"))
@MainActor
struct NDIStubAudioTests {
    /// The stub says no to sound, and says it for the same reason it says no to
    /// picture: there is nothing to send on.
    @Test func aStubBuildCarriesNoSound() {
        #expect(CNDSender.isSDKAvailable() == false)
        #expect(CNDSender.isAudioAvailable() == false,
                "a build with no NDI in it claimed it could carry sound")
        #expect(NDISender.isAudioAvailable == false)
        // …and the two answers are consistent. "Audio available" must never be
        // true where no sender can exist, in either build.
        #expect(!CNDSender.isAudioAvailable() || CNDSender.isSDKAvailable())
    }

    /// There is no sender to send on, which is what makes the leg unreachable
    /// rather than merely quiet: `startNDIOutput` never gets past the
    /// structural check, so nothing is ever registered on the pipeline's tap.
    @Test func noSenderMeansNothingOnTheTap() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            // Clearing the harness's fake puts the real (stub) sender back,
            // which is safe in exactly this build and nowhere else.
            controller.mirrors.ndiSenderFactory = nil
            controller.settings.ndi.enabled = true
            try await Task.sleep(for: .milliseconds(300))

            #expect(controller.mirrors.ndi == nil)
            #expect(controller.mirrors.ndiAudio == nil)
            #expect(!controller.pipeline.hasAudioTaps,
                    "a build that cannot send announced a sound leg anyway")
            #expect(controller.mirrors.liveAudioEncoder == nil)
        }
    }

    /// The conversion is still compiled and still right in this build. It needs
    /// no SDK, no sender and no network — the reason it is a static function of
    /// the packet — so "absent" is a claim about the BRIDGE and not about the
    /// arithmetic above it.
    @Test func theConversionStillWorksWithoutAnySDK() throws {
        var cache: CMAudioFormatDescription?
        let packet: CMSampleBuffer = try #require(
            NDIAudioFixtures.signature(frames: 4, channels: 2, cache: &cache))
        let out = try #require(NDIAudioMirror.planarFloat(from: packet))
        #expect(out.channels == 2)
        #expect(out.framesPerChannel == 4)
        #expect(out.planes.count == 8)
    }
}

/// Whether the live-sender suite below may run. Its own type rather than a
/// static on the suite: a `.enabled(if:)` that reads a member of the suite it
/// is attached to is a circular macro expansion.
enum NDILiveGate {
    static var enabled: Bool {
        CNDSender.isSDKAvailable()
            && ProcessInfo.processInfo.environment["TAKESHOT_NDI_LIVE"] != nil
    }
}

/// **The call into the real runtime, opt-in because it ANNOUNCES.**
///
///     TAKESHOT_NDI_LIVE=1 scripts/test.sh --filter NDILiveSender
///
/// Creating a sender puts a source in every NDI receiver's list on the network
/// the machine is on, which on a shoot is the set network — so this cannot be
/// part of a battery that anyone might run there, exactly as
/// `NDIPerformanceTests` cannot be part of one that has to be quick. It is off
/// by default and run deliberately.
///
/// What it proves is the thing a compile cannot: that
/// `NDIlib_send_send_audio_v3` is callable with the frame this file builds —
/// the FLTP FourCC, the plane stride, the synthesized timecode — without the
/// runtime rejecting it or walking off the end of the planes. What it does NOT
/// prove is that a receiver plays the sound, or that it lands in sync with the
/// picture; those need a receiver and a person.
@Suite(.enabled(if: NDILiveGate.enabled,
                "set TAKESHOT_NDI_LIVE=1 — this announces on the network"),
       .serialized)
struct NDILiveSenderTests {
    /// One source, one frame, one packet of sound, then down.
    @Test func theRuntimeTakesAPlanarFloatPacket() throws {
        let name = "TakeShot self-test \(UUID().uuidString.prefix(8))"
        let sender = try CNDSender(name: String(name))
        defer { sender.stop() }

        // The picture first, so a failure in the sound is not confused with a
        // sender that was never usable.
        let frame = try NDIFixtures.displayBuffer(width: 320, height: 180)
        #expect(sender.sendFrame(frame, frameRateN: 25, frameRateD: 1))

        // 40 ms of stereo at 48 kHz, planar, full-scale-ish so nothing is
        // optimised away and any read past the planes is of live memory.
        let frames = 1920
        var planes = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            let value = Float(sin(Double(index) * 2 * .pi * 440 / 48_000))
            planes[index] = value * 0.5
            planes[frames + index] = value * -0.5
        }
        let sent: Bool = planes.withUnsafeBufferPointer { buffer in
            sender.sendAudio(buffer.baseAddress!,
                             framesPerChannel: Int32(frames), channels: 2,
                             sampleRate: 48_000)
        }
        #expect(sent, "the runtime refused a planar float packet")
    }

    /// The shapes the bridge refuses, checked against the REAL runtime so that
    /// "refused" is this code's answer rather than a crash inside NDI.
    @Test func aPacketWithNoShapeIsRefusedRatherThanSent() throws {
        let name = "TakeShot self-test \(UUID().uuidString.prefix(8))"
        let sender = try CNDSender(name: String(name))
        defer { sender.stop() }
        var planes = [Float](repeating: 0, count: 64)
        planes.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            #expect(!sender.sendAudio(base, framesPerChannel: 0, channels: 2,
                                      sampleRate: 48_000))
            #expect(!sender.sendAudio(base, framesPerChannel: 32, channels: 0,
                                      sampleRate: 48_000))
            #expect(!sender.sendAudio(base, framesPerChannel: 32, channels: 2,
                                      sampleRate: 0))
        }
    }

    /// A stopped sender refuses both legs rather than sending into a destroyed
    /// instance — the lifetime rule, against the real runtime.
    @Test func aStoppedSenderRefusesBothLegs() throws {
        let name = "TakeShot self-test \(UUID().uuidString.prefix(8))"
        let sender = try CNDSender(name: String(name))
        sender.stop()
        sender.stop() // idempotent

        let frame = try NDIFixtures.displayBuffer()
        #expect(!sender.sendFrame(frame, frameRateN: 25, frameRateD: 1))
        var planes = [Float](repeating: 0, count: 64)
        planes.withUnsafeMutableBufferPointer { buffer in
            #expect(!sender.sendAudio(buffer.baseAddress!, framesPerChannel: 32,
                                      channels: 2, sampleRate: 48_000))
        }
    }
}
