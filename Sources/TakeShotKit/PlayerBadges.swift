import AVFoundation
import CaptureCore
import SwiftUI

/// What a TC readout shows when there is no timecode to show. One string for
/// the player badge, the multicam tiles and the slate — "no signal" has to
/// read the same on every readout.
let timecodeFallbackText = "--:--:--:--"

/// TC readout that updates every frame — isolated so only this text
/// re-renders at frame rate (see LiveSignal). Internal, not private: the badge
/// that hosts it lives in `PlayerBadgeMenus.swift`.
struct LiveTimecodeText: View {
    @ObservedObject var live: LiveSignal
    let tint: Color

    var body: some View {
        Text(live.currentTimecode?.description ?? timecodeFallbackText)
            .font(.body)
            .monospacedDigit()
            .foregroundStyle(tint)
            .frame(width: 96, alignment: .leading)
    }
}

/// Playback position as timecode: file start TC + player time, at the file's fps.
struct PlaybackTimecodeText: View {
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

/// The one visual family the whole top chrome is built from.
///
/// It used to be two: the rec/playback switch and the compare bar were bare
/// AppKit controls on a 55%-black slab, the TC/format/icon badges were 72%-black
/// plates with a hairline and their own height. Side by side in one row that read
/// as two unrelated toolbars. Every plate now comes from `playerChromePlate`, so
/// a control added later cannot drift off the family by accident.
enum PlayerChrome {
    /// Outer height of every plate in the row. Driven by the tallest thing the
    /// row must hold — a `.small` segmented control with its focus ring — so the
    /// text badges and the icon buttons pad UP to it instead of each sitting at
    /// whatever its content happens to measure.
    static let height: CGFloat = 26
    static let cornerRadius: CGFloat = 7
    /// Room a plate leaves either side of its content.
    static let horizontalPadding: CGFloat = 8
    /// Opacity of the plate. Lightened from its original 72% (owner item 11 —
    /// the row read as black bars on the picture): still dark enough to keep
    /// white text legible over a blown highlight, light enough that the plates
    /// sit ON the image instead of covering it.
    static let backgroundOpacity: Double = 0.55
    static let borderOpacity: Double = 0.22
    static let borderWidth: CGFloat = 0.5
}

extension View {
    /// The plate every piece of top chrome sits on (see `PlayerChrome`).
    ///
    /// `horizontalPadding` is the one dimension a caller may tighten: the compare
    /// bar is a row of controls that carry their own insets, and the shared 8pt
    /// on top of those pushes it into the badge groups at the narrowest window.
    /// Material, radius and height are not parameters — those are the family.
    func playerChromePlate(
        horizontalPadding: CGFloat = PlayerChrome.horizontalPadding
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: PlayerChrome.cornerRadius)
        return foregroundStyle(.white) // readable on any player background
            .padding(.horizontal, horizontalPadding)
            .frame(height: PlayerChrome.height)
            .background(.black.opacity(PlayerChrome.backgroundOpacity), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(PlayerChrome.borderOpacity),
                                       lineWidth: PlayerChrome.borderWidth))
    }
}

/// Record/playback switch over the player.
///
/// The plate hugs the segmented control like every other plate in the family
/// (owner item 10): the old fixed 190pt look reserved dead air either side of
/// two short labels. The segment titles are localized and each language pays
/// for its own — the switch sits in the chrome row's centered slot, so a
/// locale-dependent width moves nothing else.
struct ViewerModeSwitch: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Picker("", selection: $controller.viewerMode) {
            Text(L("mode_record")).tag(CaptureController.ViewerMode.record)
            Text(L("mode_playback")).tag(CaptureController.ViewerMode.playback)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .playerChromePlate()
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

    private var timecodeBadge: some View { PlayerTimecodeBadge() }

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

    private var formatBadge: some View { PlayerFormatBadge() }
}

extension View {
    func playerTopBadges(showsModeSwitch: Bool = true,
                         autoHide: Bool = false) -> some View {
        modifier(PlayerTopBadgesModifier(showsModeSwitch: showsModeSwitch,
                                         autoHide: autoHide))
    }
}

/// Badge chrome shared by the player overlays — the same plate the mode switch
/// and the compare bar sit on (see `PlayerChrome`).
func playerOverlayBadge(@ViewBuilder content: () -> some View) -> some View {
    content().playerChromePlate()
}

func playerFPSText(_ fps: Double) -> String {
    fps.truncatingRemainder(dividingBy: 1) == 0
        ? String(Int(fps))
        : String(format: "%.2f", fps)
}

func playerShortFormat(_ format: CaptureFormat) -> String {
    "\(format.height)p\(playerFPSText(format.frameRate))"
}
