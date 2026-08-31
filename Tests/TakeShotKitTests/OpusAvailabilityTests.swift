import AudioToolbox
import Foundation
import Testing

@testable import TakeShotKit

/// **Can this machine encode Opus at all?**
///
/// WebRTC carries no sound today, and the roadmap gives two reasons: the
/// `m=audio` negotiation and an RFC 7587 packetizer are real work, and it was
/// not known whether AudioToolbox offers an Opus encoder at the app's own
/// deployment floor. The second is answerable without a browser, a set network
/// or a second machine — CI runs `macos-15`, which IS the floor
/// (`Package.swift`), so this prints the answer on every push.
///
/// It asserts nothing about the outcome. Either answer is useful and neither is
/// a failure of this repository: "no encoder" makes Opus a reason not to start,
/// and "an encoder" removes the unknown from a decision that is currently being
/// deferred on it.
@Suite struct OpusAvailabilityTests {
    @Test func whetherAudioToolboxOffersAnOpusEncoder() {
        var source = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var destination = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&source, &destination, &converter)
        defer { if let converter { AudioConverterDispose(converter) } }

        let answer = status == noErr && converter != nil
            ? "YES — AudioToolbox opened an Opus encoder"
            : "NO — AudioConverterNew refused Opus (OSStatus \(status))"
        print("OPUS on \(ProcessInfo.processInfo.operatingSystemVersionString): \(answer)")

        // The one thing that IS asserted: the two halves of the answer agree.
        // A `noErr` with no converter, or a converter with an error, would mean
        // the probe itself is broken — and then the line printed above is not
        // an answer to anything.
        #expect((status == noErr) == (converter != nil),
                "OSStatus \(status) and converter \(converter as Any) disagree")
    }
}
