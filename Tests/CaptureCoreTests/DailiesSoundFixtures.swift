import Foundation
import Testing

@testable import CaptureCore

/// **Sound fixtures for the dailies suites** — a real Broadcast Wave, written
/// byte by byte.
///
/// Its own file because `DailiesRig` reached its length ceiling, and because
/// this is a different kind of fixture: the picture rig writes through the
/// app's own `TakeWriter`, and there is no writer in this app for a WAV. What
/// a recordist's file looks like is the thing under test, so it is built here
/// rather than by asking AVFoundation for something WAV-shaped.
extension DailiesRig {
    /// A Broadcast Wave on disk, with a real `bext` start and real samples in
    /// it — enough for `AVAssetReader` to open and for the matcher to place.
    ///
    /// A tone rather than silence: a daily whose sound track is all zeroes
    /// looks exactly like a daily whose sound never arrived.
    @discardableResult
    static func writeWave(at url: URL, startSecondsSinceMidnight: Double,
                          seconds: Double = 4,
                          sampleRate: Int = 48_000) throws -> URL {
        let frames = Int(seconds * Double(sampleRate))
        var samples = Data(capacity: frames * 4)
        for frame in 0..<frames {
            let phase = Double(frame) / Double(sampleRate) * 1_000 * 2 * .pi
            let value = Int16(max(-32_000, min(32_000, sin(phase) * 12_000)))
            let bytes = withUnsafeBytes(of: value.littleEndian) { Data($0) }
            samples += bytes  // left
            samples += bytes  // right
        }
        func uint16(_ value: UInt16) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        func uint32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        func chunk(_ id: String, _ payload: Data) -> Data {
            var out = Data(id.utf8) + uint32(UInt32(payload.count)) + payload
            if payload.count % 2 == 1 { out += Data([0]) }
            return out
        }
        var format = Data()
        format += uint16(1) + uint16(2) + uint32(UInt32(sampleRate))
        format += uint32(UInt32(sampleRate * 4)) + uint16(4) + uint16(16)

        let reference = UInt64(startSecondsSinceMidnight * Double(sampleRate))
        var bext = Data(repeating: 0, count: 338)
        bext += uint32(UInt32(reference & 0xFFFF_FFFF))
        bext += uint32(UInt32(reference >> 32))
        bext += Data(repeating: 0, count: 602 - 346)

        var body = chunk("fmt ", format) + chunk("bext", bext)
        body += chunk("data", samples)
        var file = Data("RIFF".utf8) + uint32(UInt32(4 + body.count))
        file += Data("WAVE".utf8) + body
        try file.write(to: url)
        return url
    }
}
