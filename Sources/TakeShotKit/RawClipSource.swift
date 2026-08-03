import CBraw
import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import QuartzCore

/// What the operator is looking at, for a format that develops its own colour.
///
/// The app told nobody a colour space before R3D arrived: every other source
/// either IS Rec.709 on the wire or was already developed to it. R3D is the
/// first one where the decoder had a real choice, so the choice is stated rather
/// than left for someone to infer from the picture — including the fact that the
/// clip may carry a look which is deliberately not being shown.
struct RawColorNote: Sendable, Equatable {
    /// What the decoded pixels are, e.g. "Rec.709 / BT.1886".
    let transform: String
    /// The vendor pipeline that produced them, e.g. "IPP2".
    let pipeline: String
    /// 1, 2, 4 or 8 — the decode reduction actually in use.
    let scaleDivisor: Int
    /// The clip's in-camera creative LUT, when it carries one.
    let cameraLUTName: String?
    let cameraLUTApplied: Bool

    /// What the operator is told, one line per fact, in the order they ask them:
    /// what am I looking at, at what resolution, and is a look involved.
    ///
    /// Here rather than in the badge that renders it so it can be checked
    /// without a clip — there is no way to synthesize an .r3d, and "the viewer
    /// says which colour space it is showing" is exactly the promise that must
    /// not quietly rot.
    var operatorLines: [String] {
        var lines = ["\(L("raw_color_showing")) \(transform) (\(pipeline))"]
        if scaleDivisor > 1 {
            lines.append(String(format: L("raw_decode_scale"), scaleDivisor))
        }
        if let cameraLUTName {
            lines.append(String(
                format: L(cameraLUTApplied
                    ? "raw_camera_lut_applied" : "raw_camera_lut_skipped"),
                cameraLUTName))
        }
        return lines
    }
}

/// A decodable RAW clip: BRAW file, CinemaDNG folder, R3D. Decode is blocking;
/// the player calls it off the main thread.
protocol RawClipSource: Sendable {
    var formatBadge: String { get } // "BRAW" / "DNG" / "R3D" in the transport
    var frameCount: Int { get }
    var frameRate: Double { get }
    /// Rate the clip's TIMECODE track runs at, which is not always the video
    /// rate — R3D halves it above 30 fps, so a running timecode extrapolated at
    /// the video rate would run twice as fast as the camera's.
    var timecodeFrameRate: Double { get }
    var width: Int { get }
    var height: Int { get }
    var startTimecodeText: String? { get }
    /// nil when there is nothing to say beyond the codec badge.
    var colorNote: RawColorNote? { get }
    /// Camera-reported facts, already worded — reel, body, REDCODE, exposure.
    /// Empty for a format that carries none.
    var infoLines: [String] { get }
    func copyFrame(at index: Int) -> CVPixelBuffer?
    /// Why the last `copyFrame` returned nil. Read after it did, on the same
    /// thread that called it.
    var lastDecodeError: String? { get }
}

extension RawClipSource {
    var timecodeFrameRate: Double { frameRate }
    var colorNote: RawColorNote? { nil }
    var infoLines: [String] { [] }
    var lastDecodeError: String? { nil }
}

/// Blackmagic RAW via the CBraw bridge.
struct BRAWSource: RawClipSource, @unchecked Sendable {
    let formatBadge = "BRAW"
    private let clip: CBRClip
    let frameCount: Int
    let frameRate: Double
    let width: Int
    let height: Int
    let startTimecodeText: String?

    init(url: URL) throws {
        clip = try CBRClip(path: url.path)
        frameCount = Int(clip.frameCount)
        frameRate = Double(clip.frameRate) > 0 ? Double(clip.frameRate) : 24
        width = Int(clip.width)
        height = Int(clip.height)
        startTimecodeText = clip.startTimecode
    }

    func copyFrame(at index: Int) -> CVPixelBuffer? {
        clip.copyFrame(at: UInt64(index))
    }
}

/// CinemaDNG: a folder of .dng frames, decoded through CIRAWFilter and
/// rendered into Rec.709 code values — the same convention every other
/// surface in the app draws.
struct DNGSequenceSource: RawClipSource, @unchecked Sendable {
    let formatBadge = "DNG"
    // decodes arrive from the play loop AND from seek's detached task — the
    // pool rebuild inside PixelBufferPool is not thread-safe
    private let decodeQueue = DispatchQueue(label: "takeshot.dng.decode")
    private let frames: [URL]
    let frameCount: Int
    let frameRate: Double
    let width: Int
    let height: Int
    let startTimecodeText: String? = nil
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool = PixelBufferPool()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)

    enum DNGError: LocalizedError {
        case empty
        var errorDescription: String? { "No DNG frames in the folder" }
    }

    static func frameURLs(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent.localizedStandardCompare(
                $1.lastPathComponent) == .orderedAscending }
    }

    init(folder: URL) throws {
        frames = Self.frameURLs(in: folder)
        guard !frames.isEmpty else { throw DNGError.empty }
        frameCount = frames.count
        // frame rate from the CinemaDNG tag when present, else 24
        var fps = 24.0
        var size = CGSize(width: 1920, height: 1080)
        if let source = CGImageSourceCreateWithURL(frames[0] as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
               as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                size = CGSize(width: w, height: h)
            }
            if let dng = props[kCGImagePropertyDNGDictionary] as? [CFString: Any],
               let rate = dng["FrameRate" as CFString] as? Double, rate > 0 {
                fps = rate
            }
        }
        frameRate = fps
        width = Int(size.width)
        height = Int(size.height)
    }

    func copyFrame(at index: Int) -> CVPixelBuffer? {
        decodeQueue.sync { decodeFrame(at: index) }
    }

    private func decodeFrame(at index: Int) -> CVPixelBuffer? {
        guard frames.indices.contains(index) else { return nil }
        let url = frames[index]
        var image: CIImage?
        if let filter = CIRAWFilter(imageURL: url) {
            image = filter.outputImage
        }
        if image == nil, // not a camera RAW ImageIO can develop — plain decode
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            image = CIImage(cgImage: cg)
        }
        guard let image else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              let buffer = pool.buffer(width: Int(extent.width),
                                       height: Int(extent.height))
        else { return nil }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        // develop into Rec.709 code values (unmanaged everywhere after this)
        destination.colorSpace = Self.colorSpace
        guard let task = try? context.startTask(
            toRender: image.transformed(by: CGAffineTransform(
                translationX: -extent.minX, y: -extent.minY)),
            to: destination) else { return nil }
        _ = try? task.waitUntilCompleted()
        return buffer
    }
}
