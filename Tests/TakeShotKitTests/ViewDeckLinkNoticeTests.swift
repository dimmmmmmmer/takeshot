import AppKit
import SwiftUI
import Testing

@testable import TakeShotKit

extension DeckLinkDiagnosis {
    /// The three states that have something to tell the operator. `.loaded`
    /// is not one of them and is asserted separately, because "says nothing"
    /// is its contract rather than an omission.
    static let faults: [DeckLinkDiagnosis] = [.stub, .runtimeMissing,
                                              .signatureSuspect]
}

/// Where the operator meets `DeckLinkDiagnosis`: the Settings device row and
/// the overlay over the live picture.
///
/// EVERY state here is hand-set. The development Mac has the DeckLink headers
/// and Desktop Video installed, a worktree checkout has no headers at all, and
/// the CI runner has neither — so a test that read `DeckLinkProbe.diagnosis`
/// would assert `.loaded` on one machine and `.stub` on the next and mean
/// nothing on either. Same reasoning as the hand-built snapshots in
/// `ModelDiagnosticsTests`.
///
/// Heights are NOT compared across languages here, unlike most View suites: the
/// remedy is a sentence that wraps, and Russian runs half again as long, so a
/// different line count is the expected outcome rather than a fault. What has
/// to hold is that it wraps INSIDE its container instead of truncating — the
/// signature case's remedy is the last clause of its sentence.
@Suite @MainActor struct ViewDeckLinkNoticeTests {
    // MARK: - the Settings device row

    /// The permanent home of the message, under the picker where the device is
    /// chosen. One row per fault, fitting the settings form in both languages.
    @Test func theDeviceRowExplainsEveryFaultInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let form = ViewBudget.settingsFormWidth
            for fault in DeckLinkDiagnosis.faults {
                DeckLinkProbe.overrideDiagnosis(fault)
                let row = probe.sizes(proposedWidth: form) {
                    DeckLinkNoticeRow()
                }
                #expect(row.en.height > 0,
                        "\(fault.rawValue) drew nothing under the picker")
                #expect(row.ru.height > 0,
                        "\(fault.rawValue) drew nothing in Russian")
                #expect(row.en.width <= form + 0.5,
                        "\(fault.rawValue) overflowed \(form)pt: \(row.en.width)pt")
                #expect(row.ru.width <= form + 0.5,
                        "\(fault.rawValue) overflowed \(form)pt in Russian: \(row.ru.width)pt")
                // Two lines at least — a headline and the remedy under it. One
                // line means the detail was dropped or truncated away, which is
                // how the signature case would lose the entitlement it names.
                #expect(row.en.height > 24,
                        "\(fault.rawValue) fits one line: \(row.en.height)pt")
                #expect(row.ru.height > 24,
                        "\(fault.rawValue) fits one line in Russian: \(row.ru.height)pt")
            }
        }
    }

    /// A build that can see boards says nothing here at all.
    @Test func theDeviceRowIsSilentWhenTheBuildCanSeeBoards() async throws {
        try await ViewProbe.run { probe in
            DeckLinkProbe.overrideDiagnosis(.loaded)
            let row = probe.sizes(proposedWidth: ViewBudget.settingsFormWidth) {
                DeckLinkNoticeRow()
            }
            #expect(row.en.height == 0, "a working build was explained anyway")
            #expect(row.ru.height == 0)
        }
    }

    /// The whole settings form still measures the same in both languages with
    /// the notice in it, and the notice really is inside the device section —
    /// the form grows by the row's own height and not by more.
    @Test func theSettingsFormCarriesTheNoticeWithoutMovingItsWidth()
        async throws {
        try await ViewProbe.run { probe in
            DeckLinkProbe.overrideDiagnosis(.loaded)
            let quiet = probe.fittingSizes { SettingsView() }
            DeckLinkProbe.overrideDiagnosis(.signatureSuspect)
            let explained = probe.fittingSizes { SettingsView() }

            #expect(explained.en.width == quiet.en.width,
                    "the notice widened the settings window")
            #expect(explained.ru.width == quiet.ru.width)
            #expect(explained.en.height > quiet.en.height,
                    "the notice was not rendered inside the form")
            #expect(explained.ru.height > quiet.ru.height)
        }
    }

    // MARK: - the demo source does not swallow it

    /// The point of the whole change: the demo source is in every build's
    /// device list unconditionally, and its presence must not be read as "a
    /// device is available, so there is nothing to explain". A real UltraStudio
    /// plugged into a stub build has to produce a message even though the
    /// picker is not empty.
    @Test func theNoticeSurvivesTheDemoSourceBeingAvailable() async throws {
        try await ViewProbe.run { probe in
            DeckLinkProbe.overrideDiagnosis(.stub)
            probe.controller.refreshDevices()
            // exactly the shipping stub-build situation: one entry, the demo
            // source, and the backend reporting itself perfectly available
            #expect(!probe.controller.devices.isEmpty,
                    "the demo source left the device list")
            #expect(probe.controller.devices.allSatisfy {
                $0.id.hasPrefix("mock:")
            }, "a hardware device reached a stub-build fixture")
            #expect(probe.controller.backend.isAvailable,
                    "the demo source stopped pinning availability to true")

            let row = probe.sizes(proposedWidth: ViewBudget.settingsFormWidth) {
                DeckLinkNoticeRow()
            }
            #expect(row.en.height > 0,
                    "the demo source silenced the stub-build message")
            #expect(row.ru.height > 0)
        }
    }

    // MARK: - the overlay over the picture

    /// Where the picture would be. `.loaded` keeps the old single line, which
    /// now means what it says; each fault adds its own reason under it, so the
    /// overlay is taller than the bare "no devices found".
    @Test func theLiveOverlayNamesTheBuildRatherThanTheCable() async throws {
        try await ViewProbe.run { probe in
            let player = ViewBudget.playerWidth
            DeckLinkProbe.overrideDiagnosis(.loaded)
            let cable = probe.sizes(proposedWidth: player) {
                LiveStatusOverlay()
            }
            #expect(cable.en.height > 0, "the overlay drew nothing")

            for fault in DeckLinkDiagnosis.faults {
                DeckLinkProbe.overrideDiagnosis(fault)
                let explained = probe.sizes(proposedWidth: player) {
                    LiveStatusOverlay()
                }
                #expect(explained.en.height > cable.en.height,
                        "\(fault.rawValue) read like a loose cable")
                #expect(explained.ru.height > cable.ru.height,
                        "\(fault.rawValue) read like a loose cable in Russian")
                #expect(explained.en.width <= player + 0.5,
                        "\(fault.rawValue) overflowed the player: \(explained.en.width)pt")
                #expect(explained.ru.width <= player + 0.5,
                        "\(fault.rawValue) overflowed it in Russian: \(explained.ru.width)pt")
            }
        }
    }

    /// …and it must not stretch the surface it floats over. The overlay is a
    /// ZStack member on the player, so a paragraph that pushed the layout out
    /// would move the picture rather than wrap.
    @Test func theLiveOverlayDoesNotStretchThePlayer() async throws {
        try await ViewProbe.run { probe in
            let size = CGSize(width: 720, height: 405)
            for fault in DeckLinkDiagnosis.faults {
                DeckLinkProbe.overrideDiagnosis(fault)
                let laid = ViewRender.bothLanguages({
                    ViewRender.laidOutSize($0, in: size)
                }, { probe.hosted(PreviewView()) })
                #expect(laid.en == size,
                        "\(fault.rawValue) resized the player to \(laid.en)")
                #expect(laid.ru == size,
                        "\(fault.rawValue) resized it in Russian: \(laid.ru)")
            }
        }
    }
}
