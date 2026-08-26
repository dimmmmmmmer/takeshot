@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

/// The per-frame path, in the order the stages run: levels → 10-bit split →
/// pre-roll → LUT → detector → writer → scopes → preview. This file is that
/// order plus the two decisions the frame makes about the take (does the
/// detector start or stop one, and what happens when the writer refuses a
/// frame); each stage's own workings live in the domain file named for it —
/// `+Levels`, `+LUT`, `+PreRoll`, `+Timecode`, `+Compare`, `+Preview`.
///
/// The order is load bearing — the pre-roll buffers what the WRITER would get,
/// the writer's frame is decided before the detector can start a take on this
/// same frame, and the scope/preview hops leave the capture queue at the end.
///
/// Everything here runs on `queue`, synchronously.
///
/// Split out of CapturePipeline, which had grown past 1300 lines.
extension CapturePipeline {
    // MARK: - processing (on queue)

    func processFrame(pixelBuffer: CVPixelBuffer, pts: CMTime,
                      timecode rawTimecode: Timecode?, vancTrigger: VancTrigger?,
                      ancillaryPackets: [AncillaryPacket],
                      colorimetry: WireColorimetry = .sdr) {
        guard let format else { return }
        adoptColorimetry(colorimetry)
        tagColorIfUntagged(pixelBuffer)
        frameIndex += 1
        updateVancStats(ancillaryPackets)
        let vancTrigger = vancTrigger ?? VancParser.recTrigger(in: ancillaryPackets)
        let timecode = resolvedTimecode(rawTimecode, format: format)
        lastTimecode = timecode
        // external (USB) audio: the frame path owns the stream clock, so it
        // pins the host→stream anchor and keeps a starving take padded
        anchorExternalClock(framePTS: pts)
        padExternalAudioIfNeeded(upTo: pts)

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
        analyzeScopes(wire: leveled.scopeSource, display: products.display)
        // Beside the scopes because it is the same kind of thing: a read-only
        // measurement offered to another queue at a few hertz, after the writer
        // has already been served. Handed the PRE-LUT display buffer — the stage
        // the operator's references were captured from, so a viewing LUT cannot
        // move a take (see `+VisualRec`).
        watchVisualRec(leveled.display)
        serveFrameGrab(record: products.record, leveled: leveled.display)
        presentProcessedFrame(products.display, preLUT: leveled.display)
        DispatchQueue.main.async { self.onTimecode?(timecode) }
    }

    /// Run the REC state machine for this frame. True when a take STARTED on
    /// it — the current frame has already been written out of the pre-roll
    /// buffer and must not be appended a second time.
    private func runDetector(timecode: Timecode?,
                             vancTrigger: VancTrigger?) -> Bool {
        let mode = config.settings.capture.detectionMode
        // The taught indicator is ORTHOGONAL to the mode: it composes with all
        // four rather than being a fifth. That is why it is read before the mode
        // is consulted — including in Manual, where the operator has said "no
        // inference from the signal" about VANC and timecode and has separately
        // armed a box on the picture. With nothing armed the latch is nil and
        // this is the code that shipped, line for line.
        let visualRec = latchedVisualRecReading()
        guard mode != .manual || visualRec != nil else { return false }
        // .vanc is enforced inside the detector (vancOnly): TC is passed
        // through so the take still records its start timecode. Manual starves
        // the timecode machine instead — the `.noData` row starts nothing while
        // idle, so the indicator is the only trigger left in that mode.
        let sample = FrameSample(
            index: frameIndex,
            timecode: mode == .manual ? nil : timecode,
            vancTrigger: mode.actsOnVancTrigger ? vancTrigger : nil,
            visualRec: visualRec)
        guard let event = detector.process(sample) else { return false }
        switch event {
        case .started(let atIndex, let startTC):
            beginTake(timecode: startTC ?? timecode, recStartIndex: atIndex,
                      trigger: detector.activeTrigger ?? .manual)
            return true // current frame already written from the buffer
        case .stopped:
            finishTake()
            return false
        }
    }

    /// Hand the frame to the writer, and turn a refusal into either a closed
    /// take or a drop count.
    private func appendToTake(_ recordBuffer: CVPixelBuffer, pts: CMTime) {
        guard let writer else { return }
        if writer.append(pixelBuffer: recordBuffer, pts: pts) {
            // That call may have padded the take's own audio track to keep a
            // fragment from staying shut (`TakeWriter.padAudioIfNeeded`). The
            // writer has no callbacks, so the alarm is raised from here — the
            // same split the conform has, and it costs an accepted frame one
            // integer comparison.
            noteAudioPadding(from: writer)
            return
        }
        if writer.hasFailed {
            // permanent: the volume went away, the disk filled, the encoder
            // died. Counting drops here would keep REC red for the rest of
            // the take while nothing at all reaches the file.
            let reason = writer.failureReason
            finishTake() // clears the writer, so this branch fires once
            DispatchQueue.main.async {
                self.onError?(.takeLostWriterFailed(reason: reason))
            }
        } else {
            droppedFrames += 1
            let inTake = droppedFrames
            noteHealth {
                $0.droppedVideoFramesInTake = inTake
                $0.droppedVideoFramesTotal += 1
            }
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
                    self.onError?(.recordingFramesDropped(count: count))
                }
            }
        }
    }

    /// scopes: analyzed OFF the pipeline queue (content-dependent cost —
    /// noisy frames measured two orders slower than flat ones); if the
    /// previous pass is still running the frame is simply skipped
    ///
    /// The cadence is a target RATE, not a frame count: a pass costs ~14 ms at
    /// 1080p now (it was 123 on noisy content), so a fixed "every third frame"
    /// throttled the scopes to a quarter of what the analyzer can do at every
    /// frame rate. `scopeBusy` remains the real regulator — latest-wins, and
    /// expensive content simply lands fewer passes.
    ///
    /// `wire` is the untouched 10-bit frame when the source has one (see
    /// `LevelledFrame.scopeSource`), and it is what the scopes read: the
    /// display buffer is 8-bit and has already had the excursions clipped out
    /// of it. Chosen INSIDE the guards on purpose — with no scope surface open
    /// this function still costs nothing at all, which is the property
    /// `closedScopesAnalyzeNothing` pins, and the only thing it ever adds to
    /// the capture queue is one buffer retain.
    private func analyzeScopes(wire: ScopeSourceFrame?,
                               display: CVPixelBuffer) {
        guard scopesEnabled, !scopeBusy else { return }
        let stride = Self.scopeStride(atFrameRate: format?.frameRate ?? 25)
        guard frameIndex - lastScopeFrame >= stride else { return }
        lastScopeFrame = frameIndex
        scopeBusy = true
        let frame = wire?.buffer ?? display // retained: the pool won't recycle it
        let levels = wire?.levels ?? .full
        // the display buffer has already been tone mapped, so only a WIRE frame
        // is still in the source's own transfer — reading nits off the other
        // one would be measuring this app's tone map instead of the camera
        let colorimetry = wire?.colorimetry ?? .sdr
        let region = scopeRegion
        scopeQueue.async { [weak self] in
            let data = ScopeAnalyzer.analyze(frame, region: region,
                                             wireLevels: levels,
                                             colorimetry: colorimetry)
            guard let pipeline = self else { return }
            pipeline.queue.async { pipeline.scopeBusy = false }
            if let data {
                let report = pipeline.onScopeData
                DispatchQueue.main.async { report?(data) }
            }
        }
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
}
