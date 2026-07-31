import Foundation
import Testing

@testable import CaptureCore

/// The look a DIT hands over, read off disk and turned into something the
/// existing render paths already know how to apply.
///
/// Two halves are checked here and neither is cosmetic: a parser that quietly
/// defaults a missing saturation to zero delivers a greyscale picture to the
/// director's monitor, and a lattice too coarse for the grade's shadow rolloff
/// delivers a different picture from the one the colourist evaluated.
@Suite struct CDLLookTests {
    /// A realistic strong primary: a warm lift, a cool shadow pull, a shoulder
    /// on blue and some saturation taken out. Not the identity, and not a
    /// caricature either — the point is to bound the error of a grade that
    /// could actually come off a cart.
    static let strong = CDLLook(id: "day3_ext",
                                slope: CDLLook.RGB(1.10, 1.00, 0.90),
                                offset: CDLLook.RGB(0.02, 0.00, -0.03),
                                power: CDLLook.RGB(0.95, 1.00, 1.15),
                                saturation: 0.85)

    // MARK: - parsing

    /// A `.cc`: a bare ColorCorrection, no wrapper, no namespace.
    @Test func aBareColorCorrectionParses() throws {
        let look = try CDLLook.looks(in: """
            <?xml version="1.0" encoding="UTF-8"?>
            <ColorCorrection id="shot_014">
              <SOPNode>
                <Slope>1.2 1.0 0.8</Slope>
                <Offset>0.01 0.0 -0.02</Offset>
                <Power>0.9 1.0 1.1</Power>
              </SOPNode>
              <SatNode>
                <Saturation>0.75</Saturation>
              </SatNode>
            </ColorCorrection>
            """)[0]
        #expect(look.id == "shot_014")
        #expect(look.slope == CDLLook.RGB(1.2, 1.0, 0.8))
        #expect(look.offset == CDLLook.RGB(0.01, 0.0, -0.02))
        #expect(look.power == CDLLook.RGB(0.9, 1.0, 1.1))
        #expect(look.saturation == 0.75)
    }

    /// A `.ccc` with the ASC default namespace on the root, which is how every
    /// tool that writes one spells it. Processing namespaces is what keeps the
    /// element names readable here.
    @Test func aCollectionWithADefaultNamespaceParses() throws {
        let looks = try CDLLook.looks(in: """
            <ColorCorrectionCollection xmlns="urn:ASC:CDL:v1.01">
              <ColorCorrection id="a">
                <SOPNode>
                  <Slope>1 1 1</Slope><Offset>0 0 0</Offset><Power>1 1 1</Power>
                </SOPNode>
                <SatNode><Saturation>1.4</Saturation></SatNode>
              </ColorCorrection>
              <ColorCorrection id="b">
                <SOPNode>
                  <Slope>2 2 2</Slope><Offset>0 0 0</Offset><Power>1 1 1</Power>
                </SOPNode>
              </ColorCorrection>
            </ColorCorrectionCollection>
            """)
        #expect(looks.map(\.id) == ["a", "b"])
        #expect(looks[0].saturation == 1.4)
        #expect(looks[1].slope == CDLLook.RGB(2, 2, 2))
    }

    /// A `.cdl`: ColorDecisionList → ColorDecision → ColorCorrection, and this
    /// one carries a PREFIXED namespace, the other way tools write it.
    @Test func aDecisionListWithAPrefixedNamespaceParses() throws {
        let looks = try CDLLook.looks(in: """
            <cdl:ColorDecisionList xmlns:cdl="urn:ASC:CDL:v1.01">
              <cdl:ColorDecision>
                <cdl:ColorCorrection id="cc0001">
                  <cdl:SOPNode>
                    <cdl:Description>hero</cdl:Description>
                    <cdl:Slope>1.05 0.98 1.01</cdl:Slope>
                    <cdl:Offset>0.0 0.0 0.0</cdl:Offset>
                    <cdl:Power>1.0 1.0 1.0</cdl:Power>
                  </cdl:SOPNode>
                  <cdl:SatNode><cdl:Saturation>1.0</cdl:Saturation></cdl:SatNode>
                </cdl:ColorCorrection>
              </cdl:ColorDecision>
            </cdl:ColorDecisionList>
            """)
        #expect(looks.count == 1)
        #expect(looks[0].id == "cc0001")
        #expect(looks[0].slope == CDLLook.RGB(1.05, 0.98, 1.01))
    }

    /// A SatNode is optional in the schema and a missing one means 1 — NOT 0.
    /// Defaulting a missing saturation to zero puts a greyscale image on the
    /// monitor the director is watching, and it looks like a camera fault.
    @Test func aMissingSaturationDefaultsToOne() throws {
        let look = try CDLLook.looks(in: """
            <ColorCorrection>
              <SOPNode>
                <Slope>1 1 1</Slope><Offset>0 0 0</Offset><Power>1 1 1</Power>
              </SOPNode>
            </ColorCorrection>
            """)[0]
        #expect(look.saturation == 1)
        #expect(look.id.isEmpty)
    }

    /// Triples wrapped over several lines are legal XML and appear in the wild.
    @Test func aTripleSplitOverLinesParses() throws {
        let look = try CDLLook.looks(in: """
            <ColorCorrection id="wrapped">
              <SOPNode>
                <Slope>
                  1.1
                  1.2
                  1.3
                </Slope>
              </SOPNode>
            </ColorCorrection>
            """)[0]
        #expect(look.slope == CDLLook.RGB(1.1, 1.2, 1.3))
        // the nodes the file did not mention stay at the identity
        #expect(look.offset == CDLLook.RGB.zero)
        #expect(look.power == CDLLook.RGB.one)
    }

    /// A file with no ColorCorrection at all throws rather than yielding an
    /// identity grade — "the look does nothing" and "there was no look" have to
    /// look different to the operator.
    @Test func aFileWithNoCorrectionThrows() {
        #expect(throws: CDLLook.ParseError.noColorCorrection) {
            try CDLLook.looks(in: "<ColorDecisionList></ColorDecisionList>")
        }
    }

    @Test func junkThrowsRatherThanParsingAsEmpty() {
        #expect(throws: (any Error).self) {
            try CDLLook.looks(in: "this is not xml <<<")
        }
    }

    /// Loading names an anonymous grade after its file, because the LUT list
    /// shows that name and "" is not a look anybody can pick out of a menu.
    @Test func loadingNamesAnAnonymousGradeAfterItsFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("show_look_v4-\(UUID().uuidString).cc")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
            <ColorCorrection>
              <SOPNode><Slope>1 1 1</Slope></SOPNode>
            </ColorCorrection>
            """.write(to: url, atomically: true, encoding: .utf8)
        let look = try CDLLook.load(url: url)
        #expect(look.id == url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - the transfer function

    /// The formula itself, spelled out against hand arithmetic on one channel.
    @Test func theSOPFormulaIsSlopeOffsetPowerThenSaturation() {
        let look = CDLLook(slope: CDLLook.RGB(2, 2, 2),
                           offset: CDLLook.RGB(0.1, 0.1, 0.1),
                           power: CDLLook.RGB(2, 2, 2))
        // (0.25 * 2 + 0.1)^2 = 0.6^2 = 0.36, and saturation 1 leaves it alone
        let out = look.apply(CDLLook.RGB(0.25, 0.25, 0.25))
        #expect(abs(out.r - 0.36) < 1e-9)
        #expect(abs(out.g - 0.36) < 1e-9)
    }

    /// A negative offset takes the input below zero, where a fractional power
    /// is NaN. The clamp before the power is what keeps the shadows black
    /// instead of undefined.
    @Test func aNegativeOffsetClampsInsteadOfProducingNaN() {
        let look = CDLLook(slope: .one, offset: CDLLook.RGB(-0.5, -0.5, -0.5),
                           power: CDLLook.RGB(0.5, 0.5, 0.5))
        let out = look.apply(CDLLook.RGB(0.1, 0.1, 0.1))
        #expect(out.r == 0)
        #expect(!out.r.isNaN && !out.g.isNaN && !out.b.isNaN)
    }

    /// Zero saturation collapses to Rec.709 luma, which is the check that the
    /// weights are the 709 ones and not the 601 set.
    @Test func zeroSaturationCollapsesToRec709Luma() {
        let look = CDLLook(saturation: 0)
        let out = look.apply(CDLLook.RGB(1, 0, 0))
        #expect(abs(out.r - 0.2126) < 1e-9)
        #expect(out.r == out.g && out.g == out.b)
        let green = look.apply(CDLLook.RGB(0, 1, 0))
        #expect(abs(green.g - 0.7152) < 1e-9)
    }

    // MARK: - the cube

    /// What the whole design rests on: the cube the look is rasterized into has
    /// to BE the look, to a tolerance nobody can see.
    ///
    /// The number is measured, not assumed — every cell centre of the lattice
    /// is sampled trilinearly and compared with direct evaluation (see
    /// `CubeSampling`), because the centre of a cell is where interpolation is
    /// furthest from the curve. A grade's curvature piles up in the first cell
    /// above black, so a coarse lattice is wrong exactly where an operator
    /// judges exposure.
    @Test func theCubeMatchesDirectEvaluationWithinOneTenBitCode() {
        let error = CubeSampling.maxError(of: Self.strong, size: CDLLook.cubeSize)
        // 1/1023 — one code value at the 10 bits the capture path works in
        #expect(error < 1.0 / 1023,
                "65³ is off by \(error), which is \(error * 255) 8-bit codes")
    }

    /// The justification for 65 over the usual 33: the same measurement on the
    /// smaller lattice, which misses by more than an 8-bit code value.
    @Test func aThirtyThreeLatticeIsMeasurablyWorse() {
        let coarse = CubeSampling.maxError(of: Self.strong, size: 33)
        let fine = CubeSampling.maxError(of: Self.strong, size: CDLLook.cubeSize)
        #expect(coarse > 1.0 / 255, "33³ error \(coarse) — no case for 65 then")
        #expect(fine < coarse / 2, "65³ \(fine) vs 33³ \(coarse)")
    }

    /// The generated cube is laid out the way a .cube file is — red fastest —
    /// because that is the order CIColorCube reads and the order the app's own
    /// parser produces. Getting it backwards swaps the red and blue axes of
    /// every look, which reads as a broken camera rather than a broken LUT.
    @Test func theCubeIsLaidOutRedFastestLikeADotCubeFile() throws {
        let look = CDLLook(slope: CDLLook.RGB(1, 1, 1))
        let cube = look.cube(size: 2)
        let values = CubeSampling.floats(cube)
        #expect(cube.size == 2)
        #expect(values.count == 8 * 4)
        // entry 1 is (r=1, g=0, b=0): red is the fastest-moving axis
        #expect(values[4] == 1 && values[5] == 0 && values[6] == 0)
        // entry 2 is (r=0, g=1, b=0)
        #expect(values[8] == 0 && values[9] == 1 && values[10] == 0)
        // entry 4 is (r=0, g=0, b=1)
        #expect(values[16] == 0 && values[17] == 0 && values[18] == 1)
    }

    /// The cube carries the look's name so the LUT list can show it.
    @Test func theCubeIsNamedAfterTheGrade() {
        #expect(Self.strong.cube(size: 2).name == "day3_ext")
        #expect(CDLLook().cube(size: 2).name == "CDL")
    }
}
