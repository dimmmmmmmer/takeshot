import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// The creative metadata INSIDE the recording.
///
/// This is the whole point of the feature: a .mov copied off the card without
/// its sidecars still has to know which scene it is. So every assertion here
/// reads a real, finalized file back through the AVAsset metadata APIs — the
/// same way Resolve or a DIT's inspector would — rather than trusting the
/// dictionary the writer was handed.
struct TakeWriterSlateTests {
    private static let format = CaptureFormat(width: 320, height: 180,
                                              frameRate: 25, timecodeFPS: 25,
                                              name: "test")

    /// Record a real one-second take with `slate` on it and hand back the URL.
    private func record(_ slate: SlateMetadata,
                        into directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("take.mov")
        let writer = try TakeWriter(url: url, format: Self.format,
                                    codec: .proResProxy, startTimecode: nil,
                                    slate: slate)
        let picture = TestMedia.pixelBuffer(width: 320, height: 180)
        for frame in 0..<25 {
            let pts = CMTime(value: CMTimeValue(frame * 40), timescale: 1000)
            var attempts = 0
            while !writer.append(pixelBuffer: picture, pts: pts), attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        return try await writer.finish()
    }

    /// Every metadata item of a finished file, both containers.
    private func metadata(of url: URL) async throws -> [AVMetadataItem] {
        try await AVURLAsset(url: url).load(.metadata)
    }

    /// One namespaced ('mdta') value, or nil when the key is absent.
    private func value(_ key: String,
                       in items: [AVMetadataItem]) async throws -> String? {
        guard let item = items.first(where: { ($0.key as? String) == key })
        else { return nil }
        return try await item.load(.stringValue)
    }

    @Test func aRecordedTakeCarriesItsSlateInTheFile() async throws {
        let directory = TestMedia.scratchDirectory("slate-write")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try await record(
            SlateMetadata(scene: "12A", shot: "B", take: 3), into: directory)
        let items = try await metadata(of: url)

        #expect(try await value(TakeWriter.sceneKey, in: items) == "12A")
        #expect(try await value(TakeWriter.shotKey, in: items) == "B")
        #expect(try await value(TakeWriter.takeKey, in: items) == "3")
        // the file is still one of ours, and still says which roll/clip
        #expect(try await value(TakeWriter.markerKey, in: items) == "1")
    }

    /// The slate also goes into the STANDARD description field, in both
    /// QuickTime containers — the namespaced keys above are precise but
    /// invisible to anything that has not heard of TakeShot.
    @Test func theSlateIsAlsoWrittenAsTheStandardDescription() async throws {
        let directory = TestMedia.scratchDirectory("slate-standard")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try await record(
            SlateMetadata(scene: "12A", shot: "B", take: 3), into: directory)
        let items = try await metadata(of: url)
        let expected = "Scene 12A / Shot B / Take 3"

        // modern QuickTime metadata ('mdta') — Final Cut, QuickTime Player
        #expect(try await value(
            AVMetadataKey.quickTimeMetadataKeyDescription.rawValue,
            in: items) == expected)
        // classic user data ('udta') — Premiere and the long tail. Its key
        // reads back as the raw FourCC number, so it is matched by identifier.
        let udta = try #require(AVMetadataItem.metadataItems(
            from: items,
            filteredByIdentifier: .quickTimeUserDataDescription).first)
        #expect(try await udta.load(.stringValue) == expected)
    }

    /// A day shot without a script supervisor must leave NO creative keys
    /// behind: empty values in a file's metadata are worse than absent ones —
    /// an ALE built from them imports a bin full of blank scenes.
    @Test func anEmptySlateWritesNoKeysAtAll() async throws {
        let directory = TestMedia.scratchDirectory("slate-empty")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try await record(.empty, into: directory)
        let items = try await metadata(of: url)

        for key in [TakeWriter.sceneKey, TakeWriter.shotKey,
                    TakeWriter.takeKey,
                    AVMetadataKey.quickTimeMetadataKeyDescription.rawValue] {
            #expect(try await value(key, in: items) == nil,
                    "\(key) was written for an empty slate")
        }
        #expect(AVMetadataItem.metadataItems(
            from: items,
            filteredByIdentifier: .quickTimeUserDataDescription).isEmpty)
        // and the file is still tagged as ours — the marker is not creative
        #expect(try await value(TakeWriter.markerKey, in: items) == "1")
    }

    /// A partial slate writes only what was logged. Scene alone is the normal
    /// case on a documentary unit, and it must not drag two blank keys in.
    @Test func aPartialSlateWritesOnlyTheFieldsThatHaveValues() async throws {
        let directory = TestMedia.scratchDirectory("slate-partial")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try await record(SlateMetadata(scene: "104"), into: directory)
        let items = try await metadata(of: url)

        #expect(try await value(TakeWriter.sceneKey, in: items) == "104")
        #expect(try await value(TakeWriter.shotKey, in: items) == nil)
        #expect(try await value(TakeWriter.takeKey, in: items) == nil)
        #expect(try await value(
            AVMetadataKey.quickTimeMetadataKeyDescription.rawValue,
            in: items) == "Scene 104")
    }

    /// The metadata must not cost the file its tracks. Stated separately
    /// because a writer that silently loses the timecode track when metadata
    /// is attached would still pass every assertion above.
    @Test func theSlateDoesNotDisturbTheTracks() async throws {
        let directory = TestMedia.scratchDirectory("slate-tracks")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let startTC = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                               fps: 25)
        let url = directory.appendingPathComponent("tracks.mov")
        let writer = try TakeWriter(url: url, format: Self.format,
                                    codec: .proResProxy,
                                    startTimecode: startTC,
                                    slate: SlateMetadata(scene: "12A", shot: "B",
                                                         take: 3),
                                    audioChannelCount: 2)
        let picture = TestMedia.pixelBuffer(width: 320, height: 180)
        var audioCache: CMAudioFormatDescription?
        for frame in 0..<25 {
            let pts = CMTime(value: CMTimeValue(frame * 40), timescale: 1000)
            var attempts = 0
            while !writer.append(pixelBuffer: picture, pts: pts), attempts < 200 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(5))
            }
            if let audio = TestMedia.audioBuffer(seconds: Double(frame) * 0.04,
                                                 channels: 2,
                                                 cache: &audioCache) {
                writer.append(audioSampleBuffer: audio)
            }
        }
        _ = try await writer.finish()

        let asset = AVURLAsset(url: url)
        #expect(try await asset.tracks(ofType: .video).count == 1)
        #expect(try await asset.tracks(ofType: .audio).count == 1)
        #expect(try await asset.tracks(ofType: .timecode).count == 1)
        #expect(await TimecodeReader.startTimecode(of: asset) == startTC)
    }
}
