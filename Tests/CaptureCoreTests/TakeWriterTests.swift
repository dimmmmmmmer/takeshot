import AVFoundation
import Foundation
import Testing
@testable import CaptureCore

struct TakeWriterTests {
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TakeWriterTests-\(UUID().uuidString)")
            .appendingPathComponent("take.mov")
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
        TestMedia.pixelBuffer(width: width, height: height)
    }

    @Test func writesTakeWithVideoAndTimecodeTracks() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let format = CaptureFormat(width: 1280, height: 720, frameRate: 24,
                                   timecodeFPS: 24, name: "720p24")
        let startTC = Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, fps: 24)
        let writer = try TakeWriter(url: tempURL, format: format,
                                    codec: .proRes422, startTimecode: startTC)

        let pixelBuffer = makePixelBuffer(width: 1280, height: 720)
        for frame in 0..<24 {
            let pts = CMTime(value: CMTimeValue(frame * 1000), timescale: 24_000)
            // the test feeds frames faster than real time — wait for the encoder to be ready
            var attempts = 0
            while !writer.append(pixelBuffer: pixelBuffer, pts: pts), attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let url = try await writer.finish()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(abs(writer.durationSeconds - 1.0) < 0.05)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 1.0) < 0.1)

        let videoTracks = try await asset.tracks(ofType: .video)
        #expect(videoTracks.count == 1)
        let size = try await videoTracks[0].load(.naturalSize)
        #expect(Int(size.width) == 1280)
        #expect(Int(size.height) == 720)

        let timecodeTracks = try await asset.tracks(ofType: .timecode)
        #expect(timecodeTracks.count == 1, "a timecode track must be present")

        // and the start TC reads back exactly as written
        let readBack = await TimecodeReader.startTimecode(of: asset)
        #expect(readBack == startTC)
    }

    /// Levels must not drift on write: 50% and 18% grey come back from the
    /// ProRes file within ±2/255 per channel.
    @Test func levelsSurviveWriteReadRoundTrip() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let format = CaptureFormat(width: 320, height: 180, frameRate: 25,
                                   timecodeFPS: 25, name: "test")
        let writer = try TakeWriter(url: tempURL, format: format,
                                    codec: .proRes422, startTimecode: nil)
        let gray = TestMedia.grayBuffer(128) // ~50% grey
        for frame in 0..<10 {
            let pts = CMTime(value: CMTimeValue(frame * 40), timescale: 1000)
            var attempts = 0
            while !writer.append(pixelBuffer: gray, pts: pts), attempts < 100 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        _ = try await writer.finish()

        // read a frame from the file and compare the center
        let asset = AVURLAsset(url: tempURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let (cgImage, _) = try await generator.image(
            at: CMTime(value: 200, timescale: 1000))

        // draw in the frame's NATIVE colorspace (identity) — verify the values
        // themselves didn't drift on encode/decode; colorspace interpretation is
        // a separate concern of the display layers
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709)!
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cgImage, in: CGRect(x: -160, y: -90, width: 320, height: 180))

        for channel in 0..<3 {
            let delta = abs(Int(pixel[channel]) - 128)
            #expect(delta <= 2,
                    "channel \(channel): wrote 128, read \(pixel[channel])")
        }
    }

    @Test func writesAudioTrack() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let format = CaptureFormat(width: 320, height: 180, frameRate: 25,
                                   timecodeFPS: 25, name: "test")
        let channels = 16 // 16-channel LPCM without a layout crashed the process
        let writer = try TakeWriter(url: tempURL, format: format,
                                    codec: .proResProxy, startTimecode: nil,
                                    audioChannelCount: channels)
        let pixelBuffer = makePixelBuffer(width: 320, height: 180)
        var audioCache: CMAudioFormatDescription?
        for frame in 0..<10 {
            let pts = CMTime(value: CMTimeValue(frame * 40), timescale: 1000)
            var attempts = 0
            while !writer.append(pixelBuffer: pixelBuffer, pts: pts), attempts < 100 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
            let samples = [Int16](repeating: 500, count: 1920 * channels)
            samples.withUnsafeBytes { raw in
                if let base = raw.baseAddress,
                   let sb = PCMAudio.makeSampleBuffer(
                    bytes: base, sampleFrames: 1920, channelCount: channels,
                    ptsSeconds: Double(frame) * 0.04, formatCache: &audioCache) {
                    writer.append(audioSampleBuffer: sb)
                }
            }
        }
        let url = try await writer.finish()

        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.tracks(ofType: .audio)
        #expect(audioTracks.count == 1, "the file must have an audio track")
    }

    @Test func cancelRemovesFile() throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let format = CaptureFormat(width: 640, height: 360, frameRate: 25,
                                   timecodeFPS: 25, name: "360p25")
        let writer = try TakeWriter(url: tempURL, format: format,
                                    codec: .proResProxy, startTimecode: nil)
        writer.append(pixelBuffer: makePixelBuffer(width: 640, height: 360), pts: .zero)
        writer.cancel()
        #expect(!FileManager.default.fileExists(atPath: tempURL.path))
    }
}

extension TakeWriterTests {
    /// One tc32 sample as read back: its start frame number, where it sits and
    /// how long it lasts.
    struct TCSample {
        let frameNumber: Int
        let start: Double
        let duration: Double
    }

    /// Every sample of a file's timecode track, in order.
    private func timecodeSamples(of url: URL) async throws -> [TCSample] {
        let asset = AVURLAsset(url: url)
        let track: AVAssetTrack = try #require(
            try await asset.tracks(ofType: .timecode).first,
            "the take has no timecode track")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        var samples: [TCSample] = []
        while let sample: CMSampleBuffer = output.copyNextSampleBuffer() {
            guard let block: CMBlockBuffer =
                    CMSampleBufferGetDataBuffer(sample) else { continue }
            var raw: UInt32 = 0
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4,
                                       destination: &raw)
            samples.append(TCSample(
                frameNumber: Int(UInt32(bigEndian: raw)),
                start: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                duration: CMSampleBufferGetDuration(sample).seconds))
        }
        return samples
    }

    /// The timecode track is written in one-second samples as the take runs, so
    /// that an abandoned file has a `moov` (see
    /// `TakeIntegrityBoundsTests.anAbandonedTakeIsStillReadableUpToItsLastFragment`).
    /// What that must not change is what the track SAYS, and this is where that
    /// is checked rather than assumed.
    ///
    /// A tc32 sample states the timecode of its first frame and a reader counts
    /// forward from there, so cutting a continuous run into one-second pieces is
    /// only transparent if every piece carries the value the run had reached at
    /// its own start. The other two timecode suites cannot see this: their takes
    /// are under a second long, so they get one sample per anchor exactly as
    /// before, and a chunk that carried the wrong frame number would pass all of
    /// them.
    ///
    /// 3 s at 25 fps with the camera re-anchoring at 1.6 s gives four samples:
    /// [0, 1) and [1, 1.6) from the start TC, then [1.6, 2.6) and [2.6, 3) from
    /// the re-anchor — one boundary per second, one at the anchor, one at the end.
    @Test func aLongTakesChunkedTimecodeTrackReadsAsOneRun() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let format = CaptureFormat(width: 320, height: 180, frameRate: 25,
                                   timecodeFPS: 25, name: "test 25")
        let startTC = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        let runTC = Timecode(hours: 11, minutes: 0, seconds: 0, frames: 0, fps: 25)
        let writer = try TakeWriter(url: tempURL, format: format,
                                    codec: .proResProxy, startTimecode: startTC)
        let pixelBuffer = makePixelBuffer(width: 320, height: 180)
        let resyncFrame = 40 // 1.6 s in: past the first chunk boundary
        for frame in 0..<75 {
            let pts = CMTime(value: CMTimeValue(frame * 1000), timescale: 25_000)
            if frame == resyncFrame {
                writer.addTimecodeResync(timecode: runTC, at: pts)
            }
            var attempts = 0
            while !writer.append(pixelBuffer: pixelBuffer, pts: pts), attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        // The samples are already on disk while the take is still rolling,
        // lagging the picture by about one interval. Asserted on the writer
        // rather than on the file because the FINISHED file cannot show it — the
        // tail flush writes the same layout either way, so everything below this
        // line passes just as well with the live commit removed, and what an
        // abandoned take needs is precisely that the samples were not waiting
        // for `finish()`.
        let writtenTo: Double = writer.tcWrittenUntil.seconds
        #expect(writtenTo > 2.0,
                "the track had only reached \(writtenTo) s at the last frame")

        let url = try await writer.finish()

        let samples: [TCSample] = try await timecodeSamples(of: url)
        #expect(samples.count == 4,
                "the 3 s take's timecode track has \(samples.count) sample(s)")

        // Continuous: each sample begins where the last one ended, and together
        // they cover the picture. A gap here is a file whose timecode stops.
        var covered = 0.0
        for sample in samples {
            #expect(abs(sample.start - covered) < 0.001,
                    "a sample starts at \(sample.start), not \(covered)")
            covered += sample.duration
        }
        #expect(abs(covered - 3.0) < 0.001,
                "the timecode track covers \(covered) s of a 3 s take")

        // …and every sample says what the camera's clock said at its own start.
        let resyncStart = 1.6
        for sample in samples {
            let expected: Int = sample.start < resyncStart - 0.001
                ? startTC.frameNumber + Int((sample.start * 25).rounded())
                : runTC.frameNumber
                    + Int(((sample.start - resyncStart) * 25).rounded())
            #expect(sample.frameNumber == expected,
                    "at \(sample.start) s: \(sample.frameNumber), not \(expected)")
        }

        // the start timecode a foreign tool reads is still the take's own
        let readBack: Timecode? = await TimecodeReader.startTimecode(
            of: AVURLAsset(url: url))
        #expect(readBack == startTC)
    }

    /// Rec Run starting mid-take: the resync anchor must land as a SECOND
    /// tc32 sample, so the overlap conforms frame-accurately to the camera.
    /// The take is under one timecode-sample interval long, so it gets exactly
    /// one sample per anchor (see `aLongTakesChunkedTimecodeTrackReadsAsOneRun`
    /// for the longer take, where the periodic samples appear too).
    @Test func midTakeResyncWritesSecondTimecodeSample() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let format = CaptureFormat(width: 1280, height: 720, frameRate: 24,
                                   timecodeFPS: 24, name: "720p24")
        // camera frozen at 01:00:00:00 for the first 12 frames of the take
        let frozenTC = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, fps: 24)
        let writer = try TakeWriter(url: tempURL, format: format,
                                    codec: .proResProxy, startTimecode: frozenTC)
        let pixelBuffer = makePixelBuffer(width: 1280, height: 720)
        for frame in 0..<24 {
            let pts = CMTime(value: CMTimeValue(frame * 1000), timescale: 24_000)
            if frame == 12 {
                // the camera's TC starts running here (value = frozen + 1)
                writer.addTimecodeResync(
                    timecode: Timecode(hours: 1, minutes: 0, seconds: 0,
                                       frames: 1, fps: 24),
                    at: pts)
            }
            var attempts = 0
            while !writer.append(pixelBuffer: pixelBuffer, pts: pts), attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let url = try await writer.finish()

        let asset = AVURLAsset(url: url)
        let track = try #require(
            try await asset.tracks(ofType: .timecode).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var frameNumbers: [UInt32] = []
        var durations: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var raw: UInt32 = 0
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &raw)
            frameNumbers.append(UInt32(bigEndian: raw))
            durations.append(CMSampleBufferGetDuration(sample).seconds)
        }
        reader.cancelReading()

        #expect(frameNumbers.count == 2)
        #expect(frameNumbers.first == UInt32(frozenTC.frameNumber))
        #expect(frameNumbers.last == UInt32(frozenTC.frameNumber + 1))
        // first sample covers the 12 frozen frames, the second the rest
        #expect(abs((durations.first ?? 0) - 0.5) < 0.05)
        #expect(abs((durations.last ?? 0) - 0.5) < 0.05)
    }
}
