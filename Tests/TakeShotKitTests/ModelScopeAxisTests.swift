import CaptureCore
import Foundation
import Testing
@testable import TakeShotKit

/// `ScopeAxis` is the one place a number is put next to a scope line, for all
/// four scopes and both scales. Everything here is arithmetic rather than
/// pixels: a graticule that is a few points out is a cosmetic bug, but a
/// graticule whose NUMBER names a different value than the line it sits on is a
/// measuring instrument lying, and the operator has no way to tell.
///
/// The wire range below is the real one — nominal white and black where a
/// 10-bit r210 frame puts them on the 512-row map — because that is the case
/// where the two scales stop agreeing by accident.
struct ModelScopeAxisTests {
    /// Where 940 and 64 land on the trace map: `row(for:)` on a 512-row map.
    private static let wire = ScopeNominalRange(white: 41.0 / 511,
                                                black: 479.0 / 511)

    private func axis(_ nominal: ScopeNominalRange,
                      _ mode: ScopeScaleMode) -> ScopeAxis {
        ScopeAxis(nominal: nominal, mode: mode)
    }

    // MARK: - the vertical ladder

    /// A full-range frame is exactly the geometry the scopes always had: 100 %
    /// on the top row, 0 % on the bottom, nothing shaded.
    @Test func aFullRangeFrameKeepsTheOldLadder() {
        let percent = axis(.full, .percent)
        #expect(percent.unit(ofLevel: 1) == 0)
        #expect(percent.unit(ofLevel: 0) == 1)
        #expect(percent.excursionBands.isEmpty)
        let labels = percent.ticks.map(\.label)
        #expect(labels == ["100", "90", "80", "70", "60", "50", "40", "30",
                           "20", "10", "0"])
        // …and the ladder runs top to bottom, which is what puts each number on
        // its own line rather than in the order the loop happened to build
        #expect(percent.ticks.map(\.unit) == percent.ticks.map(\.unit).sorted())
    }

    /// On a wire frame the percent ladder moves onto the nominal pair and the
    /// map keeps room outside it — the shaded bands.
    @Test func theWireLadderLeavesRoomForTheExcursions() {
        let percent = axis(Self.wire, .percent)
        #expect(abs(percent.unit(ofLevel: 1) - Self.wire.white) < 1e-9)
        #expect(abs(percent.unit(ofLevel: 0) - Self.wire.black) < 1e-9)
        let bands = percent.excursionBands
        #expect(bands.count == 2)
        #expect(bands[0].from == 0)
        #expect(bands[0].to == Self.wire.white)
        #expect(bands[1].from == Self.wire.black)
        #expect(bands[1].to == 1)
    }

    /// Code mode is linear over the WHOLE map, so code 0 is the bottom row and
    /// code 1023 the top whatever the nominal pair does — and the nominal pair
    /// is drawn separately, because neither of its codes is in the label list.
    @Test func theCodeLadderIgnoresTheNominalPair() throws {
        for nominal in [ScopeNominalRange.full, Self.wire] {
            let codes = axis(nominal, .tenBitCode)
            let top = try #require(codes.ticks.first)
            let bottom = try #require(codes.ticks.last)
            #expect(top.label == "1023")
            #expect(top.unit == 0)
            #expect(bottom.label == "0")
            #expect(bottom.unit == 1)
        }
        #expect(axis(.full, .percent).extraNominalUnits.isEmpty)
        #expect(axis(Self.wire, .tenBitCode).extraNominalUnits
            == [Self.wire.white, Self.wire.black])
    }

    // MARK: - the histogram's axis, which is the same one on its side

    /// Percent marks name signal levels, so on a wire frame they sit where the
    /// nominal pair is — 0 % a little in from the left edge, 100 % a little in
    /// from the right, with the excursions outside them.
    @Test func thePercentMarksRideWithTheNominalPair() {
        let marks = axis(Self.wire, .percent).horizontalTicks
        #expect(marks.map(\.label) == ["0", "25", "50", "75", "100"])
        #expect(abs(marks[0].unit - (1 - Self.wire.black)) < 1e-9)
        #expect(abs(marks[4].unit - (1 - Self.wire.white)) < 1e-9)
        #expect(marks[0].unit > 0.02, "0 % is hard against the left edge")
        #expect(marks[4].unit < 0.98, "100 % is hard against the right edge")
        // left to right, and the ends carry the weight
        #expect(marks.map(\.unit) == marks.map(\.unit).sorted())
    }

    /// The bug this file was written for. Code marks name CODES, which do not
    /// move with the levels: placing them by level printed "1023" over the bin
    /// holding code 940 on every wire frame, and "0" over code 64.
    @Test func theCodeMarksDoNotRideWithTheNominalPair() {
        let marks = axis(Self.wire, .tenBitCode).horizontalTicks
        #expect(marks.map(\.label) == ["0", "256", "512", "768", "1023"])
        #expect(marks[0].unit == 0, "code 0 is not the left edge")
        #expect(marks[4].unit == 1, "code 1023 is not the right edge")
        #expect(abs(marks[2].unit - 512.0 / 1023) < 1e-9)
        // the same marks on a full-range frame, because the codes never moved
        let full = axis(.full, .tenBitCode).horizontalTicks
        #expect(full.map(\.unit) == marks.map(\.unit))
        #expect(full.map(\.label) == marks.map(\.label))
    }

    /// The histogram draws its 256 bins at `bin / 255` of the width, so a code
    /// mark has to land on the bin that actually holds that code — bin
    /// `code / 4`. One bin of tolerance, because the bin IS the quantization:
    /// the mark is placed at `code / 1023` and the bin sits at `code / 1020`,
    /// which is a third of a percent of the width apart at worst — under a
    /// point in any box the panel lays out, and the wider of the two errors is
    /// the four codes the bin covers.
    @Test func aCodeMarkLandsOnTheBinThatHoldsThatCode() throws {
        for mark in axis(Self.wire, .tenBitCode).horizontalTicks {
            let code = try #require(Int(mark.label))
            let drawn = Double(min(255, code / 4)) / 255
            #expect(abs(mark.unit - drawn) < 1.0 / 255,
                    "code \(mark.label) marked at \(mark.unit), bin at \(drawn)")
        }
    }

    /// And in code mode the nominal pair still gets a rule of its own, mirrored
    /// onto the horizontal axis rather than left on the vertical one.
    @Test func theNominalPairIsMirroredOntoTheCodeAxis() {
        let codes = axis(Self.wire, .tenBitCode)
        #expect(codes.extraNominalXs == [1 - Self.wire.white,
                                         1 - Self.wire.black])
        #expect(axis(Self.wire, .percent).extraNominalXs.isEmpty)
        // nominal white sits near — but not at — the top of the code scale:
        // code 940 of 1023
        #expect(abs(codes.extraNominalXs[0] - 940.0 / 1023) < 0.005)
        #expect(abs(codes.extraNominalXs[1] - 64.0 / 1023) < 0.005)
    }

    /// The scale-mode setting string is the one the toolbar picker writes, and
    /// anything else is the percent scale rather than a crash.
    @Test func theScaleModeComesFromTheToolbarSetting() {
        #expect(ScopeScaleMode(setting: "100") == .percent)
        #expect(ScopeScaleMode(setting: "1023") == .tenBitCode)
        #expect(ScopeScaleMode(setting: "nonsense") == .percent)
    }
}
