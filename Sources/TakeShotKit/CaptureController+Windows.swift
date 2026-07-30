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

    // MARK: - scopes window placement

    /// Where the scopes window was last left, in the app's own defaults.
    ///
    /// Manual rather than `setFrameAutosaveName`: AppKit's autosave writes to
    /// `UserDefaults.standard` under a name of its own, which a test may not
    /// touch and the controller's injected suite cannot see. This way the frame
    /// travels with the rest of the app's state.
    static let scopesFrameKey = "scopesWindowFrame"

    /// Adopt the stored frame and keep it up to date as the operator moves or
    /// resizes the window.
    ///
    /// Order matters: the frame is READ before anything is observed. A SwiftUI
    /// `Window` scene has already placed the window by the time its content
    /// appears, so an observer installed first would immediately save that
    /// default placement over the operator's.
    func keepScopesWindowFrame(_ window: NSWindow) {
        if let frame = savedScopesWindowFrame() {
            window.setFrame(frame, display: false)
        }
        for token in scopesFrameObservers {
            NotificationCenter.default.removeObserver(token)
        }
        scopesFrameObservers = [NSWindow.didMoveNotification,
                                NSWindow.didEndLiveResizeNotification].map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] note in
                guard let moved = note.object as? NSWindow else { return }
                let frame = moved.frame
                // AppKit posts this on the main thread; the hop is only for the
                // main-actor isolation the compiler cannot see through a
                // notification block
                Task { @MainActor in self?.saveScopesWindowFrame(frame) }
            }
        }
    }

    func saveScopesWindowFrame(_ frame: NSRect) {
        defaults.set(NSStringFromRect(frame), forKey: Self.scopesFrameKey)
    }

    /// The stored frame, or nil when there is none, it is unusably small, or it
    /// lands on a display that is no longer attached.
    func savedScopesWindowFrame(
        screens: [NSRect]? = nil) -> NSRect? {
        guard let text = defaults.string(forKey: Self.scopesFrameKey) else {
            return nil
        }
        let visible = screens ?? NSScreen.screens.map(\.visibleFrame)
        return Self.usableScopesFrame(NSRectFromString(text), screens: visible)
    }

    /// A saved frame is only used when it is big enough to hold the panel's own
    /// minimum and still overlaps a screen the operator can reach. Coming back
    /// from a two-monitor cart to a laptop must not hide the window off-screen.
    static func usableScopesFrame(_ frame: NSRect,
                                  screens: [NSRect]) -> NSRect? {
        guard frame.width >= 420, frame.height >= 260 else { return nil }
        let visible = screens.contains {
            let overlap = $0.intersection(frame)
            return overlap.width >= 120 && overlap.height >= 80
        }
        return visible ? frame : nil
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
