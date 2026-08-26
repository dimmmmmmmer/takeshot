import CaptureCore
import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import TakeShotKit

/// The wipe handle sits on the seam.
///
/// Two different things draw those two: SwiftUI puts the line and the grab
/// circle over the picture with the origin top-left, and `CompareCompositor`
/// cuts the picture itself in Core Image's bottom-left space. Both were right
/// on their own and nothing held them against each other — the handle's
/// geometry lived inside a `GeometryReader` and a `DragGesture` closure, where
/// nothing could ask it anything.
///
/// A handle that is not on the seam is a control the operator drags while
/// watching the split move somewhere else, and the place it would go wrong is
/// named in the compositor already: SwiftUI drags a horizontal wipe from the
/// top and Core Image counts y from the bottom.
struct ViewCompareHandleTests {
    /// Deliberately NOT square: a mapping that divided by the wrong dimension
    /// would be invisible on a 1:1 picture, and no player window is 1:1.
    private let width = 96
    private let height = 64
    private var viewport: CGSize { CGSize(width: CGFloat(width),
                                          height: CGFloat(height)) }
    private let context = CIContext(options: [.useSoftwareRenderer: true])

    private func solid(_ color: CIColor) -> CIImage {
        CIImage(color: color).cropped(
            to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Red is the FRONT image, blue the back.
    private var front: CIImage { solid(CIColor(red: 1, green: 0, blue: 0)) }
    private var back: CIImage { solid(CIColor(red: 0, green: 0, blue: 1)) }

    /// Whether that Core Image pixel came from the front image.
    private func isFront(_ image: CIImage, x: Int, y: Int) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return bytes[0] > bytes[2]
    }

    /// The middle of the handle's line, in SwiftUI's top-left space.
    private func handleMidpoint(_ position: Double,
                                _ axis: CompareCompositor.Axis) -> CGPoint {
        let (p1, p2) = CompareWipeGeometry.endpoints(position: position,
                                                     in: viewport, axis: axis)
        return CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
    }

    /// Which way "past the seam" is, in SwiftUI's top-left space: the axis the
    /// wipe grows along. The front image is on the LOW side of it in all three,
    /// which is what "front occupies the left/top side" means.
    private func normal(_ axis: CompareCompositor.Axis) -> CGVector {
        switch axis {
        case .vertical: return CGVector(dx: 1, dy: 0)
        case .horizontal: return CGVector(dx: 0, dy: 1)
        case .diagonal: return CGVector(dx: 0.707, dy: 0.707)
        }
    }

    // MARK: - the handle and the seam are the same line

    /// Either side of the handle, in the composited picture, is either side of
    /// the wipe. Through the real compositor, so this cannot be satisfied by
    /// restating the handle's own arithmetic.
    @Test func eitherSideOfTheHandleIsEitherSideOfTheSeam() {
        for axis in [CompareCompositor.Axis.vertical, .horizontal, .diagonal] {
            for position in [0.35, 0.5, 0.65] {
                let composed = CompareCompositor.compose(
                    front: front, back: back,
                    mode: .wipe(axis: axis, position: position))
                let middle = handleMidpoint(position, axis)
                let step = normal(axis)
                let reach = 8.0

                // eight points from the seam on the low side, and eight on the
                // high side, converted into Core Image's bottom-left space
                let low = CGPoint(x: middle.x - step.dx * reach,
                                  y: middle.y - step.dy * reach)
                let high = CGPoint(x: middle.x + step.dx * reach,
                                   y: middle.y + step.dy * reach)
                #expect(isFront(composed, x: Int(low.x), y: height - Int(low.y)),
                        "\(axis) at \(position): the front side of the handle shows back")
                #expect(!isFront(composed, x: Int(high.x), y: height - Int(high.y)),
                        "\(axis) at \(position): the back side of the handle shows front")
            }
        }
    }

    /// The handle's line reaches the edges of the picture: a seam that stopped
    /// short would leave the operator guessing where the cut carries on.
    @Test func theLineSpansThePicture() {
        for axis in [CompareCompositor.Axis.vertical, .horizontal, .diagonal] {
            let (p1, p2) = CompareWipeGeometry.endpoints(position: 0.5,
                                                         in: viewport, axis: axis)
            for point in [p1, p2] {
                let onEdge = point.x == 0 || point.y == 0
                    || point.x == viewport.width || point.y == viewport.height
                #expect(onEdge, "\(axis): the seam ends at \(point), inside the frame")
            }
            #expect(p1 != p2)
        }
    }

    // MARK: - dragging it

    /// Drop the handle where it already is and it does not move. The drag maps
    /// a point back to a position, and that has to be the exact inverse of the
    /// line the operator is aiming at — a scale error here is a handle that
    /// creeps away from the pointer as it is dragged.
    @Test func droppingTheHandleWhereItIsLeavesItThere() {
        for axis in [CompareCompositor.Axis.vertical, .horizontal, .diagonal] {
            for position in [0.0, 0.2, 0.5, 0.8, 1.0] {
                let back = CompareWipeGeometry.position(
                    at: handleMidpoint(position, axis), in: viewport, axis: axis)
                #expect(abs(back - position) < 1e-12,
                        "\(axis): \(position) came back as \(back)")
            }
        }
    }

    /// A drag that carries on past an edge stops there. The gesture has no
    /// minimum distance and reports wherever the pointer is, which on a fast
    /// drag is well outside the picture.
    @Test func aDragPastTheEdgeStopsAtIt() {
        for axis in [CompareCompositor.Axis.vertical, .horizontal, .diagonal] {
            #expect(CompareWipeGeometry.position(
                at: CGPoint(x: -400, y: -400), in: viewport, axis: axis) == 0)
            #expect(CompareWipeGeometry.position(
                at: CGPoint(x: 900, y: 900), in: viewport, axis: axis) == 1)
        }
    }

    /// A viewport with no size arrives during window setup, before layout has
    /// run, and every branch divides by one of its dimensions. The seam parks
    /// at 0 rather than becoming a NaN nothing downstream can recover from.
    @Test func aViewportWithNoSizeDoesNotProduceANaN() {
        for axis in [CompareCompositor.Axis.vertical, .horizontal, .diagonal] {
            let position = CompareWipeGeometry.position(
                at: CGPoint(x: 10, y: 10), in: .zero, axis: axis)
            #expect(position == 0, "\(axis) answered \(position)")
            let (p1, p2) = CompareWipeGeometry.endpoints(position: .nan,
                                                         in: viewport, axis: axis)
            #expect(p1.x.isFinite && p1.y.isFinite && p2.x.isFinite && p2.y.isFinite)
        }
    }

    // MARK: - one mapping, not two

    /// The handle asks `CaptureController.compareAxis` for its axis — the same
    /// call the compositor's mode goes through. Two spellings of "diagonal" is
    /// how a handle and a seam come to disagree in the first place.
    @MainActor
    @Test func theHandleAndTheCompositorReadTheSameOrientation() {
        #expect(CaptureController.compareAxis(.vertical) == .vertical)
        #expect(CaptureController.compareAxis(.horizontal) == .horizontal)
        #expect(CaptureController.compareAxis(.diagonal) == .diagonal)
    }
}
