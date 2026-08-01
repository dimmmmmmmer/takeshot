import AVFoundation
import CaptureCore
import SwiftUI

/// Transport: play/pause, ±5 s, scrubber, time, speed, loop, fullscreen.
///
/// The pieces it shares with `RawTransportBar` live in `TransportControls.swift`;
/// what is left here is what only the AVPlayer engine has — the speed menu, the
/// per-clip LUT switch and the volume slider.
struct TransportBar: View {
    let player: AVPlayer
    @EnvironmentObject private var controller: CaptureController
    /// The app's single transport (CaptureController.transport) — never a
    /// per-view @StateObject: this bar exists in more than one place at once.
    @ObservedObject var model: TransportModel

    var body: some View {
        HStack(spacing: 10) {
            TransportPlayGroup(
                isPlaying: model.isPlaying,
                skipBack: { model.skip(-5) },
                togglePlay: { model.togglePlay() },
                skipForward: { model.skip(5) })

            TransportPositionControls(model: model, position: model.position)

            TransportTimeText(controller.playbackTC(atSeconds: model.duration))

            Menu {
                ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                    Button("\(rate.formatted())×") { model.setRate(Float(rate)) }
                }
            } label: {
                Text("\(model.desiredRate.formatted())×")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 30)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("playback_speed"))

            TransportRangeControls(engine: model)

            MarkerButton()

            if controller.playbackFileHasBakedLUT {
                Image(systemName: "camera.filters")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(L("lut_baked_indicator"))
            } else if controller.lutPreviewOn {
                Button {
                    controller.playbackLUTSuppressed.toggle()
                } label: {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 11))
                        .foregroundStyle(controller.playbackLUTSuppressed
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(controller.accentColor))
                }
                .buttonStyle(.plain)
                .help(L("lut_playback_toggle"))
            }

            TransportVolume(live: controller.live)
                .help(L("playback_volume"))

            TransportFullscreenButton()
        }
        .transportBarChrome()
        // the transport is attached once, by the controller: this bar can be on
        // screen twice, and a disappearing copy must not tear down the
        // observers the other one is still using
        .onAppear { consumeReplayLoopRequest() }
        .onChange(of: controller.playbackURL) { _, _ in
            consumeReplayLoopRequest()
        }
    }

    private func consumeReplayLoopRequest() {
        if controller.replayLoopRequested {
            model.isLooping = true
            controller.replayLoopRequested = false
        }
    }

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// TC readout + scrubber: the only part of the bar that re-renders at 10 Hz.
private struct TransportPositionControls: View {
    @EnvironmentObject private var controller: CaptureController
    let model: TransportModel
    @ObservedObject var position: TransportPosition

    var body: some View {
        TransportTimeText(controller.playbackTC(atSeconds: position.currentTime))

        Slider(value: Binding(
            get: { position.currentTime },
            set: { model.seek(to: $0) }),
            in: 0...max(model.duration, 0.01))
            .controlSize(.small)
            .overlay {
                MarkerTicks(markers: controller.playbackMarkers,
                            duration: model.duration)
            }
            .overlay {
                RangeTicks(inPoint: model.inPoint, outPoint: model.outPoint,
                           duration: model.duration,
                           tint: controller.accentColor)
            }
    }
}

/// In/out loop bounds over the scrubber (display only).
private struct RangeTicks: View {
    let inPoint: Double?
    let outPoint: Double?
    let duration: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if duration > 0 {
                ForEach([inPoint, outPoint].compactMap { $0 },
                        id: \.self) { seconds in
                    Rectangle()
                        .fill(tint)
                        .frame(width: 2, height: 10)
                        .position(
                            x: geo.size.width
                                * min(1, max(0, seconds / duration)),
                            y: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Volume control observing only LiveSignal — dragging must not re-render
/// the whole transport/window (that read as slider lag).
///
/// Internal rather than private so a render test can pin its width across the
/// mute state; see `iconWidth`.
struct TransportVolume: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var live: LiveSignal

    /// Reserved for the speaker icon. `speaker.slash.fill` and
    /// `speaker.wave.2.fill` are neither the same width nor the same height, so
    /// without a fixed frame every mute/unmute re-laid the whole transport bar
    /// out around it — the controls to the right of it visibly jumped. Both
    /// dimensions take the larger variant, so neither overflows the frame.
    static let iconWidth: CGFloat = 16
    static let iconHeight: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            // The icon is the mute (owner item 5): the same one-click
            // `toggleMonitorMute` as the footer speaker and the ⌃A hotkey,
            // level restored on the next click. The slider stays inline.
            Button {
                controller.toggleMonitorMute()
            } label: {
                Image(systemName: live.muted || live.volume == 0
                      ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(live.muted
                                     ? AnyShapeStyle(.red)
                                     : AnyShapeStyle(.secondary))
                    .frame(width: Self.iconWidth, height: Self.iconHeight)
            }
            .buttonStyle(.plain)
            .help(L("monitor_mute_help"))
            Slider(value: Binding(
                get: { controller.playbackVolume },
                set: { controller.playbackVolume = $0 }), in: 0...1)
                .frame(width: 64)
                .controlSize(.mini)
        }
    }
}
