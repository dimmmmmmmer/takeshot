import Foundation
import Testing

@testable import CaptureCore

/// Guards the exposure palettes now that the false-color bands are a table
/// instead of a nine-case switch, and the three color cubes are built by one
/// shared lattice walk. Every boundary below is a color the operator reads
/// exposure off: a table can get one wrong silently, where the switch it
/// replaced could not compile with a band missing.
struct CorePaletteTests {
    private func band(_ v: Double) -> [Double] {
        let color = AssistFilters.band(v)
        return [color.red, color.green, color.blue]
    }

    @Test func falseColorWarningBandsSitOnTheirBoundaries() {
        #expect(band(0) == [0.58, 0.20, 0.75])       // purple — crushed
        #expect(band(0.024) == [0.58, 0.20, 0.75])
        #expect(band(0.025) == [0.16, 0.34, 0.90])   // blue — deep shadow
        #expect(band(0.079) == [0.16, 0.34, 0.90])
        #expect(band(0.36) == [0.15, 0.75, 0.25])    // green — 18% gray
        #expect(band(0.439) == [0.15, 0.75, 0.25])
        #expect(band(0.52) == [0.95, 0.60, 0.70])    // pink — skin highlight
        #expect(band(0.92) == [0.98, 0.90, 0.20])    // yellow — near clip
        #expect(band(0.97) == [0.95, 0.15, 0.10])    // red — clipped
        #expect(band(1) == [0.95, 0.15, 0.10])
    }

    /// The gaps between the warning bands are not colors — the value passes
    /// through as gray, which is what makes the warnings readable at all.
    @Test func falseColorGrayRampPassesTheValueThrough() {
        for v in [0.08, 0.2, 0.359, 0.44, 0.5, 0.519, 0.58, 0.7, 0.919] {
            #expect(band(v) == [v, v, v])
        }
    }

    @Test func elZoneClampsBothOpenEndsOntoTheRamp() {
        #expect(AssistFilters.zoneColor(-99).red == 0.04) // ≤ -6: black
        #expect(AssistFilters.zoneColor(-6).red == 0.04)
        #expect(AssistFilters.zoneColor(0).red == 0.50)   // 18% — mid gray
        #expect(AssistFilters.zoneColor(6).red == 1)      // ≥ +6: white
        #expect(AssistFilters.zoneColor(99).red == 1)
    }

    /// The inverse BT.709 OETF, with its linear segment below the knee: 18%
    /// scene linear encodes to ~0.409 display, which is what puts 18% gray on
    /// the zone-0 entry above.
    @Test func bt709LinearInvertsTheTransferFunction() {
        #expect(AssistFilters.bt709Linear(0.045) == 0.045 / 4.5)
        #expect(abs(AssistFilters.bt709Linear(0.409) - 0.18) < 0.001)
        #expect(abs(AssistFilters.bt709Linear(1) - 1) < 1e-9)
    }

    /// The shared cube builder: shape (64³ RGBA floats) and the first lattice
    /// point, which is black and must therefore come out crushed-purple.
    @Test func falseColorCubeIsAFullLatticeStartingAtTheCrushedBand() {
        let cube = AssistFilters.falseColorCube
        #expect(cube.count == 64 * 64 * 64 * 4 * 4)
        let first = cube.withUnsafeBytes { raw in
            (0..<3).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        #expect(first == [0.58, 0.20, 0.75].map(Float.init))
    }

    @Test func elZoneCubeIsAFullLattice() {
        #expect(AssistFilters.elZoneCube.count == 64 * 64 * 64 * 4 * 4)
    }
}
