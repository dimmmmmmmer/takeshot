import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The refusal guards in front of the three end-of-day exports. Each guard
/// answers BEFORE the save panel — which is also why these are the only lines
/// of the export flow a headless suite can drive: everything past the guard
/// blocks on `NSSavePanel.runModal()`.
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
            controller.exportSelectsEDL()
            #expect(controller.lastError == L("edl_no_good_takes"))
        }
    }

    @Test func aleWithNoTakesAtAllIsARefusal() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.takes = []
            controller.exportALE()
            #expect(controller.lastError == L("ale_no_takes"))
        }
    }

    @Test func shiftReportWithNoTakesIsARefusalInBothFormats() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.takes = []
            controller.exportShiftReport(pdf: true)
            #expect(controller.lastError == L("report_no_takes"))
            controller.lastError = nil
            controller.exportShiftReport(pdf: false)
            #expect(controller.lastError == L("report_no_takes"))
        }
    }
}
