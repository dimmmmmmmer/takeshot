@preconcurrency import AVFoundation
import Foundation

/// The take's timecode track, all of it: the tc32 format description, the input
/// it needs (added before `startWriting()`, like every other track), the mid-take
/// re-anchors the pipeline reports, and the samples themselves — written at the
/// end, because the last anchor's duration is only known then.
///
/// Split out of TakeWriter and `+Setup`, which had a piece each while the
/// remaining piece sat inside `finish()`. One tc32 sample is four big-endian
/// bytes and a duration; getting that wrong is a file whose timecode reads plausibly
/// and lines up with nothing, so the whole rule now reads in one place.
extension TakeWriter {
    /// The take's timecode track, or nil when the source gave us no timecode to
    /// anchor it to. One tc32 sample covers the whole take unless the camera's
    /// Rec Run started mid-take, in which case each anchor gets its own.
    static func addTimecodeInput(
        formatDescription: CMTimeCodeFormatDescription?,
        to writer: AVAssetWriter) -> AVAssetWriterInput? {
        guard let formatDescription else { return nil }
        let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil,
                                       sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        return input
    }

    /// The tc32 format description for the take's timecode track, or nil when
    /// the take has no start timecode and gets no track at all.
    static func makeTimecodeFormatDescription(
        startTimecode: Timecode?,
        format: CaptureFormat) throws -> CMTimeCodeFormatDescription? {
        guard let tc = startTimecode else { return nil }
        var fdesc: CMTimeCodeFormatDescription?
        let status = CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: Self.frameDuration(at: format.frameRate),
            frameQuanta: UInt32(tc.fps),
            flags: tc.isDropFrame ? kCMTimeCodeFlag_DropFrame | kCMTimeCodeFlag_24HourMax
                                  : kCMTimeCodeFlag_24HourMax,
            extensions: nil,
            formatDescriptionOut: &fdesc)
        guard status == noErr, let fdesc else { throw WriterError.timecodeTrackFailed }
        return fdesc
    }

    /// A timecode re-anchor mid-take: the camera's Rec Run TC stood still when
    /// the take started and began running at `timecode` on the frame at `pts` —
    /// an extra tc32 sample from that frame keeps the file frame-accurate
    /// against the camera original in the overlapping region.
    public func addTimecodeResync(timecode: Timecode, at pts: CMTime) {
        guard startTimecode != nil, sessionStarted, pts > firstPTS,
              tcResyncs.count < 32 else { return }
        tcResyncs.append((pts: pts, timecode: timecode))
    }

    /// Write the track, from `finish()`: the start TC, then any re-anchor that
    /// falls inside the take, each sample lasting until the next one starts.
    func appendTimecodeTrack() {
        guard let timecodeInput, let fdesc = timecodeFormatDescription,
              let tc = startTimecode, sessionStarted else { return }
        let end = CMTimeAdd(lastPTS, frameDuration)
        var anchors: [(pts: CMTime, timecode: Timecode)] = [(firstPTS, tc)]
        anchors.append(contentsOf: tcResyncs.filter {
            $0.pts > firstPTS && $0.pts < end
        })
        for (index, anchor) in anchors.enumerated() {
            let next = index + 1 < anchors.count ? anchors[index + 1].pts : end
            appendTimecodeSample(input: timecodeInput, formatDescription: fdesc,
                                 timecode: anchor.timecode,
                                 from: anchor.pts, until: next)
        }
    }

    /// One tc32 sample covering [from, until).
    private func appendTimecodeSample(input: AVAssetWriterInput,
                                      formatDescription: CMTimeCodeFormatDescription,
                                      timecode: Timecode,
                                      from: CMTime, until: CMTime) {
        // tc32: one big-endian UInt32 with the start frame number
        var frameNumber = UInt32(clamping: timecode.frameNumber).bigEndian
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: 4, flags: 0, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { return }
        withUnsafeBytes(of: &frameNumber) { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: 4)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTimeSubtract(until, from),
            presentationTimeStamp: from,
            decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return }
        // several anchors append back to back — wait out the input queue
        let deadline = Date().addingTimeInterval(0.5)
        while !input.isReadyForMoreMediaData, Date() < deadline {
            usleep(1000)
        }
        input.append(sampleBuffer)
    }
}
