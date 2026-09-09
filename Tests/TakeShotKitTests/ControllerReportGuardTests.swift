import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The refusal guards in front of the end-of-day exports. Each guard answers
/// BEFORE the save panel, so a day with nothing to write never puts a dialog in
/// front of the operator to make the point.
///
/// **Every case here runs inside `FakeFilePanel`, and that is not a
/// convenience.** These tests used to call the exports bare, on the reasoning
/// that a working guard never reaches the panel — which is exactly the thing
/// under test. Mutating a guard out did not fail them: it opened a REAL
/// `NSSavePanel` on the machine running the suite and the run hung there, modal,
/// until it was killed. A test whose failure mode is a dialog nobody is watching
/// is a test that cannot report. With the seam installed the same mutation fails
/// in milliseconds, and `saveRequests` says plainly that the guard let one
/// through.
///
/// The rest of the export flow is `ControllerExportDocumentTests`, which answers
/// the panel through the same seam.
@Suite @MainActor struct ControllerReportGuardTests {
    /// A day with takes but no circled ones exports no EDL — the selects EDL
    /// is the circled takes by definition, and an empty cut written anyway
    /// would conform to an empty timeline at the post house.
    @Test func selectsEDLWithNoGoodTakesIsARefusalNotAPanel() async throws {
        try await ControllerHarness.run { controller, root in
            var take = ControllerFixtures.take(named: "A001C001", in: root)
            take.rating = .bad
            try ControllerFixtures.placeholder(for: take)
            controller.takes = [take]
            try await FakeFilePanel.installed { panel in
                controller.exportSelectsEDL()
                #expect(controller.lastError == L("export_no_good_takes"))
                #expect(panel.saveRequests.isEmpty,
                        "an empty cut asked where to save")
            }
        }
    }

    /// **A day with takes but none circled exports no ALE and no timeline
    /// either**, which is the half that changed with them: both used to carry
    /// every take, so both used to succeed here. One message for all three,
    /// because there is now one rule.
    @Test func everyTimelineFormatRefusesADayWithNothingCircled() async throws {
        try await ControllerHarness.run { controller, root in
            var take = ControllerFixtures.take(named: "A001C001", in: root)
            take.rating = .bad
            try ControllerFixtures.placeholder(for: take)
            controller.takes = [take]
            #expect(!controller.canExportSelects,
                    "the menu is still offering a cut of nothing")

            try await FakeFilePanel.installed { panel in
                for export in [controller.exportALE, controller.exportFCPXML] {
                    controller.lastError = nil
                    export()
                    #expect(controller.lastError == L("export_no_good_takes"))
                }
                #expect(panel.saveRequests.isEmpty,
                        "a cut of nothing asked where to save")
            }
        }
    }

    @Test func aleWithNoTakesAtAllIsARefusal() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.takes = []
            try await FakeFilePanel.installed { panel in
                controller.exportALE()
                #expect(controller.lastError == L("export_no_good_takes"))
                #expect(panel.saveRequests.isEmpty)
            }
        }
    }

    @Test func shiftReportWithNoTakesIsARefusalInBothFormats() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.takes = []
            try await FakeFilePanel.installed { panel in
                controller.exportShiftReport(pdf: true)
                #expect(controller.lastError == L("report_no_takes"))
                controller.lastError = nil
                controller.exportShiftReport(pdf: false)
                #expect(controller.lastError == L("report_no_takes"))
                #expect(panel.saveRequests.isEmpty,
                        "an empty report asked where to save")
            }
        }
    }
}
