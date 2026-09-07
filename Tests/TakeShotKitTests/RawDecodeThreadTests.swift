import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **A RAW decode must not hold a thread the machine cannot spare.**
///
/// Every `RawClipSource.copyFrame` blocks — a DNG develop through CoreImage, a
/// BRAW read, an R3D decode — and each also waits behind its own serial queue
/// while an earlier frame finishes. Every caller is inside a `Task`, and a
/// blocking call there holds one of Swift's cooperative pool threads for the
/// whole time. That pool is the width of the machine and does not grow: a
/// scrub that fires four seeks parks four of them, and every other piece of
/// async work waits behind decodes whose results are already stale.
///
/// GCD's global pool DOES grow, which is the property wanted: the thread that
/// waits is one nobody else needs.
struct RawDecodeThreadTests {
    /// A clip that decodes nothing and reports where it was asked.
    private final class WhereAmI: RawClipSource, @unchecked Sendable {
        let formatBadge = "TEST"
        let frameCount = 4
        let frameRate: Double = 24
        let width = 16
        let height = 9
        let startTimecodeText: String? = nil

        private let lock = NSLock()
        private var stored: [String] = []
        var queues: [String] { lock.withLock { stored } }

        func copyFrame(at index: Int) -> CVPixelBuffer? {
            let label = String(cString: __dispatch_queue_get_label(nil))
            lock.withLock { stored.append(label) }
            return nil
        }
    }

    @Test func aDecodeRunsOffTheCooperativePool() async {
        let clip = WhereAmI()
        _ = await clip.frame(at: 0)
        let asked = clip.queues
        #expect(asked.count == 1, "the decode ran \(asked.count) times")
        #expect(asked.first?.contains("cooperative") == false,
                "the decode held a cooperative pool thread: \(asked)")
    }

    /// …and four at once are four threads and not four parked ones, which is
    /// the case a scrub produces. Asserted as "they all finished": a decode
    /// that starved the pool would not.
    @Test func fourSeeksAtOnceAllFinish() async {
        let clip = WhereAmI()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask { _ = await clip.frame(at: index) }
            }
        }
        #expect(clip.queues.count == 4,
                "\(clip.queues.count) of four decodes ran")
        #expect(clip.queues.allSatisfy { !$0.contains("cooperative") },
                "a decode held a cooperative pool thread: \(clip.queues)")
    }
}
