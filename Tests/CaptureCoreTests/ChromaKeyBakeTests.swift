import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The chroma key asked INTO the file: `ChromaKey.record`.
///
/// `ChromaKeyIntegrityTests` next door holds the default — the key is a preview
/// and reaches no deliverable. This suite holds the exception, and it is a
/// different set of questions, because a baked take is a different kind of thing
/// from the take beside it:
///
///   1. the composite really is in the file (and the subject is not touched);
///   2. the file SAYS it is a composite, and stops claiming to carry wire codes;
///   3. the take latches what it opened with, both ways — disarming mid-take
///      cannot leave half a composite, and arming mid-take cannot start one;
///   4. the still grab follows the deliverable rather than the camera;
///   5. the scopes and the phone grid still see the camera, which is the whole
///      reason a baked take is still worth exposing by.
struct ChromaKeyBakeTests {
    /// A pipeline that can record, on a scratch folder of its own. The same
    /// shape `ChromaKeyIntegrityTests` records with, so the two suites differ in
    /// one flag rather than in a setup.
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

    /// The magenta key with the bake armed — the one difference from
    /// `ChromaProbe.magentaKey()`, spelled out so every test below reads as
    /// "the same key, recorded".
    private static func bakedKey(
        screen: ChromaKey.RGB = ChromaProbe.digitalGreen) -> ChromaKey {
        var key = ChromaProbe.magentaKey()
        key.keyColor = screen
        key.record = true
        return key
    }

    /// Record one take of `source` and hand back the finished take.
    ///
    /// `midTake` runs after the first half of the frames, which is where every
    /// latch question in this suite lives.
    private func record(_ pipeline: CapturePipeline, _ source: CVPixelBuffer,
                        frames: Int = 12,
                        midTake: (() -> Void)? = nil) async throws -> Take {
        let takes = TakeCollector()
        pipeline.onTakeFinished = { takes.append($0) }
        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                               fps: 25)
        // Frames BEFORE the take opens, which is not padding: the levels stage
        // learns what the wire carries from a frame that has been through it, so
        // a take opened before frame one deliberately says nothing about its own
        // code values (see `recordCarriesWireCodes`) — and this suite is about
        // what the file says. It is also what a real REC press looks like: the
        // signal was already running.
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

    // MARK: - the default

    /// The bake is off in a fresh key, which is what makes the integrity suite
    /// beside this one prove anything at all: every test there runs with
    /// `ChromaProbe.magentaKey()`, and if that carried a bake they would all be
    /// asserting the opposite of what they say.
    @Test func theBakeIsOffUntilItIsAskedFor() {
        #expect(!ChromaKey().record)
        #expect(!ChromaProbe.magentaKey().record)
        #expect(Self.bakedKey().record, "this suite's own fixture bakes nothing")
    }

    // MARK: - the picture

    /// The take IS the composite: where the screen was there is magenta, and the
    /// subject came through untouched.
    @Test func aTakeRecordedWithTheBakeOnCarriesTheComposite() async throws {
        let root = TestMedia.scratchDirectory("ChromaBakeTake")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setChromaKey(Self.bakedKey())
        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray,
                                       width: 320, height: 180)

        let take = try await record(pipeline, source)
        let frame = try #require(await ChromaProbe.firstFrame(of: take.url),
                                 "the take decoded no frames")
        let screen = ChromaProbe.pixel(of: frame, atFractionX: ChromaProbe.screenX)
        // ProRes is a DCT codec and this is a saturated primary beside a hard
        // edge, so the assertion is the one that matters: the screen is MAGENTA
        #expect(screen.r > 180 && screen.b > 180 && screen.g < 80,
                "the key never reached the take: \(screen)")
        let subject = ChromaProbe.pixel(of: frame, atFractionX: ChromaProbe.subjectX)
        #expect(abs(subject.g - 128) < 20, "the subject was altered: \(subject)")
    }

    // MARK: - what the file says about itself

    /// A baked take names what went behind the actor, and — this is the colour
    /// rule and not a nicety — it stops claiming to carry the camera's wire
    /// codes, because it does not: it carries display values, exactly as a
    /// LUT-baked take does.
    ///
    /// Both takes are recorded here, in one test, off a 10-bit RGB wire with the
    /// levels stage active. Asserting the absence of a key on its own would pass
    /// against a pipeline that never wrote it at all.
    @Test func aBakedTakeSaysSoAndStopsClaimingWireCodes() async throws {
        let root = TestMedia.scratchDirectory("ChromaBakeTags")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root, levels: "limited")
        let source = try Self.wireFrame()

        let clean = try await record(pipeline, source)
        pipeline.setChromaKey(Self.bakedKey(screen: Self.wireGreenOnDisplay))
        let baked = try await record(pipeline, source)

        let cleanLevels: String? = await Self.tag(TakeWriter.levelsKey,
                                                 of: clean.url)
        let cleanKey: String? = await Self.tag(TakeWriter.chromaKeyKey,
                                               of: clean.url)
        #expect(cleanLevels == TakeWriter.wireValue,
                "the clean take is not a wire-code take, so this proves nothing")
        #expect(cleanKey == nil, "a clean take claimed to be a composite")

        let bakedLevels: String? = await Self.tag(TakeWriter.levelsKey,
                                                 of: baked.url)
        let bakedKeyTag: String? = await Self.tag(TakeWriter.chromaKeyKey,
                                                 of: baked.url)
        #expect(bakedKeyTag == ChromaKey.Background.color.rawValue,
                "a composite did not say what is behind the actor: \(bakedKeyTag ?? "nil")")
        #expect(bakedLevels == nil,
                "a display-value take was tagged as wire codes and will be expanded twice")
    }

    // MARK: - the latch

    /// Disarming the bake mid-take finishes the take it started. EVERY frame is
    /// read, because the failure this guards is a file that changes halfway
    /// through — and because the record buffer's pixel format follows this
    /// answer, so a mid-take change is a format change under an open writer.
    @Test func aTakeFinishesTheWayItOpened() async throws {
        let root = TestMedia.scratchDirectory("ChromaBakeLatchOff")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setChromaKey(Self.bakedKey())
        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray,
                                       width: 320, height: 180)

        let take = try await record(pipeline, source) {
            // the operator changes their mind, and the key with it
            var key = ChromaKey()
            key.isOn = false
            key.record = false
            pipeline.setChromaKey(key)
        }
        let screens: [ChromaProbe.Pixel] =
            await ChromaProbe.screenPixels(of: take.url)
        #expect(screens.count >= 6, "only \(screens.count) frames decoded")
        #expect(screens.allSatisfy { $0.r > 180 && $0.b > 180 && $0.g < 80 },
                "the take stopped being a composite partway through: \(screens)")
    }

    /// …and arming it mid-take starts nothing. The take that is rolling stays
    /// camera original for its whole length; the NEXT one bakes.
    @Test func armingTheBakeMidTakeLeavesTheRollingTakeClean() async throws {
        let root = TestMedia.scratchDirectory("ChromaBakeLatchOn")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray,
                                       width: 320, height: 180)

        let take = try await record(pipeline, source) {
            pipeline.setChromaKey(Self.bakedKey())
        }
        let screens: [ChromaProbe.Pixel] =
            await ChromaProbe.screenPixels(of: take.url)
        #expect(screens.count >= 6, "only \(screens.count) frames decoded")
        #expect(screens.allSatisfy { $0.g > 150 && $0.r < 100 },
                "a bake armed mid-take reached the file: \(screens)")

        // and the next take does bake, so the latch is a latch rather than an
        // off switch
        let next = try await record(pipeline, source)
        let frame = try #require(await ChromaProbe.firstFrame(of: next.url))
        let screen = ChromaProbe.pixel(of: frame, atFractionX: ChromaProbe.screenX)
        #expect(screen.r > 180 && screen.b > 180 && screen.g < 80,
                "the take after the arm was still clean: \(screen)")
    }

    // MARK: - the grab, the scopes and the grid

    /// A still is a deliverable, so while a baked take rolls the grab carries
    /// the composite — the same rule that makes a grab carry a baked LUT.
    @Test func theGrabMatchesWhatTheTakeIsCarrying() async throws {
        let root = TestMedia.scratchDirectory("ChromaBakeGrab")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setChromaKey(Self.bakedKey())
        let grabs = EventCollector<Data?>()
        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray,
                                       width: 320, height: 180)

        _ = try await record(pipeline, source, frames: 8) {
            pipeline.grabNextFrame { grabs.append($0) }
        }
        await TestWait.until { !grabs.isEmpty }

        let png = try #require(grabs.first ?? nil, "no PNG came back")
        let pixel = try #require(
            ChromaProbe.pixel(inPNG: png, atFractionX: ChromaProbe.screenX),
            "the grab could not be decoded")
        #expect(pixel.r > 150 && pixel.b > 150 && pixel.g < 110,
                "the grab did not match the take it was taken from: \(pixel)")
    }

    /// The measurement side is untouched, and that is what keeps a baked take
    /// worth exposing by: the frame published for the compare provider and the
    /// phone's camera grid is still the camera's, so the scopes read the camera
    /// rather than this app's composite.
    @Test func theBakeNeverReachesTheMeasurementPath() async throws {
        let root = TestMedia.scratchDirectory("ChromaBakeClean")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setChromaKey(Self.bakedKey())
        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray,
                                       width: 320, height: 180)

        _ = try await record(pipeline, source, frames: 8)
        await TestWait.until { pipeline.currentPreviewBuffer() != nil }

        let clean = try #require(pipeline.currentPreviewBuffer())
        let screen = ChromaProbe.pixel(of: clean, atFractionX: ChromaProbe.screenX)
        #expect(screen.g > 200 && screen.r < 60,
                "the composite reached the clean frame: \(screen)")
        // …and no frame had to fall back, so the picture above is the effect
        // working rather than the effect failing
        #expect(pipeline.chromaBakeFallbacks == 0,
                "\(pipeline.chromaBakeFallbacks) frames were written unkeyed")
    }

    // MARK: - fixtures

    /// Studio-swing green as it lands on the DISPLAY buffer once the levels
    /// stage has expanded it — which is the domain the key works in, so it is
    /// the colour the key has to be set to for a wire source.
    static let wireGreenOnDisplay = ChromaKey.RGB(0, 1, 0)

    /// A 10-bit RGB wire frame with the same geometry the BGRA fixture has:
    /// studio-swing green screen either side, studio-swing mid grey down the
    /// middle. This is what makes the levels-key assertion non-vacuous — only
    /// this path writes `com.takeshot.levels` at all.
    static func wireFrame(width: Int = 320, height: Int = 180) throws
        -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        let buffer = try #require(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let subject = (width / 3)..<(2 * width / 3)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                // 64/940 is the nominal pair at 10 bits; 502 is mid grey
                let green: UInt32 = subject.contains(x) ? 502 : 940
                let other: UInt32 = subject.contains(x) ? 502 : 64
                row[x] = ((other << 20) | (green << 10) | other).bigEndian
            }
        }
        return buffer
    }

    /// One metadata value out of a finished file, or nil when the key is absent.
    ///
    /// The items are loaded and reduced to a `String?` inside this nonisolated
    /// scope: an `AVMetadataItem` is not Sendable in any macOS SDK, and only the
    /// answer may leave (the same discipline `fileCarriesBakedLUT` follows).
    static func tag(_ key: String, of url: URL) async -> String? {
        let metadata = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        guard let item = metadata.first(where: { ($0.key as? String) == key })
        else { return nil }
        return try? await item.load(.stringValue)
    }
}

extension ChromaProbe {
    /// The screen pixel of EVERY frame in a finished take, in order.
    ///
    /// Whole-file rather than first-frame, because the latch questions are about
    /// a file that changes halfway through — and the first frame is precisely the
    /// one a mid-take change cannot have touched.
    static func screenPixels(of url: URL) async -> [Pixel] {
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
        var pixels: [Pixel] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            pixels.append(pixel(of: buffer, atFractionX: screenX))
        }
        return pixels
    }
}
