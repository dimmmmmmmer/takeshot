import AVFoundation
import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Whether the look reaches the player, and — the half that costs a reshoot to
/// get wrong — whether it is applied twice.
///
/// A .cube can parse, load and be "enabled" and still not be on screen; the
/// same look can also be in the file already, in which case applying it again
/// is a grade nobody asked for. Every gate in front of the playback LUT is
/// walked here against a real .cube and a real frame, because the only visible
/// symptom of a mistake in this chain is a picture the operator judges exposure
/// by.
@Suite @MainActor struct MediaLUTTests {
    /// The suppression gates all read the same way from outside: what the tap
    /// delivers is either the identical buffer (no LUT in the path) or a
    /// rendered copy carrying the look.
    private struct Rig {
        let cube: CubeLUT
        let source: CVPixelBuffer
        let collector: MediaFixtures.FrameCollector
    }

    private func rig(_ controller: CaptureController,
                     in directory: URL) throws -> Rig {
        let cube = try CubeLUT.load(url: MediaFixtures.writeRedCube(
            at: directory.appendingPathComponent("red.cube")))
        let collector = MediaFixtures.FrameCollector()
        controller.playbackTap.setOnDisplayFrame { collector.record($0) }
        return Rig(cube: cube,
                   source: MediaFixtures.pixelBuffer(level: 0x80, width: 64,
                                                     height: 64),
                   collector: collector)
    }

    /// Push the frame through and settle the tap queue.
    private func deliver(_ rig: Rig, through controller: CaptureController) {
        controller.playbackTap.attachStill(rig.source)
        controller.playbackTap.queue.sync {}
    }

    @Test func theLookReachesThePlayerWhenThePreviewLUTIsOn() async throws {
        let media = try MediaFixtures.makeDirectory("lut-on")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            let rig = try self.rig(controller, in: media)
            controller.settings.lut.previewEnabled = true
            controller.currentCube = rig.cube
            controller.applyPlaybackLUT()

            self.deliver(rig, through: controller)
            let delivered = try #require(rig.collector.last)
            #expect(delivered !== rig.source, "the frame was passed through ungraded")
            let pixel = MediaFixtures.sample(delivered, atFractionX: 0.5)
            #expect(pixel.r > pixel.g + 60 && pixel.r > pixel.b + 60,
                    "the look is not in the frame: \(pixel.r)/\(pixel.g)/\(pixel.b)")
        }
    }

    /// The file already carries the look (our own recording tagged
    /// com.takeshot.lut): the preview LUT must take itself out of the path.
    @Test func aFileWithABakedLookIsLeftAlone() async throws {
        let media = try MediaFixtures.makeDirectory("lut-baked")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            let rig = try self.rig(controller, in: media)
            controller.settings.lut.previewEnabled = true
            controller.currentCube = rig.cube
            controller.playbackFileHasBakedLUT = true
            controller.applyPlaybackLUT()

            self.deliver(rig, through: controller)
            #expect(rig.collector.last === rig.source,
                    "a clip with the look baked in was graded a second time")
        }
    }

    /// Per-clip "LUT off" (the look came from the camera): same result, and it
    /// re-applies itself the moment the suppression is lifted.
    @Test func aPerClipSuppressionTakesTheLookOutAndPutsItBack() async throws {
        let media = try MediaFixtures.makeDirectory("lut-suppressed")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            let rig = try self.rig(controller, in: media)
            controller.settings.lut.previewEnabled = true
            controller.currentCube = rig.cube
            // the observer on this one applies the change itself
            controller.playbackLUTSuppressed = true

            self.deliver(rig, through: controller)
            #expect(rig.collector.last === rig.source)

            controller.playbackLUTSuppressed = false
            controller.playbackTap.queue.sync {}
            let delivered = try #require(rig.collector.last)
            #expect(delivered !== rig.source,
                    "lifting the suppression did not bring the look back")
        }
    }

    /// The mix coefficient reaches the tap. Zero is the operator's "show me the
    /// clean signal" stop, and it has to be exactly that — not 1% of a look.
    @Test func theMixCoefficientReachesTheTap() async throws {
        let media = try MediaFixtures.makeDirectory("lut-mix")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            let rig = try self.rig(controller, in: media)
            controller.settings.lut.previewEnabled = true
            controller.currentCube = rig.cube
            controller.lutIntensity = 0
            controller.applyPlaybackLUT()

            self.deliver(rig, through: controller)
            let delivered = try #require(rig.collector.last)
            // a render still happens — what changes is that it mixes to nothing
            #expect(delivered !== rig.source)
            let pixel = MediaFixtures.sample(delivered, atFractionX: 0.5)
            #expect(abs(pixel.r - 0x80) <= 3 && abs(pixel.g - 0x80) <= 3,
                    "intensity 0 changed the image: \(pixel.r)/\(pixel.g)/\(pixel.b)")

            // and pushing it back up re-renders the frame already on screen
            controller.lutIntensity = 1
            controller.playbackTap.queue.sync {}
            let regraded = MediaFixtures.sample(try #require(rig.collector.last),
                                                atFractionX: 0.5)
            #expect(regraded.r > regraded.g + 60)
        }
    }

    /// Ticking "apply to preview" must not re-read the .cube: a 65³ file is
    /// ~275k lines and re-parsing it on a checkbox flip stalled the window.
    /// The cached name here has no file behind it anywhere, so a rebuild that
    /// went to disk would clear the selection and set an error instead.
    @Test func theCubeCacheKeepsCheckboxFlipsOffTheDisk() async throws {
        let media = try MediaFixtures.makeDirectory("lut-cache")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            let cube = try CubeLUT.load(url: MediaFixtures.writeRedCube(
                at: media.appendingPathComponent("cached.cube")))
            let name = "cached-\(UUID().uuidString).cube"
            controller.cubeCache = .init(fileName: name, cube: cube, cdl: nil)
            controller.settings.lut.fileName = name

            controller.rebuildLUT()

            #expect(controller.settings.lut.fileName == name,
                    "the cached LUT was dropped as if its file were missing")
            #expect(controller.lastError == nil)
            let loaded = try #require(controller.currentCube)
            #expect(loaded.size == cube.size)
            #expect(loaded.data == cube.data)

            // a name the cache does not hold goes to disk and fails there
            controller.settings.lut.fileName = "other-\(UUID().uuidString).cube"
            controller.rebuildLUT()
            #expect(controller.currentCube == nil)
            #expect(controller.settings.lut.fileName == nil)
            #expect(controller.lastError?.hasPrefix("LUT:") == true)
        }
    }

    /// Baking the look into the recording is a separate switch from previewing
    /// it, and both are persisted — an operator who sets up a look before the
    /// first take expects it after a relaunch.
    @Test func thePreviewAndRecordSwitchesAreIndependentAndPersisted() async throws {
        try await ControllerHarness.run { controller, _ in
            #expect(!controller.lutPreviewOn)
            #expect(!controller.lutRecordOn)

            controller.lutRecordOn = true
            #expect(controller.settings.lut.recordEnabled == true)
            #expect(controller.settings.lut.previewEnabled != true,
                    "baking a look does not imply previewing it")
            #expect(controller.lutRecordOn)

            controller.lutPreviewOn = true
            #expect(controller.settings.lut.previewEnabled == true)
            #expect(controller.lutRecordOn, "one switch clobbered the other")

            controller.lutRecordOn = false
            #expect(controller.settings.lut.recordEnabled == false)
            #expect(controller.lutPreviewOn)
        }
    }

    /// The two switches are gated by ONE rule, and every surface asks it.
    ///
    /// Four places offer them — the badge popover, View ▸ LUT, the ⌃L key and
    /// the intensity row beside them — and three asked whether a look was
    /// selected while the popover did not. So the popover could write
    /// `previewEnabled = true` with no cube anywhere: a stored flag claiming a
    /// look that does not exist, and four controls disagreeing about one fact.
    ///
    /// Asserted as the rule rather than as a rendered control, for the reason
    /// `canChangeRecordingFormat` is: `.disabled(…)` is not something a
    /// headless render can be asked about, and a copy of the condition per
    /// surface is what let them drift in the first place.
    @Test func theLookSwitchesAreGatedByOneRuleEverySurfaceAsks() async throws {
        let media = try MediaFixtures.makeDirectory("lut-gate")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            controller.lutsDirectory = media
            _ = try MediaFixtures.writeRedCube(
                at: media.appendingPathComponent("red.cube"))

            #expect(controller.settings.lut.fileName == nil,
                    "the fixture ships a look — this test proves nothing")
            #expect(!controller.canApplyLUT,
                    "the look switches are live over no look at all")

            // the way in is the list beside them, not the switches: picking a
            // look opens the gate AND turns the preview on by itself, so
            // nothing is out of reach behind it
            controller.selectLUT(fileName: "red.cube")
            #expect(controller.lastError == nil,
                    "the fixture look did not load: \(controller.lastError ?? "")")
            #expect(controller.canApplyLUT)
            #expect(controller.lutPreviewOn,
                    "picking a look left both switches off and the gate now shut behind them")

            // …and back: clearing the look shuts it again
            controller.selectLUT(fileName: nil)
            #expect(!controller.canApplyLUT)
        }
    }

    /// Where imported looks live. The Resolve mirror is what puts the same look
    /// in the colourist's hands, and it only works at the exact path Resolve
    /// scans.
    @Test func theLUTFoldersAreTheOnesTheOtherToolsLookIn() {
        let ours = CaptureController.defaultLUTsDirectory
        #expect(ours.lastPathComponent == "LUTs")
        #expect(ours.deletingLastPathComponent().lastPathComponent == "TakeShot")

        let resolve = CaptureController.defaultResolveLUTDirectory
        #expect(resolve.path.hasSuffix(
            "Application Support/Blackmagic Design/DaVinci Resolve/LUT/TakeShot"))
    }

    /// The list entries are identified by file name — two looks exported with
    /// the same title from different projects are different LUTs.
    @Test func lutListEntriesAreIdentifiedByFileName() {
        let first = CaptureController.LUTInfo(fileName: "show_v2.cube", name: "show_v2")
        let same = CaptureController.LUTInfo(fileName: "show_v2.cube", name: "show_v2")
        let other = CaptureController.LUTInfo(fileName: "show_v3.cube", name: "show_v2")
        #expect(first.id == "show_v2.cube")
        #expect(first == same)
        #expect(first != other)
    }
}
