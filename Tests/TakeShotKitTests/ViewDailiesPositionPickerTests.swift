import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// **The place names have to fit the picker that shows them.**
///
/// A menu Picker does not push its container wider when a label is too long —
/// it truncates, and "По центру сверху" and "По центру снизу" become the same
/// two words plus an ellipsis. That is the worst possible failure for this
/// control: the two labels that would be indistinguishable are the two that sit
/// at opposite edges of the frame, so an operator picking by eye lands the
/// timecode at the wrong end and only finds out on the delivered file.
///
/// Russian is the case that matters: every place name is longer there, and the
/// picker's width was chosen against the English.
@Suite @MainActor struct ViewDailiesPositionPickerTests {
    /// What the picker's fixed width leaves for the text: a menu Picker spends
    /// the rest on its own chrome (the chevron and the padding around it).
    static let chrome: CGFloat = 30

    @Test func everyPlaceNameFitsThePickerInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            for place in DailiesBurninPosition.allCases {
                let widths = probe.fittingSizes { Text(L(place.labelKey)) }
                let room = DailiesBurninSection.pickerWidth - Self.chrome
                #expect(widths.en.width <= room, """
                    \(place) needs \(widths.en.width)pt of \(room) in English
                    """)
                #expect(widths.ru.width <= room, """
                    \(place) needs \(widths.ru.width)pt of \(room) in Russian
                    """)
            }
        }
    }

    /// …and the row that holds one — a toggle, then the picker — still fits
    /// the sheet, in both languages. The picker is fixed-width, so it cannot
    /// give anything back when the label beside it grows.
    @Test func aBurnRowFitsTheSheetInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let minimum = probe.minimumWidths {
                DailiesBurninSection(model: probe.controller.dailies)
                    .environmentObject(probe.controller)
            }
            let room = DailiesSheet.width - 40
            #expect(minimum.en <= room,
                    "the burn-in rows need \(minimum.en)pt of \(room)")
            #expect(minimum.ru <= room,
                    "the burn-in rows need \(minimum.ru)pt of \(room)")
        }
    }
}
