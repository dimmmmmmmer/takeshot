import CoreGraphics
@preconcurrency import CoreImage

/// Letterboxing that is DRAWN, rather than left over.
///
/// `picture.composited(over: colour)` says where the picture stops in terms of
/// the picture's EXTENT, and an extent is bookkeeping — nothing in the rendered
/// pixels says "the plate ends here". Where that bookkeeping is all a smaller
/// image has, because its extent was computed by the `transformed(by:)` that
/// placed it, a renderer is free to answer a sample taken past the edge with
/// the edge itself: CoreImage's texture samplers clamp, and the region of
/// definition is the only thing standing between that and the bar beside the
/// picture. The macOS 15 CI runner does exactly this. A chroma plate fitted
/// into a wider frame came back with its left column smeared across the whole
/// left bar and its right column across the right one — a plate that reached
/// both edges of the frame, which is the one thing the fit control exists to
/// prevent — while the same code letterboxes correctly on macOS 26.
///
/// Note what does NOT fix it: `cropped(to:)` with a rect that contains the
/// image returns the very same `CIImage` object, so cropping a placement to
/// its own rect adds no boundary at all. What does fix it is painting the bars
/// as constant colour ON TOP. That is a generator behind an explicit crop
/// rather than a texture behind an inferred extent, it is the construction
/// `AssistGuides` already draws its frameline matte and safe areas out of, and
/// those are green on the same runner.
extension CIImage {
    /// `self` inside `frame`, with every part of `frame` the image does not
    /// reach filled with `color`.
    ///
    /// The fill goes on twice: once as a backing under the image, so no pixel
    /// of the frame is ever transparent, and once as bars over the top of it,
    /// so no pixel of the frame is ever the picture's edge stretched into the
    /// margin. An image that covers the frame pays for the backing and nothing
    /// else — all four bars are empty and drop out.
    public func letterboxed(in frame: CGRect, with color: CIColor) -> CIImage {
        guard frame.width > 0, frame.height > 0 else { return self }
        let fill = CIImage(color: color)
        let covered = extent.intersection(frame)
        guard !covered.isNull, covered.width > 0, covered.height > 0 else {
            return fill.cropped(to: frame)
        }
        let bars = [
            CGRect(x: frame.minX, y: frame.minY,
                   width: covered.minX - frame.minX, height: frame.height),
            CGRect(x: covered.maxX, y: frame.minY,
                   width: frame.maxX - covered.maxX, height: frame.height),
            CGRect(x: covered.minX, y: frame.minY,
                   width: covered.width, height: covered.minY - frame.minY),
            CGRect(x: covered.minX, y: covered.maxY,
                   width: covered.width, height: frame.maxY - covered.maxY),
        ]
        let backed = composited(over: fill.cropped(to: frame))
        return bars.reduce(backed) { out, bar in
            let clipped = bar.intersection(frame)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0
            else { return out }
            return fill.cropped(to: clipped).composited(over: out)
        }.cropped(to: frame)
    }
}
