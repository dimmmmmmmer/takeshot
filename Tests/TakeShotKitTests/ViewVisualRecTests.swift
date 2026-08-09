import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The taught-indicator rows as the operator gets them: inside the Settings
/// form's FIXED width, in English and in Russian, at every stage of the teaching.
///
/// The failure this guards against is silent. A grouped Form does not wrap a
/// label that is too long, it truncates it — so a Russian status line that no
/// longer fits shows up as a size and as nothing else. The rows also GROW as the
/// teaching progresses (the panel is the switch and the teach row until
/// something has been taught), so each stage is measured separately: a row that
/// only appears once a reference exists is a row no test would otherwise see.
///
/// And one question that is not a size at all — whether the panel offers a way
/// in from a fresh install. See `theTeachControlIsReachableFromAFreshInstall`
/// for what a suite of width checks was able to miss.
@MainActor
struct ViewVisualRecTests {
    /// A signature that separates, built without a pipeline: the rows care only
    /// about whether the teaching is taught, not where it came from.
    private func signature(_ level: Double) -> VisualRecSignature? {
        var codes = [Double](repeating: 60,
                             count: VisualRecSignature.componentCount)
        // one cell's worth of red, which is what a REC dot is
        for index in 0..<9 where index % 3 == 0 { codes[index] = level }
        return VisualRecSignature(codes: codes)
    }

    private func taught(_ probe: ViewProbe, on: Bool = false) {
        var teaching = VisualRecTeaching()
        teaching.region = VisualRecRegion(centerX: 0.8, centerY: 0.12)
        teaching.rolling = signature(230)
        teaching.idle = signature(60)
        teaching.isOn = on
        probe.controller.visualRecTeaching = teaching
    }

    /// Every stage the rows can be in, squeezed into the width the Settings form
    /// actually gives them.
    @Test func theRowsFitTheSettingsFormAtEveryStage() async throws {
        try await ViewProbe.run { probe in
            let form = ViewBudget.settingsFormWidth

            // 1. untouched: the switch and the way in, nothing else
            var minimum = probe.minimumWidths { VisualRecRows() }
            #expect(minimum.ru <= form,
                    "the resting switch wants \(minimum.ru)pt of \(form) in Russian")
            #expect(minimum.en <= form)

            // 2. teaching mode armed: the box controls appear
            probe.controller.visualRecTeachArmed = true
            minimum = probe.minimumWidths { VisualRecRows() }
            #expect(minimum.ru <= form,
                    "teaching mode wants \(minimum.ru)pt of \(form) in Russian")
            #expect(minimum.en <= form)

            // 3. taught and armed, with a live reading beside the status line
            probe.controller.visualRecTeachArmed = false
            taught(probe, on: true)
            probe.controller.visualRecReading = .rolling
            minimum = probe.minimumWidths { VisualRecRows() }
            #expect(minimum.ru <= form,
                    "the armed rows want \(minimum.ru)pt of \(form) in Russian")
            #expect(minimum.en <= form)
        }
    }

    /// There is a way INTO the feature from a fresh install.
    ///
    /// This is the test the suite did not have, and the bug it did not catch:
    /// the teach row is the only caller of `toggleVisualRecTeach()` in the whole
    /// app, and it sat behind the same `isExpanded` gate as the dials — which is
    /// false until something has been taught. The panel was one greyed switch
    /// and no door, and every existing check here was a WIDTH: the rows fitted
    /// the form perfectly while offering the operator nothing. The controller
    /// tests missed it for the mirror-image reason — they call
    /// `toggleVisualRecTeach()` directly, which no button could.
    ///
    /// So the shape is: nothing taught, nothing armed, and the panel still has
    /// to be taller than the switch by the door — and pressing the door has to
    /// open the rest.
    @Test func theTeachControlIsReachableFromAFreshInstall() async throws {
        try await ViewProbe.run { probe in
            #expect(!probe.controller.visualRecTeaching.isTaught,
                    "the fixture starts taught — this test proves nothing")
            #expect(!probe.controller.visualRecTeachArmed)
            #expect(!probe.controller.visualRecOn)

            let fresh: CGSize = probe.fittingSize(VisualRecRows())
            let door: CGSize = probe.fittingSize(VisualRecTeachRow())
            let switchOnly: CGSize = probe.fittingSize(
                Toggle(L("visual_rec"), isOn: .constant(false)))

            #expect(door.height > 0, "the teach row renders as nothing")
            #expect(fresh.height >= switchOnly.height + door.height - 1,
                    "the untaught panel is \(fresh.height)pt — only the switch, no way in")

            // …and the door opens the rest, from exactly that state
            probe.controller.toggleVisualRecTeach()
            #expect(probe.controller.visualRecTeachArmed,
                    "the teach button did not arm teaching mode")
            let opened: CGSize = probe.fittingSize(VisualRecRows())
            #expect(opened.height > fresh.height,
                    "arming teaching opened nothing: \(fresh) → \(opened)")
        }
    }

    /// The dials appear only once there is something to show. A binding wired to
    /// the wrong flag renders the same two rows whatever the state is, which
    /// a width check would never catch.
    @Test func theRowsAppearOnlyOnceSomethingIsTaught() async throws {
        try await ViewProbe.run { probe in
            let resting = probe.fittingSizes { VisualRecRows() }
            taught(probe, on: true)
            probe.controller.visualRecReading = .rolling
            let open = probe.fittingSizes { VisualRecRows() }
            #expect(open.en.height > resting.en.height,
                    "the rows never opened: \(resting) → \(open)")
            #expect(open.ru.height > resting.ru.height,
                    "the Russian rows never opened: \(resting) → \(open)")
            // and Russian is not missing a row the English build has
            #expect(open.ru.height > open.en.height - 1,
                    "a row went missing in Russian: \(open)")
        }
    }

    /// The whole Settings form still reports its fixed width with the section
    /// grown — the rows live inside it, and a row that cannot compress pushes the
    /// window rather than truncating quietly.
    @Test func theSettingsFormStillFitsWithTheRowsOpen() async throws {
        try await ViewProbe.run { probe in
            taught(probe, on: true)
            probe.controller.visualRecTeachArmed = true
            let ideal = probe.fittingSizes { SettingsView() }
            #expect(ideal.ru.width == SettingsView.width + 32,
                    "the settings window widened: \(ideal.ru.width)")
            #expect(ideal.en.width == SettingsView.width + 32)
        }
    }

    /// The teaching overlay is an overlay: whatever it draws, it must not change
    /// the size of the player under it — the same rule the badge row obeys, and
    /// the same way a modifier starts moving the image when the language changes.
    @Test func theTeachOverlayNeverStretchesThePlayer() async throws {
        try await ViewProbe.run { probe in
            let base = CGSize(width: ViewBudget.playerWidth, height: 380)
            probe.controller.visualRecTeachArmed = true
            probe.controller.visualRecTeaching.region =
                VisualRecRegion(centerX: 0.8, centerY: 0.12)
            for language in [AppLanguage.english, .russian] {
                let size = ViewRender.withLanguage(language) {
                    ViewRender.laidOutSize(
                        probe.hosted(Color.clear.overlay { VisualRecTeachOverlay() }),
                        in: base)
                }
                #expect(size == base,
                        "the teach overlay stretched the player in \(language)")
            }
        }
    }

    /// Disarmed, the overlay draws and hit-tests nothing at all — it is mounted
    /// on the live player permanently, so "nothing" has to mean nothing.
    @Test func theTeachOverlayIsEmptyWhenDisarmed() async throws {
        try await ViewProbe.run { probe in
            probe.controller.visualRecTeachArmed = false
            let size = probe.fittingSize(VisualRecTeachOverlay())
            #expect(size == .zero, "the disarmed overlay measured \(size)")
        }
    }

    /// The REC mark over the player names the trigger, in both languages, and
    /// falls back to the plain word when no trigger was recorded.
    @Test func theRecMarkNamesTheTrigger() async throws {
        try await ViewProbe.run { probe in
            for language in [AppLanguage.english, .russian] {
                ViewRender.withLanguage(language) {
                    probe.controller.recTrigger = nil
                    #expect(probe.controller.recBadgeText == L("rec"),
                            "\(language): \(probe.controller.recBadgeText)")
                    for trigger in RecTrigger.allCases {
                        probe.controller.recTrigger = trigger
                        let text = probe.controller.recBadgeText
                        #expect(text.contains(L("rec")), "\(language): \(text)")
                        #expect(text.contains(L(trigger.labelKey)),
                                "\(language): \(trigger) rendered as \(text)")
                        // it sits in the corner of the picture over the image —
                        // a sentence there covers the frame
                        #expect(text.count <= 20,
                                "\(language): \(text) is \(text.count) characters")
                    }
                }
            }
        }
    }

    /// Every status the panel can print says something, in both languages — a
    /// missing key renders as the key itself and reads as a bug in the app.
    @Test func everyStatusLineIsTranslated() async throws {
        try await ViewProbe.run { probe in
            for language in [AppLanguage.english, .russian] {
                ViewRender.withLanguage(language) {
                    probe.controller.visualRecTeaching = VisualRecTeaching()
                    let untaught = probe.controller.visualRecStatus
                    #expect(untaught != "visual_rec_status_untaught",
                            "\(language): untranslated status")

                    var half = VisualRecTeaching()
                    half.rolling = signature(230)
                    probe.controller.visualRecTeaching = half
                    #expect(probe.controller.visualRecStatus != untaught)

                    // two references that are far too alike: the panel has to say
                    // so rather than claim the trigger is ready
                    var weak = VisualRecTeaching()
                    weak.rolling = signature(61)
                    weak.idle = signature(60)
                    probe.controller.visualRecTeaching = weak
                    #expect(!weak.isTaught)
                    let weakText = probe.controller.visualRecStatus
                    #expect(!weakText.isEmpty)

                    taught(probe)
                    let ready = probe.controller.visualRecStatus
                    #expect(ready != weakText,
                            "\(language): ready and too-alike read the same")

                    for reading in [VisualRecReading.rolling, .idle] {
                        probe.controller.visualRecReading = reading
                        #expect(probe.controller.visualRecReadingText
                                != "visual_rec_reading_\(reading.rawValue)")
                    }
                    probe.controller.visualRecReading = nil
                    #expect(!probe.controller.visualRecReadingText.isEmpty)
                }
            }
        }
    }
}
