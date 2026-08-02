@preconcurrency import CoreVideo
import Foundation

/// The chroma key's half of the pipeline: where it sits in the display path,
/// what it is allowed to reach, and the pixel the eyedropper reads.
///
/// **Where it sits.** One stage after the viewing LUT, on the DISPLAY queue.
/// The LUT's rule is that the display buffer is what mirrors the viewer —
/// preview sinks, the hardware monitor and the phone multiview all draw it —
/// while the deliverables (the writer's frame, the still grab, the scopes'
/// measurement) are taken from the record/leveled branch before it. The key
/// follows that rule exactly: it is composited into the frame the mirrors get
/// and into nothing else. `enqueuePreview` publishes the CLEAN frame for the
/// compare provider and hands the keyed one only to the surfaces, and
/// `serveFrameGrab` has already run, on the untouched frame, by the time this
/// is reached (see `+Frame` for the order).
///
/// **What it costs when off.** One `Bool` read per frame.
extension CapturePipeline {
    /// The operator's key settings. Called from the main actor on every slider
    /// tick, so it takes a lock rather than a queue hop — a hop onto the
    /// capture queue is exactly what a display-only tool must not do.
    public func setChromaKey(_ key: ChromaKey) {
        var clamped = key
        clamped.clamp()
        chromaLock.lock()
        storedChromaKey = clamped
        chromaLock.unlock()
    }

    public func currentChromaKey() -> ChromaKey {
        chromaLock.lock()
        defer { chromaLock.unlock() }
        return storedChromaKey
    }

    /// The plate that shows through the key. Handed to the keyer on its own
    /// queue — the keyer belongs to the display stage and nothing else may
    /// touch it.
    public func setChromaBackgroundImage(_ buffer: CVPixelBuffer?) {
        displayQueue.async { self.chromaKeyer.setBackgroundImage(buffer) }
    }

    /// How many frames have been shown without the key because they were
    /// already late. A diagnostic, not a control: if this climbs, the machine
    /// cannot afford the effect at this resolution and the operator is seeing
    /// it flicker.
    public var chromaKeyLateDrops: Int {
        chromaLock.lock()
        defer { chromaLock.unlock() }
        return chromaLateDropCount
    }

    /// Key a frame on its way to the surfaces. nil means "show the original":
    /// the key is off, the frame is already late, or the render failed.
    ///
    /// The lateness gate is the graceful degradation this feature promised. The
    /// display queue is latest-wins, so a slow machine cannot back frames up —
    /// but it CAN spend its whole frame interval inside the keyer and hand the
    /// surface a picture that is already a frame old. Past the deadline the
    /// effect is what gets dropped, never the frame: the operator would rather
    /// see the green screen for one frame than see the picture stutter.
    ///
    /// Display-queue only (the keyer is confined to it).
    func chromaKeyed(_ buffer: CVPixelBuffer, deadline: UInt64) -> CVPixelBuffer? {
        chromaLock.lock()
        let key = storedChromaKey
        chromaLock.unlock()
        guard key.isOn else { return nil } // off costs one Bool read
        guard DispatchTime.now().uptimeNanoseconds <= deadline else {
            chromaLock.lock()
            chromaLateDropCount += 1
            chromaLock.unlock()
            return nil
        }
        return chromaKeyer.keyed(buffer, key: key)
    }

    /// How long the display stage has to work on a frame before the frame stops
    /// being worth the work: one frame interval.
    ///
    /// One and not two: a stage that is a whole frame behind is already showing
    /// the operator a picture that has been superseded, and the cure for that
    /// is to get the newest frame on the glass, not to spend another ten
    /// milliseconds decorating a stale one. An unknown rate is treated as 25 —
    /// the slowest signal this app sees, so the guess is the generous one.
    public static func displayBudgetNanos(atFrameRate rate: Double) -> UInt64 {
        guard rate > 0, rate.isFinite else { return 40_000_000 }
        return UInt64(1_000_000_000 / rate)
    }

    /// The budget from now, in uptime nanoseconds. Capture queue (reads
    /// `format`).
    func displayDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
            + Self.displayBudgetNanos(atFrameRate: format?.frameRate ?? 0)
    }

    // MARK: - the eyedropper

    /// The color at a point on the DISPLAYED picture, given as fractions of the
    /// frame (0,0 top-left). nil when there is no frame, or it is not the 8-bit
    /// BGRA the display path produces.
    ///
    /// This reads the clean display frame — what the operator is looking at
    /// before the key is applied — because that is the pixel they are pointing
    /// at. Reading the keyed frame would sample the background the previous
    /// guess had already put there.
    ///
    /// A small neighborhood is averaged rather than one pixel: a cyc is noisy,
    /// and a single sample off a compressed HDMI feed can be several code
    /// values away from the green the operator means to pick.
    public func sampleDisplayColor(atFractionX u: Double, y v: Double,
                                   radius: Int = 2) -> ChromaKey.RGB? {
        latestPreviewLock.lock()
        let buffer = latestPreview
        latestPreviewLock.unlock()
        guard let buffer,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let cx = min(width - 1, max(0, Int(u * Double(width))))
        let cy = min(height - 1, max(0, Int(v * Double(height))))
        var sum = (b: 0, g: 0, r: 0)
        var counted = 0
        for y in (cy - radius)...(cy + radius) where y >= 0 && y < height {
            let row = bytes + y * rowBytes
            for x in (cx - radius)...(cx + radius) where x >= 0 && x < width {
                sum.b += Int(row[x * 4])
                sum.g += Int(row[x * 4 + 1])
                sum.r += Int(row[x * 4 + 2])
                counted += 1
            }
        }
        guard counted > 0 else { return nil }
        let scale = 255.0 * Double(counted)
        return ChromaKey.RGB(Double(sum.r) / scale, Double(sum.g) / scale,
                             Double(sum.b) / scale)
    }
}
