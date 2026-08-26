import CaptureCore
import SwiftUI

/// Player card: TC, format, and the mode switch live right on it.
struct PlayerArea: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        PreviewView()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.08)))
            .overlay {
                if controller.isRecording, controller.viewerMode == .record {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.red.opacity(0.85), lineWidth: 3)
                }
            }
            .playerTopBadges()
            .overlay(alignment: .bottomTrailing) {
                // player fullscreen — bottom-right (in playback this button is in the transport)
                if controller.viewerMode == .record {
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
                    .help(L("fullscreen"))
                    .padding(8)
                }
            }
            .overlay {
                if controller.showAudioPanel {
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
                            controller.persistentAlert = nil
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
