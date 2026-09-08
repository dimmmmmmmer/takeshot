import AppKit
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The empty strip along the top of the window.
///
/// The click itself is not reachable from a headless run — what IS reachable
/// is the decision the strip makes, and the decision is the part that was
/// wrong: a `Color.clear` there swallowed every click, so dragging the window
/// by its top edge and double-clicking to zoom both did nothing.
@Suite struct ViewWindowDragZoneTests {
    /// **Unset means Zoom**, which is the default on every Mac and the answer
    /// the owner is asking for. A window that always zoomed would override a
    /// preference this strip exists to stand in for.
    @Test func anUnsetPreferenceZooms() {
        #expect(TitleBarDoubleClick.reading(nil) == .zoom)
        #expect(TitleBarDoubleClick.reading("Maximize") == .zoom)
    }

    @Test func theOtherTwoAnswersAreObeyed() {
        #expect(TitleBarDoubleClick.reading("Minimize") == .minimize)
        #expect(TitleBarDoubleClick.reading("None") == .none)
    }
}

/// …and the strip is actually mounted, at the height the window reserves.
@Suite @MainActor struct ViewWindowDragZoneMountTests {
    @Test func theStripIsAsTallAsTheInsetTheWindowReserves() async throws {
        try await ViewProbe.run { probe in
            probe.controller.windowTopInset = 31
            let size = probe.sizes(proposedWidth: 400, proposedHeight: 400) {
                probe.hosted(WindowDragZone()
                    .frame(height: probe.controller.windowTopInset))
            }
            #expect(size.en.height == 31, "the strip is \(size.en.height)pt")
        }
    }
}
