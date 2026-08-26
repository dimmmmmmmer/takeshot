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
/// The one control in the top row that wears NO plate (owner item 1). It does
/// not need one: a segmented control draws its own opaque chrome, so unlike a
/// bare text badge it is already legible over a blown highlight — the plate
/// behind it was a second background under a control that has one, and it read
/// as a slab. The other plates keep theirs and keep `PlayerChrome`'s shared
/// opacity; nothing here touches them.
///
/// What it does keep is the family's HEIGHT, so the switch still lines up with
/// the badges either side of it, and a drop shadow, which is what holds the
/// control's edge against a white frame now that there is no dark plate to do
/// it. The segment titles are localized and each language pays for its own —
/// the switch sits in the row's centered slot, so a locale-dependent width
/// moves nothing else.
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
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        .frame(height: PlayerChrome.height)
    }
}

/// Top chrome over the player: the identity row — TC menu (left), mode switch
/// (center), scopes/LUT/format (right) — and the compare bar on a row of its own
/// under it. Shared by the main window and the fullscreen windows (which hide
/// the mode switch).
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
            // Neither the framelines nor the exposure legend are here any
            // more: an overlay is drawn on the surface it is mounted on, so
            // both reached this window and neither the director's monitor nor
            // the hardware output (owner item 7). They are drawn into the frame
            // itself now — `AssistGuides` and `AssistLegend` — which is why
            // there is no legend view left to double the burned-in one.
            .overlay(alignment: .bottomLeading) { scopesOverlay }
            .overlay(alignment: .top) { topChrome }
    }

    /// The identity row on top, the compare bar — when there is one — on a row
    /// of its own underneath it.
    ///
    /// **Two rows, and that is the fix rather than the layout.** The compare bar
    /// used to share the centered slot with the mode switch, and every control
    /// in it is `.fixedSize()` (five-segment picker, wipe picker, gain picker,
    /// B-side menu, blend slider and its field) — so it cannot compress, it can
    /// only overflow. The comment here used to claim the row "compresses instead
    /// of covering the format badge"; what actually happened at the narrowest
    /// window was that the HStack came out wider than the picture and shoved the
    /// timecode off the left edge and the format badge off the right, which is
    /// the owner's "the timecode and the resolution get pushed apart by the menu
    /// and the playback settings".
    ///
    /// TC on the left and resolution on the right is the brief, so that row is
    /// the one that may not move: it now holds nothing that grows without a
    /// bound. The compare bar gets the FULL width of the picture instead of the
    /// ~340pt between the badge groups, which is more than it has ever needed,
    /// and it costs no extra height — it was already on a second line, inside
    /// the centered column.
    @ViewBuilder private var topChrome: some View {
        if chromeVisible {
            VStack(spacing: 4) {
                PlayerTopBadgeRow(showsModeSwitch: showsModeSwitch)
                compareBar
            }
            // vertical inset under the window buttons is already reserved by the
            // windowTopInset strip above the player
            .padding(8)
        }
    }

    /// Auto-hide: the chrome comes back while the pointer visits the top edge.
    /// The rule itself is `ChromeReveal`, shared with the two strips at the
    /// bottom of the same windows.
    private func hoverChanged(_ phase: HoverPhase) {
        guard autoHide else { return }
        // no height: a band measured from the TOP does not need one, which is
        // the whole reason this and the bottom strips did not look like the
        // same rule before
        let shows = ChromeReveal.shows(phase, edge: .top,
                                       band: ChromeReveal.topBand, in: 0)
        withAnimation(.easeOut(duration: 0.15)) { topVisible = shows }
    }

    @ViewBuilder private var scopesOverlay: some View {
        if controller.showScopesOverlay, !controller.scopesWindowOpen {
            ScopesPanel(scopes: controller.scopes, singleScope: true)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.12)))
                .frame(maxWidth: 860, maxHeight: 320)
                .padding(10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The compare bar, on its own full-width row (see `topChrome`).
    ///
    /// The condition is `controller.showsCompareBar` and not a copy of it: the
    /// row's reachability is a decision, and it is stated once beside the
    /// compare state it is about (`CaptureController+Compare`), where a test can
    /// ask it without a window.
    @ViewBuilder private var compareBar: some View {
        if controller.showsCompareBar {
            CompareControls()
        }
    }
}

/// The row the brief is about: TC on the left, the mode switch centered, the
/// signal badges on the right.
///
/// A view of its own rather than a property of the modifier, for the reason
/// `PlayerTimecodeBadge` is one — a property inside a `ViewModifier` cannot be
/// handed to `NSHostingView`, and this row's WIDTH is now a contract
/// (`ViewPlayerBadgeTests`): everything in it is bounded, so it fits the picture
/// at the narrowest window in both languages and cannot be pushed out of shape
/// by anything the operator switches on.
struct PlayerTopBadgeRow: View {
    @EnvironmentObject private var controller: CaptureController
    var showsModeSwitch = true

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            sideZone(alignment: .leading) { PlayerTimecodeBadge() }
            modeSwitch
            sideZone(alignment: .trailing) { rightBadges }
        }
    }

    /// One of the two flexible edge zones. Equal width by construction, which
    /// is what keeps the middle group centered.
    private func sideZone(alignment: Alignment,
                          @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    @ViewBuilder private var modeSwitch: some View {
        if showsModeSwitch {
            ViewerModeSwitch()
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
            PlayerFormatBadge()
        }
    }

    private var scopesBadge: some View {
        playerOverlayBadge {
            Button {
                // `toggleScopes`, not the overlay flag: the tint below reads
                // `showScopes`, and a press that could not reach half of what
                // that reading covers is a lit button that does nothing.
                controller.toggleScopes()
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
///
/// A free function rather than a `View` extension, so it does not pick up the
/// protocol's isolation and has to say it: everything it builds is view chrome
/// and every caller is a view body.
@MainActor
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
