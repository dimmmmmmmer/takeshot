import AppKit
import SwiftUI
import Testing

@testable import TakeShotKit

/// The hotkey editor sheet, rendered headlessly in both languages.
///
/// The list moved out of the settings form into a sheet of its own fixed width
/// (owner item 20), which means it inherited the settings window's failure
/// mode: a row is a translated label beside a chord button and a reset button,
/// and a label that outgrows the row truncates without wrapping and without
/// anything throwing. Russian runs half again as long as English, so every row
/// is measured against the budget the sheet actually gives it.
@MainActor
struct ViewHotkeyEditorTests {
    /// What a row's label really gets: the sheet, minus its 16pt padding a
    /// side, minus the chord column, the reset button and the two gaps.
    private static let labelBudget: CGFloat =
        HotkeyEditorView.width - 32 - HotkeyEditorView.shortcutColumn - 24 - 16

    /// Every action title fits beside its chord and reset buttons.
    @Test func everyRowLabelFitsTheSheet() async throws {
        try await ViewProbe.run { probe in
            for action in HotkeyAction.allCases {
                let ideal = probe.fittingSizes {
                    Text(L(action.titleKey)).fixedSize()
                }
                let budget = Self.labelBudget
                #expect(ideal.ru.width <= budget,
                        "\(action.titleKey) is \(ideal.ru.width)pt of \(budget)")
                #expect(ideal.en.width <= Self.labelBudget)
            }
        }
    }

    /// The sheet renders at its declared width in both languages, and to the
    /// same height: a chrome string that went missing in one of them moves it.
    @Test func theSheetRendersTheSameInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes {
                HotkeyEditorView(hotkeys: probe.hotkeys)
            }
            #expect(ideal.en.width == HotkeyEditorView.width,
                    "the editor is \(ideal.en.width)pt wide")
            #expect(ideal.ru.width == HotkeyEditorView.width)
            #expect(ideal.ru.matches(ideal.en, slack: 8),
                    "the Russian editor is a different size: \(ideal)")
            // the list is scrollable and fixed-height, so the sheet must not
            // grow with the number of actions
            #expect(ideal.en.height < 600, """
                the editor is \(ideal.en.height)pt tall: the list grew the \
                sheet instead of scrolling
                """)
        }
    }

    /// The refusal banner is the one wrapping sentence in the sheet. It has to
    /// render, and to render at the same height in both languages.
    @Test func theConflictBannerRendersInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            probe.hotkeys.assign(HotkeyAction.toggleRecord.defaultCombo,
                                 to: .punchIn)
            let inner = HotkeyEditorView.width - 32
            let banner = probe.sizes(proposedWidth: inner) {
                Label(L("hotkey_conflict", L(HotkeyAction.toggleRecord.titleKey)),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #expect(banner.en.height > 0 && banner.ru.height > 0)
            #expect(banner.ru.height == banner.en.height,
                    "the conflict banner wrapped in one language: \(banner)")
            #expect(banner.ru.width <= inner + 1)
        }
    }

    /// The empty-search state still renders — an empty list used to be a blank
    /// sheet with no explanation.
    @Test func theSheetRendersWithNoMatchingRows() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes {
                Text(L("hotkey_no_matches")).fixedSize()
            }
            #expect(ideal.en.width > 0 && ideal.ru.width > 0)
            #expect(ideal.ru.width <= HotkeyEditorView.width - 32)
        }
    }

    /// Every string the sheet puts on screen resolves in both languages; a
    /// typo'd key renders as itself and no build step notices.
    @Test func everyEditorStringResolvesInBothLanguages() async throws {
        let keys = ["settings_hotkeys", "hotkey_bindings", "hotkey_edit",
                    "hotkey_search", "hotkey_no_matches", "hotkey_conflict",
                    "hotkey_reset_one", "reset_hotkeys", "reset_hotkeys_confirm",
                    "press_keys", "close", "cancel"]
        try await ViewProbe.run { _ in
            for language in [AppLanguage.english, .russian] {
                ViewRender.withLanguage(language) {
                    for key in keys {
                        #expect(L(key) != key,
                                "\(key) is raw in \(language.rawValue)")
                    }
                }
            }
        }
    }
}
