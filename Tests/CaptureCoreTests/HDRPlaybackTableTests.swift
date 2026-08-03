import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// What a recorded HDR take has to go through on the way back out, and the one
/// property it exists for: a take under review looks like the monitor looked
/// while it was recording.
///
/// Measured, not assumed: a ProRes file tagged SMPTE ST 2084 decodes to BGRA
/// with its codes merely video-range expanded. AVFoundation does not tone map
/// on the way out and the PQ tag changes not one pixel it returns, so the app
/// has to do it — see `HDRRecordTests` for the encode half and
/// `PlaybackFrameTap+Levels` for where this table is applied.
struct HDRPlaybackTableTests {
    /// The heart of it: running the decoder's own 8-bit output through the
    /// playback table lands on the same code the LIVE display table put the
    /// same wire code on. Two paths, one picture.
    @Test func playbackLandsWhereTheLiveMonitorDid() throws {
        let live = WireDisplayTable.table(levels: .limited, bits: 10,
                                          transfer: .pq)
        let playback = try #require(
            StudioSwing.playbackTable(wireCodes: false, transfer: .pq))
        for nits in [1.0, 10.0, HDRTransfer.referenceGreyNits, 100.0,
                     HDRTransfer.referenceWhiteNits, 400.0, 1000.0, 4000.0] {
            let wire = Int((64 + HDRTransfer.pqSignal(nits) * 876).rounded())
            let onTheMonitor = Int(live[wire]) >> 2
            // what the decoder hands back for that wire code: the video-range
            // expansion and nothing else (measured — see the type note)
            let decoded = min(255, max(0, Int((Double(wire - 64) * 255 / 876)
                .rounded())))
            let onPlayback = Int(playback[decoded])
            #expect(abs(onTheMonitor - onPlayback) <= 2,
                    "\(nits) cd/m²: monitor \(onTheMonitor) vs playback \(onPlayback)")
        }
    }

    /// An SDR take gets exactly the table it always got, and a plain SDR take
    /// with no levels key gets no table at all — which is every YCbCr take this
    /// app has ever written.
    @Test func sdrPlaybackIsUntouched() {
        #expect(StudioSwing.playbackTable(wireCodes: false, transfer: .sdr)
            == nil)
        #expect(StudioSwing.playbackTable(wireCodes: true, transfer: .sdr)
            == StudioSwing.expansionTable)
    }

    /// An RGB HDR take needs BOTH operations — the studio-swing expansion its
    /// levels key asks for and the tone map its transfer tag asks for — and it
    /// gets them as one table, so the frame is rounded once rather than twice.
    @Test func anRGBHDRTakeComposesBothOperations() throws {
        let both = try #require(
            StudioSwing.playbackTable(wireCodes: true, transfer: .pq))
        let tone = StudioSwing.toneTable(for: .pq)
        for code in 0...255 {
            let expected = tone[Int(StudioSwing.expansionTable[code])]
            #expect(both[code] == expected, "code \(code)")
        }
        // monotonic, like every table in this pipeline
        for code in 1...255 {
            #expect(both[code] >= both[code - 1], "went backwards at \(code)")
        }
    }

    /// The lookup itself works on a real buffer and leaves alpha alone.
    @Test func theLookupRunsOnABuffer() throws {
        let table = try #require(
            StudioSwing.playbackTable(wireCodes: false, transfer: .pq))
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 4,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]]
                                as CFDictionary, &made)
        let buffer = try #require(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<4 {
            for x in 0..<16 {
                let pixel = base + y * stride + x * 4
                pixel[0] = UInt8(x * 16)
                pixel[1] = UInt8(x * 16)
                pixel[2] = UInt8(x * 16)
                pixel[3] = 0x80 // an alpha a level lookup must not touch
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(StudioSwing.map(buffer, into: buffer, table: table))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let row = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        for x in 0..<16 {
            #expect(row[x * 4 + 1] == table[x * 16], "pixel \(x)")
            #expect(row[x * 4 + 3] == 0x80, "alpha was remapped at \(x)")
        }
        // a table of the wrong size is refused rather than read past its end
        #expect(!StudioSwing.map(buffer, into: buffer, table: [0, 1, 2]))
    }
}
