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
        get { settings.appLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .english }
        set { settings.appLanguage = newValue.rawValue }
    }

    /// UI theme from settings.
    var colorScheme: ColorScheme? {
        switch settings.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Player backdrop color; black by default.
    var playerBackground: Color {
        get {
            settings.playerBackgroundHex.flatMap(Color.init(hex:))
                ?? Color(hex: "#000000")!
        }
        set {
            settings.playerBackgroundHex = newValue.hexString
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
        get { settings.accentHex.flatMap(Color.init(hex:)) ?? Color(hex: "#FFFFFF")! }
        set { settings.accentHex = newValue.hexString }
    }

    /// Window background color; grey by default — 15% brightness of black (~#262626).
    var appBackground: Color {
        get {
            settings.appBackgroundHex.flatMap(Color.init(hex:))
                ?? Color(hex: "#262626")!
        }
        set { settings.appBackgroundHex = newValue.hexString }
    }

    /// Reset only the UI colors to defaults.
    func resetInterface() {
        settings.playerBackgroundHex = nil
        settings.appBackgroundHex = nil
        settings.accentHex = nil
        settings.appearance = nil
        panelSide = "right"
        applyLetterboxColor()
    }

    /// Reset ALL app settings to factory (keep the record folder so we don't lose
    /// the current library). Hotkeys and panel layout too.
    func resetAllSettings() {
        let keepDestination = settings.destinationPath
        var fresh = CaptureSettings()
        fresh.destinationPath = keepDestination
        settings = fresh
        panelSide = "right"
        defaults.removeObject(forKey: "TakeShot.Hotkeys")
        L10n.apply(appLanguage)
        rebuildLUT()
    }
}
