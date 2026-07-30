import AppKit
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
    /// make the row taller, and the row still has to fit the footer's half.
    @Test func collisionBadgeStaysInsideTheNamingRow() async throws {
        try await ViewProbe.run { probe in
            let plain = probe.fittingSizes { NamingFieldsView() }
            probe.controller.nameCollision = "TS_A001C01.mov"
            let warned = probe.fittingSizes { NamingFieldsView() }

            #expect(warned.ru.height == plain.ru.height,
                    "the collision badge made the naming row taller")
            #expect(warned.ru.width > plain.ru.width,
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
}
