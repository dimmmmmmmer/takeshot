import CaptureCore
import SwiftUI

// The footer's record-format controls: the destination folder and the codec that
// takes are written in, plus the DIM monitoring hold beside the volume. Split out
// of FooterBar.swift to keep both files inside the 400-line limit; the bar's own
// composition and the REC group live there.

extension CaptureController {
    /// Recording locks the codec and the record folder. The take's writer was
    /// created with the codec and is writing into the folder right now: neither
    /// change can reach the file being written, so a picker that accepted one
    /// would be telling the operator something untrue about the take. Changing
    /// the folder mid-take is worse — it resets the library the take is about to
    /// join.
    ///
    /// Declared with the controls that enforce it; asserted in the controller
    /// tests, which is where "is it really locked" has to be answered.
    var canChangeRecordingFormat: Bool { !isRecording }
}

/// Record folder. "Which drive am I shooting to" is a question with a wrong
/// answer, so it is in the footer rather than only in Settings; clicking opens
/// the same folder dialog Settings uses, and the tooltip carries the full path.
struct FooterFolderButton: View {
    @EnvironmentObject private var controller: CaptureController

    /// Most the folder name may take. Pinned in ViewFooterTests: the record
    /// folder's name is operator data and must not be able to resize the footer.
    static let nameWidth: CGFloat = 90

    var body: some View {
        // The tooltip hangs off the wrapper rather than off the button, so that
        // the "why is this locked" text is on a view that is NOT disabled — the
        // whole point of it is to be readable while the take is recording. Same
        // shape as the codec picker below, where the disabled part is the menu
        // inside the overlay. A single-child ZStack changes no geometry.
        ZStack {
            button
                .disabled(!controller.canChangeRecordingFormat)
        }
        .help(controller.canChangeRecordingFormat
              ? L("record_folder_help", controller.settings.destinationPath)
              : L("record_folder_locked_help"))
    }

    private var button: some View {
        Button {
            controller.chooseDestinationFolder()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                // The name is the first thing in the footer to give up its
                // width: at the narrowest window with 16 channels metering
                // there is no room for it, and the icon plus the tooltip still
                // answer the question. A truncated "Ta…" would not.
                ViewThatFits(in: .horizontal) {
                    Text(folderName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // a folder can be called anything ("2026-07-30_ProjectX_
                        // CamA"): without the cap the footer's ideal width grew
                        // with the name and pushed the naming fields off the bar
                        .frame(maxWidth: Self.nameWidth)
                    EmptyView()
                }
            }
            .opacity(controller.canChangeRecordingFormat ? 1 : 0.5)
        }
    }

    private var folderName: String {
        URL(fileURLWithPath: controller.settings.destinationPath).lastPathComponent
    }
}

/// Recording codec, in the footer: a whole day shot in Proxy because the picker
/// was a pane deep in Settings is the mistake this exists to prevent. Disabled
/// while a take is recording, with a tooltip that says why.
struct FooterCodecMenu: View {
    @EnvironmentObject private var controller: CaptureController

    /// The flavour name, for when the full one does not fit. These are what the
    /// codecs are called on set (Proxy / LT / 422 / HQ), not invented
    /// abbreviations, and H.264/HEVC are already short.
    static func shortName(_ codec: CaptureCodec) -> String {
        switch codec {
        case .proResProxy: return "Proxy"
        case .proResLT: return "LT"
        case .proRes422: return "422"
        case .proResHQ: return "HQ"
        case .h264, .hevc: return codec.rawValue
        }
    }

    var body: some View {
        // A borderless Menu sizes its label to whatever it is proposed, which
        // collapses a ViewThatFits label to its smallest form at any width. So
        // the label is laid out on its own and an invisible Menu is stretched
        // over it — the same trick the takes panel's export button uses.
        label
            .overlay {
                Menu {
                    ForEach(CaptureCodec.allCases) { codec in
                        Button {
                            controller.settings.codec = codec
                        } label: {
                            if codec == controller.settings.codec {
                                Label(codec.rawValue, systemImage: "checkmark")
                            } else {
                                Text(codec.rawValue)
                            }
                        }
                    }
                } label: {
                    Color.clear
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(!controller.canChangeRecordingFormat)
            }
            .help(controller.canChangeRecordingFormat
                  ? L("codec_footer_help", controller.settings.codec.rawValue)
                  : L("codec_locked_help"))
    }

    private var label: some View {
        HStack(spacing: 3) {
            ViewThatFits(in: .horizontal) {
                text(controller.settings.codec.rawValue)
                text(Self.shortName(controller.settings.codec))
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        // colour only: a disabled picker that also changed size would reflow the
        // whole footer the moment a take starts
        .opacity(controller.canChangeRecordingFormat ? 1 : 0.5)
        .foregroundStyle(.primary)
    }

    private func text(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11))
            .lineLimit(1)
    }
}

/// DIM, next to the volume: one click halves the monitoring level so the crew
/// can be heard over the take, the next puts it back exactly. Resolve's dim
/// button, including the part where it has to be obvious that it is engaged.
struct FooterDimButton: View {
    @EnvironmentObject private var controller: CaptureController
    /// Observes LiveSignal, not the controller: the dim state sits next to the
    /// volume and the meters, and toggling it must re-render this button only.
    @ObservedObject var live: LiveSignal

    var body: some View {
        Button {
            controller.toggleMonitorDim()
        } label: {
            Text(L("monitor_dim_label"))
                .font(.system(size: 9, weight: .heavy))
                // fixed frame: the highlight must not be able to resize the row
                .frame(width: 26, height: 18)
                .foregroundStyle(live.dimmed
                                 ? AnyShapeStyle(controller.accentColor)
                                 : AnyShapeStyle(.secondary))
                .background(live.dimmed
                            ? AnyShapeStyle(controller.accentColor.opacity(0.22))
                            : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(live.dimmed
                                  ? AnyShapeStyle(controller.accentColor)
                                  : AnyShapeStyle(Color.secondary.opacity(0.45)),
                                  lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!controller.canDimMonitoring)
        .help(live.dimmed ? L("monitor_dim_on_help") : L("monitor_dim_help"))
    }
}
