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
                    hotkeys.install(controller: controller)
                }
        }
        // кнопки окна поверх контента, без отдельной полосы тайтлбара
        .windowStyle(.hiddenTitleBar)

        // Окно диагностики VANC-пакетов (открывается кнопкой из главного окна)
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

/// При запуске голого исполняемого файла из swift build (без .app-бандла)
/// приложение не получает фокус — поднимаем его вручную.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // контент — под самый верх окна: без этого SwiftUI резервирует
        // высоту тайтлбара и сверху остаётся пустая полоса
        DispatchQueue.main.async {
            for window in NSApp.windows { Self.makeMonolithic(window) }
            NSApp.mainWindow?.makeFirstResponder(nil)
        }
        // настройки и другие окна создаются позже — стилизуем при активации
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            if let window = note.object as? NSWindow {
                Self.makeMonolithic(window)
            }
        }
    }

    /// Монолитное окно без полосы тайтлбара (кнопки поверх контента).
    static func makeMonolithic(_ window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
    }
}
