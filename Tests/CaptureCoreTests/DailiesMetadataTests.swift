import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// **What a proxy says about itself**, as opposed to what it looks like.
///
/// Split out of `DailiesToneMapTests` when that suite reached its length
/// ceiling: the tone map is about the pixels and these are about the file's own
/// claims — the take's identity, and the two keys that must NOT travel because
/// they would be untrue of a proxy.
@Suite struct DailiesMetadataTests {
    /// **The proxy carries the take's identity, and not its origin.**
    ///
    /// Nothing at all used to travel: the writer's metadata was never
    /// assigned, so the roll, the clip, the scene/shot/take and both
    /// description atoms were lost in every daily this app has made (owner:
    /// "ну и конечно важно чтоб мета вся возможная из исходника
    /// сохранялась").
    ///
    /// The absences are half the test and the more important half. A proxy
    /// carrying `com.takeshot.origin` is adopted by the library scan as one of
    /// the day's TAKES; one carrying `com.takeshot.levels` is expanded a
    /// second time by every player, which is exactly the double expansion that
    /// key exists to prevent. Both would arrive by a plain copy, which is what
    /// makes this fail the moment somebody simplifies the filter away.
    @Test func theProxyCarriesTheTakesIdentityAndNotItsOrigin() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("meta.mov"), frames: 6,
            wireCodes: true,
            slate: SlateMetadata(scene: "12A", shot: 3, take: 4),
            metadata: [TakeWriter.rollKey: "A007",
                       TakeWriter.clipKey: "0012"])
        // ProRes, because the container decides how much of this can arrive:
        // a `.mov` keeps every item, and the `.mp4` an H.264 daily is written
        // into has no QuickTime metadata atom at all — there the take's
        // identity survives as the description sentence and nothing else.
        // Both are measured in `theProxysMetadataFollowsItsContainer`.
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy)
        let daily: URL = try #require(report.items.first?.output,
                                      "the take produced no daily")

        let carried: [AVMetadataItem] =
            (try? await AVURLAsset(url: daily).load(.metadata)) ?? []
        func value(_ key: String) -> String? {
            carried.first { ($0.key as? String) == key }?.stringValue
        }
        #expect(value(TakeWriter.rollKey) == "A007",
                "the reel did not reach the proxy")
        #expect(value(TakeWriter.clipKey) == "0012")
        #expect(value(TakeWriter.sceneKey) == "12A")
        #expect(value(TakeWriter.takeKey) == "4")
        #expect(value(TakeWriter.markerKey) == nil, """
            the proxy claims to be one of this app's takes — the library scan \
            adopts it and offers it for review, export and another daily
            """)
        #expect(value(TakeWriter.levelsKey) == nil, """
            the proxy says its codes are studio swing, which they are not any \
            more — every player would expand them a second time
            """)
    }

    /// **What an `.mp4` daily can carry**, which is not what a `.mov` one can.
    ///
    /// The QuickTime metadata key space does not exist in an MPEG-4 file, so
    /// every reverse-DNS key is dropped by the writer whatever is handed to
    /// it. What survives is the description — the scene, shot and take as a
    /// sentence — mapped to ISO user data. Written down as a measurement
    /// because the alternative is a filter in this app guessing at the same
    /// rule and getting it differently.
    @Test func theProxysMetadataFollowsItsContainer() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("container.mov"), frames: 6,
            slate: SlateMetadata(scene: "12A", shot: 3, take: 4),
            metadata: [TakeWriter.rollKey: "A007"])
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"), codec: .h264)
        let daily: URL = try #require(report.items.first?.output,
                                      "the take produced no daily")
        let carried: [AVMetadataItem] =
            (try? await AVURLAsset(url: daily).load(.metadata)) ?? []
        #expect(carried.contains {
            $0.stringValue?.contains("12A") == true
        }, """
            the mp4 daily carries \(carried.count) items and none of them names \
            the take — the description did not survive either
            """)
        // …and the run produced a playable file rather than refusing the items
        // it cannot store.
        #expect(report.items.first?.failure == nil)
    }
}
