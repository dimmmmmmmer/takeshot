@preconcurrency import CoreMedia
import Foundation
import os.log

/// Which timecode the frames and the take carry: the source the frame's TC comes
/// from (RP188 off the wire or LTC decoded out of an audio channel), the LTC
/// decode itself, the pre-roll shift that keeps a take's TC track honest, and the
/// mid-take re-anchor for a camera whose Rec Run started late.
///
/// Split out of `+Frame`, `+Audio` and `+Take`, which had a third of the
/// timecode story each — LTC lived under audio only because its samples arrive
/// as audio. Everything here is internal rather than private: the frame path and
/// the audio path both call in.
extension CapturePipeline {
    /// The frame's timecode as the rest of the pipeline should see it.
    func resolvedTimecode(_ rawTimecode: Timecode?,
                          format: CaptureFormat) -> Timecode? {
        // the bridge may not know the timecode fps — fill it from the format
        var timecode = rawTimecode
        if var tc = timecode, tc.fps <= 0 {
            tc.fps = format.timecodeFPS
            timecode = tc
        }
        // LTC replaces RP188 wholesale when selected (detector, UI, TC track)
        if config.settings.capture.timecodeSource == "ltc" {
            timecode = latestLTC
        }
        return timecode
    }

    /// The file's TC track counts from its FIRST frame — which is pre-roll,
    /// shot before the camera's TC started running. Shift the start TC back
    /// by the pre-roll frames actually written, so the camera-start frame
    /// carries exactly the camera's TC and the take stays sync-accurate
    /// against the camera original.
    func preRollShiftedTimecode(_ rawTimecode: Timecode?,
                                startIndex: Int) -> Timecode? {
        let cutoffPreview = max(0, startIndex - preRollFrames)
        // only the frames written BEFORE the camera-start frame shift the TC —
        // counting the detection-latency frames too made every take a few
        // frames early against the camera original
        let preStartCount = preRollBuffer.filter {
            $0.index >= cutoffPreview && $0.index < startIndex
        }.count
        guard let tc = rawTimecode, preStartCount > 0 else { return rawTimecode }
        let dayFrames = Timecode.dayFrames(fps: tc.fps,
                                           isDropFrame: tc.isDropFrame)
        var shifted = tc.frameNumber - preStartCount
        if shifted < 0 { shifted += dayFrames } // wrap across midnight
        return Timecode(frameNumber: shifted,
                        fps: tc.fps, isDropFrame: tc.isDropFrame)
    }

    /// Rec Run started AFTER the take: while the camera TC stands still the
    /// file's TC track keeps counting, so the overlap would drift by the
    /// frozen duration. Re-anchor the track the moment the TC starts moving.
    func resyncTimecodeIfRunStarted(timecode: Timecode?, pts: CMTime) {
        if let writer, let tc = timecode {
            if let previous = lastWireTimecode {
                if tc.frameNumber == previous.frameNumber {
                    frozenTCStreak += 1
                } else {
                    if frozenTCStreak >= 3 {
                        writer.addTimecodeResync(timecode: tc, at: pts)
                        os_log("TC resync mid-take: %{public}s (frozen %d frames)",
                               log: Self.levelsLog, type: .default,
                               tc.description, frozenTCStreak)
                    }
                    frozenTCStreak = 0
                }
            }
            lastWireTimecode = tc
        } else if writer == nil {
            lastWireTimecode = timecode
            frozenTCStreak = 0
        }
    }

    /// LTC (SMPTE 12M) off one embedded audio channel, when it is the selected
    /// timecode source.
    func decodeLTC(from sampleBuffer: CMSampleBuffer, channels: Int) {
        guard channels > 0, let format else { return }
        let channel = min(max(0, config.settings.capture.ltcChannel ?? 0), channels - 1)
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
            let pointer, length >= 2 else { return }
        let fps = format.timecodeFPS
        pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
            let frames = (length / 2) / channels
            guard frames > 0 else { return }
            // extract the selected channel from the interleaved stream
            var mono = [Int16](repeating: 0, count: frames)
            for i in 0..<frames {
                mono[i] = samples[i * channels + channel]
            }
            mono.withUnsafeBufferPointer { buffer in
                if let tc = ltcDecoder.process(samples: buffer, fps: fps) {
                    latestLTC = tc
                }
            }
        }
    }
}
