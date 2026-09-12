import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **The crew's picture carries the framing on the playback and RAW arms too**
/// (owner: "на телефоне пусть тоже будет кадрирование").
///
/// `SizingMonitorTests` in CaptureCoreTests holds the live pipeline's half.
/// This is the other two producers of a `LiveFrame`: a browser watching the
/// clean picture follows the operator into playback and into a RAW clip, and a
/// stream that reframed on the live signal and stopped the moment a take was
/// opened would be a picture nobody could read.
///
/// What each of them must NOT do is reach its own measurement side: the
/// playback tap's scopes and its still grab read the composed frame itself,
/// and the RAW player's read its decoded buffer. The reframe is rendered into
/// a buffer of its own and neither is touched.
@Suite @MainActor struct ViewSizingMonitorTests {
    /// Collects the clean picture; the handler fires on the producer's queue.
    private final class Clean: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [CVPixelBuffer] = []
        func record(_ buffer: CVPixelBuffer) {
            lock.withLock { buffers.append(buffer) }
        }
        var last: CVPixelBuffer? { lock.withLock { buffers.last } }
        var count: Int { lock.withLock { buffers.count } }
    }

    /// 64x32, dark left, bright right — a frame a flip is visible in.
    private func sided(left: UInt8 = 40, right: UInt8 = 200) -> CVPixelBuffer {
        let buffer = MediaFixtures.pixelBuffer(level: 0, width: 64, height: 32)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<32 {
                let row = bytes + y * rowBytes
                for x in 0..<64 {
                    let level = x < 32 ? left : right
                    row[x * 4] = level
                    row[x * 4 + 1] = level
                    row[x * 4 + 2] = level
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// The blue channel at `fraction` across the middle row.
    private func level(of buffer: CVPixelBuffer, atFractionX fraction: Double)
        -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x = min(width - 1, max(0, Int(Double(width) * fraction)))
        let row = base.assumingMemoryBound(to: UInt8.self) + (height / 2) * rowBytes
        return Int(row[x * 4])
    }

    private func flipped() -> ViewAssist {
        var assist = ViewAssist()
        assist.flipH = true
        return assist
    }

    // MARK: - the playback tap

    /// A take under review reaches the crew's picture framed, and the scopes
    /// and the still grab keep reading the clip.
    @Test func theFramingReachesThePlaybackTapsCleanPicture() {
        let tap = PlaybackFrameTap()
        let clean = Clean()
        tap.setOnDisplayFrame { clean.record($0[.clean]) }
        tap.setMirrorsTakeCleanPicture(true)   // a browser is watching it
        defer { tap.setOnDisplayFrame(nil) }
        tap.setViewAssist(flipped())
        let source = sided()
        tap.attachStill(source)
        tap.queue.sync {}

        #expect(clean.count > 0, "the tap delivered nothing")
        let shown = clean.last
        #expect(shown !== source, "the clean picture was not framed")
        #expect(shown.map { level(of: $0, atFractionX: 0.1) } ?? 0 > 150,
                "the flip never reached the clean picture")
        // …and what the still grab and the scopes read is the clip itself
        #expect(tap.currentBuffer() === source,
                "the reframe reached the buffer a still is taken from")
    }

    /// With only a punch-in set there is nothing settled to apply, so the tap
    /// hands over the very buffer it took in — no pool, no CoreImage pass.
    @Test func aPunchInCostsThePlaybackCleanPictureNothing() {
        let tap = PlaybackFrameTap()
        let clean = Clean()
        tap.setOnDisplayFrame { clean.record($0[.clean]) }
        tap.setMirrorsTakeCleanPicture(true)
        defer { tap.setOnDisplayFrame(nil) }
        var punched = ViewAssist()
        punched.setPunchIn(4)
        tap.setViewAssist(punched)
        let source = sided()
        tap.attachStill(source)
        tap.queue.sync {}

        #expect(clean.last === source,
                "a punch-in reached the crew's picture, or cost it a render")
    }

    /// **And nobody paying for it pays nothing.** A rig whose only mirror is
    /// a hardware monitor takes `.decorated` and never looks at the clean
    /// picture — the framing pass is a full-raster CoreImage render on the
    /// queue that already runs the keyer and the aids, and it must not be
    /// spent for a buffer nobody reads.
    @Test func aMirrorThatTakesOnlyTheDecoratedPictureCostsNoFramingPass() {
        let tap = PlaybackFrameTap()
        let clean = Clean()
        tap.setOnDisplayFrame { clean.record($0[.clean]) }
        defer { tap.setOnDisplayFrame(nil) }
        tap.setViewAssist(flipped())            // …and no demand declared
        let source = sided()
        tap.attachStill(source)
        tap.queue.sync {}

        #expect(clean.last === source,
                "a framing pass was spent for a picture nobody takes")
    }

    // MARK: - the RAW player

    /// The same on a RAW clip, whose clean picture IS its decoded frame.
    @Test func theFramingReachesTheRawPlayersCleanPicture() async throws {
        let root = MediaFixtures.scratchDirectory("RawSizingMonitor")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try RawClipFixtures.player(frames: 8, in: root)
        let clean = Clean()
        model.setOnDisplayFrame { clean.record($0[.clean]) }
        model.setMirrorsTakeCleanPicture(true)
        model.setViewAssist(flipped())
        model.seek(to: 2)
        #expect(await ControllerWait.untilWritten { clean.count > 0 },
                "no frame reached the model")
        model.settlePresents()

        let decoded = try #require(model.lastBuffer)
        let tile = try #require(clean.last)
        #expect(tile !== decoded, "the RAW clean picture was not framed")
        // …and the buffer a RAW still is taken from is the decoded one
        #expect(model.currentBuffer() === decoded,
                "the reframe reached the buffer a RAW still is taken from")
    }
}
