@preconcurrency import AVFoundation
import Foundation

/// The take's timecode track, all of it: the tc32 format description, the input
/// it needs (added before `startWriting()`, like every other track), the mid-take
/// re-anchors the pipeline reports, and the samples themselves — committed as the
/// take runs, one per fragment interval, with the tail written by `finish()`.
///
/// Split out of TakeWriter and `+Setup`, which had a piece each while the
/// remaining piece sat inside `finish()`. One tc32 sample is four big-endian
/// bytes and a duration; getting that wrong is a file whose timecode reads plausibly
/// and lines up with nothing, so the whole rule now reads in one place.
///
/// **Why the samples are not all written at the end.** They were, and it cost the
/// first recording-integrity rule: `movieFragmentInterval` is set so that a crash
/// or a power loss mid-take does not lose the whole file, and AVAssetWriter will
/// not close a fragment until EVERY input has data past the boundary. A timecode
/// input whose only samples arrive in `finish()` never has any, so no fragment
/// ever closed and an abandoned file was `ftyp` plus one `mdat` with no `moov` at
/// all — measured. The guarantee therefore held only for a take with neither
/// timecode nor audio, which is the case nobody shoots.
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
    ///
    /// The anchors are kept rather than written here, because a sample's duration
    /// runs until the NEXT anchor and nobody knows that yet; `commitTimecodeSamples`
    /// turns them into samples as the picture passes them.
    public func addTimecodeResync(timecode: Timecode, at pts: CMTime) {
        guard startTimecode != nil, sessionStarted, pts > firstPTS,
              tcResyncs.count < 32 else { return }
        // An anchor can only be honoured while its span is still uncommitted.
        // It always is — the cursor lags the frame path by a sample interval and
        // this arrives on the frame that is being processed — but it is
        // stated as a guard rather than assumed, because re-anchoring a span
        // already on disk would need the file rewritten. Monotonic for the same
        // reason: `timecodeBoundary` reads the anchors in order.
        guard pts > tcWrittenUntil,
              pts > (tcResyncs.last?.pts ?? firstPTS) else { return }
        tcResyncs.append((pts: pts, timecode: timecode))
    }

    /// Write every timecode sample whose span the picture has already covered,
    /// and not one more — so the track's data ends up to one sample interval
    /// behind the video's.
    ///
    /// That lag is the whole mechanism: AVAssetWriter closes the fragment at a
    /// boundary once every input has passed it, so the picture written in the
    /// last interval or two of an abandoned take is what a crash costs, instead
    /// of all of it (see this file's header).
    ///
    /// Chunking a continuous run is transparent to a reader. A tc32 sample states
    /// the timecode of its FIRST frame and the frames after it are counted from
    /// there, which is the same arithmetic one sample spanning the whole take
    /// asks for — so a take that never re-anchors reads back exactly as it did
    /// when the track was written in one piece.
    func commitTimecodeSamples(upTo pts: CMTime) {
        guard timecodeInput != nil, startTimecode != nil,
              tcWrittenUntil.isValid else { return }
        while let boundary = timecodeBoundary(after: tcWrittenUntil, notPast: pts) {
            guard let tc = timecodeReading(at: tcWrittenUntil),
                  appendTimecodeSample(timecode: tc, from: tcWrittenUntil,
                                       until: boundary, waitUntil: nil)
            else { return } // refused: offered again on the next frame
            tcWrittenUntil = boundary
        }
    }

    /// The tail, from `finish()`: whatever the live commits could not cover,
    /// through to one frame past the last picture.
    func appendTimecodeTrack() {
        guard timecodeInput != nil, startTimecode != nil, sessionStarted,
              tcWrittenUntil.isValid, lastPTS.isValid else { return }
        let end = CMTimeAdd(lastPTS, frameDuration)
        // the last samples append back to back — wait out the input queue, which
        // is affordable here and is not on the frame path
        let deadline = Date().addingTimeInterval(0.5)
        while tcWrittenUntil < end {
            let boundary = timecodeBoundary(after: tcWrittenUntil,
                                            notPast: end) ?? end
            guard let tc = timecodeReading(at: tcWrittenUntil),
                  appendTimecodeSample(timecode: tc, from: tcWrittenUntil,
                                       until: boundary, waitUntil: deadline)
            else { return }
            tcWrittenUntil = boundary
        }
    }

    /// Where the sample starting at `cursor` has to end: one sample interval
    /// on, or the next re-anchor when it falls sooner. nil until the picture has
    /// reached that end — a sample is never written over time nobody has shot.
    private func timecodeBoundary(after cursor: CMTime,
                                  notPast limit: CMTime) -> CMTime? {
        var boundary = CMTimeAdd(cursor, Self.timecodeSampleInterval)
        if let resync = tcResyncs.first(where: { $0.pts > cursor }),
           resync.pts < boundary {
            boundary = resync.pts
        }
        return boundary <= limit ? boundary : nil
    }

    /// The camera's timecode at `time`: the anchor in force there, advanced by
    /// the frames in between.
    private func timecodeReading(at time: CMTime) -> Timecode? {
        guard let start = startTimecode else { return nil }
        let anchor: (pts: CMTime, timecode: Timecode) =
            tcResyncs.last(where: { $0.pts <= time }) ?? (pts: firstPTS,
                                                          timecode: start)
        let seconds = frameDuration.seconds
        guard seconds > 0 else { return anchor.timecode }
        let frames = Int((CMTimeSubtract(time, anchor.pts).seconds
                          / seconds).rounded())
        return frames > 0 ? anchor.timecode.advanced(by: frames) : anchor.timecode
    }

    /// One tc32 sample covering [from, until). False when the input refused it:
    /// the live path leaves the cursor where it is and offers the same sample on
    /// the next frame rather than waiting on the capture queue, which owns
    /// per-frame work and may not be parked for a four-byte write.
    private func appendTimecodeSample(timecode: Timecode,
                                      from: CMTime, until: CMTime,
                                      waitUntil deadline: Date?) -> Bool {
        guard let input = timecodeInput,
              let formatDescription = timecodeFormatDescription, until > from,
              let sampleBuffer = Self.timecodeSample(
                timecode: timecode, formatDescription: formatDescription,
                from: from, until: until) else { return false }
        if let deadline {
            while !input.isReadyForMoreMediaData, Date() < deadline {
                usleep(1000)
            }
        }
        guard input.isReadyForMoreMediaData else { return false }
        return input.append(sampleBuffer)
    }

    /// The four bytes and their timing, as a sample buffer.
    private static func timecodeSample(
        timecode: Timecode, formatDescription: CMTimeCodeFormatDescription,
        from: CMTime, until: CMTime) -> CMSampleBuffer? {
        // tc32: one big-endian UInt32 with the start frame number
        var frameNumber = UInt32(clamping: timecode.frameNumber).bigEndian
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: 4, flags: 0, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { return nil }
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
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}
