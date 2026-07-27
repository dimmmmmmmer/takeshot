import CoreImage
import Foundation
import QuartzCore
import Testing
@testable import CaptureCore

/// The registry is the one place three producers (capture, playback, RAW) share,
/// and it is reached from the producer queues and the main thread at the same
/// time. These tests pin the contract that keeps a shooting day alive: sinks are
/// held weakly, joining sinks inherit presentation state, and concurrent traffic
/// does not corrupt the table.
///
/// No frames are presented here — a layer without a Metal context short-circuits
/// present/redraw/clearToBlack, so the tests stay headless and CI-safe.
struct PreviewSinkRegistryTests {
    @Test func joiningSinkInheritsTheCurrentLetterbox() {
        let registry = PreviewSinkRegistry()
        registry.setLetterbox(CIColor(red: 0.25, green: 0.5, blue: 0.75))

        let layer = MetalPreviewLayer()
        registry.add(layer)

        #expect(abs(layer.letterboxColor.red - 0.25) < 0.001)
        #expect(abs(layer.letterboxColor.green - 0.5) < 0.001)
        #expect(abs(layer.letterboxColor.blue - 0.75) < 0.001)
    }

    @Test func letterboxChangeReachesEverySink() {
        let registry = PreviewSinkRegistry()
        let first = MetalPreviewLayer()
        let second = MetalPreviewLayer()
        registry.add(first)
        registry.add(second)

        registry.setLetterbox(CIColor(red: 1, green: 0, blue: 0))

        #expect(abs(first.letterboxColor.red - 1) < 0.001)
        #expect(abs(second.letterboxColor.red - 1) < 0.001)
    }

    @Test func removedSinkNoLongerListed() {
        let registry = PreviewSinkRegistry()
        let layer = MetalPreviewLayer()
        registry.add(layer)
        #expect(registry.all().count == 1)

        registry.remove(layer)
        #expect(registry.all().isEmpty)
    }

    /// A view that goes away must not pin its layer through the registry —
    /// every fullscreen window and scope panel mount registers one, so a strong
    /// table would accumulate dead layers for the whole session.
    @Test func sinksAreHeldWeakly() {
        let registry = PreviewSinkRegistry()
        weak var probe: MetalPreviewLayer?
        autoreleasepool {
            let layer = MetalPreviewLayer()
            probe = layer
            registry.add(layer)
            #expect(registry.all().count == 1)
        }
        // a fresh layer is retained by its enclosing CoreAnimation transaction
        // until the transaction commits — flush it, or the check below measures
        // CoreAnimation rather than the registry
        CATransaction.flush()

        #expect(probe == nil, "nothing may outlive the layer's own scope")
        #expect(registry.all().isEmpty,
                "a deallocated layer must drop out of the registry on its own")
    }

    /// Producer queues present while the main thread mounts and unmounts
    /// surfaces; without the lock this corrupts the hash table.
    @Test func concurrentTrafficKeepsTheTableConsistent() {
        let registry = PreviewSinkRegistry()
        let resident = MetalPreviewLayer()
        registry.add(resident)

        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            switch iteration % 4 {
            case 0:
                let layer = MetalPreviewLayer()
                registry.add(layer)
                registry.remove(layer)
            case 1:
                _ = registry.all()
            case 2:
                registry.setLetterbox(CIColor(red: Double(iteration % 10) / 10,
                                              green: 0, blue: 0))
            default:
                var assist = ViewAssist()
                assist.zebraOn = iteration % 8 == 3
                registry.setAssist(assist)
            }
        }

        // the long-lived sink survived the churn and nothing else stayed behind
        #expect(registry.all().contains { $0 === resident })
        #expect(registry.all().count == 1)
    }
}
