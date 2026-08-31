import SwiftUI

/// Whether the picture is leaving this machine, in the footer where the
/// operator is already looking.
///
/// Until now the only place either output's state appeared was its own row in
/// the Settings WINDOW — which is shut during a shooting day. So "is the stream
/// going out" was a question you had to open a window to answer, and the answer
/// there was half honest: SRT's state means the link is up, NDI's meant the
/// source had been announced (owner: "нам нужен в главном окне какой-то
/// визуальный индикатор что поток уходит по срт/нди. и должна быть кнопка
/// запустить/остановить поток").
///
/// **It shows the LINK, never the switch.** `StreamLink` is where that
/// distinction lives, and both transports are read through it — a lamp that
/// lights because a checkbox is ticked is a lamp nobody can use.
///
/// **Nothing at all when both are off — until this button is what turned them
/// off.** The footer is crowded and an operator who does not stream should not
/// be paying for a control that says "not streaming" all day. But the first
/// version took that literally and became a one-way door: one press turned both
/// switches off, `isEngaged` went false, the control erased itself, and the only
/// way to stream again was the Settings window — the window this control exists
/// so nobody has to open. So a stream this button PAUSED keeps the button on
/// screen, in its off state, and the next press starts it again. A stream
/// switched off in Settings still takes the control away with it: that was a
/// decision, not a pause.
struct StreamIndicator: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var mirrors: DisplayMirrors

    private var srt: StreamLink { StreamLink(mirrors.srtState) }
    private var ndi: StreamLink { StreamLink(mirrors.ndiState) }
    private var combined: StreamLink { StreamLink.combined([srt, ndi]) }

    /// The button is showing a paused stream rather than a live one — the state
    /// where its press STARTS instead of stops.
    private var isPaused: Bool { !combined.isEngaged && mirrors.pausedStreams.any }

    var body: some View {
        if combined.isEngaged || isPaused {
            Button {
                if isPaused {
                    controller.resumeStreams()
                } else {
                    controller.stopAllStreams()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .fixedSize()
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(tint.opacity(0.15), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(helpText)
        }
    }

    /// One dot for a live link, a hollow one for a link nobody has taken, and
    /// the alarm triangle for trouble. The SHAPE carries it as well as the
    /// colour, because a colour alone is a poor signal on a bright cart.
    private var symbol: String {
        if isPaused { return "antenna.radiowaves.left.and.right.slash" }
        switch combined {
        case .up: return "dot.radiowaves.left.and.right"
        case .waiting: return "antenna.radiowaves.left.and.right.slash"
        case .trouble: return "exclamationmark.triangle.fill"
        case .off: return ""
        }
    }

    /// Which transports are ON, not which are up: the label names what the
    /// operator switched on, and the symbol and colour say how it is going.
    private var label: String {
        let paused = mirrors.pausedStreams
        let names = [srt.isEngaged || (isPaused && paused.srt) ? "SRT" : nil,
                     ndi.isEngaged || (isPaused && paused.ndi) ? "NDI" : nil]
            .compactMap { $0 }
        return names.joined(separator: "+")
    }

    private var tint: Color {
        if isPaused { return .secondary }
        switch combined {
        case .up: return .green
        case .waiting: return .secondary
        case .trouble: return .orange
        case .off: return .clear
        }
    }

    /// The tooltip says what a glance cannot: which link is in which state, and
    /// what pressing this does.
    private var helpText: String {
        var lines: [String] = []
        guard !isPaused else { return L("stream_start_help") }
        if srt.isEngaged { lines.append("SRT — " + Self.words(srt)) }
        if ndi.isEngaged {
            lines.append("NDI — " + Self.words(ndi))
            if mirrors.ndiCarriesAudio == false {
                // The sentence, not the two-word label: a tooltip has room and
                // this is where an operator finds out WHY the feed is silent.
                lines.append(L("ndi_picture_only_help"))
            }
        }
        lines.append(L("stream_stop_help"))
        return lines.joined(separator: "\n")
    }

    private static func words(_ link: StreamLink) -> String {
        switch link {
        case .up: L("stream_link_up")
        case .waiting: L("stream_link_waiting")
        case .trouble(let why): why
        case .off: L("stream_link_off")
        }
    }
}
