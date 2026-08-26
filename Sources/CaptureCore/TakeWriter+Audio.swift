@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

/// The take's audio track, all of it: the input it needs (added before
/// `startWriting()`, like every other track), the width every packet is
/// conformed to, the two ways a packet reaches it, and the silence that keeps
/// it from holding a fragment shut.
///
/// Split out of `TakeWriter` for the reason `+Timecode` was, and it is the same
/// reason twice: a track's rules belong on one screen, and the class body has a
/// house limit that adding the backstop pushed it over. The stored state stays
/// on the class — Swift keeps stored properties there — and is internal rather
/// than private so this file can reach it, never wider than the module.
///
/// **Why silence is written into a track nothing is feeding.** It is the same
/// trap the timecode track fell into, one input along.
/// `movieFragmentInterval` is set so a crash mid-take does not lose the whole
/// file, and AVAssetWriter closes a fragment only once EVERY input has data
/// past the boundary — so an audio input the source never feeds has none at
/// all, no fragment ever closes, and the abandoned file is `ftyp` plus one
/// `mdat` with no `moov`: measured, AVFoundation -11829 "Cannot Open", "This
/// media may be damaged". The picture is on the disk and nothing describes it.
///
/// The alternative was not opening the input until the first packet arrives,
/// and it does not survive contact with this class: inputs must be added
/// BEFORE `startWriting()` (after it `canAdd` returns false and the file comes
/// out with no audio track at all), so deferring the input means deferring the
/// file, and a take whose audio never arrives would then have nowhere to put
/// its PICTURE. It also contradicts the latch the rest of the audio path is
/// built on — the channel mask and the track's width are fixed at take start,
/// which is what lets a mid-take channel change be conformed instead of fatal.
/// Padding is a claim about the sound; not opening the track is a claim about
/// the picture, and only one of those is recoverable.
extension TakeWriter {
    /// The take's audio track, or nil when the source has no channels or the
    /// writer refuses the input. The format is known up front — PCM 48k/16-bit,
    /// channel count from the pipeline.
    static func addAudioInput(channelCount: Int,
                              to writer: AVAssetWriter) -> AVAssetWriterInput? {
        guard channelCount > 0 else { return nil }
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: Self.audioSettings(channelCount: channelCount))
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return input
    }

    /// PCM audio from the capture board. The input is already created in init (before startWriting).
    public func append(audioSampleBuffer: CMSampleBuffer) {
        guard sessionStarted, let audioInput else { return }
        // A packet landing inside a span this writer has already padded is
        // refused: the file already describes that span, and writing a second
        // sample over it is a take whose sound is doubled where it is least
        // trustworthy. This is the same refusal `admitExternalPacket` makes one
        // level up, for the same reason and against the same kind of cursor.
        //
        // Measured rather than assumed, and the measurement is narrower than
        // the video path's: removing this guard did NOT put the writer into
        // .failed on this host the way a backwards VIDEO PTS does — the take
        // still finished. What it costs is the overlap itself, and the packet
        // going unreported. So it is counted rather than swallowed, because a
        // packet that never reached the file is what that tally is for.
        //
        // The cursor stays `.invalid` unless this writer has actually padded, so
        // a take that is never starved pays one `isValid` test for this.
        if audioPaddedUntil.isValid,
           CMSampleBufferGetPresentationTimeStamp(audioSampleBuffer)
            < audioPaddedUntil {
            droppedAudioPackets += 1
            return
        }
        // A re-shape that could not be built is a packet that never reaches the
        // file, which is what `droppedAudioPackets` counts — silently losing one
        // is the failure this whole path exists to stop.
        guard let packet = conformed(audioSampleBuffer) else {
            droppedAudioPackets += 1
            return
        }
        guard audioInput.isReadyForMoreMediaData else {
            droppedAudioPackets += 1
            return
        }
        // The result is read to move the cursor and for nothing else: a false
        // here has never been counted as a drop (by then the writer is already
        // dead and `hasFailed` is the answer) and still is not, so the tally
        // means exactly what it meant.
        if audioInput.append(packet) { noteAudioWritten(packet) }
    }

    /// Move the audio cursor to the end of a packet that reached the file.
    /// A MAXIMUM rather than an assignment: a source may deliver slightly out
    /// of order, and a cursor that went backwards would pad over sound.
    private func noteAudioWritten(_ packet: CMSampleBuffer) {
        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(packet),
                            CMSampleBufferGetDuration(packet))
        guard end.isNumeric else { return }
        if !audioWrittenUntil.isValid || end > audioWrittenUntil {
            audioWrittenUntil = end
        }
    }

    /// Keep the take's audio track alive under the picture when nothing is
    /// feeding it — the third input that can hold a fragment shut, and the one
    /// left standing after the timecode track was fixed.
    ///
    /// `movieFragmentInterval` releases a fragment only once EVERY input has
    /// data past the boundary. An audio input the source never feeds has none at
    /// all, so no fragment ever closes and an abandoned take is `ftyp` plus one
    /// `mdat` with **no `moov`** — measured, it does not open at all:
    /// AVFoundation -11829 "Cannot Open", "This media may be damaged". That is
    /// not a degraded take, it is the whole file, picture included, for a
    /// declaration the source did not honour.
    /// `CDLCapture.embeddedAudioChannels` is a hard-coded 16 handed to the
    /// pipeline at capture start, so an HDMI camera with its audio switched off
    /// reaches this on every take it ever shoots.
    ///
    /// Here rather than at a caller for the reason `conformed` is here: three
    /// paths reach the audio input, and the rule is about the FILE — the one
    /// place that knows the fragment interval and the latched width is the only
    /// place that can keep it. The shape is the external source's padding loop
    /// one level up (`CapturePipeline.padExternalAudioIfNeeded`): the same 40 ms
    /// chunks, the same cursor, the same per-frame cap.
    func padAudioIfNeeded(upTo pts: CMTime) {
        guard let audioInput, audioTrackChannels > 0,
              audioWrittenUntil.isValid,
              CMTimeSubtract(pts, audioWrittenUntil) > Self.audioStarvationLead
        else { return }
        let chunk = CMTime(value: CMTimeValue(Self.audioPadFrames),
                           timescale: 48_000)
        var padded = 0
        while CMTimeAdd(audioWrittenUntil, chunk) <= pts,
              padded < Self.maximumAudioPadPacketsPerFrame {
            guard audioInput.isReadyForMoreMediaData,
                  let silence = silencePacket(at: audioWrittenUntil),
                  audioInput.append(silence) else { break }
            audioWrittenUntil = CMTimeAdd(audioWrittenUntil, chunk)
            audioPaddedUntil = audioWrittenUntil
            paddedAudioPackets += 1
            padded += 1
        }
        // A gap still left means the cap stopped the loop, not the frame: see
        // `maximumAudioPadPacketsPerFrame` for why the rest is abandoned.
        if padded > 0, CMTimeAdd(audioWrittenUntil, chunk) <= pts {
            audioWrittenUntil = pts
        }
    }

    /// One 40 ms packet of silence at the width the track was OPENED with, so
    /// it needs neither the mask trim nor the conform a real packet gets.
    private func silencePacket(at pts: CMTime) -> CMSampleBuffer? {
        let samples = [Int16](repeating: 0,
                              count: Self.audioPadFrames * audioTrackChannels)
        return samples.withUnsafeBytes { raw -> CMSampleBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return PCMAudio.makeSampleBuffer(
                bytes: base, sampleFrames: Self.audioPadFrames,
                channelCount: audioTrackChannels, ptsSeconds: pts.seconds,
                formatCache: &padFormatCache)
        }
    }

    /// The packet at exactly the width this take's audio track was opened with.
    ///
    /// Enforced HERE, at the one place that knows the latched count, rather than
    /// at the callers: three paths reach the audio input — live packets, the
    /// silence the external-audio watchdog pads with, and the pre-roll drain —
    /// and a guard on any one of them leaves the other two able to put a packet
    /// of the wrong width into the file. The pre-roll one is not hypothetical: a
    /// source that changes its count while the app stands by leaves the ring
    /// holding the OLD width and the take latching the NEW one.
    ///
    /// A mismatched packet is not refused by AVAssetWriter — measured, it is
    /// MISREAD, because interleaved PCM has no framing to disagree with: 1920
    /// frames of two channels are 480 frames of eight. A take whose 8-channel
    /// embed dropped to 2 came out with 0.34 s of sound under 0.68 s of picture,
    /// and nothing anywhere said so.
    ///
    /// **Conformed rather than closing the take, deliberately.** Closing costs the
    /// rest of the shot's PICTURE — the deliverable — for a change in the
    /// reference audio, and a device that renegotiates its count more than once
    /// would turn one setup into a pile of takes each ended by the next
    /// renegotiation. The pipeline already answers "the audio source went away
    /// mid-take" with counted silence instead of a closed take
    /// (`externalAudioPadded`); this is the same trade. What it costs is said out
    /// loud rather than hidden: the channel MAP after the change is a guess —
    /// channel 3 of the new packet need not be the microphone channel 3 of the
    /// old one — so the pipeline raises the sticky alarm and marks the log row.
    private func conformed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let arrived = PCMAudio.channelCount(of: sampleBuffer)
        guard arrived > 0, arrived != audioTrackChannels else { return sampleBuffer }
        conformedAudioPackets += 1
        conformedFromChannels = arrived
        return PCMAudio.conformChannels(sampleBuffer, to: audioTrackChannels,
                                        formatCache: &conformFormatCache)
    }

    /// A buffered (pre-roll) audio packet — the counterpart of
    /// `appendBuffered(pixelBuffer:pts:)` and for the same reason.
    ///
    /// The pre-roll drain hands over a whole window's worth of packets in one
    /// burst, which outruns the audio input exactly as the picture burst outruns
    /// the video one. Offered through `append` they were simply refused and
    /// counted: measured on a 20-frame pre-roll, 15 of a take's ~20 pre-roll
    /// packets were dropped, so "pre-roll carries audio as well as picture" held
    /// for the first fifth of the window and the rest of the take's head was
    /// silent — reported afterwards as "audio packet(s) dropped", which reads
    /// like a busy disk rather than the head of the take.
    ///
    /// The wait shares the video drain's deadline, so the whole drain still costs
    /// the capture queue one bounded stall and not two.
    @discardableResult
    public func appendBuffered(audioSampleBuffer: CMSampleBuffer,
                               deadline: Date) -> Bool {
        guard sessionStarted, let audioInput else { return false }
        while !audioInput.isReadyForMoreMediaData, isWriting,
              Date() < deadline {
            usleep(2000)
        }
        append(audioSampleBuffer: audioSampleBuffer)
        return true
    }
}
