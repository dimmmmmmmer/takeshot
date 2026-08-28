import AppKit
import CNDI
import SwiftUI
import Testing

@testable import TakeShotKit

/// The NDI section of the settings window. Its own file rather than more rows in
/// `ViewSettingsTests`, which is already near the file-length ceiling.
///
/// What the render can say that a unit test cannot: the section is one row while
/// the switch is off (a feature nobody asked for costs no height), it grows when
/// it is thrown, and neither state wrapped differently in Russian — a truncated
/// label in a grouped Form throws nothing and shows up only as a size.
///
/// This file is also what holds the nine restored strings to the same standard
/// the rest of the window is held to. They used to be on
/// `ViewSettingsTests.theRetiredSettingsStringsAreGoneFromBothLanguages`, which
/// asserted their ABSENCE; a feature that comes back has to swap one for the
/// other, or nothing checks the labels at all.
@MainActor
struct ViewNDISettingsTests {
    @Test func theNDISectionGrowsWhenItIsSwitchedOn() async throws {
        try await ViewProbe.run { probe in
            let collapsed = probe.fittingSizes {
                Form { NDISettingsSection() }.formStyle(.grouped)
            }
            probe.controller.settings.ndi.enabled = true
            let expanded = probe.fittingSizes {
                Form { NDISettingsSection() }.formStyle(.grouped)
            }
            #expect(expanded.en.height > collapsed.en.height,
                    "the switched-on section did not grow: \(expanded)")
            // Height, not width, for the reason the remote's test states: a
            // grouped Form measured on its own reports an ideal width its
            // content never has to live within.
            #expect(abs(collapsed.ru.height - collapsed.en.height) <= 8,
                    "the Russian collapsed section differs: \(collapsed)")
            #expect(abs(expanded.ru.height - expanded.en.height) <= 8,
                    "the Russian expanded section differs: \(expanded)")
        }
    }

    /// The labels sit beside controls in a window of fixed width, and a grouped
    /// Form truncates rather than wraps. The status words are in here too: they
    /// are the longest strings in the section in Russian.
    @Test func theNDIRowLabelsFitTheSettingsForm() async throws {
        try await ViewProbe.run { probe in
            let form = ViewBudget.settingsFormWidth
            for key in ["settings_ndi", "ndi_enable", "ndi_source_name",
                        "ndi_status", "ndi_sending", "ndi_not_sending",
                        "ndi_unavailable", "ndi_failed_short"] {
                let ideal = probe.fittingSizes { Text(L(key)).fixedSize() }
                #expect(ideal.ru.width <= form,
                        "\(key) is \(ideal.ru.width)pt of \(form)")
            }
        }
    }

    /// A build with no SDK is the common case, so the section has to render the
    /// reason without stretching the settings window — **in either language,
    /// which is what changed here.**
    ///
    /// It used to be one English paragraph laid out twice, so the two heights
    /// had to agree and that agreement was the check. The reason is localized
    /// now (`BridgeUnavailable`), so the Russian is a different, longer
    /// paragraph and equal heights is no longer a property anything should
    /// want. What has to hold instead is the thing the old test was really
    /// after: NEITHER language pushes the form wider than the window.
    ///
    /// The code used is the bridge's own `not_built`, which is the one a
    /// downloaded DMG shows and the longest string this section can be asked to
    /// lay out.
    @Test func theUnavailableReasonRendersInsideTheWindow() async throws {
        // Built here rather than read off the bridge: the NDI SDK is installed
        // on the developer's Mac and absent on CI, so the real bridge answers
        // differently in the two places and this test would measure the machine.
        let unavailable = BridgeUnavailable(
            code: CNDUnavailableNotBuilt,
            english: L10n.translation("bridge_ndi_not_built") ?? "")
        try await ViewProbe.run { probe in
            probe.controller.settings.ndi.enabled = true
            probe.controller.mirrors.ndiState = .unavailable(unavailable)
            let shown = probe.sizes(proposedWidth: SettingsView.width) {
                Form { NDISettingsSection() }.formStyle(.grouped)
            }
            #expect(shown.en.width <= SettingsView.width + 1,
                    "the reason pushed the form to \(shown.en.width)pt")
            #expect(shown.ru.width <= SettingsView.width + 1,
                    "the Russian reason pushed the form to \(shown.ru.width)pt")
        }
    }

    /// **The defect this section had, stated as a render.**
    ///
    /// A Russian operator saw a localized "Состояние: Недоступно" over an
    /// English paragraph. Two halves, because no single assertion covers it:
    /// the WORDS the row is handed differ by language (exact), and the row
    /// really draws them (a height against the same section saying only "not
    /// sending").
    ///
    /// Deliberately NOT "the Russian section is a different height from the
    /// English one". Two honest translations can wrap to the same number of
    /// lines, and a test that assumed otherwise would be a coin toss on a
    /// translator's word choice. What catches a row that went back to showing
    /// the bridge's English is
    /// `BridgeLocalizationTests.theSettingsRowsShowTheWordsAndNotTheDiagnostic`,
    /// which reads the source instead of measuring it.
    @Test func theReasonIsNotTheSameParagraphInBothLanguages() async throws {
        let english: String = try #require(
            L10n.translation("bridge_ndi_not_built"))
        let unavailable = BridgeUnavailable(code: CNDUnavailableNotBuilt,
                                            english: english)
        L10n.apply(.russian)
        let russian: String = unavailable.localizedText
        L10n.apply(.english)
        #expect(russian != english,
                "the row would read English under a Russian label")
        try await ViewProbe.run { probe in
            probe.controller.settings.ndi.enabled = true
            probe.controller.mirrors.ndiState = .off
            // Ideal height, like `theNDISectionGrowsWhenItIsSwitchedOn`: a
            // PROPOSED height saturates at the loose 4000 the probe offers and
            // says nothing about what was drawn.
            let quiet = probe.fittingSizes {
                Form { NDISettingsSection() }.formStyle(.grouped)
            }
            probe.controller.mirrors.ndiState = .unavailable(unavailable)
            let shown = probe.fittingSizes {
                Form { NDISettingsSection() }.formStyle(.grouped)
            }
            // The paragraph is really drawn in Russian, not silently empty —
            // which is what an unrecognised code with no fallback would have
            // produced. Height against the same section saying only "not
            // sending", rather than against the English, because two different
            // paragraphs may honestly wrap to the same number of lines.
            #expect(shown.ru.height > quiet.ru.height,
                    "the Russian reason drew nothing: \(shown) vs \(quiet)")
            #expect(shown.en.height > quiet.en.height,
                    "the English reason drew nothing: \(shown) vs \(quiet)")
        }
    }
}
