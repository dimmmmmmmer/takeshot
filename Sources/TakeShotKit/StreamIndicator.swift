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
/// **Nothing at all when both are off.** The footer is crowded and an operator
/// who does not stream should not be paying for a control that says "not
/// streaming" all day. It appears when something is switched on and goes when
/// nothing is.
struct StreamIndicator: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var mirrors: DisplayMirrors

    private var srt: StreamLink { StreamLink(mirrors.srtState) }
    private var ndi: StreamLink { StreamLink(mirrors.ndiState) }
    private var combined: StreamLink { StreamLink.combined([srt, ndi]) }

    var body: some View {
        if combined.isEngaged {
            Button {
                controller.stopAllStreams()
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
        switch combined {
        case .up: "dot.radiowaves.left.and.right"
        case .waiting: "antenna.radiowaves.left.and.right.slash"
        case .trouble: "exclamationmark.triangle.fill"
        case .off: ""
        }
    }

    /// Which transports are ON, not which are up: the label names what the
    /// operator switched on, and the symbol and colour say how it is going.
    private var label: String {
        let names = [srt.isEngaged ? "SRT" : nil, ndi.isEngaged ? "NDI" : nil]
            .compactMap { $0 }
        return names.joined(separator: "+")
    }

    private var tint: Color {
        switch combined {
        case .up: .green
        case .waiting: .secondary
        case .trouble: .orange
        case .off: .clear
        }
    }

    /// The tooltip says what a glance cannot: which link is in which state, and
    /// what pressing this does.
    private var helpText: String {
        var lines: [String] = []
        if srt.isEngaged { lines.append("SRT — " + Self.words(srt)) }
        if ndi.isEngaged { lines.append("NDI — " + Self.words(ndi)) }
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
