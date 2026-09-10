import AppKit
import CSRT
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The SRT section of the settings window. Its own file rather than more rows in
/// `ViewSettingsTests`, which is already near the file-length ceiling.
///
/// What a render can say that a unit test cannot: the section is one row while the
/// switch is off (a feature nobody asked for costs no height), it grows when it is
/// thrown, it grows again for the role that needs an address, and none of those
/// states wrapped differently in Russian — a truncated label in a grouped Form
/// throws nothing and shows up only as a size.
@MainActor
struct ViewSRTSettingsTests {
    @Test func theSRTSectionGrowsWhenItIsSwitchedOn() async throws {
        try await ViewProbe.run { probe in
            let collapsed = probe.fittingSizes {
                Form { SRTSettingsSection() }.formStyle(.grouped)
            }
            probe.controller.settings.srt.enabled = true
            let expanded = probe.fittingSizes {
                Form { SRTSettingsSection() }.formStyle(.grouped)
            }
            #expect(expanded.en.height > collapsed.en.height,
                    "the switched-on section did not grow: \(expanded)")
            // Height, not width, for the reason the remote's test states: a
            // grouped Form measured on its own reports an ideal width its content
            // never has to live within.
            #expect(abs(collapsed.ru.height - collapsed.en.height) <= 8,
                    "the Russian collapsed section differs: \(collapsed)")
            #expect(abs(expanded.ru.height - expanded.en.height) <= 8,
                    "the Russian expanded section differs: \(expanded)")
        }
    }

    /// **A listener and a caller are the same three rows.** The connection type
    /// is part of the ADDRESS now — `srt://:8890?mode=listener` — rather than a
    /// picker of its own, so nothing appears or disappears with the role and
    /// the section does not change shape under the operator (owner: "и все еще
    /// тут есть порт, delivery buffer и connection type — обсуждали же что это
    /// не настройки").
    @Test func aListenerAndACallerAreTheSameRows() async throws {
        try await ViewProbe.run { probe in
            probe.controller.settings.srt.enabled = true
            let caller = probe.fittingSizes {
                Form { SRTSettingsSection() }.formStyle(.grouped)
            }
            probe.controller.settings.srt.role = SRTRole.listener.rawValue
            let listener = probe.fittingSizes {
                Form { SRTSettingsSection() }.formStyle(.grouped)
            }
            // **Rows, not points.** The claim is that nothing appears or
            // disappears with the role, and a row here is 28pt — so the
            // tolerance is far below anything that could hide one.
            //
            // It was an exact equality, and it failed once inside a full
            // battery by 2pt in English only (463 against 461) having never
            // failed alone. The cause was NOT established: the latency
            // sentence, which is the one text here that can change under a
            // render, measures 461 either way (checked both branches), and
            // four caller/listener pairs measured in one process came back
            // identical. So this is a tolerance against an unexplained 2pt,
            // written as such rather than dressed as a fix.
            #expect(abs(listener.en.height - caller.en.height) <= 2, """
                the section changed shape with the role: \(listener) vs \(caller)
                """)
            #expect(abs(listener.ru.height - listener.en.height) <= 8,
                    "the Russian listener section differs: \(listener)")
        }
    }

    /// **A long address does not stretch the pane.** A MediaMTX publish URL is
    /// a hundred characters, and the field used to grow with its content —
    /// stretching the row, the box and the window with it (owner: "длинный
    /// адрес srt увеличивает строчку его ввода, увеличивает бокс и ломает ui").
    @Test func aLongAddressDoesNotStretchTheSection() async throws {
        try await ViewProbe.run { probe in
            probe.controller.settings.srt.enabled = true
            let short = probe.fittingSizes {
                Form { SRTSettingsSection() }.formStyle(.grouped)
            }
            probe.controller.settings.srt.address = "192.168.1.119"
            probe.controller.settings.srt.port = 8890
            probe.controller.settings.srt.streamID =
                "publish:live:admin:14190b05fadd3bf5b8fad550600c686ccf79224b3939c3e0"
            let long = probe.fittingSizes {
                Form { SRTSettingsSection() }.formStyle(.grouped)
            }
            #expect(long.en.width == short.en.width, """
                the pane grew from \(short.en.width) to \(long.en.width) for a \
                long address
                """)
            #expect(long.en.height == short.en.height,
                    "the address row wrapped: \(long) vs \(short)")
        }
    }

    /// The labels sit beside controls in a window of fixed width, and a grouped
    /// Form truncates rather than wraps. The role labels are in here for a reason
    /// of their own: they carry the section's one real explanation, so they are the
    /// longest strings in it and the first thing a translation would break.
    @Test func theSRTRowLabelsFitTheSettingsForm() async throws {
        try await ViewProbe.run { probe in
            let form = ViewBudget.settingsFormWidth
            for key in ["settings_srt", "srt_enable", "srt_role",
                        "srt_role_caller", "srt_role_listener", "srt_address",
                        "srt_port", "srt_latency", "srt_bitrate",
                        "srt_passphrase", "srt_status", "srt_starting",
                        "srt_sending", "srt_not_sending", "srt_reconnecting",
                        "srt_unavailable", "srt_failed_short"] {
                let ideal = probe.fittingSizes { Text(L(key)).fixedSize() }
                #expect(ideal.ru.width <= form,
                        "\(key) is \(ideal.ru.width)pt of \(form)")
            }
        }
    }

    /// A build with no libsrt is the common case, so the section has to render the
    /// reason without stretching the settings window — **in either language, which
    /// is what changed here.**
    ///
    /// It used to be one English paragraph laid out twice, so the two heights had
    /// to agree and that agreement was the check. The reason is localized now
    /// (`BridgeUnavailable`), so the Russian is a different paragraph and equal
    /// heights is no longer a property anything should want. What has to hold
    /// instead is the thing the old test was really after: NEITHER language pushes
    /// the form wider than the window.
    @Test func theUnavailableReasonRendersInsideTheWindow() async throws {
        // Built here rather than read off the bridge, so this measures the row
        // and not which vendor drops the machine running it happens to have.
        let unavailable = BridgeUnavailable(
            code: CSRTUnavailableNotBuilt,
            english: L10n.translation("bridge_srt_not_built") ?? "")
        try await ViewProbe.run { probe in
            probe.controller.settings.srt.enabled = true
            probe.controller.mirrors.srtState = .unavailable(unavailable)
            let shown = probe.sizes(proposedWidth: SettingsView.width) {
                Form { SRTSettingsSection() }.formStyle(.grouped)
            }
            #expect(shown.en.width <= SettingsView.width + 1,
                    "the reason pushed the form to \(shown.en.width)pt")
            #expect(shown.ru.width <= SettingsView.width + 1,
                    "the Russian reason pushed the form to \(shown.ru.width)pt")
        }
    }

    /// …and the longest of the four, which is the one that names every path the
    /// dlopen looked at. Nothing else in the suite lays that out, and it is the
    /// only line whose length is not something a translator controls.
    @Test func theSearchedPathsRenderInsideTheWindowToo() async throws {
        let paths: [String] = CSRTSender.runtimeSearchPaths()
        let unavailable = BridgeUnavailable(
            code: CSRTUnavailableRuntimeMissing,
            english: L10n.translation("bridge_srt_runtime_missing") ?? "",
            details: paths.isEmpty
                ? ["/opt/homebrew/lib/libsrt.dylib",
                   "/opt/homebrew/lib/libsrt.1.5.dylib",
                   "/usr/local/lib/libsrt.dylib",
                   "/usr/local/lib/libsrt.1.5.dylib"]
                : paths)
        try await ViewProbe.run { probe in
            probe.controller.settings.srt.enabled = true
            probe.controller.mirrors.srtState = .unavailable(unavailable)
            let shown = probe.sizes(proposedWidth: SettingsView.width) {
                Form { SRTSettingsSection() }.formStyle(.grouped)
            }
            #expect(shown.en.width <= SettingsView.width + 1,
                    "the paths pushed the form to \(shown.en.width)pt")
            #expect(shown.ru.width <= SettingsView.width + 1,
                    "the Russian paths pushed the form to \(shown.ru.width)pt")
        }
    }

    /// …and so does a reconnect reason, which is the one an operator reads mid-shoot
    /// and the longest thing libsrt hands back.
    @Test func theReconnectReasonRendersInsideTheWindow() async throws {
        try await ViewProbe.run { probe in
            probe.controller.settings.srt.enabled = true
            probe.controller.mirrors.srtEndpoint = SRTEndpoint(
                role: .caller, address: "10.0.4.21", port: 9312,
                latencyMs: 200, passphrase: nil)
            probe.controller.mirrors.srtState = .reconnecting(
                "cannot reach 10.0.4.21:9312 — Connection setup failure: "
                    + "connection time out")
            let shown = probe.sizes(proposedWidth: SettingsView.width) {
                Form { SRTSettingsSection() }.formStyle(.grouped)
            }
            #expect(shown.en.width <= SettingsView.width + 1,
                    "the reason pushed the form to \(shown.en.width)pt")
            #expect(abs(shown.ru.height - shown.en.height) <= 8,
                    "the reason wrapped differently by language: \(shown)")
        }
    }
}
