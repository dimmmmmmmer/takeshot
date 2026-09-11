import AVFoundation
import CaptureCore
import Foundation

/// Transport actions that do not care which engine is playing.
///
/// A clip in the player is driven by one of two engines — AVPlayer through
/// `TransportModel`, or our own RAW engine (`RawPlayerModel`) for BRAW and
/// CinemaDNG — and each has a transport bar of its own that talks to it
/// directly. The menu bar cannot: it is one set of items for whatever happens to
/// be loaded. These route to the SAME methods the bars' buttons call; the
/// routing is the only thing that is new.
extension CaptureController {
    /// A clip is loaded and the app is showing it, rather than the live signal.
    /// What every transport item in the menu is enabled by. A sync-play grid
    /// counts: its master transport answers the same keys.
    var isReviewingClip: Bool {
        viewerMode == .playback && (playbackURL != nil || syncPlay != nil)
    }

    /// A clip is loaded in the SINGLE player — the grid does not count.
    ///
    /// What the items that act on one clip's own timeline are enabled by: the
    /// loop range and the markers. Both belong to a file, the grid has two to
    /// four of them and no loop at all, and both were reaching the single
    /// player parked underneath it: `toggleLoopPoint` refused outright
    /// (`guard syncPlay == nil`), `loopPlayback` and every marker item went
    /// through to whatever clip was last open — a marker written at the paused
    /// player's position, into a file the operator cannot see. Enabled and
    /// wrong is worse than grey, so the menus ask this instead.
    var isReviewingSingleClip: Bool {
        viewerMode == .playback && playbackURL != nil && syncPlay == nil
    }

    /// Which transport bar, if any, is drawn under the picture.
    enum TransportBarKind: Equatable {
        /// No bar: the live signal, a still, a sync-play grid, or a RAW clip
        /// the engine could not open.
        case none
        /// The AVPlayer transport — a video clip in the single player.
        case video
        /// The RAW engine's own bar: BRAW, R3D or a CinemaDNG folder.
        case raw
    }

    /// What is under the picture right now.
    ///
    /// One rule, because two surfaces need the answer and they used to ask
    /// different questions. `PreviewView` asked a careful one — video only, not
    /// a still, not RAW, not a grid — while the toast that has to clear the bar
    /// asked "is a clip loaded in playback", which is not the same question and
    /// is wrong for exactly the cases the careful one excludes: a still and a
    /// sync-play grid have no bar, and the toast floated 42 points above
    /// nothing over both. `PlayerToast` names the other half of that drift.
    ///
    /// A RAW clip the engine could NOT open gets no bar at all, which is the
    /// same reading `PreviewView.surfaceSource` already takes of it — what is
    /// on screen there is a "could not open" notice, and a transport under it
    /// would be driving whatever clip was open before.
    var transportBarKind: TransportBarKind {
        // A clean feed has no bar. HERE and not at the bar's own mounting
        // point, because this property is what the toast measures its offset
        // against (see above): hiding the bar anywhere else would float the
        // toast 42 points above nothing, which is the drift this property was
        // extracted to end.
        guard !cleanFeed else { return .none }
        guard viewerMode == .playback, syncPlay == nil, let url = playbackURL
        else { return .none }
        if rawPlayer?.url == url { return .raw }
        return playbackClipIsAVPlayerVideo ? .video : .none
    }

    /// **Whether the clip under review is AVPlayer video** — not a RAW clip,
    /// not a still.
    ///
    /// Extracted out of `transportBarKind` because a second reader arrived
    /// that must NOT inherit that property's first guard: the clean feed hides
    /// the transport bar, and it has nothing to say about whether a reference
    /// pinned from this clip can play (`referenceCanPlay`). Asking
    /// `transportBarKind` there would have frozen the reference for anyone
    /// working with the chrome hidden. One rule, two readers, each with its
    /// own guards.
    var playbackClipIsAVPlayerVideo: Bool {
        guard let url = playbackURL, rawPlayer?.url != url else { return false }
        let ext = url.pathExtension.lowercased()
        return !Self.rawExtensions.contains(ext)
            && !Self.imageExtensions.contains(ext)
    }

    func togglePlayPause() {
        if let sync = syncPlay {
            sync.togglePlay()
        } else if let raw = rawPlayer {
            raw.togglePlay()
        } else {
            transport.togglePlay()
        }
    }

    /// Jump by `seconds`; negative goes back.
    func skipPlayback(bySeconds seconds: Double) {
        if let sync = syncPlay {
            sync.skip(bySeconds: seconds)
        } else if let raw = rawPlayer {
            raw.seek(to: raw.currentFrame
                + Int((seconds * raw.frameRate).rounded()))
        } else {
            transport.skip(seconds)
        }
    }

    /// One frame either way — how a focus or an eyeline is checked.
    func stepPlayback(forward: Bool) {
        stepPlayback(byFrames: forward ? 1 : -1)
    }

    /// **Frames, not seconds** (owner: "значки перемотки вообще как будто не
    /// на 5 сек должны мотать а на 5 фреймов", and the arrow keys beside
    /// them). One place for every jump that is counted in frames: the buttons
    /// on the bar, ← →, and ⇧← ⇧→.
    ///
    /// The grid steps one frame at a time on purpose: its own `step` is a
    /// synchronized move of every tile, and asking it for five is five of
    /// those — which is what it costs and what it is for.
    func stepPlayback(byFrames frames: Int) {
        guard frames != 0 else { return }
        if let sync = syncPlay {
            for _ in 0..<abs(frames) { sync.step(forward: frames > 0) }
        } else if let raw = rawPlayer {
            raw.seek(to: raw.currentFrame + frames)
        } else {
            transport.skip(Double(frames) / max(1, playbackFPS))
        }
    }

    /// **J-K-L**, the way an editor's hands already know it (owner: "как в
    /// давинчи для транспорта по плейбеку хочу клавиши J K L").
    ///
    /// L pressed again goes faster, J the same backwards, K stops — and the
    /// ladder is the one this app's own speed picker offers, so the readout in
    /// the bar and the key agree about what "×4" means.
    ///
    /// **What each engine can do with it differs, and saying so is better than
    /// pretending.** The single player has a rate, so it shuttles. The RAW
    /// engine and the sync-play grid decode frame by frame and have no reverse
    /// at all: forward is play/pause, and a backwards press steps back a frame
    /// — the same thing the key does when a clip cannot be played in reverse.
    static let shuttleRates: [Double] = [1, 2, 4, 8]

    /// **How far the bar's two skip buttons and ⇧← ⇧→ move** (owner: "значки
    /// перемотки вообще как будто не на 5 сек должны мотать а на 5 фреймов").
    ///
    /// They were five SECONDS, which is the glyph Apple draws on
    /// `gobackward.5` and is not what an operator checking a moment wants: a
    /// take on set is ten seconds long and a five-second jump is half of it.
    /// Five frames is the step either side of "one frame", which is what the
    /// bare arrows do.
    static let frameJump = 5

    func shuttlePlayback(forward: Bool) {
        guard isReviewingClip else { return }
        if syncPlay != nil || rawPlayer != nil {
            if forward {
                togglePlayPause()
            } else {
                stepPlayback(byFrames: -1)
            }
            return
        }
        let current = transport.isPlaying ? transport.desiredRate : 0
        transport.setRate(Float(Self.nextShuttleRate(from: current,
                                                     forward: forward)))
        if !transport.isPlaying { transport.togglePlay() }
    }

    /// **The next rung of the ladder**, signed.
    ///
    /// Pressed again in the same direction it goes faster and stops at the
    /// top; pressed the other way it starts over at 1×, which is what every
    /// editor's hands expect — J after L is "now go back", not "go back eight
    /// times as fast". A stopped player is `current` 0 and starts at 1× either
    /// way.
    static func nextShuttleRate(from current: Double, forward: Bool) -> Double {
        let rates = shuttleRates
        let sameWay = forward ? current > 0 : current < 0
        let step = sameWay
            ? (rates.first { $0 > abs(current) } ?? rates.last ?? 1)
            : (rates.first ?? 1)
        return forward ? step : -step
    }

    /// K: stop where you are, and put the ladder back to 1×.
    func stopShuttle() {
        guard isReviewingClip else { return }
        if syncPlay != nil || rawPlayer != nil {
            if playbackIsRunning { togglePlayPause() }
            return
        }
        if transport.isPlaying { transport.togglePlay() }
        transport.setRate(1)
    }

    /// ↑ / ↓ — the head and the tail of what is under review (owner: "а стрелки
    /// вверх вниз к началу или к концу тейка меня двигали").
    ///
    /// The IN and OUT points when the operator has marked a range, because
    /// that is what "the take" means once they have: a clip trimmed to the
    /// good part has its own head, and jumping past it to the slate is not
    /// what the key is for.
    func goToPlaybackEdge(end: Bool) {
        guard isReviewingClip else { return }
        if let sync = syncPlay {
            // The grid's own clamp answers for the end: `seek` takes the
            // master timeline's length as its ceiling, so asking for more than
            // there is lands exactly on it.
            sync.seek(to: end ? .greatestFiniteMagnitude : 0)
            return
        }
        if let raw = rawPlayer {
            let last = max(0, raw.frameCount - 1)
            let inFrame = raw.inPoint.map { Int(($0 * raw.frameRate).rounded()) }
            let outFrame = raw.outPoint.map { Int(($0 * raw.frameRate).rounded()) }
            raw.seek(to: end ? (outFrame ?? last) : (inFrame ?? 0))
            return
        }
        let target = end
            ? (transport.outPoint ?? transport.duration)
            : (transport.inPoint ?? 0)
        transport.seek(to: target)
    }

    /// Set or clear the loop in/out point at the playhead. Sync-play has no
    /// loop range — the guard keeps the key from marking the hidden single
    /// player's clip underneath the grid.
    func toggleLoopPoint(out: Bool) {
        guard syncPlay == nil else { return }
        if let raw = rawPlayer {
            raw.toggleRangePoint(out: out)
        } else {
            transport.toggleRangePoint(out: out)
        }
    }

    var loopPlayback: Bool {
        get { rawPlayer?.isLooping ?? transport.isLooping }
        set {
            if let raw = rawPlayer {
                raw.isLooping = newValue
            } else {
                transport.isLooping = newValue
            }
        }
    }

    /// Fullscreen the thing the operator is actually looking at: the clip in
    /// review, otherwise the live signal. Both are borderless windows of our
    /// own, not the green button (see `+Windows`).
    func toggleViewerFullscreen() {
        if isReviewingClip {
            togglePlaybackFullscreen()
        } else {
            toggleLiveFullscreen()
        }
    }
}
