import SwiftUI

/// Footer: utilities on the left, meters centered in the left half, REC in the
/// center, naming fields on the right.
struct BottomBarView: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Button {
                                openWindow(id: "settings")
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 15))
                            }
                            .help(L("open_settings"))

                            Button {
                                openWindow(id: "vanc-monitor")
                            } label: {
                                Image(systemName: "waveform.badge.magnifyingglass")
                                    .font(.system(size: 15))
                            }
                            .help(L("vanc_open_help"))

                            NamingPresetMenu()

                            FooterMonitorButton(live: controller.live)

                            if controller.isCapturing {
                                FooterAudioMeters(live: controller.live)
                            }
                        }
                        .buttonStyle(.borderless)

                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: .infinity)

                    NamingFieldsView()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack(spacing: 12) {
                    Button {
                        controller.instantReplay()
                    } label: {
                        Image(systemName: "memories")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.borderless)
                    .disabled(controller.takes.isEmpty)
                    .help("\(L("instant_replay_help")) — \(hotkeys.combo(for: .instantReplay).display)")
                    RecordButton()
                    Button {
                        controller.grabFrame()
                    } label: {
                        Image(systemName: "camera")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.borderless)
                    .disabled(!controller.isCapturing && controller.playbackURL == nil)
                    .help(L("grab_frame"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Footer speaker: volume popover. In record mode it drives the live monitor,
/// in playback — the player volume (the transport has no volume of its own).
private struct FooterMonitorButton: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject private var live: LiveSignal
    @State private var showPopover = false

    init(live: LiveSignal) {
        self.live = live
    }

    private var isPlayback: Bool { controller.viewerMode == .playback }

    private var volume: Binding<Double> {
        Binding(get: { controller.monitorVolume },
                set: { controller.monitorVolume = $0 })
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: isPlayback
                  ? (live.volume == 0
                     ? "speaker.slash.fill" : "speaker.wave.2.fill")
                  : (controller.monitorOn
                     ? (live.volume == 0
                        ? "speaker.slash.fill" : "speaker.wave.2.fill")
                     : "speaker.slash"))
                .font(.system(size: 15))
                .foregroundStyle((isPlayback ? live.volume > 0
                                             : controller.monitorOn)
                                 ? controller.accentColor : .primary)
                // fixed BOTH dimensions: the symbol variants differ in size and
                // a changing anchor makes the volume popover jump around
                .frame(width: 24, height: 20)
        }
        .disabled(!isPlayback && !controller.isCapturing)
        .help(L("monitor_toggle"))
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VStack(spacing: 10) {
                TextField("", value: Binding(
                    get: { Int((volume.wrappedValue * 100).rounded()) },
                    set: { volume.wrappedValue = Double(min(100, max(0, $0))) / 100 }),
                    format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 44)
                Slider(value: volume, in: 0...1)
                    .frame(width: 100)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 28, height: 108)
            }
            .padding(12)
        }
    }
}

/// Naming-style picker right from the footer (same presets as in Settings).
struct NamingPresetMenu: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Menu {
            ForEach(SettingsView.namingPresets, id: \.key) { preset in
                Button {
                    controller.applyNamingPreset(preset)
                } label: {
                    if controller.settings.namingTemplate == preset.template {
                        Label(L(preset.key), systemImage: "checkmark")
                    } else {
                        Text(L(preset.key))
                    }
                }
            }
        } label: {
            Image(systemName: "textformat")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("naming_preset"))
    }
}

/// QuickTime-style record button.
struct RecordButton: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager

    var body: some View {
        Button {
            controller.toggleManualRecord()
        } label: {
            // like QuickTime: a light-grey disc; a red circle means ready to record,
            // a white square means recording
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 48, height: 48)
                if controller.isRecording {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                } else {
                    Circle()
                        .fill(Color(red: 0.96, green: 0.26, blue: 0.21))
                        .frame(width: 22, height: 22)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!controller.isCapturing)
        .help("\(controller.isRecording ? L("stop") : L("record")) — \(hotkeys.combo(for: .toggleRecord).display)")
        .animation(.easeInOut(duration: 0.15), value: controller.isRecording)
    }
}

/// Footer audio meters — observe LiveSignal so the ~25/s level updates
/// re-render only this small view, not the whole footer.
private struct FooterAudioMeters: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var live: LiveSignal
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if live.audioLevels.isEmpty {
            // audio stopped/never arrived: say so instead of vanishing
            Text(L("no_audio_short"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.25), in: Capsule())
        } else {
            Button {
                controller.showAudioPanel.toggle()
            } label: {
                AudioMeterView(
                    levels: live.audioLevels,
                    enabled: (0..<live.audioLevels.count)
                        .map { controller.isChannelEnabled($0) })
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .help(L("meters_click_help"))
        }
    }
}
