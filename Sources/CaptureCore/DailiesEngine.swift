@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

/// Editorial/review dailies from finished takes: each ProRes .mov is
/// transcoded to a small H.264 .mp4 with the burn-ins composited per frame.
///
/// The shape of the queue, which is the contract the UI and the tests hold it
/// to:
///
/// - **FIFO, one at a time.** Dailies are a background courtesy; two encodes
///   at once would just split the machine the next take needs.
/// - **A failed item is marked and skipped.** One unreadable take must never
///   cost the other thirty their dailies.
/// - **Recording wins, always.** While the app records, the queue holds
///   between frames (`DailiesControl.setPaused`) and resumes when the take
///   ends — a daily must never compete with `TakeWriter` for the disk or the
///   encoder. The sources are finished files; recordings are never touched.
/// - **Cancel is safe.** Stop deletes the partial output — a half-written
///   daily that plays until it stops is worse than no daily.
///
/// `async` rather than a blocking queue like `OffloadEngine`: the media setup
/// is AVFoundation's async loading, and the pause gate is a suspension, not a
/// parked thread. The app runs it in a utility-priority task.
public enum DailiesEngine {
    /// Longest edge of a daily. Sources above 1080p are downscaled to fit;
    /// smaller sources keep their size (upscaling buys nothing).
    static let maxSize = CGSize(width: 1920, height: 1080)
    /// H.264 rate at full 1080p, scaled by area for other sizes: enough for
    /// review and small enough to mail.
    static let bitsPerSecondAt1080p = 10_000_000

    /// Run the queue to completion (or to Stop) and report every item.
    public static func run(
        items: [DailiesItem], burnins: DailiesBurnins, into folder: URL,
        control: DailiesControl = DailiesControl(),
        progress: @escaping @Sendable (DailiesProgress) -> Void = { _ in })
        async -> DailiesReport {
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
        } catch {
            // No destination — nothing can run, and every item says why.
            return DailiesReport(items: items.map {
                DailiesItemResult(source: $0.source,
                                  failure: error.localizedDescription)
            }, wasCancelled: false)
        }
        var results: [DailiesItemResult] = []
        for (index, item) in items.enumerated() {
            guard !control.isCancelled else {
                // Everything not reached is cancelled, not silently absent —
                // the report's length always matches the queue's.
                results.append(contentsOf: items[index...].map {
                    DailiesItemResult(source: $0.source, wasCancelled: true)
                })
                break
            }
            let transcode = DailiesTranscode(
                item: item, index: index, count: items.count,
                burnins: burnins, folder: folder, control: control,
                publish: progress)
            results.append(await transcode.run())
        }
        // Cancel only counts if it cut the run short (the offload's rule):
        // Stop pressed as the last frame lands still means every daily exists.
        let stoppedShort = results.contains { $0.wasCancelled }
        return DailiesReport(items: results,
                             wasCancelled: control.isCancelled && stoppedShort)
    }

    // MARK: - the encode parameters (pure, unit-tested)

    /// Output raster: fit into 1080p preserving aspect, never upscale, and
    /// keep dimensions even — H.264 4:2:0 subsampling needs them, and an odd
    /// edge makes some encoders refuse the session outright.
    public static func outputSize(for natural: CGSize) -> CGSize {
        let width = abs(natural.width)
        let height = abs(natural.height)
        guard width > 0, height > 0 else { return maxSize }
        let scale = min(1, min(maxSize.width / width, maxSize.height / height))
        return CGSize(width: even(width * scale), height: even(height * scale))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, CGFloat(Int(value / 2) * 2))
    }

    /// H.264 settings for the daily: bitrate scaled by area from the 1080p
    /// anchor so a downscaled or small-raster source is not drowned in bits.
    static func videoSettings(size: CGSize, frameRate: Double) -> [String: Any] {
        let areaFraction = size.width * size.height
            / (maxSize.width * maxSize.height)
        let bitrate = max(1_000_000,
                          Int(Double(bitsPerSecondAt1080p) * areaFraction))
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey:
                    Int(max(1, frameRate.rounded())),
            ],
        ]
    }

    /// AAC stereo for every daily, whatever the take recorded: editorial
    /// players choke on 16 discrete channels, and the reader downmixes the
    /// embed to the pair on the way past.
    static func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
    }

    /// What the reader decodes the take's PCM into: the writer's AAC input.
    static func audioReadSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// The timecode the burn-in runs on: every anchor of the file's timecode
    /// track (a mid-take Rec Run re-anchor stays frame-accurate), else the
    /// take's remembered start TC, else a zero clock — a daily with a running
    /// counter beats one with an empty strip.
    static func timeline(for asset: AVAsset, item: DailiesItem,
                         frameRate: Double) async -> DailiesTimeline {
        let anchors = await TimecodeReader.timelineAnchors(of: asset)
        if !anchors.isEmpty {
            return DailiesTimeline(anchors: anchors, frameRate: frameRate)
        }
        let start = item.startTimecode ?? Timecode(
            frameNumber: 0, fps: Int(max(1, frameRate.rounded())))
        return DailiesTimeline(
            anchors: [DailiesTimeline.Anchor(seconds: 0, timecode: start)],
            frameRate: frameRate)
    }
}
