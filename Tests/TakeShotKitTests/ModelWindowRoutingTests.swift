import AppKit
import Testing

@testable import TakeShotKit

/// One window per job, and one process per machine.
///
/// The main window used to be a `WindowGroup` — a window FACTORY. Two
/// `ContentView`s driven by one controller mount two viewer surfaces onto one
/// preview layer, and a CALayer has exactly one host view, so the second mount
/// takes the picture away from the first: on set that looks like the board has
/// failed. It is a `Window` scene now, and every opener in the app goes through
/// `AppWindows`, which asks the scene for a window only when there is not one.
@MainActor
struct ModelWindowRoutingTests {
    /// A titled window, ordered nowhere yet — the shape SwiftUI hands out.
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                 styleMask: [.titled, .closable, .miniaturizable],
                 backing: .buffered, defer: false)
    }

    // MARK: - the scene ids

    /// The raw values ARE the scene ids in `TakeShotApp`, and a saved window
    /// frame, the scopes frame keeper and every `openWindow(id:)` are keyed by
    /// them. Renaming one silently orphans all of that.
    @Test func theSceneIdsAreTheOnesTheAppHasAlwaysUsed() {
        #expect(AppWindowID.main.rawValue == "main")
        #expect(AppWindowID.help.rawValue == "help")
        #expect(AppWindowID.scopes.rawValue == "scopes")
        #expect(AppWindowID.slate.rawValue == "slate")
        #expect(AppWindowID.vancMonitor.rawValue == "vanc-monitor")
        #expect(AppWindowID.settings.rawValue == "settings")
    }

    @Test func everySceneIdIsDistinct() {
        let ids = Set(AppWindowID.allCases.map(\.rawValue))
        #expect(ids.count == AppWindowID.allCases.count)
    }

    // MARK: - focus vs. reopen

    /// A window nobody has registered can only be asked for.
    @Test func anUnknownWindowIsReopened() {
        #expect(AppWindows.route(for: .help) == .reopen)
    }

    /// Registered and on screen: focused, never duplicated. This is the case
    /// that used to open a second one.
    @Test func anOpenWindowIsFocusedRatherThanOpenedAgain() {
        let window = window()
        AppWindows.register(window, as: .scopes)
        window.orderFront(nil)

        #expect(AppWindows.isOpen(.scopes))
        #expect(AppWindows.route(for: .scopes) == .focus)
        window.orderOut(nil)
    }

    /// Registered but closed: the scene has to build it again — a `.focus` here
    /// would order a window nobody can see to the front and look like a dead
    /// button.
    @Test func aClosedWindowIsReopened() {
        let window = window()
        AppWindows.register(window, as: .slate)
        window.orderFront(nil)
        window.orderOut(nil)

        #expect(!AppWindows.isOpen(.slate))
        #expect(AppWindows.route(for: .slate) == .reopen)
    }

    /// The registry holds its windows weakly: a window SwiftUI tore down must
    /// not be kept alive here, and a stale entry is worse than none — `present`
    /// would order a dead window front and never ask the scene to reopen.
    @Test func theRegistryDoesNotKeepAWindowAlive() {
        autoreleasepool {
            let window = window()
            window.isReleasedWhenClosed = false
            AppWindows.register(window, as: .vancMonitor)
            #expect(AppWindows.window(.vancMonitor) === window)
        }
        #expect(AppWindows.window(.vancMonitor) == nil,
                "the table is holding a window the scene has finished with")
    }

    // MARK: - one process

    /// The decision table. A second copy would open the same DeckLink board and
    /// write into the same record folder under the same clip numbers, and
    /// neither copy can see the other doing it.
    @Test func aSecondInstanceHandsOffToTheFirst() {
        #expect(SingleInstanceGuard.handsOff(bundleID: "com.takeshot.app",
                                             otherInstances: 1,
                                             allowMultiple: false))
        #expect(!SingleInstanceGuard.handsOff(bundleID: "com.takeshot.app",
                                              otherInstances: 0,
                                              allowMultiple: false))
    }

    /// A bare `swift build` binary has no bundle identifier, so a development
    /// run from the command line is never handed off — there is nothing to
    /// query LaunchServices with, and guessing would refuse to launch the app
    /// at all.
    @Test func aBundleLessBuildIsNeverHandedOff() {
        #expect(!SingleInstanceGuard.handsOff(bundleID: nil, otherInstances: 3,
                                              allowMultiple: false))
        #expect(!SingleInstanceGuard.handsOff(bundleID: "", otherInstances: 3,
                                              allowMultiple: false))
    }

    /// Two builds side by side is a development need — comparing a fix against
    /// the shipping app — and ad-hoc signing means relaunching dozens of times
    /// an hour.
    @Test func theEnvironmentOverrideAllowsASecondCopy() {
        #expect(!SingleInstanceGuard.handsOff(bundleID: "com.takeshot.app",
                                              otherInstances: 2,
                                              allowMultiple: true))
        let key = SingleInstanceGuard.overrideKey
        #expect(SingleInstanceGuard.allowsMultiple([key: "1"]))
        #expect(SingleInstanceGuard.allowsMultiple([key: "yes"]))
        #expect(!SingleInstanceGuard.allowsMultiple([key: "0"]))
        #expect(!SingleInstanceGuard.allowsMultiple([key: "false"]))
        #expect(!SingleInstanceGuard.allowsMultiple([:]))
    }
}
