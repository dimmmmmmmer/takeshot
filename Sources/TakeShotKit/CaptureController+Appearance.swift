import AppKit
import CaptureCore
import CoreImage
import Foundation
import SwiftUI

/// The appearance the settings pane owns — language, theme, the player
/// backdrop, the accent — and the two resets.
///
/// Split out of `+Settings`, which is about what a settings WRITE sets in
/// motion. Nothing here restarts anything; it is all colour and preference.
extension CaptureController {
    /// UI language; English by default.
    var appLanguage: AppLanguage {
        get { settings.theme.appLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .english }
        set { settings.theme.appLanguage = newValue.rawValue }
    }

    /// UI theme from settings.
    var colorScheme: ColorScheme? {
        switch settings.theme.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Player backdrop color; black by default.
    var playerBackground: Color {
        get {
            settings.theme.playerBackgroundHex.flatMap(Color.init(hex:))
                ?? Color(hex: "#000000")!
        }
        set {
            settings.theme.playerBackgroundHex = newValue.hexString
            applyLetterboxColor()
        }
    }

    /// The Metal preview letterboxes internally — keep its bars in the chosen
    /// backdrop color (they used to be transparent with the old video layer).
    func applyLetterboxColor() {
        let ns = NSColor(playerBackground).usingColorSpace(.sRGB) ?? .black
        let ci = CIColor(red: ns.redComponent, green: ns.greenComponent,
                         blue: ns.blueComponent)
        pipeline.setPreviewLetterbox(ci)
        playbackTap.setLetterbox(ci)
        rawPlayer?.setLetterbox(ci)
    }

    /// Control accent color; white by default.
    var accentColor: Color {
        get { settings.theme.accentHex.flatMap(Color.init(hex:)) ?? Color(hex: "#FFFFFF")! }
        set { settings.theme.accentHex = newValue.hexString }
    }

    /// Window background color; grey by default — 15% brightness of black (~#262626).
    var appBackground: Color {
        get {
            settings.theme.appBackgroundHex.flatMap(Color.init(hex:))
                ?? Color(hex: "#262626")!
        }
        set { settings.theme.appBackgroundHex = newValue.hexString }
    }

    /// Reset only the UI colors to defaults.
    func resetInterface() {
        settings.theme.playerBackgroundHex = nil
        settings.theme.appBackgroundHex = nil
        settings.theme.accentHex = nil
        settings.theme.appearance = nil
        panelSide = "right"
        applyLetterboxColor()
    }

    /// Reset ALL app settings to factory (keep the record folder so we don't lose
    /// the current library). Hotkeys and panel layout too.
    func resetAllSettings() {
        let keepDestination = settings.capture.destinationPath
        var fresh = CaptureSettings()
        fresh.capture.destinationPath = keepDestination
        settings = fresh
        panelSide = "right"
        defaults.removeObject(forKey: "TakeShot.Hotkeys")
        L10n.apply(appLanguage)
        rebuildLUT()
    }
}
