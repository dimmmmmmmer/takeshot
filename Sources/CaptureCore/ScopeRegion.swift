import Foundation

/// The part of the frame the scopes analyze, in normalized image coordinates
/// with the origin at the TOP-LEFT (the same orientation the operator sees).
///
/// Scopes exist to judge the picture on screen. While the viewer is punched in
/// that picture is a crop, so the analysis has to follow the crop — a waveform
/// of the whole frame says nothing about the exposure of the part the operator
/// is looking at. `.full` is the un-punched case and costs nothing extra.
public struct ScopeRegion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = ScopeRegion(x: 0, y: 0, width: 1, height: 1)

    /// Clamped on the way in: a region outside the frame has no pixels to
    /// sample, and the analyzer must never index past the plane.
    public init(x: Double, y: Double, width: Double, height: Double) {
        let w = min(1, max(0.01, width))
        let h = min(1, max(0.01, height))
        self.width = w
        self.height = h
        self.x = min(1 - w, max(0, x))
        self.y = min(1 - h, max(0, y))
    }

    /// The region the preview shows for these display assists.
    ///
    /// `MetalPreviewLayer` magnifies by `punchIn` about the frame center and
    /// then pans by `panX`/`panY` in image fractions, so the visible slice is
    /// `1/punchIn` of the frame centered at (0.5 + panX, 0.5 + panY). The
    /// letterbox slop of a viewer whose aspect differs from the source's is
    /// ignored — a scope reading a percent or two more of the frame than the
    /// glass shows is not a decision an operator makes differently.
    public init(assist: ViewAssist) {
        let punchIn = max(1, assist.punchIn)
        let side = 1 / punchIn
        self.init(x: 0.5 + assist.panX - side / 2,
                  y: 0.5 + assist.panY - side / 2,
                  width: side, height: side)
    }

    /// Whole frame — the analyzer skips the offset math entirely.
    public var isFull: Bool {
        width >= 1 && height >= 1
    }

    /// A region resolved against a frame size: the exact pixels to sample.
    struct PixelWindow: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// The pixel window this region names in a `width` x `height` frame.
    /// At least one pixel wide and high, and always inside the frame — the
    /// analyzer reads it with no bounds checking of its own.
    func pixels(width frameWidth: Int, height frameHeight: Int) -> PixelWindow {
        let w = max(1, min(frameWidth, Int((Double(frameWidth) * width).rounded())))
        let h = max(1, min(frameHeight, Int((Double(frameHeight) * height).rounded())))
        return PixelWindow(
            x: min(frameWidth - w, max(0, Int((Double(frameWidth) * x).rounded()))),
            y: min(frameHeight - h, max(0, Int((Double(frameHeight) * y).rounded()))),
            width: w, height: h)
    }
}
