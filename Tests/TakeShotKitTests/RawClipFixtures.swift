import AppKit
import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

// A CinemaDNG clip the RAW engine can really play.
//
// Every RAW fixture the suites had before this one was a folder of files that
// FAILED to decode — enough for `RawPlayerModel.init` to accept the folder and
// for the transport arithmetic to be measured, and nothing else. So the whole
// decode/present loop, the scope path hanging off it and the loop points were
// unreachable, and the one arm that DID run was the error arm nobody had asked
// for.
//
// What makes a playable one possible without checking a camera clip in:
// `DNGSequenceSource.decodeFrame` develops each frame through `CIRAWFilter`
// with a plain ImageIO decode behind it, and CIRAWFilter opens anything ImageIO
// opens. A PNG under a `.dng` name is therefore a frame this player really
// decodes, renders into a pixel buffer and shows — measured, not assumed.
//
// Frames are told apart by a PATTERN and not by a level. Each frame is painted
// with (index + 1) white columns on black, so a test can say WHICH picture is
// on screen rather than only that one arrived — which is what makes an
// off-by-one between the playhead and the decoded frame visible. Levels would
// not survive the trip: the develop converts sRGB to Rec.709 and moves a flat
// grey by up to eleven codes, while black stays 0 and white stays 255.
enum RawClipFixtures {
    /// Frame side, in pixels. Small enough that a whole clip decodes in
    /// milliseconds and large enough to hold more columns than any test here
    /// has frames.
    static let side = 32

    /// A CinemaDNG clip of `frames` decodable frames inside `root`.
    ///
    /// `brokenAt` replaces that one frame with bytes no decoder will open —
    /// the corrupt block, or the card going away mid-clip, that the player has
    /// to tell the operator about instead of quietly looking like the end.
    ///
    /// `brokenFrom` breaks that frame AND every frame after it, and exists
    /// because the play loop deliberately SKIPS frames it cannot keep up with
    /// (`RawPlayback+PlayLoop`: `startFrame + Int(elapsed * fps) + 1`). A test
    /// that breaks exactly one frame is therefore asking the machine to land on
    /// it in real time, and a loaded one steps straight over it — which is how
    /// `playingAgainClearsTheLastFailure` came to pass here every time and fail
    /// on CI. Breaking a RUN asks the question the test means: does a decode
    /// failure reach the operator.
    @discardableResult
    static func clip(frames: Int, in root: URL,
                     named name: String = "clip.dng-sequence",
                     brokenAt broken: Int? = nil,
                     brokenFrom: Int? = nil) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        for index in 0..<frames {
            let url = folder.appendingPathComponent(
                String(format: "frame_%06d.dng", index + 1))
            if index == broken || (brokenFrom.map { index >= $0 } ?? false) {
                try Data("not a frame".utf8).write(to: url)
            } else {
                try frame(columns: index + 1).write(to: url)
            }
        }
        return folder
    }

    /// One frame as PNG bytes: `columns` white columns from the left edge,
    /// black after them.
    private static func frame(columns: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: side * 3, bitsPerPixel: 24))
        // The rep's backing store arrives uninitialized, so every byte is
        // written rather than only the bright ones.
        let bytes = try #require(rep.bitmapData)
        for y in 0..<side {
            for x in 0..<side {
                let value: UInt8 = x < columns ? 255 : 0
                let offset = y * side * 3 + x * 3
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
            }
        }
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Which frame of the fixture a presented buffer is, or nil when the
    /// picture is not one of ours. The inverse of `frame(columns:)`.
    static func frameIndex(of buffer: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.assumingMemoryBound(to: UInt8.self) + (height / 2) * rowBytes
        var bright = 0
        for x in 0..<width where Int(row[x * 4 + 1]) > 128 { bright += 1 }
        return bright > 0 ? bright - 1 : nil
    }

    /// Every frame the engine presented, in order. `setOnDisplayFrame` fires on
    /// the decode task, so the storage is locked rather than main-actor bound.
    final class Presented: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Int] = []

        var count: Int { lock.withLock { frames.count } }
        var all: [Int] { lock.withLock { frames } }
        var last: Int? { lock.withLock { frames.last } }

        func record(_ buffer: CVPixelBuffer) {
            guard let index = RawClipFixtures.frameIndex(of: buffer) else { return }
            lock.withLock { frames.append(index) }
        }
    }

    /// What the engine toasted about the clip, in order.
    final class Toasts: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []

        var all: [String] { lock.withLock { texts } }
        func record(_ text: String) { lock.withLock { texts.append(text) } }
    }

    /// A player on a fresh clip, with the presented frames already collected.
    ///
    /// `setOnDisplayFrame` rather than a `MetalPreviewLayer` sink: the mirror
    /// slot sees exactly the frames the surfaces see (`RawPlayerModel.present`
    /// feeds both from one line) and needs no window.
    @MainActor
    static func player(frames: Int, in root: URL,
                       brokenAt broken: Int? = nil,
                       brokenFrom: Int? = nil) throws
        -> (model: RawPlayerModel, presented: Presented) {
        let folder = try clip(frames: frames, in: root, brokenAt: broken,
                              brokenFrom: brokenFrom)
        var error: String?
        let model = try #require(RawPlayerModel(url: folder, error: &error),
                                 "the engine refused a DNG folder: \(error ?? "-")")
        let presented = Presented()
        model.setOnDisplayFrame { presented.record($0[.decorated]) }
        return (model, presented)
    }
}
