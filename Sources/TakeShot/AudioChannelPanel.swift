import AVFoundation
import CaptureCore
import SwiftUI

/// Large audio-channel panel over the center of the player: big meters with dB
/// numbers; clicking a channel toggles whether it's recorded.
struct AudioChannelPanel: View {
    @EnvironmentObject private var controller: CaptureController
    // meters update ~25/s — observed separately from the controller
    @ObservedObject var live: LiveSignal

    private let range: ClosedRange<Float> = -60...0

    /// Width by content: channels (16+8) + two dB scales.
    private var panelWidth: CGFloat {
        CGFloat(max(2, live.audioLevels.count)) * 30 + 56
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(L("audio_panel_title"))
                    .font(.headline)
                Spacer()
                Button {
                    controller.showAudioPanel = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            HStack(alignment: .bottom, spacing: 8) {
                dbScale
                ForEach(Array(live.audioLevels.enumerated()), id: \.offset) { index, level in
                    channelColumn(index: index, level: level)
                }
                dbScale
            }
            // live monitor: toggle + volume (first two enabled channels)
            HStack(spacing: 8) {
                Button {
                    controller.toggleMonitorMute()
                } label: {
                    Image(systemName: !controller.monitorOn
                          ? "speaker.slash"
                          : (controller.monitorVolume == 0
                             ? "speaker.slash.fill" : "speaker.wave.2.fill"))
                        .foregroundStyle(controller.monitorOn
                                         ? controller.accentColor : .secondary)
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.plain)
                .help(L("monitor_mute_help"))
                // never disabled: dragging the volume up wakes the monitor
                Slider(value: Binding(
                    get: { controller.monitorVolume },
                    set: { controller.monitorVolume = $0 }), in: 0...1)
            }
            .frame(maxWidth: panelWidth)
            Text(L("audio_panel_hint"))
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(maxWidth: panelWidth)
        }
        .padding(14)
        .frame(width: panelWidth + 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
        .shadow(radius: 18)
    }

    private func channelColumn(index: Int, level: Float) -> some View {
        let enabled = controller.isChannelEnabled(index)
        return VStack(spacing: 3) {
            Text(level <= -99 ? "-∞" : String(format: "%.0f", level))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.black.opacity(0.5))
                SegmentedMeterBar(level: level)
                    .animation(.linear(duration: 0.07), value: level)
            }
            .frame(width: 20, height: 170)
            .opacity(enabled ? 1 : 0.25)
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(enabled ? .primary : .tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.toggleAudioChannel(index) }
        .help(enabled ? L("channel_on_help") : L("channel_off_help"))
    }

    /// dB scale beside the meters (0 at the top, -60 at the bottom).
    private var dbScale: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 12) // offset for the dB number row above the bar
            VStack(alignment: .trailing, spacing: 0) {
                ForEach([0, -12, -24, -36, -48, -60], id: \.self) { mark in
                    Text("\(mark)")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity, alignment: mark == 0 ? .top : (mark == -60 ? .bottom : .center))
                }
            }
            .frame(height: 170)
            Spacer().frame(height: 14) // offset for the channel number below
        }
    }

    private func fraction(of level: Float) -> CGFloat {
        let clamped = min(max(level, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

/// Live-signal fullscreen window: image + a control footer revealed on hover at the bottom.
struct LiveFullscreenView: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var footerHover = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                LivePreviewLayerView(pipeline: controller.pipeline)
            }
            .playerTopBadges(showsModeSwitch: false)
            // exit — bottom-right, same place as the player's enter-fullscreen button
            .overlay(alignment: .bottomTrailing) {
                Button {
                    controller.toggleLiveFullscreen()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14))
                        .padding(8)
                        .background(.black.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(14)
            }
            .overlay(alignment: .bottom) {
                if footerHover {
                    BottomBarView()
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 18))
                        .padding(.horizontal, 60)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    withAnimation(.easeOut(duration: 0.15)) {
                        footerHover = point.y > geo.size.height - 150
                    }
                case .ended:
                    withAnimation(.easeOut(duration: 0.15)) { footerHover = false }
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Playback fullscreen window: image and transport only.
struct PlaybackFullscreenView: View {
    @EnvironmentObject private var controller: CaptureController

    @State private var transportHover = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                PlaybackContent()
            }
            .playerTopBadges(showsModeSwitch: false)
            .overlay(alignment: .bottom) {
                if transportHover {
                    TransportBar(player: controller.player)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 60)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    withAnimation(.easeOut(duration: 0.15)) {
                        transportHover = point.y > geo.size.height - 130
                    }
                case .ended:
                    withAnimation(.easeOut(duration: 0.15)) { transportHover = false }
                }
            }
        }
        .ignoresSafeArea()
    }
}
