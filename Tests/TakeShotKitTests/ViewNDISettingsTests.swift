import AppKit
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
    /// reason without stretching the settings window. The reason is English in
    /// both languages — it names a file in the source tree, and a translated
    /// path is a worse instruction than the path.
    ///
    /// The text used is the bridge's OWN, not a paraphrase: it is the longest
    /// string this section can be asked to lay out, and a message rewritten to
    /// read better for an operator is exactly the change that would push the
    /// form wider without anyone measuring it again.
    @Test func theUnavailableReasonRendersInsideTheWindow() async throws {
        let reason: String = try #require(NDISender.unavailableReason
            ?? "Built without the NDI SDK. Building with it is described in "
                + "vendor/NDISDK/README.md.")
        try await ViewProbe.run { probe in
            probe.controller.settings.ndi.enabled = true
            probe.controller.mirrors.ndiState = .unavailable(reason)
            let shown = probe.sizes(proposedWidth: SettingsView.width) {
                Form { NDISettingsSection() }.formStyle(.grouped)
            }
            #expect(shown.en.width <= SettingsView.width + 1,
                    "the reason pushed the form to \(shown.en.width)pt")
            #expect(abs(shown.ru.height - shown.en.height) <= 8,
                    "the reason wrapped differently by language: \(shown)")
        }
    }
}
