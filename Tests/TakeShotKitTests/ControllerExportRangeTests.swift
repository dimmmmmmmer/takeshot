import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The operator's in/out reaches all three timelines** (owner: "так а ты
/// просто в самом таймлайне клип кидай по ин ауту но сорс пускай остается
/// полным").
///
/// The exporters themselves are pinned in `TimelineTrimTests` and
/// `TimelineTrimXMLTests`, over ranges handed straight in. This is the wiring:
/// every one of the three takes `ranges:` with a default of `[:]`, so deleting
/// any one `ranges: transport.storedRanges` argument compiles, leaves every
/// suite green, and silently un-ships the feature. Nothing else in the repo
/// exercises `transport.storedRanges` through an export at all.
@Suite @MainActor struct ControllerExportRangeTests {
    /// One circled take with the middle four seconds of ten marked.
    private func markedDay(_ controller: CaptureController,
                           in root: URL) throws -> Take {
        var good = ControllerFixtures.take(named: "A001C001", in: root, clip: 1)
        good.rating = .good
        good.durationSeconds = 10
        good.startTimecode = Timecode(hours: 10, minutes: 0, seconds: 0,
                                      frames: 0, fps: 25)
        try ControllerFixtures.placeholder(for: good)
        controller.takes = [good]
        controller.transport.storeRange(ClipRange(inPoint: 2, outPoint: 6),
                                        for: good.url)
        return good
    }

    private func exported(_ name: String, in root: URL,
                          running export: () -> Void) async throws -> String {
        let destination = root.appendingPathComponent(name)
        var text = ""
        try await FakeFilePanel.installed(saving: [destination]) { _ in
            export()
            text = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
        }
        return text
    }

    /// The EDL's event is the marked part, and it is four seconds long.
    @Test func theEDLIsCutToTheMarkedRange() async throws {
        let named: (inout CaptureSettings) -> Void = {
            $0.naming.projectName = "Nightshoot"
        }
        try await ControllerHarness.run(configure: named, { controller, root in
            _ = try self.markedDay(controller, in: root)
            let text = try await self.exported(
                "out.edl", in: root, running: { controller.exportSelectsEDL() })
            #expect(text.contains("10:00:02:00 10:00:06:00"),
                    "the EDL was written over the whole take: \(text)")
            #expect(!text.contains("10:00:00:00 10:00:10:00"))
        })
    }

    /// FCPXML places the clip over the marked part while its asset keeps the
    /// whole file — the handles an editor pulls back out.
    @Test func theFCPXMLClipIsCutWhileItsAssetStaysWhole() async throws {
        let named: (inout CaptureSettings) -> Void = {
            $0.naming.projectName = "Nightshoot"
        }
        try await ControllerHarness.run(configure: named, { controller, root in
            _ = try self.markedDay(controller, in: root)
            let text = try await self.exported(
                "out.fcpxml", in: root, running: { controller.exportFCPXML() })
            #expect(text.contains("duration=\"100/25s\""),
                    "the clip was not cut to the mark: \(text)")
            #expect(text.contains("duration=\"250/25s\""),
                    "the asset did not keep the whole take")
        })
    }

    /// …and the `xmeml` states the same two lengths the other way round.
    @Test func theXmemlClipIsCutWhileItsFileStaysWhole() async throws {
        let named: (inout CaptureSettings) -> Void = {
            $0.naming.projectName = "Nightshoot"
        }
        try await ControllerHarness.run(configure: named, { controller, root in
            _ = try self.markedDay(controller, in: root)
            let text = try await self.exported(
                "out.xml", in: root, running: { controller.exportFCP7XML() })
            #expect(text.contains("<in>50</in>"),
                    "the clipitem was not cut to the mark: \(text)")
            #expect(text.contains("<out>150</out>"))
            #expect(text.contains("<duration>250</duration>"),
                    "the file did not keep the whole take")
        })
    }
}
