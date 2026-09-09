import SwiftUI

/// Whether the picture is leaving this machine, in the player's own top row.
///
/// Until this existed the only place either output's state appeared was its own
/// row in the Settings WINDOW — which is shut during a shooting day. So "is the
/// stream going out" was a question you had to open a window to answer, and the
/// answer there was half honest: SRT's state means the link is up, NDI's meant
/// the source had been announced (owner: "нам нужен в главном окне какой-то
/// визуальный индикатор что поток уходит по срт/нди. и должна быть кнопка
/// запустить/остановить поток").
///
/// **It shows the LINK, never the switch.** `StreamLink` is where that
/// distinction lives, and all three outputs are read through it — a lamp that
/// lights because a checkbox is ticked is a lamp nobody can use.
///
/// **Beside the timecode, not in the footer** (owner: "давай ка значки srt и
/// ndi перенесем вверх правее от таймкода, в нижнем баре уже и так места нет").
/// It wears the row's plate like every other badge there, which is also what
/// took its own capsule away: two backgrounds under one reading is a slab.
///
/// **And it stays put when the streams are off** (owner: "сделай так чтоб при
/// выключении они меняли значок а не исчезали"). It used to draw nothing at
/// all — the argument was that a cart which does not stream should not pay for
/// a control saying "not streaming" all day, and in the crowded footer that
/// argument held. In the top row it does not: the width is there, and a badge
/// that vanishes leaves the operator with no way to tell "switched off" from
/// "this build has no NDI" without opening Settings. Off is a state, so it gets
/// a symbol — a SLASHED antenna, which is the one shape that reads as "not
/// sending" at a glance and on a bright cart.
///
/// **A transport this cart does not use has no line at all.** Both used to be
/// drawn always, on the argument that "off is a state and deserves a symbol" —
/// which is right for a transport the operator streams over and switched off
/// for this shot, and wrong for one they have never used: a cart with no NDI
/// receiver anywhere paid for an NDI badge all day (owner: "пользователю
/// который не использует ни то ни другое на главном окне их значки ни к чему,
/// и тому кто использует только что-то одно – только это и нужно показывать").
/// The Settings checkbox is what says "in use"; whether the link is UP is what
/// the icon then reports.
///
/// The hardware output rides beside it as a LAMP and not a third link inside
/// the button: it answers the same question — is the picture leaving this
/// machine — and it is the leg a director's monitor actually hangs off, but the
/// button STOPS the network streams, and a control that goes orange because a
/// DeckLink was taken by another process, and whose press then kills SRT, is a
/// trap.
struct StreamIndicator: View {
    @EnvironmentObject private var controller: CaptureController
    @ObservedObject var mirrors: DisplayMirrors

    private var srt: StreamLink { StreamLink(mirrors.srtState) }
    private var ndi: StreamLink { StreamLink(mirrors.ndiState) }
    private var playout: StreamLink { StreamLink(mirrors.playoutState) }
    private var combined: StreamLink { StreamLink.combined([srt, ndi]) }

    /// The button is showing a paused stream rather than a live one — the state
    /// where its press STARTS instead of stops.
    private var isPaused: Bool { !combined.isEngaged && mirrors.pausedStreams.any }

    /// **One reading per transport in use, the hardware lamp beside them, and
    /// the plate they all share — or NOTHING AT ALL.**
    ///
    /// The plate used to be the row's: `PlayerTopBadgeRow` wrapped this view in
    /// `playerOverlayBadge`, which draws a padded, bordered, fixed-height slab
    /// around whatever it is given. Once a transport nobody uses stopped
    /// getting a line, a cart that streams over neither was left with the slab
    /// and nothing inside it (owner: "там где были срт и нди значки там
    /// теперь при выключенных режимах подложка осталась без всего").
    ///
    /// So the plate is APPLIED HERE, by the only type that can answer whether
    /// there is anything to put on it: the row knows neither which transports
    /// are in use nor whether a board is feeding. A caller that wrapped this in
    /// a plate of its own would be back to drawing an empty one, which is what
    /// `ViewStreamBadgePlaceTests` now watches.
    var body: some View {
        let rows = Self.readings(srt: srt, ndi: ndi, paused: isPaused,
                                 usesSRT: controller.settings.srt.enabled == true,
                                 usesNDI: controller.settings.ndi.enabled == true)
        if !rows.isEmpty || playout.isEngaged {
            HStack(spacing: 6) {
                // **A press acts on THIS transport.** The row draws a reading
                // each, and one button around both meant a click on the NDI
                // half took SRT down with it (owner: "клик по srt/ndi в рабочем
                // окне включает и выключает оба").
                ForEach(rows, id: \.name) { entry in
                    Button {
                        controller.toggleStream(entry.kind)
                    } label: {
                        reading(symbol: Self.symbol(entry.link),
                                tint: Self.tint(entry.link),
                                text: entry.name)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .controlHelp(helpText(for: entry))
                }
                if playout.isEngaged { playoutLamp }
            }
            .playerChromePlate()
        }
    }

    /// One transport's line on the badge: what it is called, and how its link
    /// is doing.
    struct Reading: Equatable {
        var kind: LiveStreamKind
        var link: StreamLink
        var name: String { kind.name }
    }

    /// The row's content, as data. A paused transport reads OFF, because that
    /// is what it is right now — the mirror is torn down and the button offers
    /// to bring it back; what "paused" adds is in the tooltip, not in the icon.
    ///
    /// Static and pure so the suite can ask the question a rendered badge
    /// cannot answer: whether a transport that is off still has a line of its
    /// own, or has been dropped out of the row.
    static func readings(srt: StreamLink, ndi: StreamLink, paused: Bool,
                         usesSRT: Bool, usesNDI: Bool) -> [Reading] {
        var rows: [Reading] = []
        if usesSRT { rows.append(Reading(kind: .srt, link: paused ? .off : srt)) }
        if usesNDI { rows.append(Reading(kind: .ndi, link: paused ? .off : ndi)) }
        return rows
    }

    /// The hardware monitor output. Absent entirely when no board is selected —
    /// unlike the streams beside it, this is not a switch the operator can
    /// throw from here, so "no board" has nothing to report rather than a state
    /// to show.
    private var playoutLamp: some View {
        reading(symbol: Self.symbol(playout), tint: Self.tint(playout),
                text: L("stream_playout_label"))
            .controlHelp(L("stream_playout_label") + " — " + Self.words(playout))
    }

    /// The one shape every reading wears, so none of them can drift into
    /// looking like a different kind of thing than the others.
    private func reading(symbol: String, tint: Color,
                         text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 10, weight: .semibold))
                    .fixedSize()
            }
        }
        .foregroundStyle(tint)
    }

    /// One dot for a live link, a bare antenna for one nobody has taken, a
    /// SLASHED antenna for one that is off, and the alarm triangle for trouble.
    /// The SHAPE carries it as well as the colour, because a colour alone is a
    /// poor signal on a bright cart — and because off and waiting are the very
    /// distinction this whole type exists to keep, they may not share one.
    private static func symbol(_ link: StreamLink) -> String {
        switch link {
        case .up: "dot.radiowaves.left.and.right"
        case .waiting: "antenna.radiowaves.left.and.right"
        case .trouble: "exclamationmark.triangle.fill"
        case .off: "antenna.radiowaves.left.and.right.slash"
        }
    }

    /// The shape one link state wears, for the suite: that off and waiting are
    /// DIFFERENT shapes is a rule, and it is invisible from a rendered badge.
    static func symbolForTests(_ link: StreamLink) -> String { symbol(link) }

    private static func tint(_ link: StreamLink) -> Color {
        switch link {
        case .up: .green
        case .waiting: .secondary
        case .trouble: .orange
        case .off: .secondary
        }
    }

    /// The tooltip says what a glance cannot: what this link is doing, and
    /// what pressing it does to THIS transport and no other.
    private func helpText(for entry: Reading) -> String {
        var lines = [entry.name + " — " + Self.words(entry.link)]
        if entry.kind == .ndi, ndi.isEngaged, mirrors.ndiCarriesAudio == false {
            // The sentence, not the two-word label: a tooltip has room and
            // this is where an operator finds out WHY the feed is silent.
            lines.append(L("ndi_picture_only_help"))
        }
        lines.append(entry.link.isEngaged ? L("stream_stop_help")
                     : L("stream_start_help"))
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
