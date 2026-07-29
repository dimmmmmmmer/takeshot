import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CaptureCore

/// `ViewAssist.anyToolActive` is the switch that decides whether the assist
/// render pass runs at all. If it ever answers "no" while a tool is on, zebra
/// and peaking silently stop appearing on every surface at once — and the
/// preview still looks plausible, so nobody reports it as a bug.
struct GapViewAssistTests {
    @Test func aFreshAssistIsInert() {
        let assist = ViewAssist()
        #expect(!assist.anyToolActive)
        #expect(assist.colorTool == .off)
        #expect(assist.desqueeze == 1)
        #expect(assist.punchIn == 1)
        #expect(assist.panX == 0 && assist.panY == 0)
    }

    @Test func everyToolOnItsOwnActivatesTheAssistPass() {
        for tool in ViewAssist.ColorTool.allCases where tool != .off {
            var assist = ViewAssist()
            assist.colorTool = tool
            #expect(assist.anyToolActive, "\(tool) did not activate the pass")
        }

        var zebra = ViewAssist()
        zebra.zebraOn = true
        #expect(zebra.anyToolActive)

        var peaking = ViewAssist()
        peaking.peakingOn = true
        #expect(peaking.anyToolActive)
    }

    /// Framing tools are geometry, not a pixel pass: punching in or desqueezing
    /// must not switch the color-tool shader on.
    @Test func geometryOnlyChangesDoNotActivateTheAssistPass() {
        var assist = ViewAssist()
        assist.punchIn = 2
        assist.desqueeze = 1.33
        assist.panX = 0.25
        assist.zebraThreshold = 0.7
        assist.peakingIntensity = 30
        #expect(!assist.anyToolActive)
    }

    @Test func colorToolsRoundTripThroughTheirRawValues() {
        // the tool is persisted by raw value — renaming a case silently resets
        // the operator's choice to off on the next launch
        for tool in ViewAssist.ColorTool.allCases {
            #expect(ViewAssist.ColorTool(rawValue: tool.rawValue) == tool)
        }
        #expect(ViewAssist.ColorTool.allCases.map(\.rawValue)
                == ["off", "falseColor", "elZone"])
    }
}

/// `TimecodeReader` runs over whatever the folder scan finds. The happy path is
/// pinned in `TakeWriterTests`; what is not is everything that has no timecode
/// track to read — a take recorded off a signal with no RP188, or a file that
/// is not readable media at all. Any of those throwing or trapping would take
/// the whole library scan down with it.
struct GapTimecodeReaderTests {
    @Test func missingFileYieldsNil() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GapTimecodeReader-\(UUID().uuidString).mov")
        #expect(await TimecodeReader.startTimecode(of: AVURLAsset(url: url)) == nil)
    }

    @Test func fileThatIsNotMediaYieldsNil() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GapTimecodeReader-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a movie, just bytes".utf8).write(to: url)
        #expect(await TimecodeReader.startTimecode(of: AVURLAsset(url: url)) == nil)
    }

    /// A take written with no start timecode carries no timecode track. It is
    /// re-adopted by the folder scan on the next launch, which reads it back
    /// through here.
    @Test func movieWithoutATimecodeTrackYieldsNil() async throws {
        let directory = TestMedia.scratchDirectory("GapTimecodeReader")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("take.mov")

        let format = CaptureFormat(width: 320, height: 180, frameRate: 25,
                                   timecodeFPS: 25, name: "test")
        let writer = try TakeWriter(url: url, format: format,
                                    codec: .proResProxy, startTimecode: nil)
        let pixelBuffer = TestMedia.pixelBuffer()
        for frame in 0..<4 {
            let pts = CMTime(value: CMTimeValue(frame * 40), timescale: 1000)
            var attempts = 0
            while !writer.append(pixelBuffer: pixelBuffer, pts: pts), attempts < 100 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let written = try await writer.finish()

        let asset = AVURLAsset(url: written)
        #expect(try await asset.tracks(ofType: .timecode).isEmpty)
        #expect(await TimecodeReader.startTimecode(of: asset) == nil)
    }
}
