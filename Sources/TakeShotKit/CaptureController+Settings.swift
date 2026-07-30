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
        settings.save(to: defaults)
        // A settings write fans out only to the subsystems the change actually
        // touches: a volume slider tick lands here too, and rebuilding the
        // world on every one of them is what made the sliders lag.
        applyLanguageChange(from: oldValue)
        applyPipelineChange(from: oldValue)
        applyDeviceChange(from: oldValue)
        applyNamingChange(from: oldValue)
        applyRemoteChange(from: oldValue)
    }

    /// Bundle lookups hit the disk — only on an actual language change.
    private func applyLanguageChange(from oldValue: CaptureSettings) {
        guard oldValue.appLanguage != settings.appLanguage else { return }
        L10n.apply(appLanguage)
    }

    /// The pipeline only needs a push when something it reads has changed; the
    /// monitoring level, the DIM hold and the web remote are the fields it does
    /// not read — the first two are applied straight to the monitor and the
    /// third is a socket, and rebuilding the capture config per dim click (or
    /// per remote toggle) would make the sliders lag for nothing.
    private func applyPipelineChange(from oldValue: CaptureSettings) {
        var pipelineRelevant = oldValue
        pipelineRelevant.monitorVolume = settings.monitorVolume
        pipelineRelevant.monitorDimmed = settings.monitorDimmed
        pipelineRelevant.remoteEnabled = settings.remoteEnabled
        pipelineRelevant.remotePort = settings.remotePort
        pipelineRelevant.remotePIN = settings.remotePIN
        guard pipelineRelevant != settings else { return }
        pushConfig()
    }

    /// Hardware and destination: each of these restarts something.
    private func applyDeviceChange(from oldValue: CaptureSettings) {
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
    }

    /// cam/postfix/template/padding all feed the filename — recompute the
    /// "this name is already taken" warning.
    private func applyNamingChange(from oldValue: CaptureSettings) {
        guard oldValue.cameraLabel != settings.cameraLabel
            || oldValue.postfix != settings.postfix
            || oldValue.namingTemplate != settings.namingTemplate
            || oldValue.clipPadWidth != settings.clipPadWidth else { return }
        refreshNameCollision()
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
        defaults.removeObject(forKey: "TakeShot.Hotkeys")
        L10n.apply(appLanguage)
        rebuildLUT()
    }
}
