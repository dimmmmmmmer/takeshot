import CaptureCore
import SwiftUI

/// The digital slate window: a fullscreen timecode + scene/take card to point
/// a camera (or a phone held up to video village) at. See `SlateModel` for
/// what it shows and the display-only contract.
struct SlateWindowView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        SlateView(model: controller.slate, live: controller.live)
            .ignoresSafeArea(.container, edges: .top)
            // The window's own chrome, styled like the main window's and the
            // scopes window's — buttons over the content, no title strip. In
            // system fullscreen (the green button) the buttons hide with the
            // menu bar, leaving nothing but the slate face on the display.
            .monolithicWindowChrome()
    }
}

/// The slate face itself: near-black, a giant running timecode and the card of
/// what the rolling (or next) take is named. Dark-on-dark by design — unlike
/// the rest of the app it does not follow the theme, because its whole job is
/// to be read by a camera meters away.
struct SlateView: View {
    @ObservedObject var model: SlateModel
    /// Observed separately so the ~25/s TC ticks re-render this face without
    /// the model having to republish them (same split as the player badge).
    @ObservedObject var live: LiveSignal

    /// The face never goes fully black: a camera framing up in a dark room
    /// still has to see WHERE the slate is.
    private static let face = Color(white: 0.04)
    /// The hold color — distinct from both the white run and the red REC, so
    /// a frozen readout cannot be mistaken for a live one on the footage.
    private static let hold = Color(red: 1.0, green: 0.72, blue: 0.1)

    var body: some View {
        GeometryReader { geo in
            // Everything scales off one unit so the face keeps its proportions
            // from a laptop corner to a wall of video village. Height-capped:
            // a squat window must not push the card off the bottom.
            let unit = min(geo.size.width, geo.size.height * 16 / 9)
            ZStack {
                Self.face
                VStack(spacing: unit * 0.03) {
                    takeHeader(unit: unit)
                    timecodeReadout(unit: unit)
                    card(unit: unit)
                    Text(L("slate_sync_hint"))
                        .font(.system(size: max(9, unit * 0.014)))
                        .foregroundStyle(.white.opacity(0.25))
                }
                .padding(unit * 0.04)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.flashVisible {
                    Color.white
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.fireSync() }
        .background(spaceKey)
        // dark whatever the app's appearance is — the slate is not themed
        .environment(\.colorScheme, .dark)
    }

    /// Space fires the sync flash while the slate window is key — and only
    /// then: a key equivalent inside a window's own view tree is never offered
    /// to any other window, so the transport's Space stays the transport's.
    private var spaceKey: some View {
        Button(action: model.fireSync) { EmptyView() }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.plain)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// REC + the take being written, or NEXT + what the next take will be
    /// named — one `pendingTakeName` behind both (see `SlateModel.takeName`).
    private func takeHeader(unit: CGFloat) -> some View {
        HStack(spacing: unit * 0.015) {
            if model.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: unit * 0.024, height: unit * 0.024)
                Text(L("rec"))
                    .font(.system(size: unit * 0.032, weight: .bold))
                    .foregroundStyle(.red)
            } else {
                Text(L("slate_next"))
                    .font(.system(size: unit * 0.032, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Text(model.takeName)
                .font(.system(size: unit * 0.032, weight: .semibold,
                              design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .foregroundStyle(.white)
        }
    }

    /// The giant readout. Frozen, it changes color and grows a tag — the
    /// number alone must not be mistakable for the running clock on footage
    /// that shows only part of the face.
    private func timecodeReadout(unit: CGFloat) -> some View {
        Text(model.timecodeText)
            .font(.system(size: unit * 0.15, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.2)
            .foregroundStyle(model.isFrozen ? Self.hold : .white)
            .overlay(alignment: .topTrailing) {
                if model.isFrozen {
                    Text(L("slate_sync_tag"))
                        .font(.system(size: max(10, unit * 0.022), weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, unit * 0.012)
                        .padding(.vertical, unit * 0.004)
                        .background(Self.hold, in: Capsule())
                        .alignmentGuide(.top) { $0[.bottom] }
                }
            }
    }

    /// The identification card: project on top, CAM/ROLL/CLIP as a slate row,
    /// date and rate underneath.
    private func card(unit: CGFloat) -> some View {
        Grid(horizontalSpacing: unit * 0.012, verticalSpacing: unit * 0.012) {
            GridRow {
                cell(L("project"), value: model.projectName, unit: unit)
                    .gridCellColumns(3)
            }
            GridRow {
                cell(L("cam_label"), value: model.cameraLabel, unit: unit)
                cell(L("roll_label"), value: model.roll, unit: unit)
                cell(L("clip_label"), value: model.clipText, unit: unit)
            }
            GridRow {
                cell(L("slate_date"), value: model.dateText, unit: unit)
                    .gridCellColumns(2)
                cell(L("slate_fps"), value: model.fpsText, unit: unit)
            }
        }
        .frame(maxWidth: unit * 0.72)
    }

    /// An empty or missing value shows as a dash — a blank box on the footage
    /// reads as a render failure, a dash as "not set".
    private static func shown(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    /// One card box: a dim label over a large monospaced value.
    private func cell(_ label: String, value: String?, unit: CGFloat) -> some View {
        VStack(spacing: unit * 0.006) {
            Text(label.uppercased())
                .font(.system(size: max(9, unit * 0.016), weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text(Self.shown(value))
                .font(.system(size: unit * 0.045, weight: .semibold,
                              design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .foregroundStyle(.white)
        }
        .padding(.vertical, unit * 0.014)
        .padding(.horizontal, unit * 0.01)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.white.opacity(0.18)))
    }
}
