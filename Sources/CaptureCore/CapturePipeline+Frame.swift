@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import os.log

/// The per-frame path, in the order the stages run: levels → 10-bit split →
/// pre-roll → LUT → detector → writer → scopes → preview. Every stage below is
/// a step of `processFrame` and nothing else calls them; they run on `queue`,
/// synchronously, exactly where the inline code used to sit.
///
/// The order is load bearing — the pre-roll buffers what the WRITER would get,
/// the writer's frame is decided before the detector can start a take on this
/// same frame, and the scope/preview hops leave the capture queue at the end.
///
/// Split out of CapturePipeline, which had grown past 1300 lines.
extension CapturePipeline {
    /// One frame after the levels stage: the 8-bit BGRA buffer everything
    /// downstream reads, plus the precompensated 10-bit record buffer when the
    /// wire carried r210 (nil for every other format).
    struct LevelledFrame {
        let display: CVPixelBuffer
        let tenBitRecord: CVPixelBuffer?
    }

    /// What the LUT stage hands on: `display` feeds preview, scopes and grabs,
    /// `record` goes to the writer.
    struct FrameProducts {
        let display: CVPixelBuffer
        let record: CVPixelBuffer
    }

    // MARK: - processing (on queue)

    func processFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                      timecode rawTimecode: Timecode?, vancTrigger: VancTrigger?,
                      ancillaryPackets: [AncillaryPacket]) {
        guard let format else { return }
        tagColorIfUntagged(pixelBuffer)
        frameIndex += 1
        updateVancStats(ancillaryPackets)
        let vancTrigger = vancTrigger ?? VancParser.recTrigger(in: ancillaryPackets)
        let timecode = resolvedTimecode(rawTimecode, format: format)
        lastTimecode = timecode

        guard let leveled = levelledFrame(from: pixelBuffer, format: format)
        else { return }
        bufferPreRollFrame(leveled, pts: pts)
        let products = lutApplied(to: leveled)

        let startedThisFrame = runDetector(timecode: timecode,
                                           vancTrigger: vancTrigger)
        resyncTimecodeIfRunStarted(timecode: timecode, pts: pts)
        if !startedThisFrame {
            appendToTake(products.record, pts: pts)
        }
        analyzeScopes(of: products.display)
        serveFrameGrab(record: products.record, leveled: leveled.display)
        presentProcessedFrame(products.display)
        DispatchQueue.main.async { self.onTimecode?(timecode) }
    }

    /// The frame's timecode as the rest of the pipeline should see it.
    private func resolvedTimecode(_ rawTimecode: Timecode?,
                                  format: CaptureFormat) -> Timecode? {
        // the bridge may not know the timecode fps — fill it from the format
        var timecode = rawTimecode
        if var tc = timecode, tc.fps <= 0 {
            tc.fps = format.timecodeFPS
            timecode = tc
        }
        // LTC replaces RP188 wholesale when selected (detector, UI, TC track)
        if config.settings.timecodeSource == "ltc" {
            timecode = latestLTC
        }
        return timecode
    }

    /// The levels decision for this frame, logged whenever it changes.
    ///
    /// input levels: the setting states what the SOURCE carries on the wire.
    /// "limited" (16-235 RGB) is expanded once to the full-range BGRA the
    /// rest of the pipeline assumes; "full" passes through untouched (e.g.
    /// a playout device already set to Full output levels). auto (nil)
    /// assumes limited for RGB 4:4:4 HDMI (CTA-861 default). Conversion to
    /// legal-range YUV in the recorded file is the encoder's job — never
    /// done on pixels here, so it can't be applied twice.
    private func effectiveInputLevels(for format: CaptureFormat) -> String? {
        let inputLevels = levelsMode ?? (format.isRGB444 ? "limited" : nil)
        // one log line per decision change — settles "is expansion active" without
        // guessing (a stale-settings app instance once recorded an unexpanded take)
        if lastLoggedLevels != (inputLevels ?? "passthrough") {
            lastLoggedLevels = inputLevels ?? "passthrough"
            os_log("levels: mode=%{public}s rgb444=%{public}d effective=%{public}s",
                   log: Self.levelsLog, type: .default,
                   levelsMode ?? "auto", format.isRGB444 ? 1 : 0,
                   inputLevels ?? "passthrough")
        }
        return inputLevels
    }

    /// Levels and, for a 10-bit wire, the split into display + record buffers.
    /// nil means the converter could not produce a frame and this one is
    /// dropped — the same `guard` the inline code had.
    private func levelledFrame(from pixelBuffer: CVPixelBuffer,
                               format: CaptureFormat) -> LevelledFrame? {
        let inputLevels = effectiveInputLevels(for: format)
        // 10-bit RGB wire ('r210'): one pass yields the full-range display
        // BGRA AND the precompensated 10-bit record buffer; levels are applied
        // inside the converter, so the 8-bit stage below must not run again
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == TenBitConverter.r210 {
            tenBitConverter.setLimitedRange(inputLevels != "full")
            guard let split = tenBitConverter.convert(pixelBuffer) else { return nil }
            tagColorIfUntagged(split.display)
            return LevelledFrame(display: split.display, tenBitRecord: split.record)
        }
        let leveled = inputLevels == "limited"
            ? (expandLimitedRGB(pixelBuffer) ?? pixelBuffer)
            : pixelBuffer
        return LevelledFrame(display: leveled, tenBitRecord: nil)
    }

    /// while not recording — accumulate frames into the pre-roll buffer (current
    /// frame included): when a take starts, frames from the camera's actual record
    /// start (lost to debounce) plus the configured lead seconds are pulled from it.
    /// buffered AFTER the levels stage — otherwise a take starts with raw
    /// pre-roll frames and jumps in contrast when live leveled frames follow
    private func bufferPreRollFrame(_ leveled: LevelledFrame, pts: CMTime) {
        guard writer == nil else { return }
        // the pre-roll must hold what the WRITER gets: 10-bit when active,
        // but BGRA when a LUT is baked into the recording — beginTake runs
        // applyLUT over these frames and CoreImage cannot read r210
        let preRollFrameBuffer = lutRecord
            ? leveled.display : (leveled.tenBitRecord ?? leveled.display)
        preRollBuffer.append(PreRollFrame(index: frameIndex,
                                          pixelBuffer: preRollFrameBuffer,
                                          pts: pts))
        let capacity = preRollCapacity
        if preRollBuffer.count > capacity {
            preRollBuffer.removeFirst(preRollBuffer.count - capacity)
        }
    }

    /// LUT: preview may have the LUT while recording stays clean (or vice versa)
    private func lutApplied(to leveled: LevelledFrame) -> FrameProducts {
        let display = leveled.display
        let displayBuffer = lutPreview
            ? (applyLUT(to: display) ?? display) : display
        // LUT baking is an 8-bit creative decision — it keeps the BGRA record
        // path; otherwise the 10-bit record buffer goes to the writer verbatim
        let recordBuffer = lutRecord
            ? (lutPreview ? displayBuffer : (applyLUT(to: display) ?? display))
            : (leveled.tenBitRecord ?? display)
        return FrameProducts(display: displayBuffer, record: recordBuffer)
    }

    /// Run the REC state machine for this frame. True when a take STARTED on
    /// it — the current frame has already been written out of the pre-roll
    /// buffer and must not be appended a second time.
    private func runDetector(timecode: Timecode?,
                             vancTrigger: VancTrigger?) -> Bool {
        let mode = config.settings.detectionMode
        guard mode != .manual else { return false }
        // .vanc is enforced inside the detector (vancOnly): TC is passed
        // through so the take still records its start timecode
        let sample = FrameSample(
            index: frameIndex,
            timecode: timecode,
            vancTrigger: (mode == .auto || mode == .vanc) ? vancTrigger : nil)
        guard let event = detector.process(sample) else { return false }
        switch event {
        case .started(let atIndex, let startTC):
            beginTake(timecode: startTC ?? timecode, recStartIndex: atIndex)
            return true // current frame already written from the buffer
        case .stopped:
            finishTake()
            return false
        }
    }

    /// Rec Run started AFTER the take: while the camera TC stands still the
    /// file's TC track keeps counting, so the overlap would drift by the
    /// frozen duration. Re-anchor the track the moment the TC starts moving.
    private func resyncTimecodeIfRunStarted(timecode: Timecode?, pts: CMTime) {
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

    /// Hand the frame to the writer, and turn a refusal into either a closed
    /// take or a drop count.
    private func appendToTake(_ recordBuffer: CVPixelBuffer, pts: CMTime) {
        guard let writer,
              !writer.append(pixelBuffer: recordBuffer, pts: pts) else { return }
        if writer.hasFailed {
            // permanent: the volume went away, the disk filled, the encoder
            // died. Counting drops here would keep REC red for the rest of
            // the take while nothing at all reaches the file.
            let reason = writer.failureReason
            finishTake() // clears the writer, so this branch fires once
            DispatchQueue.main.async {
                self.onError?("TAKE LOST — recording stopped, writer failed: \(reason)")
            }
        } else {
            droppedFrames += 1
            // The encoder is still swallowing the pre-roll burst when the
            // first live frame arrives, so virtually every take drops one
            // frame. Alarming on that trains the operator to ignore the
            // banner — which is the one thing a real disk failure needs.
            // Sustained loss still alarms, and the take's total is reported
            // when it closes either way.
            if droppedFrames == Self.droppedFrameAlarmThreshold
                || droppedFrames % 100 == 0 {
                let count = droppedFrames
                DispatchQueue.main.async {
                    self.onError?("Dropped \(count) recording frame(s) "
                        + "— encoder/disk can't keep up")
                }
            }
        }
    }

    /// scopes: analyzed OFF the pipeline queue (content-dependent cost —
    /// noisy frames measured two orders slower than flat ones); if the
    /// previous pass is still running the frame is simply skipped
    private func analyzeScopes(of displayBuffer: CVPixelBuffer) {
        guard scopesEnabled, frameIndex % 3 == 0, !scopeBusy else { return }
        scopeBusy = true
        let frame = displayBuffer // retained: the pool won't recycle it
        scopeQueue.async { [weak self] in
            let data = ScopeAnalyzer.analyze(frame)
            guard let pipeline = self else { return }
            pipeline.queue.async { pipeline.scopeBusy = false }
            if let data {
                let report = pipeline.onScopeData
                DispatchQueue.main.async { report?(data) }
            }
        }
    }

    /// one-shot frame grab: stills are deliverables like the recording — the
    /// preview LUT is never baked in, only a look that is being recorded
    private func serveFrameGrab(record recordBuffer: CVPixelBuffer,
                                leveled: CVPixelBuffer) {
        guard let grab = frameGrabHandler else { return }
        frameGrabHandler = nil
        // the clean 8-bit frame: CI can't read r210, and the record look
        // without a baked LUT IS the leveled frame
        let png = Self.pngData(from: lutRecord ? recordBuffer : leveled,
                               ciContext: ciContext)
        DispatchQueue.main.async { grab(png) }
    }

    /// pinned reference compare — on screen only (scopes/stills/the
    /// compare-provider frame stay clean)
    private func presentProcessedFrame(_ displayBuffer: CVPixelBuffer) {
        var screenBuffer = displayBuffer
        if let reference = previewReference {
            if case .off = previewCompare {} else {
                screenBuffer = compositeReference(reference, over: displayBuffer)
                    ?? displayBuffer
            }
        }
        enqueuePreview(pixelBuffer: displayBuffer, screen: screenBuffer)
    }

    private func updateVancStats(_ packets: [AncillaryPacket]) {
        for packet in packets {
            let key = String(format: "%02X/%02X", packet.did, packet.sdid)
            let previous = rawVancStats[key]
            rawVancStats[key] = RawVancStat(
                did: packet.did, sdid: packet.sdid,
                count: (previous?.count ?? 0) + 1,
                lastLine: packet.lineNumber,
                lastData: Data(packet.data.prefix(24)))
            vancStatsDirty = true
        }
        // publish at most ~once a second so we don't poke the UI every frame
        let interval = Int(format?.frameRate.rounded() ?? 25)
        if vancStatsDirty, frameIndex - vancStatsLastPublish >= interval {
            vancStatsDirty = false
            vancStatsLastPublish = frameIndex
            let stats = rawVancStats.values.map { raw in
                VancPacketStat(
                    did: raw.did, sdid: raw.sdid, count: raw.count,
                    lastLine: raw.lastLine,
                    lastDataHex: raw.lastData
                        .map { String(format: "%02X", $0) }
                        .joined(separator: " "))
            }.sorted { $0.key < $1.key }
            DispatchQueue.main.async { self.onVancStats?(stats) }
        }
    }

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
        let bytesPerFrame = format.width * format.height * 4
        let budgetBytes = 1_500_000_000 // ~1.5 GB
        let byteCap = max(config.settings.startDebounceFrames + 5,
                          budgetBytes / max(1, bytesPerFrame))
        return min(wanted, byteCap)
    }
}
