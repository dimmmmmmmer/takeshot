import Foundation
import Testing

@testable import CaptureCore

/// **Every wait in the transcode reads the stop flag.**
///
/// The engine checks the cancel at the top of each frame and between items, so
/// a batch normally stops within a frame. The two back-pressure loops — the
/// ones that wait for an `AVAssetWriterInput` to ask for more data — did not,
/// and they are the only places a run can sit indefinitely: an input that stops
/// asking (the classic multi-input `AVAssetWriter` stall) parks the run in a
/// two-millisecond sleep for ever, with the panel already reading "stopping…"
/// and nothing ever ending (owner: "попытка остановить дейлисы в ui так и не
/// стопнула их. ни в мелкой сноске ни в отдельном окне").
///
/// Asserted on the source because the state that reaches it cannot be produced
/// in a unit test: it needs a real `AVAssetWriter` whose input has stopped
/// asking, which is a condition of the encoder rather than of this code.
@Suite struct DailiesCancelReachTests {
    /// **Every file of the transcode, not one.** The picture's wait and the
    /// sound's used to sit in one type; the pump moved to `+Audio` when that
    /// type reached its length ceiling, and a walk pinned to one file went
    /// from finding two waits to finding one — which is the walk quietly
    /// stopping to look at half of what it was written for.
    private static let files = ["DailiesTranscode.swift",
                                "DailiesTranscode+Audio.swift"]

    @Test func everyBackPressureWaitChecksTheCancel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CaptureCore")

        var waits = 0
        for name in Self.files {
            let lines = try String(
                contentsOf: root.appendingPathComponent(name),
                encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains("while !")
                && line.contains("isReadyForMoreMediaData") {
                waits += 1
                // the check is the FIRST thing in the loop, before the status
                // guard and before the sleep: a stop must not have to wait out
                // whatever the writer is doing
                let body = lines[(index + 1)...].prefix(4)
                    .joined(separator: "\n")
                #expect(body.contains("checkCancelled()"), Comment(rawValue:
                    "the wait at \(name):\(index + 1) does not read the "
                        + "stop flag"))
            }
        }
        #expect(waits == 2, """
            \(waits) back-pressure waits found, expected 2 — a new one has \
            appeared or the walk stopped matching, and either way this test \
            is no longer looking at what it was written for
            """)
    }
}
