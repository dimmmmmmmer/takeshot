import SwiftUI
import Testing

@testable import TakeShotKit

/// **The stream state sits beside the timecode, and it stays there when the
/// streams are off.**
///
/// Two decisions of the owner's, in one place because they are one change: the
/// badges moved out of the footer, which had run out of width, and they stopped
/// vanishing when nothing is switched on. The old rule — draw nothing at all
/// while both outputs are off — was argued from the footer's width, and in the
/// top row that argument does not hold: a badge that disappears leaves an
/// operator unable to tell "switched off" from "this build has no NDI" without
/// opening Settings.
@MainActor
struct ViewStreamBadgePlaceTests {
    /// The row draws the badge whatever the streams are doing, and the ROW is
    /// what is measured: a badge that quietly stopped being mounted would leave
    /// the leading zone at the timecode's own width.
    @Test func theStreamBadgeIsInTheRowInEveryState() async throws {
        try await ViewProbe.run { probe in
            let mirrors = probe.controller.mirrors
            var widths: [String: CGFloat] = [:]
            for (name, srt, ndi) in [
                ("off", SRTOutputState.off, NDIOutputState.off),
                ("starting", .starting, .off),
                ("sending", .sending, .sending),
                ("failed", .failed("gone"), .off),
            ] {
                mirrors.srtState = srt
                mirrors.ndiState = ndi
                widths[name] = probe.fittingSize(
                    StreamIndicator(mirrors: mirrors)).width
            }
            for (name, width) in widths {
                #expect(width > 0, "the \(name) badge drew nothing at all")
            }
            // **Every state is the same width**, because every state draws the
            // same two named transports and moves only their icons. The badge
            // used to shrink as transports were switched off — which is the
            // disappearance this is here to prevent — so a width that varies
            // by more than an icon glyph is the row dropping a transport.
            let spread = (widths.values.max() ?? 0) - (widths.values.min() ?? 0)
            #expect(spread <= 12, """
                the badge changes width by \(spread)pt between states, so a \
                transport is being dropped out of the row: \(widths)
                """)
        }
    }

    /// …and the whole row still fits the narrowest window with it there. The
    /// contract `theIdentityRowHoldsItsShapeAtTheNarrowestWindow` states is
    /// what the move had to survive, and the widest case is now the DEFAULT
    /// case rather than a rare one — the badge is always mounted.
    @Test func theRowStillFitsWithTheBadgeBesideTheTimecode() async throws {
        try await ViewProbe.run { probe in
            let mirrors = probe.controller.mirrors
            mirrors.srtState = .sending
            mirrors.ndiState = .sending
            mirrors.playoutState = .feeding
            let ideal = probe.fittingSizes { PlayerTopBadgeRow() }
            #expect(ideal.ru.width <= ViewBudget.playerChromeWidth,
                    "the row wants \(ideal.ru.width)pt of \(ViewBudget.playerChromeWidth)")
            #expect(ideal.en.width <= ViewBudget.playerChromeWidth)
        }
    }

    /// The footer no longer carries it, which is the half of the move that is
    /// invisible from the row: a badge in both places would be the same state
    /// drawn twice.
    @Test func theFooterNoLongerCarriesIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        let footer = try String(
            contentsOf: root.appendingPathComponent("FooterBar.swift"),
            encoding: .utf8)
        let code = footer.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("StreamIndicator("),
                "the footer still mounts the stream badge")
        let badges = try String(
            contentsOf: root.appendingPathComponent("PlayerBadges.swift"),
            encoding: .utf8)
        #expect(badges.contains("StreamIndicator("),
                "the top row does not mount the stream badge")
    }

    /// **A transport that is off keeps its own line.** The all-off case was
    /// fixed first and the one-of-two case was not: with SRT running, NDI's
    /// name simply left the row, which is the same disappearance one state
    /// along (owner: "сделай так чтоб при выключении они меняли значок а не
    /// исчезали").
    @Test func aStreamThatIsOffKeepsItsNameAndChangesItsIcon() {
        let live = StreamIndicator.readings(srt: .up, ndi: .off, paused: false)
        #expect(live.map(\.name) == ["SRT", "NDI"],
                "a transport was dropped out of the row: \(live.map(\.name))")
        #expect(live[1].link == .off)
        #expect(StreamIndicator.symbolForTests(live[1].link)
                    != StreamIndicator.symbolForTests(live[0].link),
                "the off transport wears the live one's icon")

        // …and the other way round, so the order is not what is being tested
        let other = StreamIndicator.readings(srt: .off, ndi: .up, paused: false)
        #expect(other.map(\.name) == ["SRT", "NDI"])
        #expect(other[0].link == .off)

        // Both off is still both names — this is the case that was already
        // right, and it must not regress into the old single reading.
        #expect(StreamIndicator.readings(srt: .off, ndi: .off, paused: false)
                    .map(\.name) == ["SRT", "NDI"])
    }

    /// Paused reads as off on the ICON — the mirror really is torn down — and
    /// what makes it different is in the tooltip, where there is room to say
    /// "press to resume" rather than in a shape nobody can tell apart.
    @Test func aPausedStreamReadsAsOffOnTheIcon() {
        let paused = StreamIndicator.readings(srt: .up, ndi: .up, paused: true)
        #expect(paused.allSatisfy { $0.link == .off })
        #expect(paused.map(\.name) == ["SRT", "NDI"])
    }

    /// Off and WAITING may not share a symbol: "switched off" and "switched on,
    /// nobody watching" are the very distinction `StreamLink` exists to keep,
    /// and a shape that meant both would throw it away at the last step.
    @Test func offAndWaitingDoNotLookAlike() {
        let shapes = [StreamLink.off, .waiting, .up, .trouble("x")]
            .map(StreamIndicator.symbolForTests)
        #expect(Set(shapes).count == shapes.count,
                "two link states share one symbol: \(shapes)")
        #expect(shapes.allSatisfy { !$0.isEmpty },
                "a link state draws no symbol at all: \(shapes)")
    }
}
