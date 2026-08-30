import Foundation

/// What the taught-indicator watcher decided about one frame: the box looks like
/// the reference the operator captured while the camera was rolling, or like the
/// one they captured while it was not.
///
/// There is deliberately no `unknown` case. "Neither reference, by the required
/// margin" is `nil` — no evidence — and no evidence has to be indistinguishable
/// from "the watcher did not run", because both must leave every accumulator in
/// `RecDetector` exactly where it was.
public enum VisualRecReading: String, Equatable, Sendable, Codable {
    case rolling
    case idle
}

/// The watched box, in SIGNAL coordinates — fractions of the frame the camera
/// sent, never of the viewport.
///
/// That is the whole reason this is a value of its own. A punch-in, a pan and a
/// desqueeze all move the picture inside the window and none of them move the
/// signal, so a box stored in viewport units walks out from under the indicator
/// the moment the operator zooms in to check focus. The operator's CLICK arrives
/// in viewport units and is converted once, by `ViewAssist.imageFraction` — the
/// same inverse mapping the chroma eyedropper uses, deliberately reused rather
/// than reimplemented.
///
/// `size` is a fraction of each axis rather than a square in pixels: every
/// mapping is then a fraction of the frame, which is the unit the guides, the
/// punch-in and `imageFraction` are already in, and there is no aspect ratio
/// anywhere for a desqueeze to disagree about.
public struct VisualRecRegion: Equatable, Sendable {
    /// Box centre, 0…1 across the frame; y grows DOWN, like `imageFraction`.
    public var centerX: Double
    public var centerY: Double
    /// Box extent as a fraction of the frame, PER AXIS.
    ///
    /// One `size` for both, once — which made the region a square by
    /// construction and could not be told to match what a camera actually
    /// draws. A REC indicator is a dot beside a word: wide and short. A square
    /// big enough to hold it holds a strip of picture above and below it too,
    /// and every costume that walks through that strip is a frame the trigger
    /// has to tell apart from the dot lighting up. (Owner: "по высоте ширине
    /// нельзя отредачить квадратик".)
    ///
    /// The ceiling is per axis for the same reason it existed at all: a quarter
    /// of the frame on ONE axis is still a strip, and the area rule that
    /// mattered — 6 % — is what two quarters multiply to.
    public var width: Double
    public var height: Double

    /// Bounds on the box. The ceiling is the load-bearing one: a quarter of the
    /// frame each way is already 6 % of its area, and a region larger than that
    /// stops being "the record indicator" and starts being "the picture", where
    /// a costume walking through it is indistinguishable from the dot lighting
    /// up. The floor is what a click can still land inside of.
    public static let minSize = 0.02
    public static let maxSize = 0.25
    /// 8 % of each axis — 154 × 86 px on a 1080p signal, which comfortably holds
    /// a camera's REC dot and its label without holding much else.
    public static let defaultSize = 0.08

    public init(centerX: Double = 0.5, centerY: Double = 0.5,
                width: Double = defaultSize, height: Double = defaultSize) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }

    /// Clamp everything the UI (or a hand-edited settings blob) can drive.
    public mutating func clamp() {
        centerX = min(1, max(0, centerX))
        centerY = min(1, max(0, centerY))
        width = min(Self.maxSize, max(Self.minSize, width))
        height = min(Self.maxSize, max(Self.minSize, height))
    }

    /// The watched box as a rectangle. A named struct and not four loose
    /// numbers, which is the house rule and the linter's: an origin and a size in
    /// a row is how a width ends up passed as a y.
    ///
    /// One type in two units — fractions of the frame from `normalizedBox`,
    /// pixels from `pixels(width:height:)` — because the second is the first
    /// scaled, and two structs differing only in what the numbers mean is two
    /// places to get the clamp wrong.
    public struct Box<Value: Equatable & Sendable>: Equatable, Sendable {
        public let x: Value
        public let y: Value
        public let width: Value
        public let height: Value
    }

    /// The box as fractions of the frame, clamped inside it.
    ///
    /// The ONE place the geometry is decided: the sampler turns this into pixels
    /// and the operator's on-screen guide draws it, so the box that is watched is
    /// by construction the box that is shown.
    public var normalizedBox: Box<Double> {
        let w = min(Self.maxSize, max(Self.minSize, width))
        let h = min(Self.maxSize, max(Self.minSize, height))
        return Box(x: min(1 - w, max(0, centerX - w / 2)),
                   y: min(1 - h, max(0, centerY - h / 2)),
                   width: w, height: h)
    }

    /// Pixel rect inside a frame of `width` × `height`. nil for a degenerate
    /// frame — there is nothing to watch in it.
    public func pixels(width: Int, height: Int) -> Box<Int>? {
        guard width > 0, height > 0 else { return nil }
        let box = normalizedBox
        let w = min(width, max(1, Int((box.width * Double(width)).rounded())))
        let h = min(height, max(1, Int((box.height * Double(height)).rounded())))
        return Box(x: min(width - w, max(0, Int((box.x * Double(width)).rounded()))),
                   y: min(height - h, max(0, Int((box.y * Double(height)).rounded()))),
                   width: w, height: h)
    }
}

/// One reading of the box, reduced to a fixed-length vector of code values.
///
/// A coarse grid of cell means rather than the pixels themselves, and the length
/// is fixed whatever the region's size or the signal's resolution — which is
/// what makes two signatures comparable at all. A reference captured on a 1080p
/// signal still classifies frames after the camera switches to UHD, and a
/// reference captured with a small box still classifies frames after the
/// operator widens it (badly, which is the operator's business, but not
/// nonsensically).
///
/// The cells are means, so the grid is also the noise filter: 8 × 8 cells over a
/// 154 × 86 px box average ~200 pixels each, and a compressed HDMI feed's
/// per-pixel noise disappears into that.
public struct VisualRecSignature: Equatable, Sendable {
    /// Cells per axis. 8 and not more: the point is to know WHERE inside the box
    /// something changed (a dot in one corner is not the same event as the whole
    /// box getting brighter), not to reproduce the picture. Finer cells hold
    /// fewer pixels each and buy noise.
    public static let grid = 8
    /// Grid cells times three components.
    public static let componentCount = grid * grid * 3

    /// Cell means, 0…255 display code values, row-major, R then G then B per
    /// cell. Code values and not 0…1 because the whole metric is argued in codes
    /// — "the two references are 19 codes apart" is a number an operator can be
    /// shown.
    public let codes: [Double]

    /// nil for a vector of the wrong length — the only way to build one from
    /// outside the sampler, so a stored blob cannot become a signature that the
    /// metric would read past the end of.
    public init?(codes: [Double]) {
        guard codes.count == Self.componentCount else { return nil }
        self.codes = codes
    }

    // MARK: - persistence

    /// The signature as base64 of one byte per component.
    ///
    /// One byte because the source IS 8-bit: these are means of display-buffer
    /// codes, so rounding to a code gives up a fraction of a code on a scale
    /// where the useful separations are tens of them. 192 bytes rather than 192
    /// JSON numbers matters because this lives in the settings blob.
    public var encoded: String {
        Data(codes.map { UInt8(min(255, max(0, $0.rounded()))) }).base64EncodedString()
    }

    /// A signature written by `encoded`; nil for anything else, so a truncated
    /// or hand-edited blob leaves the trigger untaught rather than armed on
    /// garbage.
    public init?(encoded: String) {
        guard let data = Data(base64Encoded: encoded),
              data.count == Self.componentCount else { return nil }
        self.init(codes: data.map(Double.init))
    }
}

/// What the operator taught, and the decision it makes about a frame.
///
/// **Teach, do not recognise.** ARRI, RED, Sony and Blackmagic each put REC in a
/// different place with a different glyph, and half of them flash it; a library
/// of shapes to match is a losing game that also fails on the next firmware.
/// So nothing here knows what a record indicator looks like. The operator marks
/// the box and captures the box twice — once with the camera rolling, once with
/// it idle — and everything below is the arithmetic of "which of those two is
/// this frame nearer to".
///
/// **The metric, and why it survives a red practical.** The two references
/// differ ONLY in the indicator: same framing, same lighting, same seconds
/// apart. Their difference Δ = rolling − idle is therefore a vector that points
/// at the indicator and at nothing else. A frame is projected onto that one
/// axis:
///
///   along    = ⟨sample − idle, Δ⟩ / ⟨Δ, Δ⟩   — 0 at idle, 1 at rolling
///   residual = ‖(sample − idle) − along·Δ‖ / ‖Δ‖ — the part that is NOT on it
///
/// Anything that changes the box as a whole — a red practical coming on, a
/// costume crossing it, the exposure being pulled — moves the sample almost
/// entirely PERPENDICULAR to Δ, because Δ is concentrated in the few cells the
/// indicator occupies. It lands in `residual` and barely moves `along`. So the
/// defence is not a colour test that red happens to pass; it is that the only
/// direction this trigger can see is the direction the operator taught it.
///
/// Three gates then have to agree before a frame is evidence at all:
///
/// 1. the two references must be `minSeparation` apart, or the teaching is
///    refused outright (the operator captured the same picture twice, or the box
///    misses the indicator);
/// 2. `residual` must be inside `maxResidual`, or something untaught is in the
///    box and the frame says nothing;
/// 3. `along` must clear `margin` of the way past the midpoint towards one
///    reference — the required margin against the idle reference.
///
/// Everything else that keeps this honest is elsewhere and named there: the
/// confirm-frame hysteresis is `RecDetector`'s (this value has no debounce of
/// its own), and it is opt-in — `isOn` starts false and is never persisted.
public struct VisualRecTeaching: Equatable, Sendable {
    /// The switch. Off by default and deliberately NOT persisted (see
    /// `CaptureController.restoreVisualRec`): the references are a photograph of
    /// one camera's overlay in one framing, and a trigger that re-arms itself on
    /// a rig it was never taught on is exactly the false start this feature is
    /// most able to cause.
    public var isOn = false
    public var region = VisualRecRegion()
    /// The box as it looks while the camera is rolling, and while it is not.
    public var rolling: VisualRecSignature?
    public var idle: VisualRecSignature?
    /// How far past the midpoint a frame must be to count as evidence, as a
    /// fraction of the taught separation. 0 would classify every frame as one
    /// or the other; 1 demands the reference itself.
    ///
    /// **Derived, not set** (owner: "что мы сами это не можем высчитывать?").
    /// It was a slider, and it was the wrong shape for the question: an
    /// operator cannot know what fraction of a separation they have not
    /// measured is enough to clear noise they cannot see. Both numbers are
    /// already here.
    ///
    /// The arithmetic, from the figure `minSeparation` is derived from: two
    /// captures of an UNCHANGED picture separate by about a code — sensor and
    /// compression noise, averaged over ~200 pixels a cell. So the threshold
    /// has to sit `noiseGuard` of those away from the midpoint, and as a
    /// fraction of the half-separation that is `noiseGuard · noise / (S/2)`.
    ///
    /// What falls out is the behaviour you would ask for: a bright REC dot
    /// separating the pair by 60 codes needs a tenth of it, a marginal teach at
    /// 5 codes needs nearly all of it, and an untaught pair gets the ceiling.
    /// The better the teaching, the less it demands.
    public var margin: Double {
        guard let separation, separation > 0 else { return Self.maxMargin }
        let needed = Self.noiseGuard * Self.captureNoise / (separation / 2)
        return min(Self.maxMargin, max(Self.minMargin, needed))
    }

    /// RMS code difference between two captures of a picture that did not
    /// change. Stated once here and used by `minSeparation`'s reasoning too.
    public static let captureNoise = 1.0
    /// How many of those the decision threshold sits clear of the midpoint.
    /// Three is the ordinary engineering answer for "not noise".
    public static let noiseGuard = 3.0
    /// Even a perfect teach keeps a little: an indicator that fades in has
    /// frames legitimately near the midpoint, and calling them either way is
    /// how a trigger chatters at the top of a take.
    public static let minMargin = 0.1
    public static let maxMargin = 0.9

    /// How much of a frame's change may be OFF the taught axis before the frame
    /// stops being evidence. 1 means "the untaught part may be as large as the
    /// whole taught difference and no larger".
    ///
    /// A constant and not a setting: it is a statement about what the metric can
    /// still answer for, not a preference, and one more dial on a false-start
    /// defence is one more dial to be found turned to zero on a Monday.
    public static let maxResidual = 1.0

    /// The least RMS code difference between the two references that counts as
    /// having taught anything.
    ///
    /// 4 codes, from the arithmetic: a REC dot 150 codes brighter than its
    /// background, filling two of the 64 cells in one component, separates the
    /// pair by √(2·150²/192) ≈ 15 codes. Two captures of an UNCHANGED picture
    /// separate by about a code — sensor and compression noise, averaged over
    /// ~200 pixels a cell. 4 sits well clear of the noise and well below any
    /// indicator.
    public static let minSeparation = 4.0

    public init() {}

    /// RMS code difference between the two references — the number the panel
    /// shows as "separation". nil until both are captured.
    public var separation: Double? {
        guard let squared = deltaSquared else { return nil }
        return (squared / Double(VisualRecSignature.componentCount)).squareRoot()
    }

    /// Both references captured, and far enough apart to mean anything.
    public var isTaught: Bool {
        guard let separation else { return false }
        return separation >= Self.minSeparation
    }

    /// Switched on AND taught. The only state in which a frame can produce a
    /// reading at all.
    public var isArmed: Bool { isOn && isTaught }

    public mutating func clamp() {
        // The margin clamps itself now — it is derived from the separation and
        // cannot arrive out of range from a hand-edited blob, because it does
        // not arrive at all.
        region.clamp()
    }

    /// Forget both references, keeping the box and the margin — what "re-teach"
    /// means when the camera's overlay changes but the box is still in the right
    /// place.
    public mutating func forgetReferences() {
        rolling = nil
        idle = nil
        isOn = false // an armed trigger with nothing taught is a lie
    }

    // MARK: - the decision

    /// Where a frame sits on the taught axis, and how far off it. nil before
    /// both references exist.
    ///
    /// Public because it is the honest readout: the panel can show the operator
    /// that their box reads 0.98 while the camera rolls and 0.01 while it does
    /// not, which is the only way to know the teaching worked before trusting a
    /// take to it.
    public func position(of sample: VisualRecSignature)
        -> (along: Double, residual: Double)? {
        guard let rolling, let idle else { return nil }
        // One pass for all three sums; the residual then follows from them
        // exactly (‖s‖² − ⟨s,Δ⟩²/‖Δ‖²) instead of costing a second walk.
        var deltaSq = 0.0
        var sampleSq = 0.0
        var product = 0.0
        for index in 0..<VisualRecSignature.componentCount {
            let delta = rolling.codes[index] - idle.codes[index]
            let offset = sample.codes[index] - idle.codes[index]
            deltaSq += delta * delta
            sampleSq += offset * offset
            product += offset * delta
        }
        guard deltaSq > 0 else { return nil }
        let along = product / deltaSq
        let residualSq = max(0, sampleSq - product * product / deltaSq)
        return (along: along, residual: (residualSq / deltaSq).squareRoot())
    }

    /// The reading for one sampled box, or nil for "no evidence" — which is
    /// what an untaught trigger, a disturbed box and a frame inside the margin
    /// all answer, because all three must leave the confirm runs alone.
    public func reading(of sample: VisualRecSignature) -> VisualRecReading? {
        guard isArmed, let position = position(of: sample) else { return nil }
        // gate 2: something untaught is in the box
        guard position.residual <= Self.maxResidual else { return nil }
        // gate 3: the required margin either side of the midpoint
        let half = min(Self.maxMargin, max(0, margin)) / 2
        if position.along >= 0.5 + half { return .rolling }
        if position.along <= 0.5 - half { return .idle }
        return nil
    }

    /// ‖Δ‖², the squared separation. Private: every caller wants either the RMS
    /// code figure or the projection, and both are stated above.
    private var deltaSquared: Double? {
        guard let rolling, let idle else { return nil }
        var total = 0.0
        for index in 0..<VisualRecSignature.componentCount {
            let delta = rolling.codes[index] - idle.codes[index]
            total += delta * delta
        }
        return total
    }
}
