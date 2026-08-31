import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// The filter control beside the playback transport, and the picture it claims
/// to describe.
///
/// The control and the tap asked different questions. `applyPlaybackLUT` — what
/// actually reaches the picture — asks four: is preview on, is the look already
/// in the file's codes, has this clip had it switched off, and is there a cube.
/// The bar asked two, so it could light in the accent colour over an ungraded
/// picture and offer to switch off something that was not on.
///
/// So every case is asserted against the FRAME the tap delivers, not against
/// the flags: the tap either hands back the identical buffer (nothing in the
/// path) or a rendered copy carrying the look, which is the only reading that
/// cannot agree with a wrong control by accident.
@Suite @MainActor struct ViewPlaybackLookTests {
    /// A look, a frame to put it on, and somewhere to catch what comes out.
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
        controller.playbackTap.setOnDisplayFrame { collector.record($0[.decorated]) }
        return Rig(cube: cube,
                   source: MediaFixtures.pixelBuffer(level: 0x80, width: 64,
                                                     height: 64),
                   collector: collector)
    }

    /// Whether the look reached the picture. The tap passes the frame straight
    /// through when there is nothing in the path.
    private func lookReachesThePicture(_ rig: Rig,
                                       _ controller: CaptureController) -> Bool {
        controller.applyPlaybackLUT()
        controller.playbackTap.attachStill(rig.source)
        controller.playbackTap.queue.sync {}
        return rig.collector.last !== rig.source
    }

    /// The four states, each read off the control and checked against the
    /// frame. `none` over a cleared look is the one that was wrong: the bar
    /// asked only whether preview was on.
    @Test func theControlSaysWhatThePictureIs() async throws {
        let media = try MediaFixtures.makeDirectory("playback-look")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            let rig = try self.rig(controller, in: media)

            controller.settings.lut.previewEnabled = true
            controller.currentCube = rig.cube
            #expect(controller.playbackLook == .applied)
            #expect(self.lookReachesThePicture(rig, controller),
                    "the control said the look was applied and it was not")

            controller.playbackLUTSuppressed = true
            #expect(controller.playbackLook == .suppressed)
            #expect(!self.lookReachesThePicture(rig, controller),
                    "a suppressed look still reached the picture")
            controller.playbackLUTSuppressed = false

            controller.playbackFileHasBakedLUT = true
            #expect(controller.playbackLook == .baked)
            #expect(!self.lookReachesThePicture(rig, controller),
                    "a baked take had the look applied a second time")
            controller.playbackFileHasBakedLUT = false

            controller.settings.lut.previewEnabled = false
            #expect(controller.playbackLook == .none)
            #expect(!self.lookReachesThePicture(rig, controller))
        }
    }

    /// Preview on with no look at all. This is the state the extraction is
    /// for, and it is reachable by an ordinary action rather than by setting a
    /// flag: `selectLUT(fileName: nil)` clears the look and deliberately leaves
    /// `previewEnabled` alone, so clearing the library while preview is on
    /// leaves the switch on over nothing.
    ///
    /// The bar asked `lutPreviewOn`, which is still true here, and drew the
    /// accent tint — an indicator lit over an ungraded picture, whose reading
    /// sends the operator looking for a look that is not being applied.
    @Test func aPreviewSwitchLeftOnOverNoLookShowsNothing() async throws {
        let media = try MediaFixtures.makeDirectory("playback-look-cleared")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            controller.lutsDirectory = media
            let rig = try self.rig(controller, in: media)
            _ = try MediaFixtures.writeRedCube(
                at: media.appendingPathComponent("red.cube"))

            controller.selectLUT(fileName: "red.cube")
            #expect(controller.lastError == nil,
                    "the fixture look did not load: \(controller.lastError ?? "")")
            #expect(controller.playbackLook == .applied)

            controller.selectLUT(fileName: nil)
            // the switch really is still on — this is not a test of selectLUT
            #expect(controller.lutPreviewOn,
                    "clearing the look turned preview off, so this state is gone")
            #expect(controller.currentCube == nil)
            #expect(controller.playbackLook == .none,
                    "the control offered a look switch with no look to switch")
            #expect(!self.lookReachesThePicture(rig, controller))
        }
    }

    /// The look being in the FILE outranks every setting, because it is a fact
    /// about the footage rather than about the app: turning preview off does
    /// not un-bake a take, and a control that then said "no look" would be
    /// telling the operator something false about what they are reviewing.
    @Test func aBakedTakeSaysSoWhateverTheSwitchesSay() {
        for previewEnabled in [true, false] {
            for suppressed in [true, false] {
                for hasCube in [true, false] {
                    let look = PlaybackLook.current(
                        previewEnabled: previewEnabled, hasCube: hasCube,
                        fileHasBakedLook: true, suppressed: suppressed)
                    let flags: String = "preview=\(previewEnabled)"
                        + " cube=\(hasCube) suppressed=\(suppressed)"
                    #expect(look == .baked,
                            "a baked take read as \(look) with \(flags)")
                }
            }
        }
    }

    /// Only one of the four cases puts the cube in the path, and only two of
    /// them are a control the operator can press. The `baked` case is the
    /// reason that is two questions and not one: it is visible and it is not
    /// pressable, because no press can reach a look that is already in the
    /// codes.
    /// Over `allCases`, not a hand-written list: the list said
    /// `[.none, .baked, .applied, .suppressed]` and `bypassed` — the newest
    /// case, and the one the whole difference-mode rule is about — was simply
    /// not in it, so nothing here was ever asked about it.
    @Test func exactlyOneStateGradesTheFrame() {
        #expect(PlaybackLook.allCases.filter(\.appliesCube) == [.applied])
        #expect(PlaybackLook.allCases.count == 5,
                "a state was added; check `PlaybackLookButton` decides for it")
    }
}
