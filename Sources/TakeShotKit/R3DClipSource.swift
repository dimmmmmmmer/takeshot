import CR3D
import CaptureCore
import CoreVideo
import Foundation

/// RED R3D via the CR3D bridge.
///
/// In its own file rather than beside BRAW and CinemaDNG in `RawClipSource`
/// because two things here belong to nothing else: the colour note the viewer
/// shows (R3D is the only format in this app whose decoder chooses a colour
/// space) and the spanning-file rule (an R3D clip can be a hundred files).
struct R3DSource: RawClipSource, @unchecked Sendable {
    let formatBadge = "R3D"
    private let clip: CR3DClip
    let frameCount: Int
    let frameRate: Double
    let timecodeFrameRate: Double
    /// The CLIP's raster, not the decode's: an operator asking "what is this
    /// clip" means 8K even when the viewer is being fed a quarter of it. The
    /// reduction is reported separately, in `colorNote`.
    let width: Int
    let height: Int
    let startTimecodeText: String?
    let colorNote: RawColorNote?
    /// Camera-reported facts, already assembled into the lines the badge shows.
    /// The app had no notion of camera metadata before this; keeping the
    /// assembly here means nothing downstream has to learn R3D's vocabulary.
    let infoLines: [String]

    var lastDecodeError: String? { clip.lastDecodeError }

    init(url: URL, scale: R3DDecodeScale, applyCameraLUT: Bool) throws {
        clip = try CR3DClip(path: url.path,
                            scale: Self.bridgeScale(scale),
                            applyCameraLUT: applyCameraLUT)
        frameCount = Int(clip.frameCount)
        frameRate = Double(clip.frameRate) > 0 ? Double(clip.frameRate) : 24
        timecodeFrameRate = Double(clip.timecodeFrameRate) > 0
            ? Double(clip.timecodeFrameRate) : frameRate
        width = Int(clip.width)
        height = Int(clip.height)
        // Absolute (time-of-day) rather than edge: it is the track that lines up
        // with the RP188 this app records off the wire, so a take and an R3D of
        // the same moment read the same. Edge TC is reported in `cameraLines`.
        startTimecodeText = clip.startTimecode
        colorNote = RawColorNote(transform: clip.outputTransformName,
                                 pipeline: clip.colorPipelineName,
                                 scaleDivisor: Int(clip.scaleDivisor),
                                 cameraLUTName: clip.cameraLUTName,
                                 cameraLUTApplied: clip.cameraLUTApplied)
        infoLines = Self.cameraLines(of: clip)
    }

    func copyFrame(at index: Int) -> CVPixelBuffer? {
        clip.copyFrame(at: UInt64(index))
    }

    private static func bridgeScale(_ scale: R3DDecodeScale) -> CR3DDecodeScale {
        switch scale {
        case .auto: return .auto
        case .full: return .full
        case .half: return .half
        case .quarter: return .quarter
        case .eighth: return .eighth
        }
    }

    private static func cameraLines(of clip: CR3DClip) -> [String] {
        var lines: [String] = []
        // Camera and sensor read as one fact, and the sensor is the interesting
        // half when two bodies share a model name.
        let body = [clip.cameraModel, clip.sensorName]
            .compactMap { $0 }.joined(separator: " · ")
        if !body.isEmpty { lines.append(body) }
        if let reel = clip.reelID {
            lines.append(clip.clipID.map { "\(reel) / \($0)" } ?? reel)
        }
        if let redcode = clip.redcodeFormat { lines.append(redcode) }
        if let lens = clip.lensName { lines.append(lens) }
        if clip.iso > 0 {
            var exposure = "ISO \(clip.iso)"
            if clip.kelvin > 0 {
                exposure += " · \(Int(clip.kelvin.rounded()))K"
                // Tint is only worth a line when someone moved it.
                if abs(clip.tint) >= 0.5 {
                    exposure += String(format: " · tint %+.1f", clip.tint)
                }
            }
            lines.append(exposure)
        }
        if let edge = clip.startEdgeTimecode, edge != clip.startTimecode {
            lines.append(L("r3d_edge_tc") + " " + edge)
        }
        return lines
    }
}

extension R3DSource {
    /// Whether an .r3d file is a continuation of a clip that starts elsewhere.
    ///
    /// A RED clip over 4 GB is written as A001_C001_0101XX_001.R3D, _002.R3D …
    /// _999.R3D, and only the first part is a clip — `Clip::LoadFrom` pulls the
    /// rest in itself. Without this, one 8K take fills the panel with a hundred
    /// rows that all open the same footage, and the folder scan keeps rescanning
    /// while any of them is still being copied.
    ///
    /// Deliberately filename arithmetic, with no SDK call in it: it has to work
    /// in a build made without RED's SDK (which is what CI and a public release
    /// are), and it must never hide a file whose `_001` sibling is absent —
    /// footage that does not fit the convention is still footage.
    ///
    /// Nikon's single-file R3D NE clips (DSC_0001.R3D) are untouched: their
    /// suffix is four digits, not three.
    static func isContinuationPart(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "r3d" else { return false }
        let base = url.deletingPathExtension().lastPathComponent
        guard let separator = base.lastIndex(of: "_") else { return false }
        let suffix = base[base.index(after: separator)...]
        guard suffix.count == 3, suffix.allSatisfy(\.isNumber), suffix != "001"
        else { return false }
        let head = base[..<separator] + "_001"
        let folder = url.deletingLastPathComponent()
        // The camera writes .R3D; a copy through a case-preserving tool may not.
        return ["R3D", "r3d"].contains { extensionCase in
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("\(head).\(extensionCase)")
                    .path)
        }
    }
}
