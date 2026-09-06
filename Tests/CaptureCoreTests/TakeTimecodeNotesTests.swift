import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// **A mid-take timecode re-anchor is in the take's log row.**
///
/// The writer keeps a second tc32 anchor when the camera's timecode starts
/// running after a frozen span; the file is frame-accurate and the only record
/// of the fact was a log line. The row post reads said nothing, and the 33rd
/// anchor — past the track's budget — was dropped without a word either.
struct TakeTimecodeNotesTests {
    @Test func aReanchorIsNamedInTheRowAndTheBudgetOverflowCounted() {
        #expect(CapturePipeline.timecodeNotes(resyncs: 0, dropped: 0).isEmpty)
        let one = CapturePipeline.timecodeNotes(resyncs: 1, dropped: 0)
        #expect(one == ["timecode re-anchored 1 time(s) mid-take"], "\(one)")
        let over = CapturePipeline.timecodeNotes(resyncs: 32, dropped: 2)
        #expect(over.first?.contains("2 more") == true, "\(over)")
    }

    @Test func theThirtyThirdAnchorIsCountedRatherThanLost() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-notes-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = CaptureFormat(width: 320, height: 180, frameRate: 25,
                                   timecodeFPS: 25, name: "test 25")
        let start = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        let writer = try TakeWriter(url: url, format: format,
                                    codec: .proResProxy, startTimecode: start)
        let pixelBuffer = TestMedia.pixelBuffer(width: 320, height: 180)
        // The session has to be OPEN for an anchor to be taken at all, and
        // the writer refuses a frame until it is ready — a discarded Bool
        // here would leave every resync guarded out and the test green on a
        // premise that never held.
        var opened = false
        for _ in 0..<200 where !opened {
            opened = writer.append(pixelBuffer: pixelBuffer,
                                   pts: CMTime(value: 0, timescale: 25_000))
            if !opened { try await Task.sleep(for: .milliseconds(5)) }
        }
        try #require(opened, "the writer never opened its session")
        defer { writer.cancel() }
        for frame in 1...33 {
            writer.addTimecodeResync(
                timecode: Timecode(hours: 11, minutes: 0, seconds: 0,
                                   frames: frame, fps: 25),
                at: CMTime(value: CMTimeValue(frame * 1000), timescale: 25_000))
        }
        #expect(writer.tcResyncs.count == 32)
        #expect(writer.droppedTimecodeResyncs == 1,
                "the anchor past the budget vanished without a count")
    }
}
