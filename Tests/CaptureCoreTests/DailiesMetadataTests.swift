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
        // ProRes here and H.264 in `theEveryCodecDailyCarriesTheTakesKeys`,
        // which is the same assertion for the codec that used to lose it: the
        // container decided how much of this could arrive, and every daily is
        // a `.mov` now.
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
        // **200, not 250, and the number is a measurement.** The claim is that
        // the strips are not the look's red — white against red is 245-255 in
        // every channel and the graded alternative is ~0 in two of them, so
        // the margin is enormous either way. The tight version was red on CI
        // and green here: this machine's encoder returned 255 and the macOS 15
        // runner's returned B246 G245 R255 for the same white text, which is
        // chroma rounding at the edge of a one-pixel glyph and a fact about
        // that encoder rather than about the picture. CLAUDE.md says it
        // plainly for the codec family next door — measure it on the OS it
        // will ship to.
        #expect(strips.green >= 200 && strips.blue >= 200, """
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

    /// **A baked desqueeze changes the proxy's own raster** (owner: "и думаю
    /// еще можно настройку сделать чтоб десквиз запекать").
    ///
    /// Width times the factor, height untouched — the one convention the whole
    /// app uses for a desqueeze. Folded into the output size rather than added
    /// as a stage, which is what makes the burn-ins come out right for free:
    /// the overlay is laid out against the raster, so on a desqueezed proxy it
    /// is laid out against the desqueezed one and the strips are never
    /// stretched with the picture.
    @Test func aBakedDesqueezeWidensTheProxyAndNotItsStrips() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("squeezed.mov"),
            width: 320, height: 180, frames: 6)
        let item = DailiesRig.item(for: source)

        let clean = await DailiesEngine.run(
            items: [item], burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Clean"), codec: .proResProxy)
        let baked = await DailiesEngine.run(
            items: [item], burnins: DailiesRig.allBurnins,
            into: root.appendingPathComponent("Baked"), codec: .proResProxy,
            desqueeze: 2)

        let cleanSize = try await Self.raster(of: try #require(
            clean.items.first?.output, "the clean run produced no daily"))
        let bakedSize = try await Self.raster(of: try #require(
            baked.items.first?.output, "the baked run produced no daily"))
        #expect(cleanSize == CGSize(width: 320, height: 180),
                "the untouched proxy is \(cleanSize), not the source's raster")
        #expect(bakedSize == CGSize(width: 640, height: 180), """
            the desqueezed proxy is \(bakedSize) — a 2x squeeze doubles the \
            width and leaves the height alone
            """)

        // …and the strips were laid out on THAT raster: the overlay's own
        // metrics are a fraction of the height, so a strip drawn against the
        // source's shape and then stretched would be the give-away.
        let overlay = DailiesOverlay(
            size: bakedSize,
            texts: DailiesRig.allBurnins.overlayTexts(for: item))
        let strip: CGRect = try #require(overlay.layout.timecode)
        let frame = try await DailiesRig.decodeFrame(0, of: try #require(
            baked.items.first?.output))
        #expect(DailiesRig.peakLevel(frame, in: strip) >= 200, """
            nothing bright is where the strips should be on a \(bakedSize) \
            picture — they were laid out against another raster
            """)
    }

    /// The raster a finished file actually has.
    private static func raster(of url: URL) async throws -> CGSize {
        let track = try #require(
            try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
                .first)
        let size = try await track.load(.naturalSize)
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
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

    /// **An H.264 daily carries the take's own keys**, because it is a `.mov`
    /// like every other daily now (owner: "давай и не рендерить в мп4. только
    /// в мовы все").
    ///
    /// This test used to measure the opposite and was right to: the QuickTime
    /// metadata key space does not exist in an MPEG-4 file, so every
    /// reverse-DNS key was dropped by the writer whatever was handed to it,
    /// and the take's identity survived as the description sentence alone.
    /// That is what the container change was made to stop, and this is the
    /// assertion that says it stopped — the same run, the same codec, the keys
    /// now present.
    @Test func theEveryCodecDailyCarriesTheTakesKeys() async throws {
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
        #expect(daily.pathExtension == "mov", """
            an H.264 daily came out as .\(daily.pathExtension) — the container \
            is what this test is about
            """)
        let carried: [String: String] = await Self.values(of: daily)
        #expect(carried[TakeWriter.rollKey] == "A007", """
            the H.264 daily carries \(carried.count) items and not the reel — \
            the keys are the reason every daily is a QuickTime file
            """)
        #expect(carried.values.contains { $0.contains("12A") }, """
            nothing in the H.264 daily names the take
            """)
        // …and the run produced a playable file rather than refusing the items
        // it cannot store.
        #expect(report.items.first?.failure == nil)
    }
}
