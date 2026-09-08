import CaptureCore
import SwiftUI

/// Player card: TC, format, and the mode switch live right on it.
struct PlayerArea: View {
    @EnvironmentObject private var controller: CaptureController

    /// **The bottom-left corner, as ONE row.**
    ///
    /// The REC label used to be an overlay of its own inside `PreviewView`,
    /// in this same corner. The eye is mounted on top of it here, so while a
    /// take rolled the eye sat over the words (owner: "подпись при реке
    /// накрывается значком глазика") — two overlays at one alignment stack,
    /// they do not make room for each other.
    ///
    /// A row cannot do that. And it belongs on THIS view rather than on the
    /// picture: the eye is the main window's control, and `PlayerArea` is the
    /// only surface that has one.
    ///
    /// Nothing to arbitrate in a clean feed, either: it takes the label away
    /// (`showsRecordingMark`) and leaves the dimmed eye, which is the one way
    /// back out of the mode.
    @ViewBuilder private var bottomLeftCorner: some View {
        HStack(spacing: 8) {
            CleanFeedButton()
            if controller.showsRecordingMark {
                // …and WHICH trigger rolled it. On the picture rather than in a
                // panel because a spurious roll has to be diagnosable by the
                // person who notices it, and what they are looking at is the
                // frame. The suffix is absent for a take with no recorded
                // trigger rather than guessed at.
                Label(controller.recBadgeText, systemImage: "record.circle.fill")
                    .font(.headline.bold())
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
    }

    var body: some View {
        PreviewView()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.08)))
            .overlay {
                if controller.showsRecordingMark {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.red.opacity(0.85), lineWidth: 3)
                }
            }
            .playerTopBadges()
            .overlay(alignment: .bottomTrailing) {
                // player fullscreen — bottom-right (in playback this button is in the transport)
                if controller.showsLiveFullscreenButton {
                    Button {
                        controller.toggleLiveFullscreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13))
                            .padding(6)
                            .background(.black.opacity(0.45),
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .controlHelp(L("fullscreen"))
                    .padding(8)
                }
            }
            // **The way out of a clean feed, and the way in** (owner: "в левом
            // нижнем углу нужна кнопка типа скрыть интерфейсные кнопки чтоб был
            // чистый вывод"). Bottom-left, mirroring the fullscreen button
            // opposite it and wearing the same plate.
            //
            // It is the ONE thing clean feed does not hide, at a quarter
            // opacity: a mode with no visible way back is a mode an operator
            // has to know a key for, and the key (⌃U) is the answer for the
            // person who set it up rather than for the one who finds it on.
            .overlay(alignment: .bottomLeading) { bottomLeftCorner }
            .overlay {
                if controller.showsAudioPanel {
                    AudioChannelPanel(live: controller.live)
                }
            }
            .overlay(alignment: .top) {
                if let alert = controller.persistentAlert {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.octagon.fill")
                        Text(alert)
                            .font(.caption.bold())
                            .lineLimit(2)
                        Button {
                            controller.dismissPersistentAlert()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.9),
                                in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 40)
                }
            }
            .overlay(alignment: .bottom) {
                if let plan = PlayerToastPlan.current(
                    error: controller.lastError, notice: controller.lastNotice,
                    noticeTint: controller.lastNoticeTint,
                    transport: controller.transportBarKind) {
                    PlayerToast(plan: plan)
                }
            }
            .animation(.easeOut(duration: 0.2), value: controller.lastError)
            .animation(.easeOut(duration: 0.2), value: controller.lastNotice)
            .padding(.horizontal, 12)
    }
}

/// What the player says over the bottom of the picture, and how far up.
///
/// Two decisions, both of which have gone wrong here before. WHICH message: an
/// error outranks a notice, because a take that failed matters more than the
/// marker that was just written, and a notice landing on top of a failure is
/// the operator not being told. HOW FAR UP: clear of the transport bar when
/// there is one, near the edge when there is not — the comment this replaces
/// said what a drifted copy of that number costs, "the take-failed message
/// hidden behind the play button", and then the number drifted anyway, because
/// it lived in a `let` inside an overlay closure where nothing could read it.
///
/// It asks `CaptureController.transportBarKind` now, which is the same answer
/// the bar itself is drawn from.
struct PlayerToastPlan: Equatable {
    let text: String
    let tint: Color
    let bottomInset: CGFloat

    /// Clear of a transport bar, and near the edge without one.
    static let insetOverTransport: CGFloat = 52
    static let insetOverPicture: CGFloat = 10

    /// nil when the player has nothing to say.
    static func current(
        error: String?, notice: String?, noticeTint: Color?,
        transport: CaptureController.TransportBarKind) -> PlayerToastPlan? {
        let inset = transport == .none ? insetOverPicture : insetOverTransport
        if let error {
            return PlayerToastPlan(text: error, tint: .orange, bottomInset: inset)
        }
        if let notice {
            // marker toasts carry the marker's own color; everything else is
            // the neutral confirmation green
            return PlayerToastPlan(text: notice, tint: noticeTint ?? .green,
                                   bottomInset: inset)
        }
        return nil
    }
}

/// A toast over the bottom of the player.
///
/// The error and the notice are the same strip with a different tint, and they
/// were written out twice. What each one SAYS is `PlayerToastPlan`.
private struct PlayerToast: View {
    let plan: PlayerToastPlan

    var body: some View {
        Text(plan.text)
            .font(.caption)
            .foregroundStyle(plan.tint)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, plan.bottomInset)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// **The way out of a clean feed, and the way in** (owner: "в левом нижнем углу
/// нужна кнопка типа скрыть интерфейсные кнопки чтоб был чистый вывод").
/// Bottom-left, mirroring the fullscreen button opposite it and wearing the
/// same plate.
///
/// It is the ONE thing clean feed does not hide, at a quarter opacity: a mode
/// with no visible way back is a mode an operator has to know a key for, and
/// the key (⌃U) is the answer for the person who set it up rather than for the
/// one who finds it on.
///
/// A view of its own so a render test can measure it: what the REC label beside
/// it needs to clear is this button's real width, and a number copied into the
/// test would be a number that stops being true.
struct CleanFeedButton: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Button {
            controller.toggleCleanFeed()
        } label: {
            Image(systemName: controller.cleanFeed ? "eye.slash" : "eye")
                .font(.system(size: 13))
                .padding(6)
                .background(.black.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .opacity(controller.cleanFeed ? 0.25 : 1)
        .controlHelp(controller.cleanFeed
                     ? L("clean_feed_show") : L("clean_feed_hide"))
    }
}
