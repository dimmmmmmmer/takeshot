import CBraw
import CDataChannel
import CDeckLink
import CNDI
import CR3D
import CSRT
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The bridges state a FACT and the app chooses the WORDS — the same split
/// `ControllerAlarmSeverityTests` holds for the capture path, in the other
/// direction.
///
/// **Machine-independent on purpose, and that is the whole design of this
/// file.** Which of the codes a bridge is actually holding depends on
/// which vendor drops the machine has, which runtimes are installed, and —
/// measured rather than assumed — what is sitting in `/usr/local/include`: the
/// NDI SDK arrived on the developer's Mac while this was being written, and a
/// Homebrew-era `/usr/local/include/srt` there makes `CSRT` the real bridge no
/// matter what `vendor/SRTSDK` holds. CI has none of it. A suite that asserted
/// on whatever this machine happens to answer would be testing the machine, so
/// every case below builds the `BridgeUnavailable` it is about, and the two
/// that do read the real bridges assert only relationships that hold in every
/// configuration.
struct BridgeLocalizationTests {
    /// Runs `body` with the app in `language` and puts English back, whatever
    /// happens. `L10n` is process-global; the suite runs `--no-parallel`.
    private func inLanguage(_ language: AppLanguage,
                            _ body: () -> Void) {
        L10n.apply(language)
        defer { L10n.apply(.english) }
        body()
    }

    // MARK: - the fallback, which is the part that has to be tested

    /// **A code this build has no words for shows the bridge's own English.**
    ///
    /// This is the safety of the whole design rather than a nicety. A bridge is
    /// the one place in this app that can grow a failure mode the app layer has
    /// never heard of — a new dlopen check, a new version test — and the two
    /// ways that can go are a blank row under "Состояние: Недоступно" and a
    /// sentence that names what to do. Nothing else in the suite covers it,
    /// because every code that exists today HAS words.
    @Test func anUnrecognisedCodeRendersTheBridgesOwnEnglish() {
        let english = "libsrt on this machine was built without a thing "
            + "invented after this app shipped. Rebuild it with that thing."
        let unavailable = BridgeUnavailable(
            code: "srt_runtime_invented_after_this_build",
            english: english, details: [])
        for language in [AppLanguage.english, .russian, .system] {
            inLanguage(language) {
                #expect(unavailable.localizedText == english,
                        "\(language) did not fall back to the bridge's own sentence: \(unavailable.localizedText)")
            }
        }
    }

    /// …and it is a sentence rather than the key, which is the failure mode
    /// `L10n.translation` exists to rule out. `L10n.string` answers a missing
    /// key WITH the key, so a fallback written on top of it would put
    /// `bridge_srt_runtime_invented…` in the settings row and look, at a
    /// glance, like a translation.
    @Test func anUnrecognisedCodeNeverRendersItsOwnKey() {
        let code = "ndi_runtime_invented_after_this_build"
        let unavailable = BridgeUnavailable(
            code: code, english: "The NDI runtime said something new.",
            details: [])
        inLanguage(.russian) {
            #expect(unavailable.localizedText != code)
            #expect(unavailable.localizedText
                != BridgeUnavailable.key(for: code))
            #expect(!unavailable.localizedText.isEmpty)
        }
    }

    /// The other way into the same path: a reason with no code at all.
    /// `AACConverter.unavailable` is the live example — AudioToolbox is in the
    /// OS rather than a vendor drop, so there is no bridge state to name.
    @Test func aReasonWithNoCodeAtAllRendersItsEnglish() {
        let english = "AudioToolbox would not open an AAC encoder "
            + "(status -50); the SRT stream carries picture only."
        let unavailable = BridgeUnavailable(code: nil, english: english)
        inLanguage(.russian) {
            #expect(unavailable.localizedText == english)
        }
    }

    /// And the real one, taken off `AACConverter` rather than reconstructed, so
    /// the fallback is exercised by a path the app actually has.
    @Test func theAACFailureTravelsAsAnUncodedReason() throws {
        guard case .unavailable(let unavailable) =
            AACConverter.unavailable(-50) else {
            Issue.record("the AAC failure is no longer an unavailable")
            return
        }
        #expect(unavailable.code == nil)
        inLanguage(.russian) {
            #expect(unavailable.localizedText == unavailable.english)
            #expect(unavailable.localizedText.contains("AudioToolbox"))
        }
    }

    // MARK: - the vocabulary

    /// Every code has words in both languages, and neither language answers
    /// with the key.
    ///
    /// `LocalizationTests.theTwoStringsFilesCoverTheSameKeys` catches a key
    /// present in one file and absent from the other; it cannot catch a code
    /// the bridge states that NEITHER file has ever heard of. That is this.
    @Test func everyCodeHasWordsInBothLanguages() {
        for language in [AppLanguage.english, .russian] {
            inLanguage(language) {
                for code in BridgeVocabulary.codes {
                    let key = BridgeUnavailable.key(for: code)
                    let words: String? = L10n.translation(key)
                    #expect(words != nil,
                            "\(language) has no \(key) — the bridge states \(code) and nothing can say it")
                    #expect(words != key)
                    #expect(words?.isEmpty == false)
                }
            }
        }
    }

    /// The Russian is a translation and not a copy of the English.
    ///
    /// A key added to `ru.lproj` by pasting the English satisfies the parity
    /// test perfectly and leaves the operator reading exactly what they read
    /// before — which is the defect this whole change is about.
    @Test func theRussianSaysSomethingOfItsOwn() {
        for code in BridgeVocabulary.codes {
            let key = BridgeUnavailable.key(for: code)
            L10n.apply(.english)
            let en: String? = L10n.translation(key)
            L10n.apply(.russian)
            let ru: String? = L10n.translation(key)
            L10n.apply(.english)
            #expect(en != nil)
            #expect(ru != nil)
            #expect(en != ru, "\(key) is the same text in both languages")
        }
    }

    /// **The stub messages keep their reader in Russian.**
    ///
    /// The two `not_built` lines are the ones a downloaded DMG shows, and their
    /// reader cannot rebuild anything — a published release is made on a runner
    /// with no vendor drops at all. So the Russian has to do what the English
    /// does: say what the app in front of them IS, say what still works, and
    /// only then point a developer at a file. A literal rendering that led with
    /// "скопируйте заголовки" would be advice its reader cannot take.
    @Test func theRussianStubMessagesStillAddressTheirReader() {
        inLanguage(.russian) {
            // The three lines the media bridges added are held to the same
            // shape by `theRussianStubMessagesOfTheMediaBridgesDoToo` next
            // door, where the rest of those bridges' rules live.
            let ndi: String = L("bridge_ndi_not_built")
            // What this build IS, and that it is the build rather than the Mac.
            #expect(ndi.contains("сборке"), "\(ndi)")
            // What still works without any vendor SDK at all.
            #expect(ndi.contains("веб-пульт"),
                    "the Russian offers the reader nothing that works: \(ndi)")
            // Untranslated on purpose: a path is a place to look.
            #expect(ndi.contains("vendor/NDISDK/README.md"), "\(ndi)")

            let webrtc: String = L("bridge_webrtc_not_built")
            #expect(webrtc.contains("сборке"), "\(webrtc)")
            // It used to point at the camera page, which was the JPEG surface
            // and is gone — the promise had to change in the same commit that
            // removed the page, or the app would be telling an operator to go
            // somewhere that answers 404. What it offers now is the rest of
            // the remote, which is true without libdatachannel.
            #expect(webrtc.contains("на пульте работает"),
                    "the Russian offers the reader nothing that works: \(webrtc)")
            #expect(!webrtc.contains("камер"),
                    "the Russian still promises a page that is gone: \(webrtc)")
            #expect(webrtc.contains("vendor/libdatachannel/README.md"),
                    "\(webrtc)")
        }
    }

    // MARK: - the detail a code may carry

    /// Only the three codes that name a search carry a placeholder, in either
    /// language.
    ///
    /// `localizedText` runs `String(format:)` only on a line that carries
    /// `%@`, so a placeholder on any other line would swallow whatever follows
    /// it and a bare `%` on a line that has one would corrupt it. A translator
    /// has no way to know which lines take an argument except by being told;
    /// this is the telling, and it is checked in both files because a
    /// translator is exactly who might add or drop one.
    @Test func onlyTheCodesThatNameASearchTakeAnArgument() {
        for language in [AppLanguage.english, .russian] {
            inLanguage(language) {
                for code in BridgeVocabulary.codes {
                    let words: String = L(BridgeUnavailable.key(for: code))
                    let carries: Bool = BridgeVocabulary.codesCarryingAValue.contains(code)
                    let has: Bool = words.contains("%@")
                    #expect(has == carries,
                            "\(language) \(code) has placeholder \(has), expected \(carries): \(words)")
                }
            }
        }
    }

    /// …and the paths really arrive in the sentence, joined the way the English
    /// prose joins them.
    @Test func theSearchedPathsReachBothLanguages() {
        let paths = ["/opt/homebrew/lib/libsrt.dylib",
                     "/usr/local/lib/libsrt.1.5.dylib"]
        let unavailable = BridgeUnavailable(
            code: CSRTUnavailableRuntimeMissing,
            english: "libsrt not found. Looked for: \(paths.joined(separator: ", "))",
            details: paths)
        for language in [AppLanguage.english, .russian] {
            inLanguage(language) {
                let shown: String = unavailable.localizedText
                for path in paths {
                    #expect(shown.contains(path),
                            "\(language) dropped \(path): \(shown)")
                }
                #expect(!shown.contains("%@"), "\(shown)")
            }
        }
    }

    /// A code that names a search but arrived with no paths shows the sentence
    /// with no argument spliced into it rather than a raw `%@`.
    ///
    /// Not reachable today — the candidate lists are constants and are never
    /// empty in a build that can look at them — which is exactly why it is
    /// pinned: the line that makes it true is one `guard` in `localizedText`
    /// and nothing else would notice its removal. It caught the first version
    /// of that guard, which keyed the formatting off the PATHS rather than off
    /// the placeholder and put a literal `%@` in the row.
    @Test func aSearchCodeWithNoPathsIsStillASentence() {
        let unavailable = BridgeUnavailable(
            code: CSRTUnavailableRuntimeMissing,
            english: "libsrt not found.", details: [])
        inLanguage(.russian) {
            #expect(!unavailable.localizedText.contains("%@"),
                    "\(unavailable.localizedText)")
        }
    }

    // MARK: - the /live page, whose reader is holding a phone

    /// **The page has no localization of its own and needs none.**
    ///
    /// Every word on `/live` is chosen on the Mac before the markup is served
    /// — `RemotePage.config` splices an `L()`-resolved string per label into
    /// the script — so the one line that arrived in English was the 503 body,
    /// which is built per request rather than per page. It is chosen the same
    /// way now, at the moment the route answers, so it is in the language the
    /// rest of the page around it is in.
    @Test func theRouteAnswersInTheLanguageThePageWasServedIn() throws {
        let english: String = try #require(
            L10n.translation("bridge_webrtc_not_built"))
        let failure = WebRTCError.unavailable(
            BridgeUnavailable(code: CDCUnavailableNotBuilt, english: english))
        L10n.apply(.russian)
        let russian: RemoteWebRTC.Answer = CaptureController.refusal(failure)
        L10n.apply(.english)
        let base: RemoteWebRTC.Answer = CaptureController.refusal(failure)

        guard case .unavailable(let ru) = russian,
              case .unavailable(let en) = base else {
            Issue.record("the refusal is no longer an unavailable")
            return
        }
        #expect(en == english,
                "the English answer is not the bridge's own: \(en)")
        #expect(ru != en, "the page reads English with the app set to Russian")
        // The library's name is not translated in either: it is the thing to go
        // and look up.
        #expect(ru.lowercased().contains("libdatachannel"), "\(ru)")
    }

    /// …and the same route falls back to the bridge's English for a code it has
    /// no words for. The page is the surface where a blank box is hardest to
    /// diagnose — nobody holding the phone can read a log.
    @Test func theRouteFallsBackToEnglishOnAnUnknownCode() {
        let english = "libdatachannel on this machine reported something this "
            + "build has never heard of."
        let failure = WebRTCError.unavailable(BridgeUnavailable(
            code: "webrtc_runtime_invented_after_this_build", english: english))
        L10n.apply(.russian)
        let answer: RemoteWebRTC.Answer = CaptureController.refusal(failure)
        L10n.apply(.english)
        guard case .unavailable(let text) = answer else {
            Issue.record("the refusal is no longer an unavailable")
            return
        }
        #expect(text == english)
    }

    /// The three lines in the page's blocked box that are the app's own rather
    /// than a bridge's. They sat in English beside the bridge's paragraph and
    /// for the same reason.
    @Test func thePagesOwnRefusalsAreLocalizedToo() {
        for key in ["live_too_many_viewers", "live_shutting_down",
                    "live_no_app"] {
            L10n.apply(.english)
            let en: String? = L10n.translation(key)
            L10n.apply(.russian)
            let ru: String? = L10n.translation(key)
            L10n.apply(.english)
            #expect(en != nil, "no English for \(key)")
            #expect(ru != nil, "no Russian for \(key)")
            #expect(en != ru, "\(key) is the same text in both languages")
        }
        // The viewer ceiling really reaches the sentence rather than being
        // dropped by a format string that lost its placeholder.
        L10n.apply(.russian)
        let full: String = L("live_too_many_viewers", WebRTCViewer.maximumViewers)
        L10n.apply(.english)
        let ceiling: String = "\(WebRTCViewer.maximumViewers)"
        #expect(full.contains(ceiling), "\(full)")
        #expect(!full.contains("%d"), "\(full)")
    }

    // MARK: - the rows read the chosen words and not the diagnostic

    /// **A view must render `localizedText` and never `english`.**
    ///
    /// The two are both non-empty paragraphs of similar length, so a row that
    /// went back to showing the bridge's diagnostic sentence would lay out at
    /// very nearly the same size and no render test would notice: the defect
    /// this whole change is about is invisible to a measurement and visible
    /// only to a reader. So it is checked the way `ViewDisabledRuleTests`
    /// checks its rule — by walking the sources.
    ///
    /// What this does NOT catch: a row that spelled an English sentence out
    /// inline instead of reading either property. Nothing here can; what covers
    /// that is that neither section has any literal prose in it at all, which
    /// `theNDIRowLabelsFitTheSettingsForm` and its SRT twin already depend on.
    /// Nor does it reach `WebRTCError.message`, which is `english` on purpose
    /// and lives in `WebRTCPeer.swift` — the diagnostic accessor has to exist
    /// somewhere, and the rule is only that a SURFACE does not read it.
    @Test func theSettingsRowsShowTheWordsAndNotTheDiagnostic() throws {
        let root: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        // The two settings rows, and the route that answers the /live page —
        // the third surface, and the one whose reader cannot read a log.
        // The two settings rows and the /live route, plus the four surfaces
        // the media bridges reach: the MAIN WINDOW's banner (+Capture), the
        // hardware-output toast (+Windows), a multicam channel's toast
        // (+Multicam) and the RAW player's open failure (RawPlayback). The
        // banner is the one that matters most — it is read while a camera is
        // rolling, not on a settings page somebody visits once.
        for name in ["NDISettingsSection", "SRTSettingsSection",
                     "CaptureController+WebRTC", "CaptureController+Capture",
                     "CaptureController+Windows", "CaptureController+Multicam",
                     "RawPlayback"] {
            let url: URL = root.appendingPathComponent("\(name).swift")
            let source: String = try String(contentsOf: url, encoding: .utf8)
            let code: String = source
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces)
                    .hasPrefix("//") }
                .joined(separator: "\n")
            #expect(code.contains("localizedText"),
                    "\(name) no longer renders the localized reason")
            #expect(!code.contains("english"),
                    "\(name) renders the bridge's English diagnostic")
        }
    }

    // MARK: - what the bridges themselves promise

    /// A bridge states a code exactly when it states a reason.
    ///
    /// The two are set together in the Obj-C and read separately in Swift, so
    /// this is the one thing that could drift silently: a `failure` assigned
    /// without its `code` would give the app a sentence and no fact, and the
    /// row would quietly stop following the language switch.
    ///
    /// Reads the real bridges, and asserts only the relationship — true of a
    /// stub build, of a machine with the SDK, and of a machine with the SDK and
    /// no runtime alike.
    @Test func aBridgeStatesACodeExactlyWhenItStatesAReason() {
        #expect((CSRTSender.unavailableReason() == nil)
            == (CSRTSender.unavailableCode() == nil))
        #expect((CNDSender.unavailableReason() == nil)
            == (CNDSender.unavailableCode() == nil))
        #expect((CDCPeerConnection.unavailableReason() == nil)
            == (CDCPeerConnection.unavailableCode() == nil))
        #expect((CR3DClip.unavailableReason() == nil)
            == (CR3DClip.unavailableCode() == nil))
    }

    /// …and when it states one, it is one of the codes this app knows, with the
    /// English still the bridge's own sentence character for character.
    ///
    /// The second half is what says the first pass changed which LAYER picks
    /// the words and did not change the words — the same claim
    /// `ControllerAlarmSeverityTests` makes about the alarms.
    ///
    /// **It is asserted for these three bridges and deliberately not for the
    /// media ones**, which is why `r3d` is not in this list and has
    /// `theMediaBridgesEnglishIsWrittenForAnOperator` of its own. libsrt, NDI
    /// and libdatachannel already reported themselves in sentences written for
    /// a settings row, so keeping them word for word cost nothing. A board says
    /// "Failed to allocate an output frame" and RED's SDK says "built without
    /// RED's R3D SDK (vendor/R3DSDK)" — diagnostics, and pinning the operator's
    /// line to them would pin the defect.
    ///
    /// Whichever bridges are stubs on the machine running this are the ones
    /// asserted; on CI that is all three.
    ///
    /// What this would NOT catch: a machine where all three bridges work
    /// asserts nothing, because there is no unavailability to be right about.
    /// That is not hypothetical — the developer's Mac reaches libsrt through
    /// `/usr/local/include/srt`, which is on clang's default search path, so
    /// `CSRT` is the REAL bridge there whatever `vendor/SRTSDK` holds. The
    /// fallback cases above are the ones that hold whatever the machine has,
    /// and they are why this one is allowed to be configuration-dependent.
    @Test func whateverThisBuildReportsIsACodeItHasWordsFor() throws {
        let bridges: [(String, BridgeUnavailable?)] = [
            ("SRT", BridgeUnavailable.srt), ("NDI", BridgeUnavailable.ndi),
            ("WebRTC", BridgeUnavailable.webrtc),
        ]
        defer { L10n.apply(.english) }
        for (name, unavailable) in bridges {
            guard let unavailable else { continue }
            let code: String = try #require(unavailable.code)
            #expect(BridgeVocabulary.codes.contains(code),
                    "\(name) states \(code), which is not in the vocabulary")
            L10n.apply(.english)
            let row: String = unavailable.localizedText
            #expect(row == unavailable.english,
                    """
                    \(name)'s English is no longer the bridge's own sentence
                    row:    \(row)
                    bridge: \(unavailable.english)
                    """)
            L10n.apply(.russian)
            #expect(unavailable.localizedText != unavailable.english,
                    "\(name) reads English with the app set to Russian")
        }
    }
}
