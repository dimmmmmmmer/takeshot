import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Fullscreen surfaces and the mirrors of the viewer — the hardware playout,
/// the NDI source and the SRT stream.
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
        guard let deviceID = settings.capture.monitorDeviceID,
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
                // **Said, not assumed.** The fallback works, so it is a notice
                // and not an error — but the director's monitor is now showing
                // a SCALED 1080p25 raster of a signal that is neither, and an
                // operator who does not know that reads the softness as the
                // camera's and the cadence as a sync problem.
                lastNotice = L("toast_output_fallback", width, height,
                               Int(rate.rounded()))
            } catch {
                lastError = L("toast_output_failed",
                              BridgeUnavailable(error: error).localizedText)
            }
        }
        // A frozen output says so once, and says so again when it recovers.
        // The feeder cannot reach the controller on its own — it runs on its
        // own queue and holds no reference — so the hop is here.
        mirrors.playout?.onStall = { [weak self] reason in
            Task { @MainActor in
                guard let self else { return }
                guard let reason else {
                    // nil is the RECOVERY, which the first version of this
                    // threw away — so the comment above it was not kept and a
                    // board that came back left its own complaint on screen.
                    // Only this message is cleared: anything else on the line
                    // is somebody else's and outranks a resolved stall.
                    if self.lastError == L("playout_stalled_pool")
                        || self.lastError == L("playout_stalled_render") {
                        self.lastError = nil
                    }
                    return
                }
                self.lastError = reason
            }
        }
        wireDisplayMirrors()
    }
    /// The mirrors of whatever the viewer shows: the hardware output, the NDI
    /// source and the SRT stream when they are switched on, and every browser
    /// watching a picture that comes off this surface.
    ///
    /// They share one handler slot per source and each takes the picture it
    /// asked for out of the frame that arrives. The hardware output and the NDI
    /// source have no choice and want none — they stand in for a cable to a
    /// director's monitor, so they take the decorated frame, aids and key
    /// included. A browser names a `LivePicture`, and `LiveFrame`'s subscript
    /// is where that name becomes a buffer.
    ///
    /// **Only the `.viewer`-sourced pictures are wired here.** `.grid` is built
    /// from every live camera rather than from this surface, so it rides the
    /// monitor taps instead (`CaptureController+RemoteMultiview`) and keeps
    /// moving while the operator scrubs a take. That split is stated once, at
    /// `LivePicture.source`.
    ///
    /// **The viewer has FOUR sources, not three.** The live pipeline, the
    /// playback tap and the RAW engine each own a slot below — and during a
    /// sync-play comparison none of them is what the operator is looking at.
    /// That case is `SyncPlayGridPicture`, composed out of the comparison's own
    /// tiles and installed into the same slot shape, so nothing downstream of
    /// this function knows the difference: the feeder, NDI and every encoder
    /// still name a `LivePicture` and read it through `LiveFrame`'s subscript.
    /// See `CaptureController+SyncPlayPicture`.
    ///
    /// **What the slot fans out to is worth counting, because two network
    /// outputs at once is a case that did not exist until NDI came back beside
    /// SRT — and a browser choosing its own picture is one more.** SRT and
    /// every browser on the SAME picture are consumers of one shared H.264
    /// session, so however many of them are watching, that picture costs ONE
    /// `offer` here and the samples fan out downstream (`LiveVideoEncoder`). A
    /// browser on a DIFFERENT picture is a second entry in the pool and a
    /// second `offer`, and the app has three pictures, of which two are wired
    /// here. The hardware feeder and the NDI mirror are consumers of the
    /// display BUFFER, because a DeckLink output takes pixels and NDI's SDK
    /// takes frames it compresses with a codec of its own. So the per-frame
    /// cost on the display queue is one pixel-format test and one
    /// `dispatch_async` per live output, and nothing else: every piece of real
    /// work — the DeckLink submit, NDI's compression, the H.264 encodes — is on
    /// a queue of its own, and none of those queues is behind another. A wedged
    /// NDI receiver cannot delay a browser's picture, an SRT reconnect cannot
    /// delay NDI, and neither can reach the capture queue, which is the one
    /// that owns the file.
    ///
    /// With no hardware output and nothing watching, the slots go back to nil —
    /// so an idle app calls nothing per frame, and `publishDisplayFrame` does
    /// not even pair the two pictures up.
    func wireDisplayMirrors() {
        let feeder = mirrors.playout
        let ndi = mirrors.ndi
        // Flattened HERE, once per wiring, and never looked up per frame: the
        // pool is MainActor state and the handler runs on the display queue.
        // Every change to it re-wires, which is what makes that safe and what
        // keeps the per-frame cost a walk of at most two entries.
        let encoders: [(LivePicture, LiveVideoEncoder)] = mirrors.liveEncoders
            .filter { $0.key.source == .viewer }
            .map { ($0.key, $0.value) }
        guard feeder != nil || ndi != nil || !encoders.isEmpty else {
            pipeline.setOnDisplayFrame(nil)
            playbackTap.setOnDisplayFrame(nil)
            rawPlayer?.setOnDisplayFrame(nil)
            refreshSyncGridPicture(handler: nil)
            return
        }
        let routeLive = viewerMode == .record
        // The rate is captured per WIRING and not read per frame: the handler runs
        // on the display queue and the frame rate is MainActor state. Every route
        // change re-wires — a signal format change, a viewer mode switch, a clip
        // opening — so it follows the source. The encoder wants it for its
        // keyframe interval and its rate controller, which is why a format change
        // with no hardware output still has to come through here.
        let rate = routeLive ? (signalFormat?.frameRate ?? 0) : playbackFPS
        // …and NDI wants the same number as an exact RATIONAL, which is a
        // difference between the two transports rather than a duplication. NDI
        // declares the rate on every frame it sends, so 23.976 has to go out as
        // 24000/1001 or a receiver guesses at the pull-down; MPEG-TS and RTP
        // both timestamp on a 90 kHz clock and have no such field. Converted
        // once per wiring, beside the number it comes from.
        let ndiRate = NDIFrameRate(fps: rate)
        let handler: @Sendable (LiveFrame) -> Void = { frame in
            feeder?.submit(frame[.decorated])
            ndi?.offer(frame[.decorated], rate: ndiRate)
            for (picture, encoder) in encoders {
                encoder.offer(frame[picture], framesPerSecond: rate)
            }
        }
        // **A comparison is a FOURTH source, and it pre-empts the other three.**
        // What the operator is looking at then is a grid of 2–4 takes, not any
        // one surface, and `startSyncPlay` leaves the single player parked and
        // loaded on purpose — so routing by viewer mode alone handed the
        // mirrors a tap that had stopped delivering, and the board went on
        // showing its last frame. The grid is composed and sent instead
        // (`CaptureController+SyncPlayPicture`); the parked tap is disconnected
        // rather than left half-wired, which is the same rule the mode switch
        // above follows.
        let comparing = syncPlay != nil
        refreshSyncGridPicture(handler: routeLive || !comparing ? nil : handler)
        pipeline.setOnDisplayFrame(routeLive ? handler : nil)
        playbackTap.setOnDisplayFrame(routeLive || comparing ? nil : handler)
        rawPlayer?.setOnDisplayFrame(routeLive || comparing ? nil : handler)
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
