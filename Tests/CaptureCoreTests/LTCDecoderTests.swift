import Foundation
import Testing

@testable import CaptureCore

@Suite struct LTCDecoderTests {
    /// The generator lives in `LTCTestSignal`, shared with the torture battery.
    private func encode(_ timecode: Timecode, fps: Int,
                        dropFrame: Bool = false,
                        polarity: inout Bool) -> [Int16] {
        LTCTestSignal.encode(timecode, fps: fps, dropFrame: dropFrame,
                             polarity: &polarity)
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

    /// 30 fps LTC is 20 % faster than the 25 fps period the decoder starts
    /// from — the adaptive half-bit period has to walk down and lock, because
    /// an NTSC-land camera is the common source of audio timecode.
    @Test func locksAt30fpsWithoutConfiguration() {
        let decoder = LTCDecoder()
        var polarity = false
        var last: Timecode?
        for frame in 0..<30 {
            let tc = Timecode(frameNumber: 16 * 3600 * 30 + frame, fps: 30)
            let samples = encode(tc, fps: 30, polarity: &polarity)
            samples.withUnsafeBufferPointer { buffer in
                if let result = decoder.process(samples: buffer, fps: 30) {
                    last = result
                }
            }
        }
        // a frame completes on the next frame's first transition, so the last
        // decodable frame of a finite run is the second-to-last one
        #expect(last?.description == "16:00:00:28")
    }

    /// Bit 10 is the SMPTE drop-frame flag, and the decoded timecode carries
    /// it — a 29.97 DF source whose flag is dropped labels every take with
    /// timecodes that drift 3.6 s/hour from the camera's.
    @Test func decodesTheDropFrameFlag() {
        let decoder = LTCDecoder()
        var polarity = false
        var last: Timecode?
        for frame in 0..<6 {
            let tc = Timecode(hours: 10, minutes: 10, seconds: 0, frames: frame,
                              fps: 30, isDropFrame: true)
            let samples = encode(tc, fps: 30, dropFrame: true,
                                 polarity: &polarity)
            samples.withUnsafeBufferPointer { buffer in
                if let result = decoder.process(samples: buffer, fps: 30) {
                    last = result
                }
            }
        }
        #expect(last?.isDropFrame == true)
        #expect(last?.description == "10:10:00;04")
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

    /// `reset()` drops the phase, the shift register and the last timecode —
    /// a decoder reused for a new source must not stitch the old source's bits
    /// onto the new one's.
    @Test func resetForgetsTheLastTimecode() {
        let decoder = LTCDecoder()
        var polarity = false
        for frame in 0..<3 {
            let tc = Timecode(frameNumber: 3600 * 25 + frame, fps: 25)
            let samples = encode(tc, fps: 25, polarity: &polarity)
            samples.withUnsafeBufferPointer {
                _ = decoder.process(samples: $0, fps: 25)
            }
        }
        #expect(decoder.lastTimecode != nil)
        decoder.reset()
        #expect(decoder.lastTimecode == nil)
        // and it locks cleanly onto a different stream afterwards
        var relocked: Timecode?
        for frame in 0..<4 {
            let tc = Timecode(frameNumber: 7 * 3600 * 25 + frame, fps: 25)
            let samples = encode(tc, fps: 25, polarity: &polarity)
            samples.withUnsafeBufferPointer {
                if let hit = decoder.process(samples: $0, fps: 25) {
                    relocked = hit
                }
            }
        }
        #expect(relocked?.hours == 7)
    }
}
