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

    // MARK: - the panel survives a pick (owner item 30)

    /// Arming the eyedropper closes the panel on purpose and the pick brings it
    /// straight back.
    ///
    /// The pick is a click on the PICTURE, i.e. a click outside the popover. A
    /// popover that is still open when it lands eats the click to dismiss
    /// itself, so the operator's first click did nothing and the second picked
    /// a color with the panel already gone. Closing it deliberately makes the
    /// first click the pick; reopening puts the operator back in front of the
    /// dials with the new key on the picture, which is when a key is judged.
    @Test func theAssistPanelComesBackAfterAPick() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await pushSplitFrame(controller)
            controller.showAssistPopover = true

            controller.toggleChromaPick()
            #expect(controller.chromaPickArmed)
            #expect(!controller.showAssistPopover,
                    "the popover would have swallowed the operator's first click")

            controller.pickChromaKeyColor(at: CGPoint(x: 400, y: 450),
                                          viewport: CGSize(width: 1600,
                                                           height: 900))
            #expect(!controller.chromaPickArmed)
            #expect(controller.showAssistPopover,
                    "the panel did not come back to judge the key on")
        }
    }

    /// Cancelling the pick with a second click on the eyedropper puts the panel
    /// back too — a mode that closed the panel has to be able to undo that.
    @Test func cancellingThePickAlsoBringsThePanelBack() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.showAssistPopover = true
            controller.toggleChromaPick()
            controller.toggleChromaPick()
            #expect(!controller.chromaPickArmed)
            #expect(controller.showAssistPopover)
        }
    }

    /// A pick armed from somewhere the panel was NOT open (a hotkey, the remote)
    /// must not open it afterwards — reopening is putting back what arming took
    /// away, not a way for the eyedropper to raise a panel nobody asked for.
    @Test func aPickWithNoPanelOpenDoesNotOpenOne() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await pushSplitFrame(controller)
            #expect(!controller.showAssistPopover)

            controller.toggleChromaPick()
            controller.pickChromaKeyColor(at: CGPoint(x: 400, y: 450),
                                          viewport: CGSize(width: 1600,
                                                           height: 900))
            #expect(!controller.showAssistPopover,
                    "the pick opened a panel that had not been open")
        }
    }

    /// A miss — a click on the letterbox — leaves the eyedropper armed and the
    /// panel away, so the next click is another attempt rather than a dismissal.
    @Test func aMissedPickKeepsThePanelAwayAndTheEyedropperArmed() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            await pushSplitFrame(controller)
            controller.showAssistPopover = true
            controller.toggleChromaPick()

            controller.pickChromaKeyColor(at: CGPoint(x: 800, y: 20),
                                          viewport: CGSize(width: 1600,
                                                           height: 1300))
            #expect(controller.chromaPickArmed)
            #expect(!controller.showAssistPopover,
                    "the panel came back mid-pick and will eat the next click")

            // …and it still comes back once the pick lands
            controller.pickChromaKeyColor(at: CGPoint(x: 400, y: 450),
                                          viewport: CGSize(width: 1600,
                                                           height: 900))
            #expect(controller.showAssistPopover)
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
            controller.chromaBackgroundRGB = ChromaKey.RGB(1, 0, 0)
            controller.commitAssistDraft() // the sliders are debounced

            #expect(controller.settings.chromaKey.colorHex == "#0000FF")
            #expect(controller.settings.chromaKey.tolerance == 0.34)
            #expect(controller.settings.chromaKey.spill == 0.8)
            #expect(controller.settings.chromaKey.background == "matte")
            #expect(controller.settings.chromaKey.backgroundHex == "#FF0000")

            // …and the same values come back out of a reload
            let reloaded = CaptureSettings.loaded(from: probe.store)
            #expect(reloaded.chromaKey.tolerance == 0.34)
            controller.restoreChroma(from: reloaded.chromaKey)
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
            #expect(controller.settings.chromaKey.tolerance == 0.5)

            controller.chromaTolerance = ChromaKey().tolerance
            controller.commitAssistDraft()
            #expect(controller.settings.chromaKey.tolerance == nil)
            #expect(controller.settings.chromaKey.colorHex == nil)
            #expect(controller.settings.chromaKey.background == nil)
            #expect(controller.settings.chromaKey.backgroundHex == nil)
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
        #expect(settings.chromaKey.colorHex == nil)
        #expect(settings.chromaKey.tolerance == nil)
        #expect(settings.chromaKey.background == nil)
        #expect(settings.chromaKey.backgroundImagePath == nil)

        var key = ChromaKey()
        key.keyColor = ChromaKey.blueScreen
        var restored = ChromaKey()
        restored.keyColor = settings.chromaKey.colorHex
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

/// The plate behind the actor: where it comes from, and where it sits.
///
/// Its own suite rather than more rows in the one above — the plate is chosen
/// from the app's own media now (owner item 36) and placed by hand (item 37),
/// which is a job of its own and has nothing to do with the keying.
@MainActor
struct ControllerChromaPlateTests {
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

            controller.loadChromaBackground(mediaURL: url)
            #expect(controller.settings.chromaKey.backgroundImagePath == url.path)
            let loaded = await ControllerWait.until {
                controller.chromaBackgroundImageName == "plate.png"
            }
            #expect(loaded, "the plate never finished decoding")

            controller.clearChromaBackgroundImage()
            #expect(controller.chromaBackgroundImageName == nil)
            #expect(controller.settings.chromaKey.backgroundImagePath == nil)
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
            controller.loadChromaBackground(mediaURL: url)
            let reported = await ControllerWait.until {
                controller.lastError != nil
            }
            #expect(reported, "a broken plate was adopted silently")
        }
    }

    /// A CLIP is a plate too (owner item 36): the head frame of a take or an
    /// Other-content movie goes behind the actor, so the unit that has the
    /// plate as a QuickTime does not have to export a frame of it first.
    @Test func aClipCanBeThePlate() async throws {
        let media = try MediaFixtures.makeDirectory("chroma-plate-clip")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("A001C001.mov"), frames: 6)

        try await ViewProbe.run { probe in
            probe.controller.loadChromaBackground(mediaURL: clip)
            let loaded = await ControllerWait.until {
                probe.controller.chromaBackgroundImageName == "A001C001.mov"
            }
            #expect(loaded, "the clip never yielded a plate")
            #expect(probe.controller.settings.chromaKey.backgroundImagePath
                    == clip.path)
        }
    }

    /// The plate's placement is dialled in like everything else on the key, and
    /// comes back with it (owner item 37).
    @Test func thePlateLayoutIsAdjustableAndPersists() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            #expect(!controller.chromaPlateIsAdjusted)

            controller.chromaPlateFit = .fill
            controller.chromaPlateScale = 1.5
            controller.chromaPlateOffsetX = 0.2
            controller.chromaPlateOffsetY = -0.1
            controller.commitAssistDraft()
            #expect(controller.chromaPlateIsAdjusted)

            #expect(controller.settings.chromaKey.plateFit == "fill")
            #expect(controller.settings.chromaKey.plateScale == 1.5)
            #expect(controller.settings.chromaKey.plateOffsetX == 0.2)
            #expect(controller.settings.chromaKey.plateOffsetY == -0.1)

            let reloaded = CaptureSettings.loaded(from: probe.store)
            controller.restoreChroma(from: reloaded.chromaKey)
            #expect(controller.chromaPlate.fit == .fill)
            #expect(controller.chromaPlate.scale == 1.5)
            #expect(controller.chromaPlate.offsetX == 0.2)
            #expect(controller.chromaPlate.offsetY == -0.1)

            // the sliders cannot be pushed past what the math is defined on
            controller.chromaPlateScale = 99
            controller.chromaPlateOffsetX = 5
            controller.chromaPlateOffsetY = -5
            #expect(controller.chromaPlateScale == ChromaKey.PlateLayout.maxScale)
            #expect(controller.chromaPlateOffsetX
                    == ChromaKey.PlateLayout.maxOffset)
            #expect(controller.chromaPlateOffsetY
                    == -ChromaKey.PlateLayout.maxOffset)

            // and reset really is the plain centered fit — stored as nil, so a
            // blob this build writes still decodes on one without the fields
            controller.resetChromaPlate()
            #expect(!controller.chromaPlateIsAdjusted)
            #expect(controller.settings.chromaKey.plateFit == nil)
            #expect(controller.settings.chromaKey.plateScale == nil)
            #expect(controller.settings.chromaKey.plateOffsetX == nil)
            #expect(controller.settings.chromaKey.plateOffsetY == nil)
        }
    }
}
