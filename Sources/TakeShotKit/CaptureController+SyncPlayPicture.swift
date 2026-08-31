import CaptureCore
import CoreVideo
import Foundation

/// **What the mirrors show while the operator is comparing takes.**
///
/// The hardware monitor, the SDI output, NDI, SRT and every browser exist so
/// the director sees what the operator sees. During a sync-play comparison what
/// the operator sees is a GRID — and every one of those surfaces was showing
/// the single take parked underneath it instead, frozen on whatever frame it
/// was paused at when the comparison started. `startSyncPlay` deliberately does
/// not clear `playbackURL` (see `PlaybackEngine`), so the parked tap stayed
/// wired to the mirror slot and simply stopped delivering; `PlayoutFeeder` then
/// held its last frame, which is a stale picture that looks exactly like a
/// live one.
///
/// The fix is to compose the grid and send THAT, and the composition is not new:
/// `MultiviewComposer` already defines what a grid picture is for
/// `LivePicture.grid`, and this uses the same one rather than a second opinion
/// about tile layout, letterboxing and canvas. What it needed was one concept —
/// `MultiviewComposer.Pacing`, because a comparison's clock tile is not its
/// top-left tile and a PAUSED comparison has no clock at all. That is written up
/// at the composer.
///
/// **Nothing here exists while nobody is comparing, and nothing exists while a
/// comparison is on screen but nowhere else.** The composer is built when a
/// mirror appears under a grid and dropped when the last one goes — the same
/// discipline `MultiviewComposer` and the live-picture pool already follow, and
/// recomputed from the mirrors rather than counted, so nothing can drift.
extension CaptureController {
    /// Build or drop the composer that turns the comparison's tiles into the
    /// one buffer the viewer's mirrors take, and wire the tile taps to it.
    ///
    /// Called from `wireDisplayMirrors` alone, which is what keeps this from
    /// becoming a second answer to "who is watching": that function has already
    /// worked out whether there is a feeder, an NDI mirror or an encoder, and
    /// `handler` is the very closure it hands the other three sources.
    /// `handler` nil means nobody is taking the viewer's picture at all.
    func refreshSyncGridPicture(handler: (@Sendable (LiveFrame) -> Void)?) {
        guard let model = syncPlay, let handler else {
            clearSyncGridPicture()
            return
        }
        let picture = mirrors.syncGrid ?? SyncPlayGridPicture()
        if mirrors.syncGrid == nil {
            mirrors.syncGrid = picture
            // Weak, like the live grid's sink on its encoder: this runs on the
            // composer's queue and must not keep a picture the wiring has
            // already dropped alive by holding it.
            mirrors.syncGridComposer = MultiviewComposer { [weak picture] buffer, _ in
                picture?.publish(buffer)
            }
            // The pacing the model already knows about, pushed on every
            // transport verb from here on (`SyncPlayModel.gridPacing`).
            model.onGridPacingChange = { [weak self] in
                guard let self, let model = self.syncPlay else { return }
                self.mirrors.syncGridComposer?.setPacing(model.gridPacing)
            }
            // …and the tile clocks on every move of the master playhead, which
            // `SyncPlayModel.moveTimeline` is the single site of.
            model.onTimelineMove = { [weak self] in
                self?.pushSyncGridClocks()
            }
        }
        picture.setOnDisplayFrame(handler)
        mirrors.syncGridComposer?.setCameraCount(model.tiles.count)
        mirrors.syncGridComposer?.setPacing(model.gridPacing)
        pushSyncGridIdentities(model)
        pushSyncGridClocks()
        wireSyncGridTaps(model)
    }

    /// **Every tile says which take it is.**
    ///
    /// `.take`, never `.camera`, and that is the whole of what the composer
    /// needs to know about the difference: a comparison tile is a finished file
    /// with a name, nothing is writing it, and `TileIdentity.take` accordingly
    /// carries no lamp to leave switched off. The name is `Source.name`, which
    /// is the take's `displayName` — the same string `SyncPlayView` puts in the
    /// tile's own corner, so the director's monitor and the operator's screen
    /// cannot be reading two different names for one cell.
    ///
    /// Pushed at wiring alone: a comparison's tiles are fixed for the length of
    /// the session — selecting different takes builds a new `SyncPlayModel` and
    /// comes back through here — so there is no rename to chase.
    private func pushSyncGridIdentities(_ model: SyncPlayModel) {
        guard let composer = mirrors.syncGridComposer else { return }
        for (index, tile) in model.tiles.enumerated() {
            composer.setIdentity(.take(label: tile.source.name), camera: index)
        }
    }

    /// **Every tile's own position, which is the point of a comparison.**
    ///
    /// Each take counts from its OWN start timecode — that is what
    /// `SyncPlayModel.tileTimecodeText` computes, and it is why a comparison's
    /// clocks cannot be one clock drawn once: four takes aligned by timecode
    /// read the same, and four aligned by START read four different values for
    /// the same master second. Which is exactly the thing the director is
    /// trying to see.
    ///
    /// Costs nothing when nobody is mirroring: the composer is nil then, and
    /// `onTimelineMove` is not even installed.
    func pushSyncGridClocks() {
        guard let composer = mirrors.syncGridComposer,
              let model = syncPlay else { return }
        for index in model.tiles.indices {
            composer.setClock(model.tileTimecodeText(index), camera: index)
        }
    }

    /// Every tile's display-frame slot pointed at the composer.
    ///
    /// The tile taps are running for the SCREEN either way — each grid mount
    /// registers its own layer with its own tap — so what this adds to a
    /// comparison that is already on screen is one `dispatch_async` per tile per
    /// delivered frame, and the compose itself on the composer's own queue.
    /// Nothing here can hold up a tile: `offer` hops and returns, exactly as it
    /// does for a live board.
    ///
    /// **`.decorated`, and on a tile that is the same buffer as `.clean`.** The
    /// mirrors' rule is unchanged — they stand in for a cable to a director's
    /// monitor, so they take what the operator is looking at — and a tile has no
    /// assist stage and no viewing LUT for that rule to pick up. Written at
    /// `SyncPlayGridPicture`, including what changes if the tiles ever grow one.
    private func wireSyncGridTaps(_ model: SyncPlayModel) {
        let composer = mirrors.syncGridComposer
        // Captured per WIRING and not read per frame, exactly as
        // `wireDisplayMirrors` and `refreshMonitorTaps` do it and for the same
        // reason: the handler runs on a tap queue and the model is MainActor
        // state. Every tile is offered the MASTER's rate, not its own file's —
        // the grid is one picture on one timeline, and the encoder is built for
        // the rate that picture actually changes at.
        let rate = model.timelineFrameRate
        for (index, tile) in model.tiles.enumerated() {
            tile.tap.setOnDisplayFrame { [weak composer] frame in
                composer?.offer(frame[.decorated], camera: index,
                                framesPerSecond: rate)
            }
        }
    }

    /// Drop the composer and unwire the tiles. Safe to call with no comparison
    /// up — which is the ordinary case, and is why it costs an optional test.
    func clearSyncGridPicture() {
        for tile in syncPlay?.tiles ?? [] {
            tile.tap.setOnDisplayFrame(nil)
        }
        syncPlay?.onGridPacingChange = nil
        syncPlay?.onTimelineMove = nil
        mirrors.syncGrid?.setOnDisplayFrame(nil)
        mirrors.syncGridComposer?.stop()
        mirrors.syncGridComposer = nil
        mirrors.syncGrid = nil
    }

    // MARK: - leaving the comparison

    /// **Whether any frame source is going to publish to the mirrors now.**
    ///
    /// The mirrors HOLD their last frame — the board goes on showing what
    /// `PlayoutFeeder` last submitted, an NDI receiver keeps the last frame it
    /// got, a browser keeps the last one it decoded — so a source going quiet is
    /// not the same thing as a surface going blank. That is what made the parked
    /// take visible on a director's monitor for the length of a comparison, and
    /// it is the same trap one door along when the comparison ENDS.
    ///
    /// A named rule rather than a condition inside the exit, because it is a
    /// question about the session and the three answers are not obvious: record
    /// mode has the live signal, a RAW clip re-presents to its sinks, and the
    /// single player has a tap that will deliver its parked frame — but a
    /// comparison started with nothing open in the single player leaves NOTHING
    /// behind it, and that is a reachable state (select four takes from the
    /// panel without opening one first).
    var mirrorsHaveASource: Bool {
        if viewerMode == .record { return true }
        if syncPlay != nil { return true }
        if rawPlayer != nil { return true }
        return playbackURL != nil
    }

    /// **The comparison is over: put a picture back on the mirrors.**
    ///
    /// The whole of what "the parked take comes back" means on a hardware
    /// output, and it owns the rewiring because the ORDER is the content — the
    /// replacement has to be handed over on the far side of the slot changing
    /// hands, and which side depends on which of three cases this is.
    ///
    /// - **Nothing is parked underneath.** No source will ever publish, so the
    ///   last four-up frame would stay on the director's monitor. One black
    ///   frame goes out instead (`SyncPlayGridPicture.blank`) — and it has to go
    ///   BEFORE the rewiring, while the grid still has somewhere to hand it.
    /// - **A take is parked in the single player** (the ordinary way in — review
    ///   a take, then select four). Its tap is switched back on by
    ///   `updateTapRunning` and re-delivers the paused frame on its own next
    ///   tick, because being switched on drops the idle latch
    ///   (`PlaybackFrameTap.setRunning`).
    /// - **A RAW clip is parked.** The RAW engine has no poll: it publishes when
    ///   it decodes and when a sink mounts, so leaving it alone makes the
    ///   director's monitor depend on a SwiftUI remount happening. It does
    ///   happen — the player area really does rebuild its surface — but "the
    ///   picture comes back because a view was recreated" is not a rule anything
    ///   can hold on to, so the frame is pushed here instead, AFTER the slot is
    ///   back.
    func restoreMirrorsAfterComparison(_ grid: SyncPlayGridPicture?) {
        if !mirrorsHaveASource {
            grid?.blank()
        }
        wireDisplayMirrors()
        if let raw = rawPlayer, let parked = raw.lastBuffer {
            raw.present(parked)
        }
    }
}
