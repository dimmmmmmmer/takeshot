import CaptureCore
import CoreVideo
import Foundation
import Testing
@testable import TakeShotKit

/// The scopes' half of the playback tap: WHICH part of the frame they read, and
/// that the request to re-read it is never lost.
///
/// A suite of its own rather than more of `ModelPlaybackTapTests`: that one is
/// about what the tap hands to the screen, this one drives the analyzer end to
/// end and needs a whole fixture set for it (a ramp frame, a locked collector,
/// a poll — the analysis is asynchronous, unlike everything the render tests
/// assert).
struct ModelPlaybackTapScopeTests {
    /// A left-to-right ramp from 0 to 255: which columns were analyzed is
    /// readable straight off the luma histogram.
    private func ramp(width: Int = 320, height: Int = 180) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        guard let out else { fatalError("could not allocate a test frame") }
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            let rowBytes = CVPixelBufferGetBytesPerRow(out)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes + y * rowBytes
                for x in 0..<width {
                    let value = UInt8(x * 255 / (width - 1))
                    row[x * 4] = value
                    row[x * 4 + 1] = value
                    row[x * 4 + 2] = value
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }

    /// Collects the analyzer's output. It arrives on the main queue while the
    /// test polls from a concurrency worker, so it goes behind a lock.
    private final class ScopeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ScopeData] = []

        var count: Int { lock.withLock { stored.count } }
        var last: ScopeData? { lock.withLock { stored.last } }

        func record(_ data: ScopeData) { lock.withLock { stored.append(data) } }
    }

    /// A tap with scopes on, showing a ramp.
    private func tapShowingARamp() -> (PlaybackFrameTap, ScopeCollector) {
        let tap = PlaybackFrameTap()
        let scopes = ScopeCollector()
        tap.onScopeData = { scopes.record($0) }
        tap.setScopesEnabled(true)
        tap.attachStill(ramp())
        return (tap, scopes)
    }

    /// Wait for a pass to land. The analysis runs on a utility-QoS queue — on
    /// purpose, so it never competes with the render path — and utility work
    /// yields to everything else on the machine, so the budget is generous
    /// rather than interactive. Polling costs nothing when it lands early.
    private func waitForScopeData(_ scopes: ScopeCollector,
                                  beyond count: Int) async -> ScopeData? {
        for _ in 0..<600 where scopes.count <= count {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return scopes.last
    }

    /// Lowest and highest code value with any weight in the luma histogram.
    private func lumaRange(_ data: ScopeData) -> (low: Int, high: Int)? {
        let occupied = data.histY.indices.filter { data.histY[$0] > 0 }
        guard let low = occupied.first, let high = occupied.last else { return nil }
        return (low, high)
    }

    /// Punched in, the scopes over PLAYBACK read the crop on screen — the same
    /// rule the live path follows (`PipelineScopeTests` is the live half, and
    /// `ScopeRegionTests` proves the analyzer itself honours a region).
    ///
    /// Driven end to end through the tap rather than by reading its stored
    /// region back: the region has to reach the analyzer AND the composed frame
    /// has to be the one sampled, and only the delivered data says both.
    @Test func playbackScopesReadTheCropOnScreen() async throws {
        let (tap, scopes) = tapShowingARamp()

        let full = try #require(await waitForScopeData(scopes, beyond: 0),
                                "no scope data for the whole frame")
        let fullRange = try #require(lumaRange(full))
        #expect(fullRange.low <= 2)
        #expect(fullRange.high >= 253)

        // punched in on the right half: the top half of the code range, and
        // nothing at all from the left half of the ramp
        let delivered = scopes.count
        tap.setScopeRegion(ScopeRegion(x: 0.5, y: 0, width: 0.5, height: 1))
        let punched = try #require(await waitForScopeData(scopes, beyond: delivered),
                                   "the moved crop was never analyzed")
        let punchedRange = try #require(lumaRange(punched))
        #expect(punchedRange.low >= 124,
                "the right half started at \(punchedRange.low)")
        #expect(punchedRange.high >= 253)
        #expect(punched.histY[0..<100].reduce(0, +) == 0,
                "the left half of the frame is still being sampled")
    }

    /// The crop the operator settles on is the one most likely to arrive while a
    /// pass is in flight — a pan drag asks for a re-read 60 times a second and a
    /// pass spans several of those ticks. Dropping that request outright left a
    /// paused take's scopes measuring a crop that is no longer on screen, with
    /// no next frame to ever correct it.
    @Test func theLastCropWinsEvenWhenAPassIsInFlight() async throws {
        let (tap, scopes) = tapShowingARamp()

        // a drag's worth of crops, faster than the analyzer can answer: only the
        // last one is on screen when the operator lets go
        for step in 0..<12 {
            tap.setScopeRegion(ScopeRegion(x: Double(step) / 24, y: 0,
                                           width: 0.5, height: 1))
        }
        tap.setScopeRegion(ScopeRegion(x: 0.5, y: 0, width: 0.5, height: 1))

        // the settled crop is the only one whose darkest sample is mid-scale
        var settled: ScopeData?
        for _ in 0..<600 {
            if let data = scopes.last, let range = lumaRange(data), range.low >= 124 {
                settled = data
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let data = try #require(settled, "the scopes never caught up with the crop")
        #expect(data.histY[0..<100].reduce(0, +) == 0)
    }
}
