import Foundation

/// Which of the three engines is driving the picture under review, and whether
/// it is actually moving.
///
/// # Why this is one place and was five spellings
///
/// Playback is not one engine, it is three: the sync-play GRID (2–4 takes, each
/// tile its own `AVPlayer`), the RAW engine (`RawPlayerModel`, for BRAW/R3D/
/// CinemaDNG), and the single `AVPlayer` behind `TransportModel`. The transport
/// VERBS know that and all ask in the same order — `togglePlayPause`,
/// `skipPlayback` and `stepPlayback` each go grid → raw → single.
///
/// Five other places did not, and four of them were found by pulling on the
/// first:
///
/// | asked by | grid | raw | single |
/// | --- | --- | --- | --- |
/// | the transport verbs | yes | yes | yes |
/// | `playbackTimecodeText` | **no** | yes | yes |
/// | the TC badge's 10 Hz tick | **no** | yes | yes |
/// | `addMarker` / `removeNearestMarker` | **no** | — | — |
/// | `playbackPositionSeconds` | **no** | yes | yes |
///
/// `seekPlayback` is the one still asking raw → single, and it is left that
/// way deliberately: its only caller is `jumpToMarker`, which is menu-only and
/// gated to the single clip, and seeking a GRID is `SyncPlayModel.seek`, which
/// re-issues a synchronized start across every tile rather than moving one
/// player. Making it "handle" a grid would mean routing to a different verb,
/// not adding an arm.
///
/// **Every one of them was wrong over a grid, and the grid is not an exotic
/// state.** `startSyncPlay` pauses the single player and leaves it holding the
/// clip that was open before — it does not clear `playbackURL`, which is
/// exactly why `transportBarKind` has to guard `syncPlay == nil` before reading
/// it. So with a grid on screen the badge read `player.currentTime()` of a
/// PARKED player and showed the previous clip's timecode, frozen: a confident
/// number, belonging to a take that is not on screen, on the readout the brief
/// puts top left. The 10 Hz tick then declined to re-read it, because neither
/// `player.rate != 0` nor `rawPlayer?.isPlaying` is true while the grid's own
/// players carry the picture. The two marker methods went further and WROTE to
/// the parked take — see `addMarker`.
///
/// These are the third through sixth instances of one family. The shared-rule
/// wave found the transport bar and the toast asking different questions about
/// the same grid; `isReviewingClip` and `isReviewingSingleClip` are two more
/// rules that exist precisely because the grid has to be counted in one and out
/// of the other. The grid is the case every surface forgets, so the answer is
/// named once here and the surfaces read it.
///
/// # What a grid's timecode is
///
/// Nothing — deliberately, and that is the finding rather than a shortcut. A
/// grid is 2–4 takes with 2–4 different start timecodes running against ONE
/// master timeline, so there is no single timecode for the picture as a whole;
/// that is why the grid's own transport shows elapsed time
/// (`TransportBar.timeText`) rather than TC, and why each TILE carries its own
/// (`SyncPlayModel.tileTimecodeText`). The badge therefore shows
/// `timecodeFallbackText`, the same "there is no timecode here" string the live
/// badge, the multicam tiles and the slate all use. A readout that says it has
/// no number is worth more than one that states another clip's.
enum PlaybackEngine: Equatable {
    /// The sync-play grid: its own players, its own master timeline.
    case grid
    /// The RAW engine — BRAW, R3D or a CinemaDNG folder.
    case raw
    /// The single `AVPlayer`.
    case single

    /// Which engine owns the picture, from whether each of the two that can
    /// pre-empt the single player is present.
    ///
    /// The ORDER is the content: the grid outranks the RAW engine because
    /// `startSyncPlay` pauses both single-clip engines and leaves them loaded,
    /// so "a raw player exists" stays true underneath a grid and answering
    /// `.raw` there would be the same parked-engine mistake one door along.
    /// Written to match the routing in `CaptureController+Transport` arm for
    /// arm — `ControllerPlaybackEngineTests` holds the two against each other,
    /// because a precedence that agrees with the verbs today and not tomorrow
    /// is how this drifted in the first place.
    static func current(hasGrid: Bool, hasRawPlayer: Bool) -> PlaybackEngine {
        if hasGrid { return .grid }
        return hasRawPlayer ? .raw : .single
    }
}
