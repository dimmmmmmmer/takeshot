import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **Switching an aid off must not forget what it was set to.**
///
/// Framelines and the desqueeze both used to express off as their VALUE — a nil
/// aspect, a factor of 1 — which was the same statement while the picker
/// carried an Off row. With a checkbox beside them (owner: "давай и у
/// фреймлайнов и у десквиза вместо опции офф тоже сделаем галочки слева как у
/// остальных пунктов") that spelling deletes the 2.39 the operator set every
/// time they untick the box.
@Suite struct ModelAssistSwitchTests {
    @Test func anOldBlobsIntentIsReadForBothAids() {
        var carried = AssistSettings()
        carried.framelineRatio = 2.39
        carried.desqueezeFactor = 2
        #expect(carried.framelinesOnEffective)
        #expect(carried.desqueezeOnEffective)

        let untouched = AssistSettings()
        #expect(!untouched.framelinesOnEffective)
        #expect(!untouched.desqueezeOnEffective)

        // A blob that stored the factor as 1 meant "off" then and means it now.
        var spherical = AssistSettings()
        spherical.desqueezeFactor = 1
        #expect(!spherical.desqueezeOnEffective)
    }

    @Test func theFlagIsTheAuthorityOnceItExists() {
        var settings = AssistSettings()
        settings.framelineRatio = 2.39
        settings.framelinesOn = false
        #expect(!settings.framelinesOnEffective)
        // …and the aspect is still there, which is the point.
        #expect(settings.framelineRatioChosen == 2.39)
        // …and nothing is drawn.
        #expect(settings.framelineRatioDrawn == nil)

        settings.framelinesOn = true
        #expect(settings.framelineRatioDrawn == 2.39)
    }

    @Test func theDesqueezeIsAppliedOnlyWhileItIsOn() {
        var settings = AssistSettings()
        settings.desqueezeFactor = 1.33
        settings.desqueezeOn = false
        #expect(settings.desqueezeFactorChosen == 1.33)
        #expect(settings.desqueezeApplied == 1,
                "a switched-off desqueeze still squeezes the picture")
        settings.desqueezeOn = true
        #expect(settings.desqueezeApplied == 1.33)
    }

    /// An aid switched on with nothing ever chosen draws something — an empty
    /// picker and no guide is a checkbox that appears not to work.
    @Test func anAidSwitchedOnWithNoChoiceHasADefault() {
        var settings = AssistSettings()
        settings.framelinesOn = true
        #expect(settings.framelineRatioDrawn
            == AssistSettings.defaultFramelineRatio)
        settings.desqueezeOn = true
        #expect(settings.desqueezeApplied
            == AssistSettings.defaultDesqueezeFactor)
    }

    /// A stored zero or a negative is a hand-edited blob, and a frameline at
    /// ratio 0 draws a box with no height.
    @Test func aNonsenseStoredValueFallsBackToTheDefault() {
        var settings = AssistSettings()
        settings.framelinesOn = true
        settings.framelineRatio = 0
        #expect(settings.framelineRatioChosen
            == AssistSettings.defaultFramelineRatio)
        settings.desqueezeOn = true
        settings.desqueezeFactor = -2
        #expect(settings.desqueezeFactorChosen
            == AssistSettings.defaultDesqueezeFactor)
    }
}

/// …and the live half: the factor the renderer is handed, and what survives
/// a switch through the controller.
@Suite @MainActor struct ControllerAssistSwitchTests {
    @Test func theFactorSurvivesBeingSwitchedOffAndComesBack() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.settings.assist.desqueezeOn = true
            controller.setAssist { $0.desqueeze = 1.33 }
            #expect(controller.settings.assist.desqueezeFactor == 1.33)

            // …switched off the way the checkbox does it.
            controller.settings.assist.desqueezeOn = false
            controller.setAssist { $0.desqueeze = 1 }
            #expect(controller.liveAssist.desqueeze == 1,
                    "the picture is still squeezed")
            #expect(controller.settings.assist.desqueezeFactor == 1.33,
                    "the operator's factor was thrown away")

            // …and back on, at the factor they chose.
            controller.settings.assist.desqueezeOn = true
            controller.setAssist {
                $0.desqueeze = controller.settings.assist.desqueezeFactorChosen
            }
            #expect(controller.liveAssist.desqueeze == 1.33)
        }
    }

    /// The guides the renderer draws come from one conversion, so "off" cannot
    /// mean two things.
    @Test func theRenderersGuidesFollowTheSwitch() {
        var settings = AssistSettings()
        settings.framelineRatio = 2.39
        settings.framelinesOn = false
        #expect(AssistGuides(settings: settings).ratio == nil)
        settings.framelinesOn = true
        #expect(AssistGuides(settings: settings).ratio == 2.39)
    }
}
