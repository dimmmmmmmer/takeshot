import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// What a settings change sets in motion, plus the appearance the settings
/// pane owns: theme, player backdrop, accent, and the resets.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    /// Every settings write lands here (from the `settings` didSet). Only the
    /// parts of the app the change actually touches are rebuilt — see below.
    func applySettingsChange(from oldValue: CaptureSettings) {
        settings.save()
        // volume slider ticks land here too — only re-apply localization on
        // an actual language change (Bundle lookups hit the disk), and only
        // push the pipeline config when something it reads has changed
        if oldValue.appLanguage != settings.appLanguage {
            L10n.apply(appLanguage)
        }
        var irrelevant = oldValue
        irrelevant.monitorVolume = settings.monitorVolume
        if irrelevant != settings {
            pushConfig()
        }
        if oldValue.monitorDeviceID != settings.monitorDeviceID {
            rebuildPlayout()
        }
        if oldValue.destinationPath != settings.destinationPath {
            resetLibraryForNewDestination()
            startFolderWatcher()
        }
        if oldValue.forcedInputMode != settings.forcedInputMode
            || oldValue.forcedInputRGB != settings.forcedInputRGB
            || oldValue.tenBitCapture != settings.tenBitCapture {
            restartCapture()
        }
        // cam/postfix/template/padding affect the name — recompute the warning
        if oldValue.cameraLabel != settings.cameraLabel
            || oldValue.postfix != settings.postfix
            || oldValue.namingTemplate != settings.namingTemplate
            || oldValue.clipPadWidth != settings.clipPadWidth {
            refreshNameCollision()
        }
    }

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
        UserDefaults.standard.removeObject(forKey: "TakeShot.Hotkeys")
        L10n.apply(appLanguage)
        rebuildLUT()
    }
}
