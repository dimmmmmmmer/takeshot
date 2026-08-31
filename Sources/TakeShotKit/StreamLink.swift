import Foundation

/// Whether a live output's LINK is up — as opposed to whether its switch is on,
/// which is a different fact and the one an indicator must not show.
///
/// The two transports report in their own vocabularies, and until now neither
/// was read anywhere but its own Settings row. An indicator on the main window
/// needs one reading, because the operator's question is one question: is the
/// picture leaving this machine and is somebody taking it (owner: "нам нужен в
/// главном окне какой-то визуальный индикатор что поток уходит по срт/нди").
///
/// **`waiting` is the state worth having.** SRT already distinguished it — a
/// listener that has bound a port with nobody dialled in is `.starting`, and
/// that is what the bridge measures rather than a UI convention. NDI did not:
/// it wrote "sending" one line after the source was announced, so its lamp lit
/// because a checkbox was ticked. It can answer now, on a runtime that exports
/// the connection count.
///
/// Both initializers switch EXHAUSTIVELY, with no `default:`. A case added to
/// either transport's enum then fails to compile here rather than silently
/// arriving as a green light.
enum StreamLink: Equatable {
    /// No mirror: the switch is off.
    case off
    /// The mirror exists and nothing is taking the bytes.
    case waiting
    /// A peer is taking them.
    case up
    /// It was up and went, or it cannot come up. Carries what to say about it.
    case trouble(String)

    init(_ state: SRTOutputState) {
        switch state {
        case .off: self = .off
        case .starting: self = .waiting
        case .sending: self = .up
        case .reconnecting(let why): self = .trouble(why)
        case .failed(let why): self = .trouble(why)
        case .unavailable(let bridge): self = .trouble(bridge.localizedText)
        }
    }

    init(_ state: NDIOutputState) {
        switch state {
        case .off: self = .off
        case .announced: self = .waiting
        case .sending: self = .up
        case .failed(let why): self = .trouble(why)
        case .unavailable(let bridge): self = .trouble(bridge.localizedText)
        }
    }

    /// Whether anything at all is switched on. `off` is the only state in which
    /// the indicator has nothing to say.
    var isEngaged: Bool { self != .off }

    /// The two links as one reading, for a single indicator.
    ///
    /// Trouble outranks everything — it is the one an operator has to see
    /// mid-shoot — then `up`, because one live link is a picture leaving the
    /// machine even if the other is waiting.
    static func combined(_ links: [StreamLink]) -> StreamLink {
        if let trouble = links.first(where: {
            if case .trouble = $0 { return true }
            return false
        }) { return trouble }
        if links.contains(.up) { return .up }
        if links.contains(.waiting) { return .waiting }
        return .off
    }
}
