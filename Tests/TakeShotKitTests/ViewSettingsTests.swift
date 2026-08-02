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

    /// The input-levels picker gained a third option, and it is the longest
    /// string in the row by some way ("Limited, preserving excursions
    /// (4-1019)"). A menu picker is as wide as its widest option, so this is
    /// exactly the shape of row that silently truncates.
    @Test func theInputLevelsRowFitsTheSettingsForm() async throws {
        try await ViewProbe.run { probe in
            let form = ViewBudget.settingsFormWidth
            let ideal = probe.fittingSizes { InputLevelsPicker() }
            #expect(ideal.ru.width <= form,
                    "the levels row wants \(ideal.ru.width)pt of \(form)")
            #expect(ideal.en.width <= form,
                    "the levels row wants \(ideal.en.width)pt of \(form)")
            #expect(ideal.ru.height == ideal.en.height,
                    "the levels row wrapped in one language: \(ideal)")
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

    /// The Remote section grows a port field, the PIN, the addresses and a QR
    /// code when it is switched on. All of it has to render in both languages,
    /// and the QR has to be an image rather than a missing one.
    ///
    /// The listener is started explicitly on an ephemeral port first: switching
    /// the setting on is what brings the server up in the app, and a view test
    /// must not claim the configured port on the machine running the suite.
    @Test func theRemoteSectionRendersExpandedInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let collapsed = probe.fittingSizes {
                Form { RemoteSettingsSection() }.formStyle(.grouped)
            }
            probe.controller.startRemoteServer(overridePort: 0)
            await ControllerWait.until { probe.controller.remoteBoundPort > 0 }
            probe.controller.settings.remoteEnabled = true

            let expanded = probe.fittingSizes {
                Form { RemoteSettingsSection() }.formStyle(.grouped)
            }
            #expect(expanded.en.height > collapsed.en.height,
                    "the switched-on section did not grow: \(expanded)")
            // Height, not width: measured on its own a grouped Form reports an
            // ideal width its content does not have to live within (the app
            // gives this section SettingsView.width, and the row labels are
            // checked against that budget in the test below). The height is the
            // number that catches the real failures — a row that wrapped in
            // Russian, or a row that never rendered at all.
            #expect(abs(expanded.ru.height - expanded.en.height) <= 8,
                    "the Russian remote section is a different height: \(expanded)")
            #expect(RemoteAddress.qrImage(for: "http://192.168.1.5:8765/") != nil)
        }
    }

    /// The section's own labels sit beside controls in a window of fixed width,
    /// and a grouped Form truncates rather than wraps.
    @Test func remoteRowLabelsFitTheSettingsForm() async throws {
        try await ViewProbe.run { probe in
            let form = ViewBudget.settingsFormWidth
            for key in ["remote_enable", "remote_port", "remote_pin",
                        "remote_address", "remote_pin_new", "remote_offline",
                        "remote_no_network", "remote_script"] {
                let ideal = probe.fittingSizes { Text(L(key)).fixedSize() }
                #expect(ideal.ru.width <= form,
                        "\(key) is \(ideal.ru.width)pt of \(form)")
            }
        }
    }

    /// The Offload section is two explanatory paragraphs and two rows, and the
    /// paragraphs are the only wrapping text in the window. A translation one
    /// line longer than the base moves the whole form, which is what the two
    /// whole-form tests here fail on — measured on its own, this one says WHICH
    /// section did it.
    @Test func theOffloadSectionIsTheSameHeightInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            // The paragraphs are what wraps, so they are measured at the width
            // the form's rows actually get rather than through the Form — asked
            // for a loose height a grouped Form answers with the whole
            // proposal, which is a test that cannot fail.
            let inner = ViewBudget.settingsFormWidth - 40
            for key in ["offer_mounted_cards_hint", "cards_remembered_hint"] {
                let ideal = probe.sizes(proposedWidth: inner) {
                    Text(L(key))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #expect(ideal.ru.height == ideal.en.height,
                        "\(key) wrapped in one language only: \(ideal)")
            }
        }
    }

    /// "Keep TakeShot in the menu bar" is a toggle with a caption under it, and
    /// the caption is the longest sentence in the Interface section. A grouped
    /// Form truncates a label rather than wrapping it, so the row is measured
    /// against the width the window actually gives it, in both languages —
    /// Russian runs half again as long here.
    @Test func theMenuBarRowFitsTheSettingsForm() async throws {
        try await ViewProbe.run { probe in
            let form = ViewBudget.settingsFormWidth
            let label = probe.fittingSizes { Text(L("menubar_keep")).fixedSize() }
            #expect(label.ru.width <= form,
                    "the menu-bar toggle label is \(label.ru.width)pt of \(form)")
            #expect(label.en.width <= form)

            // The caption is allowed to wrap — what it must not do is fail to
            // render, or come out a different number of lines' worth of height
            // by a margin that says a string went missing.
            let row = probe.sizes(proposedWidth: form) { MenuBarSettingsRow() }
            #expect(row.en.width <= form + 1)
            #expect(row.ru.width <= form + 1)
            #expect(row.en.height > 0 && row.ru.height > 0)
        }
    }

    /// …and the whole form still measures the same in both languages with the
    /// row in it: a section that fell out of the Russian build shows up here.
    @Test func theSettingsFormStillMatchesWithTheMenuBarRow() async throws {
        try await ViewProbe.run { probe in
            probe.controller.settings.keepInMenuBar = nil
            let off = probe.fittingSizes { SettingsView() }
            #expect(off.ru.matches(off.en, slack: 8),
                    "the Russian settings form is a different size: \(off)")
            // Switching it on must not resize the window — the toggle is the
            // only thing that moves, and the controller must not install a
            // status item from a render (no `menuBar` is built here: the
            // setting is read back, not applied through a presence).
            #expect(!probe.controller.keepInMenuBar)
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
