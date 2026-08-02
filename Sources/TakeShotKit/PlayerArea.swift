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
                // above the transport bar when one is showing (marker toasts
                // must not land under the controls)
                let transportInset: CGFloat =
                    controller.viewerMode == .playback
                    && controller.playbackURL != nil ? 52 : 10
                if let error = controller.lastError {
                    PlayerToast(text: error, tint: .orange,
                                bottomInset: transportInset)
                } else if let notice = controller.lastNotice {
                    // marker toasts carry the marker's own color; everything
                    // else is the neutral confirmation green
                    PlayerToast(text: notice,
                                tint: controller.lastNoticeTint ?? .green,
                                bottomInset: transportInset)
                }
            }
            .animation(.easeOut(duration: 0.2), value: controller.lastError)
            .animation(.easeOut(duration: 0.2), value: controller.lastNotice)
            .padding(.horizontal, 12)
    }

    static func fpsText(_ fps: Double) -> String { playerFPSText(fps) }

    static func shortFormat(_ format: CaptureFormat) -> String {
        playerShortFormat(format)
    }
}

/// A toast over the bottom of the player.
///
/// The error and the notice are the same strip with a different tint, and they
/// were written out twice — including the `bottomInset`, which is what keeps a
/// toast from landing under the transport bar. A drifted copy of that number is
/// the take-failed message hidden behind the play button.
private struct PlayerToast: View {
    let text: String
    let tint: Color
    let bottomInset: CGFloat

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, bottomInset)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
