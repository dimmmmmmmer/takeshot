import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The Other-content row, now that it also says which folder its file is in.
///
/// The row lives in the takes panel, which compresses to 310pt, and it already
/// carried a name and a metric. A third element there is the shape that pushes
/// a panel wider than the split view allows — so it is measured rather than
/// eyeballed, in both languages and with the longest realistic contents.
@MainActor @Suite struct ViewOtherFolderRowTests {
    /// The panel's content width: `ViewBudget.panelMinWidth` less the list's
    /// own insets, the same budget the offload status strip is held to.
    static let budget = ViewBudget.panelMinWidth - 24

    @Test func theRowFitsTheNarrowestPanelWithAFolderOnIt() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let url = probe.root
                .appendingPathComponent("CARD_A/DCIM/100CANON/A001C001_260802.mov")
            let widths = probe.minimumWidths {
                OtherRow(url: url).environmentObject(controller)
            }
            #expect(widths.en <= Self.budget,
                    "the row needs \(widths.en)pt of \(Self.budget)")
            #expect(widths.ru <= Self.budget,
                    "the row needs \(widths.ru)pt of \(Self.budget)")
        }
    }

    /// **A long folder path does not widen the row.**
    ///
    /// The label is the one part of the row that can be arbitrarily long — a
    /// card tree is four folders deep before the clip — and the row sits in a
    /// panel the operator drags narrow. Measured at the row's MINIMUM width,
    /// which is what a split view is allowed to compress it to: the label has
    /// to give way there, not push.
    @Test func aLongFolderDoesNotWidenTheRow() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let short = probe.root
                .appendingPathComponent("Dailies/A001C001_260802.mov")
            let long = probe.root.appendingPathComponent(
                "CARD_A/DCIM/100CANON/SECOND_UNIT_PICKUPS/A001C001_260802.mov")
            let near = probe.minimumWidths {
                OtherRow(url: short).environmentObject(controller)
            }
            let deep = probe.minimumWidths {
                OtherRow(url: long).environmentObject(controller)
            }
            #expect(deep.en == near.en, """
                a four-deep folder asks for \(deep.en)pt where a one-deep one \
                asks for \(near.en) — the label is pushing the panel wider \
                instead of truncating
                """)
            #expect(deep.ru == near.ru)
        }
    }

    /// A file directly in the record folder has no label at all — most of them
    /// are, and a row that said "." or repeated the folder name would be noise
    /// on every line.
    @Test func aFileInTheRecordFolderCarriesNoLabel() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let bare = probe.root.appendingPathComponent("A001C001_260802.mov")
            let nested = probe.root
                .appendingPathComponent("Dailies/A001C001_260802.mov")
            let plain = probe.fittingSizes {
                OtherRow(url: bare).environmentObject(controller)
            }
            let labelled = probe.fittingSizes {
                OtherRow(url: nested).environmentObject(controller)
            }
            #expect(labelled.en.width > plain.en.width,
                    "the folder label drew nothing")
        }
    }
}
