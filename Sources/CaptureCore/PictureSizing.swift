@preconcurrency import CoreImage
import Foundation

/// **Where the picture is, at what size, and which way up** — the nine
/// controls a colourist has under "Sizing" in Resolve, as one value.
///
/// Owner: pan, tilt, zoom, rotate, width, height, pitch, yaw and flip, wanted
/// separately for playback, for record viewing and for the recording itself.
/// One value type for all three, because they are the same nine numbers doing
/// the same arithmetic, and three copies of a transform is how two surfaces
/// come to disagree about where the frame is — which this app has already paid
/// for once, in the overlays that stayed pinned to the window while the
/// punched-in picture moved under them (`ViewAssist.placement`).
///
/// **The stage order is the whole contract** and it is stated once, here:
///
/// 1. **flip**, about the SOURCE's own centre — so flipping twice is exactly
///    the picture again, whatever else is set;
/// 2. **width / height**, the independent axis scales (`width` is what the
///    anamorphic desqueeze has always been);
/// 3. **rotate**, about the same centre;
/// 4. **aspect-fit** the result into the frame, times **zoom** — so a rotated
///    or stretched picture is LETTERBOXED rather than cropped, and zoom is the
///    only control that can push picture off the frame;
/// 5. **pan / tilt**, as fractions of the picture's own on-screen size, which
///    is the unit the punch-in pan has always used;
/// 6. **pitch / yaw**, the only non-affine terms, about the frame's centre.
///
/// Steps 1-5 are one `CGAffineTransform`, which is why the overlays, the
/// eyedropper and the framelines can ride it for free (`transform`). Step 6
/// has no affine inverse, which is why `isAffine` exists and why a pick from
/// the picture is refused under a pitch or a yaw rather than landing on the
/// wrong pixel.
public struct PictureSizing: Equatable, Sendable {
    /// Pan and tilt, as fractions of the picture's own size on screen — the
    /// unit the punch-in's pan has always been in. Clamped to what the zoom
    /// leaves off the frame (`panLimit`).
    public var panX = 0.0
    public var panY = 0.0
    /// Uniform magnification. Unlike the punch-in it replaces, it goes BELOW
    /// one: a colourist shrinks a picture to see what is outside the frame,
    /// and Resolve's own sizing does.
    public var zoom = 1.0
    /// The two axis scales. `width` is the anamorphic desqueeze under its
    /// Resolve name; `height` is new and has never existed in this app.
    public var width = 1.0
    public var height = 1.0
    /// Degrees, POSITIVE CLOCKWISE as the operator sees it — the direction
    /// Resolve turns for a positive number, and the direction an AppKit
    /// `rotationAngle` turns in the y-down space the overlays are laid out in.
    /// CoreImage is y-up and therefore takes the negative of it; that sign is
    /// in one place (`applied`) and pinned by a test that renders a mark and
    /// looks for it where `transform` says it should be.
    public var rotation = 0.0
    /// Degrees of perspective about the frame's horizontal and vertical axis —
    /// the only two terms that are not affine.
    public var pitch = 0.0
    public var yaw = 0.0
    public var flipH = false
    public var flipV = false

    public init() {}

    // MARK: - what a value IS

    /// Nothing set: the fast path every stage guards on, and the answer that
    /// keeps a take at its wire codes (a sizing that does nothing must not
    /// cost a resample — see `recordBakesDisplayBuffer`).
    public var isIdentity: Bool {
        self == PictureSizing()
    }

    /// Whether steps 1-5 are the whole of it, i.e. whether there is an affine
    /// inverse for the overlays and the eyedropper to ride.
    public var isAffine: Bool {
        pitch == 0 && yaw == 0
    }

    /// **Whether picture the camera sent leaves the frame.**
    ///
    /// Only the zoom can do that, and that is a consequence of the stage order
    /// rather than a policy: everything before step 4 is FITTED into the
    /// frame, so a 2:1 stretch or a 12° rotation shrinks the picture and puts
    /// black around it, while a zoom above 1 pushes its edges out of the
    /// frame. Asked by the record controls, which have to say out loud when a
    /// setting is throwing away footage permanently.
    public var isCropping: Bool {
        zoom > 1
    }

    /// Whether anything is set that a badge should light up for.
    public var isShowingChange: Bool { !isIdentity }

    // MARK: - the dials

    /// Zoom bounds. Below one is the half this app has never had: the punch-in
    /// floored at 1 because it was a focus aid, and a sizing is not.
    public static let minZoom = 0.1
    public static let maxZoom = 10.0
    /// The axis scales' bounds — the desqueeze's own range, which covers every
    /// anamorphic ever built (0.25 to 4) and is what the panel's ratio field
    /// already accepts.
    public static let minAxisScale = 0.25
    public static let maxAxisScale = 4.0

    /// How far the pan may travel before the magnified view leaves the
    /// picture: at magnification s only 1/s of the frame is visible, so its
    /// centre can move (1 − 1/s)/2 of a frame in each direction. The clamp
    /// used to be a flat ±0.5, which let the operator pan letterbox into the
    /// middle of the image at every magnification.
    public var panLimit: Double {
        zoom > 1 ? (1 - 1 / zoom) / 2 : 0
    }

    /// **The pan the two transforms actually take**, which is nothing at all
    /// below a magnification: unmagnified the picture has nowhere to go, and
    /// that is what `panLimit` says one line up.
    ///
    /// Read rather than trusted, because the value's own mutators are not the
    /// only way a pan gets set: the fields are stored settings and a restore
    /// writes them straight in, so a session that was saved punched-in and
    /// reopened at 1× used to carry a pan nothing would clamp. The mutators
    /// keep the invariant and this enforces it — belt and braces on the one
    /// number that can slide a picture off centre behind the operator's back.
    var effectivePan: CGPoint {
        guard zoom > 1 else { return .zero }
        return CGPoint(x: panX, y: panY)
    }

    /// Keep the pan inside `panLimit` (zooming back out has to bring the
    /// picture with it, not leave it parked off-centre).
    public mutating func clampPan() {
        let limit = panLimit
        panX = min(limit, max(-limit, panX))
        panY = min(limit, max(-limit, panY))
    }

    /// Set the magnification, clamped, pan kept inside the new frame.
    public mutating func setZoom(_ value: Double) {
        guard value.isFinite else { return }
        zoom = min(Self.maxZoom, max(Self.minZoom, value))
        clampPan()
    }

    /// Multiply the magnification (a pinch delta is relative), clamped.
    public mutating func magnify(by factor: Double) {
        guard factor > 0, factor.isFinite else { return }
        setZoom(zoom * factor)
    }

    /// Pan by a fraction of the whole frame, clamped. Positive `dx` moves the
    /// visible window right, i.e. the picture on screen left.
    public mutating func pan(by delta: CGSize) {
        guard zoom > 1 else { return }
        panX += Double(delta.width)
        panY += Double(delta.height)
        clampPan()
    }

    // MARK: - where the picture lands

    /// **The affine part, as one matrix**: source pixels (y DOWN, origin at the
    /// source's top-left — the space the overlays and the mouse are in) to
    /// viewport units.
    ///
    /// nil when a pitch or a yaw is set, because there is then no affine
    /// answer at all, and nil for a degenerate source or viewport (nothing to
    /// place). Every caller that inverts this — the eyedropper, the chroma
    /// pick, the taught-REC box — has to treat nil as "refuse", not as
    /// "identity": a pick that lands on the wrong pixel is worse than a pick
    /// that does not happen.
    public func transform(sourceSize: CGSize,
                          in viewport: CGSize) -> CGAffineTransform? {
        guard isAffine, sourceSize.width > 0, sourceSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return nil }
        // about the source's own centre — steps 1-3
        var shape = CGAffineTransform(translationX: -sourceSize.width / 2,
                                      y: -sourceSize.height / 2)
        shape = shape.concatenating(CGAffineTransform(
            scaleX: CGFloat(flipH ? -width : width),
            y: CGFloat(flipV ? -height : height)))
        shape = shape.concatenating(CGAffineTransform(
            rotationAngle: CGFloat(rotation) * .pi / 180))
        // step 4: what that shape's BOUNDING BOX has to fit into
        let box = CGRect(origin: .zero, size: sourceSize).applying(shape)
        guard box.width > 0, box.height > 0 else { return nil }
        let fit = min(viewport.width / box.width, viewport.height / box.height)
        let scale = fit * CGFloat(min(Self.maxZoom, max(Self.minZoom, zoom)))
        shape = shape.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        // step 5: pan, as a fraction of the picture's own size on screen
        let shiftX = effectivePan.x * box.width * scale
        let shiftY = effectivePan.y * box.height * scale
        return shape.concatenating(CGAffineTransform(
            translationX: viewport.width / 2 - shiftX,
            y: viewport.height / 2 - shiftY))
    }

    /// The picture's rect inside the viewport — its bounding box under
    /// `transform`, in the same y-down space. What the framelines and the
    /// letterbox need; nil under a pitch or a yaw, and for a degenerate size.
    public func pictureRect(sourceSize: CGSize, in viewport: CGSize) -> CGRect? {
        guard let matrix = transform(sourceSize: sourceSize, in: viewport)
        else { return nil }
        return CGRect(origin: .zero, size: sourceSize).applying(matrix)
    }

    /// Where a point on the SURFACE lands on the picture, as fractions of the
    /// frame (0,0 top-left, y down like the transform it inverts).
    ///
    /// nil when the point is off the picture — on the letterbox, or outside a
    /// zoomed crop — because there is no pixel there to answer for, and nil
    /// under a pitch or a yaw, which have no affine inverse at all.
    public func imageFraction(of point: CGPoint, sourceSize: CGSize,
                              in viewport: CGSize) -> CGPoint? {
        guard let matrix = transform(sourceSize: sourceSize, in: viewport),
              matrix.a * matrix.d - matrix.b * matrix.c != 0 else { return nil }
        let source = point.applying(matrix.inverted())
        let u = source.x / sourceSize.width
        let v = source.y / sourceSize.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
    }
}
