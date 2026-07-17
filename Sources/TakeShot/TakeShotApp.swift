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
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    hotkeys.install(controller: controller)
                }
        }

        // Окно диагностики VANC-пакетов (открывается кнопкой из главного окна)
        Window("VANC Monitor", id: "vanc-monitor") {
            VancMonitorView()
                .environmentObject(controller)
        }
        .defaultSize(width: 640, height: 320)

        Settings {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(hotkeys)
        }
    }
}

/// При запуске голого исполняемого файла из swift build (без .app-бандла)
/// приложение не получает фокус — поднимаем его вручную.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
