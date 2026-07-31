import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// An ASC CDL from a DIT, all the way to the picture on the monitor.
///
/// The design decision under test is that a CDL becomes a cube at import and
/// then IS a LUT everywhere else — so what has to hold is that the file lands
/// in the library, that the grade survives the conversion into the lattice, and
/// that the nine numbers are still around afterwards for the EDL. A CDL that
/// previewed correctly but lost its parameters would cost the colourist the
/// day's grade with nothing on screen to show for it.
@Suite @MainActor struct MediaCDLLookTests {
    /// The look a cart would hand over: a warm lift, a cool shadow pull, a
    /// shoulder on blue, some saturation out.
    private static let cdlText = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ColorDecisionList xmlns="urn:ASC:CDL:v1.01">
          <ColorDecision>
            <ColorCorrection id="day3_ext">
              <SOPNode>
                <Slope>1.10 1.00 0.90</Slope>
                <Offset>0.02 0.00 -0.03</Offset>
                <Power>0.95 1.00 1.15</Power>
              </SOPNode>
              <SatNode><Saturation>0.85</Saturation></SatNode>
            </ColorCorrection>
          </ColorDecision>
        </ColorDecisionList>
        """

    /// Point a controller at scratch folders before it touches any of them. The
    /// defaults are the operator's real Application Support and their real
    /// Resolve LUT directory, and `clearLUTs` would empty the second one.
    private func isolateLookFolders(_ controller: CaptureController,
                                    in directory: URL) {
        controller.lutsDirectory = directory.appendingPathComponent("LUTs")
        controller.resolveLUTDirectory = directory.appendingPathComponent("Resolve")
    }

    private func write(_ text: String, named name: String,
                       in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - import

    /// The whole import flow: the file arrives, appears in the list, is
    /// selected, and is on screen — plus the half a .cube import has no
    /// equivalent of, the parameters kept alongside the lattice.
    @Test func anImportedCDLIsListedSelectedAndApplied() async throws {
        let media = try MediaFixtures.makeDirectory("cdl-import")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            self.isolateLookFolders(controller, in: media)
            let source = try self.write(Self.cdlText, named: "day3_ext.cdl",
                                        in: media)

            controller.adoptLooks(from: [source])

            #expect(controller.availableLUTs.map(\.fileName) == ["day3_ext.cdl"])
            #expect(controller.availableLUTs.map(\.name) == ["day3_ext"])
            #expect(controller.settings.lutFileName == "day3_ext.cdl")
            #expect(controller.lutPreviewOn,
                    "picking a look and not seeing it is not a look")
            #expect(controller.lastError == nil)
            #expect(FileManager.default.fileExists(atPath: controller
                .lutsDirectory.appendingPathComponent("day3_ext.cdl").path))

            let cdl = try #require(controller.currentCDL)
            #expect(cdl.id == "day3_ext")
            #expect(cdl.slope == CDLLook.RGB(1.10, 1.00, 0.90))
            #expect(cdl.offset == CDLLook.RGB(0.02, 0.00, -0.03))
            #expect(cdl.saturation == 0.85)
            #expect(try #require(controller.currentCube).size == CDLLook.cubeSize)
        }
    }

    /// A CDL is not a lattice, and Resolve's LUT folder is scanned for
    /// lattices. Mirroring one there puts a file the colourist cannot select
    /// exactly where they would go looking for the look.
    @Test func aCDLIsNotMirroredIntoResolvesLUTFolder() async throws {
        let media = try MediaFixtures.makeDirectory("cdl-mirror")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            self.isolateLookFolders(controller, in: media)
            let cdl = try self.write(Self.cdlText, named: "look.cdl", in: media)
            let cube = try MediaFixtures.writeRedCube(
                at: media.appendingPathComponent("red.cube"))

            controller.adoptLooks(from: [cdl, cube])

            let mirror = controller.resolveLUTDirectory
            #expect(FileManager.default.fileExists(
                atPath: mirror.appendingPathComponent("red.cube").path),
                "the .cube did not reach Resolve")
            #expect(!FileManager.default.fileExists(
                atPath: mirror.appendingPathComponent("look.cdl").path))
        }
    }

    /// The parameters are what the selects EDL writes as `*ASC_SOP`/`*ASC_SAT`,
    /// so a .cube look has to leave them nil — an identity SOP in their place
    /// would tell the colourist the day was graded flat.
    @Test func aCubeLookCarriesNoCDLParameters() async throws {
        let media = try MediaFixtures.makeDirectory("cdl-none")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            self.isolateLookFolders(controller, in: media)
            controller.adoptLooks(from: [try MediaFixtures.writeRedCube(
                at: media.appendingPathComponent("red.cube"))])

            #expect(controller.currentCube != nil)
            #expect(controller.currentCDL == nil)
            let take = ControllerFixtures.take(named: "A", in: media)
            let edl = try #require(EDLExporter.selectsEDL(
                takes: [take], title: "t", cdl: controller.currentCDL))
            #expect(!edl.contains("ASC_SOP"))
        }
    }

    /// A file that is not a grade fails where the operator can see it. The
    /// parse is the only step of the import that can fail on content rather
    /// than on the disk, and a look that silently stayed at the identity would
    /// put an ungraded picture in front of the director with the look menu
    /// showing the DIT's file name — the one failure mode worse than an error.
    @Test func aFileThatIsNotAGradeFailsVisibly() async throws {
        let media = try MediaFixtures.makeDirectory("cdl-broken")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            self.isolateLookFolders(controller, in: media)
            controller.adoptLooks(from: [try self.write(
                "<ColorCorrectionCollection></ColorCorrectionCollection>",
                named: "empty.ccc", in: media)])

            #expect(controller.lastError?.hasPrefix("LUT:") == true,
                    "a .ccc with no grade in it imported quietly")
            #expect(controller.currentCube == nil)
            #expect(controller.currentCDL == nil)
            #expect(controller.settings.lutFileName == nil,
                    "a look that cannot be read must not stay selected")
        }
    }

    /// Ticking "bake into recording" rebuilds the look. The CDL has to come
    /// back off the cache with its parameters — re-parsing the file on every
    /// checkbox flip is what the cache exists to prevent, and losing the
    /// parameters to the cache would empty the EDL silently.
    @Test func aCheckboxFlipKeepsTheGradeAndItsParameters() async throws {
        let media = try MediaFixtures.makeDirectory("cdl-cache")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            self.isolateLookFolders(controller, in: media)
            controller.adoptLooks(from: [try self.write(Self.cdlText,
                                                        named: "look.cdl",
                                                        in: media)])
            // the file goes away: anything that re-reads disk now fails loudly
            try FileManager.default.removeItem(
                at: controller.lutsDirectory.appendingPathComponent("look.cdl"))

            controller.lutRecordOn = true

            #expect(controller.lastError == nil)
            #expect(controller.settings.lutFileName == "look.cdl")
            #expect(controller.currentCDL?.saturation == 0.85)
            #expect(controller.currentCube != nil)
        }
    }

    // MARK: - the picture

    /// Push a still through the tap and read the middle pixel back.
    private func rendered(_ controller: CaptureController,
                          level: UInt8 = 0x80) -> MediaFixtures.Pixel {
        let collector = MediaFixtures.FrameCollector()
        controller.playbackTap.setOnDisplayFrame { collector.record($0) }
        controller.playbackTap.attachStill(
            MediaFixtures.pixelBuffer(level: level, width: 64, height: 64))
        controller.playbackTap.queue.sync {}
        guard let last = collector.last else { return MediaFixtures.Pixel() }
        return MediaFixtures.sample(last, atFractionX: 0.5)
    }

    /// Select a look built in memory, without a file behind it.
    private func apply(_ look: CDLLook, to controller: CaptureController) {
        controller.cubeCache = .init(fileName: "memory.cdl", cube: look.cube(),
                                     cdl: look)
        controller.settings.lutFileName = "memory.cdl"
        controller.settings.lutPreviewEnabled = true
        controller.rebuildLUT()
    }

    /// A grade with zero slope maps every input to one constant, so the whole
    /// lattice is that constant and the input encoding drops out of the answer.
    /// At 0 and 1 — the two fixed points every transfer function in the render
    /// chain shares — direct math gives an exact expected pixel, no tolerance.
    @Test func aConstantGradeRendersExactlyItsConstant() async throws {
        try await ControllerHarness.run { controller, _ in
            self.apply(CDLLook(slope: .zero, offset: .one), to: controller)
            let white = self.rendered(controller)
            #expect(white == MediaFixtures.Pixel(r: 255, g: 255, b: 255),
                    "offset 1 with zero slope is white: \(white.description)")

            self.apply(CDLLook(slope: .zero, offset: .zero), to: controller)
            let black = self.rendered(controller)
            #expect(black == MediaFixtures.Pixel(r: 0, g: 0, b: 0),
                    "offset 0 with zero slope is black: \(black.description)")
        }
    }

    /// Saturation 0 collapses every pixel to its luma, i.e. to three equal
    /// channels. The render chain applies the same per-channel curve to all
    /// three, so equal in the lattice has to be equal on screen — an exact
    /// consequence of the math that no colour management can disturb.
    @Test func zeroSaturationRendersNeutral() async throws {
        try await ControllerHarness.run { controller, _ in
            self.apply(CDLLook(slope: CDLLook.RGB(1.4, 1.0, 0.6),
                               saturation: 0), to: controller)
            let pixel = self.rendered(controller)
            #expect(pixel.r == pixel.g && pixel.g == pixel.b,
                    "saturation 0 left colour in the frame: \(pixel.description)")
            #expect(pixel.r > 0 && pixel.r < 255)
        }
    }

    /// Per-channel slope, in the picture. A cube filled along the wrong axis
    /// still renders something plausible — what it does not do is put the
    /// channels in the order the numbers demand.
    @Test func perChannelSlopeReachesThePixelsInOrder() async throws {
        try await ControllerHarness.run { controller, _ in
            self.apply(CDLLook(slope: CDLLook.RGB(1.3, 1.0, 0.7)),
                       to: controller)
            let pixel = self.rendered(controller)
            #expect(pixel.r > pixel.g && pixel.g > pixel.b,
                    "the channels came out \(pixel.description)")

            // and the other way round, so the check cannot pass on a fixed bias
            self.apply(CDLLook(slope: CDLLook.RGB(0.7, 1.0, 1.3)),
                       to: controller)
            let flipped = self.rendered(controller)
            #expect(flipped.b > flipped.g && flipped.g > flipped.r,
                    "the channels came out \(flipped.description)")
        }
    }

    /// The same grade by two roads: the CDL rasterized by the app, and a .cube
    /// file generated here from the ASC formula written out independently. Same
    /// source frame, same render path, so the pixels have to agree — this is
    /// what says the generated lattice is indexed and filled the way a .cube
    /// file is, which nothing about a plausible-looking picture would reveal.
    @Test func theCDLRendersWhatAnEquivalentCubeDoes() async throws {
        let media = try MediaFixtures.makeDirectory("cdl-vs-cube")
        defer { try? FileManager.default.removeItem(at: media) }

        try await ControllerHarness.run { controller, _ in
            let look = CDLLook(id: "day3_ext",
                               slope: CDLLook.RGB(1.10, 1.00, 0.90),
                               offset: CDLLook.RGB(0.02, 0.00, -0.03),
                               power: CDLLook.RGB(0.95, 1.00, 1.15),
                               saturation: 0.85)
            self.apply(look, to: controller)
            let viaCDL = self.rendered(controller)

            let url = media.appendingPathComponent("equivalent.cube")
            try Self.cubeText(of: look, size: CDLLook.cubeSize)
                .write(to: url, atomically: true, encoding: .utf8)
            controller.cubeCache = .init(fileName: "equivalent.cube",
                                         cube: try CubeLUT.load(url: url),
                                         cdl: nil)
            controller.settings.lutFileName = "equivalent.cube"
            controller.rebuildLUT()
            let viaCube = self.rendered(controller)

            #expect(viaCDL == viaCube,
                    "CDL \(viaCDL.description) vs cube \(viaCube.description)")
            // and it is not simply the ungraded frame coming back both times
            #expect(viaCDL != MediaFixtures.Pixel(r: 0x80, g: 0x80, b: 0x80))
        }
    }

    /// The ASC formula, written out again rather than reused: a generator that
    /// called the code under test would agree with it about any mistake.
    private static func cubeText(of look: CDLLook, size: Int) -> String {
        var lines = ["LUT_3D_SIZE \(size)"]
        lines.reserveCapacity(size * size * size + 1)
        let step = 1.0 / Double(size - 1)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let out = asc(look, Double(red) * step,
                                  Double(green) * step, Double(blue) * step)
                    lines.append("\(Float(out.r)) \(Float(out.g)) \(Float(out.b))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func asc(_ look: CDLLook, _ red: Double, _ green: Double,
                            _ blue: Double) -> CDLLook.RGB {
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        func sop(_ value: Double, _ slope: Double, _ offset: Double,
                 _ power: Double) -> Double {
            pow(clamp(value * slope + offset), max(0.0001, power))
        }
        let shaped = CDLLook.RGB(
            sop(red, look.slope.r, look.offset.r, look.power.r),
            sop(green, look.slope.g, look.offset.g, look.power.g),
            sop(blue, look.slope.b, look.offset.b, look.power.b))
        let luma = 0.2126 * shaped.r + 0.7152 * shaped.g + 0.0722 * shaped.b
        return CDLLook.RGB(clamp(luma + look.saturation * (shaped.r - luma)),
                           clamp(luma + look.saturation * (shaped.g - luma)),
                           clamp(luma + look.saturation * (shaped.b - luma)))
    }
}
