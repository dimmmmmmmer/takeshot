import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import CaptureCore

/// Pre-roll used to buffer picture only: the take opened with frames from
/// before the REC press and an audio track that started where the operator
/// pressed it. Sound arrived seconds late — or, for a short take, not at all.
struct PreRollAudioTests {
    private func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &buffer)
        return buffer!
    }

    /// 40 ms of 16-channel silence at the given time — shape matters, not content.
    private func makeAudio(seconds: Double,
                           cache: inout CMAudioFormatDescription?) -> CMSampleBuffer? {
        let channels = 16
        let frames = 1920
        let samples = [Int16](repeating: 0, count: frames * channels)
        return samples.withUnsafeBytes { raw in
            PCMAudio.makeSampleBuffer(bytes: raw.baseAddress!, sampleFrames: frames,
                                      channelCount: channels, ptsSeconds: seconds,
                                      formatCache: &cache)
        }
    }

    @Test func takeCarriesAudioFromBeforeTheRecPoint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreRollAudio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CaptureSettings()
        settings.codec = .proResProxy
        settings.destinationPath = root.path
        settings.startDebounceFrames = 3
        settings.stopDebounceFrames = 5
        settings.detectionMode = .timecodeRun
        settings.preRollSeconds = 0.8 // 20 frames at 25 fps

        let pipeline = CapturePipeline(config: .init(
            settings: settings, scene: "1", takeNumber: 1))
        var finished: [Take] = []
        pipeline.onTakeFinished = { finished.append($0) }
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                            timecodeFPS: 25, name: "test"))

        let pixelBuffer = makePixelBuffer()
        var audioCache: CMAudioFormatDescription?
        var tc = Timecode(hours: 9, minutes: 0, seconds: 0, frames: 0, fps: 25)
        var frame = 0

        // one video frame and its 40 ms of audio, at the live pace
        func push(_ timecode: Timecode) async throws {
            frame += 1
            let seconds = Double(frame) * 0.04
            pipeline.handleFrame(
                pixelBuffer: pixelBuffer,
                pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                timecode: timecode, vancTrigger: nil)
            if let audio = makeAudio(seconds: seconds, cache: &audioCache) {
                pipeline.handleAudio(audio)
            }
            try await Task.sleep(for: .milliseconds(40))
        }

        // standby long enough to fill the pre-roll window, then record, then stop
        for _ in 0..<30 { try await push(tc) }
        for _ in 0..<50 {
            tc = tc.advanced(by: 1)
            try await push(tc)
        }
        for _ in 0..<10 { try await push(tc) }

        for _ in 0..<100 where finished.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let take = try #require(finished.first)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: take.url.path) {
            try await Task.sleep(for: .milliseconds(50))
        }

        let asset = AVURLAsset(url: take.url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 1, "the take must have an audio track")
        let track = try #require(audioTracks.first)
        let videoDuration = try await asset.load(.duration).seconds

        // The track's declared timeRange follows the writer's session and looks
        // healthy even with no samples in the pre-roll region, so the actual
        // samples are read out: how much sound is really in the file, and where
        // the first of it sits.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var firstSample: Double?
        var sampledSeconds = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if firstSample == nil, pts.isNumeric { firstSample = pts.seconds }
            let duration = CMSampleBufferGetDuration(buffer)
            if duration.isNumeric { sampledSeconds += duration.seconds }
        }
        reader.cancelReading()

        let start = try #require(firstSample, "no audio samples in the take at all")
        // the fix: sound is present from the take's first frame, ~0.8 s before
        // the REC point, not only from the press onwards
        #expect(start < 0.12,
                "first audio sample at \(start) s — the pre-roll has no sound")
        #expect(sampledSeconds > videoDuration - 0.25,
                "only \(sampledSeconds) s of audio for \(videoDuration) s of picture")
    }
}
