import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// Guards the footer against the Russian UI: the bar carries the REC button dead
/// center, the utilities on the left and the naming fields on the right, and it
/// has one row of height to do it in. A localized label that grows pushes the
/// naming fields into the record button or wraps the row — neither throws, both
/// are the "i18n ухудшает UI" the owner reported.
@MainActor
struct ViewFooterTests {
    /// Everything in the footer's left half is an icon and everything in its
    /// right half is a latin field label (PREFIX/CAM/ROLL/CLIP/POSTFIX, chosen
    /// so file names stay portable). So the footer is required to measure
    /// IDENTICALLY in both languages — a difference means a localized string
    /// reached the bar and the centered REC button is no longer centered.
    @Test func footerMeasuresTheSameInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes { BottomBarView() }
            #expect(ideal.ru == ideal.en,
                    "footer changed size with the language: \(ideal)")
            #expect(ideal.ru.width > 0 && ideal.ru.height > 0)

            let laid = probe.sizes(proposedWidth: ViewBudget.footerWidth) {
                BottomBarView()
            }
            #expect(laid.ru == laid.en)
            #expect(laid.ru.width == ViewBudget.footerWidth,
                    "the footer overflowed the narrowest main column")
        }
    }

    /// The footer has to fit the narrowest window the app allows.
    @Test func footerFitsTheNarrowestMainColumn() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes { BottomBarView() }
            #expect(ideal.ru.width <= ViewBudget.footerWidth,
                    "footer wants \(ideal.ru.width)pt, has \(ViewBudget.footerWidth)")
        }
    }

    /// The meters replace the footer's left-hand utilities while capturing, and
    /// the "no audio" capsule that stands in for them IS localized. It must not
    /// change the bar's height — the footer is a single row.
    @Test func capturingFooterKeepsItsHeightWithAndWithoutAudio() async throws {
        try await ViewProbe.run { probe in
            probe.controller.isCapturing = true
            let silent = probe.sizes(proposedWidth: ViewBudget.footerWidth) {
                BottomBarView()
            }
            ViewFixtures.seedAudioLevels(probe.controller)
            let metered = probe.sizes(proposedWidth: ViewBudget.footerWidth) {
                BottomBarView()
            }

            #expect(silent.ru.height == silent.en.height,
                    "the localized \"no audio\" capsule changed the footer height")
            #expect(metered.ru == metered.en)
            // meters are taller than the capsule by design; what matters is that
            // the language does not decide the height
            #expect(metered.ru.height >= silent.ru.height)
        }
    }

    /// The naming fields are deliberately locale-independent — the labels are
    /// latin because they end up in file names on other people's systems. This
    /// pins that: localize CAM/ROLL/CLIP and the row grows into the REC button.
    @Test func namingFieldsAreLocaleIndependentAndFitTheFooterHalf() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes { NamingFieldsView() }
            #expect(ideal.ru == ideal.en,
                    "a naming field label became localized: \(ideal)")
            let half = ViewBudget.footerHalfWidth
            #expect(ideal.ru.width <= half,
                    "naming row wants \(ideal.ru.width)pt of \(half)")
        }
    }

    /// The name-collision warning is the one localized thing in the naming row
    /// ("TAKEN" / "ЗАНЯТО"). It may be a few points wider in Russian; it may not
    /// make the row taller, and the block still has to fit the footer's half.
    ///
    /// That it RENDERS is measured on the file-name row itself, not on the block:
    /// the slate row under it is the widest thing in the block since it went
    /// compact, so the block's width no longer moves when this badge appears.
    @Test func collisionBadgeStaysInsideTheNamingRow() async throws {
        try await ViewProbe.run { probe in
            let plainRow = probe.fittingSizes { NamingFileNameRow() }
            let plain = probe.fittingSizes { NamingFieldsView() }
            probe.controller.nameCollision = "TS_A001C01.mov"
            let warnedRow = probe.fittingSizes { NamingFileNameRow() }
            let warned = probe.fittingSizes { NamingFieldsView() }

            #expect(warned.ru.height == plain.ru.height,
                    "the collision badge made the naming row taller")
            #expect(warnedRow.ru.width > plainRow.ru.width,
                    "the collision badge did not render at all")
            #expect(warned.ru.width <= ViewBudget.footerHalfWidth,
                    "the warned naming row wants \(warned.ru.width)pt")
        }
    }

    /// The CLIP field is a fixed 50pt digit box with a stepper: it must stay the
    /// same size in both languages (its label is latin) and it must render.
    @Test func clipFieldIsLocaleIndependent() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes { ClipField() }
            #expect(ideal.ru == ideal.en)
            #expect(ideal.ru.width > 50)
        }
    }

    /// The naming-style menu in the footer is an icon whose menu lists the
    /// vendor presets. The trigger must stay icon-sized whatever the preset
    /// names are — it is `.fixedSize()` in a row that has no slack.
    @Test func namingPresetMenuStaysIconSized() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes { NamingPresetMenu() }
            #expect(ideal.ru == ideal.en)
            #expect(ideal.ru.width > 0 && ideal.ru.width < 60,
                    "the preset menu grew past an icon: \(ideal.ru)")
        }
    }

    /// The REC button is the anchor of the whole footer: a fixed 48pt disc that
    /// no translation may resize.
    @Test func recordButtonKeepsItsFixedSize() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes { RecordButton() }
            #expect(ideal.en == CGSize(width: 48, height: 48))
            #expect(ideal.ru == ideal.en)
        }
    }

    // MARK: - the reorganized footer (owner item 48)

    /// The footer must not overflow the narrowest main column in ANY state it can
    /// be in on a shoot: idle, capturing with all 16 channels metering, and
    /// recording — when the codec picker and the folder button go disabled, which
    /// is a colour change and must not be a layout change.
    @Test func footerFitsTheNarrowestColumnInEveryShootingState() async throws {
        try await ViewProbe.run { probe in
            @MainActor func laidOut() -> (en: CGSize, ru: CGSize) {
                probe.sizes(proposedWidth: ViewBudget.footerWidth) { BottomBarView() }
            }
            let idle = laidOut()
            probe.controller.isCapturing = true
            ViewFixtures.seedAudioLevels(probe.controller)
            let metered = laidOut()
            probe.controller.isRecording = true
            let recording = laidOut()

            for (state, size) in [("idle", idle), ("metering", metered),
                                  ("recording", recording)] {
                #expect(size.ru.width == ViewBudget.footerWidth,
                        "the \(state) footer overflowed to \(size.ru.width)pt")
                #expect(size.ru == size.en, "\(state) footer differs by language: \(size)")
            }
            #expect(recording.ru.height == metered.ru.height,
                    "locking the codec changed the footer's height")
        }
    }

    /// The left-hand group and the record button are stacked, not laid out in a
    /// row: a group that grows just slides underneath the button. What stops it is
    /// the gap `BottomBarView` reserves, and the reserve has to be at least half
    /// the centered group — measured here rather than trusted.
    @Test func theReservedGapCoversHalfTheRecordGroup() async throws {
        try await ViewProbe.run { probe in
            let center = probe.fittingSizes { FooterCenterControls() }
            #expect(center.ru == center.en)
            #expect(BottomBarView.centerReserve >= center.ru.width / 2,
                    "record group \(center.ru.width)pt, reserve \(BottomBarView.centerReserve)pt")
        }
    }

    /// Everything on the left of the record button — folder, codec, naming style,
    /// volume, DIM and the meters — has to fit the zone beside it when squeezed:
    /// the folder name drops out and the codec falls back to its short flavour
    /// name rather than the row reaching the button. Worst case: capturing with
    /// 16 embedded channels at the app's minimum window width.
    @Test func theShootingControlsFitBesideTheRecordButton() async throws {
        try await ViewProbe.run { probe in
            let zone = ViewBudget.footerSideZoneWidth
            let idle = probe.minimumWidths { FooterShootingControls() }
            #expect(idle.ru <= zone,
                    "the idle controls need \(idle.ru)pt of \(zone)")

            probe.controller.isCapturing = true
            ViewFixtures.seedAudioLevels(probe.controller)
            let metered = probe.minimumWidths { FooterShootingControls() }
            #expect(metered.ru <= zone,
                    "16 channels metering needs \(metered.ru)pt of \(zone)")
            #expect(metered.ru == metered.en,
                    "the shooting controls differ by language: \(metered)")
            // and they really do compress instead of overflowing the zone
            let laid = probe.sizes(proposedWidth: zone) { FooterShootingControls() }
            #expect(laid.ru.width <= zone + 4,
                    "the controls overflowed their zone by \(laid.ru.width - zone)pt")
        }
    }

    /// The record folder is icon-only in the footer (owner item 3): its name is
    /// operator data that can be anything — the fixture's own is a long scratch
    /// path — and it lives in the tooltip now. The button must stay icon-sized
    /// whatever the folder is called, in both languages.
    @Test func theFolderButtonStaysIconSizedWhateverTheFolderIsCalled() async throws {
        try await ViewProbe.run { probe in
            // the footer's own button style, or the measurement is of AppKit's
            // bordered chrome rather than of the label inside it
            let ideal = probe.fittingSizes {
                FooterFolderButton().buttonStyle(.borderless)
            }
            #expect(ideal.en.width < 40,
                    "the folder button grew past an icon: \(ideal.en.width)pt")
            #expect(ideal.ru == ideal.en)
        }
    }

    /// The codec picker is icon-only too (owner item 3): the name lives in the
    /// tooltip, so every codec has to leave the trigger byte-for-byte the same
    /// size — a picker that resized with the setting would reflow the footer on
    /// a codec change.
    @Test func theCodecPickerStaysIconSizedForEveryCodec() async throws {
        try await ViewProbe.run { probe in
            var first: CGSize?
            for codec in CaptureCodec.allCases {
                probe.controller.settings.capture.codec = codec
                let ideal = probe.fittingSizes { FooterCodecMenu() }
                #expect(ideal.ru == ideal.en, "\(codec.rawValue): \(ideal)")
                #expect(ideal.en.width < 50,
                        "\(codec.rawValue) grew the icon to \(ideal.en.width)pt")
                if let first {
                    #expect(ideal.en == first,
                            "\(codec.rawValue) resized the icon: \(ideal.en) vs \(first)")
                } else {
                    first = ideal.en
                }
            }
        }
    }

    /// Locking the codec and the folder while a take records is a colour change.
    /// If it were a size change the whole footer would reflow the moment the
    /// camera rolled — which is the one moment nothing may move.
    @Test func lockingTheRecordingFormatDoesNotReflowTheFooter() async throws {
        try await ViewProbe.run { probe in
            probe.controller.isCapturing = true
            let unlocked = probe.fittingSizes { FooterShootingControls() }
            probe.controller.isRecording = true
            #expect(!probe.controller.canChangeRecordingFormat)
            let locked = probe.fittingSizes { FooterShootingControls() }
            #expect(locked.en == unlocked.en, "the locked footer resized: \(locked)")
            #expect(locked.ru == unlocked.ru)
        }
    }

    /// DIM is a fixed badge next to the volume. Its highlight must not move the
    /// controls around it, and its label is the same three latin letters in both
    /// languages (DaVinci's DIM, which is what an operator is looking for).
    @Test func dimButtonKeepsItsSizeWhenEngaged() async throws {
        try await ViewProbe.run { probe in
            probe.controller.isCapturing = true
            let off = probe.fittingSizes { FooterDimButton(live: probe.controller.live) }
            probe.controller.toggleMonitorDim()
            #expect(probe.controller.live.dimmed, "DIM did not engage")
            let on = probe.fittingSizes { FooterDimButton(live: probe.controller.live) }

            #expect(off.en == CGSize(width: 26, height: 18))
            #expect(on.en == off.en, "the DIM highlight resized the button: \(on)")
            #expect(on.ru == on.en, "the DIM label became localized: \(on)")
        }
    }
}
