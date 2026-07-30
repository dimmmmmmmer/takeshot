import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Fullscreen surfaces and the hardware playout mirror.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    struct ScreenOption: Identifiable, Equatable {
        var id: CGDirectDisplayID
        var name: String
    }

    /// Displays other than the one the app's main window is on.
    var availableScreens: [ScreenOption] {
        let currentScreen = NSApp.mainWindow?.screen
        return NSScreen.screens.compactMap { screen in
            guard screen != currentScreen,
                  let id = screen.deviceDescription[
                      NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return ScreenOption(id: id, name: screen.localizedName)
        }
    }

    func rebuildPlayout() {
        playoutFeeder?.stop()
        playoutFeeder = nil
        guard let deviceID = settings.monitorDeviceID,
              deviceID.hasPrefix("decklink:") else {
            wirePlayoutRouting()
            return
        }
        // output mode follows the live signal; 1080p25 until one is known
        let width = signalFormat?.width ?? 1920
        let height = signalFormat?.height ?? 1080
        let rate = signalFormat?.frameRate ?? 25
        do {
            playoutFeeder = try PlayoutFeeder(
                deviceID: String(deviceID.dropFirst("decklink:".count)),
                width: width, height: height, frameRate: rate)
        } catch {
            // fall back to the universal 1080p25 raster (frames are scaled)
            do {
                playoutFeeder = try PlayoutFeeder(
                    deviceID: String(deviceID.dropFirst("decklink:".count)),
                    width: 1920, height: 1080, frameRate: 25)
            } catch {
                lastError = "Output: \(error.localizedDescription)"
            }
        }
        wirePlayoutRouting()
    }
    /// The output mirrors whatever the viewer shows.
    func wirePlayoutRouting() {
        guard let feeder = playoutFeeder else {
            pipeline.setOnDisplayFrame(nil)
            playbackTap.setOnDisplayFrame(nil)
            rawPlayer?.setOnDisplayFrame(nil)
            return
        }
        let routeLive = viewerMode == .record
        let handler: @Sendable (CVPixelBuffer) -> Void = { buffer in
            feeder.submit(buffer)
        }
        pipeline.setOnDisplayFrame(routeLive ? handler : nil)
        playbackTap.setOnDisplayFrame(routeLive ? nil : handler)
        rawPlayer?.setOnDisplayFrame(routeLive ? nil : handler)
    }
    /// Shared factory for the borderless full-screen output windows
    /// (playback fullscreen, live fullscreen, external monitor).
    private func makeBorderlessWindow(
        on screen: NSScreen, content: some View,
        behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary],
        makeKey: Bool = true) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false, screen: screen)
        window.level = .statusBar
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = behavior
        window.contentView = NSHostingView(rootView: content)
        window.setFrame(screen.frame, display: true)
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        return window
    }
    /// A different display was chosen for the director's monitor. Guarded on an
    /// actual change: rebuilding the window tears the picture down and puts it
    /// back, which reads as a flash on a monitor somebody is watching.
    func applyExternalDisplayChange(from oldValue: CGDirectDisplayID?) {
        guard oldValue != externalDisplayID else { return }
        updateExternalWindow()
    }
    func updateExternalWindow() {
        externalWindow?.orderOut(nil)
        externalWindow = nil

        guard let displayID = externalDisplayID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                   as? CGDirectDisplayID) == displayID
              }) else { return }

        externalWindow = makeBorderlessWindow(
            on: screen,
            content: ExternalOutputView().environmentObject(self),
            behavior: [.fullScreenAuxiliary, .stationary],
            makeKey: false)
    }
    /// System fullscreen of the main window (immersive mode).
    func toggleFullscreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }
    /// Fullscreen for PLAYBACK ONLY: a borderless full-screen window;
    /// the app itself stays as it was (this isn't the green button).
    func togglePlaybackFullscreen() {
        if isPlaybackFullscreen {
            playbackFullscreenWindow?.orderOut(nil)
            playbackFullscreenWindow = nil
            isPlaybackFullscreen = false
            return
        }
        guard let screen = NSApp.mainWindow?.screen ?? NSScreen.main else { return }
        playbackFullscreenWindow = makeBorderlessWindow(
            on: screen,
            content: PlaybackFullscreenView()
                .environmentObject(self)
                .environmentObject(hotkeysRef ?? HotkeyManager())
                .tint(accentColor))
        isPlaybackFullscreen = true
    }
    /// Fullscreen for the PLAYER ONLY in record mode (a live mirror in a borderless window).
    func toggleLiveFullscreen() {
        if isLiveFullscreen {
            liveFullscreenWindow?.orderOut(nil)
            liveFullscreenWindow = nil
            isLiveFullscreen = false
            return
        }
        guard let screen = NSApp.mainWindow?.screen ?? NSScreen.main else { return }
        liveFullscreenWindow = makeBorderlessWindow(
            on: screen,
            content: LiveFullscreenView()
                .environmentObject(self)
                .environmentObject(hotkeysRef ?? HotkeyManager())
                .tint(accentColor))
        isLiveFullscreen = true
    }
}
