import AppKit
import SwiftUI

@main
struct TakeShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = CaptureController()

    @StateObject private var hotkeys = HotkeyManager()

    var body: some Scene {
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

        // VANC packet diagnostics window (opened by a button from the main window)
        Window("VANC Monitor", id: "vanc-monitor") {
            VancMonitorView()
                .environmentObject(controller)
                .tint(controller.accentColor)
                .preferredColorScheme(controller.colorScheme)
        }
        .defaultSize(width: 640, height: 320)

        Settings {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(hotkeys)
                .tint(controller.accentColor)
                .preferredColorScheme(controller.colorScheme)
        }
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
    static func makeMonolithic(_ window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
    }

    /// Actual height of the window-button area: window height minus contentLayoutRect.
    static func titlebarInset(of window: NSWindow) -> CGFloat {
        max(20, window.frame.height - window.contentLayoutRect.height + 2)
    }
}
