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
@MainActor
struct ViewNDISettingsTests {
    @Test func theNDISectionGrowsWhenItIsSwitchedOn() async throws {
        try await ViewProbe.run { probe in
            let collapsed = probe.fittingSizes {
                Form { NDISettingsSection() }.formStyle(.grouped)
            }
            probe.controller.settings.ndiEnabled = true
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
    /// both languages — it names a directory, and a translated path is a worse
    /// instruction than the path.
    @Test func theUnavailableReasonRendersInsideTheWindow() async throws {
        try await ViewProbe.run { probe in
            probe.controller.settings.ndiEnabled = true
            probe.controller.mirrors.ndiState = .unavailable(
                "Built without the NDI SDK. Download the NDI SDK for Apple "
                    + "from ndi.video, then copy its headers into "
                    + "vendor/NDISDK/include and rebuild.")
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
