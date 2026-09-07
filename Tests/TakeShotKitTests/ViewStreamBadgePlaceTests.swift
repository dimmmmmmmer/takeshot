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
            // Every state has something on screen — an OFF badge is a symbol
            // and no label, which is the narrowest, and it is still not zero.
            for (name, width) in widths {
                #expect(width > 0, "the \(name) badge drew nothing at all")
            }
            #expect((widths["off"] ?? 0) < (widths["sending"] ?? 0), """
                the off badge is not narrower than the sending one, so it is \
                carrying a label it should not: \(widths)
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
