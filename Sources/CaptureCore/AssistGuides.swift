@preconcurrency import CoreImage
import Foundation

/// Framelines and safe areas — the aids that are DRAWN on the picture rather
/// than computed from it.
///
/// They used to be a SwiftUI overlay over the player, which is why owner item 7
/// was reported against them twice over: an overlay lives on the surface it is
/// mounted on, so the guides were on the operator's window and on nothing else.
/// The director's monitor window never mounted them, and the hardware playout
/// is a pixel buffer with no view tree to hang an overlay in at all.
///
/// So they are drawn into the frame, at the SIGNAL's resolution — which is also
/// the only reading of "2.39" that means anything: 2.39 of what the camera is
/// sending, not of whatever shape the window happens to be. The punch-in and
/// the letterbox then carry the guides with the picture for free, because they
/// are part of it.
public struct AssistGuides: Equatable, Sendable {
    /// Frameline aspect (2.39, 1.85, 4:3…); nil — no frameline.
    public var ratio: Double?
    public var safeAreas = false
    /// Action/title safe as a percentage of the frame. SMPTE RP 218 is 93/90,
    /// and title safe is the INNER box.
    public var actionPercent: Double = 93
    public var titlePercent: Double = 90

    public init(ratio: Double? = nil, safeAreas: Bool = false,
                actionPercent: Double = 93, titlePercent: Double = 90) {
        self.ratio = ratio
        self.safeAreas = safeAreas
        self.actionPercent = actionPercent
        self.titlePercent = titlePercent
    }

    /// The guides as the operator's settings describe them. One conversion, so
    /// the value the renderer draws and the value the popover edits cannot
    /// disagree about what "off" or "93%" means.
    public init(settings: AssistSettings) {
        self.init(ratio: settings.framelineRatio,
                  safeAreas: settings.safeAreasOn == true,
                  actionPercent: settings.safeActionPercentEffective,
                  titlePercent: settings.safeTitlePercentEffective)
    }

    /// Nothing to draw — the display stage skips the whole pass on this.
    public var isEmpty: Bool {
        (ratio ?? 0) <= 0 && !safeAreas
    }

    /// The frameline's box inside a frame of `size`, in the image's own pixels.
    /// The whole frame when no ratio is set: the safe areas live inside the
    /// frameline when there is one and inside the picture when there is not.
    public func framedRect(in size: CGSize) -> CGRect {
        guard let ratio, ratio > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let r = CGFloat(ratio)
        let frameAspect = size.width / size.height
        return r >= frameAspect
            ? CGRect(x: 0, y: (size.height - size.width / r) / 2,
                     width: size.width, height: size.width / r)
            : CGRect(x: (size.width - size.height * r) / 2, y: 0,
                     width: size.height * r, height: size.height)
    }

    /// A safe-area box: `percent` of `base`, centered. Clamped to 50…100 so a
    /// hand-edited settings blob cannot put a guide outside the picture.
    public func safeRect(_ base: CGRect, percent: Double) -> CGRect {
        let inset = CGFloat((100 - min(100, max(50, percent))) / 200)
        return base.insetBy(dx: base.width * inset, dy: base.height * inset)
    }

    /// Stroke width for the frameline, in the frame's own pixels.
    ///
    /// Scaled off the picture rather than fixed at one pixel: a 1-px line on a
    /// UHD frame shown on a 1000pt player is a quarter of a screen pixel, which
    /// is a guide the operator cannot see. Two-thousandths of the height is
    /// ~2px at 1080 and ~4px at UHD — the same apparent weight on both.
    public static func lineWidth(in size: CGSize) -> CGFloat {
        max(1, (size.height / 540).rounded())
    }

    /// The guides drawn over `image`, whose extent is the frame.
    ///
    /// Composited as filled rectangles rather than stroked paths: this runs on
    /// the display queue on every frame, and four thin `CIImage(color:)` crops
    /// per box is a cheaper graph than anything that rasterizes a path.
    func drawn(over image: CIImage) -> CIImage {
        let extent = image.extent
        guard !isEmpty, extent.width > 1, extent.height > 1 else { return image }
        let size = extent.size
        let box = framedRect(in: size)
        var out = image
        if (ratio ?? 0) > 0 {
            // matte the outside so the frame reads instantly, then the line
            out = matte(box, over: out, in: extent)
            out = stroke(box, width: Self.lineWidth(in: size), alpha: 0.75,
                         over: out, in: extent)
        }
        if safeAreas {
            let thin = max(1, Self.lineWidth(in: size) * 0.6)
            out = stroke(safeRect(box, percent: actionPercent), width: thin,
                         alpha: 0.45, over: out, in: extent)
            out = stroke(safeRect(box, percent: titlePercent), width: thin,
                         alpha: 0.3, over: out, in: extent)
        }
        return out.cropped(to: extent)
    }

    /// A white rectangle outline of `rect`, as four filled bars.
    private func stroke(_ rect: CGRect, width: CGFloat, alpha: Double,
                        over image: CIImage, in extent: CGRect) -> CIImage {
        let line = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: alpha))
        let bars = [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: width),
            CGRect(x: rect.minX, y: rect.maxY - width,
                   width: rect.width, height: width),
            CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
            CGRect(x: rect.maxX - width, y: rect.minY,
                   width: width, height: rect.height),
        ]
        return bars.reduce(image) { out, bar in
            let clipped = bar.intersection(extent)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0
            else { return out }
            return line.cropped(to: clipped).composited(over: out)
        }
    }

    /// The four bands outside `rect`, dimmed — what makes the frameline read as
    /// a crop rather than as a stray rectangle.
    private func matte(_ rect: CGRect, over image: CIImage,
                       in extent: CGRect) -> CIImage {
        let shade = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        let bands = [
            CGRect(x: extent.minX, y: extent.minY,
                   width: extent.width, height: rect.minY - extent.minY),
            CGRect(x: extent.minX, y: rect.maxY,
                   width: extent.width, height: extent.maxY - rect.maxY),
            CGRect(x: extent.minX, y: rect.minY,
                   width: rect.minX - extent.minX, height: rect.height),
            CGRect(x: rect.maxX, y: rect.minY,
                   width: extent.maxX - rect.maxX, height: rect.height),
        ]
        return bands.reduce(image) { out, band in
            let clipped = band.intersection(extent)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0
            else { return out }
            return shade.cropped(to: clipped).composited(over: out)
        }
    }
}
