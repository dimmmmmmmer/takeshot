import CaptureCore
import SwiftUI

/// Preview: live, playback, and compare modes.
struct PreviewView: View {
    @EnvironmentObject private var controller: CaptureController

    /// The live signal's aspect — a shared compare container so frames of
    /// different resolutions (and the wipe) line up geometrically.
    static func liveAspect(_ format: CaptureFormat?) -> CGFloat {
        guard let format, format.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(format.width) / CGFloat(format.height)
    }

    /// What feeds the unified surface right now (stills go through the tap
    /// too — the same render/LUT/compare path as video).
    private var surfaceSource: ViewerSurface.Source {
        if controller.viewerMode == .record { return .live }
        guard let url = controller.playbackURL else { return .none }
        // the RAW engine claimed the clip (BRAW/DNG folder/R3D)
        if let raw = controller.rawPlayer, raw.url == url {
            return .raw(ObjectIdentifier(raw))
        }
        if CaptureController.rawExtensions.contains(
            url.pathExtension.lowercased()) { return .none }
        return .playback
    }

    var body: some View {
        // the image area stays the same between record and playback: the transport
        // is a translucent bottom overlay, not a row that squeezes the frame
        ZStack(alignment: .bottom) {
            GeometryReader { _ in
                ZStack {
                    Rectangle().fill(controller.playerBackground)
                    if controller.viewerMode == .record, controller.multicamOn,
                       !controller.extraChannels.isEmpty {
                        MulticamGrid()
                    } else if controller.viewerMode == .playback,
                              let sync = controller.syncPlay {
                        // 2–4 takes side by side, each tile its own tap and
                        // layer — the single ViewerSurface stays out of the
                        // tree, exactly like the two grid modes above/below
                        SyncPlayView(model: sync)
                    } else if controller.showsCompareSplit {
                        // the same split the fullscreen player and the external
                        // display mount, from the same view
                        ComparePlaybackSplit()
                    } else {
                        // ONE NSView/layer for live, playback video and RAW: the
                        // mode switch re-routes frames into the same surface, so
                        // rec и playback land on identical pixels by construction.
                        // The punch-in pan gesture used to hang off this surface,
                        // which is why it did nothing in the fullscreen windows —
                        // it lives on the shared mount now (playerTopBadges →
                        // punchInZoom).
                        ViewerSurface(controller: controller, source: surfaceSource)
                            // a click on the picture closes a panel floating
                            // over it; the punch-in pan lives on the shared
                            // mount (playerTopBadges → punchInZoom) and is a
                            // drag, so it never reads as this tap
                            .dismissesPlayerOverlays(controller)
                        if controller.viewerMode == .record {
                            LiveStatusOverlay()
                        } else if controller.playbackURL == nil {
                            VStack(spacing: 8) {
                                Image(systemName: "play.rectangle")
                                    .font(.system(size: 40))
                                Text(L("playback_pick_hint"))
                                    .font(.headline)
                            }
                            .foregroundStyle(.secondary)
                        } else if case .none = surfaceSource {
                            RawOpenFailedNotice() // RAW that failed to open
                        }
                        // the same overlay the fullscreen player and the
                        // external display mount, from the same view
                        CompareWipeOverlay()
                        // over the picture only while the eyedropper is armed;
                        // it draws and hit-tests nothing otherwise
                        ChromaPickOverlay()
                        // …and the same again for the taught REC indicator's box
                        VisualRecTeachOverlay()
                    }
                }
            }
            // which bar, if any, is `controller.transportBarKind` and not a
            // rule of this view's own: the toast over the picture has to clear
            // whatever is drawn here, and two spellings of it drifted
            switch controller.transportBarKind {
            case .video:
                TransportBar(player: controller.player, model: controller.transport)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(6)
            case .raw:
                if let model = controller.rawPlayer {
                    RawTransportBar(model: model)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(6)
                }
            case .none:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if controller.isRecording, controller.viewerMode == .record {
                // …and WHICH trigger rolled it. On the picture rather than in a
                // panel because a spurious roll has to be diagnosable by the
                // person who notices it, and what they are looking at is the
                // frame. The suffix is absent for a take with no recorded
                // trigger rather than guessed at.
                Label(controller.recBadgeText, systemImage: "record.circle.fill")
                    .font(.headline.bold())
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
    }
}

/// The draggable wipe seam, on whichever surface is drawing the player.
///
/// One view, mounted by all three of them — the main viewer, the fullscreen
/// player and the external display. It used to be written inline in
/// `PreviewView`, so the other two showed a seam nobody could move: the wipe is
/// composited into the picture upstream and travels everywhere, the handle did
/// not travel at all. The drag writes `controller.wipePosition`, which is what
/// the compositor reads, so moving it on any surface moves it on all of them.
///
/// Draws nothing at all when there is no wipe — cheaper than each caller
/// repeating the condition, and impossible for one of them to get wrong.
struct CompareWipeOverlay: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        if controller.showsWipeHandle {
            // the handle rides the same centered aspect-fit box the layer
            // letterboxes the composite into
            Color.clear
                .aspectRatio(controller.compareAspect, contentMode: .fit)
                .overlay { WipeHandle(live: controller.compareLive) }
        }
    }
}

/// Draggable compare wipe (line + handle, any direction).
///
/// Where the line goes and where a drag puts it are `CompareWipeGeometry`,
/// which states both over the same axis the compositor cuts on — see there for
/// why that had to leave this closure.
private struct WipeHandle: View {
    @EnvironmentObject private var controller: CaptureController
    /// Observed directly, so a drag re-runs THIS body and not the window's —
    /// passed in by the overlay, which has the controller to take it from.
    @ObservedObject var live: CompareLive

    private var axis: CompareCompositor.Axis {
        CaptureController.compareAxis(controller.wipeOrientation)
    }

    var body: some View {
        GeometryReader { geo in
            let (p1, p2) = CompareWipeGeometry.endpoints(
                position: live.wipePosition, in: geo.size, axis: axis)
            ZStack {
                Path { path in
                    path.move(to: p1)
                    path.addLine(to: p2)
                }
                .stroke(.white.opacity(0.9), lineWidth: 2)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(radius: 2)
                    .position(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                // Through the CONTROLLER, which pushes the new cut to the
                // compositor. The controller no longer publishes it — only
                // `CompareLive` does — so this wakes the handle and the tap
                // and nothing else.
                controller.wipePosition = CompareWipeGeometry.position(
                    at: value.location, in: geo.size, axis: axis)
            })
        }
    }
}

/// Live signal + status badges.
struct LivePreviewContent: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        ZStack {
            PreviewMount.live(controller.pipeline)
            LiveStatusOverlay()
        }
    }
}

/// Status text over the live image (no devices / no signal).
///
/// "No devices found" is the whole story only when the binary can SEE boards.
/// It used to be chosen by `backendAvailable`, which the demo source pinned to
/// true, so the alternative was unreachable and this surface told a stub build
/// the same thing it tells a loose cable. It asks `DeckLinkProbe.current` now: with
/// `.loaded` the old wording stands and now means what it says, and the other
/// three name themselves. The permanent home of that message is the Settings
/// device row (`DeckLinkNoticeRow`) — this is where the picture would be, and
/// nothing here is on screen while a source is feeding it.
struct LiveStatusOverlay: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        if !controller.isCapturing || controller.devices.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "cable.connector.slash")
                    .font(.system(size: 40))
                Text(DeckLinkProbe.current.noticeTitle
                     ?? L("no_devices_found"))
                    .font(.headline)
                if let detail = DeckLinkProbe.current.noticeDetail {
                    Text(detail)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        // wrap inside the picture rather than run off it; the
                        // player is at least ViewBudget.playerWidth wide
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
            }
            .foregroundStyle(.secondary)
        } else if !controller.signalPresent {
            Text(L("no_signal"))
                .font(.headline)
                .padding(8)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}
