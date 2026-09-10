import SwiftUI

/// Footer: only what an operator touches or reads while the camera is rolling —
/// record folder, codec, naming style, monitoring (volume + DIM) and the meters
/// on the left, REC dead center, the naming fields on the right.
///
/// Settings, the VANC monitor and the offload copy used to sit here as well.
/// They are setup, not shooting, and they live in a row of their own under the
/// takes panel now (`PanelUtilityButtons`): at the app's minimum window width
/// the footer has around 290pt on each side of the record button, and the codec
/// and the destination folder — the two things a whole day can be shot wrong
/// on — need that space more than a gear icon does.
struct BottomBarView: View {
    @EnvironmentObject private var controller: CaptureController

    /// Half of the centered REC group, plus the air either side of it.
    ///
    /// The groups are in the same ZStack as the record button and know nothing
    /// about it, so without a reserved gap a group that grows slides UNDER the
    /// button instead of stopping short of it. Pinned against the real group
    /// width — plus `centerAir` — in `ViewFooterTests`.
    static let centerReserve: CGFloat = 64
    /// What the reserve has to leave over the record group's own half.
    ///
    /// It used to be whatever was left of a round 60, and the arithmetic had
    /// run out: the REC group measures 100pt, so the reserve bought 10pt of
    /// air — and only the LEFT group ever saw it, because the naming block had
    /// no reserve at all. Measured at the narrowest window the naming block's
    /// first caption landed ONE POINT from the grab button (owner: "вот
    /// видишь там где вписывать имя камеры липнет к реку точнее к кнопкам
    /// рядом с ним"). Both sides reserve it now, and the number is stated
    /// rather than left over.
    static let centerAir: CGFloat = 14

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // **Both halves reserve the middle, and the halves touch.**
                //
                // The 8pt that used to sit between them straddled the centre
                // line, so it was air the record button was already standing
                // in — while the naming block, which has no reserve of its
                // own, spent it reaching further in. Zero here and the reserve
                // on each side is one statement of the same gap, measured from
                // the centre where the button actually is.
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        FooterShootingControls()
                        Spacer(minLength: Self.centerReserve)
                    }
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 0) {
                        Spacer(minLength: Self.centerReserve)
                        NamingFieldsView()
                    }
                    .frame(maxWidth: .infinity)
                }
                FooterCenterControls()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The footer's left-hand group. Its own view so the render tests can ask
/// whether it still fits beside the record button — the whole footer's width
/// says nothing about that, because the two are stacked, not laid out in a row.
struct FooterShootingControls: View {
    @EnvironmentObject private var controller: CaptureController

    /// **The gap between two icons, and the slack a MENU adds to it.**
    ///
    /// The five controls do not agree about their own padding — a menu carries
    /// a disclosure and about 5pt of trailing space after it that a bare glyph
    /// button does not — so one spacing produced four different gaps. Measured
    /// as ink at 12, 17, 18 and 8 points (owner: "подвинь в нав баре внизу
    /// слева значки покучнее друг к другу, там отступы чет великоваты").
    ///
    /// The menus give their slack back and the spacing carries the rhythm, so
    /// every gap in the row is the same 8-9pt and the row is 26pt narrower
    /// than it was. `theShootingIconsShareOneRhythm` measures the ink, not
    /// these numbers: what an operator sees is the distance between glyphs.
    static let iconSpacing: CGFloat = 2
    static let menuTrailingSlack: CGFloat = 5

    var body: some View {
        HStack(spacing: Self.iconSpacing) {
            // The stream badges used to be here. They are beside the timecode
            // now (owner: "в нижнем баре уже и так места нет") — see
            // `PlayerTopBadgeRow`.
            FooterFolderButton()
            // The folder and the codec are icon-only (owner item 3) — their
            // names live in the tooltips — so the meters are the one thing left
            // that gives up width when the window is narrow (5pt → 3pt bars).
            FooterCodecMenu()
                .padding(.trailing, -Self.menuTrailingSlack)
            NamingPresetMenu()
                .padding(.trailing, -Self.menuTrailingSlack)
            FooterMonitorButton(live: controller.live)
            FooterDimButton(live: controller.live)
            if controller.isCapturing {
                FooterAudioMeters(live: controller.live)
                    .layoutPriority(1)
            }
        }
        .buttonStyle(.borderless)
    }
}

/// Instant replay, REC, grab — dead center, as in the brief.
struct FooterCenterControls: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager

    var body: some View {
        // Tight around the record button: these two ACT on it — the last take
        // and a frame of what it is recording — and at 12pt they read as three
        // separate controls with the naming block crowded against them (owner:
        // "кнопку стилл шота и реплея последнего тейка поближе прицепить к
        // кнопке река, иначе ощущение что справа где поля ввода воздуха мало").
        HStack(spacing: 6) {
            Button {
                controller.instantReplay()
            } label: {
                Image(systemName: "memories")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .disabled(!controller.hasTakes)
            .controlHelp("\(L("instant_replay_help")) — \(hotkeys.combo(for: .instantReplay).display)")
            RecordButton()
            Button {
                controller.grabFrame()
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .disabled(!controller.canGrabFrame)
            .controlHelp(L("grab_frame"))
        }
    }
}

/// Footer speaker, split in two (owner item 5). ONE click on the icon is the
/// full mute — the same `toggleMonitorMute` the ⌃A hotkey and the audio panel's
/// speaker call, level restored exactly on the next click — because "kill the
/// sound NOW" must not be behind a popover. The volume popover the click used
/// to open lives on the chevron beside the icon. In record mode the control
/// drives the live monitor, in playback — the player volume (one shared level).
///
/// What the icon SHOWS is `MonitorSpeaker`, shared with the audio panel and the
/// transport bar: the level as a wave count, red for silence however it was
/// reached.
private struct FooterMonitorButton: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var hotkeys: HotkeyManager
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

    /// Symbol and colour in one reading, shared with the audio panel and the
    /// playback transport — see `MonitorSpeaker` for the rule and why red means
    /// silence rather than "the mute button specifically".
    private var speaker: MonitorSpeaker {
        MonitorSpeaker.reading(muted: live.muted, volume: live.volume,
                               monitorOn: controller.monitorOn,
                               isPlayback: isPlayback)
    }

    /// Red for silence, the accent for a monitor that is doing its job — the
    /// same accent the DIM badge beside it lights with when engaged.
    private var speakerTint: AnyShapeStyle {
        speaker.isSilent
            ? AnyShapeStyle(.red) : AnyShapeStyle(controller.accentColor)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                controller.toggleMonitorMute()
            } label: {
                Image(systemName: speaker.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(speakerTint)
                    // fixed BOTH dimensions: the symbol variants differ in size
                    // — and there are five of them now, one per rung of the
                    // level ladder — so without this the row would shuffle on
                    // every drag of the volume slider, not just on a mute
                    .frame(width: 24, height: 20)
            }
            .disabled(!controller.canMonitorAudio)
            .controlHelp("\(L("monitor_mute_help")) — \(hotkeys.combo(for: .toggleMonitorMute).display)")

            Button {
                showPopover.toggle()
            } label: {
                FooterDisclosure()
                    .frame(width: 11, height: 20)
            }
            .disabled(!controller.canMonitorAudio)
            .controlHelp(L("monitor_volume_help"))
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
}

/// **The mark every footer control that opens something wears.**
///
/// Three controls in that row open something — the codec menu, the naming
/// menu and the volume popover — and each drew its own mark: the two menus
/// took AppKit's own indicator, a chevron pointing DOWN, while the volume
/// drew a 7pt chevron pointing UP because its popover rises. Side by side
/// that reads as three different kinds of control (owner: "стрелочка вверх у
/// звука отличается от стрелочек вниз у соседних иконок; давай у всех
/// стрелочки вверх сделаем и пусть они будут одинаковые").
///
/// UP for all three, and it is the honest direction: the footer is at the
/// bottom of the window, so everything these open opens upward.
struct FooterDisclosure: View {
    var body: some View {
        // The glyph and its size are stated once, in `FooterMarkedSymbol` —
        // the menus beside this one bake the same two into their images,
        // because a composed label does not survive `.borderlessButton`.
        Image(systemName: FooterMarkedSymbol.mark)
            .font(.system(size: FooterMarkedSymbol.markSize, weight: .semibold))
            .foregroundStyle(.secondary)
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
                    if controller.settings.naming.namingTemplate == preset.template {
                        Label(L(preset.key), systemImage: "checkmark")
                    } else {
                        Text(L(preset.key))
                    }
                }
            }
        } label: {
            Image(nsImage: FooterMarkedSymbol.image("textformat", size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlHelp(L("naming_preset"))
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
        // **The name, not only the tooltip.** A disc and a square announce
        // themselves to VoiceOver as "button" — see `controlHelp`.
        .controlHelp("\(controller.isRecording ? L("stop") : L("record")) "
            + "— \(hotkeys.combo(for: .toggleRecord).display)")
        .animation(.easeInOut(duration: 0.15), value: controller.isRecording)
    }
}

/// Footer audio meters — observe LiveSignal so the ~25/s level updates
/// re-render only this small view, not the whole footer.
private struct FooterAudioMeters: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var live: LiveSignal

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
