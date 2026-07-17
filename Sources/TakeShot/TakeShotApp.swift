import AppKit
import SwiftUI

@main
struct TakeShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = CaptureController()

    var body: some Scene {
        WindowGroup("TakeShot") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 960, minHeight: 600)
        }
        Settings {
            SettingsView()
                .environmentObject(controller)
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
