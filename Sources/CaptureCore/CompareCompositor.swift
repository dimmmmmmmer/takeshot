@preconcurrency import CoreImage

/// Shared wipe/blend compositing math: the playback tap (playback vs live)
/// and the live pipeline (live vs pinned reference) must draw the exact same
/// seam and fade, so the geometry lives in one place.
public enum CompareCompositor {
    public enum Axis: String, Sendable {
        case vertical    // vertical seam, drags horizontally
        case horizontal  // horizontal seam, drags vertically
        case diagonal    // 45°
    }

    public enum Mode: Sendable {
        case off
        case blend(opacity: Double)
        case wipe(axis: Axis, position: Double)
        /// Per-pixel |A−B|, amplified by `gain` (×1/×4/×16 in the UI) and
        /// clamped. The framing-match tool: identical frames come out exact
        /// black, and anything that moved lights up.
        case difference(gain: Double)
    }

    /// `front` occupies the left/top side of the wipe, or fades in over
    /// `back` in blend. Both images must share the same extent.
    public static func compose(front: CIImage, back: CIImage,
                               mode: Mode) -> CIImage {
        switch mode {
        case .off:
            return front
        case .blend(let opacity):
            // cross-dissolve, not an alpha matrix: fading only the alpha of a
            // premultiplied image leaves RGB at full strength and over-brightens
            return CapturePipeline.mix(source: back, filtered: front,
                                       intensity: opacity)
        case .difference(let gain):
            return difference(front: front, back: back, gain: gain)
        case .wipe(let axis, let position):
            let extent = front.extent
            switch axis {
            case .vertical:
                let rect = CGRect(x: extent.minX, y: extent.minY,
                                  width: extent.width * position,
                                  height: extent.height)
                return front.cropped(to: rect).composited(over: back)
            case .horizontal:
                // SwiftUI's wipe drags from the top; CI origin is bottom-left
                let rect = CGRect(x: extent.minX,
                                  y: extent.minY + extent.height * (1 - position),
                                  width: extent.width,
                                  height: extent.height * position)
                return front.cropped(to: rect).composited(over: back)
            case .diagonal:
                // SwiftUI wipe region (top-left origin): x + y ≤ t. In CI's
                // bottom-left coordinates that is d(x,y) = x − y ≤ t − height.
                // A 1-px gradient across that line makes an exact hard mask.
                let t = position * Double(extent.width + extent.height)
                let threshold = t - Double(extent.height)
                func pointAt(_ d: Double) -> CIVector {
                    CIVector(x: d / 2, y: -d / 2) // the point where x − y = d
                }
                guard let mask = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": pointAt(threshold - 0.5),
                    "inputPoint1": pointAt(threshold + 0.5),
                    "inputColor0": CIColor.white,
                    "inputColor1": CIColor.black,
                ])?.outputImage?.cropped(to: extent) else { return front }
                return front.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: back,
                    kCIInputMaskImageKey: mask,
                ])
            }
        }
    }

    /// Per-pixel |A−B|, amplified and clamped.
    ///
    /// |A−B| per channel on the raw code values (both inputs are read with
    /// color management off, like everything else in this path), so identical
    /// frames land on exact black with no bias. The blend-mode filter needs
    /// opaque inputs — both halves are, everywhere this is called.
    private static func difference(front: CIImage, back: CIImage,
                                   gain: Double) -> CIImage {
        let diff = front.applyingFilter("CIDifferenceBlendMode", parameters: [
            kCIInputBackgroundImageKey: back,
        ])
        guard gain > 1 else { return diff }
        // The gain is what makes small differences visible at all (a 2-code
        // framing error is invisible at ×1), scaled on RGB only — alpha stays
        // opaque — and clamped back into range explicitly: the intermediate
        // is float and would otherwise carry >1.0 values into whatever is
        // composited downstream.
        return diff.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
    }

    /// Aspect-fit `image` into `extent`, letterboxed with black — an
    /// anamorphic stretch would make the geometric comparison meaningless.
    ///
    /// The bars are painted rather than left to what shows through beside the
    /// fitted picture: see `CIImage.letterboxed(in:with:)` for the runner that
    /// smeared a picture's edge column across the bar next to it instead.
    public static func fitted(_ image: CIImage, into extent: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }
        if source.size == extent.size {
            return image
        }
        let scale = min(extent.width / source.width,
                        extent.height / source.height)
        let tx = (extent.width - source.width * scale) / 2
        let ty = (extent.height - source.height * scale) / 2
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
            .letterboxed(in: extent, with: CIColor(red: 0, green: 0, blue: 0))
    }
}
