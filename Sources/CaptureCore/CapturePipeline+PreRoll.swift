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
        config.settings.capture.preRollFramesEffective
    }

    /// The memory the pre-roll ring is allowed to hold, ~1.5 GB. A hard
    /// ceiling: see `preRollCapacity` for what it is allowed to shorten.
    static let preRollBudgetBytes = 1_500_000_000

    /// Frames the ring keeps even when a single one is over budget. Guards the
    /// division below rather than any real raster — at 12-bit 8K a frame is
    /// 265 MB and the budget already allows five.
    static let minimumPreRollFrames = 2

    /// Buffer capacity: pre-roll + detection latency + slack, but never more
    /// than the memory budget. Without the cap, 3 s of pre-roll at 4K60 holds
    /// ~6 GB of uncompressed frames in RAM (OOM); at high resolution the
    /// pre-roll quietly shortens.
    ///
    /// **The budget is a ceiling, not one term of a `max()`.** It used to be the
    /// second: `max(startConfirmSpan + 5, budgetFrames)` guaranteed the ring
    /// could always hold the detection latency however big a frame was, on the
    /// reasoning that a ring shorter than that costs the head of every take.
    /// That guarantee was affordable while the deepest capture needed a
    /// deliberate click — an operator who chose 12-bit UHD had agreed to what it
    /// costs. Bit depth follows the signal now, so the same arithmetic can be
    /// reached by a camera changing its output between setups, and it does not
    /// hold: with the taught REC indicator armed the confirm count is multiplied
    /// by the watcher's stride (5 at 25 fps), so a start debounce of 12 asks for
    /// 65 frames, and at 12-bit UHD a record frame is 66 MB — 4.3 GB, pinned, on
    /// a signal nobody selected. At 10-bit the same settings ask for 2.2 GB, so
    /// the floor was already over budget before 12-bit could arrive unannounced;
    /// what changed is who decides.
    ///
    /// So the trade is made the other way, deliberately: a ring shortened below
    /// the detection latency costs the HEAD of one take, and the frames it drops
    /// are counted and shown (`preRollIncomplete`). An allocation three times
    /// the budget costs the session. Recording integrity is the reason the cap
    /// exists at all, and it is the reason it now wins.
    private var preRollCapacity: Int {
        let wanted = preRollFrames + startConfirmSpan + 3
        guard let format, format.width > 0, format.height > 0 else { return wanted }
        // the ring holds what the WRITER gets, so the frame size is the RECORD
        // buffer's — 3 bytes a pixel for 'v210', 4 for BGRA and 'r210', 8 for
        // the 12-bit path's 64RGBALE. Assuming 4 would let a 12-bit UHD pre-roll
        // reach ~3 GB against the budget.
        let bytesPerPixel = recordBakesDisplayBuffer ? 4 : recordBytesPerPixel
        return Self.preRollCapacity(
            wanted: wanted,
            bytesPerFrame: format.width * format.height * bytesPerPixel)
    }

    /// The capacity rule alone, as arithmetic.
    ///
    /// Split from the property that feeds it for the reason `diskVerdict` is:
    /// this half is a rule about two numbers and can be stated exactly, while
    /// the caller's half needs a signal, a converter and a settings blob to say
    /// anything at all. The one case that matters most — 12-bit UHD with a deep
    /// visual-REC confirm, which the app can now be put into without anybody
    /// choosing it — is a shape no synthetic pipeline test can reach, and it is
    /// exactly the shape a wrong answer here is measured in gigabytes of.
    static func preRollCapacity(wanted: Int, bytesPerFrame: Int) -> Int {
        let budgetFrames = preRollBudgetBytes / max(1, bytesPerFrame)
        return max(minimumPreRollFrames, min(wanted, budgetFrames))
    }

    /// How many frames pass between the camera's actual start and the detector
    /// declaring one — the detection latency the ring has to hold.
    ///
    /// For the timecode and VANC machines that is the confirm count itself, one
    /// frame per frame. The taught indicator confirms over the same COUNT but
    /// against frames it has measured, and it measures a few times a second (see
    /// `CapturePipeline+VisualRec`), so its confirm run spans the count times the
    /// watcher's stride. Sized for it while the trigger is armed, and not a frame
    /// larger otherwise: a ring five times deeper costs real memory at UHD and
    /// buys nothing for a trigger nobody switched on.
    private var startConfirmSpan: Int {
        let confirm = config.settings.capture.startDebounceFrames
        guard visualRecArmed else { return confirm }
        return confirm * Self.visualRecStride(atFrameRate: format?.frameRate ?? 25)
    }

    /// while not recording — accumulate frames into the pre-roll buffer (current
    /// frame included): when a take starts, frames from the camera's actual record
    /// start (lost to debounce) plus the configured lead seconds are pulled from it.
    /// buffered AFTER the levels stage — otherwise a take starts with raw
    /// pre-roll frames and jumps in contrast when live leveled frames follow
    func bufferPreRollFrame(_ leveled: LevelledFrame, pts: CMTime) {
        guard writer == nil else { return }
        // the pre-roll must hold what the WRITER gets: the wire-code record
        // buffer when active, but BGRA when a display decision is baked into the
        // recording — beginTake runs applyLUT and the keyer over these frames and
        // a wire format ('r210', 'R12B', 'v210') is not something to hand
        // CoreImage. Armed rather than latched, necessarily: these frames are
        // buffered BEFORE the take that will latch them exists, which is why the
        // bake's arm/latch split has an armed half at all.
        let preRollFrameBuffer = recordBakesDisplayBuffer
            ? leveled.display : (leveled.wireRecord ?? leveled.display)
        preRollBuffer.append(PreRollFrame(index: frameIndex,
                                          pixelBuffer: preRollFrameBuffer,
                                          pts: pts))
        let capacity = preRollCapacity
        if preRollBuffer.count > capacity {
            preRollBuffer.removeFirst(preRollBuffer.count - capacity)
        }
    }

    /// How many frames of the pre-roll window the ring never held — the cost of
    /// the memory ceiling, in frames, so it can be reported instead of inferred.
    ///
    /// The ceiling's whole justification is that "a short ring costs the head of
    /// ONE take and those frames are counted and shown". They were not: eviction
    /// is silent, and `drainPreRoll` only ever counted frames the WRITER refused.
    /// A 12-bit UHD signal shortens the ring to 22 frames against a 100-frame
    /// pre-roll — 3.2 s of head missing from the take, with the operator's only
    /// evidence being the length of the file.
    ///
    /// `cutoff` is floored at frame 1 because that is the first frame index the
    /// pipeline ever issues: the first take of a session legitimately has fewer
    /// frames behind it than the window asks for, and reporting that as a
    /// shortfall would put a notice on screen at the top of every shooting day.
    static func preRollShortfall(startIndex: Int, cutoff: Int,
                                 heldInWindow: Int) -> Int {
        let first = max(1, cutoff)
        guard startIndex >= first else { return 0 }
        return max(0, startIndex - first + 1 - heldInWindow)
    }

    /// The audio ring's hard ceiling, in packets.
    ///
    /// The trim below is a TIME window measured against the OLDEST packet held,
    /// and a window only bounds anything while the clock goes forwards. One
    /// packet stamped in the future makes every later packet look older than
    /// the oldest one, so the trim never fires again and the ring grows for the
    /// rest of the shift — ~60 KB per 40 ms packet at sixteen channels is
    /// ~1.5 MB a second, i.e. gigabytes over a standby that nobody is watching.
    /// The picture ring's memory cap exists for the same reason: a bound a bad
    /// input can switch off is not a bound.
    ///
    /// 1024 is far above anything honest. The settings pane allows 100 frames of
    /// pre-roll, so at the slowest rate the app supports the window is ~5.2 s,
    /// and a USB interface running 512-frame buffers delivers ~94 packets a
    /// second — 481 at the deepest combination the app can be put into.
    static let maximumPreRollAudioPackets = 1024

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
        // …and the ceiling behind the window, for the timestamps the window
        // cannot read (see the constant).
        if preRollAudio.count > Self.maximumPreRollAudioPackets {
            preRollAudio.removeFirst(
                preRollAudio.count - Self.maximumPreRollAudioPackets)
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
        var lostPreRoll = Self.preRollShortfall(
            startIndex: startIndex, cutoff: cutoff,
            heldInWindow: preRollBuffer.filter {
                $0.index >= cutoff && $0.index <= startIndex
            }.count)
        var firstPreRollPTS: CMTime?
        for buffered in preRollBuffer where buffered.index >= cutoff {
            // The head of the take goes through the same bakes its body will,
            // and with the same latched values: a pre-roll that arrived clean
            // while the body is a composite is a cut in the middle of one file.
            var frame = takeLUTRecord
                ? (applyLUT(to: buffered.pixelBuffer, using: takeLUTFilter)
                    ?? buffered.pixelBuffer)
                : buffered.pixelBuffer
            if takeChromaRecord { frame = chromaBaked(frame) }
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
        drainPreRollAudio(into: writer, from: firstPreRollPTS,
                          deadline: drainDeadline)
        // The ring can hold packets from BEFORE a channel-count change while the
        // take latched the count after it, so the head of a take is a place the
        // conform really fires (see `TakeWriter.conformed`). Reported here rather
        // than waiting for the first live packet, which a source that went quiet
        // never sends.
        noteAudioConform(from: writer)
        // Two ways the head of a take goes missing, reported as one number
        // because they cost the operator the same thing. Once the drain budget is
        // spent the rest of the burst is dropped — and those are the frames
        // closest to the camera's REC press, the whole point of pre-roll. The
        // other is the memory ceiling having kept fewer frames than the window
        // asked for (`preRollShortfall`). Silence here reads as a clean head.
        if lostPreRoll > 0 {
            let count = lostPreRoll
            DispatchQueue.main.async {
                self.onError?(.preRollIncomplete(frames: count))
            }
        }
    }

    /// Write the buffered pre-roll audio into a take that has just started,
    /// trimmed with the mask latched for this take. Packets older than the
    /// take's first video frame have nowhere to go and are discarded.
    private func drainPreRollAudio(into writer: TakeWriter, from start: CMTime?,
                                   deadline: Date) {
        defer { preRollAudio.removeAll() }
        guard let start else { return }
        var writtenTo: CMTime?
        for buffered in preRollAudio where buffered.pts >= start {
            var toWrite: CMSampleBuffer? = buffered.buffer
            if let mask = recordingMask {
                toWrite = PCMAudio.selectChannels(buffered.buffer,
                                                  indices: Self.channels(in: mask),
                                                  formatCache: &trimFormatCache)
            }
            guard let toWrite else { continue }
            // Buffered, not live: the whole window arrives in one burst and the
            // audio input refuses most of it unless it is waited for, exactly as
            // the picture burst above is (see `appendBuffered`).
            writer.appendBuffered(audioSampleBuffer: toWrite, deadline: deadline)
            writtenTo = CMTimeAdd(buffered.pts,
                                  CMSampleBufferGetDuration(buffered.buffer))
        }
        // The take's audio already reaches `writtenTo`, so the external source's
        // gap watchdog has to measure from there and not from the take's first
        // VIDEO frame, which is where the pre-roll PICTURE starts. With a
        // pre-roll longer than the starvation threshold the first live frame of
        // every take otherwise looked like a device that had gone quiet: the take
        // was padded with silence back over the sound just written — a DECREASING
        // audio PTS — and then every real packet arriving inside the padded span
        // was refused as an overlap. A take with a working sound cart came out
        // with an invented silent head and "USB audio lost" in the log row post
        // reads. Its own field rather than `lastExternalAudioEnd`, which also
        // arms that overlap guard (see `preRolledAudioEnd`).
        if audioSourceKind == .external { preRolledAudioEnd = writtenTo }
    }
}
