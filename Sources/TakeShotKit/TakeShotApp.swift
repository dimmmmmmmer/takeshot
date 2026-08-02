import AppKit
import SwiftUI

/// The app scene. `@main` lives in the executable target's main.swift, which
/// calls `TakeShotApp.main()` — see the comment there.
public struct TakeShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = CaptureController()

    @StateObject private var hotkeys = HotkeyManager()

    public init() {}

    /// Hand focus to an already-running copy of TakeShot and report that this
    /// process should stop launching. Called from the executable's entry point,
    /// before the scene graph — and the capture controller inside it — exists.
    /// See `SingleInstanceGuard` for what it does and does not cover.
    ///
    /// Not `@MainActor` itself: the executable's top-level code runs on the
    /// main thread but is not main-actor isolated in Swift 5 language mode, and
    /// this must be callable from the first line of it.
    public static func handOffToRunningInstance() -> Bool {
        MainActor.assumeIsolated { SingleInstanceGuard.handOffToRunningInstance() }
    }

    public var body: some Scene {
        // A `Window`, NOT a `WindowGroup`. A group is a window FACTORY: AppKit's
        // window tabbing ("New Tab", ⌘T, the "+" in the tab bar) and a reopen
        // of a closed group each ask it for another window, and two ContentViews
        // driven by one controller mount two viewer surfaces onto one preview
        // layer — a CALayer has exactly one host view, so the second mount takes
        // the picture away from the first (see the preview display rule in
        // CLAUDE.md). A `Window` scene has one window by construction and
        // `openWindow(id:)` reopens THAT one.
        Window("TakeShot", id: AppWindowID.main.rawValue) {
            ContentView()
                .environmentObject(controller)
                .environmentObject(hotkeys)
                .frame(minWidth: 1080, minHeight: 620)
                .tint(controller.accentColor)
                .preferredColorScheme(controller.colorScheme)
                .registersAppWindow(.main)
                .onAppear {
                    AppDelegate.shared?.controller = controller
                    hotkeys.install(controller: controller)
                    // inset under the window buttons — measured, not a constant
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let window = NSApp.windows.first(where: {
                            $0.styleMask.contains(.titled) }) {
                            controller.windowTopInset =
                                AppDelegate.titlebarInset(of: window)
                        }
                    }
                }
        }
        // window buttons over the content, no separate title-bar strip
        .windowStyle(.hiddenTitleBar)
        // The menu bar. Attached to the main window's scene so the items are
        // present for the whole app, not just while a particular window is key.
        .commands {
            TakeShotCommands(controller: controller, hotkeys: hotkeys)
        }

        // Operator guide (Help menu). A window, because it is read while the app
        // is being used — on set that means dragging it onto the second screen.
        Window(L("menu_help"), id: AppWindowID.help.rawValue) {
            HelpView()
                .environmentObject(controller)
                .frame(minWidth: 420, minHeight: 320)
                .tint(controller.accentColor)
                .preferredColorScheme(controller.colorScheme)
                .registersAppWindow(.help)
        }
        .defaultSize(width: HelpView.width, height: 720)

        // Scopes window: movable/resizable, opened from the player badge
        // Same rule as the VANC monitor below: the scene carries the localized
        // name, because that string is what the Window menu and Mission Control
        // label read. It is not drawn anywhere — the window wears the app's own
        // chrome, and `ScopesWindowView` hides the title strip the moment the
        // window exists rather than waiting for it to become key.
        Window(L("scopes_window_title"), id: AppWindowID.scopes.rawValue) {
            ScopesWindowView()
                .environmentObject(controller)
                .tint(controller.accentColor)
                .preferredColorScheme(.dark)
                .registersAppWindow(.scopes)
        }
        .defaultSize(width: 980, height: 380)

        // Digital slate: a fullscreen timecode + take card to point a camera
        // at (see SlateView). Dark by design like the scopes, and the scene
        // carries the localized name for the same reason — the Window menu and
        // Mission Control read it; the view hides the title strip itself.
        // Standard green-button fullscreen puts it wall-sized on any display.
        Window(L("slate_window_title"), id: AppWindowID.slate.rawValue) {
            SlateWindowView()
                .environmentObject(controller)
                .tint(controller.accentColor)
                .preferredColorScheme(.dark)
                .registersAppWindow(.slate)
        }
        .defaultSize(width: 960, height: 540)

        // VANC packet diagnostics window (opened by a button from the main
        // window). The localized name lives on the SCENE, not in a
        // `navigationTitle` inside the view: the scene title is what the Window
        // menu lists, and setting it from the view made SwiftUI show the title
        // strip as well (see VancMonitorView.monolithicWindowChrome).
        Window(L("vanc_monitor_title"), id: AppWindowID.vancMonitor.rawValue) {
            VancMonitorView()
                .environmentObject(controller)
                .tint(controller.accentColor)
                .preferredColorScheme(controller.colorScheme)
                .registersAppWindow(.vancMonitor)
        }
        .defaultSize(width: 640, height: 320)

        Window("Settings", id: AppWindowID.settings.rawValue) {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(hotkeys)
                .tint(controller.accentColor)
                .preferredColorScheme(controller.colorScheme)
                .registersAppWindow(.settings)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// The app-level behaviour no SwiftUI scene modifier expresses: activation on
/// launch (a bare `swift build` executable without an .app bundle does not get
/// focus on its own), the window chrome, closing a take that is still being
/// written on the way out, and the three rules that keep the app to ONE main
/// window — no tabbing, a dock click that restores rather than duplicates, and
/// a last-window-close that does not end the session.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    weak var controller: CaptureController?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.flushOnTerminate()
    }

    /// Window tabbing off, process-wide, before any window exists.
    ///
    /// It is the second way to get a duplicate main window and the one that
    /// survives `CommandGroup(replacing: .newItem)`: "New Tab" (⌘T), "Show Tab
    /// Bar" and the tab bar's own "+" live in the WINDOW menu, which the app
    /// does not own, and each of them asks the scene for another window. The
    /// main window is a single `Window` scene now, so there is nothing for them
    /// to duplicate — but an app with one window per job has no use for tabs in
    /// any of its five windows, and leaving the items in the menu bar offers
    /// the operator something that cannot work.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// The dock icon (or Window menu → TakeShot) with the main window closed
    /// brings THE main window back.
    ///
    /// AppKit's own answer for an app with no windows left is to do nothing at
    /// all, which reads as a dead dock icon; a `WindowGroup`'s answer used to be
    /// to build another window. `AppWindows.present` does neither — it reopens
    /// the one scene, or focuses it if it was merely minimized.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !AppWindows.isOpen(.main) { AppWindows.present(.main) }
        return true
    }

    /// Closing the last window does NOT quit TakeShot.
    ///
    /// Stated explicitly rather than left to AppKit's default, because the
    /// menu-bar item's whole promise depends on it: a take that is rolling when
    /// the operator closes the window keeps rolling, and the status item is the
    /// handle on it. This is also what the app has always done — the answer is
    /// the same with "keep TakeShot in the menu bar" off, so nothing changes for
    /// somebody who never turns it on.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // content up to the very top of the window: without this SwiftUI reserves
        // title-bar height and leaves an empty strip on top
        DispatchQueue.main.async {
            for window in NSApp.windows { Self.makeMonolithic(window) }
            NSApp.mainWindow?.makeFirstResponder(nil)
        }
        // settings and other windows are created later — style them on activation
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            if let window = note.object as? NSWindow {
                Self.makeMonolithic(window)
            }
        }
    }

    /// A monolithic window with no title-bar strip (buttons over the content).
    /// The chrome itself lives in `WindowChrome` — this used to be a second
    /// copy of it, and the two had already drifted apart.
    static func makeMonolithic(_ window: NSWindow) {
        WindowChrome.makeMonolithic(window)
    }

    /// Actual height of the window-button area: window height minus contentLayoutRect.
    static func titlebarInset(of window: NSWindow) -> CGFloat {
        max(20, window.frame.height - window.contentLayoutRect.height + 2)
    }
}
