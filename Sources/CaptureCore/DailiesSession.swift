@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

/// Why one dailies item stopped early. Cancel covers both Stop and Skip —
/// the difference is which items after this one still run, and that is the
/// queue's decision, not the item's.
enum DailiesAbort: Error {
    case cancelled
    case failed(String)
}

/// What the probe learned about one source before anything opens: the tracks,
/// the rates, the raster the daily will be, and the timecode timeline the
/// burn-in runs on. Gathered in one async pass so the session opener and the
/// composer are both synchronous over settled facts.
struct DailiesSourceFacts {
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    let audioTracks: [AVAssetTrack]
    /// The VIDEO rate (23.976, 25…), which also paces the TC clock.
    let frameRate: Double
    /// For the progress bar; the loop itself just reads until the file ends.
    let framesTotal: Int
    let outputSize: CGSize
    /// nil — the timecode burn-in is off and no clock is computed at all.
    let timeline: DailiesTimeline?

    static func probe(item: DailiesItem,
                      burnins: DailiesBurnins) async throws -> DailiesSourceFacts {
        let asset = AVURLAsset(url: item.source)
        guard let track = try? await asset.tracks(ofType: .video).first else {
            throw DailiesAbort.failed(
                "no video track: \(item.source.lastPathComponent)")
        }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let nominalRate = (try? await track.load(.nominalFrameRate)) ?? 0
        // 25 as the last resort only: a rate of 0 would freeze the TC clock.
        let frameRate = nominalRate > 0 ? Double(nominalRate) : 25
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        return DailiesSourceFacts(
            asset: asset, videoTrack: track,
            audioTracks: (try? await asset.tracks(ofType: .audio)) ?? [],
            frameRate: frameRate,
            framesTotal: max(1, Int((duration * frameRate).rounded())),
            outputSize: DailiesEngine.outputSize(for: naturalSize),
            timeline: burnins.timecode
                ? await DailiesEngine.timeline(for: asset, item: item,
                                               frameRate: frameRate) : nil)
    }
}

/// Everything one open transcode holds: the reader, the writer and their
/// track ends. Grouped so the frame loop's helpers take one parameter, and
/// so cleanup can reach both from any failure point.
struct DailiesSession {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOutput: AVAssetReaderTrackOutput
    let audioOutput: AVAssetReaderOutput?
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let adaptor: AVAssetWriterInputPixelBufferAdaptor

    /// Open the whole rig against an already-reserved output URL (the caller
    /// holds the reservation so it can clean up whatever happens here).
    static func open(at url: URL, facts: DailiesSourceFacts) throws
        -> DailiesSession {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: facts.asset)
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw DailiesAbort.failed(error.localizedDescription)
        }
        let (videoOutput, audioOutput) = try addOutputs(facts: facts,
                                                        to: reader)
        let (videoInput, adaptor) = addVideoInput(facts: facts, to: writer)
        let audioInput = audioOutput != nil ? addAudioInput(to: writer) : nil
        // moov up front: a daily gets dropped into review players and file
        // shares, where a streamable file starts playing before it finishes
        // copying.
        writer.shouldOptimizeForNetworkUse = true
        guard writer.startWriting() else {
            throw DailiesAbort.failed(failure(of: writer))
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw DailiesAbort.failed(reader.error?.localizedDescription
                ?? "cannot read: \(facts.asset.url.lastPathComponent)")
        }
        return DailiesSession(reader: reader, writer: writer,
                              videoOutput: videoOutput,
                              audioOutput: audioOutput,
                              videoInput: videoInput, audioInput: audioInput,
                              adaptor: adaptor)
    }

    /// The reader's two ends: video decoded to BGRA (so CoreGraphics can
    /// composite the strips directly), audio downmixed to the stereo pair.
    /// A take whose audio cannot be read still gets its picture — a silent
    /// daily beats no daily, and the failure modes there are exotic layouts,
    /// not footage problems.
    private static func addOutputs(facts: DailiesSourceFacts,
                                   to reader: AVAssetReader) throws
        -> (video: AVAssetReaderTrackOutput, audio: AVAssetReaderOutput?) {
        let video = AVAssetReaderTrackOutput(
            track: facts.videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
            ])
        guard reader.canAdd(video) else {
            throw DailiesAbort.failed(
                "cannot decode: \(facts.asset.url.lastPathComponent)")
        }
        reader.add(video)
        guard !facts.audioTracks.isEmpty else { return (video, nil) }
        let audio = AVAssetReaderAudioMixOutput(
            audioTracks: facts.audioTracks,
            audioSettings: DailiesEngine.audioReadSettings())
        guard reader.canAdd(audio) else { return (video, nil) }
        reader.add(audio)
        return (video, audio)
    }

    /// The writer's picture end: H.264 at the daily raster, fed through a
    /// pixel-buffer adaptor.
    private static func addVideoInput(facts: DailiesSourceFacts,
                                      to writer: AVAssetWriter)
        -> (input: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: DailiesEngine.videoSettings(
                size: facts.outputSize, frameRate: facts.frameRate))
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video, sourcePixelBufferAttributes: nil)
        writer.add(video)
        return (video, adaptor)
    }

    /// The writer's sound end: AAC stereo, only when the reader has audio to
    /// feed it — an empty audio track helps nobody.
    private static func addAudioInput(to writer: AVAssetWriter)
        -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: DailiesEngine.audioSettings())
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        return input
    }

    static func failure(of writer: AVAssetWriter) -> String {
        writer.error?.localizedDescription
            ?? "writer failed (status \(writer.status.rawValue))"
    }
}
