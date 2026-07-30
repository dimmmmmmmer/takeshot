import AVFoundation
import CaptureCore
import SwiftUI

/// TC readout that updates every frame — isolated so only this text
/// re-renders at frame rate (see LiveSignal).
private struct LiveTimecodeText: View {
    @ObservedObject var live: LiveSignal
    let tint: Color

    var body: some View {
        Text(live.currentTimecode?.description ?? "--:--:--:--")
            .font(.body)
            .monospacedDigit()
            .foregroundStyle(tint)
            .frame(width: 96, alignment: .leading)
    }
}

/// Playback position as timecode: file start TC + player time, at the file's fps.
private struct PlaybackTimecodeText: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var now = Date()
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(controller.playbackTimecodeText)
            .font(.body)
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 96, alignment: .leading)
            .onReceive(timer) { date in
                // paused TC is static — don't re-render the badge at 10 Hz
                if controller.player.rate != 0
                    || controller.rawPlayer?.isPlaying == true {
                    now = date
                }
            }
    }
}

/// Record/playback switch over the player.
///
/// `minWidth` and not `width`: the two segment titles are localized, and a
/// hard width clips whichever language needs more than English does — the
/// switch keeps its 190pt look wherever it fits and grows where it has to.
struct ViewerModeSwitch: View {
    /// The width the switch has in English; wider languages get what they need.
    static let idealWidth: CGFloat = 190

    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Picker("", selection: $controller.viewerMode) {
            Text(L("mode_record")).tag(CaptureController.ViewerMode.record)
            Text(L("mode_playback")).tag(CaptureController.ViewerMode.playback)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(minWidth: Self.idealWidth)
        .fixedSize()
    }
}

/// Top badges over the player: TC menu (left), mode switch + compare (center),
/// scopes/LUT/format (right). Shared by the main window and the fullscreen
/// windows (which hide the mode switch).
struct PlayerTopBadgesModifier: ViewModifier {
    @EnvironmentObject private var controller: CaptureController
    var showsModeSwitch = true
    /// Fullscreen: the top chrome hides until the pointer visits the top edge.
    var autoHide = false
    @State private var topVisible = true

    private var chromeVisible: Bool { !autoHide || topVisible }

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in hoverChanged(phase) }
            // punch-in pan/zoom lives on this mount because it is the ONE the
            // main player and both fullscreen windows share (see AssistZoom)
            .punchInZoom()
            .overlay { AssistFramelines() }
            .overlay { AssistLegendOverlay(fullscreen: autoHide) }
            .overlay(alignment: .bottomLeading) { scopesOverlay }
            .overlay(alignment: .top) { topChrome }
    }

    /// The timecode badge, the centered mode/compare group and the right-hand
    /// badges in ONE row.
    ///
    /// They used to be three independent corner overlays, and overlays do not
    /// know about each other: the centered group slid straight under the badges
    /// on either side as soon as it grew. It grows a lot — 306pt for the compare
    /// bar in playback, 386 with the wipe picker, 460 in blend mode, against the
    /// ~340pt the badge groups leave at the narrowest window. One HStack with two
    /// equally flexible side zones keeps the group exactly centered (both zones
    /// always get the same width) and makes overlap impossible: a group too wide
    /// for the row compresses instead of covering the format badge.
    @ViewBuilder private var topChrome: some View {
        if chromeVisible {
            HStack(alignment: .top, spacing: 8) {
                sideZone(alignment: .leading) { timecodeBadge }
                modeSwitch
                sideZone(alignment: .trailing) { rightBadges }
            }
            // vertical inset under the window buttons is already reserved by the
            // windowTopInset strip above the player
            .padding(8)
        }
    }

    /// One of the two flexible edge zones. Equal width by construction, which
    /// is what keeps the middle group centered.
    private func sideZone(alignment: Alignment,
                          @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    /// Auto-hide: the chrome comes back while the pointer visits the top edge.
    private func hoverChanged(_ phase: HoverPhase) {
        guard autoHide else { return }
        switch phase {
        case .active(let point):
            withAnimation(.easeOut(duration: 0.15)) {
                topVisible = point.y < 140
            }
        case .ended:
            withAnimation(.easeOut(duration: 0.15)) {
                topVisible = false
            }
        }
    }

    @ViewBuilder private var scopesOverlay: some View {
        if controller.showScopesOverlay, !controller.scopesWindowOpen {
            ScopesPanel(live: controller.live, singleScope: true)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.12)))
                .frame(maxWidth: 860, maxHeight: 320)
                .padding(10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var timecodeBadge: some View {
        playerOverlayBadge {
            Menu {
                detectionModePicker
                Divider()
                timecodeSourcePicker
            } label: {
                if controller.viewerMode == .playback {
                    PlaybackTimecodeText()
                } else {
                    LiveTimecodeText(
                        live: controller.live,
                        tint: controller.isRecording ? Color.red : Color.white)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("tc_menu_help"))
        }
    }

    private var detectionModePicker: some View {
        Picker(L("detection_mode"),
               selection: $controller.settings.detectionMode) {
            Text(L("mode_vanc")).tag(RecDetectionMode.vanc)
            Text(L("mode_auto")).tag(RecDetectionMode.auto)
            Text(L("mode_timecode")).tag(RecDetectionMode.timecodeRun)
            Text(L("mode_manual")).tag(RecDetectionMode.manual)
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var timecodeSourcePicker: some View {
        Picker(L("tc_source"), selection: Binding(
            get: {
                controller.settings.timecodeSource == "ltc"
                    ? 1 + (controller.settings.ltcChannel ?? 0)
                    : 0
            },
            set: { value in
                if value == 0 {
                    controller.settings.timecodeSource = nil
                } else {
                    controller.settings.timecodeSource = "ltc"
                    controller.settings.ltcChannel = value - 1
                }
            })) {
            Text(L("tc_source_rp188")).tag(0)
            ForEach(1...8, id: \.self) { channel in
                Text(L("tc_source_ltc", channel)).tag(channel)
            }
        }
        .pickerStyle(.menu)
    }

    private var modeSwitch: some View {
        VStack(spacing: 4) {
            if showsModeSwitch {
                ViewerModeSwitch()
            }

            if (controller.viewerMode == .playback
                && controller.playbackURL != nil)
                || (controller.viewerMode == .record
                    && controller.referencePinned) {
                CompareControls()
            }
        }
    }

    private var rightBadges: some View {
        HStack(spacing: 6) {
            scopesBadge
            multicamBadge
            playerOverlayBadge {
                AssistMenu()
            }
            playerOverlayBadge {
                LUTMenu()
            }
            formatBadge
        }
    }

    private var scopesBadge: some View {
        playerOverlayBadge {
            Button {
                controller.showScopesOverlay.toggle()
            } label: {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(controller.showScopes
                                     ? controller.accentColor : .white)
            }
            .buttonStyle(.plain)
            .help(L("scopes_toggle"))
        }
    }

    @ViewBuilder private var multicamBadge: some View {
        if controller.devices.filter({
            $0.id.hasPrefix("decklink:")
        }).count > 1 {
            playerOverlayBadge {
                Button {
                    controller.toggleMulticam()
                } label: {
                    Image(systemName: "rectangle.split.2x2")
                        .font(.system(size: 13))
                        .foregroundStyle(controller.multicamOn
                                         ? controller.accentColor
                                         : .white)
                }
                .buttonStyle(.plain)
                .help(L("multicam_toggle"))
            }
        }
    }

    private var formatBadge: some View {
        playerOverlayBadge {
            Menu {
                inputModePicker
                if controller.settings.forcedInputMode != nil {
                    Toggle(L("input_mode_rgb"), isOn: Binding(
                        get: { controller.settings.forcedInputRGB ?? false },
                        set: { controller.settings.forcedInputRGB = $0 }))
                }
            } label: {
                formatLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("input_mode"))
        }
    }

    private var inputModePicker: some View {
        Picker(L("input_mode"), selection: Binding(
            get: { controller.settings.forcedInputMode ?? "auto" },
            set: { controller.settings.forcedInputMode =
                $0 == "auto" ? nil : $0 })) {
            Text(L("input_mode_auto")).tag("auto")
            ForEach(controller.selectedDeviceInputModes,
                    id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var formatLabel: some View {
        Group {
            if controller.viewerMode == .playback,
               let info = controller.playbackFormatText {
                Text(info).monospacedDigit()
            } else if let format = controller.signalFormat {
                Text(playerShortFormat(format)).monospacedDigit()
            } else {
                Text(L("no_signal_short"))
            }
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.9))
    }
}

extension View {
    func playerTopBadges(showsModeSwitch: Bool = true,
                         autoHide: Bool = false) -> some View {
        modifier(PlayerTopBadgesModifier(showsModeSwitch: showsModeSwitch,
                                         autoHide: autoHide))
    }
}

/// Badge chrome shared by the player overlays.
func playerOverlayBadge(@ViewBuilder content: () -> some View) -> some View {
    content()
        .foregroundStyle(.white) // readable on any player background (incl. black)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
}

func playerFPSText(_ fps: Double) -> String {
    fps.truncatingRemainder(dividingBy: 1) == 0
        ? String(Int(fps))
        : String(format: "%.2f", fps)
}

func playerShortFormat(_ format: CaptureFormat) -> String {
    "\(format.height)p\(playerFPSText(format.frameRate))"
}
