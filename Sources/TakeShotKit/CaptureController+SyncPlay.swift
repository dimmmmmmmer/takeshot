import AVFoundation
import CaptureCore
import Foundation

/// Entering and leaving sync-play — the mode itself lives in `SyncPlayModel`.
///
/// Sync-play mounts in the player area as its own mode branch of
/// `PreviewView`, beside `MulticamGrid` and `ComparePlaybackSplit`: the main
/// viewer's single re-routed `ViewerSurface` is simply not in the tree while
/// the grid is, so its routing is untouched and no per-mode surface is added
/// to it. A separate window was rejected for the same reason the A/B split is
/// not one — the transport hotkeys, the Esc convention and the operator's eyes
/// all live on the player area.
extension CaptureController {
    /// How many takes a sync-play session can hold.
    static let syncPlayTakeCounts = 2...4

    /// The selected takes, oldest first — the order the grid reads left to
    /// right, top to bottom (take 2 beside take 3, not the panel's
    /// newest-first). Foreign files in the selection are not takes and are
    /// simply not part of the session.
    var syncPlayTakes: [Take] {
        takes.filter { selectedItems.contains($0.url) }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    /// What the context menu's "Sync play" is enabled by: 2–4 takes selected.
    var canStartSyncPlay: Bool {
        Self.syncPlayTakeCounts.contains(syncPlayTakes.count)
    }

    /// Whether the grid on screen is showing `url` in one of its tiles.
    ///
    /// The grid is the one place in the app that holds a clip OPEN without
    /// `playbackURL` naming it, so a file leaving the session has to be asked
    /// about here as well — see `trashAndRelease`, whose release list is
    /// otherwise complete and did not have the grid on it.
    func syncPlayShows(_ url: URL) -> Bool {
        syncPlay?.tiles.contains { $0.source.url == url } ?? false
    }

    /// Open the selected takes side by side, transport-locked.
    func startSyncPlay() {
        guard canStartSyncPlay else { return }
        endSyncPlay()
        // The single-clip engines fall silent — the grid's own players carry
        // the picture and the one audible take now.
        player.pause()
        rawPlayer?.pause()
        let sources = syncPlayTakes.map {
            SyncPlayModel.Source(url: $0.url, name: $0.displayName,
                                 startTimecode: $0.startTimecode,
                                 duration: $0.durationSeconds)
        }
        let model = SyncPlayModel(sources: sources)
        // The grid opens at the level the operator is already listening at,
        // mute and DIM included — a comparison that starts at full level over a
        // muted monitor is the surprise this app exists not to produce.
        model.setVolume(live.volume)
        syncPlay = model
        viewerMode = .playback
        // The tap and the analyzers are pointed at whatever is on screen, and
        // what is on screen has just changed without the viewer MODE changing —
        // which is the path `applyViewerModeChange` covers and the reason these
        // are called here as well. Coming from playback (the ordinary way in:
        // review a take, then select four) the didSet does not fire at all.
        updateTapRunning()
        updateScopesRunning()
    }

    /// Back to normal playback (Esc, the close button, a mode switch, or a
    /// take opened in the single player).
    func endSyncPlay() {
        guard let model = syncPlay else { return }
        model.shutDown()
        syncPlay = nil
        // …and back: the single player's picture is the one on screen again, so
        // the tap and the analyzers have to be told before the first frame the
        // operator judges anything by.
        updateTapRunning()
        updateScopesRunning()
    }
}
