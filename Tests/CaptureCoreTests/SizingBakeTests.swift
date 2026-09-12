import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The reframe asked INTO the file: `ViewAssist.sizingRecord` (owner: "и то и
/// другое, отдельной галкой").
///
/// `SizingReachTests` next door holds the default — a reframe is a view, it
/// reaches every surface that mirrors the viewer, and no deliverable carries
/// it. This suite holds the exception, and it is the same set of questions
/// `ChromaKeyBakeTests` asks one bake along, deliberately in the same order so
/// that a change which breaks one reads as breaking the other:
///
///   1. the reframe really is in the file;
///   2. the file SAYS so, and stops claiming to carry the camera's wire codes;
///   3. the take latches what it opened with, both ways;
///   4. the still grab follows the deliverable rather than the camera;
///   5. the measurement path still sees the camera, which is what keeps a
///      reframed take worth exposing by.
struct SizingBakeTests {
    private func recordingPipeline(root: URL, levels: String = "full",
                                   width: Int = 320,
                                   height: Int = 180) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.destinationPath = root.path
        settings.capture.detectionMode = .manual
        settings.capture.videoLevels = levels
        settings.capture.preRollFrames = 0
        settings.capture.codec = .proResProxy
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(width: width, height: height,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "1080p25"))
        return pipeline
    }

    /// A horizontal flip with the bake armed — the one difference from the
    /// assist every test next door uses, spelled out so each test below reads
    /// as "the same reframe, recorded".
    private static func bakedFlip() -> ViewAssist {
        var assist = ViewAssist()
        assist.flipH = true
        assist.sizingRecord = true
        return assist
    }

    /// Record one take of `source`. `midTake` runs after the first half of the
    /// frames, which is where every latch question in this suite lives.
    private func record(_ pipeline: CapturePipeline, _ source: CVPixelBuffer,
                        frames: Int = 12,
                        midTake: (() -> Void)? = nil) async throws -> Take {
        let takes = TakeCollector()
        pipeline.onTakeFinished = { takes.append($0) }
        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                                fps: 25)
        // Frames BEFORE the take opens, for `ChromaKeyBakeTests.record`'s
        // reason: the levels stage learns what the wire carries from a frame
        // that has been through it, and this suite asks what the file says.
        for _ in 0..<3 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: source)
        }
        pipeline.toggleManualRecord()
        for index in 0..<frames {
            if index == frames / 2 { midTake?() }
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: source)
        }
        pipeline.toggleManualRecord()
        await TestWait.untilWritten { takes.first != nil }
        let take = try #require(takes.first, "no take was finished")
        await TestWait.fileExists(at: take.url)
        return take
    }

    private func source() -> CVPixelBuffer {
        SizingProbe.sided(width: 320, height: 180)
    }

    // MARK: - the default

    /// The bake is off in a fresh assist, which is what makes the reach suite
    /// beside this one prove anything: every test there records with a plain
    /// `ViewAssist`, and if that carried a bake they would all be asserting
    /// the opposite of what they say.
    @Test func theBakeIsOffUntilItIsAskedFor() {
        #expect(!ViewAssist().sizingRecord)
        #expect(Self.bakedFlip().sizingRecord, "this suite's fixture bakes nothing")
    }

    // MARK: - the picture

    /// The take IS the reframe: the bright half has changed ends in the file.
    @Test func aTakeRecordedWithTheBakeOnCarriesTheReframe() async throws {
        let root = TestMedia.scratchDirectory("SizingBakeTake")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setViewAssist(Self.bakedFlip())

        let take = try await record(pipeline, source())
        let frame = try #require(await ChromaProbe.firstFrame(of: take.url),
                                 "the take decoded no frames")
        let left = ChromaProbe.pixel(of: frame, atFractionX: 0.1)
        let right = ChromaProbe.pixel(of: frame, atFractionX: 0.9)
        #expect(left.g > 150, "the reframe never reached the take: \(left)")
        #expect(right.g < 100, "the reframe never reached the take: \(right)")
    }

    /// **An identity reframe is never baked, however armed the checkbox is.**
    ///
    /// A resample that would change no pixel must not cost a take its wire
    /// codes. The sequence is the one an operator actually produces: a flip,
    /// the bake armed over it, and then the framing reset without unchecking
    /// the box — which leaves the capture side armed and holding nothing to
    /// apply. Arming over an already-neutral geometry would prove less, since
    /// the value never reaches the capture queue at all.
    @Test func anIdentityReframeIsNeverBaked() async throws {
        let root = TestMedia.scratchDirectory("SizingBakeIdentity")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root, levels: "limited")
        pipeline.setViewAssist(Self.bakedFlip())
        var armed = ViewAssist()
        armed.sizingRecord = true              // …and the flip taken back off
        pipeline.setViewAssist(armed)

        let take = try await record(pipeline, try ChromaKeyBakeTests.wireFrame())
        let tag: String? = await ChromaKeyBakeTests.tag(TakeWriter.sizingKey,
                                                        of: take.url)
        let levels: String? = await ChromaKeyBakeTests.tag(TakeWriter.levelsKey,
                                                           of: take.url)
        #expect(tag == nil, "a take with nothing to bake claimed a reframe")
        #expect(levels == TakeWriter.wireValue,
                "an armed checkbox alone cost the take its wire codes")
    }

    // MARK: - what the file says about itself

    /// A reframed take names what was done to its framing and stops claiming
    /// to carry the camera's wire codes, because it does not — it carries
    /// display values, exactly as a LUT-baked or keyed take does.
    ///
    /// Both takes are recorded here, off a 10-bit RGB wire with the levels
    /// stage active: asserting the absence of a key on its own would pass
    /// against a pipeline that never wrote it at all.
    @Test func aBakedTakeSaysSoAndStopsClaimingWireCodes() async throws {
        let root = TestMedia.scratchDirectory("SizingBakeTags")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root, levels: "limited")
        let wire = try ChromaKeyBakeTests.wireFrame()

        let clean = try await record(pipeline, wire)
        pipeline.setViewAssist(Self.bakedFlip())
        let baked = try await record(pipeline, wire)

        let cleanLevels: String? = await ChromaKeyBakeTests.tag(
            TakeWriter.levelsKey, of: clean.url)
        let cleanTag: String? = await ChromaKeyBakeTests.tag(
            TakeWriter.sizingKey, of: clean.url)
        #expect(cleanLevels == TakeWriter.wireValue,
                "the clean take is not a wire-code take, so this proves nothing")
        #expect(cleanTag == nil, "a clean take claimed to be reframed")

        let bakedLevels: String? = await ChromaKeyBakeTests.tag(
            TakeWriter.levelsKey, of: baked.url)
        let bakedTag: String? = await ChromaKeyBakeTests.tag(
            TakeWriter.sizingKey, of: baked.url)
        #expect(bakedTag == "flipH",
                "a reframed take did not say what was done: \(bakedTag ?? "nil")")
        #expect(bakedLevels == nil,
                "a display-value take was tagged as wire codes and will be expanded twice")
    }

    // MARK: - the latch

    /// Disarming the bake mid-take finishes the take it started. EVERY frame
    /// is read: the failure this guards is a file that changes halfway
    /// through, and the record buffer's pixel format follows this answer — so
    /// a mid-take change is a format change under an open writer.
    @Test func aTakeFinishesTheWayItOpened() async throws {
        let root = TestMedia.scratchDirectory("SizingBakeLatchOff")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setViewAssist(Self.bakedFlip())

        let take = try await record(pipeline, source()) {
            pipeline.setViewAssist(ViewAssist())
        }
        let lefts = await Self.leftPixels(of: take.url)
        #expect(lefts.count >= 6, "only \(lefts.count) frames decoded")
        #expect(lefts.allSatisfy { $0.g > 150 },
                "the take stopped being reframed partway through: \(lefts)")
    }

    /// …and arming it mid-take starts nothing. The take that is rolling stays
    /// camera original for its whole length; the NEXT one bakes.
    @Test func armingTheBakeMidTakeLeavesTheRollingTakeClean() async throws {
        let root = TestMedia.scratchDirectory("SizingBakeLatchOn")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)

        let take = try await record(pipeline, source()) {
            pipeline.setViewAssist(Self.bakedFlip())
        }
        let lefts = await Self.leftPixels(of: take.url)
        #expect(lefts.count >= 6, "only \(lefts.count) frames decoded")
        #expect(lefts.allSatisfy { $0.g < 100 },
                "a bake armed mid-take reached the file: \(lefts)")

        // …and the next take does bake, so the latch is a latch rather than an
        // off switch
        let next = try await record(pipeline, source())
        let frame = try #require(await ChromaProbe.firstFrame(of: next.url))
        #expect(ChromaProbe.pixel(of: frame, atFractionX: 0.1).g > 150,
                "the take after the arm was still camera original")
    }

    // MARK: - the grab and the measurement path

    /// A still is a deliverable, so while a reframed take rolls the grab
    /// carries the reframe — the rule that makes a grab carry a baked LUT.
    @Test func theGrabMatchesWhatTheTakeIsCarrying() async throws {
        let root = TestMedia.scratchDirectory("SizingBakeGrab")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setViewAssist(Self.bakedFlip())
        let grabs = EventCollector<Data?>()

        _ = try await record(pipeline, source(), frames: 8) {
            pipeline.grabNextFrame { grabs.append($0) }
        }
        await TestWait.until { !grabs.isEmpty }

        let png = try #require(grabs.first ?? nil, "no PNG came back")
        let left = try #require(ChromaProbe.pixel(inPNG: png, atFractionX: 0.1),
                                "the grab could not be decoded")
        #expect(left.g > 140,
                "the grab did not match the take it came from: \(left)")
    }

    /// The measurement side is untouched, and that is what keeps a reframed
    /// take worth exposing by: the frame published for the compare provider is
    /// still the camera's.
    ///
    /// **The phone's camera grid is no longer on that list**, and the
    /// narrowing is deliberate: the crew's picture carries the SETTLED framing
    /// now (`LivePicture.clean`), which is the half that cannot crop. The grid
    /// still shows the whole frame the camera sent — in the shape it is meant
    /// to be seen in.
    @Test func theBakeNeverReachesTheMeasurementPath() async throws {
        let root = TestMedia.scratchDirectory("SizingBakeClean")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setViewAssist(Self.bakedFlip())

        _ = try await record(pipeline, source(), frames: 8)
        await TestWait.until { pipeline.currentPreviewBuffer() != nil }

        let clean = try #require(pipeline.currentPreviewBuffer())
        let left = ChromaProbe.pixel(of: clean, atFractionX: 0.1)
        #expect(left.g < 100, "the reframe reached the clean frame: \(left)")
        // …and no frame had to fall back, so the picture above is the bake
        // working rather than the bake failing
        #expect(pipeline.health.sizingBakeFallbacks == 0,
                "\(pipeline.health.sizingBakeFallbacks) frames were written unframed")
    }

    // MARK: - fixtures

    /// The left-hand pixel of EVERY frame in a finished take, in order —
    /// whole-file, because the latch questions are about a file that changes
    /// halfway through and the first frame is the one that cannot have.
    static func leftPixels(of url: URL) async -> [ChromaProbe.Pixel] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        var pixels: [ChromaProbe.Pixel] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            pixels.append(ChromaProbe.pixel(of: buffer, atFractionX: 0.1))
        }
        return pixels
    }
}
