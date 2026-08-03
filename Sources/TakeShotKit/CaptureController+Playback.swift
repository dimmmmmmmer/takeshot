import AVFoundation
import AppKit
import CaptureCore
import CoreMedia
import Foundation
import SwiftUI

/// Opening a take in the player: which engine gets it, and what the switch
/// tears down on the way.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more. Reading a clip's
/// format and timecode back is `+PlaybackInfo`; stills — showing one and making
/// one — are `+Stills`.
extension CaptureController {
    /// RAW codecs played by our own engine, not AVPlayer.
    nonisolated static let rawExtensions: Set<String> = ["braw", "r3d"]

    /// A folder of .dng frames = one CinemaDNG clip.
    nonisolated static func isCinemaDNGFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return !DNGSequenceSource.frameURLs(in: url).isEmpty
    }

    /// Instant replay (video assist): the freshest take, from the top, looping.
    func instantReplay() {
        guard let last = takes.max(by: { $0.recordedAt < $1.recordedAt })
        else { return }
        replayLoopRequested = true
        play(url: last.url)
        if let raw = rawPlayer {
            raw.isLooping = true
            replayLoopRequested = false
        }
    }
    /// Open a file in the player and switch to playback mode.
    /// Photos are just displayed (AVPlayer isn't needed for them).
    func play(url: URL) {
        // One take in the single player supersedes a running comparison.
        endSyncPlay()
        // In/out belong to the clip they were marked on. The outgoing RAW
        // engine is about to be thrown away, so its range is filed here while
        // it still exists; the AVPlayer transport files its own in `loadClip`.
        if let raw = rawPlayer, let previous = playbackURL {
            transport.storeRange(
                ClipRange(inPoint: raw.inPoint, outPoint: raw.outPoint),
                for: previous)
        }
        playbackURL = url
        playbackFormatText = nil
        playbackStartTC = nil
        playbackAspect = nil
        playbackFPS = 25
        rawPlayer?.pause()
        rawPlayer = nil
        rawPlayerError = nil
        let ext = url.pathExtension.lowercased()
        let isRaw = Self.rawExtensions.contains(ext) || Self.isCinemaDNGFolder(url)
        let isStill = Self.imageExtensions.contains(ext) && !isRaw
        // only real video is driven by this transport (see TransportModel.loadClip)
        transport.loadClip(url, driving: !isRaw && !isStill)
        if isStill {
            player.pause()
            player.replaceCurrentItem(with: nil)
            playbackTap.detach()
            playbackLUTSuppressed = false
            loadStill(url: url)
        } else if isRaw {
            player.pause()
            player.replaceCurrentItem(with: nil)
            playbackTap.detach()
            openRawClip(url: url)
        } else {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            playbackTap.attach(to: item)
            playbackTap.setCompareClip(url: compareClipURL, syncTo: player)
            playbackLUTSuppressed = false
            detectBakedLUT(for: item) // applies the LUT itself once it learns the tag
            // a clip that carries a loop range opens INSIDE it: a new item
            // starts at zero, and the loop is only enforced at the out point
            // (owner item 38 — see TransportModel.rangeStart)
            transport.beginInsideRange()
            player.play()
            loadPlaybackInfo(for: item)
        }
        viewerMode = .playback
        updateTapRunning()
        updateScopesRunning()
    }
    /// BRAW/CinemaDNG: our own engine, not AVPlayer. The badges come from the
    /// clip itself — there is no AVAsset to load them from.
    private func openRawClip(url: URL) {
        var openError: String?
        // The R3D options are read here, not inside the engine: the engine is
        // built per clip and has no business reaching into settings, and the
        // decode scale has to be fixed before the first frame is asked for.
        guard let model = RawPlayerModel(
            url: url, scale: settings.r3dDecodeScaleEffective,
            applyCameraLUT: settings.r3dApplyCameraLUT ?? false,
            error: &openError) else {
            rawPlayerError = openError
            return
        }
        model.onScopeData = { [weak self] data in
            self?.scopes.data = data
        }
        model.onPlaybackError = { [weak self] text in
            self?.lastError = text
        }
        // A RAW engine is built from scratch per clip, so it starts with no
        // range at all; what was marked on THIS clip earlier in the session is
        // handed back here, in the engine's own units.
        let range = transport.storedRange(for: url)
        model.inFrame = range.inPoint.map { Int(($0 * model.frameRate).rounded()) }
        model.outFrame = range.outPoint.map { Int(($0 * model.frameRate).rounded()) }
        // File it as it is marked, not only when the clip is closed: a quit with a
        // RAW clip still open would otherwise lose the mark. Seconds is the unit
        // the store and the sidecar speak; the engine converts from its frames.
        model.onRangeChanged = { [weak self, weak model] in
            guard let self, let model else { return }
            self.transport.storeRange(
                ClipRange(inPoint: model.inPoint, outPoint: model.outPoint),
                for: url)
        }
        rawPlayer = model
        model.setViewAssist(assist)
        // the mirrors follow the RAW player too (renamed from
        // wirePlayoutRouting when NDI joined the hardware output on one slot)
        wireDisplayMirrors()
        playbackFormatText = Self.shortFormat(height: model.height,
                                              fps: model.frameRate)
        playbackStartTC = model.startTimecode
        playbackFPS = model.frameRate
        // After the rate, not before it: the mirrors state the rate of the
        // source they are pointed at, and the NDI frame carries it (see
        // `wireDisplayMirrors`).
        wireDisplayMirrors()
        playbackAspect = model.height > 0
            ? CGFloat(model.width) / CGFloat(model.height) : nil
        applyLetterboxColor()
        model.play()
    }
}
