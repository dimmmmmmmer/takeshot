import Foundation
import Testing

@testable import CaptureCore

@Suite struct LTCDecoderTests {
    /// Biphase-mark LTC generator (the inverse of the decoder under test).
    private func encode(_ timecode: Timecode, fps: Int,
                        sampleRate: Double = 48000,
                        polarity: inout Bool) -> [Int16] {
        var bits = [Bool](repeating: false, count: 80)
        func put(_ value: Int, at low: Int, width: Int) {
            for i in 0..<width {
                bits[low + i] = (value >> i) & 1 == 1
            }
        }
        put(timecode.frames % 10, at: 0, width: 4)
        put(timecode.frames / 10, at: 8, width: 2)
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

    private func appendLevel(_ out: inout [Int16], until end: Double,
                             from position: inout Double, _ high: Bool) {
        let count = Int(end.rounded()) - Int(position.rounded())
        out.append(contentsOf: [Int16](repeating: high ? 12000 : -12000,
                                       count: max(0, count)))
        position = end
    }

    @Test func decodesAContinuousRun() {
        let decoder = LTCDecoder()
        var polarity = false
        var decoded: [Timecode] = []
        for frame in 0..<50 {
            let tc = Timecode(frameNumber: 3600 * 25 + frame, fps: 25)
            let samples = encode(tc, fps: 25, polarity: &polarity)
            samples.withUnsafeBufferPointer { buffer in
                if let result = decoder.process(samples: buffer, fps: 25) {
                    decoded.append(result)
                }
            }
        }
        // a frame completes on the FIRST transition of the next frame, so a
        // finite run decodes n-1 frames (real LTC streams continuously)
        #expect(decoded.count == 49)
        #expect(decoded.first?.description == "01:00:00:00")
        #expect(decoded.last?.description == "01:00:01:23")
    }

    @Test func locksAt24fpsWithoutConfiguration() {
        let decoder = LTCDecoder()
        var polarity = false
        var last: Timecode?
        for frame in 0..<30 {
            let tc = Timecode(frameNumber: 10 * 3600 * 24 + frame, fps: 24)
            let samples = encode(tc, fps: 24, polarity: &polarity)
            samples.withUnsafeBufferPointer { buffer in
                if let result = decoder.process(samples: buffer, fps: 24) {
                    last = result
                }
            }
        }
        #expect(last?.description == "10:00:01:04")
    }

    @Test func garbageAudioDecodesNothing() {
        let decoder = LTCDecoder()
        var noise: [Int16] = []
        var seed: UInt64 = 0x1234_5678
        for _ in 0..<48000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise.append(Int16(truncatingIfNeeded: Int32(seed >> 40)))
        }
        let result = noise.withUnsafeBufferPointer {
            decoder.process(samples: $0, fps: 25)
        }
        #expect(result == nil)
    }
}
