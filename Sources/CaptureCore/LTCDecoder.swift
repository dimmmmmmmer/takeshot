import Foundation

/// SMPTE 12M linear timecode (LTC) decoder: PCM audio of a biphase-mark
/// signal → `Timecode`. Used when the camera feeds TC on an audio channel
/// instead of RP188 in the video stream.
///
/// Biphase-mark: the polarity flips at every bit boundary; a "1" bit has an
/// extra flip mid-bit. The decoder classifies intervals between zero
/// crossings against an adaptive half-bit period, so any LTC rate (23.976…30
/// fps, ±speed) locks in automatically.
public final class LTCDecoder {
    /// The last cleanly decoded timecode (sync word matched, fields sane).
    public private(set) var lastTimecode: Timecode?

    private var lastSign = false
    private var samplesSinceTransition = 0.0
    /// Adaptive half-bit period in samples (init for 25 fps @ 48 kHz).
    private var halfPeriod = LTCDecoder.defaultHalfPeriod
    private var pendingHalf = false
    /// 80-bit shift register: bits flow through `sync` (newest 16) into
    /// `data`, so right after a full frame `data` holds bits 0…63 (bit 0 at
    /// the LSB) and `sync` holds the sync word.
    private var data: UInt64 = 0
    private var sync: UInt16 = 0
    /// Sync word bits 64…79 (0011111111111101) pushed LSB-first.
    private static let syncPattern: UInt16 = 0xBFFC
    /// Noise deadband for the zero-crossing detector (16-bit full scale).
    private let deadband: Int16 = 400
    /// The half-bit period the decoder starts from (25 fps @ 48 kHz), and what
    /// `garbageStreak` puts back — see below.
    private static let defaultHalfPeriod = 12.0
    /// Consecutive intervals the classifier could not place. A run of them
    /// means the adaptive period has been dragged somewhere no real LTC rate
    /// lives: a noise burst's one-sample intervals walk `halfPeriod` down
    /// toward 1, where every LEGITIMATE interval then reads as garbage — a
    /// branch that never adapts — so without this the decoder stayed deaf
    /// until something called `reset()`. Thirty-two garbage intervals is a
    /// fifth of one LTC frame: locked signal never produces that many in a
    /// row, and after a burst the period snaps back within a frame.
    private var garbageStreak = 0

    public init() {}

    public func reset() {
        lastTimecode = nil
        pendingHalf = false
        samplesSinceTransition = 0
        data = 0
        sync = 0
        garbageStreak = 0
    }

    /// Feed interleaved-extracted mono samples; returns the newest timecode
    /// completed inside this chunk (also kept in `lastTimecode`).
    @discardableResult
    public func process(samples: UnsafeBufferPointer<Int16>,
                        fps: Int) -> Timecode? {
        var newest: Timecode?
        for sample in samples {
            let sign = sample > deadband ? true
                     : (sample < -deadband ? false : lastSign)
            samplesSinceTransition += 1
            guard sign != lastSign else { continue }
            lastSign = sign
            let interval = samplesSinceTransition
            samplesSinceTransition = 0
            if interval < halfPeriod * 1.5 {
                // half-bit interval: two of them make a "1"
                if pendingHalf {
                    pendingHalf = false
                    push(true)
                    if sync == Self.syncPattern, let tc = decode(fps: fps) {
                        newest = tc
                        lastTimecode = tc
                    }
                } else {
                    pendingHalf = true
                }
                halfPeriod = halfPeriod * 0.95 + interval * 0.05
                garbageStreak = 0
            } else if interval < halfPeriod * 3.5 {
                // full-bit interval: a "0"
                pendingHalf = false // a lone half before a full bit is a slip
                push(false)
                if sync == Self.syncPattern, let tc = decode(fps: fps) {
                    newest = tc
                    lastTimecode = tc
                }
                halfPeriod = halfPeriod * 0.95 + (interval / 2) * 0.05
                garbageStreak = 0
            } else {
                // silence or garbage — drop the phase, keep the period. Unless
                // NOTHING has fitted for a while: then the period itself is
                // what the garbage left behind, and it goes back to default so
                // a clean signal can lock again (see garbageStreak).
                pendingHalf = false
                garbageStreak += 1
                if garbageStreak >= 32 {
                    garbageStreak = 0
                    halfPeriod = Self.defaultHalfPeriod
                }
            }
        }
        return newest
    }

    private func push(_ bit: Bool) {
        let carry = UInt64(sync & 1)
        sync = (sync >> 1) | (bit ? 0x8000 : 0)
        data = (data >> 1) | (carry << 63)
    }

    private func decode(fps: Int) -> Timecode? {
        func field(_ low: Int, _ width: Int) -> Int {
            Int((data >> UInt64(low)) & ((1 << UInt64(width)) - 1))
        }
        let frames = field(0, 4) + 10 * field(8, 2)
        let dropFrame = field(10, 1) == 1
        let seconds = field(16, 4) + 10 * field(24, 3)
        let minutes = field(32, 4) + 10 * field(40, 3)
        let hours = field(48, 4) + 10 * field(56, 2)
        guard hours < 24, minutes < 60, seconds < 60, frames < max(1, fps)
        else { return nil }
        return Timecode(hours: hours, minutes: minutes, seconds: seconds,
                        frames: frames, fps: fps, isDropFrame: dropFrame)
    }
}
