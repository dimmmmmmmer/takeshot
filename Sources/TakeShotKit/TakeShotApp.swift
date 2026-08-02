import AppKit
import SwiftUI

/// The app scene. `@main` lives in the executable target's main.swift, which
/// calls `TakeShotApp.main()` — see the comment there.
public struct TakeShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = CaptureController()

    @StateObject private var hotkeys = HotkeyManager()

    public init() {}

    public var body: some Scene {
        WindowGroup("TakeShot") {
            ContentView()
                .environmentObject(controller)
                .environmentObject(hotkeys)
                .frame(minWidth: 1080, minHeight: 620)
                .tint(controller.accentColor)
                .preferredColorScheme(controller.colorScheme)
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
        // The menu bar. Attached to the main window group so the items are
        // present for the whole app, not just while a particular window is key.
        .commands {
            TakeShotCommands(controller: controller, hotkeys: hotkeys)
        }

        // Operator guide (Help menu). A window, because it is read while the app
        // is being used — on set that means dragging it onto the second screen.
        Window(L("menu_help"), id: "help") {
            HelpView()
                .environmentObject(controller)
                .frame(minWidth: 420, minHeight: 320)
                .tint(controller.accentColor)
                .preferredColorScheme(controller.colorScheme)
        }
        .defaultSize(width: HelpView.width, height: 720)

        // Scopes window: movable/resizable, opened from the player badge
        // Same rule as the VANC monitor below: the scene carries the localized
        // name, because that string is what the Window menu and Mission Control
        // label read. It is not drawn anywhere — the window wears the app's own
        // chrome, and `ScopesWindowView` hides the title strip the moment the
        // window exists rather than waiting for it to become key.
        Window(L("scopes_window_title"), id: "scopes") {
            ScopesWindowView()
                .environmentObject(controller)
                .tint(controller.accentColor)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 380)

        // Digital slate: a fullscreen timecode + take card to point a camera
        // at (see SlateView). Dark by design like the scopes, and the scene
        // carries the localized name for the same reason — the Window menu and
        // Mission Control read it; the view hides the title strip itself.
        // Standard green-button fullscreen puts it wall-sized on any display.
        Window(L("slate_window_title"), id: "slate") {
            SlateWindowView()
                .environmentObject(controller)
                .tint(controller.accentColor)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: 540)

        // VANC packet diagnostics window (opened by a button from the main
        // window). The localized name lives on the SCENE, not in a
        // `navigationTitle` inside the view: the scene title is what the Window
        // menu lists, and setting it from the view made SwiftUI show the title
        // strip as well (see VancMonitorView.monolithicWindowChrome).
        Window(L("vanc_monitor_title"), id: "vanc-monitor") {
            VancMonitorView()
                .environmentObject(controller)
                .tint(controller.accentColor)
                .preferredColorScheme(controller.colorScheme)
        }
        .defaultSize(width: 640, height: 320)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(hotkeys)
                .tint(controller.accentColor)
                .preferredColorScheme(controller.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// When launching the bare executable from swift build (without an .app bundle)
/// the app doesn't get focus — bring it to front manually.
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
