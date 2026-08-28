import AudioToolbox
import Foundation

/// One AudioToolbox AAC-LC encoder, and nothing else.
///
/// Split from `LiveAudioEncoder` for the reason `SRTVideoEncoder` is split from
/// `LiveVideoEncoder`: one of them is the app's pacing, clock and fan-out, and
/// the other is a codec's C API with its callback and its error codes. Keeping
/// the second one this small is also what makes it possible to say what it does
/// NOT do — no queue, no state beyond the converter and its scratch buffer, and
/// exactly one access unit per call.
///
/// **Not thread-safe, and confined rather than locked.** An `AudioConverterRef`
/// is one codec instance; the only thing that ever touches one of these is
/// `LiveAudioEncoder`, on `com.takeshot.audio-encode`, one call at a time.
final class AACConverter {
    /// The codec cannot be built on this machine, with what AudioToolbox said.
    /// Modelled on `SRTStreamError.unavailable` and reported the same way — an
    /// operator cannot fix it by flicking a switch.
    ///
    /// Coded `nil` deliberately: `BridgeUnavailable`'s codes name the states an
    /// SDK BRIDGE can be in, and AudioToolbox is not one — it is in the OS, and
    /// a machine without an AAC encoder has no vendor drop to be missing. So
    /// there is no fact to key words off, and this sentence is shown as it
    /// stands. That is the same fallback an unrecognised bridge code takes.
    static func unavailable(_ status: OSStatus) -> SRTStreamError {
        .unavailable(BridgeUnavailable(
            code: nil,
            english: "AudioToolbox would not open an AAC encoder "
                + "(status \(status)); the SRT stream carries picture only."))
    }

    /// Whether this machine has an AAC-LC encoder at all.
    ///
    /// Its own answer rather than a caught failure, so a suite can be GATED on
    /// it — `SRTVideoEncoder.isSupported` exists for the picture for the same
    /// reason. A test that failed on a machine with no codec would be reporting
    /// the machine rather than the code.
    static var isSupported: Bool {
        (try? AACConverter(channels: 2, bitsPerSecond: 128_000)) != nil
    }

    let channels: Int
    private let converter: AudioConverterRef
    /// The input side of one call, handed to the C callback through
    /// `inUserData`. A class so its identity survives the round trip as an
    /// opaque pointer, and reused across calls so a steady stream costs no
    /// allocation per access unit.
    private let feed: PCMFeed

    init(channels: Int, bitsPerSecond: Int) throws {
        guard channels > 0 else { throw AACConverter.unavailable(-1) }
        self.channels = channels
        feed = PCMFeed(channels: channels,
                       capacity: LiveAudioEncoder.samplesPerAccessUnit * channels)
        var source = AudioStreamBasicDescription(
            mSampleRate: Double(LiveAudioEncoder.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0)
        var destination = AudioStreamBasicDescription(
            mSampleRate: Double(LiveAudioEncoder.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(LiveAudioEncoder.samplesPerAccessUnit),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        var built: AudioConverterRef?
        let status = AudioConverterNew(&source, &destination, &built)
        guard status == noErr, let built else {
            throw AACConverter.unavailable(status)
        }
        converter = built
        // Refused rather than fatal: an encoder that would not take the rate
        // still encodes, at its own default. It is the operator's number
        // quietly not being honoured, which is what the log is for.
        var rate = UInt32(bitsPerSecond)
        AudioConverterSetProperty(built, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &rate)
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// Exactly one access unit's worth of interleaved 16-bit samples in, one
    /// raw AAC access unit out — or nil while the encoder is still filling its
    /// own transform window, which is normal and happens once per stream.
    ///
    /// `samples.count` must be `samplesPerAccessUnit × channels`; the caller
    /// slices to that, so a short block is a programming error rather than a
    /// stream condition and is refused rather than padded.
    func encode(_ samples: [Int16]) -> [UInt8]? {
        guard samples.count == feed.capacity else { return nil }
        feed.load(samples)
        var packets: UInt32 = 1
        var description = AudioStreamPacketDescription()
        var out = [UInt8](repeating: 0, count: Self.outputScratchBytes)
        let status: OSStatus = out.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                      mDataByteSize: UInt32(raw.count),
                                      mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(
                converter, Self.inputProc,
                Unmanaged.passUnretained(feed).toOpaque(),
                &packets, &list, &description)
        }
        guard status == noErr, packets == 1 else { return nil }
        let length = Int(description.mDataByteSize)
        guard length > 0, length <= out.count else { return nil }
        return Array(out[0..<length])
    }

    /// Room for one access unit. AAC-LC's own ceiling is 768 bytes per channel
    /// per unit (13 bits of `frame_length` is the format's, and the codec's own
    /// limit is lower), so this cannot be reached at any bitrate a monitoring
    /// feed uses — it is a bound rather than a budget.
    private static let outputScratchBytes = 768 * 8

    /// The converter's pull callback. Serves the whole block once and then
    /// reports end of input, which is what makes one call one access unit.
    private static let inputProc: AudioConverterComplexInputDataProc
        = { _, packets, ioData, descriptions, context in
            descriptions?.pointee = nil
            guard let context else {
                packets.pointee = 0
                return noErr
            }
            let feed = Unmanaged<PCMFeed>.fromOpaque(context)
                .takeUnretainedValue()
            guard !feed.served else {
                // Zero packets with noErr is AudioToolbox's "no more input":
                // the fill returns what it has rather than failing.
                packets.pointee = 0
                return noErr
            }
            feed.served = true
            packets.pointee = UInt32(feed.capacity / feed.channels)
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = UInt32(feed.channels)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(feed.capacity * 2)
            ioData.pointee.mBuffers.mData =
                UnsafeMutableRawPointer(feed.storage.baseAddress)
            return noErr
        }
}

/// The samples one `encode` call hands the converter, in an allocation that
/// outlives the call.
///
/// A manually managed buffer rather than an `[Int16]`: the callback needs a
/// pointer that is still valid when AudioToolbox reads it, and a Swift array's
/// `withUnsafe…` scope ends at the closure — taking `baseAddress` out of one is
/// exactly the dangling pointer that behaves on the machine you write it on.
private final class PCMFeed {
    let channels: Int
    let capacity: Int
    let storage: UnsafeMutableBufferPointer<Int16>
    var served = false

    init(channels: Int, capacity: Int) {
        self.channels = channels
        self.capacity = capacity
        storage = UnsafeMutableBufferPointer<Int16>.allocate(capacity: capacity)
        storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    func load(_ samples: [Int16]) {
        _ = samples.withUnsafeBufferPointer { source in
            storage.update(fromContentsOf: source)
        }
        served = false
    }
}
