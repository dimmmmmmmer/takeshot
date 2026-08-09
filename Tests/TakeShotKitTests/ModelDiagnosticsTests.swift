import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The parts of the diagnostic bundle that are pure: the DeckLink verdict, the
/// redaction rules, the folder name, and what the report actually prints.
///
/// Separated from the controller suite because these are the assertions that
/// must hold for states this machine cannot be put into — a signed build whose
/// library validation blocks Blackmagic's framework, a rig that dropped four
/// hundred frames — and a snapshot built by hand is the only way to reach them.
@Suite struct ModelDiagnosticsTests {
    // MARK: - the DeckLink verdict

    /// The four answers, including the one that cost a day on set: compiled
    /// in, framework installed, and STILL not loaded is the hardened-runtime
    /// library-validation trap, not a missing Desktop Video.
    @Test func theDeckLinkVerdictSeparatesTheFourCases() {
        #expect(DeckLinkDiagnosis.of(compiledWithSDK: false, runtimeLoaded: false,
                                     frameworkPresent: false) == .stub)
        // A stub build stays a stub build however much Desktop Video is
        // installed around it — the binary has no bridge in it at all.
        #expect(DeckLinkDiagnosis.of(compiledWithSDK: false, runtimeLoaded: false,
                                     frameworkPresent: true) == .stub)
        #expect(DeckLinkDiagnosis.of(compiledWithSDK: true, runtimeLoaded: true,
                                     frameworkPresent: true) == .loaded)
        #expect(DeckLinkDiagnosis.of(compiledWithSDK: true, runtimeLoaded: false,
                                     frameworkPresent: false) == .runtimeMissing)
        #expect(DeckLinkDiagnosis.of(compiledWithSDK: true, runtimeLoaded: false,
                                     frameworkPresent: true) == .signatureSuspect)
    }

    /// Only the signature case names the entitlement, and only it shouts. A
    /// bundle that said "install Desktop Video" to somebody who already had it
    /// is exactly the wrong turn this type exists to prevent.
    @Test func onlyTheSignatureCaseNamesTheEntitlement() {
        let suspect = DeckLinkDiagnosis.signatureSuspect.explanation
        #expect(suspect.contains("disable-library-validation"))
        #expect(suspect.contains("SIGNATURE SUSPECT"))
        for other in [DeckLinkDiagnosis.stub, .loaded, .runtimeMissing] {
            #expect(!other.explanation.contains("disable-library-validation"),
                    "\(other.rawValue) blames the signature")
            #expect(!other.explanation.contains("SIGNATURE SUSPECT"))
        }
        #expect(DeckLinkDiagnosis.runtimeMissing.explanation
            .contains("Desktop Video"))
    }

    // MARK: - what the OPERATOR is told

    /// The same four answers as four different messages — which is the whole
    /// defect this pins. `backendAvailable` used to choose between two, the
    /// demo source pinned it to one, and every fault came out as "no devices
    /// found": the words a loose cable earns.
    ///
    /// Hand-set states, never `DeckLinkProbe.diagnosis`: the development Mac
    /// has the SDK headers and Desktop Video, a worktree checkout has neither,
    /// and a test that reported whichever it was running on would mean nothing
    /// on either.
    @Test @MainActor func everyDiagnosisGetsItsOwnMessage() {
        // A working build says nothing at all: "this build can see boards" is
        // not news to a professional, and the device list already says whether
        // one is attached.
        #expect(DeckLinkDiagnosis.loaded.noticeKeys == nil)
        #expect(DeckLinkDiagnosis.loaded.noticeTitle == nil)
        #expect(DeckLinkDiagnosis.loaded.noticeDetail == nil)

        for language in [AppLanguage.english, .russian] {
            ViewRender.withLanguage(language) {
                var titles: Set<String> = []
                var details: Set<String> = []
                for fault in DeckLinkDiagnosis.faults {
                    let keys = fault.noticeKeys
                    let title = fault.noticeTitle ?? ""
                    let detail = fault.noticeDetail ?? ""
                    #expect(keys != nil, "\(fault.rawValue) says nothing")
                    // A key missing from the .strings file comes back AS the
                    // key — the failure mode that renders raw identifiers all
                    // over the UI instead of throwing.
                    #expect(title != keys?.title,
                            "\(keys?.title ?? "-") is untranslated")
                    #expect(detail != keys?.detail,
                            "\(keys?.detail ?? "-") is untranslated")
                    titles.insert(title)
                    details.insert(detail)
                }
                #expect(titles.count == 3,
                        "two faults share a headline in \(language.rawValue)")
                #expect(details.count == 3,
                        "two faults share a remedy in \(language.rawValue)")
            }
        }
    }

    /// The one that cost a day on set has to be the one that names the trap.
    /// Told "install Desktop Video" by a machine that already has it, the
    /// operator goes and installs it again — which is the day.
    @Test @MainActor func onlyTheSignatureNoticeNamesTheEntitlement() {
        // Both languages: the entitlement is a literal that has to survive
        // translation, and the other two must not acquire it.
        for language in [AppLanguage.english, .russian] {
            ViewRender.withLanguage(language) {
                let entitlement = "com.apple.security.cs.disable-library-validation"
                #expect((DeckLinkDiagnosis.signatureSuspect.noticeDetail ?? "")
                    .contains(entitlement))
                for other in [DeckLinkDiagnosis.stub, .runtimeMissing] {
                    #expect(!(other.noticeDetail ?? "")
                        .contains("disable-library-validation"),
                            "\(other.rawValue) blames the signature")
                }
            }
        }
        // …and each of the other two names its own remedy, which is a different
        // one: a build with the SDK for the stub, an install for the runtime.
        ViewRender.withLanguage(.english) {
            #expect((DeckLinkDiagnosis.stub.noticeDetail ?? "").contains("SDK"))
            #expect((DeckLinkDiagnosis.runtimeMissing.noticeDetail ?? "")
                .contains("Desktop Video"))
        }
    }

    /// The retired key must not come back. `sdk_not_connected` was chosen by
    /// `backendAvailable` and was therefore never once on screen; a string left
    /// in the file is how a dead branch gets re-added by whoever finds it.
    @Test func theUnreachableSDKStringIsGoneFromBothLanguages() throws {
        for language in ["en", "ru"] {
            let path = try #require(Bundle.module.path(forResource: language,
                                                       ofType: "lproj"))
            let strings = try #require(NSDictionary(
                contentsOfFile: path + "/Localizable.strings") as? [String: String])
            #expect(strings["sdk_not_connected"] == nil)
        }
    }

    // MARK: - redaction

    /// The account name is what a home-directory path gives away, and it is in
    /// every path this app touches.
    @Test func pathsLoseTheHomeDirectory() {
        let path = NSHomeDirectory() + "/Movies/TakeShot/Ep2"
        #expect(DiagnosticsRedaction.abbreviate(path) == "~/Movies/TakeShot/Ep2")
        // …including inside a longer line, which is how the log excerpt gets it
        let line = "folder watcher armed: \(path)"
        #expect(DiagnosticsRedaction.abbreviate(line)
            == "folder watcher armed: ~/Movies/TakeShot/Ep2")
    }

    /// Secrets go by KEY NAME, not by value. A four-digit PIN cannot be removed
    /// by searching for its digits — "1080" is also a raster — so the rule has
    /// to be structural, and it has to catch a credential nobody has added yet.
    @Test func secretsAreRecognisedByName() {
        #expect(DiagnosticsRedaction.isSecretKey("remotePIN"))
        #expect(DiagnosticsRedaction.isSecretKey("apiToken"))
        #expect(DiagnosticsRedaction.isSecretKey("SharedSecret"))
        #expect(DiagnosticsRedaction.isSecretKey("password"))
        #expect(!DiagnosticsRedaction.isSecretKey("remotePort"))
        #expect(!DiagnosticsRedaction.isSecretKey("chromaKeyTolerance"))
        #expect(!DiagnosticsRedaction.isSecretKey("destinationPath"))
    }

    @Test func theSettingsBlobDropsThePINAndKeepsThePort() {
        var settings = CaptureSettings()
        settings.remote.pin = "4271"
        settings.remote.port = 8791
        settings.naming.projectName = "Ep2"
        settings.capture.destinationPath = NSHomeDirectory() + "/Movies/TakeShot"
        let flat = DiagnosticsRedaction.settings(settings)

        #expect(flat["remotePIN"] == nil)
        #expect(!flat.values.contains("4271"))
        #expect(flat["remotePort"] == "8791")
        #expect(flat["projectName"] == "Ep2")
        #expect(flat["destinationPath"] == "~/Movies/TakeShot")
        // Booleans have to read as switches. JSONSerialization hands them back
        // as NSNumber, and "monitorEnabled = 0" reads as a level.
        settings.audio.monitorEnabled = false
        #expect(DiagnosticsRedaction.settings(settings)["monitorEnabled"]
            == "false")
    }

    // MARK: - the report

    /// A snapshot of a rig that is having a bad day: frames going missing, USB
    /// audio padded, a take that never finalized, and the sticky alarm up.
    private func troubledSnapshot() -> DiagnosticsSnapshot {
        var snapshot = DiagnosticsSnapshot()
        snapshot.recording.health.isRecording = true
        snapshot.recording.health.takeFileName = "A001C014.mov"
        snapshot.recording.health.droppedVideoFramesInTake = 37
        snapshot.recording.health.droppedVideoFramesTotal = 412
        snapshot.recording.health.droppedAudioPacketsInTake = 3
        snapshot.recording.health.gapFilledAudioPacketsInTake = 9
        snapshot.recording.health.ingressDrops = 51
        snapshot.recording.health.takesFailedToFinalize = 1
        snapshot.recording.persistentAlert = "TAKE LOST — writer failed"
        var failed = DiagnosticsSnapshot.TakeRow()
        failed.name = "A001C013_FAILED.mov"
        failed.durationSeconds = 8.5
        failed.failedFinalize = true
        failed.fileExists = true
        failed.note = "USB audio lost — 9 packet(s) padded with silence"
        var good = DiagnosticsSnapshot.TakeRow()
        good.name = "A001C012.mov"
        good.durationSeconds = 31.25
        good.fileExists = true
        snapshot.takes.recent = [good, failed]
        snapshot.takes.total = 2
        snapshot.takes.listed = 2
        return snapshot
    }

    @Test func theReportNamesEveryDropCounter() {
        let report = DiagnosticsReport.text(for: troubledSnapshot())
        #expect(report.contains("Dropped video frames"))
        #expect(report.contains("37 in this take, 412 since launch"))
        #expect(report.contains("Dropped audio packets"))
        #expect(report.contains("3 in this take"))
        #expect(report.contains("Gap-filled audio"))
        #expect(report.contains("9 in this take"))
        #expect(report.contains("Ingress drops"))
        #expect(report.contains("51"))
        #expect(report.contains("Failed to finalize"))
    }

    @Test func theReportNamesTheTakeThatFailedToFinalize() {
        let report = DiagnosticsReport.text(for: troubledSnapshot())
        #expect(report.contains("A001C013_FAILED.mov"))
        // Spelled out, not left as a substring of a file name for the reader
        // to spot.
        #expect(report.contains("FAILED FINALIZE"))
        #expect(report.contains("USB audio lost"))
        // …and the healthy take beside it is listed without the marker
        #expect(report.contains("A001C012.mov"))
        #expect(report.components(separatedBy: "FAILED FINALIZE").count == 2)
        #expect(report.contains("TAKE LOST — writer failed"))
    }

    /// The disclosure is the first thing in the file, because the decision to
    /// send it has to be made with the facts in front of you — not found
    /// further down, after the reader has already forwarded it.
    @Test func theHeaderStatesWhatIsAndIsNotInTheBundle() throws {
        let report = DiagnosticsReport.text(for: DiagnosticsSnapshot())
        for promise in ["WHAT IS IN THIS BUNDLE", "remote's PIN",
                        "Screen Recording", "Nothing was uploaded",
                        "it names the job", "report.txt", "log.txt"] {
            #expect(report.contains(promise), "the header dropped: \(promise)")
        }
        // …and it is above the first section of data, not buried in the file
        let disclosure = try #require(report.range(of: "WHAT IS IN THIS BUNDLE"))
        let firstData = try #require(report.range(of: "MACHINE"))
        #expect(disclosure.lowerBound < firstData.lowerBound)
    }

    /// The stub build's own wording, pinned against a snapshot rather than
    /// against whatever hardware the suite happens to run on.
    ///
    /// A machine with the SDK headers and Desktop Video installed (the owner's)
    /// and a CI runner with neither must both hold this: what matters is that
    /// the bundle NEVER answers "no SDK in this binary" with the signature
    /// story, or the other way round. Those are two different machines to go
    /// and fix.
    @Test func aStubBuildIsReportedAsAStubAndNotAsASignatureProblem() {
        var snapshot = DiagnosticsSnapshot()
        // Desktop Video installed and working, and the binary still has no
        // bridge in it — the case most likely to be misread.
        snapshot.deckLink.compiledWithSDK = false
        snapshot.deckLink.runtimeLoaded = false
        snapshot.deckLink.frameworkPresent = true
        snapshot.deckLink.desktopVideoVersion = "16.0.1"
        snapshot.deckLink.diagnosis = .of(compiledWithSDK: false,
                                          runtimeLoaded: false,
                                          frameworkPresent: true)
        snapshot.deckLink.diagnosisText = snapshot.deckLink.diagnosis.explanation

        #expect(snapshot.deckLink.diagnosis == .stub)
        let report = DiagnosticsReport.text(for: snapshot)
        #expect(report.contains("Built WITHOUT the DeckLink SDK"))
        #expect(!report.contains("SIGNATURE SUSPECT"))
        // the three facts, printed so the verdict can be checked
        #expect(report.contains(DiagnosticsReport.pair("Compiled with SDK",
                                                       false)))
        #expect(report.contains(DiagnosticsReport.pair("Runtime loaded", false)))
        #expect(report.contains(DiagnosticsReport.pair("Framework on disk",
                                                       true)))
        #expect(report.contains("16.0.1"))
    }

    /// …and the mirror image: compiled in, framework there, still blind. This
    /// is the wording that would have saved a day on set.
    @Test func aBlockedFrameworkIsReportedAsASignatureProblem() {
        var snapshot = DiagnosticsSnapshot()
        snapshot.deckLink.compiledWithSDK = true
        snapshot.deckLink.runtimeLoaded = false
        snapshot.deckLink.frameworkPresent = true
        snapshot.deckLink.diagnosis = .of(compiledWithSDK: true,
                                          runtimeLoaded: false,
                                          frameworkPresent: true)
        snapshot.deckLink.diagnosisText = snapshot.deckLink.diagnosis.explanation

        let report = DiagnosticsReport.text(for: snapshot)
        #expect(report.contains("SIGNATURE SUSPECT"))
        #expect(report.contains("disable-library-validation"))
        #expect(!report.contains("Built WITHOUT the DeckLink SDK"))
        #expect(report.contains("signatureSuspect"))
    }

    /// Absence is reported, not skipped: a rig with nothing attached is the
    /// case this bundle exists for, and blank lines diagnose nothing.
    @Test func anEmptySnapshotStillSaysSomethingAboutEveryThing() {
        let report = DiagnosticsReport.text(for: DiagnosticsSnapshot())
        #expect(report.contains("NOT CONFIGURED"))
        #expect(report.contains("none — no signal detected"))
        #expect(report.contains("No takes this session."))
        #expect(report.contains("none — no integrity alarm is up"))
        #expect(report.contains("0 — not listening"))
    }

    // MARK: - the folder on disk

    @Test func theFolderNameCarriesTheProjectAndAStamp() {
        let date = Date(timeIntervalSince1970: 1_775_000_000)
        let name = DiagnosticsBundle.folderName(project: "Ep 2 / Pilot",
                                                at: date)
        #expect(name.hasPrefix("TakeShot-diagnostics_"))
        // Sanitized through the naming engine: a project name cannot put a
        // path separator into the folder it names.
        #expect(!name.contains("/"))
        #expect(name.contains("Ep"))
        #expect(name.range(of: "[0-9]{6}-[0-9]{6}$", options: .regularExpression)
                != nil)
        // No project yet is a real state — the name must not come out with a
        // dangling separator in it.
        let anonymous = DiagnosticsBundle.folderName(project: "", at: date)
        #expect(!anonymous.contains("__"))
    }

    /// Pretty and sorted, because the owner reads this file too — "human
    /// readable JSON, not a binary blob" was the requirement.
    @Test func theJSONIsReadableAndSorted() throws {
        var snapshot = DiagnosticsSnapshot()
        snapshot.settings = ["zzz": "last", "aaa": "first"]
        let json = DiagnosticsBundle.json(for: snapshot)
        #expect(json.contains("\n"))
        let first = try #require(json.range(of: "\"aaa\""))
        let last = try #require(json.range(of: "\"zzz\""))
        #expect(first.lowerBound < last.lowerBound)
        // A path in the JSON has to stay a path.
        #expect(!json.contains("\\/"))
    }
}
