import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **A grade reaching the documents that leave set.**
///
/// `MediaCDLLookTests` next door is about the CDL becoming a look — the file
/// landing in the library, the nine numbers surviving the conversion into a
/// lattice. This is the other end: what the EDL and the Avid log say about
/// that grade, and that they say the same thing.
@Suite @MainActor struct MediaCDLExportTests {
    /// The same look a cart would hand over, spelled the way
    /// `MediaCDLLookTests` spells it — one fixture would be better and one
    /// fixture is what `CDLLookFixtures` should become the moment a third
    /// suite wants it.
    private static let cdlText = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ColorDecisionList xmlns="urn:ASC:CDL:v1.01">
          <ColorDecision>
            <ColorCorrection id="day3_ext">
              <SOPNode>
                <Slope>1.10 1.00 0.90</Slope>
                <Offset>0.02 0.00 -0.03</Offset>
                <Power>0.95 1.00 1.15</Power>
              </SOPNode>
              <SatNode><Saturation>0.85</Saturation></SatNode>
            </ColorCorrection>
          </ColorDecision>
        </ColorDecisionList>
        """

    /// Point a controller at scratch folders before it touches any of them:
    /// the defaults are the operator's real Application Support and their real
    /// Resolve LUT directory.
    private func isolateLookFolders(_ controller: CaptureController,
                                    in directory: URL) {
        controller.lutsDirectory = directory.appendingPathComponent("LUTs")
        controller.resolveLUTDirectory = directory.appendingPathComponent("Resolve")
    }

    private func write(_ text: String, named name: String,
                       in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// **…and the Avid log carries the same nine numbers** (owner: "нужно
    /// да"). The EDL and the ALE are read side by side during a conform, so
    /// the grade has to be one grade — a column filled from a second spelling
    /// is how two documents from one day come to disagree.
    @Test func theAvidLogCarriesTheSameGradeAsTheEDL() async throws {
        let media = try MediaFixtures.makeDirectory("cdl-ale")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            self.isolateLookFolders(controller, in: media)
            controller.adoptLooks(from: [try self.write(
                Self.cdlText, named: "day3_ext.cdl", in: media)])
            var take = ControllerFixtures.take(named: "A", in: media)
            take.rating = .good

            let cdl = try #require(controller.currentCDL)
            let ale: String = try #require(ALEExporter.ale(
                takes: [take], format: nil, cdl: cdl))
            let edl: String = try #require(EDLExporter.selectsEDL(
                takes: [take], title: "t", cdl: cdl))
            // Taken OUT of the EDL rather than built from a helper both
            // documents share: what this has to pin is that the two files
            // agree, and a helper they both call cannot tell you that.
            let sop: String = try #require(edl
                .components(separatedBy: "\n")
                .first { $0.hasPrefix("*ASC_SOP ") }?
                .dropFirst("*ASC_SOP ".count)
                .trimmingCharacters(in: .whitespaces))
            #expect(sop.hasPrefix("(1.1000"), "\(sop)")
            #expect(ale.contains("\t\(sop)\t"),
                    "the log does not carry the EDL's grade: \(sop)")
            #expect(ale.contains("ASC_SAT"))
            #expect(ale.contains("0.8500"), "the saturation did not travel")

            // …and the EXPORT hands the grade over, which is the half a
            // direct call to the writer cannot see.
            controller.takes = [take]
            let destination = media.appendingPathComponent("log.ale")
            try await FakeFilePanel.installed(saving: [destination]) { _ in
                controller.exportALE()
            }
            let written: String = try String(contentsOf: destination,
                                             encoding: .utf8)
            #expect(written.contains("\t\(sop)\t"),
                    "the exported log lost the grade")
        }
    }
}
