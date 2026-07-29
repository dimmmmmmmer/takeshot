import Foundation
import Testing
@testable import TakeShotKit

/// A CinemaDNG "clip" is a folder of numbered .dng frames, and the folder listing
/// IS the edit: whatever order these URLs come back in is the order the player
/// plays. A plain lexicographic sort puts frame_10 before frame_2, which shows
/// up as a clip that stutters backwards — subtle enough to be blamed on the
/// decoder rather than the sort.
struct ModelRawClipTests {
    private func folder(_ names: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelRawClip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        for name in names {
            try Data("frame".utf8)
                .write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    @Test func framesAreOrderedNumericallyNotLexicographically() throws {
        let directory = try folder([
            "clip_10.dng", "clip_2.dng", "clip_1.dng", "clip_100.dng", "clip_20.dng",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let names = DNGSequenceSource.frameURLs(in: directory)
            .map(\.lastPathComponent)
        #expect(names == ["clip_1.dng", "clip_2.dng", "clip_10.dng",
                          "clip_20.dng", "clip_100.dng"])
    }

    /// Cameras write zero-padded names too; those must stay in order as well.
    @Test func zeroPaddedNamesKeepTheirOrder() throws {
        let directory = try folder(["A_000003.dng", "A_000001.dng", "A_000002.dng"])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(DNGSequenceSource.frameURLs(in: directory).map(\.lastPathComponent)
                == ["A_000001.dng", "A_000002.dng", "A_000003.dng"])
    }

    /// A CinemaDNG folder also holds sidecars, audio and .DS_Store; only frames
    /// belong in the sequence, and the extension check is case-insensitive
    /// because cameras disagree about it.
    @Test func onlyDNGFilesAreTakenAndTheCaseDoesNotMatter() throws {
        let directory = try folder([
            "a_001.dng", "a_002.DNG", "a_003.Dng",
            "clip.wav", "metadata.xml", "notes.txt", "a_004.dng.bak",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let names = DNGSequenceSource.frameURLs(in: directory)
            .map(\.lastPathComponent)
        #expect(names == ["a_001.dng", "a_002.DNG", "a_003.Dng"])
    }

    @Test func hiddenFilesAreSkipped() throws {
        let directory = try folder([".hidden_001.dng", "a_001.dng"])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(DNGSequenceSource.frameURLs(in: directory)
            .map(\.lastPathComponent) == ["a_001.dng"])
    }

    @Test func anUnreadableFolderYieldsNoFrames() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelRawClip-nope-\(UUID().uuidString)")
        #expect(DNGSequenceSource.frameURLs(in: missing).isEmpty)
    }

    /// Opening a folder with no frames has to fail with the source's own error
    /// rather than construct a zero-length clip the transport then divides by.
    @Test func aFolderWithNoFramesRefusesToOpen() throws {
        let directory = try folder(["clip.wav", "readme.txt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: DNGSequenceSource.DNGError.self) {
            _ = try DNGSequenceSource(folder: directory)
        }
    }

    /// A folder that is still being written contains .dng files that are not yet
    /// decodable. The clip must still open — with the documented fallbacks — so
    /// the operator sees a transport rather than an error sheet.
    @Test func undecodableFramesStillProduceAClipWithSaneDefaults() throws {
        let directory = try folder(["p_001.dng", "p_002.dng", "p_003.dng"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DNGSequenceSource(folder: directory)
        #expect(source.formatBadge == "DNG")
        #expect(source.frameCount == 3)
        #expect(source.frameRate == 24)     // documented fallback
        #expect(source.width == 1920)       // documented fallback
        #expect(source.height == 1080)
        #expect(source.startTimecodeText == nil)
    }

    /// The transport seeks by index and clamps late; an out-of-range decode must
    /// answer nil rather than index the array.
    @Test func decodingOutsideTheClipYieldsNil() throws {
        let directory = try folder(["p_001.dng"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DNGSequenceSource(folder: directory)
        #expect(source.copyFrame(at: -1) == nil)
        #expect(source.copyFrame(at: 1) == nil)
        #expect(source.copyFrame(at: 99) == nil)
        // in range but not real image data — nil, not a garbage buffer
        #expect(source.copyFrame(at: 0) == nil)
    }
}
