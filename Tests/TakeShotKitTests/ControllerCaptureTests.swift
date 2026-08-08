import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The take session driven end to end through a synthetic 1080p25 source: no
/// board, no window. This is the path that actually produces footage, so the
/// assertions are the ones an operator would make — a file on the card, the
/// next clip number moved on, the markers pressed during the take attached to
/// it, and the alarm banner cleared by a clean start.
@Suite @MainActor struct ControllerCaptureTests {
    /// Roll a take for roughly `seconds`. The source sits in standby like the
    /// demo camera, so its timecode is frozen and the clock is the only thing
    /// left to pace the take against; every assertion after it waits on real
    /// state.
    private func record(_ controller: CaptureController,
                        seconds: Double) async {
        controller.toggleManualRecord()
        await ControllerWait.until { controller.isRecording }
        let deadline = Date().addingTimeInterval(seconds)
        await ControllerWait.until({ Date() >= deadline },
                                   timeout: .seconds(seconds + 45))
        controller.toggleManualRecord()
        await ControllerWait.until { !controller.isRecording }
    }

    @Test func theOnlyDeviceIsSelectedAndCaptureStartsItself() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            // selecting a device starts capture on its own — there is no
            // separate start button
            #expect(controller.selectedDeviceID
                == "mock:\(MockCaptureBackend.deviceID)")
            #expect(controller.isMockSelected)
            #expect(controller.isCapturing)
            #expect(controller.lastError == nil)

            await ControllerWait.until { controller.signalFormat != nil }
            #expect(controller.signalFormat?.width == 1920)
            #expect(controller.signalFormat?.height == 1080)
            await ControllerWait.until { controller.signalPresent }
            #expect(controller.signalPresent)
            // 16-channel SDI-style embed, stated before the first packet
            #expect(controller.backend.embeddedAudioChannels
                == MockCaptureBackend.audioChannels)

            await ControllerWait.until { controller.live.currentTimecode != nil }
            #expect(controller.live.currentTimecode?.fps == 25)
            await ControllerWait.until { !controller.live.audioLevels.isEmpty }
            #expect(controller.live.audioLevels.count
                == MockCaptureBackend.audioChannels)
        }
    }

    @Test func aManualTakeLandsOnDiskAndInTheList() async throws {
        try await ControllerHarness.run(live: true) { controller, root in
            await ControllerWait.until { controller.signalFormat != nil }

            await record(controller, seconds: 1.2)
            await ControllerWait.untilWritten { controller.takes.count == 1 }

            let take = try #require(controller.takes.first)
            #expect(take.url.lastPathComponent == "A001C01.mov")
            #expect(take.url.deletingLastPathComponent().path == root.path)
            #expect(FileManager.default.fileExists(atPath: take.url.path))
            #expect(take.roll == "001")
            #expect(take.takeNumber == 1)
            #expect(take.durationSeconds > 0)
            // the next take must not land on the name just used
            #expect(controller.nextTakeNumber == 2)
            #expect(controller.recentlyAddedURL == take.url)
            // whatever the machine's timing did to the frame budget, the take
            // itself must not have been lost
            #expect(controller.persistentAlert?.contains("TAKE LOST") != true)
        }
    }

    /// The demo source generates real sine tones on sixteen channels, so with
    /// the monitor switched off not one buffer may reach it — otherwise the app
    /// plays sound out of the machine's speakers and opens an output device a
    /// headless runner may not have at all.
    @Test func noAudioIsRoutedWhileTheMonitorIsOff() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            let routed = HitCounter()
            controller.pipeline.onMonitorAudio = { _ in routed.bump() }

            // wait until audio is demonstrably flowing through the pipeline
            await ControllerWait.until { !controller.live.audioLevels.isEmpty }
            #expect(!controller.live.audioLevels.isEmpty)
            let deadline = Date().addingTimeInterval(0.5)
            await ControllerWait.until({ Date() >= deadline },
                                       timeout: .seconds(5))

            #expect(!controller.monitorOn)
            #expect(routed.value == 0)

            // and the other direction, so the check above cannot pass by
            // accident: with the route open the same feed does arrive. The
            // sink here is the counter, not the machine's output device.
            controller.pipeline.setAudioMonitorEnabled(true)
            await ControllerWait.until({ routed.value > 0 }, timeout: .seconds(5))
            #expect(routed.value > 0)
            controller.pipeline.setAudioMonitorEnabled(false)
        }
    }

    /// The alarm banner is sticky on purpose, and the one thing that clears it
    /// automatically is a take starting cleanly.
    @Test func aCleanStartClearsTheStickyAlarm() async throws {
        try await ControllerHarness.run { controller, _ in
            let recState = try #require(controller.pipeline.onRecStateChanged)
            controller.persistentAlert = "DISK FULL (0.3 GB) — recording stopped"
            controller.recordingMarkers = [TakeMarker(seconds: 1)]

            recState(true)
            #expect(controller.isRecording)
            #expect(controller.persistentAlert == nil)
            // markers from the previous take must not bleed into this one
            #expect(controller.recordingMarkers.isEmpty)
            #expect(controller.recordingStartDate != nil)

            recState(false)
            #expect(!controller.isRecording)
        }
    }

    @Test func consecutiveTakesGetConsecutiveClipNumbers() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }

            await record(controller, seconds: 0.8)
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            await record(controller, seconds: 0.8)
            await ControllerWait.untilWritten { controller.takes.count == 2 }

            #expect(controller.takes.map(\.url.lastPathComponent)
                == ["A001C01.mov", "A001C02.mov"])
            #expect(controller.nextTakeNumber == 3)
            // and the taken-name warning now sees the first one
            controller.nextTakeNumber = 1
            #expect(controller.nameCollision == "A001C01.mov")
        }
    }

    /// A marker pressed while the take rolls is measured from the REC press,
    /// which is off by the pre-roll — it has to be re-anchored on the take's
    /// own start timecode before it lands in the sidecar.
    @Test func markersPressedDuringATakeAreAttachedToIt() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }

            controller.toggleManualRecord()
            await ControllerWait.until { controller.isRecording }
            controller.addMarker()
            #expect(controller.recordingMarkers.count == 1)
            let deadline = Date().addingTimeInterval(0.8)
            await ControllerWait.until({ Date() >= deadline },
                                       timeout: .seconds(6))
            controller.toggleManualRecord()

            await ControllerWait.untilWritten { controller.takes.count == 1 }
            let take = try #require(controller.takes.first)
            #expect(take.markers.count == 1)
            #expect(take.markers[0].seconds >= 0)
            // the queue is emptied, or the next take inherits them
            #expect(controller.recordingMarkers.isEmpty)
        }
    }

    @Test func aFinishedTakeReachesTheLogAndGrowsAThumbnail() async throws {
        try await ControllerHarness.run(live: true) { controller, root in
            await ControllerWait.until { controller.signalFormat != nil }
            await record(controller, seconds: 1.0)
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            let take = try #require(controller.takes.first)

            let log = root.appendingPathComponent(TakeLogExporter.fileName)
            let logged = await ControllerWait.untilWritten {
                (try? String(contentsOf: log, encoding: .utf8))?
                    .contains("A001C01.mov") == true
            }
            // asserted before reading, so a timeout says what went wrong
            // instead of throwing a bare "no such file"
            try #require(logged, "the take never reached \(log.lastPathComponent)")
            let csv = try String(contentsOf: log, encoding: .utf8)
            // a fresh take is unrated, and Resolve's Good Take column is a
            // checkbox: unrated is an EMPTY field, not "false" (which reads as
            // "the operator rejected it")
            #expect(csv.contains("A001C01.mov,001,1,,"))

            await ControllerWait.untilWritten { controller.thumbnails[take.id] != nil }
            #expect(controller.thumbnails[take.id] != nil)
        }
    }

    @Test func stoppingAndRestartingCaptureClosesAndReopensTheSession()
        async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }

            controller.stopCapture()
            #expect(!controller.isCapturing)
            await ControllerWait.until { controller.signalFormat == nil }
            #expect(controller.signalFormat == nil)
            #expect(controller.live.currentTimecode == nil)

            controller.startCapture()
            #expect(controller.isCapturing)
            await ControllerWait.until { controller.signalFormat != nil }
            #expect(controller.signalFormat?.height == 1080)
        }
    }

    /// Starting a device that does not exist used to return silently, leaving
    /// the UI showing "capturing" over nothing.
    @Test func selectingAnUnknownDeviceReportsItInsteadOfPretending()
        async throws {
        try await ControllerHarness.run { controller, _ in
            controller.selectedDeviceID = "nosuchbackend:zero"

            #expect(!controller.isCapturing)
            #expect(controller.lastError?.contains("Unknown capture device") == true)
        }
    }

    /// The demo source is a stand-in: the moment a real board shows up the app
    /// has to move to it by itself, or a shoot starts recording the test
    /// pattern.
    @Test func arrivingHardwareTakesOverFromTheDemoSource() async throws {
        let board = StubBackend()
        let stub = [("stub", board as CaptureBackend)]
        try await ControllerHarness.run(extraBackends: stub) { controller, _ in
            #expect(controller.isMockSelected)

            board.deviceList = [CaptureDeviceInfo(id: "cam1", name: "Stub Board")]
            controller.refreshDevices()

            #expect(controller.selectedDeviceID == "stub:cam1",
                    "a real board must take over from the demo source")
            #expect(!controller.isMockSelected)
            #expect(board.startedDeviceID == "cam1")
        }
    }

    /// The board being pulled must not leave the UI pointed at a device that
    /// is gone — that combination showed "capturing" over a dead input.
    @Test func anUnpluggedDeviceIsNotLeftSelected() async throws {
        let board = StubBackend()
        board.deviceList = [CaptureDeviceInfo(id: "cam1", name: "One"),
                            CaptureDeviceInfo(id: "cam2", name: "Two")]
        let stub = [("stub", board as CaptureBackend)]
        try await ControllerHarness.run(extraBackends: stub) { controller, _ in
            #expect(controller.selectedDeviceID == "stub:cam1")

            board.deviceList = [CaptureDeviceInfo(id: "cam2", name: "Two")]
            controller.refreshDevices()

            #expect(controller.selectedDeviceID != "stub:cam1")
            // whatever it moved to, it has to be something that exists
            let selected = try #require(controller.selectedDeviceID)
            #expect(controller.devices.map(\.id).contains(selected))
            // Deliberately NOT asserted: the L("device_disconnected") notice
            // this path sets is wiped again by the successful start on the
            // fallback device before any view can show it. Reported rather
            // than pinned, so fixing it does not have to edit this test.
        }
    }

    /// Recording-integrity failures stick in the banner; everything else is a
    /// five-second toast. Getting this backwards is how a lost take gets
    /// announced more quietly than a dropped frame.
    @Test func integrityFailuresStickAndTheRestJustToast() async throws {
        try await ControllerHarness.run { controller, _ in
            let onError = try #require(controller.pipeline.onError)

            onError("TAKE LOST: A001C01 (writer failed)")
            #expect(controller.persistentAlert?.hasPrefix("TAKE LOST") == true)
            #expect(controller.lastError == nil)

            onError("Take closed: input format changed")
            #expect(controller.persistentAlert == "Take closed: input format changed")

            onError("Failed to start recording")
            #expect(controller.persistentAlert == "Failed to start recording")

            onError("Pre-roll incomplete: 2 of 5 frames")
            #expect(controller.persistentAlert?.hasPrefix("Pre-roll") == true)

            onError("Playout output stalled")
            #expect(controller.lastError == "Playout output stalled")
            // and the sticky one is still up underneath the toast
            #expect(controller.persistentAlert?.hasPrefix("Pre-roll") == true)
        }
    }

    /// Multicam on the demo source adds a second camera, lettered on from the
    /// main one. This is the one test that starts a real `MockCaptureBackend`
    /// (the controller builds it itself), so it is kept as short as possible —
    /// see the crash reported against that backend's AppKit drawing.
    @Test func multicamAddsAndRemovesTheSecondDemoCamera() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(controller.extraChannels.isEmpty)
            #expect(controller.allCameraLabels == ["A"])

            controller.toggleMulticam()
            #expect(controller.multicamOn)
            #expect(controller.extraChannels.count == 1)
            #expect(controller.allCameraLabels == ["A", "B"])

            controller.toggleMulticam()
            #expect(!controller.multicamOn)
            #expect(controller.extraChannels.isEmpty)
            #expect(controller.allCameraLabels == ["A"])
        }
    }
}
