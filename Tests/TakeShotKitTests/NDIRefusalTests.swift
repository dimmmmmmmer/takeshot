import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **A refused frame freezes the source, and nothing used to notice.**
///
/// `NDISending.send` returns whether the runtime took the frame, and both
/// mirrors discarded it. A runtime refusing frames leaves the source announced
/// and its connection count intact — so the state stayed `.sending`, the footer
/// lamp stayed green, and the director's monitor sat on the last picture it got.
/// NDI has no other way to see this: there is no link to drop.
@Suite @MainActor struct NDIRefusalTests {
    private func frame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(nil, 32, 18, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &buffer)
        return try #require(buffer)
    }

    @Test func aRunOfRefusedFramesIsReported() async throws {
        let sender = FakeNDISender(name: "refusing")
        sender.acceptsFrames = false
        let reported = RefusalBox()
        let mirror = NDIVideoMirror(sender: sender, framesPerSecond: 1000,
                                    onRefused: { reported.record($0) })
        defer { mirror.stop() }
        let buffer = try frame()

        // Well past the threshold, offered fast enough that the mirror's own
        // pacing is not what is being measured.
        for _ in 0..<(NDIVideoMirror.refusalAlarmThreshold * 3) {
            mirror.offer(buffer, rate: .fallback)
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(reported.all.count == 1, """
            expected exactly one report for one run of refusals, got \
            \(reported.all) — a message per frame is fifty a second
            """)
        #expect(reported.all.first == NDIVideoMirror.refusalAlarmThreshold)
    }

    /// One refusal is a busy send, not a frozen feed.
    @Test func oneRefusalIsNotReported() async throws {
        let sender = FakeNDISender(name: "busy")
        let reported = RefusalBox()
        let mirror = NDIVideoMirror(sender: sender, framesPerSecond: 1000,
                                    onRefused: { reported.record($0) })
        defer { mirror.stop() }
        let buffer = try frame()

        sender.acceptsFrames = false
        mirror.offer(buffer, rate: .fallback)
        try await Task.sleep(for: .milliseconds(20))
        sender.acceptsFrames = true
        for _ in 0..<5 {
            mirror.offer(buffer, rate: .fallback)
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(reported.all.isEmpty, "a single busy send lit the trouble lamp")
    }

    /// And the report turns the lamp amber rather than leaving it green.
    @Test func theReportPutsTheLampInTrouble() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.ndi.enabled = true
            let up = await ControllerWait.until { controller.mirrors.ndi != nil }
            #expect(up, "the NDI source never came up")

            controller.noteNDIRefusing(NDIVideoMirror.refusalAlarmThreshold)

            let link = StreamLink(controller.mirrors.ndiState)
            #expect(link.isEngaged)
            if case .trouble = link {} else {
                Issue.record("""
                    a frozen feed reads as \(link) — the footer lamp is still \
                    telling the operator the picture is going out
                    """)
            }
        }
    }
}

/// Refusal reports as they arrive, off the mirror's queue.
final class RefusalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func record(_ count: Int) { lock.withLock { stored.append(count) } }
    var all: [Int] { lock.withLock { stored } }
}

/// **A B-camera that never started is a loss, not a notice.**
///
/// A channel whose board refuses to start is absent from `extraChannels`, so it
/// is absent from pushConfig, from the grid, from every take and from the log
/// that goes to post. The pipeline reports exactly that loss as
/// `recordingStartFailed` and classifies it `.integrity`; the multicam path
/// reported the identical failure into the five-second toast register instead.
/// An operator setting up B-cam while looking at the slate had no way to learn
/// a board never came up.
@Suite @MainActor struct ControllerChannelStartTests {
    private struct BoardRefused: Error, LocalizedError {
        var errorDescription: String? { "the board is in use by another app" }
    }

    @Test func achannelThatWouldNotStartSticksOnScreen() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.persistentAlert = nil
            controller.lastError = nil

            controller.noteChannelStartFailed(BoardRefused(),
                                              device: "UltraStudio 4K Mini")

            let banner = try #require(controller.persistentAlert, """
                a camera that never came up was announced in the register that \
                clears itself after five seconds
                """)
            #expect(banner.hasPrefix("UltraStudio 4K Mini: "),
                    "the failure did not name the board: \(banner)")
            #expect(controller.lastError == nil,
                    "the same failure was said twice, in two registers")
        }
    }

    /// And it is the same severity the pipeline gives the same event, which is
    /// what keeps the two boards' failures reading alike.
    @Test func itIsTheSameSeverityThePipelineGivesIt() {
        #expect(PipelineAlarm.recordingStartFailed(reason: "x").severity
            == .integrity)
    }
}

/// **A take written without the key it was promised is in the bundle.**
///
/// The pipeline has counted these since the bake shipped, behind a property
/// whose own doc said it was "read from the main actor for the diagnostics
/// bundle" — and the bundle printed only the display-only number beside it. A
/// take the operator believes was keyed comes back with the green screen in it
/// and there was no record of it anywhere.
@Suite struct DiagnosticsChromaTests {
    @Test func theBakeFallbackCountReachesTheReport() {
        var health = PipelineHealth()
        health.chromaLateDrops = 3
        health.chromaBakeFallbacks = 7
        health.lutBakeFallbacks = 11
        let text = DiagnosticsStateReport.counters(health).joined(separator: "\n")
        // The look's version of the same claim: a file whose metadata says the
        // LUT is baked and whose frames are clean. It was `?? display` on both
        // record paths and recorded nowhere.
        #expect(text.contains("LUT bake fallbacks"), """
            frames written without the look they were promised are counted \
            nowhere a bundle can show them: \(text)
            """)
        #expect(text.contains("11"))
        #expect(text.contains("Chroma bake fallbacks"), """
            frames written to the file without the key are still counted \
            nowhere a diagnostics bundle can show them: \(text)
            """)
        #expect(text.contains("7"))
        // …and it is a DIFFERENT number from the display-only one beside it
        #expect(text.contains("Chroma late drops"))
        #expect(text.contains("3"))
    }
}
