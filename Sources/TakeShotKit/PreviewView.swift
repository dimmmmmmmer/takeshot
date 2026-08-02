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

    /// Whether to show the AVPlayer transport (video, not photo/RAW).
    /// The still-image list is the folder scanner's own — a second copy here
    /// would eventually drift, and a still on the drifted side gets a video
    /// transport drawn over a photo.
    private var showsTransport: Bool {
        guard controller.viewerMode == .playback, controller.syncPlay == nil,
              let url = controller.playbackURL
        else { return false }
        let ext = url.pathExtension.lowercased()
        return !CaptureController.imageExtensions.contains(ext)
            && !CaptureController.rawExtensions.contains(ext)
            && controller.rawPlayer?.url != url
    }

    /// RAW clips get the engine's own transport.
    private var showsRawTransport: Bool {
        guard controller.viewerMode == .playback, controller.syncPlay == nil,
              let url = controller.playbackURL
        else { return false }
        if controller.rawPlayer?.url == url { return true }
        return CaptureController.rawExtensions.contains(url.pathExtension.lowercased())
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
                    }
                }
            }
            if showsTransport {
                TransportBar(player: controller.player, model: controller.transport)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(6)
            } else if showsRawTransport, let model = controller.rawPlayer {
                RawTransportBar(model: model)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if controller.isRecording, controller.viewerMode == .record {
                Label(L("rec"), systemImage: "record.circle.fill")
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
                .overlay { WipeHandle() }
        }
    }
}

/// Draggable compare wipe (line + handle, any direction).
private struct WipeHandle: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        GeometryReader { geo in
            let (p1, p2) = endpoints(in: geo.size)
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
                let size = geo.size
                let raw: Double
                switch controller.wipeOrientation {
                case .vertical:
                    raw = value.location.x / size.width
                case .horizontal:
                    raw = value.location.y / size.height
                case .diagonal:
                    raw = (value.location.x + value.location.y)
                        / (size.width + size.height)
                }
                controller.wipePosition = min(1, max(0, raw))
            })
        }
    }

    private func endpoints(in size: CGSize) -> (CGPoint, CGPoint) {
        switch controller.wipeOrientation {
        case .vertical:
            let x = size.width * controller.wipePosition
            return (CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height))
        case .horizontal:
            let y = size.height * controller.wipePosition
            return (CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y))
        case .diagonal:
            let t = controller.wipePosition * (size.width + size.height)
            let p1 = CGPoint(x: max(0, t - size.height), y: min(t, size.height))
            let p2 = CGPoint(x: min(t, size.width), y: max(0, t - size.width))
            return (p1, p2)
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
struct LiveStatusOverlay: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        if !controller.isCapturing || controller.devices.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "cable.connector.slash")
                    .font(.system(size: 40))
                Text(controller.backendAvailable
                     ? L("no_devices_found")
                     : L("sdk_not_connected"))
                    .font(.headline)
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
