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

        // Loaded, not read: `AVMetadataItem.stringValue` is deprecated from
        // macOS 13 and the runner's SDK says so — a warning there is a failed
        // build, and this machine's SDK does not raise it. (docs/ARCHITECTURE:
        // the runner is a second compiler AND an older SDK; a local battery
        // cannot see either.)
        let carried: [String: String] = await Self.values(of: daily)
        func value(_ key: String) -> String? { carried[key] }
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

    /// **A look reaches the proxy's pixels, and the burn-ins survive it**
    /// (owner: "о в дейликах хочу еще возможность чтоб лут в них запекался").
    ///
    /// The cube turns every code pure red, which makes both halves of the
    /// claim readable at once: the picture goes red, and the strips do NOT.
    /// A look applied after the overlay would take the plates and their white
    /// with it, which is the same ordering trap the tone map has and the same
    /// answer — a grade is the PICTURE's.
    @Test func aBakedLookReachesTheProxyAndTheBurnInsSurviveIt() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let raster = CGSize(width: 320, height: 180)
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("look.mov"),
            width: Int(raster.width), height: Int(raster.height),
            frames: 6, level: 128)
        let fixture = DailiesRig.item(for: source)
        let look = DailiesLook(cube: try CubeLUT.parse(Self.redCube),
                               name: "Show LUT")
        let report = await DailiesEngine.run(
            items: [fixture], burnins: DailiesRig.allBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy, look: look)
        let daily: URL = try #require(report.items.first?.output,
                                      "the take produced no daily")
        let frame = try await DailiesRig.decodeFrame(0, of: daily)

        // BGRA: the picture is red, so blue and green are on the floor and
        // red is at the ceiling.
        let centre = DailiesRig.centerRegion(of: raster)
        let channels = Self.channelMeans(frame, in: centre)
        #expect(channels.red > 200, """
            the look never reached the picture — red is \(channels.red) where \
            a fully red grade puts it
            """)
        #expect(channels.green < 40 && channels.blue < 40,
                "the picture is \(channels), which is not the look's red")

        // …and the strips kept their own white rather than being graded too.
        let overlay = DailiesOverlay(
            size: raster,
            texts: DailiesRig.allBurnins.overlayTexts(for: fixture))
        let strip: CGRect = try #require(overlay.layout.timecode)
        // Per CHANNEL, and that is the whole point: this cube maps every code
        // to pure red, so a strip that had been graded with the picture would
        // still peak at 255 — in red. White is white only if green and blue
        // are there too. (Seen: the first version of this asserted the peak
        // over all channels and passed with the look moved after the
        // overlay.)
        let strips = Self.channelPeaks(frame, in: strip)
        #expect(strips.green >= 250 && strips.blue >= 250, """
            the burn-in came out \(strips) — the grade took the strips with \
            the picture
            """)

        // …and the file SAYS which look is in its pixels, or the player would
        // grade it a second time.
        let carried: [AVMetadataItem] =
            (try? await AVURLAsset(url: daily).load(.metadata)) ?? []
        #expect(await TakeWriter.bakedLookName(carried) == "Show LUT",
                "the proxy does not say the look is already in it")
    }

    /// **A take that already carries its look is not graded again.**
    ///
    /// The take was recorded with the look burned in and says so; a second
    /// pass would put two grades in one file, permanently, in the proxy an
    /// editor cuts with. The same rule `PlaybackLook.baked` states for the
    /// player, asked through the same predicate.
    @Test func aTakeThatAlreadyCarriesItsLookIsNotGradedTwice() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let raster = CGSize(width: 320, height: 180)
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("already.mov"),
            width: Int(raster.width), height: Int(raster.height),
            frames: 6, level: 128,
            metadata: [TakeWriter.lutKey: "Show LUT"])
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy,
            look: DailiesLook(cube: try CubeLUT.parse(Self.redCube),
                              name: "Another LUT"))
        let daily: URL = try #require(report.items.first?.output)
        let frame = try await DailiesRig.decodeFrame(0, of: daily)
        let channels = Self.channelMeans(
            frame, in: DailiesRig.centerRegion(of: raster))
        #expect(channels.red < 200 && channels.green > 80, """
            the take was graded a second time: \(channels) is the cube's red, \
            not the grey the file was written at
            """)
    }

    /// Every metadata item a file carries, by key, with its value LOADED.
    ///
    /// `stringValue` is deprecated from macOS 13 and the CI SDK says so —
    /// where a warning fails the build and this machine raises none.
    private static func values(of url: URL) async -> [String: String] {
        let items = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        var found: [String: String] = [:]
        for item in items {
            // Keyed by the item's KEY when it has one and by its identifier
            // otherwise: an `.mp4` keeps its description as ISO user data,
            // which comes back identified (`uiso/dscp`) and with no key at
            // all, so a map built on the key alone would report that file as
            // carrying nothing.
            //
            // One binding for the value: `try?` over a `String?` flattens, so
            // the optional the loader returns and the one a failure would add
            // are the same one.
            let key = (item.key as? String) ?? item.identifier?.rawValue
            guard let key,
                  let value = try? await item.load(.stringValue)
            else { continue }
            found[key] = value
        }
        return found
    }

    /// Every code to pure red — a look whose effect is unmistakable in one
    /// channel comparison, and the same shape `LUTBakeLatchTests` uses.
    private static let redCube = """
        LUT_3D_SIZE 2
        \(Array(repeating: "1.0 0.0 0.0", count: 8).joined(separator: "\n"))
        """

    /// One reading of a BGRA region, per channel — a named value rather than
    /// a bare triple, which is the house rule and the linter's: three numbers
    /// in a row is how a blue ends up compared against a red.
    struct Channels: CustomStringConvertible {
        var blue: Double
        var green: Double
        var red: Double

        var description: String {
            "B\(Int(blue)) G\(Int(green)) R\(Int(red))"
        }
    }

    /// The brightest value each channel reaches inside a region.
    private static func channelPeaks(_ buffer: CVPixelBuffer, in rect: CGRect)
        -> Channels {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Channels(blue: 0, green: 0, red: 0)
        }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var peaks = [0, 0, 0]
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for channel in 0..<3 {
                    peaks[channel] = max(peaks[channel],
                                         Int(bytes[y * row + x * 4 + channel]))
                }
            }
        }
        return Channels(blue: Double(peaks[0]), green: Double(peaks[1]),
                        red: Double(peaks[2]))
    }

    /// The three channels' means over a region, as a BGRA buffer holds them.
    private static func channelMeans(_ buffer: CVPixelBuffer, in rect: CGRect)
        -> Channels {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Channels(blue: 0, green: 0, red: 0)
        }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var totals = [0.0, 0.0, 0.0]
        var counted = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for channel in 0..<3 {
                    totals[channel] += Double(bytes[y * row + x * 4 + channel])
                }
                counted += 1
            }
        }
        guard counted > 0 else { return Channels(blue: 0, green: 0, red: 0) }
        return Channels(blue: totals[0] / counted, green: totals[1] / counted,
                        red: totals[2] / counted)
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
        let carried: [String: String] = await Self.values(of: daily)
        #expect(carried.values.contains { $0.contains("12A") }, """
            the mp4 daily carries \(carried.count) items and none of them \
            names the take — the description did not survive either
            """)
        // …and the run produced a playable file rather than refusing the items
        // it cannot store.
        #expect(report.items.first?.failure == nil)
    }
}
