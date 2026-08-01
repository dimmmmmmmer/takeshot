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
/// the same folder dialog Settings uses. Icon only (owner item 3): a folder can
/// be called anything ("2026-07-30_ProjectX_CamA") and the name ate the
/// footer's width, so the tooltip carries the full path instead — in the locked
/// state too, because the icon is then the only folder readout the footer has.
struct FooterFolderButton: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        // The tooltip hangs off the wrapper rather than off the button, so that
        // the "why is this locked" text is on a view that is NOT disabled — the
        // whole point of it is to be readable while the take is recording. Same
        // shape as the codec picker below. A single-child ZStack changes no
        // geometry.
        ZStack {
            button
                .disabled(!controller.canChangeRecordingFormat)
        }
        .help(controller.canChangeRecordingFormat
              ? L("record_folder_help", controller.settings.destinationPath)
              : L("record_folder_locked_help", controller.settings.destinationPath))
    }

    private var button: some View {
        Button {
            controller.chooseDestinationFolder()
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .opacity(controller.canChangeRecordingFormat ? 1 : 0.5)
        }
    }
}

/// Recording codec, in the footer: a whole day shot in Proxy because the picker
/// was a pane deep in Settings is the mistake this exists to prevent. Icon only
/// (owner item 3): the name ("Apple ProRes 422 Proxy") ate the footer's width,
/// so the tooltip names the codec instead — in the locked state too, because
/// while a take records the tooltip is the only codec readout the footer has.
/// Disabled while a take is recording, and the tooltip also says why.
struct FooterCodecMenu: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        // The tooltip hangs off the wrapper rather than off the menu, so the
        // "which codec / why locked" text is on a view that is NOT disabled —
        // the whole point of it is to be readable while the take is recording.
        // Same shape as the folder button above.
        ZStack {
            menu
                .disabled(!controller.canChangeRecordingFormat)
        }
        .help(controller.canChangeRecordingFormat
              ? L("codec_footer_help", controller.settings.codec.rawValue)
              : L("codec_locked_help", controller.settings.codec.rawValue))
    }

    private var menu: some View {
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
            HStack(spacing: 3) {
                Image(systemName: "film.stack")
                    .font(.system(size: 13))
                // the chevron is what says "picker, not readout" once the
                // codec name is gone from the bar
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            // colour only: a disabled picker that also changed size would
            // reflow the whole footer the moment a take starts
            .opacity(controller.canChangeRecordingFormat ? 1 : 0.5)
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
