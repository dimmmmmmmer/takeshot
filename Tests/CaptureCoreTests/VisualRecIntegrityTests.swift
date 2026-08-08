import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The rule the whole feature is built around: the taught REC indicator is
/// ANALYSIS. It decides when a take starts and it reaches the recorded file, the
/// still grab, the scopes' measurement and the phone camera grid nowhere at all.
///
/// The same shape as `ChromaKeyIntegrityTests` and for the same reason: the only
/// convincing proof is a real ProRes encode with the pixels read back out. A take
/// rolled by a box on the picture must be the take the camera sent — and it must
/// be indistinguishable in the file from one the operator started by hand,
/// because post has no way to know which fired and no business caring.
struct VisualRecIntegrityTests {
    /// The raster the recording cases work at: small enough to encode in real
    /// time, big enough that the taught box is tens of pixels across.
    private static let width = 320
    private static let height = 180

    private func rollingFrame() -> CVPixelBuffer {
        VisualRecProbe.frame([VisualRecProbe.dot],
                             width: Self.width, height: Self.height)
    }

    private func idleFrame() -> CVPixelBuffer {
        VisualRecProbe.frame(width: Self.width, height: Self.height)
    }

    /// A pipeline that records, on a scratch folder of its own, with the
    /// PRODUCTION detection default — VANC-only, whose timecode machine is off.
    /// So a take that starts in these tests was started by the indicator and by
    /// nothing else, even though the fixture's timecode runs the whole time.
    private func recordingPipeline(root: URL) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.destinationPath = root.path
        settings.detectionMode = .vanc
        settings.preRollFrames = 0
        settings.codec = .proResProxy  // the suite encodes in real time
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                    takeNumber: 1))
        // asked of the pipeline rather than left in the settings blob: the
        // levels stage reads `setVideoLevels`, so a `videoLevels` field on a
        // config the pipeline was constructed with would do nothing at all
        pipeline.setVideoLevels("full") // pass the fixture's codes through
        pipeline.handleFormat(CaptureFormat(width: Self.width, height: Self.height,
                                           frameRate: 25, timecodeFPS: 25,
                                           name: "1080p25"))
        return pipeline
    }

    private func teaching() -> VisualRecTeaching {
        VisualRecProbe.taught(rolling: rollingFrame(), idle: idleFrame())
    }

    /// Drive the pipeline until the watcher has latched a reading of `expected`,
    /// pushing `buffer` at the live pace, and then a few frames MORE.
    ///
    /// The extra frames are the point rather than slack. The reading is latched
    /// off the capture queue and the detector reads the latch on the NEXT frame,
    /// so a run that stops the instant the reading flips has produced the
    /// evidence and given the state machine nothing to act on it with — which is
    /// exactly how the app behaves, and exactly why the watcher's latency is
    /// covered by the pre-roll rather than pretended away.
    ///
    /// The wait polls for the outcome rather than counting on a wall-clock
    /// window: the pass runs at utility QoS and a loaded machine schedules it
    /// when it feels like it.
    private func drive(_ driver: SignalDriver, _ pipeline: CapturePipeline,
                       buffer: CVPixelBuffer, from start: Timecode,
                       until expected: VisualRecReading?,
                       then extra: Int = 5,
                       limit: Int = 60) async throws -> Timecode {
        var timecode = start
        var seen = false
        for _ in 0..<limit {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: buffer)
            if pipeline.visualRecReading == expected { seen = true; break }
        }
        guard seen else { return timecode }
        for _ in 0..<extra {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: buffer)
        }
        return timecode
    }

    // MARK: - the file

    /// A take the indicator rolled, decoded: the camera's picture, dot and all,
    /// and no trace of the box that was watching it.
    @Test func aTakeTheIndicatorRolledIsThePictureTheCameraSent() async throws {
        let root = TestMedia.scratchDirectory("VisualRecTake")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setVisualRec(teaching())
        let takes = TakeCollector()
        pipeline.onTakeFinished = { takes.append($0) }

        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        // idle first, so the latch has said "not rolling" before the dot appears
        timecode = try await drive(driver, pipeline, buffer: idleFrame(),
                                   from: timecode, until: .idle)
        #expect(!pipeline.health.isRecording, "a take started on the idle picture")
        // …then the indicator lights and the take opens on it
        timecode = try await drive(driver, pipeline, buffer: rollingFrame(),
                                   from: timecode, until: .rolling)
        await TestWait.until { pipeline.health.isRecording }
        #expect(pipeline.health.isRecording, "the indicator never rolled a take")
        #expect(pipeline.health.startTrigger == .visual,
                "started by \(String(describing: pipeline.health.startTrigger))")

        for _ in 0..<12 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: rollingFrame())
        }
        // the dot goes away and the take closes on it
        _ = try await drive(driver, pipeline, buffer: idleFrame(),
                            from: timecode, until: .idle)
        await TestWait.untilWritten { takes.first != nil }

        let take = try #require(takes.first, "the take never finished")
        await TestWait.fileExists(at: take.url)
        let frame = try #require(await ChromaProbe.firstFrame(of: take.url),
                                 "the take decoded no frames")
        // the indicator is in the picture because the camera sent it there…
        let indicator = Self.pixel(of: frame, atX: VisualRecProbe.indicatorX,
                                   y: VisualRecProbe.indicatorY)
        #expect(indicator.r > 150 && indicator.g < 110,
                "the take does not hold the camera's own overlay: \(indicator)")
        // …and nothing else is: no box outline, no marker, nothing drawn
        let flat = VisualRecProbe.background
        for (x, y) in [(0.5, 0.5), (0.2, 0.8), (0.9, 0.9)] {
            let sampled = Self.pixel(of: frame, atX: x, y: y)
            #expect(abs(sampled.r - Int(flat.r)) < 20
                    && abs(sampled.g - Int(flat.g)) < 20
                    && abs(sampled.b - Int(flat.b)) < 20,
                    "something was drawn at \(x),\(y): \(sampled)")
        }
    }

    /// The take is indistinguishable in the file from one started by hand.
    ///
    /// Both takes are made on this host from the same synthetic frames through
    /// the same encoder, so the comparison is take against take and says nothing
    /// about which macOS release is running it — which is the trap two suites in
    /// this repo already fell into.
    @Test func aTakeStartedByTheIndicatorMatchesAManualOne() async throws {
        let root = TestMedia.scratchDirectory("VisualRecParity")
        defer { try? FileManager.default.removeItem(at: root) }
        let manual = try await recordByHand(in: root)
        let visual = try await recordByIndicator(in: root)

        await TestWait.fileExists(at: manual.url)
        await TestWait.fileExists(at: visual.url)
        let manualShape = try await Self.shape(of: manual.url)
        let visualShape = try await Self.shape(of: visual.url)
        #expect(manualShape == visualShape,
                "the files differ: \(manualShape) vs \(visualShape)")

        // and the pixels, at the three places that could carry a difference
        let manualFrame = try #require(await ChromaProbe.firstFrame(of: manual.url))
        let visualFrame = try #require(await ChromaProbe.firstFrame(of: visual.url))
        for (x, y) in [(VisualRecProbe.indicatorX, VisualRecProbe.indicatorY),
                       (0.5, 0.5), (0.1, 0.9)] {
            let byHand = Self.pixel(of: manualFrame, atX: x, y: y)
            let byBox = Self.pixel(of: visualFrame, atX: x, y: y)
            #expect(abs(byHand.r - byBox.r) <= 2 && abs(byHand.g - byBox.g) <= 2
                    && abs(byHand.b - byBox.b) <= 2,
                    "at \(x),\(y): by hand \(byHand), by the box \(byBox)")
        }
    }

    /// The same fourteen frames, recorded by pressing REC.
    ///
    /// The frames BEFORE the take opens are part of the fixture rather than
    /// padding, and both halves of that matter: a take pressed before the first
    /// frame of a session has no timecode to start from and gets no timecode
    /// track, and every take opens by draining the pre-roll ring — so the frame
    /// the file BEGINS with is the last one pushed before the take did. Comparing
    /// an idle first frame against a rolling one would be comparing the two
    /// setups rather than the two triggers.
    private func recordByHand(in root: URL) async throws -> Take {
        let pipeline = recordingPipeline(root: root)
        let takes = TakeCollector()
        pipeline.onTakeFinished = { takes.append($0) }
        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        for index in 0..<5 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(
                timecode, pixelBuffer: index == 4 ? rollingFrame() : idleFrame())
        }
        pipeline.toggleManualRecord()
        for _ in 0..<14 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: rollingFrame())
        }
        pipeline.toggleManualRecord()
        await TestWait.untilWritten { takes.first != nil }
        #expect(pipeline.health.startTrigger == .manual)
        return try #require(takes.first, "the manual take never finished")
    }

    /// …and by the indicator lighting up and going away again.
    private func recordByIndicator(in root: URL) async throws -> Take {
        let pipeline = recordingPipeline(root: root)
        pipeline.setVisualRec(teaching())
        let takes = TakeCollector()
        pipeline.onTakeFinished = { takes.append($0) }
        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        timecode = try await drive(driver, pipeline, buffer: idleFrame(),
                                   from: timecode, until: .idle)
        timecode = try await drive(driver, pipeline, buffer: rollingFrame(),
                                   from: timecode, until: .rolling)
        await TestWait.until { pipeline.health.isRecording }
        for _ in 0..<14 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: rollingFrame())
        }
        _ = try await drive(driver, pipeline, buffer: idleFrame(),
                            from: timecode, until: .idle)
        await TestWait.untilWritten { takes.first != nil }
        #expect(pipeline.health.startTrigger == .visual)
        return try #require(takes.first, "the visual take never finished")
    }

    // MARK: - the other deliverables

    /// The still grab is a deliverable and comes off the frame before anything
    /// display-side runs, so an armed trigger cannot be in it.
    @Test func aGrabTakenWhileTheTriggerIsArmedHoldsThePicture() async throws {
        let root = TestMedia.scratchDirectory("VisualRecGrab")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setVisualRec(teaching())
        let grabs = EventCollector<Data?>()
        pipeline.grabNextFrame { grabs.append($0) }

        let source = rollingFrame()
        for index in 1...6 {
            PreviewProbe.push(pipeline, source, frame: index)
        }
        await TestWait.until { !grabs.isEmpty }

        let png = try #require(grabs.first ?? nil, "no PNG came back")
        let pixel = try #require(
            ChromaProbe.pixel(inPNG: png, atFractionX: 0.5),
            "the grab could not be decoded")
        // the flat middle of the fixture, untouched: nothing was drawn on it
        let flat = VisualRecProbe.background
        #expect(abs(pixel.r - Int(flat.r)) < 25
                && abs(pixel.g - Int(flat.g)) < 25
                && abs(pixel.b - Int(flat.b)) < 25,
                "something reached the grab: \(pixel)")
    }

    /// The frames published for the compare provider and for the scopes are the
    /// very buffers the pipeline produced — an armed trigger copies nothing and
    /// alters nothing on the way past.
    @Test func theTriggerNeverTouchesAFrameOnItsWay() async throws {
        let root = TestMedia.scratchDirectory("VisualRecClean")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setVisualRec(teaching())
        let source = rollingFrame()
        for index in 1...6 {
            PreviewProbe.push(pipeline, source, frame: index)
        }
        await TestWait.until { pipeline.currentPreviewBuffer() != nil }

        let clean = try #require(pipeline.currentPreviewBuffer())
        let preLUT = try #require(pipeline.currentPreLUTPreviewBuffer())
        // the display path passes the fixture straight through with no LUT, so
        // both must be the SAME OBJECT the frame path produced
        #expect(clean === preLUT, "the trigger forked the display frame")
        let pixel = PreviewProbe.level(of: clean, atFractionX: 0.5, channel: 2)
        #expect(abs(pixel - 60) < 25, "the frame was altered: \(pixel)")
    }

    // MARK: - reading the file back

    /// What a take's video track IS, for a comparison that does not care which
    /// encoder release wrote it: codec, raster, nominal rate, whether it carries
    /// a timecode track, and the levels key the RGB record path stamps.
    private static func shape(of url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let timecodes = try await asset.loadTracks(withMediaType: .timecode)
        let track = try #require(video.first, "no video track")
        let descriptions = try await track.load(.formatDescriptions)
        let format = try #require(descriptions.first)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        let metadata = try await asset.load(.metadata)
        let levelsItem = metadata.first {
            $0.key as? String == TakeWriter.levelsKey
        }
        let levels = try await levelsItem?.load(.stringValue) ?? "none"
        return "\(CMFormatDescriptionGetMediaSubType(format)) "
            + "\(size.width)x\(size.height) "
            + "tc:\(timecodes.count) levels:\(levels)"
    }

    /// The pixel at a fraction across and down a decoded BGRA frame.
    ///
    /// `ChromaProbe.Pixel` rather than a triple, for the reason that type exists:
    /// three anonymous Ints in a row is how channels get swapped, and it is what
    /// the chroma suites already read frames back into.
    private static func pixel(of buffer: CVPixelBuffer, atX fractionX: Double,
                              y fractionY: Double) -> ChromaProbe.Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return ChromaProbe.Pixel(r: -1, g: -1, b: -1)
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x = min(width - 1, max(0, Int(fractionX * Double(width))))
        let y = min(height - 1, max(0, Int(fractionY * Double(height))))
        let row = base.assumingMemoryBound(to: UInt8.self) + y * rowBytes
        return ChromaProbe.Pixel(r: Int(row[x * 4 + 2]), g: Int(row[x * 4 + 1]),
                                 b: Int(row[x * 4]))
    }
}
