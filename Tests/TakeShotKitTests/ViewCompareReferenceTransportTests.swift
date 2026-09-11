import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// **The freeze control on the compare bar**, which exists only because the
/// reference moves now.
///
/// A pinned take PLAYS (`ReferenceClipPlayer`), and the moment an operator
/// wants to line the next setup up against one particular frame of it, a moving
/// picture is the wrong tool. What these hold is that the control is offered
/// exactly where there is a clip to freeze — over a still pin there is nothing
/// to stop, and a button that does nothing is worse than no button.
@Suite @MainActor struct ViewCompareReferenceTransportTests {
    /// The rule, across every state that can reach the bar.
    @Test func theFreezeControlIsOfferedOnlyForAMovingReference() async throws {
        try await ControllerHarness.run { controller, root in
            #expect(!controller.showsReferenceTransport,
                    "an app with nothing pinned offers a freeze")

            // A still pin: the bar is there, the control is not.
            controller.referencePinned = true
            #expect(controller.showsCompareBar,
                    "the compare bar is not shown — the premise is gone")
            #expect(!controller.showsReferenceTransport, """
                a pinned STILL offers a freeze control, which would do nothing \
                at all
                """)

            // …and with a clip behind it, it is offered.
            let url = try await MediaFixtures.writeClip(
                at: root.appendingPathComponent("ref.mov"), frames: 12)
            controller.play(url: url)
            #expect(await ControllerWait.until {
                controller.playbackTap.currentBuffer() != nil
            })
            controller.pinReferenceFromCurrentFrame()
            #expect(controller.referenceIsMoving, "the pin produced no clip")
            #expect(controller.showsReferenceTransport)

            controller.unpinReference()
            #expect(!controller.showsReferenceTransport,
                    "the freeze control outlived the reference")
        }
    }

    /// The control names its rule on the controller rather than spelling one
    /// inline.
    ///
    /// `ViewDisabledRuleTests` walks `.disabled(` sites and cannot see a bare
    /// `if`, so this is asserted the way `ViewCompareBarReportsTests` asserts
    /// the pin's own condition: on the source of the view.
    @Test func theFreezeControlNamesItsRuleOnTheController() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/TakeShotKit/CompareControls.swift"),
            encoding: .utf8)
        #expect(source.contains("if controller.showsReferenceTransport {"), """
            the freeze control does not ask a named rule — a condition spelled \
            in the view is one the controller's tests cannot see
            """)
    }

    /// Both directions have words, in both languages: the control is one
    /// button that changes meaning, and a missing key would render as its own
    /// name in a tooltip.
    @Test func theFreezeControlSpeaksBothLanguages() {
        for language in [AppLanguage.english, .russian] {
            let words = ViewRender.withLanguage(language) {
                [L("reference_freeze_help"), L("reference_play_help")]
            }
            for word in words {
                #expect(!word.hasPrefix("reference_"),
                        Comment(rawValue: "\(language.rawValue): \(word)"))
            }
            #expect(Set(words).count == 2,
                    Comment(rawValue: "\(language.rawValue) says the same thing "
                            + "for both directions: \(words)"))
        }
    }

    /// …and the bar still fits the player it sits on, in both languages, with
    /// the control on it.
    @Test func theCompareBarStillFitsWithTheFreezeControl() async throws {
        try await ViewProbe.run { probe in
            probe.controller.referencePinned = true
            let sizes = probe.fittingSizes { probe.hosted(ComparePinControls()) }
            #expect(sizes.en.width <= 120,
                    "the pin controls want \(sizes.en.width)pt")
            #expect(sizes.ru.width == sizes.en.width, """
                the controls measure \(sizes.ru.width)pt in Russian against \
                \(sizes.en.width) in English — they are icons, so they must not
                """)
        }
    }
}
