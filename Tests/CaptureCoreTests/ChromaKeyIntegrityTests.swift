import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing

@testable import CaptureCore

/// The rule the whole feature is built around: the chroma key is a PREVIEW.
///
/// It reaches the viewer and the hardware monitor because those mirror what the
/// operator is looking at — the same rule the viewing LUT follows. It reaches
/// the recorded file, the still grab, the scopes' measurement and the phone
/// camera grid nowhere at all, and that is what this suite exists to keep true:
/// a director watching a keyed monitor must never be the reason a take comes
/// back from post with a magenta background baked into it. (The grid is a
/// monitoring surface, not an assist one — see `PreviewDisplayPathTests`.)
struct ChromaKeyIntegrityTests {
    /// A pipeline that can record, on a scratch folder of its own.
    private func recordingPipeline(root: URL) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.destinationPath = root.path
        settings.capture.detectionMode = .manual // this suite starts its own take
        settings.capture.videoLevels = "full"    // pass the test frame's codes through
        settings.capture.preRollFrames = 0
        settings.capture.codec = .proResProxy    // the suite encodes in real time
        return CapturePipeline(config: .init(settings: settings, takeNumber: 1))
    }

    /// The still grab is a deliverable: it comes off the frame before the
    /// display stage ever sees it, so the green is still green in the PNG.
    @Test func aGrabTakenWhileTheKeyIsOnHoldsTheOriginalPicture() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setChromaKey(ChromaProbe.magentaKey())
        let grabs = EventCollector<Data?>()
        let shown = EventCollector<Int>()
        pipeline.setOnDisplayFrame { buffer in
            shown.append(ChromaProbe.pixel(of: buffer,
                                           atFractionX: ChromaProbe.screenX).r)
        }
        defer { pipeline.setOnDisplayFrame(nil) }
        pipeline.grabNextFrame { grabs.append($0) }

        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray)
        for index in 1...3 {
            PreviewProbe.push(pipeline, source, frame: index)
        }
        await TestWait.until { !grabs.isEmpty && !shown.isEmpty }

        // the operator IS looking at a keyed picture…
        #expect(shown.all.contains { $0 > 250 },
                "the key never reached the screen, so this proves nothing")
        // …and the file they just made is not
        let png = try #require(grabs.first ?? nil, "no PNG came back")
        let pixel = try #require(
            ChromaProbe.pixel(inPNG: png, atFractionX: ChromaProbe.screenX),
            "the grab could not be decoded")
        #expect(pixel.g > 180 && pixel.r < 80 && pixel.b < 80,
                "the key was baked into the grab: \(pixel)")
    }

    /// The recorded take, the same question, through a real encoder.
    @Test func aTakeRecordedWhileTheKeyIsOnHoldsTheOriginalPicture() async throws {
        let root = TestMedia.scratchDirectory("ChromaKeyTake")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                            timecodeFPS: 25, name: "1080p25"))
        pipeline.setChromaKey(ChromaProbe.magentaKey())
        let takes = TakeCollector()
        pipeline.onTakeFinished = { takes.append($0) }
        let shown = EventCollector<Int>()
        pipeline.setOnDisplayFrame { buffer in
            shown.append(ChromaProbe.pixel(of: buffer,
                                           atFractionX: ChromaProbe.screenX).r)
        }
        defer { pipeline.setOnDisplayFrame(nil) }

        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray,
                                       width: 320, height: 180)
        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        pipeline.toggleManualRecord()
        for _ in 0..<12 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: source)
        }
        pipeline.toggleManualRecord()
        await TestWait.untilWritten { takes.first != nil }

        let take = try #require(takes.first, "no take was finished")
        await TestWait.fileExists(at: take.url)
        #expect(shown.all.contains { $0 > 250 },
                "the key never reached the screen, so this proves nothing")

        let frame = try #require(await ChromaProbe.firstFrame(of: take.url),
                                 "the take decoded no frames")
        let screen = ChromaProbe.pixel(of: frame, atFractionX: ChromaProbe.screenX)
        // ProRes is a DCT codec and this is a saturated primary next to a hard
        // edge, so the assertion is the one that matters: the screen is still
        // GREEN, not the magenta the monitor was showing
        #expect(screen.g > 180 && screen.r < 80 && screen.b < 80,
                "the key was baked into the take: \(screen)")
        let subject = ChromaProbe.pixel(of: frame, atFractionX: ChromaProbe.subjectX)
        #expect(abs(subject.g - 128) < 20, "the subject was altered: \(subject)")
    }

    /// The frame published for the compare provider — what a pinned reference
    /// and the difference compare are taken from — is the clean one too.
    @Test func theCompareProviderNeverSeesTheKey() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setChromaKey(ChromaProbe.magentaKey())
        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray)
        let shown = try await ChromaProbe.presented(pipeline, source)
        #expect(ChromaProbe.pixel(of: shown, atFractionX: ChromaProbe.screenX).r > 250)

        let clean = try #require(pipeline.currentPreviewBuffer())
        #expect(clean === source, "the provider was handed the keyed frame")
        let preLUT = try #require(pipeline.currentPreLUTPreviewBuffer())
        #expect(preLUT === source)
    }

    /// Graceful degradation: a frame that reaches the display stage already
    /// stale is shown at once WITHOUT the key, rather than being held up while
    /// the GPU works on a picture that is out of date before it lands.
    ///
    /// The stall is put on the display queue directly, which is what a machine
    /// under load does to it: the frame is enqueued on time and the block that
    /// draws it is scheduled late.
    @Test func aFrameThatIsAlreadyLateLosesTheEffectAndNotTheFrame() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setChromaKey(ChromaProbe.magentaKey())
        let source = ChromaProbe.frame(screen: ChromaProbe.digitalGreen,
                                       subject: ChromaProbe.midGray)

        // an unobstructed queue keys the frame
        let keyed = try await ChromaProbe.presented(pipeline, source, frame: 1)
        #expect(ChromaProbe.pixel(of: keyed, atFractionX: ChromaProbe.screenX).r > 250,
                "the key is not working at all, so the late case proves nothing")
        #expect(pipeline.chromaKeyLateDrops == 0)

        // …and one that has been sitting behind a stalled display queue for
        // five frame intervals does not
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }
        pipeline.displayQueue.async { Thread.sleep(forTimeInterval: 0.2) }
        PreviewProbe.push(pipeline, source, frame: 2)
        await TestWait.until { collector.count > 0 }

        let late = try #require(collector.last)
        #expect(late === source, "a stale frame was still keyed")
        #expect(pipeline.chromaKeyLateDrops == 1,
                "the drop was not counted: \(pipeline.chromaKeyLateDrops)")
    }
}

extension ChromaProbe {
    /// The pixel at `fraction` across the middle row of a PNG.
    ///
    /// Drawn into a device-RGB context rather than read out of the file's own
    /// Rec.709 space: the conversion moves the values by a few codes, which the
    /// assertions here allow for — what they ask is whether the picture is
    /// green or magenta, and no color management turns one into the other.
    static func pixel(inPNG data: Data, atFractionX fraction: Double) -> Pixel? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard width > 0, height > 0,
              let context = pixels.withUnsafeMutableBytes({ bytes in
                  CGContext(data: bytes.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: info)
              }) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = min(width - 1, max(0, Int(Double(width) * fraction)))
        let offset = (height / 2) * width * 4 + x * 4
        return Pixel(r: Int(pixels[offset]), g: Int(pixels[offset + 1]),
                     b: Int(pixels[offset + 2]))
    }

    /// The first video frame of a recorded file, as BGRA.
    static func firstFrame(of url: URL) async -> CVPixelBuffer? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        return CMSampleBufferGetImageBuffer(sample)
    }
}
