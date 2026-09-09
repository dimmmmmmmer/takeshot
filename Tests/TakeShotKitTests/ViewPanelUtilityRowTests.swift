import AppKit
import SwiftUI
import Testing

@testable import TakeShotKit

/// **The row under the takes panel, and what an operator can actually press.**
///
/// The export control used to be a bordered `Button` in the panel's header with
/// an invisible `Menu` stretched over it, and the menu's label was a
/// `Color.clear` — which claims no hit points. So the control answered only
/// where the menu's own chrome happened to land, and opened sometimes (owner:
/// "кнопка экспорта хмл/пдф не всегда прожимается").
///
/// It is two menus in this row now, beside the offload and the dailies, with
/// real icons for labels (owner: "кнопку дейлизов давай рядом с кнопкой
/// оффлоада добавим, а не в экспорт там где тейки"; "кнопку экспорта давай туда
/// же вниз перенесем и разделим на 2 – шифт репорты ксв/пдф и экспорт авид и
/// хмл таймлайна").
@Suite @MainActor struct ViewPanelUtilityRowTests {
    /// **Every control in the row claims the point it looks like it occupies.**
    /// Hit-tested rather than read off the source: a label that draws and does
    /// not answer is exactly the failure, and it is invisible in a screenshot.
    @Test func everyControlInTheRowIsHitTestable() async throws {
        try await ViewProbe.run { probe in
            _ = try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let size = CGSize(width: 320, height: 44)
            let host = NSHostingView(rootView: AnyView(
                probe.hosted(PanelUtilityButtons())))
            host.frame = CGRect(origin: .zero, size: size)
            // a window: hit testing of a hosted control answers as it does in
            // the app only once there is one
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            // the icons sit in a centred row: walk across its middle and count
            // the distinct views that answer
            var claimed: Set<ObjectIdentifier> = []
            for x in stride(from: 4.0, to: size.width - 4, by: 2) {
                if let hit = host.hitTest(CGPoint(x: x, y: size.height / 2)),
                   hit !== host {
                    claimed.insert(ObjectIdentifier(hit))
                }
            }
            #expect(claimed.count == 6, """
                \(claimed.count) controls in the row answer a click, not six — \
                settings, VANC, offload, dailies, reports and the timeline
                """)
            // …and each is the size it looks. A `Menu` whose label has no size
            // of its own collapses and sits centred in whatever it was overlaid
            // on, which is how the export control came to open only when
            // clicked in the middle: measured, an icon label makes this row 214
            // points wide and a clear one 175.
            let width = probe.fittingSize(PanelUtilityButtons()).width
            #expect(width >= 200, """
                the row is \(width) points wide — a control has collapsed to \
                less than its icon
                """)
        }
    }

    /// The export menus are gone from the panel's header, which is the other
    /// half of the move: two homes for one errand is how the offload came to
    /// be unreachable before the first take.
    @Test func theHeaderNoLongerCarriesTheExportControl() throws {
        let code = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TakeShotKit/TakeListView.swift"),
            encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for gone in ["export_report_pdf", "export_edl", "export_ale",
                     "dailies_menu"] {
            #expect(!code.contains(gone),
                    Comment(rawValue: "the header still carries \(gone)"))
        }
    }

    /// …and the utility row carries them, split the way the owner asked: the
    /// production office's paperwork in one, the edit's timeline in the other.
    @Test func theRowCarriesBothMenusSplitByErrand() throws {
        let code = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TakeShotKit/PanelUtilityButtons.swift"),
            encoding: .utf8)
        for reports in ["export_report_pdf", "export_report_csv"] {
            #expect(code.contains(reports))
        }
        for timeline in ["export_edl", "export_ale"] {
            #expect(code.contains(timeline))
        }
        #expect(code.contains("dailies_menu"), "the dailies button did not move")
    }
}
