import CaptureCore
import CoreGraphics

/// Where the wipe seam is on screen, and where a drag of its handle puts it.
///
/// The handle and the SEAM are drawn by two different things in two different
/// coordinate systems: SwiftUI draws the line and the grab circle over the
/// picture with the origin top-left, and `CompareCompositor` cuts the picture
/// itself in Core Image's bottom-left space. Nothing lined the two up — the
/// handle's geometry lived inside a `GeometryReader` and a `DragGesture`
/// closure in `PreviewView`, where nothing could ask it anything — and a
/// handle that does not sit on the seam is a control the operator drags while
/// watching the split move somewhere else.
///
/// So both halves are stated here, over the same 0…1 position and the same
/// axis the compositor takes, and `ViewCompareHandleTests` holds them against
/// the seam the compositor actually cuts.
enum CompareWipeGeometry {
    /// The seam's two ends inside a viewport, in SwiftUI's top-left space.
    ///
    /// Vertical and horizontal are a full-width or full-height line. The
    /// diagonal is the segment of `x + y = t` that lies inside the box, which
    /// is what the compositor's mask draws — hence the two clamps: past the
    /// halfway point the line's ends leave the top and left edges and slide
    /// down the right and bottom ones.
    static func endpoints(position: Double, in size: CGSize,
                          axis: CompareCompositor.Axis) -> (CGPoint, CGPoint) {
        let clamped = clamp(position)
        switch axis {
        case .vertical:
            let x = size.width * clamped
            return (CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height))
        case .horizontal:
            let y = size.height * clamped
            return (CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y))
        case .diagonal:
            let t = clamped * (size.width + size.height)
            return (CGPoint(x: max(0, t - size.height), y: min(t, size.height)),
                    CGPoint(x: min(t, size.width), y: max(0, t - size.width)))
        }
    }

    /// Where a drag that lands on `point` puts the seam.
    ///
    /// The exact inverse of `endpoints` — drop the handle on the line and it
    /// stays where it was — and clamped, because the picture has two ends and
    /// a drag that carries on past one must stop rather than wrap.
    static func position(at point: CGPoint, in size: CGSize,
                         axis: CompareCompositor.Axis) -> Double {
        let raw: Double
        switch axis {
        case .vertical:
            raw = point.x / size.width
        case .horizontal:
            raw = point.y / size.height
        case .diagonal:
            raw = (point.x + point.y) / (size.width + size.height)
        }
        return clamp(raw)
    }

    /// 0…1, and 0 for a viewport with no size at all: that arrives during
    /// window setup, before layout has run, and every branch above divides by
    /// one of its dimensions.
    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
