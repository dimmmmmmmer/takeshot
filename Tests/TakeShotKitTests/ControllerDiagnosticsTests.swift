import CDeckLink
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// "Collect diagnostics", driven through the controller.
///
/// The case that matters is the broken one — no device selected, no record
/// folder there, nothing running — because that is when the operator reaches
/// for this. The other three assertions are the promises the feature makes: the
/// PIN never leaves, the bundle lands somewhere the test chose (never the
/// operator's Desktop), and pressing it mid-take costs the take nothing.
@Suite @MainActor struct ControllerDiagnosticsTests {
    /// A folder the bundle is written into. Never the Desktop: the app's
    /// default destination is the operator's, and no suite may write there.
    private func scratch(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("diagnostics-out")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// Collect into `parent` and hand back the folder that appeared. The
    /// Finder is stubbed out for the duration — the real one opens a window on
    /// whoever is running the suite.
    private func collect(_ controller: CaptureController,
                         into parent: URL) async throws -> URL {
        let previous = FinderOpen.handler
        FinderOpen.handler = { _ in }
        defer { FinderOpen.handler = previous }
        controller.collectDiagnostics(into: parent)
        // Wait for the OUTCOME, not for the files. `collectDiagnostics` writes
        // the bundle inside its task and only then reports — so a wait that
        // stops at "the folder is not empty" returns while the task is still
        // running, and a caller that goes on to read `lastNotice` reads it
        // before it is set. That is what it did: green here for months, then red
        // on a loaded run and again under ThreadSanitizer, both of which widen
        // the window rather than create it. Either branch settles this wait, so
        // a failure to write is a failed assertion below rather than a hang.
        await ControllerWait.untilWritten {
            controller.lastNotice != nil || controller.lastError != nil
        }
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: parent.path)
        let name = try #require(entries.first, "no bundle folder was written")
        #expect(entries.count == 1)
        return parent.appendingPathComponent(name)
    }

    private func read(_ folder: URL, _ file: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(file),
                   encoding: .utf8)
    }

    // MARK: - the broken rig

    /// Nothing attached, nothing configured, nothing running. The bundle is
    /// still produced, and every section says what is absent rather than being
    /// absent itself.
    @Test func theBundleIsProducedWithNoDeviceAndNoFolder() async throws {
        try await ControllerHarness.run { controller, root in
            let out = try scratch(in: root)
            // No device: the harness selects its synthetic source in init, so
            // the "nothing plugged in" state has to be asked for.
            controller.selectedDeviceID = nil
            controller.stopCapture()
            // No record folder. Pointing it at a path that does not exist is
            // the real fault (a card that was ejected, a path from another
            // machine) — and the watcher re-creates the folder when it is
            // armed, so it goes first.
            let missing = root.appendingPathComponent("no-such-folder")
            controller.settings.capture.destinationPath = missing.path
            controller.folderWatcher?.cancel()
            controller.folderWatcher = nil
            try? FileManager.default.removeItem(at: missing)

            let folder = try await collect(controller, into: out)
            let report = try read(folder, DiagnosticsBundle.reportFileName)

            // all three files, and none of them empty
            for file in [DiagnosticsBundle.reportFileName,
                         DiagnosticsBundle.jsonFileName,
                         DiagnosticsBundle.logFileName] {
                #expect(try read(folder, file).count > 20,
                        "\(file) came out empty")
            }
            #expect(report.contains("Folder exists"))
            #expect(report.contains("no-such-folder"))
            #expect(report.contains("none selected"))
            #expect(report.contains("No takes this session."))
            #expect(report.contains("none — no signal detected"))
            // and the operator was told where it went
            #expect(controller.lastError == nil)
            #expect(controller.lastNotice?.contains(folder.lastPathComponent)
                == true)
        }
    }

    /// The verdict is the pure mapping of three facts, and it is reported next
    /// to those three facts so a reader can check it rather than take it on
    /// trust.
    ///
    /// What this build IS is deliberately not asserted here: CI has no SDK
    /// headers and the owner's own Mac has both the headers and Desktop Video,
    /// so an assertion about the host would say "stub" on one machine and
    /// "loaded" on the other and mean nothing on either. The four verdicts and
    /// the words the stub build prints are pinned in `ModelDiagnosticsTests`,
    /// against snapshots that do not depend on the machine at all.
    @Test func theDeckLinkSectionIsConsistentWithItsOwnFacts() async throws {
        try await ControllerHarness.run { controller, root in
            let out = try scratch(in: root)
            let deck = controller.diagnosticsSnapshot().deckLink

            #expect(deck.diagnosis == DeckLinkDiagnosis.of(
                compiledWithSDK: deck.compiledWithSDK,
                runtimeLoaded: deck.runtimeLoaded,
                frameworkPresent: deck.frameworkPresent))
            #expect(deck.diagnosisText == deck.diagnosis.explanation)
            #expect(deck.compiledWithSDK == CDLDeviceManager.isCompiledWithSDK())
            #expect(deck.runtimeLoaded == CDLDeviceManager.isSDKAvailable())
            #expect(deck.frameworkPresent == FileManager.default
                .fileExists(atPath: DeckLinkProbe.frameworkPath))
            // A runtime that loaded cannot have come from nowhere.
            if deck.runtimeLoaded { #expect(deck.frameworkPresent) }

            let folder = try await collect(controller, into: out)
            let report = try read(folder, DiagnosticsBundle.reportFileName)
            #expect(report.contains("Compiled with SDK"))
            #expect(report.contains("Runtime loaded"))
            #expect(report.contains("Framework on disk"))
            #expect(report.contains("Desktop Video"))
            #expect(report.contains(deck.diagnosis.rawValue))
        }
    }

    // MARK: - the PIN

    /// Whether a PIN leaked, as opposed to merely occurring.
    ///
    /// A bare `contains` cannot tell the two apart, and the difference is not
    /// academic: the app's PIN is FOUR DIGITS (`ensureRemotePIN` regenerates
    /// anything else), macOS hands out ephemeral ports from 49152–65535, and
    /// 54271 contains 4271. This test used to fail whenever the kernel picked
    /// one of those and report a leaked credential that was really the port it
    /// also asserts is present. Free space and file sizes in bytes are longer
    /// numbers with the same hazard.
    ///
    /// A leak writes the PIN as a value — `PIN: 4271`, `"remotePIN":"4271"` —
    /// so it has a non-digit on both sides. An accidental occurrence is inside
    /// a longer run of digits. That is the whole distinction, and the fixture
    /// stays four digits so the test keeps describing the real product.
    private func leaks(_ pin: String, in text: String) -> Bool {
        text.ranges(of: pin).contains { range in
            let before = range.lowerBound > text.startIndex
                ? text[text.index(before: range.lowerBound)] : " "
            let after = range.upperBound < text.endIndex
                ? text[range.upperBound] : " "
            return !before.isNumber && !after.isNumber
        }
    }

    /// The bundle is made to be sent to someone. The PIN is the only
    /// credential this app has, and it must be in none of the files — while
    /// the port, which is what actually diagnoses a remote that will not come
    /// up, is in all the ones that mention the remote at all.
    @Test func thePINIsInNoFileAndThePortIsInThem() async throws {
        // the matcher earns its keep only if a planted leak trips it — without
        // this the boundary rule could quietly stop matching anything at all
        #expect(leaks("4271", in: #""remotePIN" : "4271""#))
        #expect(leaks("4271", in: "PIN: 4271"))
        #expect(!leaks("4271", in: "boundPort : 54271"))
        #expect(!leaks("4271", in: "Free space: 1427193856 bytes"))

        try await ControllerHarness.run { controller, root in
            let out = try scratch(in: root)
            // Four digits, like every PIN the app itself makes.
            controller.settings.remote.pin = "4271"
            // Port 0: the listener picks an ephemeral one, so the suite never
            // claims a fixed port on the machine running it.
            controller.startRemoteServer(overridePort: 0)
            await ControllerWait.until { controller.remoteBoundPort > 0 }
            let port = controller.remoteBoundPort
            #expect(port > 0)
            defer { controller.stopRemoteServer() }

            let folder = try await collect(controller, into: out)
            let files = try FileManager.default
                .contentsOfDirectory(atPath: folder.path)
            #expect(files.count == 3)

            // The two files the app COMPOSES are asked whether the value
            // leaked: every character in them is one this app chose to write.
            for file in [DiagnosticsBundle.reportFileName,
                         DiagnosticsBundle.jsonFileName] {
                let text = try read(folder, file)
                #expect(!leaks("4271", in: text), "the PIN is in \(file)")
            }
            // The log is not composed, it is COLLECTED — every line the app's
            // subsystem emitted in the last hour. In a suite that is 1677 tests
            // deep in one process, and a four-digit needle will eventually meet
            // an unrelated four-digit number standing on its own: a frame
            // index, a byte count, a duration. CI found one, and it was not a
            // leak. Searching the log for the value therefore tests the corpus
            // rather than this app.
            //
            // What IS this app's promise about the log — and the only thing it
            // can be held to — is that its own logging never writes a
            // credential at all. That is checked by name, on every file, which
            // is also how the redaction itself works.
            for file in files {
                let text = try read(folder, file).lowercased()
                for word in ["remotepin", "pin:", "pin =", "password", "secret"] {
                    #expect(!text.contains(word),
                            "\(file) names a credential: \(word)")
                }
            }
            let report = try read(folder, DiagnosticsBundle.reportFileName)
            #expect(report.contains("\(port)"))
            #expect(report.contains("set (not included in this bundle)"))
            #expect(try read(folder, DiagnosticsBundle.jsonFileName)
                .contains("\"boundPort\" : \(port)"))
        }
    }

    // MARK: - the takes

    @Test func theReportNamesAFailedTakeFromTheList() async throws {
        try await ControllerHarness.run { controller, root in
            let out = try scratch(in: root)
            let good = ControllerFixtures.take(named: "A001C01", in: root)
            let failed = ControllerFixtures.take(named: "A001C02_FAILED",
                                                 in: root, clip: 2)
            try ControllerFixtures.placeholder(for: good)
            try ControllerFixtures.placeholder(for: failed)
            controller.takes = [good, failed]

            let folder = try await collect(controller, into: out)
            let report = try read(folder, DiagnosticsBundle.reportFileName)
            #expect(report.contains("A001C02_FAILED.mov"))
            #expect(report.contains("FAILED FINALIZE"))
            #expect(report.contains("A001C01.mov"))
            // The counters are printed whether or not anything went wrong —
            // "0 dropped" is an answer, a missing line is not.
            #expect(report.contains("Dropped video frames"))
            #expect(report.contains("Gap-filled audio"))
            #expect(report.contains("Ingress drops"))
        }
    }

    // MARK: - mid-take

    /// The one thing this must never do. Collecting reads a lock-guarded
    /// mirror of the pipeline's counters (`CapturePipeline+Health`) and nothing
    /// else — no `queue.sync`, no writer, no finalize — so a take that is
    /// rolling when the operator hits the menu item finishes exactly as it
    /// would have.
    @Test func collectingMidTakeLeavesTheTakeIntact() async throws {
        try await ControllerHarness.run(live: true) { controller, root in
            let out = try scratch(in: root)
            await ControllerWait.until { controller.signalFormat != nil }

            controller.toggleManualRecord()
            await ControllerWait.until { controller.isRecording }
            #expect(controller.isRecording)

            // The mirror says a take is open, and names it, without going
            // anywhere near the writer.
            let health = controller.pipeline.health
            #expect(health.isRecording)
            #expect(health.takeFileName == "A001C01.mov")

            let folder = try await collect(controller, into: out)
            // still rolling on the other side of the collect
            #expect(controller.isRecording)
            let report = try read(folder, DiagnosticsBundle.reportFileName)
            #expect(report.contains("Take rolling"))
            #expect(report.contains("A001C01.mov"))

            // let it run a moment past the collect, then close it normally
            let deadline = Date().addingTimeInterval(0.6)
            await ControllerWait.until({ Date() >= deadline },
                                       timeout: .seconds(45))
            controller.toggleManualRecord()
            await ControllerWait.until { !controller.isRecording }
            await ControllerWait.untilWritten { controller.takes.count == 1 }

            let take = try #require(controller.takes.first)
            #expect(take.url.lastPathComponent == "A001C01.mov")
            #expect(take.durationSeconds > 0)
            let size = try FileManager.default
                .attributesOfItem(atPath: take.url.path)[.size] as? NSNumber
            #expect((size?.int64Value ?? 0) > 0)
            #expect(!controller.showsATakeLostAlarm)
            // the mirror agrees: one take closed, none lost
            let after = controller.pipeline.health
            #expect(!after.isRecording)
            #expect(after.takeFileName == nil)
            #expect(after.takesClosed == 1)
            #expect(after.takesFailedToFinalize == 0)
        }
    }

    // MARK: - the fallback

    /// The Desktop is behind TCC and can be refused. A bundle that gave up at
    /// the first closed door would be missing on exactly the machine that most
    /// needed it, so the writer walks a list.
    @Test func anUnwritableDestinationFallsThroughToTheNextOne() async throws {
        try await ControllerHarness.run { controller, root in
            let out = try scratch(in: root)
            let snapshot = controller.diagnosticsSnapshot()
            // /dev/null is a file, so a folder cannot be made under it — the
            // same shape of refusal a denied Desktop gives.
            let outcome = DiagnosticsBundle.write(
                snapshot, log: ["log"],
                into: [URL(fileURLWithPath: "/dev/null/nope"), out])
            guard case .written(let url) = outcome else {
                Issue.record("the fallback destination was not used")
                return
            }
            #expect(url.path.hasPrefix(out.path))
            #expect(FileManager.default.fileExists(
                atPath: url.appendingPathComponent(
                    DiagnosticsBundle.reportFileName).path))
        }
    }

    /// Every candidate refusing is reported as such rather than swallowed.
    @Test func noWritableDestinationIsReportedNotSwallowed() async throws {
        try await ControllerHarness.run { controller, _ in
            let outcome = DiagnosticsBundle.write(
                controller.diagnosticsSnapshot(), log: [],
                into: [URL(fileURLWithPath: "/dev/null/nope")])
            guard case .failed(let reason) = outcome else {
                Issue.record("a bundle was written to /dev/null")
                return
            }
            #expect(!reason.isEmpty)
        }
    }
}
