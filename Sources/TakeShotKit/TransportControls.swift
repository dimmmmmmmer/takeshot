import CaptureCore
import SwiftUI

// The pieces both transport bars are built from.
//
// There are two bars because there are two playback engines: `TransportBar`
// drives AVPlayer, `RawTransportBar` drives the BRAW/CinemaDNG decoder. They
// grew as siblings and drifted — the skip/play group, the timecode readout, the
// in/out/loop trio, the fullscreen button and the bar's own chrome were written
// out twice, so a fix landed in one bar and not the other. The in/out glyphs
// were the first thing pulled out for exactly that reason (see
// `TransportModel.inPointSymbol`); this file finishes the job.
//
// What actually differs between the two is the ENGINE, so the engine is what
// these take. Everything else is one implementation, and each piece emits its
// controls WITHOUT a container of its own: a `View` whose body is a tuple
// contributes its children straight to the enclosing `HStack`, so the bars keep
// their single 10pt spacing (the same trick `TransportPositionControls` and
// `MarkerButton` already use).

/// What a transport bar needs of its engine to draw the in/out/loop trio.
///
/// `TransportModel` holds its in/out as stored seconds; `RawPlayerModel` marks
/// frames and converts. Both answer the same three questions, which is why the
/// trio can be one view over either of them.
@MainActor
protocol TransportRangeEngine: ObservableObject {
    var inPoint: Double? { get }
    var outPoint: Double? { get }
    var isLooping: Bool { get set }
    /// Set/clear the in or out point at the playhead.
    func toggleRangePoint(out: Bool)
}

extension TransportModel: TransportRangeEngine {}
extension RawPlayerModel: TransportRangeEngine {}

/// Skip back 5 s, play/pause, skip forward 5 s.
///
/// The glyph metrics used to be parameters, because the two bars carried
/// visibly different ones — 14pt bold in a 20pt slot for the AVPlayer bar,
/// 15pt regular in an 18pt slot for the RAW one. That was drift left over from
/// the days when each bar was written out separately, not a decision anyone
/// made, and it was on screen: the same button changed weight and jumped a
/// point sideways when the operator opened a BRAW clip instead of a take. The
/// main bar's metrics won because that is the bar people spend the day in.
struct TransportPlayGroup: View {
    let isPlaying: Bool
    let skipBack: () -> Void
    let togglePlay: () -> Void
    let skipForward: () -> Void

    /// One slot for both glyphs. `play.fill` and `pause.fill` are not the same
    /// width, so without a fixed frame every play/pause re-laid the row out
    /// around it — the same reflow the speaker icon caused (`TransportVolume`).
    static let glyph = Font.system(size: 14, weight: .bold)
    static let glyphWidth: CGFloat = 20

    var body: some View {
        Button {
            skipBack()
        } label: {
            Image(systemName: "gobackward.5")
        }
        .buttonStyle(.plain)

        Button {
            togglePlay()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(Self.glyph)
                .frame(width: Self.glyphWidth)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])

        Button {
            skipForward()
        } label: {
            Image(systemName: "goforward.5")
        }
        .buttonStyle(.plain)
    }
}

/// A timecode readout in the bar: monospaced digits so the row does not shuffle
/// as the numbers change, secondary so it does not compete with the controls.
struct TransportTimeText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// In point, loop, out point — the trio, over either engine.
struct TransportRangeControls<Engine: TransportRangeEngine>: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var engine: Engine

    var body: some View {
        rangeButton(out: false)

        Button {
            engine.isLooping.toggle()
        } label: {
            Image(systemName: "repeat")
                .foregroundStyle(tint(engine.isLooping))
        }
        .buttonStyle(.plain)
        .help(L("playback_loop"))

        rangeButton(out: true)
    }

    private func rangeButton(out: Bool) -> some View {
        Button {
            engine.toggleRangePoint(out: out)
        } label: {
            Image(systemName: out ? TransportModel.outPointSymbol
                                  : TransportModel.inPointSymbol)
                .font(.system(size: 11))
                .foregroundStyle(tint((out ? engine.outPoint : engine.inPoint)
                                      != nil))
        }
        .buttonStyle(.plain)
        .help(L(out ? "loop_out_help" : "loop_in_help"))
    }

    /// Lit in the operator's accent colour, dim otherwise. `AnyShapeStyle` on
    /// both arms because the two branches are different style types.
    private func tint(_ on: Bool) -> AnyShapeStyle {
        on ? AnyShapeStyle(controller.accentColor) : AnyShapeStyle(.secondary)
    }
}

/// Fill the screen with the player — the same button in both bars.
struct TransportFullscreenButton: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        Button {
            controller.togglePlaybackFullscreen()
        } label: {
            Image(systemName: controller.isPlaybackFullscreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.plain)
        .help(L("fullscreen_playback"))
    }
}

extension View {
    /// The strip itself: a translucent band laid over the bottom of the player.
    /// `PlayerArea` lifts its toasts by a fixed inset to clear it, so the two
    /// bars have to agree on the padding as well as on the material.
    func transportBarChrome() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)
    }
}
