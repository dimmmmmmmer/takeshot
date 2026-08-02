import AppKit
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The menu-bar item, from its model's side.
///
/// An `NSStatusItem` and its `NSMenu` are built by AppKit at click time and can
/// be neither measured nor clicked from a test — which is exactly why
/// `MenuBarModel` exists apart from `MenuBarPresence` (the same split
/// `SlateModel` has from `SlateView`). Everything below runs headlessly: no
/// status item is ever created, so the suite cannot put an icon in the menu bar
/// of whoever runs it.
@Suite @MainActor struct ModelMenuBarTests {
    private func recordItem(_ model: MenuBarModel) throws -> MenuBarModel.Item {
        try #require(model.items.first { $0.command == .toggleRecord })
    }

    // MARK: - what the button says

    /// Nothing captured, nothing on the wire: the item says so, and the record
    /// row is greyed. A Stop item while idle is a lie, and so is a live-looking
    /// REC with no device behind it.
    @Test func idleShowsNoSignalAndOffersNoStop() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.isCapturing, "the harness starts this one stopped")
            let model = MenuBarModel(controller: controller)

            #expect(model.presence == .idle)
            #expect(model.symbolName == "video.slash")
            #expect(!model.isAlarmColored)
            #expect(model.statusTitle.isEmpty)
            #expect(model.tooltip == L("menubar_status_idle"))

            let record = try recordItem(model)
            #expect(record.title == L("record"))
            #expect(!record.enabled)
        }
    }

    /// A live signal with no take running: armed. Still no timecode in the bar
    /// — the number is about a take, not about the clock.
    @Test func armedShowsReadyAndCarriesNoTimecode() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until {
                controller.isCapturing && controller.signalPresent
            }
            let model = MenuBarModel(controller: controller)

            #expect(model.presence == .ready)
            #expect(model.symbolName == "video")
            #expect(!model.isAlarmColored)
            #expect(model.statusTitle.isEmpty)
            #expect(model.tooltip == L("menubar_status_ready"))

            let record = try recordItem(model)
            #expect(record.title == L("record"))
            #expect(record.enabled)
        }
    }

    // MARK: - the record item is the app's own record path

    /// The one assertion this whole feature stands on: the menu item does not
    /// reimplement recording, it presses the same `toggleManualRecord` the REC
    /// button and the phone press — so a take started from the menu bar is a
    /// take, with a file behind it and a row in the list.
    @Test func theRecordItemRollsARealTakeThroughTheControllersOwnPath()
        async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            let model = MenuBarModel(controller: controller)

            #expect(model.perform(.toggleRecord))
            await ControllerWait.until { controller.isRecording }
            #expect(controller.isRecording)

            model.refresh()
            #expect(model.presence == .recording)
            #expect(model.symbolName == "record.circle.fill")
            #expect(model.isAlarmColored, "REC has to be red, not a template glyph")
            #expect(model.tooltip == L("menubar_status_recording"))
            let rolling = try recordItem(model)
            #expect(rolling.title == L("stop"))

            // long enough to be a file rather than a header
            let deadline = Date().addingTimeInterval(1.2)
            await ControllerWait.until({ Date() >= deadline },
                                       timeout: .seconds(46))
            #expect(model.perform(.toggleRecord))
            await ControllerWait.until { !controller.isRecording }
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            #expect(controller.takes.count == 1)
        }
    }

    /// The take row names the take being written — the same `pendingTakeName`
    /// the collision warning, the slate and the phone read.
    @Test func theTakeRowNamesTheTakeAndIsNotClickable() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = MenuBarModel(controller: controller)
            let row = try #require(model.items.first {
                $0.command == nil && !$0.isSeparator
            })
            #expect(!row.enabled, "the take name is a readout, not a control")
            #expect(row.title == L("menubar_take", controller.pendingTakeName))
            #expect(row.title.contains(controller.pendingTakeName))
        }
    }

    // MARK: - marker

    /// Greyed with nothing to mark, and it refuses the command in that state
    /// rather than trusting AppKit not to send it. Rolling, it drops a marker
    /// on the take in progress.
    @Test func theMarkerItemIsGatedAndThenAddsAMarker() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            let model = MenuBarModel(controller: controller)

            let idle = try #require(model.items.first { $0.command == .addMarker })
            #expect(!idle.enabled)
            #expect(!model.perform(.addMarker),
                    "a greyed item that still fires is worse than a greyed one")
            #expect(controller.recordingMarkers.isEmpty)

            model.perform(.toggleRecord)
            await ControllerWait.until { controller.isRecording }
            #expect(model.items.first { $0.command == .addMarker }?.enabled == true)
            #expect(model.perform(.addMarker))
            #expect(controller.recordingMarkers.count == 1)

            controller.toggleManualRecord()
            await ControllerWait.until { !controller.isRecording }
        }
    }

    // MARK: - mute

    /// The check mark IS the controller's mute state, in both directions: the
    /// item drives `toggleMonitorMute` and reads back through the same flag the
    /// footer speaker draws from.
    @Test func muteMirrorsTheControllerBothWays() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = MenuBarModel(controller: controller)
            let checked = { @MainActor in
                model.items.first { $0.command == .toggleMute }?.checked
            }

            #expect(checked() == false)
            #expect(model.perform(.toggleMute))
            #expect(controller.live.muted)
            #expect(checked() == true)

            // …and a mute pressed anywhere else shows up here
            controller.toggleMonitorMute()
            #expect(!controller.live.muted)
            #expect(checked() == false)

            controller.mutePersistTask?.cancel()
        }
    }

    // MARK: - the timecode throttle

    /// The timecode arrives at the signal's frame rate. A status item redrawn
    /// per frame re-lays out the system's own menu bar 25 times a second for a
    /// readout no eye resolves that fast, so the title is gated to 2 Hz.
    ///
    /// Driven off an injected clock rather than a sleep: the assertion is about
    /// the RATE, and two seconds of real waiting would prove it less exactly.
    @Test func theTimecodeTitleIsThrottledInsteadOfRedrawnPerFrame()
        async throws {
        try await ControllerHarness.run { controller, _ in
            let model = MenuBarModel(controller: controller)
            var clock = Date(timeIntervalSinceReferenceDate: 0)
            model.now = { clock }

            controller.isRecording = true
            model.refresh()
            #expect(model.presence == .recording)

            // two seconds of 25 fps
            let frames = 50
            for frame in 0..<frames {
                clock = Date(timeIntervalSinceReferenceDate: Double(frame) / 25)
                model.timecodeTicked()
            }
            // t=0 (the transition into REC), then 0.52, 1.04, 1.56
            let emissions = model.titleEmissions
            let gate = MenuBarModel.titleInterval
            #expect(emissions == 4,
                    "\(emissions) title updates for \(frames) frames at a \(gate)s gate")
            #expect(gate == 0.5)

            // leaving REC takes the number away rather than freezing the last
            // one up there for the rest of the day
            controller.isRecording = false
            model.refresh()
            #expect(model.presence == .idle)
            #expect(model.statusTitle.isEmpty)
        }
    }

    // MARK: - quit

    /// Quit goes through the app's own terminate path — the one that runs
    /// `flushOnTerminate` and closes a take that is still being written. It is
    /// injected here only so pressing it does not take the test runner with it.
    @Test func quitRoutesThroughTheTerminatePath() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = MenuBarModel(controller: controller)
            let fired = HitCounter()
            model.quitAction = { fired.bump() }

            #expect(model.perform(.quit))
            #expect(fired.value == 1)
        }
    }

    // MARK: - the menu's shape

    /// Every command the menu offers is reachable exactly once. Two rows onto
    /// one action is how a menu and a button drift apart.
    @Test func everyCommandAppearsExactlyOnce() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = MenuBarModel(controller: controller)
            for command in MenuBarModel.Command.allCases {
                let count = model.items.filter { $0.command == command }.count
                #expect(count == 1, "\(command.rawValue) appears \(count) times")
            }
            #expect(model.items.contains { $0.isSeparator },
                    "ten rows with no grouping is a list, not a menu")
        }
    }

    // MARK: - the setting

    /// Off until it is asked for, and back where it was left afterwards.
    @Test func theKeepInMenuBarSettingRoundTrips() {
        let defaults = InMemoryDefaults()
        var settings = CaptureSettings()
        #expect(settings.keepInMenuBar == nil,
                "the menu bar is not TakeShot's until somebody says so")

        settings.keepInMenuBar = true
        settings.save(to: defaults)
        #expect(CaptureSettings.loaded(from: defaults).keepInMenuBar == true)

        settings.keepInMenuBar = nil
        settings.save(to: defaults)
        #expect(CaptureSettings.loaded(from: defaults).keepInMenuBar == nil)
    }

    /// An install that never touched the switch writes no field at all, which
    /// is what keeps a settings blob decodable by a build that predates it.
    @Test func anUntouchedInstallWritesNoMenuBarField() throws {
        let data = try JSONEncoder().encode(CaptureSettings())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("keepInMenuBar"))
        let decoded = try JSONDecoder().decode(CaptureSettings.self, from: data)
        #expect(decoded.keepInMenuBar == nil)
    }

    /// The controller's own read of the setting, which is what installs or
    /// removes the item. No presence is built here — that would put a real
    /// icon in the menu bar of whoever runs the suite.
    @Test func theControllerReadsTheSettingWithoutInstallingAnything()
        async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.keepInMenuBar)
            #expect(controller.menuBar == nil,
                    "startup installed a status item nobody asked for")
        }
    }

    /// Quitting from the menu-bar item with no window open still has to close a
    /// take that is being written. That runs off the delegate's controller
    /// reference — whose other assignment is ContentView's `onAppear`, which in
    /// that exact situation has not run.
    @Test func aControllerHandsItselfToTheDelegateThatFlushesItOnQuit()
        async throws {
        let delegate = AppDelegate()
        #expect(AppDelegate.shared === delegate)
        try await ControllerHarness.run { controller, _ in
            #expect(delegate.controller === controller,
                    "a quit from the menu bar would flush nothing")
        }
        withExtendedLifetime(delegate) {}
    }

    // MARK: - localization

    /// Every string the item and its menu put on screen. A key with a typo
    /// renders as itself, which no build or lint step notices.
    private static let keys = [
        "menubar_keep", "menubar_keep_hint", "menubar_take", "menubar_no_take",
        "menubar_mute_monitor", "menubar_open_main", "menubar_quit",
        "menubar_status_idle", "menubar_status_ready", "menubar_status_recording",
        // reused, because the item and the button are the same action
        "record", "stop", "hotkey_marker", "menu_slate",
    ]

    @Test func everyMenuBarStringResolvesInBothLanguages() {
        for language in [AppLanguage.english, .russian] {
            ViewRender.withLanguage(language) {
                for key in Self.keys {
                    #expect(L(key) != key,
                            "\(key) renders as its raw key in \(language.rawValue)")
                }
            }
        }
    }

    /// Menu rows are titles. The one sentence here is the settings caption,
    /// which is not a menu row.
    @Test func menuRowTitlesAreTitlesNotSentences() {
        let rows = Self.keys.filter { $0 != "menubar_keep_hint" && $0 != "menubar_keep" }
        for language in [AppLanguage.english, .russian] {
            ViewRender.withLanguage(language) {
                for key in rows {
                    #expect(L(key).count <= 40,
                            "\(key) is \(L(key).count) characters long")
                }
            }
        }
    }
}
