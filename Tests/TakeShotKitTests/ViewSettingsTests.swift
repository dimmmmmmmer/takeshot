import AppKit
import SwiftUI
import Testing

@testable import TakeShotKit

/// Guards the settings window, which is the densest localized surface in the
/// app: every row is a translated label beside a control, inside a window of
/// FIXED width. A grouped Form does not wrap those labels — it truncates them —
/// so nothing about the rendered form's height gives the truncation away. What
/// does is measuring the rows that are their own views and the label strings the
/// form puts in them, and checking they still fit the width the window has.
@MainActor
struct ViewSettingsTests {
    /// The form renders and reports the fixed width in both languages. The
    /// height has to match too: a section that fell out of the Russian build (a
    /// missing key throwing off a `ForEach`, say) shows up here.
    @Test func settingsFormRendersAtItsFixedWidth() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes { SettingsView() }
            #expect(ideal.ru.width == SettingsView.width + 32,
                    "settings window width moved: \(ideal.ru.width)")
            #expect(ideal.ru.matches(ideal.en, slack: 8),
                    "the Russian settings form is a different size: \(ideal)")
            #expect(ideal.ru.height > 500)
        }
    }

    /// The three frame-count rows carry the longest labels in the detection
    /// section ("REC start confirm (frames)" / "Подтверждение старта (кадры)")
    /// next to a 56pt field and a stepper. Each has to fit the form.
    @Test func frameCountRowsFitTheSettingsForm() async throws {
        try await ViewProbe.run { probe in
            let form = ViewBudget.settingsFormWidth
            for key in ["start_frames", "stop_frames", "pre_roll_frames"] {
                let ideal = probe.fittingSizes {
                    FrameCountField(label: L(key), value: .constant(4),
                                    range: 0...60)
                }
                #expect(ideal.ru.width <= form,
                        "\(key) row wants \(ideal.ru.width)pt of \(form)")
                #expect(ideal.ru.height == ideal.en.height,
                        "\(key) row wrapped in Russian: \(ideal)")
            }
        }
    }

    /// The hotkey section is a label, a spacer and a 90pt shortcut button per
    /// action. The labels are the longest sentences in the window ("Fullscreen
    /// (playback fullscreen while viewing)"), and a label that outgrows the row
    /// truncates silently.
    @Test func hotkeyRowsFitTheSettingsForm() async throws {
        try await ViewProbe.run { probe in
            // the same 90pt minimum the settings row gives the shortcut button
            let shortcutColumn: CGFloat = 90
            let form = ViewBudget.settingsFormWidth
            for action in HotkeyAction.allCases {
                let ideal = probe.fittingSizes {
                    Text(L(action.titleKey)).fixedSize()
                }
                let needed = ideal.ru.width + shortcutColumn
                #expect(needed <= form,
                        "\(action.titleKey) needs \(needed)pt of \(form)")
            }
        }
    }

    /// Every hotkey action has a translation in both files, and the recording
    /// placeholder is what replaces the combo while a key is being captured —
    /// both land in the same 90pt-minimum button.
    @Test func hotkeyTitlesAreTranslated() async throws {
        try await ViewProbe.run { _ in
            for action in HotkeyAction.allCases {
                let ru = ViewRender.withLanguage(.russian) { L(action.titleKey) }
                #expect(ru != action.titleKey,
                        "\(action.titleKey) renders as its raw key in Russian")
            }
        }
    }

    /// The naming presets are vendor names (ARRI, RED, Sony) plus "Custom", and
    /// they fill both the settings picker and the footer menu. They must fit the
    /// form in either language.
    @Test func namingPresetLabelsFitTheSettingsForm() async throws {
        try await ViewProbe.run { probe in
            for preset in SettingsView.namingPresets {
                let ideal = probe.fittingSizes {
                    Text(L(preset.key)).fixedSize()
                }
                #expect(ideal.ru.width <= ViewBudget.settingsFormWidth,
                        "\(preset.key) is \(ideal.ru.width)pt wide")
            }
        }
    }

    /// Recording in progress disables the device pickers and hides nothing; the
    /// form must still measure the same.
    @Test func settingsFormWhileRecordingKeepsItsSize() async throws {
        try await ViewProbe.run { probe in
            let idle = probe.fittingSizes { SettingsView() }
            probe.controller.isRecording = true
            probe.controller.settings.forcedInputMode = "1080p25"
            let recording = probe.fittingSizes { SettingsView() }
            #expect(recording.ru.width == idle.ru.width)
            #expect(recording.ru.matches(recording.en, slack: 8),
                    "the recording form differs by language: \(recording)")
        }
    }
}
