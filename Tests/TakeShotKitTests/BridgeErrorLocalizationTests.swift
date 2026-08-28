import CBraw
import CDeckLink
import CR3D
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The half of the bridge-words rule that `BridgeLocalizationTests` cannot
/// hold on its own: the three bridges whose failures are per-CALL `NSError`s
/// rather than a process-wide answer, and the surfaces they land on.
///
/// Split from that file rather than added to it because the two ask different
/// questions of different things — one is about a vocabulary and a pair of
/// `.strings` tables, this one is about wiring — and the vocabulary itself is
/// read from there rather than copied, so a code added to one list and not the
/// other cannot pass both.
///
/// Machine-independent on the same terms: the two cases that drive the real
/// `CDeckLink` and `CBraw` assert a RELATIONSHIP that holds with the SDK, with
/// the SDK and no runtime, and in a forced-stub build alike.
@Suite struct BridgeErrorLocalizationTests {
    /// One code that carries a value, the value, and the sentence the bridge
    /// would have said. A struct rather than a tuple because three members is
    /// one more than this project's lint takes, and naming them reads better
    /// at the call site anyway.
    struct ValueSample {
        let code: String
        let detail: String
        let english: String
    }

    /// Runs `body` with the app in `language` and puts English back, whatever
    /// happens. `L10n` is process-global; the suite runs `--no-parallel`.
    private func inLanguage(_ language: AppLanguage, _ body: () -> Void) {
        L10n.apply(language)
        defer { L10n.apply(.english) }
        body()
    }

    /// **One `userInfo` key, spelled in two targets that cannot share a
    /// header.**
    ///
    /// `CDeckLink` and `CBraw` have no dependency on each other and one Swift
    /// reader looks their errors up, so the two constants have to be the same
    /// string. Nothing but this notices if one of them is retyped: a BRAW error
    /// whose key differed by a character would simply arrive with no code and
    /// render its English, which looks exactly like the fallback working.
    @Test func theTwoPerCallBridgesSpellOneKey() {
        #expect(CBRBridgeCodeKey == CDLBridgeCodeKey,
                "\(CBRBridgeCodeKey) vs \(CDLBridgeCodeKey)")
        #expect(CBRBridgeDetailKey == CDLBridgeDetailKey,
                "\(CBRBridgeDetailKey) vs \(CDLBridgeDetailKey)")
        #expect(BridgeUnavailable.codeKey == CDLBridgeCodeKey)
        #expect(BridgeUnavailable.detailKey == CDLBridgeDetailKey)
    }

    /// **An error carrying no code renders the originator's own English.**
    ///
    /// The other half of the fallback, and the half the `NSError` path made
    /// reachable in production rather than in theory: every failure that
    /// reaches the banner goes through `BridgeUnavailable(error:)`, including
    /// `AggregateBackend`'s "Unknown capture device", a CinemaDNG folder with
    /// nothing in it, and any backend written after this. None of them is a
    /// bridge and none of them has a code.
    @Test func anErrorWithNoBridgeCodeRendersItsOwnEnglish() {
        let english = "Unknown capture device \"aja:9999\""
        let unavailable = BridgeUnavailable(
            error: BridgeVocabulary.error(code: nil, english: english))
        #expect(unavailable.code == nil)
        for language in [AppLanguage.english, .russian, .system] {
            inLanguage(language) {
                #expect(unavailable.localizedText == english,
                        "\(language): \(unavailable.localizedText)")
            }
        }
    }

    /// **…and one carrying a code this build has no words for does the same.**
    ///
    /// A board's failure modes are the vendor's, not this app's: a Desktop
    /// Video release can start returning a status nothing here has heard of,
    /// and the sentence that arrives with it is the only thing anybody on set
    /// can act on. Never a blank banner over a rolling camera.
    @Test func anErrorWithACodeThisBuildHasNoWordsForRendersItsEnglish() {
        let english = "The DeckLink driver reported something invented after "
            + "this app shipped."
        let error = BridgeVocabulary.error(
            code: "decklink_invented_after_this_build", english: english,
            detail: "UltraStudio 4K Mini")
        let unavailable = BridgeUnavailable(error: error)
        #expect(unavailable.code == "decklink_invented_after_this_build")
        inLanguage(.russian) {
            #expect(unavailable.localizedText == english)
            #expect(unavailable.localizedText
                != BridgeUnavailable.key(for: "decklink_invented_after_this_build"))
        }
    }

    /// A coded error reaches the operator's language, and its one value reaches
    /// the sentence.
    ///
    /// Three codes carry a value and each is a different KIND — a device id, a
    /// raster, a file name — travelling through one field and one `%@`. A
    /// sentence that dropped it would still read as a sentence, which is why
    /// this looks for the value rather than for a difference.
    @Test func aCodedErrorReachesBothLanguagesWithItsValue() throws {
        let samples: [ValueSample] = [
            ValueSample(code: CDLUnavailableDeviceMissing,
                        detail: "UltraStudio 4K Mini",
                        english: "Device \"UltraStudio 4K Mini\" not found"),
            ValueSample(code: CDLUnavailableModeUnsupported,
                        detail: "4096x2160@23.976",
                        english: "No 4096x2160@23.976 output mode on this device"),
            ValueSample(code: CBRUnavailableClipUnreadable,
                        detail: "A001_C002.braw",
                        english: "Can't open BRAW clip A001_C002.braw"),
        ]
        for sample in samples {
            let (code, detail, english) = (sample.code, sample.detail,
                                           sample.english)
            let unavailable = BridgeUnavailable(
                error: BridgeVocabulary.error(
                    code: code, english: english, detail: detail))
            #expect(unavailable.details == [detail])
            for language in [AppLanguage.english, .russian] {
                inLanguage(language) {
                    let shown: String = unavailable.localizedText
                    #expect(shown.contains(detail),
                            "\(language) \(code) dropped \(detail): \(shown)")
                    #expect(!shown.contains("%@"), "\(shown)")
                    #expect(shown != english,
                            "\(language) \(code) is still the diagnostic: \(shown)")
                }
            }
        }
    }

    /// **Whatever build this is, the board's own refusal carries a code this
    /// app has words for.**
    ///
    /// The end-to-end wiring, read off the real bridge rather than a fixture,
    /// and machine-independent the way the rest of this file is: with the SDK
    /// this is `decklink_device_missing` naming the id it was handed, and in a
    /// forced-stub build it is `decklink_not_built`. Both are in the
    /// vocabulary, both have words in both languages, and the assertion is the
    /// same either way.
    ///
    /// Safe to call with no board attached and with one: `CDLCapture` is not
    /// the adapter, so nothing here installs the process-wide hot-plug callback
    /// or adopts whatever is plugged in.
    @Test func theBoardsOwnRefusalCarriesACodeThisAppKnows() throws {
        let capture = CDLCapture()
        defer { capture.stop() }
        do {
            try capture.start(withDeviceID: "no-such-board")
            Issue.record("a device id nothing answers to must not start")
        } catch {
            let unavailable = BridgeUnavailable(error: error)
            let code: String = try #require(
                unavailable.code,
                "the board's error carries no code: \(unavailable.english)")
            #expect(BridgeVocabulary.codes.contains(code),
                    "CDeckLink states \(code), which is not in the vocabulary")
            inLanguage(.russian) {
                #expect(unavailable.localizedText != unavailable.english,
                        "the banner reads English with the app set to Russian")
                #expect(!unavailable.localizedText.isEmpty)
            }
            if code == CDLUnavailableDeviceMissing {
                #expect(unavailable.details == ["no-such-board"])
            }
        }
    }

    /// The same, for Blackmagic RAW: a path no clip is at.
    ///
    /// With the SDK and the runtime this is `braw_clip_unreadable` naming the
    /// file; with the SDK and no Blackmagic RAW Player it is
    /// `braw_runtime_missing`; in a forced-stub build it is `braw_not_built`.
    @Test func theBRAWBridgesRefusalCarriesACodeThisAppKnows() throws {
        do {
            _ = try CBRClip(path: "/nonexistent/A001_C002.braw")
            Issue.record("a path with no clip at it must not open")
        } catch {
            let unavailable = BridgeUnavailable(error: error)
            let code: String = try #require(
                unavailable.code,
                "the BRAW error carries no code: \(unavailable.english)")
            #expect(BridgeVocabulary.codes.contains(code),
                    "CBraw states \(code), which is not in the vocabulary")
            inLanguage(.russian) {
                #expect(unavailable.localizedText != unavailable.english)
            }
            if code == CBRUnavailableClipUnreadable {
                #expect(unavailable.details == ["A001_C002.braw"],
                        "the clip's name did not ride the error")
            }
        }
    }

    /// **The stub messages of the three media bridges keep their reader in
    /// Russian**, the way `theRussianStubMessagesStillAddressTheirReader`
    /// holds the other three.
    ///
    /// These are the lines a downloaded DMG shows and their reader cannot
    /// rebuild anything — a published release is made on a runner with no
    /// vendor drops at all, so DeckLink's is what somebody who plugs in a real
    /// UltraStudio reads. Each has to say what the app in front of them IS,
    /// say what still works, and only then point a developer at a file. A
    /// literal rendering that opened with "скопируйте заголовки" would be
    /// advice its reader cannot take.
    @Test func theRussianStubMessagesOfTheMediaBridgesDoToo() {
        inLanguage(.russian) {
            // What the BUILD is, and that it is the build rather than the Mac.
            // libsrt's own line says the same in a different word ("Собрано
            // без libsrt") and predates the rule, which is why the loop is
            // over these three.
            for code in BridgeVocabulary.mediaStubCodes {
                let line: String = L(BridgeUnavailable.key(for: code))
                #expect(line.hasPrefix("В этой сборке нет"),
                        "\(code) does not open with what this build is: \(line)")
            }
            // What still works with no vendor SDK at all — and for DeckLink
            // that is the whole app, because the demo source is in every build.
            #expect(L("bridge_decklink_not_built").contains("Демо-источник"),
                    "\(L("bridge_decklink_not_built"))")
            #expect(L("bridge_braw_not_built").contains("CinemaDNG"),
                    "\(L("bridge_braw_not_built"))")
            #expect(L("bridge_r3d_not_built").contains("CinemaDNG"),
                    "\(L("bridge_r3d_not_built"))")
            // Untranslated on purpose in all three: a path is a place to look.
            #expect(L("bridge_decklink_not_built")
                .contains("vendor/DeckLinkSDK/README.md"))
            #expect(L("bridge_braw_not_built")
                .contains("vendor/BRAWSDK/README.md"))
            #expect(L("bridge_r3d_not_built")
                .contains("vendor/R3DSDK/README.md"))
        }
    }

    // MARK: - the main window's banner, which is the point

    /// **The board's refusal reaches the BANNER in the operator's language.**
    ///
    /// `CaptureController+Capture` was the file that contradicted itself: two
    /// lines apart it set `lastError` to `L("device_disconnected")` and to a
    /// board's English `localizedDescription`. This is the surface an operator
    /// reads while a camera is rolling, not a settings row they visit once, so
    /// it is asserted through the controller rather than on the type.
    @MainActor
    @Test func theBoardsRefusalReachesTheBannerInTheOperatorsLanguage()
        async throws {
        let english = "Failed to open video input "
            + "(the input may be in use by another application)"
        let board = StubBackend(
            devices: [CaptureDeviceInfo(id: "held", name: "UltraStudio")])
        board.startError = BridgeVocabulary.error(
            code: CDLUnavailableDeviceBusy, english: english)
        L10n.apply(.russian)
        defer { L10n.apply(.english) }
        let backends: [(String, CaptureBackend)] = [("stub", board)]
        try await ControllerHarness.run(extraBackends: backends) { controller, _ in
            // The controller adopts the only real board in `init` and has
            // already been refused once by the time this runs, so the id is
            // assigned rather than changed and `startCapture` is called
            // outright — assigning the id it already holds is a no-op, which
            // is how the first version of this test read a stale nil.
            #expect(controller.selectedDeviceID == "stub:held")
            controller.lastError = nil
            controller.startCapture()

            #expect(!controller.isCapturing)
            let shown: String = try #require(controller.lastError)
            #expect(shown == L(BridgeUnavailable.key(for: CDLUnavailableDeviceBusy)),
                    "the banner is not the operator's sentence: \(shown)")
            #expect(shown != english,
                    "the banner still reads the board's English: \(shown)")
        }
    }

    /// …and falls back to the board's own English for a code it has no words
    /// for. Same surface, same run, opposite half of the rule.
    @MainActor
    @Test func theBannerFallsBackToEnglishForACodeItHasNoWordsFor()
        async throws {
        let english = "The DeckLink driver reported something new."
        let board = StubBackend(
            devices: [CaptureDeviceInfo(id: "odd", name: "UltraStudio")])
        board.startError = BridgeVocabulary.error(
            code: "decklink_invented_after_this_build", english: english)
        L10n.apply(.russian)
        defer { L10n.apply(.english) }
        let backends: [(String, CaptureBackend)] = [("stub", board)]
        try await ControllerHarness.run(extraBackends: backends) { controller, _ in
            #expect(controller.selectedDeviceID == "stub:odd")
            controller.lastError = nil
            controller.startCapture()

            #expect(controller.lastError == english,
                    "the banner is blank or keyed: \(controller.lastError ?? "nil")")
        }
    }

    // MARK: - R3D, which was a localized label glued to an English detail

    /// **The R3D sentence is one sentence, chosen once.**
    ///
    /// It used to be `L("r3d_sdk_unavailable") + " — " + unavailableReason()`,
    /// so a Russian operator read a translated half and an English half joined
    /// by a dash. There is no join left: the bridge states a code, the app
    /// picks one line, and the bridge's English is what a code with no line
    /// falls back to.
    @Test func theR3DTextIsOneSentenceRatherThanALabelGluedToEnglish() {
        let english = "built without RED's R3D SDK (vendor/R3DSDK)"
        let unavailable = BridgeUnavailable(code: CR3DUnavailableNotBuilt,
                                            english: english)
        inLanguage(.russian) {
            let shown: String = unavailable.localizedText
            #expect(!shown.contains(english),
                    "the English detail is still glued on: \(shown)")
            #expect(!shown.contains(L("r3d_sdk_unavailable") + " — "),
                    "the label is still glued on: \(shown)")
            #expect(shown != english)
        }
    }

    /// The media bridges' English is written for an OPERATOR, not copied from
    /// the driver.
    ///
    /// The counterpart of `whateverThisBuildReportsIsACodeItHasWordsFor`'s
    /// character-for-character claim, and deliberately its opposite. Two of the
    /// eleven DeckLink messages and two of RED's seven share a code, so the
    /// line cannot be either bridge sentence; and the ones that could be
    /// should not, because "Device does not support capture" tells an operator
    /// nothing to do. What is pinned instead is that each line names a remedy —
    /// the bridge's own words stay reachable as `english` and in the
    /// diagnostics bundle.
    @Test func theMediaBridgesEnglishIsWrittenForAnOperator() {
        // A line an operator can act on either points at a control in this app,
        // at a piece of software to install, or at the hardware in front of
        // them. Every one of the fourteen has to do one of the three.
        let remedies: [String] = [
            "Settings", "Install", "install", "Reinstall", "Restart",
            "restart", "Choose", "Copy", "Replace", "Reconnect", "Quit",
            "Building with it", "Put ",
        ]
        let media: [String] = BridgeVocabulary.codes.filter {
            $0.hasPrefix("decklink_") || $0.hasPrefix("braw_")
                || $0.hasPrefix("r3d_")
        }
        #expect(media.count == 14, "\(media.count)")
        inLanguage(.english) {
            for code in media {
                let line: String = L(BridgeUnavailable.key(for: code))
                #expect(remedies.contains { line.contains($0) },
                        "\(code) names nothing the reader can do: \(line)")
            }
        }
    }
}
