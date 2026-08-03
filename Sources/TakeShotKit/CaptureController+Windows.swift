import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Fullscreen surfaces and the mirrors of the viewer — the hardware playout and
/// the NDI source.
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
        mirrors.playout?.stop()
        mirrors.playout = nil
        guard let deviceID = settings.monitorDeviceID,
              deviceID.hasPrefix("decklink:") else {
            wireDisplayMirrors()
            return
        }
        // output mode follows the live signal; 1080p25 until one is known
        let width = signalFormat?.width ?? 1920
        let height = signalFormat?.height ?? 1080
        let rate = signalFormat?.frameRate ?? 25
        let board = String(deviceID.dropFirst("decklink:".count))
        do {
            mirrors.playout = try PlayoutFeeder.factory(board, width, height, rate)
        } catch {
            // fall back to the universal 1080p25 raster (frames are scaled)
            do {
                mirrors.playout = try PlayoutFeeder.factory(board, 1920, 1080, 25)
            } catch {
                lastError = "Output: \(error.localizedDescription)"
            }
        }
        wireDisplayMirrors()
    }
    /// The mirrors show whatever the viewer shows: the hardware output, and the
    /// NDI source when it is switched on.
    ///
    /// Both take the SAME frame — the decorated one, aids and key included,
    /// which is what a director watches — so they share one handler slot per
    /// source rather than each claiming its own. That is only true because they
    /// want the same picture: the phone camera grid has a slot of its own
    /// precisely because it wants the CLEAN frame (see
    /// `CapturePipeline.publishDisplayFrame`).
    ///
    /// With neither mirror present the slots go back to nil, so an app with no
    /// hardware output and NDI off calls nothing per frame.
    func wireDisplayMirrors() {
        let feeder = mirrors.playout
        let mirror = mirrors.ndi
        guard feeder != nil || mirror != nil else {
            pipeline.setOnDisplayFrame(nil)
            playbackTap.setOnDisplayFrame(nil)
            rawPlayer?.setOnDisplayFrame(nil)
            return
        }
        let routeLive = viewerMode == .record
        // The rate is stated per sender, not per frame: it is captured here
        // because the handler runs on the display queue and the frame rate is
        // MainActor state. Every route change re-wires — a signal format change,
        // a viewer mode switch, a clip opening — so it follows the source.
        let rate = NDIFrameRate(fps: routeLive
            ? (signalFormat?.frameRate ?? 0) : playbackFPS)
        let handler: @Sendable (CVPixelBuffer) -> Void = { buffer in
            feeder?.submit(buffer)
            mirror?.offer(buffer, rate: rate)
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
