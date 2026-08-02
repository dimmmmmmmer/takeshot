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
            // whose channels these are: the board's embed or the USB source
            // (with its honest channel count) — the meters look the same
            // either way, and mistaking one for the other costs a take's sound
            Text(controller.audioSourceStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: panelWidth)
            // live monitor: toggle + volume (first two enabled channels)
            HStack(spacing: 8) {
                Button {
                    controller.toggleMonitorMute()
                } label: {
                    // same reading as the footer speaker: slashed FILL is
                    // silence (mute engaged, or the slider at zero), hollow
                    // slash is the live monitor path switched off
                    Image(systemName: live.muted || live.volume == 0
                          ? "speaker.slash.fill"
                          : (controller.monitorOn
                             ? "speaker.wave.2.fill" : "speaker.slash"))
                        .foregroundStyle(live.muted
                                         ? AnyShapeStyle(.red)
                                         : (controller.monitorOn
                                            ? AnyShapeStyle(controller.accentColor)
                                            : AnyShapeStyle(.secondary)))
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
            // The output device belongs where the volume is: plugging in
            // headphones between takes should not mean a trip into Settings.
            // Same device list and the same setting as the Settings pane.
            AudioOutputMenu()
                // centered on the panel, which is centered on the channel grid
                // (the dB scales flank it symmetrically) — owner item 6: the
                // device row sat flush left under a centered block of meters
                .frame(maxWidth: panelWidth, alignment: .center)
            // the panel is exactly as wide as the channel count makes it, so a
            // two-channel signal leaves less room than any translation of the
            // hint needs: wrap it instead of truncating a sentence to "Click a…"
            Text(L("audio_panel_hint"))
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
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
        .onTapGesture {
            // the channel mask is latched per take — flipping it mid-take
            // would desync the writer's fixed channel count
            guard !controller.isRecording else { return }
            controller.toggleAudioChannel(index)
        }
        .opacity(controller.isRecording ? 0.55 : 1)
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
        AudioMeterScale.fraction(of: level, in: range)
    }
}

/// Audio output picker for the channels panel — where the volume is adjusted, so
/// the device it comes out of is adjustable in the same place. Writes the same
/// setting as the Settings pane (`playbackOutputUID`: player and live monitor).
struct AudioOutputMenu: View {
    @EnvironmentObject private var controller: CaptureController
    /// Enumerated once when the panel appears, not in `body`: this panel
    /// re-renders with the meters (~25/s) and a CoreAudio device walk per frame
    /// is not free. A device plugged in while the panel is open shows up the
    /// next time it is opened.
    @State private var devices: [AudioOutputDevices.Device] = []

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "headphones")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Menu {
                Button {
                    controller.playbackOutputUID = nil
                } label: {
                    checked(L("system_default"),
                            on: controller.playbackOutputUID == nil)
                }
                ForEach(devices) { device in
                    Button {
                        controller.playbackOutputUID = device.uid
                    } label: {
                        checked(device.name,
                                on: controller.playbackOutputUID == device.uid)
                    }
                }
            } label: {
                Text(currentName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
        }
        .help(L("audio_output_help"))
        .onAppear { devices = AudioOutputDevices.list() }
    }

    /// What the selected device is called. A UID with no device behind it is
    /// worth saying out loud: monitoring is coming out of the system default
    /// instead, and silence from the wrong output is a call to the sound
    /// department that nobody needs.
    private var currentName: String {
        guard let uid = controller.playbackOutputUID else {
            return L("system_default")
        }
        return devices.first { $0.uid == uid }?.name ?? L("audio_output_missing")
    }

    @ViewBuilder private func checked(_ title: String, on: Bool) -> some View {
        if on {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// A strip that appears when the pointer nears the bottom of a fullscreen
/// window, and slides away again.
///
/// Both fullscreen surfaces carry one — the live window reveals the footer, the
/// playback window reveals the transport — and both had written out the
/// overlay, the hover test and the animation. The reveal HEIGHT is the part
/// that must not drift: it is how far up the operator has to move the mouse
/// before the controls appear, and two different answers on two windows reads
/// as one of them being broken.
private struct BottomHoverReveal<Strip: View>: ViewModifier {
    let height: CGFloat
    @Binding var shown: Bool
    @ViewBuilder let strip: () -> Strip

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .overlay(alignment: .bottom) {
                    if shown {
                        strip()
                            .padding(.horizontal, 60)
                            .padding(.bottom, 18)
                            .transition(.move(edge: .bottom)
                                .combined(with: .opacity))
                    }
                }
                .onContinuousHover { phase in
                    withAnimation(.easeOut(duration: 0.15)) {
                        switch phase {
                        case .active(let point):
                            shown = point.y > geo.size.height - height
                        case .ended:
                            shown = false
                        }
                    }
                }
        }
        .ignoresSafeArea()
    }
}

/// Live-signal fullscreen window: image + a control footer revealed on hover at the bottom.
struct LiveFullscreenView: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var footerHover = false

    var body: some View {
        Group {
            ZStack {
                Color.black
                PreviewMount.live(controller.pipeline)
            }
            .playerTopBadges(showsModeSwitch: false, autoHide: true)
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
        }
        .modifier(BottomHoverReveal(height: 150, shown: $footerHover) {
            BottomBarView()
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 18))
        })
    }
}

/// Playback fullscreen window: image and transport only.
struct PlaybackFullscreenView: View {
    @EnvironmentObject private var controller: CaptureController

    @State private var transportHover = false

    var body: some View {
        Group {
            ZStack {
                Color.black
                // A/B is a split of two surfaces; wipe and blend arrive already
                // composited in the one picture PlaybackContent draws.
                if controller.showsCompareSplit {
                    ComparePlaybackSplit()
                } else {
                    PlaybackContent()
                }
                // …but the seam the wipe composited in is only draggable where
                // the handle is mounted, and this window had none.
                CompareWipeOverlay()
            }
            .playerTopBadges(showsModeSwitch: false, autoHide: true)
        }
        .modifier(BottomHoverReveal(height: 130, shown: $transportHover) {
            TransportBar(player: controller.player, model: controller.transport)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        })
    }
}
