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
                .preferredColorScheme(controller.colorScheme)
        }
        .defaultSize(width: 640, height: 320)

        Settings {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(hotkeys)
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
            for window in NSApp.windows where window.styleMask.contains(.titled) {
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
        }
    }
}
