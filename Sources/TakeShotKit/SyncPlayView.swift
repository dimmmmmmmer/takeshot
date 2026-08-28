import CaptureCore
import SwiftUI

/// The sync-play grid: 2 takes side by side, 3–4 in a 2×2, one master
/// transport under them. Mounted by `PreviewView` in the player area, in the
/// same slot `MulticamGrid` and `ComparePlaybackSplit` occupy — the single
/// `ViewerSurface` is simply not in the tree while this is.
struct SyncPlayView: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var model: SyncPlayModel

    var body: some View {
        VStack(spacing: 6) {
            SyncPlayHeader(model: model)
            SyncPlayGrid(model: model)
            SyncPlayTransportBar(model: model)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(8)
        .background {
            // Esc leaves the comparison, like every panel over the player
            EscapeKeyCatcher { controller.endSyncPlay() }
        }
    }
}

/// **The tiles themselves**, without the header plate or the transport.
///
/// Its own view because three surfaces draw the comparison and only one of them
/// wants the chrome around it: the main viewer mounts `SyncPlayView`, and the
/// fullscreen player and the director's external display mount this. That is
/// the shape `ComparePlaybackSplit` already has, and it exists for the same
/// reason — those two windows drew the take parked UNDER the comparison, which
/// reads as "the comparison is off" on the surface a client is watching.
///
/// Each tile's `PreviewMount` builds its own layer against that tile's own tap,
/// so a second mount of this view is a second layer per tile and never a shared
/// one (the preview display rule).
struct SyncPlayGrid: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var model: SyncPlayModel

    /// Grid columns for a tile count: two takes sit side by side in one row,
    /// three and four fill a 2×2.
    ///
    /// **Answered by the composer**, not by a rule of this view's own. The same
    /// comparison is drawn here as tiles and composed there as one picture for
    /// the hardware output and every browser, and two spellings of "how many
    /// across" is how the director's monitor comes to disagree with the
    /// operator's screen about which take is which. The composer is where a grid
    /// picture's arrangement is defined; this reads it.
    static func columns(for count: Int) -> Int {
        MultiviewComposer.columns(cameras: count)
    }

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 4),
            count: Self.columns(for: model.tiles.count))
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(model.tiles.enumerated()),
                    id: \.element.id) { index, tile in
                SyncPlayTile(model: model, index: index, tile: tile,
                             background: controller.playerBackground)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The grid's header plate: the alignment picker, the TC-fallback note and
/// the close button. Internal rather than folded into `SyncPlayView` so the
/// render harness can measure it in both languages — the fallback note is the
/// one localized string that rides the plate.
struct SyncPlayHeader: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var model: SyncPlayModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $model.alignmentMode) {
                Text(L("sync_align_start")).tag(SyncPlayAlignmentMode.byStart)
                Text(L("sync_align_tc")).tag(SyncPlayAlignmentMode.byTimecode)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .controlSize(.small)
            .help(L("sync_align_help"))
            if model.alignmentMode == .byTimecode, !model.schedule.usedTimecode {
                // asked for TC alignment, got the fallback — say so on screen
                Text(L("sync_tc_fallback"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                controller.endSyncPlay()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(L("sync_close"))
        }
        .playerChromePlate()
    }
}

/// One take of the comparison. Its `PreviewMount` builds its OWN
/// `MetalPreviewLayer` and registers it with this tile's own tap — one layer
/// per NSView, one tap per tile (the preview display rule).
private struct SyncPlayTile: View {
    @ObservedObject var model: SyncPlayModel
    let index: Int
    let tile: SyncPlayModel.Tile
    let background: Color

    var body: some View {
        ZStack {
            Rectangle().fill(background)
            PreviewMount.playback(tile.tap)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.white.opacity(0.12)))
        .overlay(alignment: .topLeading) {
            Text(tile.source.name)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            SyncPlayTileTimecode(model: model, index: index,
                                 position: model.position)
        }
        .overlay(alignment: .bottomTrailing) {
            speakerToggle
        }
    }

    /// The one audible take: the lit speaker marks it, a click on any other
    /// tile's speaker moves the audio there. One at a time, never a mix.
    private var speakerToggle: some View {
        Button {
            model.audibleIndex = index
        } label: {
            Image(systemName: model.audibleIndex == index
                  ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 11))
                .foregroundStyle(model.audibleIndex == index
                                 ? AnyShapeStyle(.white)
                                 : AnyShapeStyle(.secondary))
                .frame(width: 16, height: 14)
                .padding(4)
                .background(.black.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(L("sync_audio_help"))
        .padding(6)
    }
}

/// The tile's own running TC — observes only the 10 Hz playhead, so the tick
/// re-renders these labels and nothing else in the grid.
private struct SyncPlayTileTimecode: View {
    let model: SyncPlayModel
    let index: Int
    @ObservedObject var position: TransportPosition

    var body: some View {
        Text(model.tileTimecodeText(index))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.black.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
    }
}

/// The master transport: play/pause, ±5 s, frame steps, the scrubber and the
/// monitoring level, all driving every player through the model's synchronized
/// start. Icons and monospaced digits only — like the other two bars, the
/// localization lives in the tooltips.
///
/// The speaker is `TransportVolume`, the same control the single player's
/// transport carries, on the same one shared level: the tiles' own speakers say
/// WHICH take is audible, and this says how loud and whether at all. The grid
/// shipped with only the first of those, so a comparison could be moved between
/// takes and never turned down.
struct SyncPlayTransportBar: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var model: SyncPlayModel

    var body: some View {
        HStack(spacing: 10) {
            TransportPlayGroup(
                isPlaying: model.isPlaying,
                skipBack: { model.skip(bySeconds: -5) },
                togglePlay: { model.togglePlay() },
                skipForward: { model.skip(bySeconds: 5) })

            stepButton(forward: false)
            stepButton(forward: true)

            SyncPlayPositionControls(model: model, position: model.position)

            TransportTimeText(TransportBar.timeText(model.schedule.length))

            TransportVolume(live: controller.live)
                .help(L("playback_volume"))
        }
        .transportBarChrome()
    }

    private func stepButton(forward: Bool) -> some View {
        Button {
            model.step(forward: forward)
        } label: {
            Image(systemName: forward ? "forward.frame" : "backward.frame")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .help(L(forward ? "menu_step_forward" : "menu_step_back"))
    }
}

/// Readout + scrubber: the only part of the bar on the 10 Hz tick.
private struct SyncPlayPositionControls: View {
    let model: SyncPlayModel
    @ObservedObject var position: TransportPosition

    var body: some View {
        TransportTimeText(TransportBar.timeText(position.currentTime))

        Slider(value: Binding(
            get: { position.currentTime },
            set: { model.seek(to: $0) }),
            in: 0...max(model.schedule.length, 0.01))
            .controlSize(.small)
    }
}
