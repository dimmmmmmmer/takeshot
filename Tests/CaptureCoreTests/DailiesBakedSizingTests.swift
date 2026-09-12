import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// **A daily does not stretch a take that is already stretched.**
///
/// The transcode has always refused a second GRADE: a take recorded with the
/// look burned in names it, and a proxy graded a second time is permanently
/// wrong in the file an editor cuts with. The reframe bake gave the same
/// question a second shape — a take can now carry the anamorphic desqueeze in
/// its own pixels (`ViewAssist.sizingRecord`) — and an anamorphic unit that
/// ticked both checkboxes would have shipped doubly-stretched proxies.
///
/// It is the worst shape a defect can have here: the app's own player shows
/// such a take correctly, because the file says what was done to it, so
/// nobody on set ever sees it. Only the cutting room does.
@Suite struct DailiesBakedSizingTests {
    private func probe(_ url: URL, desqueeze: Double) async throws
        -> DailiesSourceFacts {
        try await DailiesSourceFacts.probe(item: DailiesRig.item(for: url),
                                           burnins: DailiesRig.noBurnins,
                                           desqueeze: desqueeze)
    }

    /// A source with the reframe baked in takes the run's desqueeze NOWHERE,
    /// and one without it takes it exactly as it always did.
    @Test func aTakeWhoseFramingIsBakedInIsNotStretchedAgain() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("plain.mov"), frames: 4)
        let baked = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("baked.mov"), frames: 4,
            metadata: [TakeWriter.sizingKey: "width=2.000"])

        // 320x180 stretched 2x is 640x180, fitted under the 1080 ceiling
        let stretched = try await probe(plain, desqueeze: 2).outputSize
        #expect(stretched.width == 640 && stretched.height == 180,
                "the run's desqueeze does nothing at all: \(stretched)")

        let asShot = try await probe(baked, desqueeze: 2).outputSize
        #expect(asShot.width == 320 && asShot.height == 180,
                "a take that carries its own stretch was stretched again: \(asShot)")

        // …and the refusal is about the TAG, not about the number: the same
        // baked file with no desqueeze asked for comes out the same way.
        let untouched = try await probe(baked, desqueeze: 1).outputSize
        #expect(untouched == asShot)
    }

    /// The tag a recorded take actually writes is the one this reads. A
    /// refusal keyed to a string nothing produces is a refusal that never
    /// happens, and the value is built field by field
    /// (`TakeWriter.sizingValue`) rather than being a bare flag.
    @Test func theTagThisRefusesOnIsTheOneATakeWrites() async throws {
        var sizing = PictureSizing()
        sizing.width = 2
        let written = TakeWriter.sizingValue(sizing)
        #expect(written == "width=2.000", "a take writes \(written)")

        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let baked = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("tagged.mov"), frames: 4,
            metadata: [TakeWriter.sizingKey: written])
        let metadata = (try? await AVURLAsset(url: baked).load(.metadata)) ?? []
        #expect(await TakeWriter.bakedSizing(metadata) == written,
                "the key did not survive the writer")
    }
}
