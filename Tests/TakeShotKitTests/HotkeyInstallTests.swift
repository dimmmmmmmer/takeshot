import Foundation
import Testing

@testable import TakeShotKit

/// The main window's `onAppear` installs the key monitor, and runs again when
/// the window is reopened. A monitor never goes away by itself.
@MainActor
struct HotkeyInstallTests {
    @Test func reopeningTheWindowReplacesTheMonitorRatherThanStackingOne() async throws {
        try await ControllerHarness.run { controller, _ in
            let manager = HotkeyManager(defaults: InMemoryDefaults())
            manager.install(controller: controller)
            // A local monitor needs an application event queue; a test process
            // that has none is not a place this can be said anything about.
            try #require(manager.hasMonitor,
                         "no monitor came up headless — the premise is gone")
            manager.install(controller: controller)
            #expect(manager.hasMonitor)
            #expect(manager.staleMonitorsRemoved == 1,
                    "the second install stacked on the first")
        }
    }
}
