import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The multicam preview grid's layout.
///
/// The rule under test is the column count: one camera fills the width, two to
/// four go two across, five and up go three. It matters on set because the grid
/// is the whole player area — six cameras in one row would give each of them a
/// strip too small to judge focus in, and one camera in a third of the width
/// wastes the monitor the operator is standing in front of.
///
/// Measured as sizes, which is the portable half of the render harness (see the
/// note in `ViewRenderSupport`): the tiles are 16:9 by construction, so the
/// grid's own height is a direct read-out of how many columns and rows it chose.
/// No ink is sampled and no AppKit control is involved.
@Suite @MainActor struct ViewMulticamGridTests {
    private static let width: CGFloat = 800

    /// Extra cameras that need no hardware: a stub backend produces no signal,
    /// and the grid only asks each channel for a pipeline, a label and a state.
    /// `MockCaptureBackend` is deliberately not used — it is the one that draws
    /// with AppKit on its own queue.
    private func addChannels(_ count: Int, to controller: CaptureController) {
        var channels: [CameraChannel] = []
        for index in 0..<count {
            let backend = StubCaptureBackend()
            backend.deviceList = [CaptureDeviceInfo(id: "stub-\(index)",
                                                    name: "Stub \(index)")]
            channels.append(CameraChannel(
                camLabel: String(UnicodeScalar(UInt8(66 + index))),
                backend: backend, deviceID: "stub-\(index)",
                settings: controller.settings, roll: "001"))
        }
        controller.extraChannels = channels
    }

    /// The grid's settled height at the fixed test width, with `extras` cameras
    /// beside the main one.
    private func height(extras: Int, _ probe: ViewProbe) -> CGFloat {
        addChannels(extras, to: probe.controller)
        defer {
            for channel in probe.controller.extraChannels { channel.stopStreams() }
            probe.controller.extraChannels = []
        }
        return probe.size(MulticamGrid(), proposedWidth: Self.width).height
    }

    /// One camera is one column: the tile is the full width, so the grid is as
    /// tall as a 16:9 picture that wide.
    @Test func oneCameraFillsTheWidth() async throws {
        try await ViewProbe.run { probe in
            let height = self.height(extras: 0, probe)
            let full = Self.width * 9 / 16
            #expect(abs(height - full) < 20,
                    "a single camera laid out \(height)pt tall, expected ~\(full)pt")
        }
    }

    /// Two cameras share a row, so the grid is about half as tall as one camera
    /// on its own — and emphatically not taller, which is what stacking them
    /// would give.
    @Test func twoCamerasShareOneRow() async throws {
        try await ViewProbe.run { probe in
            let one = self.height(extras: 0, probe)
            let two = self.height(extras: 1, probe)
            #expect(two < one,
                    "two cameras (\(two)pt) were stacked rather than paired")
            #expect(abs(two - one / 2) < 20,
                    "two cameras laid out \(two)pt tall, expected ~\(one / 2)pt")
        }
    }

    /// Three and four cameras stay at two columns, which means two rows — back to
    /// about the height of a single full-width camera.
    @Test func threeAndFourCamerasFillTwoRowsOfTwo() async throws {
        try await ViewProbe.run { probe in
            let two = self.height(extras: 1, probe)
            let three = self.height(extras: 2, probe)
            let four = self.height(extras: 3, probe)
            #expect(abs(three - two * 2) < 20,
                    "three cameras laid out \(three)pt tall, expected ~\(two * 2)pt")
            #expect(abs(four - three) < 1,
                    "the fourth camera changed the layout: \(three)pt → \(four)pt")
        }
    }

    /// The fifth camera moves the grid to three columns, and the give-away is
    /// that the grid gets SHORTER while gaining a camera: five tiles across three
    /// columns is two rows of smaller tiles, where two columns would have needed
    /// three rows.
    @Test func theFifthCameraMovesToThreeColumns() async throws {
        try await ViewProbe.run { probe in
            let four = self.height(extras: 3, probe)
            let five = self.height(extras: 4, probe)
            let six = self.height(extras: 5, probe)
            #expect(five < four,
                    "the fifth camera did not widen the grid: 4 → \(four)pt, 5 → \(five)pt")
            #expect(abs(six - five) < 1,
                    "the sixth camera changed the row count: \(five)pt → \(six)pt")
        }
    }

    /// Past six the grid grows downwards rather than sideways — three columns is
    /// the ceiling, so a seventh camera starts a third row.
    @Test func pastSixTheGridGrowsInRowsNotColumns() async throws {
        try await ViewProbe.run { probe in
            let six = self.height(extras: 5, probe)
            let seven = self.height(extras: 6, probe)
            #expect(seven > six,
                    "a seventh camera did not start a row: 6 → \(six)pt, 7 → \(seven)pt")
            #expect(abs(seven - six * 3 / 2) < 20,
                    "seven cameras laid out \(seven)pt tall for three rows")
        }
    }

    /// The grid mounts and holds a preview surface per camera without the layout
    /// stretching to something else: whatever the host is given, that is the
    /// frame it keeps. The mount is what a shared `CALayer` would break (see the
    /// preview display rule), and a host released before the assertion takes the
    /// mounts with it — hence `mounted`.
    @Test func theGridMountsWithoutStretchingItsHost() async throws {
        try await ViewProbe.run { probe in
            self.addChannels(2, to: probe.controller)
            defer {
                for channel in probe.controller.extraChannels {
                    channel.stopStreams()
                }
                probe.controller.extraChannels = []
            }
            let exact = CGSize(width: 960, height: 540)
            await probe.mounted(MulticamGrid(), in: exact) {
                #expect(ViewRender.laidOutSize(
                    probe.hosted(MulticamGrid()), in: exact) == exact)
            }
        }
    }
}
