@preconcurrency import CoreMedia
import Foundation

/// The pre-roll ring: what goes into it while the pipeline stands by, how big it
/// is allowed to get, and how it is drained into a take that has just started.
///
/// Split out of `+Frame` (which buffered) and `+Take` (which drained) — one
/// mechanism whose two halves sat in different files, so the capacity rule and
/// the frames it governs were never on screen together. Internal rather than
/// private: the frame path fills the ring and the take path empties it.
extension CapturePipeline {
    /// Pre-roll frame count (a direct frames setting, fps-independent).
    var preRollFrames: Int {
        config.settings.preRollFramesEffective
    }

    /// Buffer capacity: pre-roll + detection latency + slack, but with a memory
    /// cap. Without the cap, 3 s of pre-roll at 4K60 holds ~6 GB of uncompressed
    /// frames in RAM (OOM); at high resolution the pre-roll quietly shortens.
    private var preRollCapacity: Int {
        let wanted = preRollFrames + config.settings.startDebounceFrames + 3
        guard let format, format.width > 0, format.height > 0 else { return wanted }
        // the ring holds what the WRITER gets, so the frame size is the RECORD
        // buffer's — 4 bytes a pixel for BGRA and 'r210', 8 for the 12-bit
        // path's 64RGBALE. Assuming 4 would let a 12-bit UHD pre-roll reach
        // ~3 GB against a 1.5 GB budget.
        let bytesPerPixel = lutRecord ? 4 : recordBytesPerPixel
        let bytesPerFrame = format.width * format.height * bytesPerPixel
        let budgetBytes = 1_500_000_000 // ~1.5 GB
        let byteCap = max(config.settings.startDebounceFrames + 5,
                          budgetBytes / max(1, bytesPerFrame))
        return min(wanted, byteCap)
    }

    /// while not recording — accumulate frames into the pre-roll buffer (current
    /// frame included): when a take starts, frames from the camera's actual record
    /// start (lost to debounce) plus the configured lead seconds are pulled from it.
    /// buffered AFTER the levels stage — otherwise a take starts with raw
    /// pre-roll frames and jumps in contrast when live leveled frames follow
    func bufferPreRollFrame(_ leveled: LevelledFrame, pts: CMTime) {
        guard writer == nil else { return }
        // the pre-roll must hold what the WRITER gets: the wire-code record
        // buffer when active, but BGRA when a LUT is baked into the recording —
        // beginTake runs applyLUT over these frames and a wire format ('r210',
        // 'R12B', 'v210') is not something to hand CoreImage
        let preRollFrameBuffer = lutRecord
            ? leveled.display : (leveled.wireRecord ?? leveled.display)
        preRollBuffer.append(PreRollFrame(index: frameIndex,
                                          pixelBuffer: preRollFrameBuffer,
                                          pts: pts))
        let capacity = preRollCapacity
        if preRollBuffer.count > capacity {
            preRollBuffer.removeFirst(preRollBuffer.count - capacity)
        }
    }

    /// Keep the pre-roll window's audio, trimmed to a little more than the
    /// window itself. Raw packets: the channel mask is latched when the take
    /// starts, so the trim happens at drain time. ~60 KB per 40 ms packet at
    /// 16 channels, so even a long lead costs single-digit megabytes.
    func bufferPreRollAudio(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        preRollAudio.append((pts: pts, buffer: sampleBuffer))
        let fps = format?.frameRate ?? 25
        let window = Double(preRollFrames) / max(1, fps) + 1.0 // slack for jitter
        while let first = preRollAudio.first,
              (pts - first.pts).seconds > window {
            preRollAudio.removeFirst()
        }
    }

    /// pull frames from the buffer from (camera start - pre-roll) to current;
    /// in Rec Run their timecode is frozen at the start value, so the take's
    /// timecode track stays correct
    func drainPreRoll(into writer: TakeWriter, startIndex: Int) {
        let cutoff = max(0, startIndex - preRollFrames)
        // the burst outruns the encoder queue — wait, but within a total
        // budget: unbounded waits stall the pipeline queue while capture
        // callbacks pile up retained 4K frames behind it
        let drainDeadline = Date().addingTimeInterval(1.5)
        var lostPreRoll = 0
        var firstPreRollPTS: CMTime?
        for buffered in preRollBuffer where buffered.index >= cutoff {
            let frame = lutRecord
                ? (applyLUT(to: buffered.pixelBuffer) ?? buffered.pixelBuffer)
                : buffered.pixelBuffer
            if writer.appendBuffered(pixelBuffer: frame, pts: buffered.pts,
                                     deadline: drainDeadline) {
                if firstPreRollPTS == nil { firstPreRollPTS = buffered.pts }
            } else {
                lostPreRoll += 1
            }
        }
        preRollBuffer.removeAll()
        // ...and the sound that goes under those frames. The writer's session
        // starts at the first video PTS above, so anything older than that
        // cannot be placed and is dropped.
        drainPreRollAudio(into: writer, from: firstPreRollPTS)
        // once the drain budget is spent the rest of the burst is dropped —
        // and those are the frames closest to the camera's REC press, the
        // whole point of pre-roll. Silence here reads as a clean head.
        if lostPreRoll > 0 {
            let count = lostPreRoll
            DispatchQueue.main.async {
                self.onError?("Pre-roll incomplete: \(count) frame(s) "
                    + "before the REC point were not written")
            }
        }
    }

    /// Write the buffered pre-roll audio into a take that has just started,
    /// trimmed with the mask latched for this take. Packets older than the
    /// take's first video frame have nowhere to go and are discarded.
    private func drainPreRollAudio(into writer: TakeWriter, from start: CMTime?) {
        defer { preRollAudio.removeAll() }
        guard let start else { return }
        for buffered in preRollAudio where buffered.pts >= start {
            var toWrite: CMSampleBuffer? = buffered.buffer
            if let mask = recordingMask {
                toWrite = PCMAudio.selectChannels(buffered.buffer,
                                                  indices: Self.channels(in: mask),
                                                  formatCache: &trimFormatCache)
            }
            if let toWrite { writer.append(audioSampleBuffer: toWrite) }
        }
    }
}
