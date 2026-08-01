import Foundation

@testable import CaptureCore

/// Biphase-mark LTC generator — the inverse of `LTCDecoder`, shared by the
/// decoder tests and the parser torture battery so both speak the same wire
/// format. Lives beside the tests: the app never generates LTC.
enum LTCTestSignal {
    /// One 80-bit LTC frame as PCM. `polarity` carries the line level across
    /// frames — biphase-mark flips at every bit boundary, so a stream is only
    /// continuous if consecutive calls share it. `dropFrame` sets bit 10, the
    /// SMPTE 12M drop-frame flag.
    static func encode(_ timecode: Timecode, fps: Int,
                       sampleRate: Double = 48000,
                       dropFrame: Bool = false,
                       polarity: inout Bool) -> [Int16] {
        var bits = [Bool](repeating: false, count: 80)
        func put(_ value: Int, at low: Int, width: Int) {
            for i in 0..<width {
                bits[low + i] = (value >> i) & 1 == 1
            }
        }
        put(timecode.frames % 10, at: 0, width: 4)
        put(timecode.frames / 10, at: 8, width: 2)
        bits[10] = dropFrame
        put(timecode.seconds % 10, at: 16, width: 4)
        put(timecode.seconds / 10, at: 24, width: 3)
        put(timecode.minutes % 10, at: 32, width: 4)
        put(timecode.minutes / 10, at: 40, width: 3)
        put(timecode.hours % 10, at: 48, width: 4)
        put(timecode.hours / 10, at: 56, width: 2)
        // sync word 0011111111111101 (bits 64…79)
        let syncBits = [false, false, true, true, true, true, true, true,
                        true, true, true, true, true, true, false, true]
        for (i, bit) in syncBits.enumerated() {
            bits[64 + i] = bit
        }

        let samplesPerBit = sampleRate / (Double(fps) * 80)
        var out: [Int16] = []
        var position = 0.0
        for bit in bits {
            polarity.toggle() // biphase-mark: always flip at the bit start
            let bitEnd = position + samplesPerBit
            if bit {
                let mid = position + samplesPerBit / 2
                appendLevel(&out, until: mid, from: &position, polarity)
                polarity.toggle() // extra mid-bit flip for a "1"
                appendLevel(&out, until: bitEnd, from: &position, polarity)
            } else {
                appendLevel(&out, until: bitEnd, from: &position, polarity)
            }
        }
        return out
    }

    private static func appendLevel(_ out: inout [Int16], until end: Double,
                                    from position: inout Double, _ high: Bool) {
        let count = Int(end.rounded()) - Int(position.rounded())
        out.append(contentsOf: [Int16](repeating: high ? 12000 : -12000,
                                       count: max(0, count)))
        position = end
    }
}
