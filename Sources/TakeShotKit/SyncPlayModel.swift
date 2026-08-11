import AVFoundation
import CaptureCore
import Combine
import CoreMedia
import Foundation

/// Sync-play: 2–4 takes of the same action side by side, transport-locked.
///
/// Every take gets its OWN AVPlayer and its own `PlaybackFrameTap` — one frame
/// source per tile, so each grid mount registers its own `MetalPreviewLayer`
/// with its own tap (the preview display rule; the same shape as the compare
/// clip's slaved player in `PlaybackFrameTap+CompareClip`, once per tile).
/// One master transport drives them all.
///
/// The sync discipline: every start and every re-sync goes through
/// `AVPlayer.setRate(_:time:atHostTime:)` with ONE shared host time, so all
/// players slave their timebases to the same host-clock instant — they cannot
/// drift apart while rolling because they are counting the same clock. Seeks
/// and rate changes re-issue that synchronized start rather than nudging
/// players individually; a watchdog in the master's periodic observer catches
/// the residue (a player that stalled at start, an item that was not ready).
@MainActor
final class SyncPlayModel: ObservableObject {
    /// What one tile plays: the take's file plus the facts alignment and the
    /// tile label need. A plain value so tests can build sessions without a
    /// controller.
    struct Source: Equatable {
        var url: URL
        var name: String
        var startTimecode: Timecode?
        var duration: Double
    }

    /// One clip of the comparison: its own player, its own frame tap.
    @MainActor
    final class Tile: Identifiable {
        let source: Source
        let player: AVPlayer
        let tap = PlaybackFrameTap()

        init(source: Source) {
            self.source = source
            let item = AVPlayerItem(url: source.url)
            let player = AVPlayer(playerItem: item)
            // setRate(_:time:atHostTime:) refuses to schedule against the host
            // clock while automatic stalling is on; these are local files.
            player.automaticallyWaitsToMinimizeStalling = false
            // A clip that runs out mid-comparison freezes on its last frame
            // while the others continue — never a loop, never black.
            player.actionAtItemEnd = .pause
            player.isMuted = true
            self.player = player
            tap.attach(to: item, url: source.url)
            tap.setRunning(true)
        }

        /// Stop the 60 Hz poll and let go of the item. Explicit rather than in
        /// deinit — the tap's timer belongs to the dispatch system once resumed.
        func shutDown() {
            player.pause()
            tap.setRunning(false)
            tap.detach()
        }
    }

    let tiles: [Tile]
    /// Master playhead, seconds into the master timeline. Its own tiny
    /// observable (the same one the main transport uses) so the 10 Hz tick
    /// re-renders the TC labels and the slider, not the whole grid.
    let position = TransportPosition()
    @Published private(set) var isPlaying = false
    @Published private(set) var schedule: SyncPlaySchedule
    /// Rebuilds the schedule and rewinds: a master second means a different
    /// thing under the other alignment, so the session restarts from 0 paused.
    @Published var alignmentMode: SyncPlayAlignmentMode {
        didSet { applyAlignmentChange() }
    }
    /// The one take whose audio plays. Comparing two performances over both
    /// soundtracks at once is noise, so the master picks ONE — the first take
    /// by default, switched from the tiles' speaker toggles, never mixed.
    @Published var audibleIndex = 0 {
        didSet { applyAudioRouting() }
    }
    /// The level the audible take plays at, 0…1.
    ///
    /// The app's ONE monitoring level, pushed in by `CaptureController.setVolume`
    /// — so the mute hold, the DIM hold and the slider reach the grid the way
    /// they reach the single player, and switching between them does not change
    /// loudness. The grid used to have neither: the per-tile speaker moved the
    /// sound between takes and there was no way to turn it down or off at all,
    /// which on a set is the control that matters most.
    @Published private(set) var volume: Double = 1

    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// The player the two time observers were installed on. Removal must go to
    /// the SAME player, and `anchorIndex` may already point at a new master by
    /// the time an alignment change reinstalls them.
    private weak var observedPlayer: AVPlayer?
    /// The tile the transport reads its position from: the one that plays
    /// longest in the master domain, so the clock never stops early because a
    /// shorter clip froze.
    private var anchorIndex = 0
    /// One-shot recheck after a synchronized start (see `play`).
    private var startCheckTask: Task<Void, Never>?

    /// Host-clock lead given to a synchronized start: every player gets its
    /// seek done and waits at the gate, then all of them cross it on the same
    /// host-clock tick.
    static let startLeadSeconds = 0.12

    init(sources: [Source], alignmentMode: SyncPlayAlignmentMode = .byStart) {
        self.tiles = sources.map(Tile.init)
        self.alignmentMode = alignmentMode
        self.schedule = SyncPlaySchedule.compute(
            alignmentMode,
            startTimecodes: sources.map(\.startTimecode),
            durations: sources.map(\.duration))
        anchorIndex = Self.anchorIndex(for: schedule, sources: sources)
        applyAudioRouting()
        installObservers()
        alignPaused(to: 0)
    }

    /// End the session: observers off, players stopped, taps parked.
    func shutDown() {
        startCheckTask?.cancel()
        startCheckTask = nil
        removeObservers()
        for tile in tiles {
            tile.shutDown()
        }
        isPlaying = false
    }

    // MARK: - transport

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard !tiles.isEmpty else { return }
        var target = position.currentTime
        if target >= schedule.length - frameDuration / 2 {
            target = 0 // play at the end means "from the top", like the transport
        }
        syncPlayers(at: target)
        isPlaying = true
        // Rechecks after the gate: a player that was not `.readyToPlay` when
        // the start was issued only got parked at its position (see
        // `syncPlayers`) — once it turns ready, the whole synchronized start
        // is re-issued at the current playhead. Bounded, so an item that
        // FAILED (a corrupt file) does not keep the loop alive forever.
        startCheckTask?.cancel()
        startCheckTask = Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let model = self, model.isPlaying
                else { return }
                let now = model.currentTimelineSeconds
                guard now < model.schedule.length - model.frameDuration / 2
                else { return }
                let stalled = model.tiles.indices.filter {
                    model.isStalled($0, at: now)
                }
                if stalled.isEmpty { return } // everyone rolls (or froze at end)
                if stalled.contains(where: {
                    model.tiles[$0].player.status == .readyToPlay
                }) {
                    model.syncPlayers(at: now)
                }
            }
        }
    }

    func pause() {
        startCheckTask?.cancel()
        let now = currentTimelineSeconds
        for tile in tiles {
            tile.player.pause()
        }
        isPlaying = false
        // The pauses land a hair apart; a precise re-align parks every tile on
        // the exact frame the master stopped on.
        alignPaused(to: now)
        position.currentTime = now
    }

    /// Move the master playhead. Playing, the synchronized start is re-issued
    /// wholesale — the drift contract — and paused, every player is
    /// zero-tolerance seeked to its own offset position.
    func seek(to seconds: Double) {
        let target = min(max(0, seconds), schedule.length)
        position.currentTime = target
        if isPlaying {
            syncPlayers(at: target)
        } else {
            alignPaused(to: target)
        }
    }

    func skip(bySeconds seconds: Double) {
        seek(to: currentTimelineSeconds + seconds)
    }

    /// One frame either way. Stepping pauses first — a frame check is a
    /// paused activity, and stepping a rolling grid lands nowhere exact.
    func step(forward: Bool) {
        if isPlaying { pause() }
        seek(to: position.currentTime
            + (forward ? frameDuration : -frameDuration))
    }

    /// One master frame: the fastest rate among the takes, so a step is never
    /// coarser than what any tile can show.
    var frameDuration: Double {
        let fps = tiles.compactMap { $0.source.startTimecode?.fps }.max() ?? 25
        return 1 / Double(max(1, fps))
    }

    /// Tile label TC: the take's start TC advanced by its own clip position
    /// (the same arithmetic as the main player's readout in `+PlaybackInfo`).
    func tileTimecodeText(_ index: Int) -> String {
        let clip = clipSeconds(at: position.currentTime, tile: index)
        let source = tiles[index].source
        let fps = max(1, source.startTimecode?.fps ?? 25)
        // floor with an epsilon: the offset arithmetic leaves ~1e-13 of float
        // dust, and a bare floor turns 12.999… frames into 12 — a label one
        // frame behind the picture it sits on
        let frames = Int((clip * Double(fps) + 1e-6).rounded(.down))
        guard let start = source.startTimecode else {
            return Timecode(frameNumber: frames, fps: fps).description
        }
        return Timecode(frameNumber: start.frameNumber + frames, fps: fps,
                        isDropFrame: start.isDropFrame).description
    }
}

// MARK: - the sync itself

/// The machinery under the transport verbs: the shared-host-time start, the
/// paused re-align, and the three observers hanging off the anchor player.
/// Same file as the class — everything here reaches its private state.
extension SyncPlayModel {
    /// Seconds into tile `index`'s clip at master time `timelineSeconds`,
    /// clamped to the clip — the clamp IS the freeze-on-last-frame rule.
    func clipSeconds(at timelineSeconds: Double, tile index: Int) -> Double {
        min(max(0, timelineSeconds + schedule.offsets[index]),
            tiles[index].source.duration)
    }

    /// Footage tile `index` still has left at master time `timelineSeconds`.
    private func remaining(at timelineSeconds: Double, tile index: Int) -> Double {
        tiles[index].source.duration
            - clipSeconds(at: timelineSeconds, tile: index) - frameDuration / 2
    }

    /// The frame-honest start: one shared host time, every player told to be
    /// at its own clip position exactly then. Re-issued whole on every seek
    /// and rate change — nudging players individually is how drift creeps in.
    private func syncPlayers(at timelineSeconds: Double) {
        let hostStart = CMTimeAdd(
            CMClockGetTime(CMClockGetHostTimeClock()),
            CMTime(seconds: Self.startLeadSeconds, preferredTimescale: 600))
        for (index, tile) in tiles.enumerated() {
            let clip = clipSeconds(at: timelineSeconds, tile: index)
            guard remaining(at: timelineSeconds, tile: index) > 0 else {
                // nothing left in this take — park it on its final frame
                tile.player.pause()
                tile.player.seek(to: Self.time(clip),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
                continue
            }
            guard tile.player.status == .readyToPlay else {
                // setRate(_:time:atHostTime:) RAISES until the player is
                // ready. Park at the position; the recheck loop in `play`
                // re-issues the synchronized start the moment it can.
                tile.player.seek(to: Self.time(clip),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
                continue
            }
            tile.player.setRate(1, time: Self.time(clip), atHostTime: hostStart)
        }
    }

    /// Zero-tolerance park of every tile at its own position for a paused
    /// master playhead.
    private func alignPaused(to timelineSeconds: Double) {
        for (index, tile) in tiles.enumerated() {
            tile.player.seek(to: Self.time(clipSeconds(at: timelineSeconds,
                                                       tile: index)),
                             toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// The master playhead as the master player reports it right now (falls
    /// back to the last published position before the player is readable).
    var currentTimelineSeconds: Double {
        guard tiles.indices.contains(anchorIndex) else { return 0 }
        let raw = tiles[anchorIndex].player.currentTime().seconds
            - schedule.offsets[anchorIndex]
        guard raw.isFinite else { return position.currentTime }
        return min(max(0, raw), schedule.length)
    }

    /// The tile that plays longest in the master domain. By-start that is the
    /// longest clip; a TC-clamped window ends everywhere at once and any tile
    /// will do.
    private static func anchorIndex(for schedule: SyncPlaySchedule,
                                    sources: [Source]) -> Int {
        guard !sources.isEmpty else { return 0 }
        let spans = sources.enumerated().map { index, source in
            source.duration - schedule.offsets[index]
        }
        return spans.firstIndex(of: spans.max() ?? 0) ?? 0
    }

    private func applyAlignmentChange() {
        startCheckTask?.cancel()
        for tile in tiles {
            tile.player.pause()
        }
        isPlaying = false
        schedule = SyncPlaySchedule.compute(
            alignmentMode,
            startTimecodes: tiles.map(\.source.startTimecode),
            durations: tiles.map(\.source.duration))
        anchorIndex = Self.anchorIndex(for: schedule,
                                       sources: tiles.map(\.source))
        installObservers() // the master and the end boundary both moved
        position.currentTime = 0
        alignPaused(to: 0)
    }

    /// Set the monitoring level for the whole grid. Called by the controller on
    /// every level change, mute and un-mute — never by a view.
    func setVolume(_ level: Double) {
        volume = min(max(0, level), 1)
        applyAudioRouting()
    }

    /// One take audible, at the app's level. The mute flag stays the choice of
    /// WHICH take and the volume is the level of it: a zero level silences the
    /// grid without moving the speaker glyph off the take the operator picked.
    private func applyAudioRouting() {
        for (index, tile) in tiles.enumerated() {
            tile.player.isMuted = index != audibleIndex
            tile.player.volume = Float(volume)
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - observers

    /// Three ways the session learns time passed, all hanging off the master
    /// player: the 10 Hz position tick (which also runs the drift watchdog), a
    /// boundary observer at the exact master end (a TC-clamped window ends
    /// mid-clip, where no item notification exists), and the item's own
    /// did-play-to-end (by-start, where the master end IS the item end and a
    /// boundary at the last sample is not reliably fired).
    private func installObservers() {
        removeObservers()
        guard tiles.indices.contains(anchorIndex) else { return }
        let anchor = tiles[anchorIndex].player
        observedPlayer = anchor
        timeObserver = anchor.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.anchorTicked() }
        }
        let end = schedule.offsets[anchorIndex] + schedule.length
        if end > 0 {
            boundaryObserver = anchor.addBoundaryTimeObserver(
                forTimes: [NSValue(time: Self.time(end))], queue: .main
            ) { [weak self] in
                Task { @MainActor [weak self] in self?.reachedEnd() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            // Only WHICH item ended crosses to the main actor, never the
            // notification: it belongs to the thread that posted it, and the
            // check needs an identity, which is a value. `===` on the far side
            // asked the same question of the same two pointers.
            let ended = note.object.map { ObjectIdentifier($0 as AnyObject) }
            Task { @MainActor [weak self] in
                guard let self,
                      let ended,
                      self.tiles[self.anchorIndex].player.currentItem
                        .map(ObjectIdentifier.init) == ended
                else { return }
                self.reachedEnd()
            }
        }
    }

    private func removeObservers() {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let boundaryObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
        observedPlayer = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func anchorTicked() {
        // Paused, the playhead is owned by seek()/pause() — a tick that lands
        // after a paused seek would stomp the target with a stale player time.
        guard isPlaying else { return }
        let now = currentTimelineSeconds
        position.currentTime = now
        if now >= schedule.length - 0.001 {
            reachedEnd()
            return
        }
        resyncDrifted(at: now)
    }

    /// A tile paused with footage still owed to the master timeline — a start
    /// the player swallowed because its item was not ready. A player parked at
    /// (or a hair before) its own media end is NOT stalled: it froze on its
    /// last frame legitimately, and a file can run a frame short of the
    /// nominal duration the schedule was computed from.
    private func isStalled(_ index: Int, at timelineSeconds: Double) -> Bool {
        let player = tiles[index].player
        guard player.rate == 0,
              remaining(at: timelineSeconds, tile: index) > 0 else { return false }
        let actual = player.currentTime().seconds
        guard actual.isFinite else { return true }
        let itemEnd = player.currentItem?.duration.seconds ?? .nan
        if itemEnd.isFinite, actual >= itemEnd - frameDuration * 1.5 {
            return false
        }
        return true
    }

    /// The watchdog: a tile more than a frame away from where the master says
    /// it should be — or one that never started — gets its synchronized start
    /// re-issued. Host-clock slaving makes this a no-op in practice; it exists
    /// for the player that was not ready when the start was scheduled.
    private func resyncDrifted(at timelineSeconds: Double) {
        for (index, tile) in tiles.enumerated() where index != anchorIndex {
            guard tile.player.status == .readyToPlay,
                  remaining(at: timelineSeconds, tile: index) > 0 else { continue }
            let actual = tile.player.currentTime().seconds
            let expected = clipSeconds(at: timelineSeconds, tile: index)
            let drifted = tile.player.rate != 0 && actual.isFinite
                && abs(actual - expected) > frameDuration
            guard drifted || isStalled(index, at: timelineSeconds) else { continue }
            let hostStart = CMTimeAdd(
                CMClockGetTime(CMClockGetHostTimeClock()),
                CMTime(seconds: Self.startLeadSeconds, preferredTimescale: 600))
            let target = clipSeconds(at: timelineSeconds + Self.startLeadSeconds,
                                     tile: index)
            tile.player.setRate(1, time: Self.time(target),
                                atHostTime: hostStart)
        }
    }

    /// The master timeline ran out: everything pauses where it stands — the
    /// clips end parked on the window's last frame, and play means "again".
    private func reachedEnd() {
        guard isPlaying else { return }
        startCheckTask?.cancel()
        for tile in tiles {
            tile.player.pause()
        }
        isPlaying = false
        alignPaused(to: schedule.length)
        position.currentTime = schedule.length
    }
}
