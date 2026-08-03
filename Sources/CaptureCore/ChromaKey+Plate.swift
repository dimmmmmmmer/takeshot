import CoreGraphics
import Foundation

/// Where the plate lands behind the actor.
///
/// Its own file, and pure geometry: the keyer runs this once per (plate, frame,
/// layout) and caches the CIImage it builds from the answer, and the tests
/// measure the rect directly rather than reading pixels back off a render.
extension ChromaKey.PlateLayout {
    /// The rect the plate occupies inside `frame`, in the frame's own
    /// coordinate space (CoreImage's, y growing UP — which is why a positive
    /// `offsetY` raises the plate).
    ///
    /// nil for a degenerate plate or frame: there is nothing to place, and the
    /// caller shows the checkerboard rather than dividing by zero.
    ///
    /// `.fit` letterboxes, `.fill` covers and lets the overhang be cropped, and
    /// `.stretch` scales the axes independently. `scale` multiplies whichever
    /// of those was chosen, so "fill, ×1.2" is a fill pushed in by a fifth
    /// rather than a different fit; the offset then slides the result by a
    /// fraction of the FRAME, so the slider means the same distance whatever
    /// size the plate is.
    public func rect(forPlate plate: CGSize, in frame: CGRect) -> CGRect? {
        guard plate.width > 0, plate.height > 0,
              frame.width > 0, frame.height > 0 else { return nil }
        let horizontal = frame.width / plate.width
        let vertical = frame.height / plate.height
        let base: (x: CGFloat, y: CGFloat)
        switch fit {
        case .fit:
            let uniform = min(horizontal, vertical)
            base = (uniform, uniform)
        case .fill:
            let uniform = max(horizontal, vertical)
            base = (uniform, uniform)
        case .stretch:
            base = (horizontal, vertical)
        }
        let magnification = CGFloat(scale)
        let width = plate.width * base.x * magnification
        let height = plate.height * base.y * magnification
        let centerX = frame.midX + CGFloat(offsetX) * frame.width
        let centerY = frame.midY + CGFloat(offsetY) * frame.height
        return CGRect(x: centerX - width / 2, y: centerY - height / 2,
                      width: width, height: height)
    }

    /// Whether the plate covers the frame completely at this layout — i.e.
    /// whether anything of what is behind it can show through at the edges.
    ///
    /// The panel has no use for it; the keyer does. A plate that does not cover
    /// the frame is composited over black, and knowing that in advance is what
    /// lets the covering case skip the fill entirely.
    public func covers(_ frame: CGRect, plate: CGSize) -> Bool {
        guard let placed = rect(forPlate: plate, in: frame) else { return false }
        return placed.contains(frame)
    }
}
