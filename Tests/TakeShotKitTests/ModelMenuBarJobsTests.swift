import AppKit
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **The two jobs an operator starts with the window shut** — the status
/// item's dailies and offload rows (owner: "в статус бар думаю стоит добавить
/// – открыть окно дейликов, открыть окно переноса файлов").
///
/// Their own suite because `ModelMenuBarTests` reached the length at which
/// nobody reads a type top to bottom, and because these two ask a different
/// question from the rest of that file: not what the menu SAYS, but what
/// pressing a row does to the controller behind it.
@Suite @MainActor struct ModelMenuBarJobsTests {

    /// **Dailies and the offload are on the menu** (owner: "в статус бар думаю
    /// стоит добавить – открыть окно дейликов, открыть окно переноса файлов").
    ///
    /// Both open the sheet they name — and both are ungated, like the two
    /// monitor rows and unlike the footer's own buttons: a card has just come
    /// off the camera, or the day's dailies want starting, and neither is a
    /// reason to go hunting for the main window first.
    @Test func theMenuOpensTheDailiesSheet() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = MenuBarModel(controller: controller)
            let item = try #require(model.items.first {
                $0.command == .openDailies
            }, "the menu has no dailies row")
            #expect(item.enabled)
            #expect(item.title == L("menubar_open_dailies"))
            #expect(!controller.dailiesSheetPresented,
                    "the harness starts with the sheet closed")
            #expect(model.perform(.openDailies))
            #expect(controller.dailiesSheetPresented, """
                the dailies row was clicked and no sheet came up
                """)
        }
    }

    @Test func theMenuOpensTheOffloadSheet() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = MenuBarModel(controller: controller)
            let item = try #require(model.items.first {
                $0.command == .openOffload
            }, "the menu has no offload row")
            #expect(item.enabled)
            #expect(item.title == L("menubar_open_offload"))
            #expect(!controller.offloadSheetPresented)
            #expect(model.perform(.openOffload))
            #expect(controller.offloadSheetPresented, """
                the offload row was clicked and no sheet came up
                """)
        }
    }
}
