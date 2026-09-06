import Foundation
import Testing

@testable import TakeShotKit

/// **Every sheet leaves on Escape.** A take that starts with the offload sheet
/// up wants the operator back at the picture in one press; none of the four
/// had a cancel action, so Escape did nothing on any of them.
struct ViewSheetEscapeRuleTests {
    private static let sheets = ["OffloadSheet", "DailiesSheet",
                                 "OffloadVerifySheet", "HotkeyEditorView"]

    @Test func everySheetHasACancelAction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TakeShotKit")
        for sheet in Self.sheets {
            let source = try String(contentsOf: root.appendingPathComponent("\(sheet).swift"),
                                    encoding: .utf8)
            #expect(source.contains(".keyboardShortcut(.cancelAction)"),
                    "\(sheet) has no way out on Escape")
        }
    }
}

/// **Visual detection chosen before the indicator has been taught says so.**
///
/// The setter keeps the trigger off and nothing on screen said it, so an
/// operator stood watching for takes that could not start. The rule is a
/// property rather than a shape in the view, so it can be asked directly.
@MainActor
struct ModelVisualRecCaptionTests {
    @Test func visualWithoutATeachingIsFlagged() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.capture.detectionMode = .vanc
            #expect(!controller.visualRecNeedsTeaching)
            controller.settings.capture.detectionMode = .visual
            #expect(controller.canUseVisualRec == false,
                    "the fixture came up already taught — the premise is gone")
            #expect(controller.visualRecNeedsTeaching,
                    "Visual is on, nothing is taught, and nothing says so")
        }
    }
}
