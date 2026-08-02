import AppKit
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// The chroma key's controller half: what a click on the picture picks, what
/// survives a relaunch, and what deliberately does not.
@MainActor
struct ControllerChromaKeyTests {
    /// A frame with a green left half and a grey right half, pushed straight
    /// into the controller's own pipeline: the eyedropper reads whatever the
    /// display path last published, and this is the shortest way to give it
    /// something to read without a board.
    private func pushSplitFrame(_ controller: CaptureController) async {
        let width = 320
        let height = 180
        let buffer = MediaFixtures.pixelBuffer(level: 0, width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes + y * rowBytes
                for x in 0..<width {
                    // BGRA: a lit cyc green on the left, mid grey on the right
                    let green = x < width / 2
                    row[x * 4] = green ? 69 : 128
                    row[x * 4 + 1] = green ? 181 : 128
                    row[x * 4 + 2] = green ? 61 : 128
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        controller.pipeline.handleFormat(
            CaptureFormat(width: width, height: height, frameRate: 25,
                          timecodeFPS: 25, name: "320x180"))
        controller.pipeline.handleFrame(
            pixelBuffer: buffer, pts: CMTime(value: 40, timescale: 1000),
            timecode: nil, vancTrigger: nil)
        await ControllerWait.until {
            controller.pipeline.sampleDisplayColor(atFractionX: 0.25, y: 0.5) != nil
        }
    }

    /// A click on the screen adopts the color that is actually there — which is
    /// the whole point of the eyedropper: nobody can name their cyc's green.
    @Test func theEyedropperTakesTheScreenColorOffThePicture() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await pushSplitFrame(controller)
            controller.chromaPickArmed = true

            // a 16:9 viewport, so the picture fills it and a point IS a fraction
            let viewport = CGSize(width: 1600, height: 900)
            controller.pickChromaKeyColor(at: CGPoint(x: 400, y: 450),
                                          viewport: viewport)

            #expect(!controller.chromaPickArmed, "the pick stayed armed")
            #expect(controller.chromaKeyOn, "picking a color did not show the key")
            let picked = controller.chroma.keyColor
            #expect(abs(picked.green - 181 / 255.0) < 0.02,
                    "the pick missed the screen: \(picked.hexString)")
            #expect(picked.red < 0.35 && picked.blue < 0.35,
                    "the pick is not a green: \(picked.hexString)")
            // …and the key it lands keys exactly what was picked
            #expect(controller.chroma.matte(for: picked) == 0)
        }
    }

    /// A click on the letterbox is not a color. It must leave the key alone
    /// rather than adopt whatever the black bars are made of.
    @Test func aPickOutsideThePictureChangesNothing() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await pushSplitFrame(controller)
            let before = controller.chroma.keyColor
            controller.chromaPickArmed = true
            // a tall viewport on a 16:9 picture: the top 200pt are letterbox
            controller.pickChromaKeyColor(at: CGPoint(x: 800, y: 20),
                                          viewport: CGSize(width: 1600,
                                                           height: 1300))
            #expect(controller.chroma.keyColor == before,
                    "the letterbox was picked as a screen color")
            #expect(controller.chromaPickArmed,
                    "a miss disarmed the eyedropper the operator is mid-pick with")
        }
    }

    /// Switching the key off puts the eyedropper away with it — a crosshair
    /// left on the picture reads as a stuck mode.
    @Test func switchingTheKeyOffDisarmsTheEyedropper() async throws {
        try await ViewProbe.run { probe in
            probe.controller.chromaKeyOn = true
            probe.controller.chromaPickArmed = true
            probe.controller.chromaKeyOn = false
            #expect(!probe.controller.chromaPickArmed)
        }
    }

    // MARK: - persistence

    /// The dial-in comes back after a relaunch; the switch does not.
    @Test func theDialInPersistsAndTheSwitchDoesNot() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.chromaKeyOn = true
            controller.setChromaScreen(ChromaKey.blueScreen)
            controller.chromaTolerance = 0.34
            controller.chromaSoftness = 0.05
            controller.chromaSpill = 0.8
            controller.chromaBackground = .matte
            controller.chromaBackgroundColor = Color(ChromaKey.RGB(1, 0, 0))
            controller.commitAssistDraft() // the sliders are debounced

            #expect(controller.settings.chromaKeyColorHex == "#0000FF")
            #expect(controller.settings.chromaKeyTolerance == 0.34)
            #expect(controller.settings.chromaKeySpill == 0.8)
            #expect(controller.settings.chromaKeyBackground == "matte")
            #expect(controller.settings.chromaKeyBackgroundHex == "#FF0000")

            // …and the same values come back out of a reload
            let reloaded = CaptureSettings.loaded(from: probe.store)
            #expect(reloaded.chromaKeyTolerance == 0.34)
            controller.restoreChroma(from: reloaded)
            #expect(controller.chroma.keyColor == ChromaKey.blueScreen)
            #expect(controller.chroma.tolerance == 0.34)
            #expect(controller.chroma.softness == 0.05)
            #expect(controller.chroma.spill == 0.8)
            #expect(controller.chroma.background == .matte)
            #expect(controller.chroma.backgroundColor == ChromaKey.RGB(1, 0, 0))
            #expect(!controller.chroma.isOn,
                    "the key came back switched on by itself")
        }
    }

    /// Defaults are stored as nil, so a blob written by this build still
    /// decodes on a build that has never heard of the keyer.
    @Test func defaultsAreStoredAsNil() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.chromaTolerance = 0.5
            controller.commitAssistDraft()
            #expect(controller.settings.chromaKeyTolerance == 0.5)

            controller.chromaTolerance = ChromaKey().tolerance
            controller.commitAssistDraft()
            #expect(controller.settings.chromaKeyTolerance == nil)
            #expect(controller.settings.chromaKeyColorHex == nil)
            #expect(controller.settings.chromaKeyBackground == nil)
            #expect(controller.settings.chromaKeyBackgroundHex == nil)
        }
    }

    /// Settings written before the keyer existed decode, and land on the
    /// defaults the panel shows.
    @Test func oldSettingsDecodeWithoutTheChromaFields() throws {
        let legacy = """
        {"codec":"ProRes 422","namingTemplate":"{prefix}_C{clip}",
         "destinationPath":"/tmp/x","detectionMode":"vanc",
         "startDebounceFrames":0,"stopDebounceFrames":0,
         "projectName":"P","cameraLabel":"A"}
        """
        let settings = try JSONDecoder().decode(
            CaptureSettings.self, from: Data(legacy.utf8))
        #expect(settings.chromaKeyColorHex == nil)
        #expect(settings.chromaKeyTolerance == nil)
        #expect(settings.chromaKeyBackground == nil)
        #expect(settings.chromaKeyBackgroundImagePath == nil)

        var key = ChromaKey()
        key.keyColor = ChromaKey.blueScreen
        var restored = ChromaKey()
        restored.keyColor = settings.chromaKeyColorHex
            .flatMap(ChromaKey.RGB.init(hex:)) ?? ChromaKey().keyColor
        #expect(restored.keyColor == ChromaKey.greenScreen)
        #expect(key.keyColor != restored.keyColor)
    }

    /// A clamped slider cannot be pushed outside the range the math is defined
    /// on, whichever end it is dragged to.
    @Test func theSlidersAreClamped() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.chromaTolerance = 99
            controller.chromaSoftness = -3
            controller.chromaSpill = 42
            #expect(controller.chromaTolerance == ChromaKey.maxTolerance)
            #expect(controller.chromaSoftness == 0)
            #expect(controller.chromaSpill == 1)
        }
    }

    // MARK: - the plate

    /// The plate is loaded the way a pinned reference still is, remembered by
    /// path, and cleared without leaving the path behind.
    @Test func theBackgroundPlateLoadsAndIsRemembered() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let url = probe.root.appendingPathComponent("plate.png")
            let image = NSImage(size: NSSize(width: 64, height: 36))
            image.lockFocus()
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: 64, height: 36).fill()
            image.unlockFocus()
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]))
            try png.write(to: url)

            controller.loadChromaBackground(imageURL: url)
            #expect(controller.settings.chromaKeyBackgroundImagePath == url.path)
            let loaded = await ControllerWait.until {
                controller.chromaBackgroundImageName == "plate.png"
            }
            #expect(loaded, "the plate never finished decoding")

            controller.clearChromaBackgroundImage()
            #expect(controller.chromaBackgroundImageName == nil)
            #expect(controller.settings.chromaKeyBackgroundImagePath == nil)
        }
    }

    /// A plate whose file has gone (offloaded card, renamed folder) reports
    /// itself instead of leaving the operator with an empty background and no
    /// explanation.
    @Test func aPlateThatCannotBeReadIsReported() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let url = probe.root.appendingPathComponent("not-an-image.png")
            try Data([0x00, 0x01]).write(to: url)
            controller.loadChromaBackground(imageURL: url)
            let reported = await ControllerWait.until {
                controller.lastError != nil
            }
            #expect(reported, "a broken plate was adopted silently")
        }
    }

    // MARK: - the aids badge

    /// A remembered tolerance must not leave the assist badge lit for the rest
    /// of the project — only something actually on the picture counts.
    @Test func aStoredDialInDoesNotLightTheAssistBadge() {
        var assist = ViewAssist()
        assist.chroma.tolerance = 0.4
        assist.chroma.background = .matte
        #expect(!assist.isShowingAid)
        assist.chroma.isOn = true
        #expect(assist.isShowingAid)
    }
}
