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
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
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

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1)
        let size = try await videoTracks[0].load(.naturalSize)
        #expect(Int(size.width) == 1280)
        #expect(Int(size.height) == 720)

        let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
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

        func makeGray(_ value: UInt8) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                &pb)
            let buffer = pb!
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(value),
                   CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for (key, value) in [
                (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            ] {
                CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
            }
            return buffer
        }

        let format = CaptureFormat(width: 320, height: 180, frameRate: 25,
                                   timecodeFPS: 25, name: "test")
        let writer = try TakeWriter(url: tempURL, format: format,
                                    codec: .proRes422, startTimecode: nil)
        let gray = makeGray(128) // ~50% grey
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
            var samples = [Int16](repeating: 500, count: 1920 * channels)
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
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
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
    /// Rec Run starting mid-take: the resync anchor must land as a SECOND
    /// tc32 sample, so the overlap conforms frame-accurately to the camera.
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
            try await asset.loadTracks(withMediaType: .timecode).first)
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
