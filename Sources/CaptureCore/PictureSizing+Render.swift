@preconcurrency import CoreImage
import Foundation

/// **The nine numbers as pixels** — the other half of `PictureSizing`, in
/// CoreImage's own y-UP space.
///
/// Split from the value for two reasons and not for length: this half imports
/// CoreImage and the value does not, and this is the half where a sign is a
/// picture upside down. The y-DOWN transform beside it is what the overlays,
/// the mouse and the framelines ride; the two are pinned to each other by a
/// test that renders a mark and looks for it where the other one says it is
/// (`PictureSizingRenderTests`), because "positive rotation is clockwise" is a
/// sentence that has to be true in both spaces or the eyedropper picks the
/// wrong pixel.
extension PictureSizing {
    /// The picture sized into `frame`, letterboxed with `letterbox`, in the
    /// frame's own y-up space.
    ///
    /// Identity is handed straight back — not as an optimisation but as a
    /// contract: a sizing that does nothing must not resample, because a
    /// resample is what costs a take its wire codes.
    public func applied(to image: CIImage, in frame: CGRect,
                        letterbox: CIColor) -> CIImage {
        let sized = placed(image, in: frame)
        guard sized !== image else { return image }
        let background = CIImage(color: letterbox).cropped(to: frame)
        return sized.cropped(to: frame).composited(over: background)
    }

    /// The picture sized into `frame` and NOT letterboxed — for a caller that
    /// paints its own bars, which the preview layer does (`letterboxed(in:with:)`
    /// exists because an extent alone does not keep a picture's edge column out
    /// of the bar beside it).
    public func placed(_ image: CIImage, in frame: CGRect) -> CIImage {
        let source = image.extent
        guard !isIdentity || source != frame,
              source.width > 0, source.height > 0,
              frame.width > 0, frame.height > 0 else { return image }
        let centred = image.transformed(by: CGAffineTransform(
            translationX: -source.midX, y: -source.midY))
        var sized = centred.transformed(
            by: renderTransform(sourceSize: source.size, in: frame.size))
        // **Integral-pixel placement**, carried over from the layer this
        // replaced: a fractional offset shifts live against playback by a
        // visible pixel in the compare modes, where the two pictures are meant
        // to lie on top of each other. Rounding the whole picture's position
        // is not the same as rounding inside it — a rotation still samples
        // between pixels, and should.
        sized = sized.transformed(by: CGAffineTransform(
            translationX: (frame.midX + sized.extent.minX).rounded(.down)
                - sized.extent.minX,
            y: (frame.midY + sized.extent.minY).rounded(.down)
                - sized.extent.minY))
        if !isAffine { sized = perspectiveApplied(to: sized, in: frame) }
        return sized
    }

    /// Steps 1-5 about the ORIGIN, in y-up space: the caller centres the image
    /// on the origin first and moves the result to the frame's centre after,
    /// so this is the shape and the scale and nothing about where anything is.
    ///
    /// Two signs differ from the y-down `transform` and both are stated where
    /// they are taken: the rotation, because a positive angle turns the other
    /// way when y grows up, and the tilt, because moving the visible WINDOW
    /// down moves the PICTURE up.
    func renderTransform(sourceSize: CGSize,
                         in frame: CGSize) -> CGAffineTransform {
        var shape = CGAffineTransform(
            scaleX: CGFloat(flipH ? -width : width),
            y: CGFloat(flipV ? -height : height))
        shape = shape.concatenating(CGAffineTransform(
            rotationAngle: -CGFloat(rotation) * .pi / 180))
        let box = CGRect(origin: .zero, size: sourceSize).applying(shape)
        guard box.width > 0, box.height > 0 else { return shape }
        let fit = min(frame.width / box.width, frame.height / box.height)
        let scale = fit * CGFloat(min(Self.maxZoom, max(Self.minZoom, zoom)))
        shape = shape.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return shape.concatenating(CGAffineTransform(
            translationX: -effectivePan.x * box.width * scale,
            y: effectivePan.y * box.height * scale))
    }

    /// **Pitch and yaw, as a projection and not as a shear.**
    ///
    /// The picture is treated as a flat card at the frame's centre, turned
    /// about the frame's horizontal axis (pitch) and its vertical one (yaw),
    /// and photographed from `viewingDistance` away. That is what a
    /// perspective control means to anyone who has used one: the far edge gets
    /// SHORTER than the near edge, which a shear cannot do and which is the
    /// whole visible difference between the two.
    private func perspectiveApplied(to image: CIImage,
                                    in frame: CGRect) -> CIImage {
        let rect = image.extent.isInfinite ? frame : image.extent
        guard rect.width > 0, rect.height > 0,
              let filter = CIFilter(name: "CIPerspectiveTransform")
        else { return image }
        let corners = [
            CGPoint(x: rect.minX, y: rect.maxY),  // top left
            CGPoint(x: rect.maxX, y: rect.maxY),  // top right
            CGPoint(x: rect.maxX, y: rect.minY),  // bottom right
            CGPoint(x: rect.minX, y: rect.minY),  // bottom left
        ].map { projected($0, about: frame, size: rect.size) }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (corner, key) in zip(corners, ["inputTopLeft", "inputTopRight",
                                           "inputBottomRight", "inputBottomLeft"]) {
            filter.setValue(CIVector(cgPoint: corner), forKey: key)
        }
        return filter.outputImage ?? image
    }

    /// How far the eye is from the card, as a multiple of its longer side.
    ///
    /// Two is a lens with visible but usable perspective: at 45° of yaw the far
    /// edge comes back about two thirds the height of the near one, which reads
    /// as a turn rather than as a fold. A larger number flattens the control
    /// into a shear; a smaller one makes a few degrees violent.
    static let viewingDistance: CGFloat = 2

    /// One corner of the card, turned and projected.
    private func projected(_ point: CGPoint, about frame: CGRect,
                           size: CGSize) -> CGPoint {
        let x = point.x - frame.midX
        let y = point.y - frame.midY
        // yaw about the vertical axis, then pitch about the horizontal one —
        // one order, stated, because two rotations do not commute.
        let yawRadians = CGFloat(yaw) * .pi / 180
        let pitchRadians = CGFloat(pitch) * .pi / 180
        let x1 = x * cos(yawRadians)
        let z1 = -x * sin(yawRadians)
        let y2 = y * cos(pitchRadians)
        let z2 = z1 * cos(pitchRadians) - y * sin(pitchRadians)
        let distance = Self.viewingDistance * max(size.width, size.height)
        let denominator = max(distance * 0.1, distance - z2)
        let perspective = distance / denominator
        return CGPoint(x: frame.midX + x1 * perspective,
                       y: frame.midY + y2 * perspective)
    }
}
